#!/bin/sh
#
# build_authorized_keys.sh
# ------------------------
# create the file /home/borg/.ssh/authorized_keys based on:
#   /config/clients.conf  (Format: name:group:repo)
#   /config/keys/<name>.pub (public ssh-key from user)
#

set -eu

CONF="/config/clients.conf"
KEYDIR="/config/keys"
OUT="/home/borg/.ssh/authorized_keys"
LOG="/log/build_authorized_keys.log"
LOGDIR="$(dirname "$LOG")"

mkdir -p "$LOGDIR"

is_valid_name() {
    case "$1" in
        ""|*[!A-Za-z0-9_.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_valid_repo() {
    case "$1" in
        /repo/*) ;;
        *) return 1 ;;
    esac

    case "$1" in
        *[!A-Za-z0-9_./-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_valid_pubkey() {
    echo "$1" | grep -Eq '^ssh-[A-Za-z0-9-]+ [A-Za-z0-9+/=]+( .*)?$'
}

# Log Function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

# sanity checks
if [ ! -f "$CONF" ]; then
    log "[ERROR] Config file $CONF not found – aborting"
    exit 1
fi

if [ ! -d "$KEYDIR" ]; then
    log "[ERROR] Key directory $KEYDIR not found – aborting"
    exit 1
fi

if [ ! -d "$(dirname "$OUT")" ]; then
    log "[ERROR] Target directory $(dirname "$OUT") not found – aborting"
    exit 1
fi

# Header
log "# Starting the build of authorized_keys..."
echo "# Auto-generated authorized_keys" > "$OUT"
echo "# Do not edit manually" >> "$OUT"
echo "" >> "$OUT"

# read each line from clients.conf
while IFS=":" read -r name group repo mode; do
    # skip empty lines and comments
    [ -z "$name" ] && continue
    case "$name" in
        \#*) continue ;;
    esac

    if ! is_valid_name "$name"; then
        log "[WARN] Invalid username '$name' – skipped"
        continue
    fi

    if ! is_valid_repo "$repo"; then
        log "[WARN] Invalid repo path '$repo' for '$name' – skipped"
        continue
    fi

    # Log the found user
    log "[INFO] Found user: '$name'"

    KEYFILE="${KEYDIR}/${name}.pub"

    if [ ! -f "$KEYFILE" ]; then
        log "[WARN] No public key found for '$name' – will be skipped"
        continue
    fi

    # Check if the keyfile is empty
    if [ ! -s "$KEYFILE" ]; then
        log "[WARN] Public key file '$KEYFILE' for '$name' is empty – will be skipped"
        continue
    fi

    key="$(head -n 1 "$KEYFILE" | tr -d '\r')"

    if ! is_valid_pubkey "$key"; then
        log "[WARN] Invalid public key format in '$KEYFILE' – skipped"
        continue
    fi

    # Log the key's content status (optional, only for debugging)
    log "[INFO] Public key for '$name' is valid and non-empty"

    # forced command with append-only
    CMD="borg serve --restrict-to-path $repo --append-only"

    # create new entry in authorized_keys
    printf '%s\n' "command=\"$CMD\",restrict $key" >> "$OUT"
    log "[INFO] Added authorized key for '$name' with repo '$repo'"

done < "$CONF"

# set permissions
chown borg:borg "$OUT"
chmod 600 "$OUT"
log "[INFO] Permissions set for $OUT"

log "done"
