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

KEYDIR="config/keys"
CONF="config/clients.conf"

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

# Fall 1: INPUT is a existing file
if [ -f "$INPUT" ]; then
    echo "[key] Read key from file: $INPUT"
    cp "$INPUT" "$TARGET"
    OK=1
else
    # Fall 2: INPUT is a Key-String
    echo "$INPUT" | grep -q "^ssh-" && OK=1
    if [ "$OK" = "1" ]; then
        echo "[key] Write key string in file: $TARGET"
        echo "$INPUT" > "$TARGET"
    else
        echo "ERROR: '$INPUT' isn't a file or a valid ssh key!"
        exit 1
    fi
fi

if ! ssh-keygen -l -f "$TARGET" > /dev/null 2>&1; then
    echo "ERROR: not a valid SSH public key!"
    rm "$TARGET"
    exit 1
fi

echo "[key] Public key saved in: $TARGET"
echo "→ Please restart the container!"

