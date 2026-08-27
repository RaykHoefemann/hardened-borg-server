#!/bin/sh
#
# 04-reattach-client.sh
# ----------------------
# Reconnects an existing client's repository -- directory, host ownership and
# XFS project id already correct on disk -- to clients.conf, which no longer
# holds an entry for it (ROADMAP.md 11.5, "What restoring HOST_REPO_BASE
# alone does not restore"). Companion to 00-ssh-create-user.sh the way
# 03-provision-client.sh is companion to 02-change-user-quota.sh: 00 creates
# both halves of a client (clients.conf entry + filesystem) from nothing, 03
# rebuilds the filesystem half from an existing clients.conf entry, and this
# rebuilds the clients.conf entry from an existing filesystem half.
#
# WHY THIS EXISTS. HOST_CONFIG_BASE (clients.conf, config/keys/) lives inside
# the git checkout, not on the quota-enforcing storage volume that snapshots
# (11.5) and offsite mirroring (11.2) protect -- deliberately out of scope
# for both, see ROADMAP.md 11.5 "Scope". A HOST_REPO_BASE restore can
# therefore bring a client's repository directory, its host ownership and its
# XFS project id back perfectly intact while clients.conf and the key file do
# not come back with it. Everything the server needs to serve that client
# again is derived from the client's name and already sits on disk; this is
# the tool that reads it back rather than requiring it to be typed in by
# hand.
#
# WHAT IT MAY DO. It reads the group, the XFS project id and the quota
# currently enforced from the filesystem, and from those alone writes one
# line to clients.conf and (unless one is already there) one empty key file
# -- nothing it did not already find on disk. It never assigns a project id
# and never applies a limit, so unlike 00 and 03 it needs no `podman unshare`
# and no mutating `sudo xfs_quota` call -- only the same read-only
# `xfs_quota -x -c 'state -p'` enforcement check 00/02/03 all make before
# trusting anything quota-related.
#
# WHAT IT REFUSES. clients.conf already declaring this username is not this
# script's problem to fix. A missing repository directory has nothing to
# reattach and belongs to 00. A directory without an XFS project id is an
# unexpected state this script does not build a fresh id for -- it needs
# manual review, since 03 (which would normally provision that) itself
# requires the clients.conf entry this script exists to create. And an
# enforced quota that is not a whole number of GiB cannot be written into
# clients.conf's "<n>G" format at all -- refused rather than rounded, see
# "QUOTA FORMAT" below.
#
# WHAT IT CANNOT BRING BACK. The client's original SSH key, if no key file
# survived either. It never lived on HOST_REPO_BASE and there is nothing on
# disk to read it back from -- an empty key file is created, same as 00 does
# for a brand new client, and nothing about repository access depends on
# which key was used historically (ROADMAP.md 11.5).
#
# QUOTA FORMAT. clients.conf records quotas as "<n>G", and quota_kib() --
# which every script here uses to interpret that field -- accepts nothing
# else. Under normal operation the enforced quota is always an exact multiple
# of 1 GiB in KiB, because 00 and 02 are the only things that ever set it and
# both go through quota_kib() themselves. A value that is not can only mean
# something set this quota outside this project's tooling, and is refused
# rather than rounded to the nearest GiB: rounding would write a figure into
# clients.conf that is not the one actually enforced, and
# 09-show-all-users.sh would then either report false drift against a value
# nobody chose, or -- if the rounding happened to land close enough not to
# trip the drift check -- hide that the recorded and enforced limits disagree
# at all.
#
# Usage:
#   ./scripts/04-reattach-client.sh <username>
#
# Safe to re-run: refuses immediately once clients.conf already holds the
# entry it would otherwise write.
#
# The confirmation is read from stdin, so an unattended caller answers it the
# way tests and scripted runs do: `printf 'y\n' | 04-reattach-client.sh ...`.
#
# Run as the normal operator user. No `podman unshare` and no mutating
# `xfs_quota` call happen here (see "WHAT IT MAY DO" above), but the single
# enforcement check still shells out via `sudo xfs_quota` and may prompt for
# a password. Must run on the HOST, not inside the container.
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

mkdir -p "$(dirname "$CONF")"
touch "$CONF"

if grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: '$USERNAME' already has an entry in clients.conf."
    echo "This script reattaches a client whose entry is missing. To provision"
    echo "an existing entry's filesystem side instead, use"
    echo "./scripts/03-provision-client.sh $USERNAME."
    exit 1
fi

# The client's group: scanned from the filesystem, the same discovery
# 77-restore-last-snapshot.sh uses (snapshots/77-restore-last-snapshot.sh) --
# clients.conf cannot be consulted here, it is exactly what is missing.
GROUP=""
for D in "${HOST_REPO_BASE}"/*/"${USERNAME}"; do
    [ -d "$D" ] || continue
    if [ -n "$GROUP" ]; then
        echo "ERROR: '$USERNAME' has a repository directory under more than one"
        echo "       group ('$GROUP' and '$(basename "$(dirname "$D")")') --"
        echo "       refusing to guess which one is the real one. Needs manual review."
        exit 1
    fi
    GROUP="$(basename "$(dirname "$D")")"
done

if [ -z "$GROUP" ]; then
    echo "ERROR: no repository directory found for '$USERNAME' under $HOST_REPO_BASE."
    echo "This script reattaches clients.conf to an existing repository -- it does"
    echo "NOT create one. For a client that does not exist on disk either, use"
    echo "./scripts/00-ssh-create-user.sh <username> <group> <quota>."
    exit 1
fi

if [ "$GROUP" != "OWN" ] && [ "$GROUP" != "MIRROR" ]; then
    echo "ERROR: '$USERNAME' sits under group directory '$GROUP', which is neither"
    echo "OWN nor MIRROR. Needs manual review."
    exit 1
fi

HOST_REPO="${HOST_REPO_BASE}/${GROUP}/${USERNAME}"

if [ -z "${CONTAINER_REPO_BASE:-}" ]; then
    echo "ERROR: CONTAINER_REPO_BASE is not set in config.sh."
    exit 1
fi
CONTAINER_REPO_BASE="${CONTAINER_REPO_BASE%/}"
CONTAINER_REPO="${CONTAINER_REPO_BASE}/${GROUP}/${USERNAME}"

# Enforcement must genuinely be ON before anything read from this directory
# is trusted -- the same precondition 00/02/03 check before relying on
# xfs_quota, here because a quota this script is about to declare permanent
# in clients.conf must be one that is actually held to.
XFS_MOUNT=$(repo_xfs_mount "$HOST_REPO")
if [ -z "$XFS_MOUNT" ]; then
    echo "ERROR: could not resolve filesystem mount for '$HOST_REPO'."
    exit 1
fi
repo_quota_enforcing "$XFS_MOUNT" || exit 1

PROJID=$(repo_projid "$HOST_REPO") || {
    echo "ERROR: '$HOST_REPO' has no readable XFS project id."
    echo "This script reattaches clients.conf to a client whose filesystem side"
    echo "is already complete -- directory, ownership and project id all in"
    echo "place. A directory without a project id is not that state and needs"
    echo "manual review (docs/OPERATIONS.md chapter 9.12)."
    exit 1
}

QUOTA_KIB=$(quota_enforced_kib "$HOST_REPO")
case "$QUOTA_KIB" in
    ''|*[!0-9]*)
        echo "ERROR: could not read the enforced quota for '$HOST_REPO'."
        exit 1
        ;;
esac

VOLUME_KIB=$(volume_kib)
case "$VOLUME_KIB" in
    ''|*[!0-9]*|0)
        echo "ERROR: could not read the size of the volume at '$HOST_REPO_BASE'."
        exit 1
        ;;
esac

if [ "$QUOTA_KIB" -eq 0 ] || [ "$QUOTA_KIB" = "$VOLUME_KIB" ]; then
    echo "ERROR: '$HOST_REPO' has no limit in effect (df reports the whole volume)."
    echo "clients.conf cannot record a quota that is not actually enforced --"
    echo "that would recreate exactly the drift ./scripts/09-show-all-users.sh"
    echo "exists to catch. Apply a real limit with xfs_quota directly first,"
    echo "then re-run this script."
    exit 1
fi

# See "QUOTA FORMAT" above: refused rather than rounded.
case $((QUOTA_KIB % 1048576)) in
    0) ;;
    *)
        echo "ERROR: the enforced quota on '$HOST_REPO' is ${QUOTA_KIB} KiB"
        echo "($(quota_human "$QUOTA_KIB")), which is not a whole number of GiB."
        echo "clients.conf only records quotas as '<n>G', and rounding this value"
        echo "would record a limit different from the one actually enforced."
        echo "This can only happen if something outside this project's tooling set"
        echo "the limit -- correct it to a whole GiB with xfs_quota directly, then"
        echo "re-run this script."
        exit 1
        ;;
esac
QUOTA="$((QUOTA_KIB / 1048576))G"

echo "[reattach] Client:      $USERNAME ($GROUP)"
echo "[reattach] Directory:   $HOST_REPO"
echo "[reattach] Project id $PROJID, enforced limit $(quota_human "$QUOTA_KIB") -- reattaching as $QUOTA"
echo ""
quota_preview "$VOLUME_KIB" "$USERNAME" "" "" "$QUOTA_KIB" "$QUOTA" 0

if ! quota_confirm "Reattach client '$USERNAME' to clients.conf with this quota?"; then
    echo "Aborted -- nothing was changed."
    exit 0
fi

echo "[reattach] Create entry in clients.conf"
echo "${USERNAME}:${GROUP}:${CONTAINER_REPO}:${QUOTA}" >> "$CONF"

mkdir -p "$KEYDIR"
KEYFILE="${KEYDIR}/${USERNAME}.pub"
if [ -s "$KEYFILE" ]; then
    echo "[reattach] Existing key file found at $KEYFILE -- left unchanged."
    HAVE_KEY=1
else
    echo "[reattach] Create empty public key file"
    touch "$KEYFILE"
    HAVE_KEY=""
fi

echo "[reattach] Client '$USERNAME' reattached: quota $QUOTA (project id $PROJID, already"
echo "           enforced -- nothing on the filesystem was changed)."

if [ -n "$HAVE_KEY" ]; then
    echo "→ A key file already exists for this client -- restart the container to"
    echo "  activate it:"
    echo "    ./scripts/92-container-restart.sh"
else
    echo "→ Set now the public key:"
    echo "    ./scripts/01-ssh-set-user-key.sh ${USERNAME} <keyfile|keystring>"
    echo "  and then activate the client:"
    echo "    ./scripts/92-container-restart.sh"
    echo "  Both steps are required. authorized_keys is generated at container start,"
    echo "  and a client whose key file is still empty is skipped there -- restarting"
    echo "  before the key is set authorizes nobody."
fi
