#!/bin/sh
#
# 02-change-user-quota.sh
# -----------------------
# Change the quota of an existing Borg client:
#  - Looks up the client's HOST repository directory and its XFS project id
#  - Refuses a limit above 99% of the volume outright: it cannot be enforced,
#    and applying it is how a client ends up bounded by nothing at all
#  - Shows the limit currently enforced on that directory (which is not
#    necessarily what clients.conf claims), the intended one, each as a share
#    of the volume, and the resulting sum across all clients — then asks
#  - Applies the new hard limit to that project id immediately (xfs_quota)
#  - Reads the limit back from the directory and shows it; restores the
#    previous limit and aborts without touching clients.conf if the new one is
#    not actually in effect
#  - Updates the quota field in config/clients.conf
#
# The confirmation is read from stdin, so an unattended caller answers it the
# way tests and scripted runs do: `printf 'y\n' | 02-change-user-quota.sh ...`.
#
# The enforced limit takes effect immediately (xfs_quota applies live). The
# container must still be restarted to refresh the 'quota:' value shown in
# the client's info text; the live 'Used: X of Y' figure in the info channel
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
# Run as the normal operator user, NOT as root: only the individual
# xfs_quota calls that need CAP_SYS_ADMIN are elevated internally via sudo
# (you'll be prompted for your password there). Must run on the HOST, not
# inside the container.
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

# What the requested limit means relative to the volume, decided before sudo is
# reached: a value that cannot be enforced must never make it as far as
# xfs_quota. Applied first and verified afterwards — the order this script used
# to work in — it stays on the filesystem when the verification fails, and the
# client is left effectively unlimited on a volume shared with everyone else.
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
    echo "       Nothing was changed."
    exit 1
}

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

if ! sudo xfs_quota -x -c 'state -p' "$XFS_MOUNT" 2>/dev/null | grep -qE '^[[:space:]]*Enforcement:[[:space:]]*ON'; then
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

# Show what is in effect BEFORE the change, so the operator sees the actual
# starting point rather than only the clients.conf value — the two drift apart
# whenever a limit was changed outside this script, and that drift is exactly
# what an operator needs to see before deciding anything.
BEFORE_KIB=$(quota_enforced_kib "$HOST_REPO")
case "$BEFORE_KIB" in
    ''|*[!0-9]*) echo "[quota] Currently enforced: could not be read" ;;
    *) echo "[quota] Currently enforced: $(quota_human "$BEFORE_KIB") (clients.conf says $OLD_QUOTA)" ;;
esac

# "Nothing to change" is decided on what the filesystem enforces, not on what
# clients.conf claims. If the recorded value already equals the requested one
# but the kernel enforces something else, fall through and re-apply — that
# repairs the drift instead of reporting a quota that isn't real.
if [ "$OLD_QUOTA" = "$QUOTA" ]; then
    if [ "$BEFORE_KIB" = "$WANT_KIB" ]; then
        echo "[quota] Quota for '$USERNAME' is already $QUOTA and enforced. Nothing to change."
        exit 0
    fi
    echo "[quota] clients.conf already says $QUOTA, but that is not what is enforced."
    echo "[quota] Re-applying the limit to bring the filesystem back in line."
fi

# State what is about to happen as a share of the volume, and ask. A bare
# "60G" does not tell an operator whether that is generous or reckless, and
# raising quotas one request at a time is how a correctly sized volume drifts
# into overcommitment without anyone deciding to overcommit (OPERATIONS.md
# Chapter 10.2). Both figures are shown while stopping still costs nothing.
echo ""
quota_preview "$VOLUME_KIB" "$USERNAME" "$BEFORE_KIB" "$OLD_QUOTA" "$WANT_KIB" "$QUOTA" \
    "$(quota_used_kib "$HOST_REPO")" "$(quota_avail_kib "$HOST_REPO")"

if ! quota_confirm "Apply this change?"; then
    echo "Aborted — nothing was changed."
    exit 0
fi

# The limit currently on the project id, read from xfs_quota rather than from
# df: df reports the volume size when no limit applies, so restoring what df
# says would write a limit in volume size and make the very state this script
# exists to prevent permanent. Empty when it cannot be read, which the rollback
# below treats as "do not guess".
PREV_BHARD_KIB=$(sudo xfs_quota -x -c "report -p -N -b" "$XFS_MOUNT" 2>/dev/null \
    | awk -v p="#${PROJID}" '$1 == p { print $4; exit }')
case "$PREV_BHARD_KIB" in
    ''|*[!0-9]*) PREV_BHARD_KIB="" ;;
esac

echo "[quota] Applying new hard limit on host: project id $PROJID -> $QUOTA"
sudo xfs_quota -x -c "limit -p bhard=${QUOTA} ${PROJID}" "$XFS_MOUNT"

# Read the new limit back from the directory itself instead of trusting the
# exit status above: xfs_quota also reports success for a limit set on a
# project id that does not actually govern this directory. Verify BEFORE
# clients.conf is rewritten, so a failed change never leaves the recorded
# quota claiming something the filesystem does not enforce.
if ! quota_verify "$HOST_REPO" "$QUOTA"; then
    # clients.conf is intact, but the limit above is already on the filesystem.
    # An abort that leaves it there does not mean "nothing changed", which is
    # what this message used to imply and what OPERATIONS.md Chapter 9.4
    # promises. Put the previous limit back, so the abort is true.
    if [ -n "$PREV_BHARD_KIB" ]; then
        echo "[quota] Restoring the previous hard limit on project id $PROJID."
        if sudo xfs_quota -x -c "limit -p bhard=${PREV_BHARD_KIB}k ${PROJID}" "$XFS_MOUNT"; then
            NOW_KIB=$(quota_enforced_kib "$HOST_REPO")
            if [ "$NOW_KIB" = "$BEFORE_KIB" ]; then
                echo "[quota] Restored: $(quota_human "$NOW_KIB") is enforced again."
            else
                echo "WARNING: the restored limit does not read back as before"
                echo "         (was $(quota_human "$BEFORE_KIB"), now $(quota_human "$NOW_KIB"))."
            fi
        else
            echo "WARNING: restoring the previous limit failed."
        fi
    else
        echo "WARNING: the previous hard limit could not be read, so it was not"
        echo "         restored. The limit now enforced for '$USERNAME' is"
        echo "         whatever the failed change left behind — check it with"
        echo "         ./scripts/09-show-all-users.sh before relying on it."
    fi
    echo "ERROR: aborting — clients.conf was not modified, it still says $OLD_QUOTA."
    exit 1
fi

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

if [ "$OLD_QUOTA" = "$QUOTA" ]; then
    echo "[quota] Quota for '$USERNAME' re-applied: ${QUOTA} (enforced immediately)"
else
    echo "[quota] Quota for '$USERNAME' changed: ${OLD_QUOTA} → ${QUOTA} (enforced immediately)"
fi
echo "→ Restart the container to refresh the 'quota:' value in the client's info text."
