#!/bin/sh
#
# 03-provision-client.sh
# -------------------
# Provision the filesystem side of one already-declared client: the repository
# directory, its container-side ownership, its XFS project id and its hard
# limit. Everything 00-ssh-create-user.sh does for a new client, for a client
# clients.conf already holds.
#
# It is deliberately not called a repair. It restores a client's *access* by
# creating what is missing; it restores nothing that was inside the directory,
# it does not change a limit that is merely wrong, and it does not correct a
# group directory it did not create. A name promising more than that would be
# read as a promise in exactly the situation where the reader is in a hurry.
#
# WHY THIS EXISTS. A client has two halves, and they are applied by different
# mechanisms. The SSH half — clients.conf plus config/keys/*.pub — is rendered
# by build_authorized_keys.sh at every container start, so it repairs itself:
# put a key file back, restart, and the client is authorized again. The
# filesystem half was applied inline by 00-ssh-create-user.sh and nowhere else,
# so there was no way to reapply it. A repository directory deleted by hand left
# a client that was refused by the server and by both scripts that might have
# fixed it: 02-change-user-quota.sh refuses a directory it cannot find, and 00
# refuses a name clients.conf already holds. 02's own error message told the
# operator to "assign one manually first" — a step no script performed.
# This is that step (issues #29, #30).
#
# WHAT IT MAY DO. It writes to the filesystem and never to clients.conf.
# clients.conf is the declaration; this script makes the filesystem agree with
# it. Where the two disagree in the other direction — a directory and project id
# that exist but carry a different limit — that is drift, not damage, and
# 02-change-user-quota.sh is the script for it. This one refuses and says so.
#
# It adds what is missing and changes nothing else. A group directory that
# exists with the wrong ownership is reported rather than corrected: it was not
# created here, and since neither borg-wrapper.sh nor build_authorized_keys.sh
# creates repository directories any more, an odd one is inert rather than
# dangerous.
#
# WHAT IT CANNOT BRING BACK. Archives. If the repository directory is gone, so
# is everything the client stored in it; recreating the directory only lets the
# client connect and `borg init` again. This is stated before the confirmation,
# because it is the one consequence an operator must not discover afterwards.
#
# Usage:
#   ./scripts/03-provision-client.sh <username>
#
# Safe to re-run: a client whose filesystem state is already correct is
# reported as such and nothing is written.
#
# The confirmation is read from stdin, so an unattended caller answers it the
# way tests and scripted runs do: `printf 'y\n' | 03-provision-client.sh ...`.
#
# Run as **the same user that runs the container**, and not as root: the
# directory is created inside that user's container namespace via
# `podman unshare`, and only the individual xfs_quota calls are elevated with
# sudo. Must run on the HOST, not inside the container — see OPERATIONS.md
# chapter 9.12.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

USERNAME="$1"

if [ -z "${HOST_REPO_BASE:-}" ]; then
    echo "ERROR: HOST_REPO_BASE is not set in config.sh."
    exit 1
fi

HOST_REPO_BASE="${HOST_REPO_BASE%/}"

case "$HOST_REPO_BASE" in
    /*) ;;
    *) echo "ERROR: HOST_REPO_BASE ('$HOST_REPO_BASE') must be an absolute path."; exit 1 ;;
esac

if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "ERROR: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist or is not a directory."
    echo "Check that the intended storage volume is mounted."
    exit 1
fi

case "$USERNAME" in
    *[!a-zA-Z0-9_-]*)
        echo "ERROR: Invalid username '$USERNAME' (only a-z, 0-9, _, - allowed)"
        exit 1
        ;;
esac

# The declaration. Everything this script does is derived from it, and it is
# never written back to.
ENTRY=$(grep "^${USERNAME}:" "$CONF" 2>/dev/null) || {
    echo "ERROR: user '$USERNAME' does not exist in clients.conf."
    echo "This script provisions a client that is already declared. To create one,"
    echo "use ./scripts/00-ssh-create-user.sh <username> <group> <quota>."
    exit 1
}
GROUP=$(echo "$ENTRY" | cut -d: -f2)
QUOTA=$(echo "$ENTRY" | cut -d: -f4)

if [ "$GROUP" != "OWN" ] && [ "$GROUP" != "MIRROR" ]; then
    echo "ERROR: clients.conf entry for '$USERNAME' has invalid group '$GROUP'."
    echo "Expected OWN or MIRROR — needs manual review."
    exit 1
fi

case "$QUOTA" in
    *[!0-9G]*|""|*[!G])
        echo "ERROR: clients.conf records an unusable quota '$QUOTA' for '$USERNAME'."
        echo "Expected <number>G — needs manual review."
        exit 1
        ;;
esac

HOST_REPO="${HOST_REPO_BASE}/${GROUP}/${USERNAME}"

VOLUME_KIB=$(volume_kib)
case "$VOLUME_KIB" in
    ''|*[!0-9]*|0)
        echo "ERROR: could not read the size of the volume at '$HOST_REPO_BASE'."
        exit 1
        ;;
esac

WANT_KIB=$(quota_kib "$QUOTA") || {
    echo "ERROR: clients.conf records an unusable quota '$QUOTA' for '$USERNAME'."
    exit 1
}

# The recorded value is checked against the volume before it is applied, for the
# same reason 00 and 02 check the value an operator types: a limit at or above
# the volume is reported back through statvfs() as the whole volume and is
# indistinguishable from no limit at all. A clients.conf that grew such a value
# by hand must not be made real here.
quota_reject_oversized "$QUOTA" "$WANT_KIB" "$VOLUME_KIB" || {
    echo "       clients.conf records this value for '$USERNAME'. Correct it there"
    echo "       first — nothing was changed."
    exit 1
}

# ---------------------------------------------------------------------------
# Diagnose before touching anything
# ---------------------------------------------------------------------------
#
# Three states can be provisioned here, and they are cumulative: a missing directory
# needs all three steps, a directory without a project id needs two, and a
# project id whose limit was never applied needs one. Everything else is either
# healthy or somebody else's job.
NEED_DIR=""
NEED_PROJID=""
PROJID=""

if [ ! -d "$HOST_REPO" ]; then
    NEED_DIR=1
    NEED_PROJID=1
else
    PROJID=$(repo_projid "$HOST_REPO") || NEED_PROJID=1
fi

echo "[provision] Client:      $USERNAME ($GROUP)"
echo "[provision] Directory:   $HOST_REPO"
if [ -n "$NEED_DIR" ]; then
    echo "[provision] State:       MISSING on host — the directory does not exist"
elif [ -n "$NEED_PROJID" ]; then
    echo "[provision] State:       no XFS project id — no quota applies to this client"
else
    echo "[provision] State:       directory and project id $PROJID are in place"
fi
echo "[provision] clients.conf: $QUOTA"

# The group directory, reported rather than corrected. 00-ssh-create-user.sh
# creates it as a side effect of `podman unshare mkdir -p` and leaves it owned
# by namespace root; a copy owned by 'borg' is the fingerprint of a release in
# which borg-wrapper.sh still created directories it could not finish. It is
# inert now — nothing in the container creates directories any more — but it is
# worth seeing.
GROUP_DIR="${HOST_REPO_BASE}/${GROUP}"
if [ -d "$GROUP_DIR" ]; then
    GROUP_NS_UID="$(podman unshare stat -c %u "$GROUP_DIR" 2>/dev/null || true)"
    if [ -n "$GROUP_NS_UID" ] && [ "$GROUP_NS_UID" != "0" ]; then
        echo "[provision] NOTE: the group directory '$GROUP_DIR' belongs to uid"
        echo "         $GROUP_NS_UID inside the container namespace rather than to root."
        echo "         Left as it is: this script adds what is missing and changes"
        echo "         nothing else. See OPERATIONS.md chapter 9.12."
    fi
fi

# Nothing to do is a result, not a failure. Whether the recorded limit is the
# one in force is 02's question, and it is asked here only to say which script
# the operator wants.
if [ -z "$NEED_DIR" ] && [ -z "$NEED_PROJID" ]; then
    HAVE_KIB=$(quota_enforced_kib "$HOST_REPO")
    if [ "$HAVE_KIB" = "$WANT_KIB" ]; then
        echo "[provision] Nothing to do — the filesystem already matches clients.conf."
        exit 0
    fi
    echo ""
    echo "[provision] Nothing missing here: the directory and its project id are"
    echo "         both in place, so this is a quota that differs rather than one"
    echo "         that is absent. Changing it is what 02-change-user-quota.sh is for:"
    echo ""
    echo "             ./scripts/02-change-user-quota.sh $USERNAME $QUOTA"
    echo ""
    echo "         It shows both figures and the resulting sum before applying"
    echo "         anything (OPERATIONS.md chapter 9.4)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Preconditions for writing
# ---------------------------------------------------------------------------

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found. This script creates the client's repository"
    echo "directory inside the container's user namespace (podman unshare), which"
    echo "is what makes it writable by the container's 'borg' user."
    exit 1
fi

repo_ns_uid_ok "$HOST_REPO_BASE" || exit 1

# Resolved against the base rather than against the repository directory, which
# may not exist yet. Both are on the same volume by construction.
XFS_MOUNT=$(repo_xfs_mount "$HOST_REPO_BASE")
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO_BASE'."
    exit 1
fi

repo_quota_enforcing "$XFS_MOUNT" || exit 1

# ---------------------------------------------------------------------------
# What this would do, then ask
# ---------------------------------------------------------------------------

echo ""
echo "[provision] This would:"
[ -n "$NEED_DIR" ] && echo "         - create $HOST_REPO, owned by ${BORG_UID}:${BORG_GID} in the container namespace"
[ -n "$NEED_PROJID" ] && echo "         - assign it a new XFS project id"
echo "         - apply the hard limit $QUOTA recorded in clients.conf"
echo "         - and write nothing to clients.conf"

if [ -n "$NEED_DIR" ]; then
    echo ""
    echo "         The archives that were in this directory are NOT coming back."
    echo "         A recreated directory is empty: the client can connect and run"
    echo "         'borg init' again, and everything it had stored is gone with the"
    echo "         directory. If that is not what you expect, stop here and find out"
    echo "         where the directory went first."
fi

echo ""
quota_preview "$VOLUME_KIB" "$USERNAME" "" "" "$WANT_KIB" "$QUOTA" 0

if ! quota_confirm "Provision client '$USERNAME' now?"; then
    echo "Aborted — nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
#
# Every step goes through the repo_* helpers in config.sh's lib.sh, the same
# ones 00-ssh-create-user.sh writes with — this script is a different order over
# the same operations, not a second implementation of them.
#
# The rollback is narrower than 00's on purpose. 00 created everything it
# touched and can therefore remove everything; here the directory may have
# existed before this run, and removing it would destroy data this script was
# called to protect. Only what this run created is undone.

if [ -n "$NEED_DIR" ]; then
    repo_dir_create "$HOST_REPO"
fi

if [ -n "$NEED_PROJID" ]; then
    PROJID=$(repo_projid_next "$HOST_REPO") || {
        [ -n "$NEED_DIR" ] && repo_dir_remove "$HOST_REPO"
        exit 1
    }
    echo "[provision] Assigning XFS project id $PROJID to $HOST_REPO"
    repo_projid_assign "$XFS_MOUNT" "$HOST_REPO" "$PROJID"
fi

echo "[provision] Setting hard quota: $QUOTA"
repo_limit_apply "$XFS_MOUNT" "$PROJID" "$QUOTA"

if ! quota_verify "$HOST_REPO" "$QUOTA"; then
    echo "ERROR: aborting — the limit is not in effect."
    if [ -n "$NEED_PROJID" ]; then
        # The id was allocated by this run and is handed out again by the next
        # allocation, so a limit left on it would be inherited by a client
        # nobody chose it for.
        repo_limit_clear "$XFS_MOUNT" "$PROJID" 2>/dev/null || \
            echo "WARNING: the limit set on project id $PROJID could not be cleared."
    fi
    if [ -n "$NEED_DIR" ]; then
        repo_dir_remove "$HOST_REPO"
    else
        echo "WARNING: '$HOST_REPO' existed before this run and was left in place."
        echo "         Check what is enforced on it with ./scripts/09-show-all-users.sh."
    fi
    exit 1
fi

echo "[provision] Client '$USERNAME' provisioned: quota $QUOTA (project id $PROJID, limit verified)."
echo "         clients.conf was not modified."

if [ -n "$NEED_DIR" ]; then
    echo "→ The client's repository is empty. It has to run 'borg init' again"
    echo "  before its next backup (CLIENTUSE.md chapter 3.1)."
fi

echo "→ No container restart is needed: nothing under /config changed."
