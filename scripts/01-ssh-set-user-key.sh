#!/bin/sh
#
# 01-ssh-set-user-key.sh
# ----------------------
# Set the public key for an existing user.
# required:
#   - ssh-file
#   - or ssh key string directly
#
# Usage:
#   ./scripts/01-ssh-set-user-key.sh <username> <keyfile|keystring>
#   ./scripts/01-ssh-set-user-key.sh test "ssh-ed25519 AAAA…"
#   ./scripts/01-ssh-set-user-key.sh test test-key.pub
#

set -e
#load setup for all scripts
. "$(dirname "$0")/../config.sh"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <public-key-file|public-key-string>"
    exit 1
fi

USERNAME="$1"
INPUT="$2"

# check if user exists
if ! grep -q "^${USERNAME}:" "$CONF"; then
    echo "ERROR: user '$USERNAME' does not exists in clients.conf!"
    exit 1
fi

TARGET="${KEYDIR}/${USERNAME}.pub"
mkdir -p "$KEYDIR"

if [ -s "$TARGET" ]; then
    echo "WARNING: A key for '$USERNAME' already exists."
    printf "Overwrite? [y/N] "
    read -r CONFIRM
    case "$CONFIRM" in
        y|Y) echo "[key] Overwriting existing key." ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# Fall 1: INPUT is a existing file
if [ -f "$INPUT" ]; then
    echo "[key] Read key from file: $INPUT"
    cp "$INPUT" "$TARGET"
else
    # Fall 2: INPUT is a Key-String
    echo "[key] Write key string in file: $TARGET"
    echo "$INPUT" > "$TARGET"
fi

# checking ssh-key
if ! ssh-keygen -l -f "$TARGET" > /dev/null 2>&1; then
    echo "ERROR: not a valid SSH public key!"
    rm "$TARGET"
    exit 1
fi

echo "[key] Public key saved in: $TARGET"
echo "→ Please restart the container!"

