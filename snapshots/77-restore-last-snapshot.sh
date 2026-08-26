#!/bin/sh
#
# 77-restore-last-snapshot.sh
# -----------------------------
# Restores one client's repository from that client's most recent snapshot
# generation under SNAPSHOT_BASE (ROADMAP.md 11.5). Deliberately restores
# ONLY the newest generation, not an arbitrary one: the intended workflow is
#
#   75-list-snapshots.sh   -- find the anomaly (append-only means a size
#                              jump on an existing generation is never
#                              legitimate; ROADMAP.md 11.5, "Snapshot
#                              comparison")
#   76-delete-snapshots.sh -- remove every generation that covers the
#                              compromise window
#   77-restore-last-snapshot.sh  -- whatever generation is left as "last"
#                              after that IS the most recent known-good one,
#                              by construction. No timestamp argument is
#                              needed or accepted; picking one by hand here
#                              would just be re-deriving what 76- already
#                              established.
#
# Usage:
#   ./snapshots/77-restore-last-snapshot.sh <client>
#
# What this does, in order:
#
#   1. Finds this client's newest snapshot generation and this client's
#      current live repository directory (by scanning HOST_REPO_BASE, the
#      same client-discovery approach 70-create-snapshot.sh uses, rather
#      than trusting clients.conf).
#   2. Shows both: the snapshot generation's timestamp and size (`du -sh`,
#      same as 75-list-snapshots.sh), and the live repository's path.
#   3. Asks for confirmation. Same exact-uppercase-Y rule as
#      76-delete-snapshots.sh, for the same reason: this is irreversible.
#   4. Only then: DELETES the current live repository outright (not
#      quarantined -- ROADMAP.md 11.5 already gives a compromised client's
#      tainted history nowhere safe to sit once 76- has removed the
#      snapshots that covered it; keeping the live copy around serves no
#      purpose 76-'s own quarantine-free deletion did not already reject
#      for the same class of data), then recreates the directory and
#      restores the snapshot's content into it.
#
# What is restored, and what is not (ROADMAP.md 11.5, "What restoring
# HOST_REPO_BASE alone does not restore"): the repository's file content,
# its host ownership, and its XFS project id (see "QUOTA IDENTITY" below).
# NOT restored: nothing needs to be -- clients.conf and the SSH key are
# untouched by this whole workflow, because the client's repository
# directory never stopped existing. That is also this script's boundary:
# if the directory is gone entirely (an operator rm -rf, or a client
# removed and later wanted back), there is no "current live repository" to
# scan for, and this script refuses rather than attempting the fuller
# from-scratch rebuild 00-ssh-create-user.sh does (new project id, a limit
# read from clients.conf, a clients.conf entry) -- that path still needs
# 04-reattach-client.sh, which does not exist yet.
#
# QUOTA IDENTITY. `cp -a` does not preserve an XFS project id -- it is not a
# file attribute `cp` knows about. Before anything is deleted, this script
# reads the CURRENT project id and its enforced limit off the live
# directory, and re-applies that exact same id afterward (never a freshly
# allocated one, and clients.conf is never consulted for a quota figure):
# the id already carries its original limit in the kernel, so re-applying
# it is sufficient to make the restored directory exactly as protected as
# it was before, and the limit is verified read back before any content is
# copied in.
#
# WHY THIS SOURCES scripts/lib.sh. Re-applying ownership and a project id
# needs exactly the repo_* helpers 00-ssh-create-user.sh already uses
# (podman unshare for ownership, sudo xfs_quota for the project id) --
# the same "confined, per-call sudo" privilege class scripts/ has always
# used, NOT the pervasive chattr root that made snapshots/ a separate
# top-level directory from scripts/ in the first place (ROADMAP.md 11.5,
# "where this code lives"). Reusing the existing, already-tested
# implementation was chosen over a second copy of the same xfs_quota
# mechanics living in snapshots/ and risking drift from it.
#
# PRIVILEGES. `sudo` for the same class of commands 70-/76- already use --
# `rm -rf` (deleting the live directory: mode 755, mapped-subuid owned, an
# unprivileged rm fails with Permission denied, same finding as 76-'s
# header explains for snapshot deletion) and `cp -a` (CAP_CHOWN, to
# preserve the mapped-subuid ownership already correct on the snapshot's
# files) -- plus, via scripts/lib.sh, `sudo xfs_quota` for the project id
# (same as 00-/02-) and `podman unshare` for the directory's own ownership
# (same as 00-). No `chattr` here at all: live repositories are
# deliberately never made immutable (ROADMAP.md 11.5, "Mechanism").
#
# LOCKING. Holds the same SNAPSHOT_BASE/.lock 70-/76- use, for the whole
# run -- a snapshot creation running mid-restore could otherwise capture
# this client in its torn, briefly-empty state.
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

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
    echo "ERROR: missing <client> argument."
    echo "Usage: $0 <client>"
    exit 1
fi
CLIENT="$1"

case "$CLIENT" in
    *[!a-zA-Z0-9_-]*)
        echo "ERROR: '$CLIENT' contains characters outside a-z, 0-9, _, - and"
        echo "       cannot be trusted as a path component."
        exit 1
        ;;
esac

if [ ! -f "${REPO_ROOT}/scripts/lib.sh" ]; then
    echo "ERROR: could not find '${REPO_ROOT}/scripts/lib.sh' -- see WHY THIS"
    echo "       SOURCES scripts/lib.sh in this script's own header."
    exit 1
fi
. "${REPO_ROOT}/scripts/lib.sh"

check_timestamp_format() {
    case "$1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) return 0 ;;
        *) return 1 ;;
    esac
}

SNAP_CLIENT_DIR="${SNAPSHOT_BASE}/${CLIENT}"
if [ ! -d "$SNAP_CLIENT_DIR" ]; then
    echo "No snapshots found for client '$CLIENT' under $SNAPSHOT_BASE."
    echo "Nothing to restore from."
    exit 1
fi

# Newest generation: same skip rule as 75-/76- (a stale .creating-* or
# SNAPSHOT_BASE's own .lock never matches the timestamp format), sorted
# ascending because the format is fixed-width and zero-padded, last line is
# the newest. Runs in a subshell (command substitution) -- fine, only the
# final value is needed afterwards.
LAST_TS=$(
    for GEN_DIR in "$SNAP_CLIENT_DIR"/*/; do
        [ -d "$GEN_DIR" ] || continue
        TS="$(basename "$GEN_DIR")"
        check_timestamp_format "$TS" || continue
        printf '%s\n' "$TS"
    done | sort | tail -n1
)
if [ -z "$LAST_TS" ]; then
    echo "No snapshot generations found for client '$CLIENT' under $SNAP_CLIENT_DIR."
    echo "Nothing to restore from."
    exit 1
fi
LAST_GEN_DIR="${SNAP_CLIENT_DIR}/${LAST_TS}"

# The client's group: scanned from the filesystem (HOST_REPO_BASE/<group>/
# <client>), the same discovery 70-create-snapshot.sh uses, not read from
# clients.conf. Also the point where "no existing repository" is detected --
# see the header's "boundary" paragraph for why that refuses rather than
# building one from scratch.
GROUP=""
for D in "${HOST_REPO_BASE}"/*/"${CLIENT}"; do
    [ -d "$D" ] || continue
    if [ -n "$GROUP" ]; then
        echo "ERROR: client '$CLIENT' has a repository directory under more than"
        echo "       one group ('$GROUP' and '$(basename "$(dirname "$D")")') --"
        echo "       refusing to guess which one is the real one."
        exit 1
    fi
    GROUP="$(basename "$(dirname "$D")")"
done

if [ -z "$GROUP" ]; then
    echo "ERROR: no existing repository directory found for client '$CLIENT' under"
    echo "       $HOST_REPO_BASE."
    echo "This script restores an existing client's repository in place -- it does"
    echo "NOT (yet) recreate one that no longer exists at all. If this client's"
    echo "directory is genuinely gone, that needs 00-ssh-create-user.sh or"
    echo "03-provision-client.sh first (and, to reconnect clients.conf, the"
    echo "still-unbuilt 04-reattach-client.sh -- see ROADMAP.md 11.5)."
    exit 1
fi
HOST_REPO="${HOST_REPO_BASE}/${GROUP}/${CLIENT}"

# ---------------------------------------------------------------------------
# Lock before anything is shown, for the same reason 76- does: nothing else
# in this tooling may add or remove a generation, or race this restore,
# between the display below and the destructive steps later.
# ---------------------------------------------------------------------------
LOCK_FILE="${SNAPSHOT_BASE}/.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another snapshot run (create, delete or restore) is already"
    echo "       in progress (lock held: $LOCK_FILE). Nothing was done."
    exit 1
fi

SIZE="$(du -sh "$LAST_GEN_DIR" 2>/dev/null | cut -f1)"
[ -n "$SIZE" ] || SIZE="n/a (unreadable)"

echo "Most recent snapshot for client '$CLIENT':"
printf '%-20s %s\n' "$LAST_TS" "$SIZE"
echo ""
echo "Current live repository: $HOST_REPO"
echo ""
echo "!!! This will PERMANENTLY DELETE the current repository above and replace"
echo "!!! it with the snapshot shown above ('$LAST_TS'). This cannot be undone."
printf 'Type Y (exactly, uppercase) to proceed, anything else aborts: '
IFS= read -r ANSWER || ANSWER=""
case "$ANSWER" in
    Y) ;;
    *)
        echo "Aborted — nothing was restored."
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Quota identity, read BEFORE anything is deleted -- see QUOTA IDENTITY
# above. Refusing here (rather than deleting first and finding out the id
# cannot be read) leaves the live repository completely untouched on
# failure.
# ---------------------------------------------------------------------------
repo_ns_uid_ok "$HOST_REPO_BASE" || exit 1

XFS_MOUNT=$(repo_xfs_mount "$HOST_REPO")
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'. Nothing was done."
    exit 1
fi
repo_quota_enforcing "$XFS_MOUNT" || exit 1

OLD_PROJID=$(repo_projid "$HOST_REPO") || {
    echo "ERROR: could not read the XFS project id currently on '$HOST_REPO'."
    echo "       Refusing to proceed without it -- restoring without re-applying"
    echo "       the same id would silently drop this client's quota enforcement."
    exit 1
}
OLD_ENFORCED_KIB=$(quota_enforced_kib "$HOST_REPO")
case "$OLD_ENFORCED_KIB" in
    ''|*[!0-9]*)
        echo "ERROR: could not read the enforced quota currently on '$HOST_REPO'."
        echo "       Nothing was done."
        exit 1
        ;;
esac

echo "[restore] Deleting current repository: $HOST_REPO"
if ! sudo rm -rf "$HOST_REPO"; then
    echo "ERROR: could not delete '$HOST_REPO'. Left as-is; nothing was restored."
    exit 1
fi

repo_dir_create "$HOST_REPO"

echo "[restore] Re-applying XFS project id $OLD_PROJID"
repo_projid_assign "$XFS_MOUNT" "$HOST_REPO" "$OLD_PROJID"

NEW_ENFORCED_KIB="$(quota_enforced_kib "$HOST_REPO")"
case "$NEW_ENFORCED_KIB" in
    ''|*[!0-9]*) NEW_ENFORCED_KIB="" ;;
esac
if [ "$NEW_ENFORCED_KIB" != "$OLD_ENFORCED_KIB" ]; then
    echo "ERROR: after re-applying project id $OLD_PROJID, the enforced quota on"
    echo "       '$HOST_REPO' is '${NEW_ENFORCED_KIB:-unreadable}', not the original"
    echo "       $(quota_human "$OLD_ENFORCED_KIB"). The directory exists but is NOT"
    echo "       correctly quota-protected -- needs manual attention before this"
    echo "       client is used again."
    exit 1
fi
echo "[restore] Verified: quota identity matches what this client had before ($(quota_human "$NEW_ENFORCED_KIB"))."

echo "[restore] Copying snapshot content into place"
if ! sudo cp -a --reflink=always "${LAST_GEN_DIR}"/. "$HOST_REPO"/.; then
    echo "ERROR: copying snapshot content into '$HOST_REPO' failed partway through."
    echo "       The directory exists with correct ownership and quota identity,"
    echo "       but its CONTENT may be incomplete -- needs manual attention"
    echo "       before this client is used again."
    exit 1
fi

echo ""
echo "[restore] Done. '$HOST_REPO' now holds the '$LAST_TS' snapshot for client '$CLIENT'."
exit 0
