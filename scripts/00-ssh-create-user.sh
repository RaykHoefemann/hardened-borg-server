#!/bin/sh
#
# 00-ssh-create-user.sh
# ---------------------
# Creates a new Borg client:
#  - Repository directory on the host
#  - Entry in config/clients.conf
#  - Empty public key file in config/keys/
#
# Usage:
#   ./scripts/00-ssh-create-user.sh <username> <group>
#
# Groups:
#   OWN     internal users from own network
#   MIRROR  external users (e.g. friends)
#

#load setup for all scripts
. "$(dirname "$0")/../config.sh"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <group>"
    echo "Group: OWN | MIRROR"
    exit 1
fi

USERNAME="$1"
GROUP="$2"

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

# autogenerate repo path
REPO_SUBPATH="${GROUP}/${USERNAME}"
CONTAINER_REPO="/repo/${REPO_SUBPATH}"

# check if user exists
if grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: User '$USERNAME' already exists in clients.conf! Aborted."
    exit 1
fi

echo "[create] Create entry in clients.conf"
echo "${USERNAME}:${GROUP}:${CONTAINER_REPO}" >> "$CONF"

echo "[create] Create empty public key file"
mkdir -p "$KEYDIR"
touch "${KEYDIR}/${USERNAME}.pub"

echo "[create] User '$USERNAME' created."
echo "→ Set now the public key!"

