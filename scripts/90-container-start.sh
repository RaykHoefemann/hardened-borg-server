#!/bin/sh
#
# 90-container-start.sh
# -----------
# Starts the Borg server container via systemd.
#
# Usage:
#   ./scripts/90-container-start.sh
#
# Example:
#   ./scripts/90-container-start.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

echo "[start] Starting Borg server..."
systemctl --user start "$SERVICE"
if systemctl --user is-active --quiet "$SERVICE"; then
    echo "[start] Service is running."
else
    echo "ERROR: Service failed to start!"
    systemctl --user status "$SERVICE" --no-pager
    exit 1
fi
echo "[start] Done."
