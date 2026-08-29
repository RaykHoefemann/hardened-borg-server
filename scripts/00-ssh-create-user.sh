#!/bin/sh
#
# 00-ssh-create-user.sh
# ---------------------
# Creates a new Borg client:
#  - Repository directory on the HOST (bind-mounted into the container as
#    CONTAINER_REPO, e.g. /repo/<user> -> $HOST_REPO_BASE/<user>)
#  - XFS project quota assigned to that directory and set to the given quota
#    (see README Chapter 1.1.3 / BEST_PRACTICES.md Chapter 1 — enforcing
#    prjquota is a mandatory host requirement; this script requires it).
#    The limit is then read back from the directory and shown; the client is
#    only recorded in clients.conf once it is confirmed to be in effect.
#  - Entry in config/clients.conf
#  - Empty public key file in config/keys/
#
# Usage:
#   ./scripts/00-ssh-create-user.sh <username> <quota>
#
# There is no group argument. Separating trust levels (your own devices vs.
# external partners) is done by running a second instance of this project,
# which is a real isolation boundary — see docs/DESIGN.md 1.2.3. The OWN/MIRROR
# group that used to sit here was organisational only and was removed in 1.0.0.
#
# Quota:
#   Format: <number>G (e.g. 10G, 50G, 200G)
#
#   Stated as a share of the volume, together with the resulting sum across
#   all clients, and confirmed before anything is created — this is where the
#   number is chosen for the first time, with nothing to compare it against.
#   A quota above 99% of the volume is refused: it cannot be enforced, and the
#   client would be told it may use the whole disk. The confirmation is read
#   from stdin, so a scripted run answers it with
#   `printf 'y\n' | 00-ssh-create-user.sh ...`.
#
# Run as the normal operator user, NOT as root, and as the SAME user that runs
# the container: only the individual xfs_quota calls that need CAP_SYS_ADMIN
# are elevated internally via sudo (you'll be prompted for your password
# there), while the repository directory is created and handed to the
# container's 'borg' user through `podman unshare`, which resolves the uid
# mapping of that user's rootless podman. Must run on the HOST, not inside the
# container.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <quota>"
    echo "Quota format: <number>G (e.g. 50G)"
    exit 1
fi

USERNAME="$1"
QUOTA="$2"

if [ -z "${HOST_REPO_BASE:-}" ]; then
    echo "ERROR: HOST_REPO_BASE is not set in config.sh."
    echo "It must point at the host path bind-mounted into the container as /repo."
    exit 1
fi
if [ -z "${CONTAINER_REPO_BASE:-}" ]; then
    echo "ERROR: CONTAINER_REPO_BASE is not set in config.sh."
    exit 1
fi

# Normalize base paths: strip any trailing slash so path construction below is
# unambiguous regardless of how the operator wrote config.sh ("/x" or "/x/").
HOST_REPO_BASE="${HOST_REPO_BASE%/}"
CONTAINER_REPO_BASE="${CONTAINER_REPO_BASE%/}"

# Both must be absolute paths.
case "$HOST_REPO_BASE" in
    /*) ;;
    *) echo "ERROR: HOST_REPO_BASE ('$HOST_REPO_BASE') must be an absolute path."; exit 1 ;;
esac
case "$CONTAINER_REPO_BASE" in
    /*) ;;
    *) echo "ERROR: CONTAINER_REPO_BASE ('$CONTAINER_REPO_BASE') must be an absolute path."; exit 1 ;;
esac

# HOST_REPO_BASE must already exist as a directory. We deliberately do NOT
# mkdir -p it ourselves: if the intended external volume is not mounted, its
# mountpoint typically still exists as an empty directory on the ROOT
# filesystem. Silently creating missing parents there would write client data
# onto the wrong disk before any quota check ever runs. Failing here forces
# the operator to confirm the mount is actually present.
if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "ERROR: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist or is not a directory."
    echo "Check that the intended storage volume is mounted before creating clients."
    exit 1
fi

# Verify HOST_REPO_BASE itself sits on an XFS filesystem with ENFORCING
# project quotas, before creating anything. This catches the dangerous case
# where an external volume's mountpoint directory exists (e.g. left over from
# a previous mount) but the volume itself is currently not mounted there —
# in that case HOST_REPO_BASE would silently resolve to the root filesystem.
BASE_MOUNT=$(df -P "$HOST_REPO_BASE" | awk 'NR==2 {print $6}')
if [ -z "$BASE_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO_BASE'."
    exit 1
fi
if ! sudo xfs_quota -x -c 'state -p' "$BASE_MOUNT" 2>/dev/null | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
    echo "ERROR: '$HOST_REPO_BASE' resolves to mount '$BASE_MOUNT', which does not"
    echo "have enforcing XFS project quotas (prjquota). This usually means either:"
    echo "  - the intended storage volume is not mounted (HOST_REPO_BASE is"
    echo "    pointing at an empty leftover directory on a different filesystem), or"
    echo "  - prjquota enforcement was never enabled on that volume."
    echo "This is a mandatory host requirement (see BEST_PRACTICES.md Chapter 1)."
    exit 1
fi

# Everything this script writes under HOST_REPO_BASE goes through
# `podman unshare`, and that is not optional — see the block at the directory
# creation below. Check for it here, before anything has been created, rather
# than failing halfway through with a bare "command not found".
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found. This script creates the client's repository"
    echo "directory inside the container's user namespace (podman unshare), which"
    echo "is what makes it writable by the container's 'borg' user."
    exit 1
fi

# Whose user namespace is this, and does it match the container's? Asked before
# anything is created, because the wrong answer produces a directory the
# container cannot use and the failure would otherwise surface much later, as a
# client whose backups cannot be written (repo_ns_uid_ok in config.sh).
repo_ns_uid_ok "$HOST_REPO_BASE" || exit 1

mkdir -p "$(dirname "$CONF")"
touch "$CONF"

case "$USERNAME" in
    ''|-*|*[!a-zA-Z0-9_-]*) echo "ERROR: Invalid username '$USERNAME' (must be non-empty, must not start with '-', only a-z, 0-9, _, - allowed)"; exit 1 ;;
esac

# validate quota (mandatory, format: <digits>G, e.g. 50G)
case "$QUOTA" in
    *[!0-9G]*|"")
        echo "ERROR: invalid quota format '$QUOTA' (expected: <number>G, e.g. 50G)"
        exit 1
        ;;
esac
case "$QUOTA" in
    *G) ;;
    *)
        echo "ERROR: invalid quota format '$QUOTA' (expected: <number>G, e.g. 50G)"
        exit 1
        ;;
esac
NUMPART=${QUOTA%G}
case "$NUMPART" in
    ''|0) echo "ERROR: quota must be greater than 0 (got '$QUOTA')"; exit 1 ;;
esac

# autogenerate repo paths (container view + host view)
CONTAINER_REPO="${CONTAINER_REPO_BASE}/${USERNAME}"
HOST_REPO="${HOST_REPO_BASE}/${USERNAME}"

# check if user exists
if grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: User '$USERNAME' already exists in clients.conf! Aborted."
    exit 1
fi

if [ -e "$HOST_REPO" ]; then
    echo "ERROR: '$HOST_REPO' already exists on the host. Aborted."
    exit 1
fi

# What the requested quota means relative to the volume — stated before
# anything is created, and refused outright above 99%, where a limit stops
# being enforceable at all. This is the more likely place to hand out an
# oversized quota than 02: it is where the number is chosen for the first time,
# with nothing to compare it against.
VOLUME_KIB=$(volume_kib)
case "$VOLUME_KIB" in
    ''|*[!0-9]*|0)
        echo "ERROR: could not read the size of the volume at '$HOST_REPO_BASE'."
        exit 1
        ;;
esac

WANT_KIB=$(quota_kib "$QUOTA") || {
    echo "ERROR: quota '$QUOTA' is not a usable value."
    exit 1
}
quota_reject_oversized "$QUOTA" "$WANT_KIB" "$VOLUME_KIB" || {
    echo "       Nothing was created."
    exit 1
}

echo ""
quota_preview "$VOLUME_KIB" "$USERNAME" "" "" "$WANT_KIB" "$QUOTA" 0

if ! quota_confirm "Create client '$USERNAME' with this quota?"; then
    echo "Aborted — nothing was created."
    exit 0
fi

# From here on the filesystem is written, and every step of it goes through the
# repo_* helpers in config.sh — the same ones 02-change-user-quota.sh uses, so
# a client's directory, its project id and its limit are produced in exactly
# one place. Each failure below undoes what this run created before exiting:
# nothing is in clients.conf yet, so an abort has to leave no directory and no
# limit behind either.
repo_dir_create "$HOST_REPO"

XFS_MOUNT=$(repo_xfs_mount "$HOST_REPO")
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'."
    repo_dir_remove "$HOST_REPO"
    exit 1
fi

if ! repo_quota_enforcing "$XFS_MOUNT"; then
    repo_dir_remove "$HOST_REPO"
    exit 1
fi

# The directory created moments ago is skipped by the scan: it has no id of its
# own yet and inherits the parent's, which says nothing about what is in use.
PROJID=$(repo_projid_next "$HOST_REPO") || {
    repo_dir_remove "$HOST_REPO"
    exit 1
}

echo "[create] Assigning XFS project id $PROJID to $HOST_REPO"
repo_projid_assign "$XFS_MOUNT" "$HOST_REPO" "$PROJID"

echo "[create] Setting hard quota: $QUOTA"
repo_limit_apply "$XFS_MOUNT" "$PROJID" "$QUOTA"

# Read the limit back from the directory itself instead of trusting the exit
# status above: xfs_quota reports success for a limit set on a project id that
# never reaches this directory (e.g. the project assignment above did not
# stick), and the client would then be effectively unlimited until the whole
# volume runs full. Verify before the client exists in clients.conf at all.
if ! quota_verify "$HOST_REPO" "$QUOTA"; then
    # The directory goes, and so does the limit that was just set on the
    # project id (repo_limit_clear says why bhard=0 is the right value).
    echo "ERROR: aborting — no client was created."
    repo_limit_clear "$XFS_MOUNT" "$PROJID" 2>/dev/null || \
        echo "WARNING: the limit set on project id $PROJID could not be cleared."
    repo_dir_remove "$HOST_REPO"
    exit 1
fi

echo "[create] Create entry in clients.conf"
echo "${USERNAME}:${CONTAINER_REPO}:${QUOTA}" >> "$CONF"

echo "[create] Create empty public key file"
mkdir -p "$KEYDIR"
touch "${KEYDIR}/${USERNAME}.pub"

echo "[create] User '$USERNAME' created with quota $QUOTA (project id $PROJID, limit verified)."
echo "         Repository directory owned by ${BORG_UID}:${BORG_GID} in the container's"
echo "         user namespace — writable by 'borg', no further action needed."
echo "→ Set now the public key:"
echo "    ./scripts/01-ssh-set-user-key.sh ${USERNAME} <keyfile|keystring>"
echo "  and then activate the client:"
echo "    ./scripts/92-container-restart.sh"
echo "  Both steps are required. authorized_keys is generated at container start,"
echo "  and a client whose key file is still empty is skipped there — restarting"
echo "  before the key is set authorizes nobody."
