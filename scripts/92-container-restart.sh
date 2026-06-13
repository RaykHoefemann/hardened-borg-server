#!/bin/sh
#
# 92-container-restart.sh
# --------------
# Restarts the Borg server container.
# Must be executed when clients.conf has been modified.
#
# Usage:
#   ./scripts/92-container-restart.sh
#
# Example:
#   ./scripts/92-container-restart.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/../config.sh"

echo "[restart] Restarting Borg server..."
systemctl --user restart "$SERVICE"
if systemctl --user is-active --quiet "$SERVICE"; then
    echo "[restart] Service is running."
else
    echo "ERROR: Service failed to restart!"
    systemctl --user status "$SERVICE" --no-pager
    exit 1
fi
echo "[restart] Done."
