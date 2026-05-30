#!/bin/sh
#
# 00-ssh-create-user.sh
# ---------------------
# Creates a new Borg client:
#  - Repository directory on the host
#  - Entry in config/clients.conf
#  - Empty public key file
#
# Usage:
#   ./scripts/00-ssh-create-user.sh <username> <group>
#
# Groups:
#   OWN     internal users from own network
#   MIRROR  external users (e.g. friends)
#

set -eu

CONF="config/clients.conf"
KEYDIR="config/keys"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <group>"
    echo "Group: OWN | MIRROR"
    exit 1
fi

USERNAME="$1"
GROUP="$2"

# Validate username (safe filename + config token)
case "$USERNAME" in
    ""|*[!A-Za-z0-9_.-]*)
        echo "ERROR: invalid username '$USERNAME'"
        echo "allowed chars: A-Z a-z 0-9 . _ -"
        exit 1
        ;;
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

mkdir -p "$(dirname "$CONF")"
touch "$CONF"

# check if user exists
if grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: User '$USERNAME' already exists in clients.conf! Aborted."
    exit 1
fi

echo "[create] Create entry in clients.conf"
printf '%s\n' "${USERNAME}:${GROUP}:${CONTAINER_REPO}" >> "$CONF"

echo "[create] Create empty public key file"
mkdir -p "$KEYDIR"
touch "${KEYDIR}/${USERNAME}.pub"

echo "[create] User '$USERNAME' created."
echo "→ Set now the public key!"

