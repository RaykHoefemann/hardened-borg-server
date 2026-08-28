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
. "$(dirname "$0")/config.sh"

if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <public-key-file|public-key-string>"
    exit 1
fi

USERNAME="$1"
INPUT="$2"

case "$USERNAME" in
    ''|-*|*[!a-zA-Z0-9_-]*)
        echo "ERROR: Invalid username '$USERNAME' (must be non-empty, must not start with '-', only a-z, 0-9, _, - allowed)"
        exit 1
        ;;
esac

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

# Stage the new key beside the target and validate it BEFORE replacing
# anything. Writing straight to $TARGET and deleting it on a failed check
# would destroy a working key whenever the replacement turns out to be
# invalid — the client would lose access at the next container restart, and
# the operator would have no copy left to restore from. Same
# validate-then-swap pattern build_authorized_keys.sh uses for
# authorized_keys.
TMP="${TARGET}.tmp"

# Fall 1: INPUT is a existing file
if [ -f "$INPUT" ]; then
    echo "[key] Read key from file: $INPUT"
    cp "$INPUT" "$TMP"
else
    # Fall 2: INPUT is a Key-String
    echo "[key] Write key string in file: $TARGET"
    echo "$INPUT" > "$TMP"
fi

# checking ssh-key
if ! ssh-keygen -l -f "$TMP" > /dev/null 2>&1; then
    echo "ERROR: not a valid SSH public key!"
    rm -f "$TMP"
    if [ -s "$TARGET" ]; then
        echo "[key] Existing key for '$USERNAME' left unchanged."
    fi
    exit 1
fi

mv "$TMP" "$TARGET"

echo "[key] Public key saved in: $TARGET"
echo "→ Restart the container to activate this key:"
echo "    ./scripts/92-container-restart.sh"
echo "  authorized_keys is generated at container start and nowhere else, so"
echo "  until then this key grants no access. The restart drops connections in"
echo "  flight, including a backup in progress."

