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
while IFS=":" read -r name group repo; do
    # skip empty lines and comments
    [ -z "$name" ] && continue
    case "$name" in
        \#*) continue ;;
    esac
    
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

    key="$(cat "$KEYFILE")"

    # Log the key's content status (optional, only for debugging)
    log "[INFO] Public key for '$name' is valid and non-empty"

    # forced command with append-only
    CMD="/borg-wrapper.sh $repo"

    # create new entry in authorized_keys
    echo "command=\"$CMD\",restrict $key" >> "$OUT"
    log "[INFO] Added authorized key for '$name' with repo '$repo'"

done < "$CONF"

# set permissions
chown borg:borg "$OUT"
chmod 600 "$OUT"
log "[INFO] Permissions set for $OUT"

log "done"
