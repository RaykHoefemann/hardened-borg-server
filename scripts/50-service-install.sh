#!/bin/sh
#
# 50-install-service.sh
# ---------------------
# Installs the systemd unit for the Borg server as a rootless container
# and creates a symlink to avoid duplicate files.
#
# Usage:
#   ./scripts/50-install-service.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/../config.sh"

SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="container-borg-server.service"
SOURCE_FILE="$(pwd)/systemd/$SERVICE_NAME"
TARGET_FILE="$SERVICE_DIR/$SERVICE_NAME"

echo "[install] Installing systemd unit as symlink..."

if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: Service file not found: $SOURCE_FILE"
    exit 1
fi

mkdir -p "$SERVICE_DIR"

# If an old file exists → delete it
if [ -e "$TARGET_FILE" ]; then
    echo "[install] Removing old file $TARGET_FILE"
    rm -f "$TARGET_FILE"
fi

# Create symlink
ln -s "$SOURCE_FILE" "$TARGET_FILE"

echo "[install] Symlink created:"
echo "  $TARGET_FILE -> $SOURCE_FILE"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"

echo "[install] Service enabled for rootless container."
echo "→ To start the service use 90-container-start.sh"
echo "→ To start the service on boot without login, run:"
echo "  loginctl enable-linger $USER"
