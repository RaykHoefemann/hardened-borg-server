#!/bin/sh
#
# entrypoint.sh
# --------------
# Startup script for the Borg backup container.
#
# Tasks:
#   - Generate SSH host keys (if not present)
#   - Prepare the .ssh directory for the 'borg' user
#   - Generate authorized_keys from /config/clients.conf
#     (via /config/build_authorized_keys.sh)
#   - Fix permissions
#   - Start the SSH daemon
#

set -e

LOG="/log/entrypoint.log"

# Ensure log path exists before first log write.
mkdir -p /log

# Log Function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

log "Starting Borg server..."

# ---------------------------------------------------------
# Generate SSH host keys (if not already present)
# ---------------------------------------------------------
log "Generating SSH host keys (if needed)..."
ssh-keygen -A

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
if [ -f /build_authorized_keys.sh ]; then
    log "Create authorized_keys from clients.conf..."
    /build_authorized_keys.sh
else
    log "WARNING: /build_authorized_keys.sh not found!"
    log "SSH login will NOT work!"
fi

# ---------------------------------------------------------
# set owner of repo
# ---------------------------------------------------------
log "Setting owner of /repo..."
if [ -d /repo ]; then
    chown -R borg:borg /repo
else
    log "WARNING: /repo not found, skipping chown"
fi

# ---------------------------------------------------------
# start SSH
# ---------------------------------------------------------
log "Starting SSH-Daemon..."
exec /usr/sbin/sshd -D -e

log "done."

