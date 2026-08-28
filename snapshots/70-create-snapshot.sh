#!/bin/sh
#
# 70-create-snapshot.sh
# ----------------------
# Creates one point-in-time snapshot of every client currently found under
# HOST_REPO_BASE (see docs/SNAPSHOTS.md for the full picture). For each
# client:
#
#   ${SNAPSHOT_BASE}/<group>/<client>/<timestamp>/
#
#   - the snapshot tree mirrors HOST_REPO_BASE/<group>/<client> exactly
#     (DESIGN.md 1.2.3), so an operator reads one the way they read the
#     other, and two clients of the same name in different groups can never
#     collide here even if the "globally unique name" rule is somehow
#     violated out of band
#   - copied from ${HOST_REPO_BASE}/<group>/<client> with
#     `cp -a --reflink=always` (cheap: blocks are shared with the live
#     repository until either side diverges)
#   - then made read-only, rename-proof and delete-proof with
#     `chattr -R +i` — this, not a weaker permission change, is what
#     actually matters: it blocks unlink()/rename() outright (EPERM) on
#     every file, where a mode change alone leaves root free to `chmod`
#     its way back in first.
#
# Copying a live, actively-written repository this way is safe -- tested,
# not assumed. A `cp -a` walk is not atomic the way a block-layer snapshot
# would be, so the obvious worry is a transaction committing mid-copy: an
# index naming a segment the copy never actually captured. Tested
# empirically (Borg 1.2.8): a deterministic worst case (segments copied
# before a second archive committed, then the index copied after), the
# reverse ordering, and a real `borg create` interrupted mid-write by a
# plain `cp -a` all came back clean under `borg check`. On a cache-less
# first access Borg does not appear to trust a copied index at face value
# -- it rebuilds the true state from the segments actually present in
# `data/`, the same replay a hard crash already relies on. This script
# therefore does one unordered copy per client, no special-casing of
# `index`/`hints` versus `data/`.
#
# Clients are discovered by walking the filesystem
# (${HOST_REPO_BASE}/<group>/<client>), not by reading clients.conf: the
# point of this feature is to protect whatever is physically on disk,
# including a client whose clients.conf entry is missing or wrong. (A
# client's clients.conf entry itself surviving on the filesystem but not
# in the file is a different situation -- scripts/04-reattach-client.sh.)
#
# Usage:
#   ./snapshots/70-create-snapshot.sh
#
#   No arguments: every run sweeps every client found under HOST_REPO_BASE.
#   Nothing is skipped by prior success — a snapshot is a new, independent
#   directory each time, keyed by the timestamp this run started at.
#
# Intended to run unattended, on a schedule (hence no confirmation prompt,
# unlike scripts/00 and scripts/03 — this operation only ever adds a
# directory, it never changes or removes anything an operator would want to
# confirm first). Two ways to schedule it, pick whichever exists on your
# host:
#
#   - systemd timer (works everywhere this project already requires
#     systemd for the container service, and the only option on Fedora
#     CoreOS, which has no cron): see snapshots/71-timer-install.sh and
#     snapshots/snapshot-create.timer, which fires daily at 03:00.
#   - plain crontab line, hourly, on a host that has cron:
#
#       0 * * * *  /path/to/borg-server/snapshots/70-create-snapshot.sh >> /path/to/borg-server/log/snapshots.log 2>&1
#
# A run already in progress is detected and refused (flock on a lock file
# inside SNAPSHOT_BASE), so a slow run never overlaps the next firing,
# whichever of the two triggers it.
#
# One client failing (disk full mid-copy, an unreadable directory, ...) does
# not stop the others: every client found is attempted, and the exit status
# at the end reflects whether all of them succeeded (0) or not (1) — the
# signal a cron MAILTO or a systemd OnFailure= unit is meant to catch.
#
# TIMING. Every client is timed (wall clock around the whole per-client
# attempt — mkdir, stale cleanup, the reflink copy, rename, chattr and its
# read-back). Reported on the normal `[snapshot] ...` line every run, cheap
# enough to always print. Where the time actually goes on a real repository
# — the reflink copy is expected to be near-instant regardless of data size
# (blocks are shared, not moved), `chattr -R` recurses the whole tree and is
# the more likely place a large client shows up here — has not been
# measured against a real repository; only against small synthetic test
# trees so far (see this script's own commit history).
#
# DEBUG LOG. Off by default — nothing is written and no file is created.
# Set SNAPSHOT_DEBUG_LOG to a path to additionally append one line per
# client (timestamp, directory, result, duration) there, e.g.:
#
#   SNAPSHOT_DEBUG_LOG=/path/to/borg-server/log/snapshot-debug.log ./snapshots/70-create-snapshot.sh
#
# Meant for a one-off debugging session (a slow or misbehaving run), not
# routine operation — the normal stdout lines already go wherever stdout
# goes (cron's own redirection, or the journal under the systemd timer), so
# this does not replace that. To turn it off again, stop setting the
# variable; nothing needs to be edited in this script.
#
# PRIVILEGES. Run as the normal operator user, the SAME user that runs the
# container — same as every script in scripts/ — with three exceptions
# elevated internally via `sudo`, and unattended operation needs all three to
# be passwordless (a sudoers drop-in restricting them to exactly these
# commands, e.g.
# `operator ALL=(root) NOPASSWD: /usr/bin/cp, /usr/sbin/chattr, /usr/bin/rm`
# — narrower still if your sudo supports argument restrictions):
#
#   - `cp -a`: the source directories are owned by the container's mapped
#     subuid (see scripts/lib.sh, repo_dir_create), not by this operator. A
#     plain `cp -a` cannot preserve that ownership without CAP_CHOWN — it
#     would either fail outright or silently hand back a snapshot owned by
#     the wrong user, which is exactly the kind of silently-wrong state this
#     project avoids elsewhere (see quota_verify, repo_ns_uid_ok). Root can
#     chown to any numeric id, mapped subuid included, so this is a plain
#     `sudo cp`, not a `podman unshare` — nothing here runs inside the
#     container's user namespace.
#   - `chattr -R +i`: needs CAP_LINUX_IMMUTABLE, which not even the file's
#     owner has without it.
#   - `rm -rf` (stale `.creating-*` cleanup only): the same `cp -a` above
#     already means a genuinely stale staging directory is mapped-subuid-
#     owned, not operator-owned, for exactly the reason the `cp -a` bullet
#     gives — an unprivileged `rm -rf` fails on it the same way an
#     unprivileged `cp -a` would. See 76-delete-snapshots.sh's own
#     PRIVILEGES section: this is the same command, needed for the same
#     reason, on content this script itself created rather than on a
#     finished, immutable generation.
#
# Must run on the HOST, not inside the container — see OPERATIONS.md
# chapter 9.12.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

# snapshot_debug_log <line>
#
# See "DEBUG LOG" above. A no-op, and no file is ever created, unless
# SNAPSHOT_DEBUG_LOG is set.
snapshot_debug_log() {
    [ -n "${SNAPSHOT_DEBUG_LOG:-}" ] || return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$SNAPSHOT_DEBUG_LOG"
}

# snapshot_client <client-dir>
#
# Everything for one client: mkdir, stale-staging cleanup, the reflink copy,
# the rename, chattr, and reading the flag back. A function rather than
# inline loop body so the loop below can time and log the whole attempt in
# one place regardless of where inside here a client succeeds or fails —
# `return` where the inline version used `continue`, so control always comes
# back to the loop's own timing/logging tail. Returns 0 on success, 1 on any
# failure; every failure explains itself on stdout before returning.
#
# Uses the shared globals SNAPSHOT_BASE and TIMESTAMP (set once for the
# whole run, below) and prefixes everything local to itself with `_sc_` —
# same convention scripts/lib.sh's functions use — since POSIX sh functions
# have no `local` and share the caller's variable namespace.
snapshot_client() {
    _sc_client_dir="$1"
    _sc_username="$(basename "$_sc_client_dir")"
    _sc_group="$(basename "$(dirname "$_sc_client_dir")")"

    # Both path components are validated before use, since both become
    # directory names under SNAPSHOT_BASE.
    case "$_sc_username" in
        ''|-*|*[!a-zA-Z0-9_-]*)
            echo "ERROR: skipping '$_sc_client_dir' -- name must be non-empty,"
            echo "       must not start with '-', and may use only a-z, 0-9, _, -"
            echo "       to be trusted as a path component under SNAPSHOT_BASE."
            return 1
            ;;
    esac
    case "$_sc_group" in
        ''|-*|*[!a-zA-Z0-9_-]*)
            echo "ERROR: skipping '$_sc_client_dir' -- group '$_sc_group' must be"
            echo "       non-empty, must not start with '-', and may use only"
            echo "       a-z, 0-9, _, - to be trusted as a path component."
            return 1
            ;;
    esac

    _sc_snap_dir="${SNAPSHOT_BASE}/${_sc_group}/${_sc_username}"
    _sc_staging="${_sc_snap_dir}/.creating-${TIMESTAMP}"
    _sc_final="${_sc_snap_dir}/${TIMESTAMP}"

    echo "[snapshot] ${_sc_group}/${_sc_username}: starting"

    mkdir -p "$_sc_snap_dir"

    # A .creating-* left behind by a run that never reached the mv below
    # (crash, kill, disk full mid-copy). It was never renamed to a real
    # <timestamp>/, so nothing could have listed or relied on it yet, and it
    # is never immutable (chattr only ever runs after the rename) -- but it
    # is not plain-owned either. `sudo cp -a` above preserves the SOURCE's
    # ownership and mode onto it, same as onto any finished snapshot: a
    # genuinely interrupted copy is owned by the client's mapped subuid at
    # mode 755, exactly like the live client directory it came from. An
    # unprivileged `rm -rf` cannot recurse into that (confirmed against a
    # real deployment -- FCOS-BorgBackupServer, 2026-08-27: it fails on the
    # first file with "Permission denied" and leaves the rest of the stale
    # tree in place, silently, forever, since the run's own outcome does not
    # depend on this cleanup succeeding). Needs the same privilege the copy
    # itself used to create it.
    for _sc_stale in "${_sc_snap_dir}"/.creating-*; do
        [ -e "$_sc_stale" ] || continue
        echo "[snapshot] ${_sc_username}: removing stale incomplete snapshot from a previous run: $_sc_stale"
        sudo rm -rf "$_sc_stale"
    done

    if [ -e "$_sc_final" ]; then
        echo "ERROR: ${_sc_username}: '$_sc_final' already exists (duplicate timestamp"
        echo "       within the same second?). Skipping this client this run."
        return 1
    fi

    if ! sudo cp -a --reflink=always "$_sc_client_dir" "$_sc_staging"; then
        echo "ERROR: ${_sc_username}: reflink copy failed. Leaving '$_sc_staging' in"
        echo "       place for inspection; it is not a valid snapshot and"
        echo "       will be removed automatically on the next run."
        return 1
    fi

    if ! mv "$_sc_staging" "$_sc_final"; then
        echo "ERROR: ${_sc_username}: could not rename '$_sc_staging' to '$_sc_final'."
        return 1
    fi

    if ! sudo chattr -R +i "$_sc_final"; then
        echo "ERROR: ${_sc_username}: '$_sc_final' was created but chattr +i failed."
        echo "       It holds a real copy of this client's data but is NOT"
        echo "       protected against deletion. Needs manual attention."
        return 1
    fi

    # Trust but verify, the way quota_verify reads the limit back rather than
    # the exit status of the command that set it: confirm the flag actually
    # reached the directory rather than assuming a zero exit means it did.
    _sc_final_attrs="$(lsattr -d "$_sc_final" 2>/dev/null | awk '{print $1}')"
    case "$_sc_final_attrs" in
        *i*) ;;
        *)
            echo "ERROR: ${_sc_username}: chattr reported success but '$_sc_final' is"
            echo "       NOT showing the immutable flag on read-back"
            echo "       (lsattr: '${_sc_final_attrs:-unreadable}'). Needs manual"
            echo "       attention -- this snapshot is not protected."
            return 1
            ;;
    esac

    echo "[snapshot] ${_sc_username}: done -> $_sc_final"
    return 0
}

if [ -z "${HOST_REPO_BASE:-}" ]; then
    echo "ERROR: HOST_REPO_BASE is not set in config.sh."
    exit 1
fi
if [ -z "${SNAPSHOT_BASE:-}" ]; then
    echo "ERROR: SNAPSHOT_BASE is not set in config.sh."
    exit 1
fi

# Normalize: strip any trailing slash so path construction below is
# unambiguous regardless of how the operator wrote config.sh.
HOST_REPO_BASE="${HOST_REPO_BASE%/}"
SNAPSHOT_BASE="${SNAPSHOT_BASE%/}"

case "$HOST_REPO_BASE" in
    /*) ;;
    *) echo "ERROR: HOST_REPO_BASE ('$HOST_REPO_BASE') must be an absolute path."; exit 1 ;;
esac
case "$SNAPSHOT_BASE" in
    /*) ;;
    *) echo "ERROR: SNAPSHOT_BASE ('$SNAPSHOT_BASE') must be an absolute path."; exit 1 ;;
esac

# HOST_REPO_BASE must already exist. Not mkdir -p'd here either, for the same
# reason scripts/00-ssh-create-user.sh refuses to: if the storage volume is
# not mounted, silently creating it fresh would snapshot an empty directory
# on the wrong (root) filesystem instead of failing loudly.
if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "ERROR: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist or is not a directory."
    echo "Check that the intended storage volume is mounted."
    exit 1
fi

# SNAPSHOT_BASE, unlike HOST_REPO_BASE, IS created here: it is this script's
# own territory (docs/SNAPSHOTS.md — a sibling of HOST_REPO_BASE, never nested
# inside a client's project tree, so it carries no client's XFS project id
# by construction), not a client-facing path an operator must consciously
# mount first. Created as the plain operator, not root: nothing here needs
# to be owned by the container's mapped uid, only the client subtrees
# reflinked into it later do.
mkdir -p "$SNAPSHOT_BASE"

# ---------------------------------------------------------------------------
# Refuse to overlap with another run
# ---------------------------------------------------------------------------
#
# The lock lives inside SNAPSHOT_BASE itself so it is automatically
# namespaced per CONTAINER exactly the way SNAPSHOT_BASE already is (ROADMAP
# 11.5) -- two independently-scheduled instances of this tooling protecting
# different containers on the same volume cannot contend on the same lock
# file either. Held for the whole run via fd 9; released automatically when
# the script exits, however it exits.
LOCK_FILE="${SNAPSHOT_BASE}/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another 70-create-snapshot.sh run is still in progress"
    echo "       (lock held: $LOCK_FILE). Nothing was done."
    exit 1
fi

# ---------------------------------------------------------------------------
# Reflink support -- a hard prerequisite, checked once up front rather than
# discovered as a mid-run cp failure on the first client.
# ---------------------------------------------------------------------------
SNAP_MOUNT=$(df -P "$SNAPSHOT_BASE" | awk 'NR==2 {print $6}')
if [ -z "$SNAP_MOUNT" ]; then
    echo "ERROR: could not resolve the filesystem mount for '$SNAPSHOT_BASE'."
    exit 1
fi
if ! xfs_info "$SNAP_MOUNT" 2>/dev/null | grep -q 'reflink=1'; then
    echo "ERROR: '$SNAPSHOT_BASE' (mount '$SNAP_MOUNT') is not on an XFS"
    echo "       filesystem with reflink support (xfs_info must report"
    echo "       reflink=1). This mechanism requires it (see docs/SNAPSHOTS.md,"
    echo "       \"Why reflinks\"). Nothing was done."
    exit 1
fi

# ---------------------------------------------------------------------------
# One snapshot generation for this whole run. Every client that gets a
# snapshot this run gets the same label -- the group/client layout
# (docs/SNAPSHOTS.md, "Layout on disk") means this carries no grouping
# meaning, it is purely "when this run happened".
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

RUN_START="$(date +%s.%N)"
snapshot_debug_log "run start host_repo_base=${HOST_REPO_BASE} snapshot_base=${SNAPSHOT_BASE} timestamp=${TIMESTAMP}"

TOTAL=0
FAILED=0

# Same enumeration lib.sh's repo_projid_next already uses for "every client
# directory that exists on disk": HOST_REPO_BASE/<group>/<client>, two
# levels deep. Deliberately not clients.conf -- see the file header.
for CLIENT_DIR in "${HOST_REPO_BASE}"/*/*; do
    [ -d "$CLIENT_DIR" ] || continue
    TOTAL=$((TOTAL + 1))

    CLIENT_START="$(date +%s.%N)"
    if snapshot_client "$CLIENT_DIR"; then
        CLIENT_RESULT="ok"
    else
        CLIENT_RESULT="failed"
        FAILED=$((FAILED + 1))
    fi
    CLIENT_END="$(date +%s.%N)"
    CLIENT_DURATION="$(awk -v s="$CLIENT_START" -v e="$CLIENT_END" 'BEGIN{printf "%.2f", e-s}')"

    echo "[snapshot] $(basename "$CLIENT_DIR"): ${CLIENT_RESULT} in ${CLIENT_DURATION}s"
    snapshot_debug_log "client=$(basename "$CLIENT_DIR") dir=${CLIENT_DIR} result=${CLIENT_RESULT} duration=${CLIENT_DURATION}s"
done

RUN_END="$(date +%s.%N)"
RUN_DURATION="$(awk -v s="$RUN_START" -v e="$RUN_END" 'BEGIN{printf "%.2f", e-s}')"
snapshot_debug_log "run end total=${TOTAL} failed=${FAILED} duration=${RUN_DURATION}s"

echo ""
if [ "$TOTAL" -eq 0 ]; then
    echo "[snapshot] No clients found under $HOST_REPO_BASE. Nothing to do."
    exit 0
fi

OK=$((TOTAL - FAILED))
echo "[snapshot] $OK/$TOTAL client(s) snapshotted successfully in ${RUN_DURATION}s total."
if [ "$FAILED" -gt 0 ]; then
    echo "[snapshot] $FAILED client(s) FAILED -- see ERROR lines above."
    exit 1
fi
exit 0
