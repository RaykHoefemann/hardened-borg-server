#!/bin/sh
#
# 51-service-uninstall.sh
# ------------------------
# Reverses 50-service-install.sh: stops and disables the systemd unit,
# removes its symlink from ~/.config/systemd/user/, and deletes the
# generated EnvironmentFile and rendered unit.
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

SERVICE_DIR="$HOME/.config/systemd/user"
TARGET_FILE="$SERVICE_DIR/$SERVICE"
ENV_FILE="${REPO_ROOT}/systemd/${SERVICE}.env"
RENDERED_FILE="${REPO_ROOT}/systemd/${SERVICE}.rendered"

if systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then
    echo "[uninstall] Stopping $SERVICE..."
    systemctl --user stop "$SERVICE"
fi

if systemctl --user is-enabled --quiet "$SERVICE" 2>/dev/null; then
    echo "[uninstall] Disabling $SERVICE..."
    systemctl --user disable "$SERVICE"
fi

if [ -e "$TARGET_FILE" ]; then
    echo "[uninstall] Removing unit symlink $TARGET_FILE"
    rm -f "$TARGET_FILE"
fi

systemctl --user daemon-reload

if [ -f "$RENDERED_FILE" ]; then
    echo "[uninstall] Removing rendered unit $RENDERED_FILE"
    rm -f "$RENDERED_FILE"
fi

if [ -f "$ENV_FILE" ]; then
    echo "[uninstall] Removing EnvironmentFile $ENV_FILE"
    rm -f "$ENV_FILE"
fi

echo "[uninstall] Service uninstalled."
echo "→ Left untouched: the container image, and all data under"
echo "  HOST_CONFIG_BASE/HOST_REPO_BASE/HOST_LOG_BASE."
echo "→ To also remove the image: podman rmi \"\$IMAGE\" (see config.sh)"
