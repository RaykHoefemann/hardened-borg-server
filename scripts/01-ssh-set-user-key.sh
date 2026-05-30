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

set -eu

KEYDIR="config/keys"
CONF="config/clients.conf"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <public-key-file|public-key-string>"
    exit 1
fi

USERNAME="$1"
INPUT="$2"
OK=0

# Validate username (safe filename + config token)
case "$USERNAME" in
    ""|*[!A-Za-z0-9_.-]*)
        echo "ERROR: invalid username '$USERNAME'"
        echo "allowed chars: A-Z a-z 0-9 . _ -"
        exit 1
        ;;
esac

is_valid_pubkey() {
    # Accepts common OpenSSH key formats and optional trailing comment.
    echo "$1" | grep -Eq '^ssh-[A-Za-z0-9-]+ [A-Za-z0-9+/=]+( .*)?$'
}

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
    KEY_LINE="$(head -n 1 "$INPUT" | tr -d '\r')"
    if is_valid_pubkey "$KEY_LINE"; then
        printf '%s\n' "$KEY_LINE" > "$TARGET"
        OK=1
    fi
else
    # Fall 2: INPUT is a Key-String
    is_valid_pubkey "$INPUT" && OK=1
    if [ "$OK" = "1" ]; then
        echo "[key] Write key string in file: $TARGET"
        printf '%s\n' "$INPUT" > "$TARGET"
    else
        echo "ERROR: '$INPUT' isn't a file or a valid ssh key!"
        exit 1
    fi
fi

if [ "$OK" != "1" ]; then
    echo "ERROR: key content in '$INPUT' is not a valid OpenSSH public key"
    exit 1
fi

echo "[key] Public key saved in: $TARGET"
echo "→ Please restart the container!"

