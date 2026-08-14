#!/bin/sh
#
# 91-container-stop.sh
# ----------
# Stops the Borg server container via systemd.
#
# Usage:
#   ./scripts/91-container-stop.sh
#
# Example:
#   ./scripts/91-container-stop.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

echo "[stop] Stopping Borg server..."
systemctl --user stop "$SERVICE"
if ! systemctl --user is-active --quiet "$SERVICE"; then
    echo "[stop] Service is stopped."
else
    echo "ERROR: Service failed to stop!"
    systemctl --user status "$SERVICE" --no-pager
    exit 1
fi
echo "[stop] Done."
