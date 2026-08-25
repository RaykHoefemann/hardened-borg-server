#!/bin/sh
#
# 70-create-snapshot.sh
# ----------------------
# Creates one point-in-time snapshot of every client currently found under
# HOST_REPO_BASE (ROADMAP.md 11.5). For each client:
#
#   ${SNAPSHOT_BASE}/<client>/<timestamp>/
#
#   - copied from ${HOST_REPO_BASE}/<group>/<client> with
#     `cp -a --reflink=always` (cheap: blocks are shared with the live
#     repository until either side diverges)
#   - then made read-only, rename-proof and delete-proof with
#     `chattr -R +i` — see "Constraints to preserve" in ROADMAP.md 11.5 for
#     why this, and not a weaker permission change, is what actually matters
#
# Copy ordering between data/ and index/hints/ was flagged in ROADMAP.md as
# an open question and has since been tested and resolved: a single
# unordered `cp -a --reflink=always` over the whole client tree is
# sufficient (ROADMAP.md 11.5, "Copy ordering"). This script does not
# special-case any file within a client's tree.
#
# Clients are discovered by walking the filesystem
# (${HOST_REPO_BASE}/<group>/<client>), not by reading clients.conf: the
# point of this feature is to protect whatever is physically on disk,
# including a client whose clients.conf entry is missing or wrong (see
# ROADMAP.md 11.5, "What restoring HOST_REPO_BASE alone does not restore").
#
# Usage:
#   ./snapshots/70-create-snapshot.sh
#
#   No arguments: every run sweeps every client found under HOST_REPO_BASE.
#   Nothing is skipped by prior success — a snapshot is a new, independent
#   directory each time, keyed by the timestamp this run started at.
#
# Intended to run unattended from cron (hence no confirmation prompt, unlike
# scripts/00 and scripts/03 — this operation only ever adds a directory, it
# never changes or removes anything an operator would want to confirm
# first). Example crontab line, hourly:
#
#   0 * * * *  /path/to/borg-server/snapshots/70-create-snapshot.sh >> /path/to/borg-server/log/snapshots.log 2>&1
#
# A run already in progress is detected and refused (flock on a lock file
# inside SNAPSHOT_BASE), so a slow run never overlaps the next cron firing.
#
# One client failing (disk full mid-copy, an unreadable directory, ...) does
# not stop the others: every client found is attempted, and the exit status
# at the end reflects whether all of them succeeded (0) or not (1) — the
# signal a cron MAILTO or a systemd OnFailure= unit is meant to catch.
#
# PRIVILEGES. Run as the normal operator user, the SAME user that runs the
# container — same as every script in scripts/ — with two exceptions
# elevated internally via `sudo`, and unattended operation needs both to be
# passwordless (a sudoers drop-in restricting them to exactly these two
# commands, e.g. `operator ALL=(root) NOPASSWD: /usr/bin/cp, /usr/sbin/chattr`
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
#
# Must run on the HOST, not inside the container — see OPERATIONS.md
# chapter 9.12.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

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
# own territory (ROADMAP.md 11.5 — a sibling of HOST_REPO_BASE, never nested
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
    echo "       reflink=1). This mechanism requires it (ROADMAP.md 11.5,"
    echo "       \"Mechanism\"). Nothing was done."
    exit 1
fi

# ---------------------------------------------------------------------------
# One snapshot generation for this whole run. Every client that gets a
# snapshot this run gets the same label -- client isolation (ROADMAP.md
# 11.5, "Client isolation") means this carries no grouping meaning across
# clients, it is purely "when this run happened".
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

TOTAL=0
FAILED=0

# Same enumeration lib.sh's repo_projid_next already uses for "every client
# directory that exists on disk": HOST_REPO_BASE/<group>/<client>, two
# levels deep. Deliberately not clients.conf -- see the file header.
for CLIENT_DIR in "${HOST_REPO_BASE}"/*/*; do
    [ -d "$CLIENT_DIR" ] || continue

    USERNAME="$(basename "$CLIENT_DIR")"
    GROUP="$(basename "$(dirname "$CLIENT_DIR")")"
    TOTAL=$((TOTAL + 1))

    case "$USERNAME" in
        *[!a-zA-Z0-9_-]*)
            echo "ERROR: skipping '$CLIENT_DIR' -- name contains characters"
            echo "       outside a-z, 0-9, _, - and cannot be trusted as a"
            echo "       path component under SNAPSHOT_BASE."
            FAILED=$((FAILED + 1))
            continue
            ;;
    esac

    CLIENT_SNAP_DIR="${SNAPSHOT_BASE}/${USERNAME}"
    STAGING="${CLIENT_SNAP_DIR}/.creating-${TIMESTAMP}"
    FINAL="${CLIENT_SNAP_DIR}/${TIMESTAMP}"

    echo "[snapshot] ${USERNAME} (${GROUP}): starting"

    mkdir -p "$CLIENT_SNAP_DIR"

    # A .creating-* left behind by a run that never reached the mv below
    # (crash, kill, disk full mid-copy). It was never renamed to a real
    # <timestamp>/, so nothing could have listed or relied on it yet, and it
    # is still plain-owned/mutable (chattr only ever runs after the rename)
    # -- safe for the operator to remove without sudo.
    for STALE in "${CLIENT_SNAP_DIR}"/.creating-*; do
        [ -e "$STALE" ] || continue
        echo "[snapshot] ${USERNAME}: removing stale incomplete snapshot from a previous run: $STALE"
        rm -rf "$STALE"
    done

    if [ -e "$FINAL" ]; then
        echo "ERROR: ${USERNAME}: '$FINAL' already exists (duplicate timestamp"
        echo "       within the same second?). Skipping this client this run."
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! sudo cp -a --reflink=always "$CLIENT_DIR" "$STAGING"; then
        echo "ERROR: ${USERNAME}: reflink copy failed. Leaving '$STAGING' in"
        echo "       place for inspection; it is not a valid snapshot and"
        echo "       will be removed automatically on the next run."
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! mv "$STAGING" "$FINAL"; then
        echo "ERROR: ${USERNAME}: could not rename '$STAGING' to '$FINAL'."
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! sudo chattr -R +i "$FINAL"; then
        echo "ERROR: ${USERNAME}: '$FINAL' was created but chattr +i failed."
        echo "       It holds a real copy of this client's data but is NOT"
        echo "       protected against deletion. Needs manual attention."
        FAILED=$((FAILED + 1))
        continue
    fi

    # Trust but verify, the way quota_verify reads the limit back rather than
    # the exit status of the command that set it: confirm the flag actually
    # reached the directory rather than assuming a zero exit means it did.
    FINAL_ATTRS="$(lsattr -d "$FINAL" 2>/dev/null | awk '{print $1}')"
    case "$FINAL_ATTRS" in
        *i*) ;;
        *)
            echo "ERROR: ${USERNAME}: chattr reported success but '$FINAL' is"
            echo "       NOT showing the immutable flag on read-back"
            echo "       (lsattr: '${FINAL_ATTRS:-unreadable}'). Needs manual"
            echo "       attention -- this snapshot is not protected."
            FAILED=$((FAILED + 1))
            continue
            ;;
    esac

    echo "[snapshot] ${USERNAME}: done -> $FINAL"
done

echo ""
if [ "$TOTAL" -eq 0 ]; then
    echo "[snapshot] No clients found under $HOST_REPO_BASE. Nothing to do."
    exit 0
fi

OK=$((TOTAL - FAILED))
echo "[snapshot] $OK/$TOTAL client(s) snapshotted successfully."
if [ "$FAILED" -gt 0 ]; then
    echo "[snapshot] $FAILED client(s) FAILED -- see ERROR lines above."
    exit 1
fi
exit 0
