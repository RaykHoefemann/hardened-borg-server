#!/bin/sh
#
# 00-ssh-create-user.sh
# ---------------------
# Creates a new Borg client:
#  - Repository directory on the HOST (bind-mounted into the container as
#    CONTAINER_REPO, e.g. /repo/OWN/<user> -> $HOST_REPO_BASE/OWN/<user>)
#  - XFS project quota assigned to that directory and set to the given quota
#    (see README Chapter 1.1.3 / BEST_PRACTICES.md Chapter 1 — enforcing
#    prjquota is a mandatory host requirement; this script requires it)
#  - Entry in config/clients.conf
#  - Empty public key file in config/keys/
#
# Usage:
#   ./scripts/00-ssh-create-user.sh <username> <group> <quota>
#
# Groups:
#   OWN     internal users from own network
#   MIRROR  external users (e.g. friends)
#
# Quota:
#   Format: <number>G (e.g. 10G, 50G, 200G)
#
# Run as the normal operator user, NOT as root: only the individual
# xfs_quota calls that need CAP_SYS_ADMIN are elevated internally via sudo
# (you'll be prompted for your password there). Must run on the HOST, not
# inside the container.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ $# -ne 3 ]; then
    echo "Usage: $0 <username> <group> <quota>"
    echo "Group: OWN | MIRROR"
    echo "Quota format: <number>G (e.g. 50G)"
    exit 1
fi

USERNAME="$1"
GROUP="$2"
QUOTA="$3"

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

mkdir -p "$(dirname "$CONF")"
touch "$CONF"

case "$USERNAME" in
    *[!a-zA-Z0-9_-]*) echo "ERROR: Invalid username '$USERNAME' (only a-z, 0-9, _, - allowed)"; exit 1 ;;
esac

# validate group
if [ "$GROUP" != "OWN" ] && [ "$GROUP" != "MIRROR" ]; then
    echo "ERROR: unknown group '$GROUP'"
    echo "required: OWN | MIRROR"
    exit 1
fi

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
REPO_SUBPATH="${GROUP}/${USERNAME}"
CONTAINER_REPO="${CONTAINER_REPO_BASE}/${REPO_SUBPATH}"
HOST_REPO="${HOST_REPO_BASE}/${REPO_SUBPATH}"

# check if user exists
if grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: User '$USERNAME' already exists in clients.conf! Aborted."
    exit 1
fi

if [ -e "$HOST_REPO" ]; then
    echo "ERROR: '$HOST_REPO' already exists on the host. Aborted."
    exit 1
fi

echo "[create] Creating repository directory: $HOST_REPO"
mkdir -p "$HOST_REPO"

# Resolve the XFS mount that actually holds the repo (must be enforcing prjquota).
XFS_MOUNT=$(df -P "$HOST_REPO" | awk 'NR==2 {print $6}')
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'."
    rmdir "$HOST_REPO" 2>/dev/null
    exit 1
fi

# Verify the mount is enforcing project quotas before we rely on it.
if ! sudo xfs_quota -x -c 'state -p' "$XFS_MOUNT" 2>/dev/null | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
    echo "ERROR: '$XFS_MOUNT' does not have enforcing XFS project quotas (prjquota)."
    echo "This is a mandatory host requirement (see BEST_PRACTICES.md Chapter 1)."
    rmdir "$HOST_REPO" 2>/dev/null
    exit 1
fi

# Allocate the next free project id: scan existing repo dirs under
# HOST_REPO_BASE for their current projid (via lsattr -p) and take max+1,
# starting from PROJID_BASE. This needs no separate id registry/database.
PROJID=$((${PROJID_BASE:-1000} - 1))
for d in "$HOST_REPO_BASE"/*/*; do
    [ -d "$d" ] || continue
    pid=$(lsattr -p -d "$d" 2>/dev/null | awk '{print $1}')
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" -gt "$PROJID" ] && PROJID="$pid"
done
PROJID=$((PROJID + 1))

echo "[create] Assigning XFS project id $PROJID to $HOST_REPO"
sudo xfs_quota -x -c "project -s -p $HOST_REPO $PROJID" "$XFS_MOUNT" >/dev/null

echo "[create] Setting hard quota: $QUOTA"
sudo xfs_quota -x -c "limit -p bhard=${QUOTA} ${PROJID}" "$XFS_MOUNT"

echo "[create] Create entry in clients.conf"
echo "${USERNAME}:${GROUP}:${CONTAINER_REPO}:${QUOTA}" >> "$CONF"

echo "[create] Create empty public key file"
mkdir -p "$KEYDIR"
touch "${KEYDIR}/${USERNAME}.pub"

echo "[create] User '$USERNAME' created with quota $QUOTA (project id $PROJID)."
echo "→ Set now the public key!"
echo "NOTE: verify '$HOST_REPO' is writable by the container's 'borg' user"
echo "      (rootless Podman UID mapping) before the client's first connection."
