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

echo "[start] Starting Borg server..."
systemctl --user start container-borg-server.service
echo "[start] Done."
