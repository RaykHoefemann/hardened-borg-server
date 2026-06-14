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

set -eu

LOG="/log/entrypoint.log"

# Log Function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG"
}

log "Starting Borg server..."

# ---------------------------------------------------------
# Generate SSH host keys (if not already present)
# ---------------------------------------------------------
log "looking for SSH host keys..."
# SSH Host Keys persistent halten
HOST_KEY_DIR="/config/ssh_host_keys"
mkdir -p "$HOST_KEY_DIR"
chmod 700 "$HOST_KEY_DIR"

if [ ! -f "$HOST_KEY_DIR/ssh_host_ed25519_key" ]; then
    log "[INFO] Generating new SSH host keys..."
    ssh-keygen -t ed25519 -f "$HOST_KEY_DIR/ssh_host_ed25519_key" -N ""
    ssh-keygen -t rsa -b 4096 -f "$HOST_KEY_DIR/ssh_host_rsa_key" -N ""
else
    log "[INFO] Using existing SSH host keys."
fi

# sshd auf die Keys im Volume zeigen lassen
sed -i "s|#HostKey /etc/ssh/ssh_host_ed25519_key|HostKey $HOST_KEY_DIR/ssh_host_ed25519_key|" /etc/ssh/sshd_config
sed -i "s|#HostKey /etc/ssh/ssh_host_rsa_key|HostKey $HOST_KEY_DIR/ssh_host_rsa_key|" /etc/ssh/sshd_config

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
    log "ERROR: /build_authorized_keys.sh not found! Aborting."
    exit 1
fi

# ---------------------------------------------------------
# set owner of repo
# ---------------------------------------------------------
log "Setting owner of /repo..."
chown -R borg:borg /repo

# ---------------------------------------------------------
# start SSH
# ---------------------------------------------------------
log "Starting SSH-Daemon..."
exec /usr/sbin/sshd -D -e

log "done."

