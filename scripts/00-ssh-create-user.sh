#!/bin/sh
#
# 00-ssh-create-user.sh
# ---------------------
# Creates a new Borg client:
#  - Repository directory on the HOST (bind-mounted into the container as
#    CONTAINER_REPO, e.g. /repo/OWN/<user> -> $HOST_REPO_BASE/OWN/<user>)
#  - XFS project quota assigned to that directory and set to the given quota
#    (see README Chapter 1.1.3 / BEST_PRACTICES.md Chapter 1 — enforcing
#    prjquota is a mandatory host requirement; this script requires it).
#    The limit is then read back from the directory and shown; the client is
#    only recorded in clients.conf once it is confirmed to be in effect.
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

# Whose user namespace is this, and does it match the container's?
#
# `podman unshare` resolves the mapping of whoever runs it. Run by the wrong
# user it still succeeds — it just creates the directory under a mapping the
# container does not share, and the failure surfaces much later as a client
# whose backups cannot be written. So ask the question directly: inside this
# user's namespace, who owns the repository base?
#
#   BORG_UID  the container has taken ownership of it, i.e. the server has run
#             at least once, and this user's mapping is the container's
#   0         nobody has taken it yet — a fresh installation whose server has
#             not started, where the base is still plainly operator-owned
#
# Anything else means the base belongs to a mapping that is not this user's,
# and the most likely reason is that the container runs as somebody else.
BASE_NS_UID="$(podman unshare stat -c %u "$HOST_REPO_BASE" 2>/dev/null || true)"
case "$BASE_NS_UID" in
    0|"$BORG_UID") ;;
    ''|*[!0-9]*)
        echo "ERROR: could not read '$HOST_REPO_BASE' inside this user's container"
        echo "namespace. Check that rootless podman works for this user"
        echo "(podman info) and that the path is the one bind-mounted as /repo."
        exit 1
        ;;
    *)
        echo "ERROR: inside this user's container namespace, '$HOST_REPO_BASE'"
        echo "belongs to uid $BASE_NS_UID — neither this user (0) nor the"
        echo "container's borg user ($BORG_UID)."
        echo "Run this script as the same user that runs the container."
        exit 1
        ;;
esac

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
quota_preview "$VOLUME_KIB" "$USERNAME" "" "$WANT_KIB" "after this change"

if ! quota_confirm "Create client '$USERNAME' with this quota?"; then
    echo "Aborted — nothing was created."
    exit 0
fi

# Created and owned inside the container's user namespace, not on the host.
#
# entrypoint.sh takes ownership of the bind-mounted repository base at every
# container start (chown borg:borg /repo). Under rootless podman that lands on
# the host as the mapped subuid — container 1111 becomes host 524288+1110 or
# whatever the operator's subuid range makes of it — so from the host side the
# base belongs to a user that does not exist, and a plain mkdir here fails with
# "Permission denied" on every installation that has ever started its server.
#
# `podman unshare` enters exactly that mapping, where this operator is root and
# BORG_UID/BORG_GID mean what they mean inside the container. Creating the
# directory there, and handing it to 'borg' in the same namespace, is what
# config.sh has always documented these two values to be for.
#
# The mode is deliberately left at the default (755, minus umask): the host
# scripts read these directories back — 02 reads the project id with lsattr,
# 09 reads the quota through df — and they run as the operator, who is not the
# owner. A tighter mode would make those reads fail silently.
echo "[create] Creating repository directory: $HOST_REPO"
podman unshare mkdir -p "$HOST_REPO"
echo "[create] Setting container-side ownership: ${BORG_UID}:${BORG_GID}"
podman unshare chown "${BORG_UID}:${BORG_GID}" "$HOST_REPO"

# Resolve the XFS mount that actually holds the repo (must be enforcing prjquota).
XFS_MOUNT=$(df -P "$HOST_REPO" | awk 'NR==2 {print $6}')
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'."
    podman unshare rmdir "$HOST_REPO" 2>/dev/null
    exit 1
fi

# Verify the mount is enforcing project quotas before we rely on it.
if ! sudo xfs_quota -x -c 'state -p' "$XFS_MOUNT" 2>/dev/null | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
    echo "ERROR: '$XFS_MOUNT' does not have enforcing XFS project quotas (prjquota)."
    echo "This is a mandatory host requirement (see BEST_PRACTICES.md Chapter 1)."
    podman unshare rmdir "$HOST_REPO" 2>/dev/null
    exit 1
fi

# Allocate the next free project id: scan existing repo dirs under
# HOST_REPO_BASE for their current projid (via lsattr -p) and take max+1,
# starting from PROJID_BASE. This needs no separate id registry/database.
#
# A directory whose id cannot be read is an ERROR, not something to skip: the
# scan would then hand out an id that is already in use, and two clients would
# share one quota — each seeing the other's consumption, neither limited to
# what it was promised. Silence is the wrong answer to "I could not read the
# thing this decision depends on". These directories belong to the container's
# mapped uid, so the operator reads them by mode, not ownership; anything that
# tightens that mode surfaces here rather than in a quota that quietly stops
# separating clients.
PROJID=$((${PROJID_BASE:-1000} - 1))
for d in "$HOST_REPO_BASE"/*/*; do
    [ -d "$d" ] || continue
    # The directory created moments ago has no id of its own yet — it inherits
    # the parent's, which says nothing about what is in use. It is the one
    # entry whose unreadability would mean nothing, so it is not consulted.
    [ "$d" = "$HOST_REPO" ] && continue
    pid=$(lsattr -p -d "$d" 2>/dev/null | awk '{print $1}')
    case "$pid" in
        ''|*[!0-9]*)
            echo "ERROR: cannot read the XFS project id of '$d'."
            echo "Allocating an id without it risks reusing one that is already in"
            echo "use, which would put two clients under a single shared quota."
            echo "Check that the directory is readable (mode 755) and on the XFS mount."
            podman unshare rmdir "$HOST_REPO" 2>/dev/null
            exit 1
            ;;
    esac
    [ "$pid" -gt "$PROJID" ] && PROJID="$pid"
done
PROJID=$((PROJID + 1))

echo "[create] Assigning XFS project id $PROJID to $HOST_REPO"
sudo xfs_quota -x -c "project -s -p $HOST_REPO $PROJID" "$XFS_MOUNT" >/dev/null

echo "[create] Setting hard quota: $QUOTA"
sudo xfs_quota -x -c "limit -p bhard=${QUOTA} ${PROJID}" "$XFS_MOUNT"

# Read the limit back from the directory itself instead of trusting the exit
# status above: xfs_quota reports success for a limit set on a project id that
# never reaches this directory (e.g. the project assignment above did not
# stick), and the client would then be effectively unlimited until the whole
# volume runs full. Verify before the client exists in clients.conf at all.
if ! quota_verify "$HOST_REPO" "$QUOTA"; then
    # The directory goes, and so does the limit that was just set on the
    # project id — bhard=0 is XFS for "no limit", which is what this id had
    # before this run. The id is handed out again by the next create (max+1
    # over the directories that exist), and leaving a limit on it would make
    # that client inherit a number nobody chose for it.
    echo "ERROR: aborting — no client was created."
    sudo xfs_quota -x -c "limit -p bhard=0 ${PROJID}" "$XFS_MOUNT" 2>/dev/null || \
        echo "WARNING: the limit set on project id $PROJID could not be cleared."
    podman unshare rmdir "$HOST_REPO" 2>/dev/null
    exit 1
fi

echo "[create] Create entry in clients.conf"
echo "${USERNAME}:${GROUP}:${CONTAINER_REPO}:${QUOTA}" >> "$CONF"

echo "[create] Create empty public key file"
mkdir -p "$KEYDIR"
touch "${KEYDIR}/${USERNAME}.pub"

echo "[create] User '$USERNAME' created with quota $QUOTA (project id $PROJID, limit verified)."
echo "         Repository directory owned by ${BORG_UID}:${BORG_GID} in the container's"
echo "         user namespace — writable by 'borg', no further action needed."
echo "→ Set now the public key!"
