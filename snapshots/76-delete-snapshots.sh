#!/bin/sh
#
# 76-delete-snapshots.sh
# ------------------------
# Deletes one or more snapshot generations of a single client under
# SNAPSHOT_BASE (docs/SNAPSHOTS.md). This is the most dangerous code in the
# deployment -- it exists specifically to disarm the immutable flag and then
# delete recursively, on client-scoped history that otherwise cannot be
# removed at all.
#
# Usage:
#   ./snapshots/76-delete-snapshots.sh <client> [from] [to]
#
# Same three arguments, same meaning, as 75-list-snapshots.sh -- <client>
# mandatory, [from]/[to] optional inclusive bounds in the same
# YYYYMMDDTHHMMSSZ format 70-create-snapshot.sh names generations with.
# Omitting both deletes this client's ENTIRE snapshot history -- the
# intended way to handle a compromised client, a client's own repository
# reset, or complete/residue-free removal of a client, in one pass, without
# touching any other client's history (the client-first layout is what
# makes that one pass sufficient -- see docs/SNAPSHOTS.md, "Layout on
# disk").
#
# What this does, in order:
#
#   1. Calls 75-list-snapshots.sh with the exact same arguments, so the
#      operator sees precisely what generations and sizes are in scope
#      before being asked to confirm anything -- the same information,
#      the same script that would be used to look this up on its own.
#   2. Asks for confirmation. The prompt must be answered with an exact,
#      uppercase Y. Anything else -- empty input, "y", "yes", a stray
#      keystroke, EOF/no input at all -- aborts with nothing touched. This
#      is deliberately stricter than scripts/lib.sh's quota_confirm
#      ([y/N], case-insensitive), which guards reversible configuration
#      changes; this guards an irreversible deletion, elsewhere on the same
#      host as the only copy this action is capable of destroying.
#   3. Only then: for each generation in scope, `sudo chattr -R -i` (read
#      back via `lsattr` before trusting it worked -- see PRIVILEGES), then
#      `sudo rm -rf`. One generation failing does not stop the rest -- see
#      PRIVILEGES below for why both steps need root.
#
# Held under the same lock 70-create-snapshot.sh uses (SNAPSHOT_BASE/.lock),
# for the whole run from directly after argument validation through the
# last deletion: a creation run and a deletion run must never interleave on
# the same SNAPSHOT_BASE, and what step 1 shows the operator must be exactly
# what step 3 acts on -- taking the lock before step 1 is what guarantees
# nothing else in this tooling can add or remove a generation in between.
#
# PATH SAFETY. Per generation, the path actually handed to `chattr`/`rm` is
# canonicalized (`cd ... && pwd -P`) and checked to resolve inside
# SNAPSHOT_BASE before anything is touched -- this code must validate that
# its target resolves inside the snapshot root and refuse everything else,
# rather than trusting its argument. <client> is additionally restricted to
# a safe charset (same
# rule 70-/75- already apply) before it is ever used to build a path, and
# [from]/[to] must match the exact timestamp format, so neither can smuggle
# a `..` or an absolute path in.
#
# PRIVILEGES. Same operator user as every other script here, `sudo` for
# exactly two commands, both already reasoned through in
# 70-create-snapshot.sh's own header:
#
#   - `chattr -R -i`: needs CAP_LINUX_IMMUTABLE, same as setting +i did.
#   - `rm -rf`: clearing the immutable flag is NOT sufficient on its own.
#     The reflinked files still carry the *original* client directories'
#     mapped-subuid ownership and restrictive mode (verified against a real
#     deployment, FCOS-BorgBackupServer, 2026-08-25), so an unprivileged
#     `rm -rf` fails with `Permission denied` (a different failure than the
#     flag's `Operation not permitted`) even after the flag is gone.
#     Deleting therefore needs root too, not only the flag change.
#
# Unattended/scripted use is not a goal of this script -- the confirmation
# step exists precisely because deletion here is meant to be a deliberate,
# witnessed act by an operator, not something a cron job decides on its
# own. (A future retention-driven prune, if it is ever built, is a
# different, non-interactive script -- docs/SNAPSHOTS.md leaves that open.)
# A sudoers entry enabling passwordless `chattr` and `rm` already exists for
# 70-create-snapshot.sh's own unattended operation (its stale `.creating-*`
# cleanup needs `rm -rf` for the same reason this script's deletion does --
# see that script's own PRIVILEGES section). Running this script
# interactively does not need any of that to be passwordless, since a human
# is present to authenticate `sudo` normally -- but if a sudoers policy is
# written down, `chattr -R -i` and `rm -rf` here reuse exactly the same two
# commands 70-create-snapshot.sh's own policy already names, not new ones.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ -z "${SNAPSHOT_BASE:-}" ]; then
    echo "ERROR: SNAPSHOT_BASE is not set in config.sh."
    exit 1
fi
SNAPSHOT_BASE="${SNAPSHOT_BASE%/}"
case "$SNAPSHOT_BASE" in
    /*) ;;
    *) echo "ERROR: SNAPSHOT_BASE ('$SNAPSHOT_BASE') must be an absolute path."; exit 1 ;;
esac

CLIENT="${1:-}"
FROM="${2:-}"
TO="${3:-}"

if [ -z "$CLIENT" ]; then
    echo "ERROR: missing <client> argument."
    echo "Usage: $0 <client> [from] [to]"
    exit 1
fi

# Same rule 70-/75- apply to a directory name before it is ever used to
# build a path under SNAPSHOT_BASE.
case "$CLIENT" in
    ''|-*|*[!a-zA-Z0-9_-]*)
        echo "ERROR: '$CLIENT' must be non-empty, must not start with '-', and may"
        echo "       use only a-z, 0-9, _, - -- it is a path component under"
        echo "       SNAPSHOT_BASE and cannot be trusted otherwise."
        exit 1
        ;;
esac

check_timestamp_format() {
    case "$1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -n "$FROM" ] && ! check_timestamp_format "$FROM"; then
    echo "ERROR: [from] value '$FROM' is not in the expected format"
    echo "       YYYYMMDDTHHMMSSZ (e.g. 20260825T210335Z)."
    exit 1
fi
if [ -n "$TO" ] && ! check_timestamp_format "$TO"; then
    echo "ERROR: [to] value '$TO' is not in the expected format"
    echo "       YYYYMMDDTHHMMSSZ (e.g. 20260825T210335Z)."
    exit 1
fi
if [ -n "$FROM" ] && [ -n "$TO" ] && expr "$FROM" '>' "$TO" >/dev/null; then
    echo "ERROR: [from] ('$FROM') is later than [to] ('$TO')."
    exit 1
fi

CLIENT_DIR="${SNAPSHOT_BASE}/${CLIENT}"

if [ ! -d "$CLIENT_DIR" ]; then
    echo "No snapshots found for client '$CLIENT' under $SNAPSHOT_BASE."
    echo "Nothing to delete."
    exit 0
fi

# Soft check: DESIGN.md 1.2.3 requires client names to be unique across
# groups, and 70-create-snapshot.sh refuses to run when they are not -- but
# an out-of-band directory can still create that state after snapshots
# already exist. If it holds now, ${SNAPSHOT_BASE}/<client>/ may not be
# attributable to a single client. Warn; do not block (the operator may be
# deleting exactly to clean this up).
_live_group_count=0
for _d in "${HOST_REPO_BASE%/}"/*/"${CLIENT}"; do
    [ -d "$_d" ] || continue
    _live_group_count=$((_live_group_count + 1))
done
if [ "$_live_group_count" -gt 1 ]; then
    echo "WARNING: client '$CLIENT' has a live repository under more than one"
    echo "         group. These generations may not all belong to the same"
    echo "         client -- see DESIGN.md 1.2.3. Review before confirming."
    echo ""
fi

LIST_SCRIPT="$(dirname "$0")/75-list-snapshots.sh"
if [ ! -x "$LIST_SCRIPT" ]; then
    echo "ERROR: expected to find 75-list-snapshots.sh next to this script"
    echo "       ('$LIST_SCRIPT') -- it was not found or is not executable."
    exit 1
fi

# ---------------------------------------------------------------------------
# From here on, hold the same lock 70-create-snapshot.sh uses. See the
# header above for why this has to start before step 1 (the listing), not
# just before the deletions in step 3.
# ---------------------------------------------------------------------------
LOCK_FILE="${SNAPSHOT_BASE}/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another snapshot run (create or delete) is already in"
    echo "       progress (lock held: $LOCK_FILE). Nothing was done."
    exit 1
fi

echo "The following generations are in scope for client '$CLIENT':"
echo ""
"$LIST_SCRIPT" "$CLIENT" "$FROM" "$TO"
echo ""

# Independent, name-only enumeration for the actual deletion set -- same
# filter 75-list-snapshots.sh just applied above, but without sizing (no
# `du` needed to decide what to delete). Held under the same lock as the
# listing just printed, so this can only differ from it if something
# outside this tooling touched SNAPSHOT_BASE between the two -- not a case
# either script defends against anywhere else either.
TMP_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
GEN_LIST="${TMP_DIR}/generations"

for GEN_DIR in "$CLIENT_DIR"/*/; do
    [ -d "$GEN_DIR" ] || continue
    TS="$(basename "$GEN_DIR")"
    check_timestamp_format "$TS" || continue
    if [ -n "$FROM" ] && expr "$TS" '<' "$FROM" >/dev/null; then continue; fi
    if [ -n "$TO" ] && expr "$TS" '>' "$TO" >/dev/null; then continue; fi
    printf '%s\n' "$TS"
done | sort > "$GEN_LIST"

if [ ! -s "$GEN_LIST" ]; then
    echo "Nothing in scope. Nothing to delete."
    exit 0
fi

COUNT=$(wc -l < "$GEN_LIST" | tr -d ' ')

# ---------------------------------------------------------------------------
# Confirmation. Exact, uppercase Y only -- see header for why this is
# stricter than scripts/lib.sh's quota_confirm.
# ---------------------------------------------------------------------------
echo "!!! This will PERMANENTLY delete the ${COUNT} generation(s) listed above"
echo "!!! for client '$CLIENT'. This cannot be undone -- a snapshot lives on"
echo "!!! the same storage as everything else this tooling protects."
printf 'Type Y (exactly, uppercase) to proceed, anything else aborts: '
IFS= read -r ANSWER || ANSWER=""
case "$ANSWER" in
    Y) ;;
    *)
        echo "Aborted — nothing was deleted."
        exit 0
        ;;
esac

# delete_generation <dir>
#
# One generation: canonicalize and verify it resolves inside SNAPSHOT_BASE
# (see PATH SAFETY above), clear the immutable flag with a read-back
# verification (same "trust but verify" idiom 70-create-snapshot.sh uses
# for +i), then delete. Returns 0 on success, 1 on any failure; every
# failure explains itself and leaves whatever it could not finish exactly
# where it was, never in a half-renamed or otherwise ambiguous state.
delete_generation() {
    _dg_dir="$1"

    _dg_real="$(cd "$_dg_dir" 2>/dev/null && pwd -P)" || {
        echo "ERROR: cannot resolve '$_dg_dir' -- skipping, nothing touched."
        return 1
    }
    case "$_dg_real" in
        "${SNAPSHOT_BASE}"/*) ;;
        *)
            echo "ERROR: '$_dg_real' does not resolve inside SNAPSHOT_BASE"
            echo "       ('$SNAPSHOT_BASE') -- refusing to touch it."
            return 1
            ;;
    esac

    if ! sudo chattr -R -i "$_dg_real"; then
        echo "ERROR: could not clear the immutable flag on '$_dg_real'."
        echo "       Left untouched -- still protected, nothing was deleted."
        return 1
    fi

    _dg_attrs="$(lsattr -d "$_dg_real" 2>/dev/null | awk '{print $1}')"
    case "$_dg_attrs" in
        *i*)
            echo "ERROR: chattr reported success but '$_dg_real' still shows"
            echo "       the immutable flag on read-back. Refusing to delete"
            echo "       something that may still be protected."
            return 1
            ;;
    esac

    if ! sudo rm -rf "$_dg_real"; then
        echo "ERROR: '$_dg_real' had its immutable flag cleared but could"
        echo "       NOT be deleted. It is NOT protected anymore -- needs"
        echo "       manual attention immediately."
        return 1
    fi

    echo "[delete] removed $_dg_real"
    return 0
}

FAILED=0
while IFS= read -r TS; do
    [ -n "$TS" ] || continue
    if ! delete_generation "${CLIENT_DIR}/${TS}"; then
        FAILED=$((FAILED + 1))
    fi
done < "$GEN_LIST"

echo ""
OK=$((COUNT - FAILED))
echo "${OK}/${COUNT} generation(s) deleted for client '$CLIENT'."
if [ "$FAILED" -gt 0 ]; then
    echo "${FAILED} generation(s) FAILED -- see ERROR lines above. Needs manual attention."
    exit 1
fi
exit 0
