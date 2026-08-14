#!/bin/bash
#
# build_authorized_keys.sh
# ------------------------
# create the file /home/borg/.ssh/authorized_keys based on:
#   /config/clients.conf (Format: name:group:repo:quota)
#   /config/keys/<name>.pub (public ssh-key from user)
#
# Also generates <repo>/info.txt per client, containing server
# contact info (from /config/server_info.conf) and client-specific
# info (user, quota).
#
set -euo pipefail

CONF="/config/clients.conf"
KEYDIR="/config/keys"
OUT="/home/borg/.ssh/authorized_keys"
TMPOUT="${OUT}.tmp"
SERVER_INFO="/config/server_info.conf"

# Identity of the software itself, as opposed to the operator's deployment.
# Baked into the image at build time (Dockerfile), so it cannot be edited into
# something untrue by whoever runs the container. "unknown" means the image was
# built outside the release pipeline.
VERSION_FILE="/VERSION"
RELEASE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)"
[ -n "$RELEASE_VERSION" ] || RELEASE_VERSION="unknown"
SOURCE_URL="https://github.com/RaykHoefemann/hardened-borg-server"
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

if [ ! -f "$SERVER_INFO" ]; then
    log "[ERROR] Server info file $SERVER_INFO not found – aborting"
    exit 1
fi

# ---------------------------------------------------------
# Read server info (validated key=value pairs)
# ---------------------------------------------------------
SERVER_NAME=""
SERVER_LOCATION=""
SERVER_CONTACT=""

while IFS="=" read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    case "$key" in
        name)     SERVER_NAME="$value" ;;
        location) SERVER_LOCATION="$value" ;;
        contact)  SERVER_CONTACT="$value" ;;
        *)        log "[WARN] Unknown key in $SERVER_INFO: '$key' – ignoring" ;;
    esac
done < "$SERVER_INFO"

if [ -z "$SERVER_NAME" ] || [ -z "$SERVER_LOCATION" ] || [ -z "$SERVER_CONTACT" ]; then
    log "[ERROR] Server info incomplete (name/location/contact required) – aborting"
    exit 1
fi

# Header (write to tempfile, not directly to $OUT)
log "# Starting the build of authorized_keys..."
echo "# Auto-generated authorized_keys" > "$TMPOUT"
echo "# Do not edit manually" >> "$TMPOUT"
echo "" >> "$TMPOUT"

count=0

# read each line from clients.conf
while IFS=":" read -r name group repo quota; do
    [ -z "$name" ] && continue
    case "$name" in
        \#*) continue ;;
    esac

    # Validate name (used in file path)
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        log "[ERROR] Invalid name '$name' – skipping"
        continue
    fi

    # Validate group
    if ! echo "$group" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        log "[ERROR] Invalid group '$group' for '$name' – skipping"
        continue
    fi

    # Validate repo path (used in forced command)
    if ! echo "$repo" | grep -qE '^/[a-zA-Z0-9/_-]+$'; then
        log "[ERROR] Invalid repo path for '$name': '$repo' – skipping"
        continue
    fi

    # Validate quota (mandatory, format: <digits>G, e.g. 50G)
    if ! echo "$quota" | grep -qE '^[0-9]+G$'; then
        log "[ERROR] Invalid or missing quota for '$name': '$quota' (expected format: <number>G) – skipping"
        continue
    fi

    log "[INFO] Found user: '$name'"

    KEYFILE="${KEYDIR}/${name}.pub"

    if [ ! -f "$KEYFILE" ]; then
        log "[WARN] No public key found for '$name' – skipping"
        continue
    fi

    if [ ! -s "$KEYFILE" ]; then
        log "[WARN] Public key file for '$name' is empty – skipping"
        continue
    fi

    # Validate SSH key
    if ! ssh-keygen -l -f "$KEYFILE" > /dev/null 2>&1; then
        log "[ERROR] Invalid SSH key for '$name' – skipping"
        continue
    fi

    # Use only the first line – prevents multi-line key files
    # from injecting additional entries that bypass command= or restrict options
    key="$(head -n1 "$KEYFILE")"
    CMD="/borg-wrapper.sh $repo"
    echo "command=\"$CMD\",restrict $key" >> "$TMPOUT"
    log "[INFO] Added key for '$name' with repo '$repo' (quota: $quota)"
    count=$((count + 1))

    # ---------------------------------------------------------
    # Generate info.txt for this client
    # ---------------------------------------------------------
    mkdir -p "$repo"
    INFO_FILE="${repo}/info.txt"

    cat > "$INFO_FILE" <<EOF
[server]
name: ${SERVER_NAME}
location: ${SERVER_LOCATION}
contact: ${SERVER_CONTACT}

[software]
version: ${RELEASE_VERSION}
source: ${SOURCE_URL}

[client]
user: ${name}
quota: ${quota}
EOF

    chown borg:borg "$INFO_FILE"
    chmod 644 "$INFO_FILE"
    log "[INFO] Generated info.txt for '$name'"
done < "$CONF"

# Abort if no keys were successfully added
if [ "$count" -eq 0 ]; then
    log "[ERROR] No valid keys were added – authorized_keys would be empty! Keeping existing file."
    rm -f "$TMPOUT"
    exit 1
fi

# Atomic swap: replace authorized_keys only on success
mv "$TMPOUT" "$OUT"

# set permissions
chown borg:borg "$OUT"
chmod 600 "$OUT"
log "[INFO] Permissions set for $OUT"
log "[INFO] $count key(s) written to authorized_keys"

log "done"
