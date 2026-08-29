#!/bin/sh
#
# 75-list-snapshots.sh
# ---------------------
# Inventory for one client's snapshot history under SNAPSHOT_BASE
# (docs/SNAPSHOTS.md): which generations exist, and how large each one is.
# Pure read-only reporting -- no anomaly detection, no thresholds. A
# structural comparison between generations (segments, config, nonce) to
# explain *what* changed was considered and dropped (docs/SNAPSHOTS.md,
# "What this does not protect against") -- it could not add anything
# append-only does not already rule out. This script only ever prints raw
# numbers; interpreting
# them is left to the operator, on purpose -- what counts as a normal size
# for one client says nothing about another.
#
# Usage:
#   ./snapshots/75-list-snapshots.sh <client> [from] [to]
#
#   <client>  Required. A username as it appears under HOST_REPO_BASE. The
#             group is resolved from the snapshot tree itself
#             (SNAPSHOT_BASE/<group>/<client>/, the same shape as
#             HOST_REPO_BASE), not passed in. Not cross-checked against
#             clients.conf or HOST_REPO_BASE -- a client that was
#             snapshotted and has since been removed from either still has
#             to be listable here.
#
#   [from]    Optional. Lower bound, inclusive.
#   [to]      Optional. Upper bound, inclusive.
#
#             Both must be given in exactly the same format
#             70-create-snapshot.sh names its generations with:
#             YYYYMMDDTHHMMSSZ (UTC, ISO-8601 basic) -- e.g.
#             20260825T210335Z. This is deliberate, not a limitation: every
#             valid value is copy-pasteable straight out of this script's own
#             output, so there is never a date parser to get wrong or a
#             timezone to guess at. Omitting [from] means "from the oldest
#             generation on"; omitting [to] means "up to the newest".
#
# Examples:
#   ./snapshots/75-list-snapshots.sh user1-os1-pc1
#   ./snapshots/75-list-snapshots.sh user1-os1-pc1 20260801T000000Z
#   ./snapshots/75-list-snapshots.sh user1-os1-pc1 20260801T000000Z 20260901T000000Z
#
# Why a range matters here at all: a client's history can span years and
# thousands of generations. Without a bound, listing it means sizing every
# single one of them (see COST below) just to look at the most recent week.
#
# COST. There is no fast path for snapshot size the way 09-show-all-users.sh
# has one for live repositories: SNAPSHOT_BASE deliberately carries no XFS
# project id -- exactly so that reflinked blocks are never double-counted
# against a client's quota -- so there is no per-directory quota to read via
# a cheap `df`. Each generation actually printed here is sized with `du -sh`,
# which walks its whole tree -- the same order of cost `70-create-snapshot.sh`
# already pays once per generation to create it via `cp -a`. Bounding
# [from]/[to] bounds how many generations get walked. What this has NOT been
# measured against is a single client repository large enough for that one
# walk itself to be slow (a multi-terabyte archive with very many segments)
# -- the same gap flagged as unmeasured for 70-create-snapshot.sh's own
# `chattr -R` step (see that script's own header, TIMING).
#
# Note on what `du -sh` actually reports: reflinked blocks are shared on
# disk, but each generation's own inodes still carry the full extent map, so
# `du` reports each generation's complete size on its own terms, not the
# marginal cost it actually adds to the volume (which is usually far
# smaller, and only visible in aggregate -- 11 real client repositories
# snapshotted twice, 22 generations total, moved reported volume usage to
# 2.0 GiB, measured against a real deployment). That is the right number for
# this script's purpose: an
# operator scanning for an anomaly wants to see "generation N is a very
# different size than its neighbours", not the volume's aggregate storage
# bill.
#
# PRIVILEGES. Runs as the normal operator user, with one elevated read:
# `sudo du -sh` on each generation. The generation directory itself was
# reflinked from HOST_REPO_BASE, which scripts/lib.sh (repo_dir_create)
# deliberately leaves at mode 755 precisely so the operator can read into it
# without root, and `cp -a` preserves that mode -- but Borg's own `data/`
# subdirectory inside the repository is mode 700, owned by the mapped
# subuid, regardless of the outer directory's mode. An unprivileged `du`
# cannot descend into it and silently reports only the handful of always-
# readable top-level metadata files, undercounting the true size by orders
# of magnitude (issue #35) -- so this read needs `sudo` to be correct, even
# though nothing here needs to change data or metadata, and so nothing here
# needs CAP_LINUX_IMMUTABLE or CAP_CHOWN.
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

# Same charset rule 70-create-snapshot.sh applies to a directory name found
# on disk (scripts/lib.sh has nothing to check this argument against, since
# this script deliberately does not cross-reference clients.conf) -- an
# operator typo containing e.g. '/' or '..' must not be allowed to walk this
# script's path construction anywhere outside SNAPSHOT_BASE.
case "$CLIENT" in
    ''|-*|*[!a-zA-Z0-9_-]*)
        echo "ERROR: '$CLIENT' must be non-empty, must not start with '-', and may"
        echo "       use only a-z, 0-9, _, - -- it is a path component under"
        echo "       SNAPSHOT_BASE and cannot be trusted otherwise."
        exit 1
        ;;
esac

# [from]/[to] format check: exactly YYYYMMDDTHHMMSSZ. Rejected outright
# rather than guessed at -- see the header for why.
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

# Fixed-width, zero-padded, same fields in the same order in every valid
# value -- plain ASCII string comparison already sorts these chronologically,
# no date arithmetic needed. `expr`'s relational operators do exactly that
# comparison for non-integer operands (POSIX); output discarded, only the
# exit status is used.
if [ -n "$FROM" ] && [ -n "$TO" ] && expr "$FROM" '>' "$TO" >/dev/null; then
    echo "ERROR: [from] ('$FROM') is later than [to] ('$TO')."
    exit 1
fi

# Resolve the client's group from the snapshot tree
# (SNAPSHOT_BASE/<group>/<client>/, the same shape as HOST_REPO_BASE). The
# client name is unique across groups (DESIGN.md 1.2.3), so this matches
# exactly one -- if it ever matched two, refuse rather than guess.
GROUP=""
for _d in "${SNAPSHOT_BASE}"/*/"${CLIENT}"; do
    [ -d "$_d" ] || continue
    if [ -n "$GROUP" ]; then
        echo "ERROR: client '$CLIENT' has snapshots under more than one group"
        echo "       ('$GROUP' and '$(basename "$(dirname "$_d")")'). The name"
        echo "       must be unique across groups -- see DESIGN.md 1.2.3."
        exit 1
    fi
    GROUP="$(basename "$(dirname "$_d")")"
done

if [ -z "$GROUP" ]; then
    echo "No snapshots found for client '$CLIENT' under $SNAPSHOT_BASE."
    echo "(Either this client has never been snapshotted, or the name does"
    echo "not match what 70-create-snapshot.sh recorded it under.)"
    exit 0
fi

CLIENT_DIR="${SNAPSHOT_BASE}/${GROUP}/${CLIENT}"

# Working file for the sorted, filtered list of generation names -- a real
# temp file rather than a shell variable so an empty result and "one empty
# line" can never be confused, the same reason 09-show-all-users.sh uses a
# temp dir for its markers rather than a variable set inside a subshell.
TMP_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
GEN_LIST="${TMP_DIR}/generations"

# Entries that are not a completed generation -- a stale
# .creating-<timestamp> staging directory left by an interrupted run, or
# SNAPSHOT_BASE's own .lock -- do not match the timestamp format and are
# silently skipped rather than listed as broken: 70-create-snapshot.sh
# already treats a leftover .creating-* as routine cleanup, not a fault, and
# this script should agree with it rather than alarm the operator over the
# same non-event.
#
# This `for` is the left side of a pipe into `sort`, so it runs in a
# subshell -- fine here, since nothing set inside it is read afterwards; the
# sorted result is read back from $GEN_LIST instead. Sorting works because
# the timestamp format is fixed-width and zero-padded: plain ASCII sort
# already puts these in chronological order, exactly the way the range
# check above already relies on for comparing two of them.
for GEN_DIR in "$CLIENT_DIR"/*/; do
    [ -d "$GEN_DIR" ] || continue
    TS="$(basename "$GEN_DIR")"
    check_timestamp_format "$TS" || continue

    if [ -n "$FROM" ] && expr "$TS" '<' "$FROM" >/dev/null; then continue; fi
    if [ -n "$TO" ] && expr "$TS" '>' "$TO" >/dev/null; then continue; fi

    printf '%s\n' "$TS"
done | sort > "$GEN_LIST"

if [ ! -s "$GEN_LIST" ]; then
    if [ -n "$FROM" ] || [ -n "$TO" ]; then
        echo "No snapshot generations for client '$CLIENT' in the given range."
    else
        echo "No snapshot generations found for client '$CLIENT' under $CLIENT_DIR."
    fi
    exit 0
fi

# One line per generation, oldest first: timestamp, then size. `sudo du -sh`
# walks the whole generation (see COST and PRIVILEGES above) -- a failure
# (sudo unavailable, a generation removed mid-run) shows as a clear marker
# rather than aborting the rest of the listing, the same "empty output is
# the real signal" idiom 09-show-all-users.sh uses for df.
COUNT=0
while IFS= read -r TS; do
    [ -n "$TS" ] || continue
    SIZE="$(sudo du -sh "${CLIENT_DIR}/${TS}" 2>/dev/null | cut -f1)"
    [ -n "$SIZE" ] || SIZE="n/a (unreadable)"
    printf '%-20s %s\n' "$TS" "$SIZE"
    COUNT=$((COUNT + 1))
done < "$GEN_LIST"

echo ""
echo "${COUNT} generation(s) listed for client '$CLIENT'."
