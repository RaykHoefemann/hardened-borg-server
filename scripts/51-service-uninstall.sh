#!/bin/sh
#
# 51-service-uninstall.sh
# ------------------------
# Reverses 50-service-install.sh: stops the generated unit, removes the
# Quadlet symlink and its generated drop-in from
# ~/.config/containers/systemd/, and reloads the user manager so the unit
# stops being generated.
#
# Does NOT touch the container image, or any data under HOST_CONFIG_BASE,
# HOST_REPO_BASE, or HOST_LOG_BASE (config.sh) — clients, repositories and
# logs are left exactly as they are.
#
# Usage:
#   ./scripts/51-service-uninstall.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/${CONTAINER}.container"
DROPIN_DIR="${QUADLET_DIR}/${CONTAINER}.container.d"

# A generated unit cannot be `systemctl --user disable`d — there is no
# [Install] symlink to remove, the wiring comes from the Quadlet. Stopping it
# is enough; removing the source files below is what stops it being generated
# on the next reload.
if systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "[uninstall] Stopping $SERVICE..."
    systemctl --user stop "$SERVICE"
fi

if [ -e "$QUADLET_FILE" ] || [ -L "$QUADLET_FILE" ]; then
    echo "[uninstall] Removing Quadlet $QUADLET_FILE"
    rm -f "$QUADLET_FILE"
fi

if [ -d "$DROPIN_DIR" ]; then
    echo "[uninstall] Removing drop-in directory $DROPIN_DIR"
    rm -rf "$DROPIN_DIR"
fi

echo "[uninstall] Reloading the user manager"
systemctl --user daemon-reload

echo "[uninstall] Service uninstalled."
echo "→ Left untouched: the container image, and all data under"
echo "  HOST_CONFIG_BASE/HOST_REPO_BASE/HOST_LOG_BASE."
echo "→ To also remove the image: podman rmi \"\$IMAGE\" (see config.sh)"
