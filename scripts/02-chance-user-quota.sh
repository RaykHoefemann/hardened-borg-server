#!/bin/sh
#
# 02-change-user-quota.sh
# -----------------------
# Change the quota of an existing Borg client:
#  - Looks up the client's HOST repository directory and its XFS project id
#  - Applies the new hard limit to that project id immediately (xfs_quota)
#  - Updates the quota field in config/clients.conf
#
# The enforced limit takes effect immediately (xfs_quota applies live). The
# container must still be restarted to refresh the 'quota:' value shown in
# the client's info.txt; the live 'Used: X of Y' figure in the info channel
# (see README Chapter 7) reflects the new limit right away, since it reads
# the XFS quota directly via statvfs().
#
# Usage:
#   ./scripts/02-change-user-quota.sh <username> <new-quota>
#   ./scripts/02-change-user-quota.sh user1-os1-pc1 100G
#
# Quota:
#   Format: <number>G (e.g. 10G, 50G, 200G)
#
# Requires: root (or equivalent CAP_SYS_ADMIN) for xfs_quota. Must run on the
# HOST, not inside the container.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <new-quota>"
    echo "Quota format: <number>G (e.g. 50G)"
    exit 1
fi

USERNAME="$1"
QUOTA="$2"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must run as root (needed for xfs_quota)."
    exit 1
fi

if [ -z "${HOST_REPO_BASE:-}" ]; then
    echo "ERROR: HOST_REPO_BASE is not set in config.sh."
    exit 1
fi

# Normalize base path: strip any trailing slash so path construction below is
# unambiguous regardless of how the operator wrote config.sh ("/x" or "/x/").
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

# validate username charset (defensive: keeps the grep pattern safe)
case "$USERNAME" in
    *[!a-zA-Z0-9_-]*)
        echo "ERROR: Invalid username '$USERNAME' (only a-z, 0-9, _, - allowed)"
        exit 1
        ;;
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

# check if user exists and read its current entry (username:group:repo:quota)
ENTRY=$(grep "^${USERNAME}:" "$CONF" 2>/dev/null) || {
    echo "ERROR: user '$USERNAME' does not exist in clients.conf!"
    exit 1
}
GROUP=$(echo "$ENTRY" | cut -d: -f2)
OLD_QUOTA=$(echo "$ENTRY" | cut -d: -f4)

# defensive: clients.conf is self-authored, but a malformed/manually-edited
# line should not silently produce a bogus path.
if [ "$GROUP" != "OWN" ] && [ "$GROUP" != "MIRROR" ]; then
    echo "ERROR: clients.conf entry for '$USERNAME' has invalid group '$GROUP'."
    echo "Expected OWN or MIRROR — needs manual review."
    exit 1
fi

HOST_REPO="${HOST_REPO_BASE}/${GROUP}/${USERNAME}"

if [ "$OLD_QUOTA" = "$QUOTA" ]; then
    echo "[quota] Quota for '$USERNAME' is already $QUOTA. Nothing to change."
    exit 0
fi

if [ ! -d "$HOST_REPO" ]; then
    echo "ERROR: repository directory '$HOST_REPO' not found on host."
    echo "clients.conf and the filesystem are out of sync — needs manual review."
    exit 1
fi

# Resolve the XFS mount and the repo's existing project id.
XFS_MOUNT=$(df -P "$HOST_REPO" | awk 'NR==2 {print $6}')
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'."
    exit 1
fi

if ! xfs_quota -x -c 'state -p' "$XFS_MOUNT" 2>/dev/null | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
    echo "ERROR: '$XFS_MOUNT' does not have enforcing XFS project quotas (prjquota)."
    echo "This is a mandatory host requirement (see BEST_PRACTICES.md Chapter 1)."
    exit 1
fi

PROJID=$(lsattr -p -d "$HOST_REPO" 2>/dev/null | awk '{print $1}')
case "$PROJID" in
    ''|*[!0-9]*|0)
        echo "ERROR: '$HOST_REPO' has no valid XFS project id assigned."
        echo "It may predate project-quota enforcement; assign one manually first."
        exit 1
        ;;
esac

echo "[quota] Applying new hard limit on host: project id $PROJID -> $QUOTA"
xfs_quota -x -c "limit -p bhard=${QUOTA} ${PROJID}" "$XFS_MOUNT"

# rewrite clients.conf, changing only the quota field (4) of the matching user.
# awk with -F:/OFS=: preserves all other fields verbatim, including the repo
# path (which contains '/'). Written to a temp file and moved into place so the
# update is atomic and never leaves clients.conf half-written.
TMP="${CONF}.tmp"
awk -F: -v OFS=: -v u="$USERNAME" -v q="$QUOTA" '
    $1 == u { $4 = q }
    { print }
' "$CONF" > "$TMP"
mv "$TMP" "$CONF"

echo "[quota] Quota for '$USERNAME' changed: ${OLD_QUOTA} → ${QUOTA} (enforced immediately)"
echo "→ Restart the container to refresh the 'quota:' value in the client's info.txt."
