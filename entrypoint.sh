#!/bin/bash
#
# entrypoint.sh
# --------------
# Startup script for the Borg backup container.
#
# Tasks:
# - Generate SSH host keys (if not present)
# - Prepare the .ssh directory for the 'borg' user
# - Generate authorized_keys from /config/clients.conf
#   (via /build_authorized_keys.sh)
# - Fix permissions
# - Start the SSH daemon
#

set -euo pipefail

LOG="/log/entrypoint.log"

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

log "Starting Borg server..."

# ---------------------------------------------------------
# Generate SSH host keys (if not already present)
# ---------------------------------------------------------
log "Looking for SSH host keys..."

HOST_KEY_DIR="/config/ssh_host_keys"
mkdir -p "$HOST_KEY_DIR"
chmod 700 "$HOST_KEY_DIR"

if [ ! -f "$HOST_KEY_DIR/ssh_host_ed25519_key" ]; then
    log "[INFO] Generating new SSH host key (ed25519)..."
    ssh-keygen -t ed25519 -f "$HOST_KEY_DIR/ssh_host_ed25519_key" -N ""
else
    log "[INFO] Using existing SSH host key."
fi

# ---------------------------------------------------------
# Prepare .ssh directory for user 'borg'
# ---------------------------------------------------------
log "Preparing /home/borg/.ssh..."
mkdir -p /home/borg/.ssh
chmod 700 /home/borg/.ssh
chown borg:borg /home/borg/.ssh

# ---------------------------------------------------------
# Create authorized_keys
# ---------------------------------------------------------
if [ ! -f /build_authorized_keys.sh ]; then
    log "[ERROR] /build_authorized_keys.sh not found! Aborting."
    exit 1
fi

log "Creating authorized_keys from clients.conf..."
if ! /build_authorized_keys.sh; then
    log "[ERROR] build_authorized_keys.sh failed – aborting startup."
    exit 1
fi

# ---------------------------------------------------------
# Set owner of repo
# ---------------------------------------------------------
log "Checking owner of /repo..."
if [ "$(stat -c '%U:%G' /repo)" != "borg:borg" ]; then
    log "[INFO] Fixing /repo ownership..."
    chown borg:borg /repo
else
    log "[INFO] /repo ownership OK."
fi

# ---------------------------------------------------------
# Start SSH daemon
# ---------------------------------------------------------
log "Starting SSH daemon..."
exec /usr/sbin/sshd -D -e
