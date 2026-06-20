#!/bin/sh
#
# 99-container-status.sh
# -------------
# Shows the current status of the Borg-Backup container.
# Detects both systemd-managed and regular Podman containers.
#
# Usage:
#   ./scripts/99-container-status.sh
#
# Example:
#   ./scripts/99-container-status.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

echo "------------------------------------------------------------"
echo "[status] Systemd Service Status"
echo "------------------------------------------------------------"
systemctl --user status "$SERVICE" --no-pager

echo
echo "------------------------------------------------------------"
echo "[status] Container Status (podman ps)"
echo "------------------------------------------------------------"
podman ps --filter "name=$CONTAINER"

# Check if the container exists
CONTAINER_EXISTS=$(podman ps -a --format "{{.Names}}" | grep -w "$CONTAINER" || true)

echo
echo "------------------------------------------------------------"
echo "[status] Container Details"
echo "------------------------------------------------------------"

if [ -z "$CONTAINER_EXISTS" ]; then
    echo "Container '$CONTAINER' is not registered in podman."
    echo "→ It might be running transiently under systemd."
else
    # Try to inspect
    if ! podman inspect "$CONTAINER" --format \
    "Name: {{.Name}}
    Image: {{.ImageName}}
    Status: {{.State.Status}}
    PID: {{.State.Pid}}
    IP: {{.NetworkSettings.IPAddress}}
    Ports: {{json .NetworkSettings.Ports}}
    Mounts:
    {{range .Mounts}}  - {{.Source}} -> {{.Destination}}
    {{end}}" 2>/dev/null; then
        echo "Container is running, but 'podman inspect' is unavailable."
        echo "→ The container might be transient."
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Last Log Lines"
echo "------------------------------------------------------------"
journalctl --user -u "$SERVICE" -n 20 --no-pager

echo
echo "[status] Done."
echo "------------------------------------------------------------"
