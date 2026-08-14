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
echo "[status] Installed Release"
echo "------------------------------------------------------------"
# The host half of a release is these scripts, which the container image does
# not carry — so the image tag alone never answers "what is installed here".
echo "Host scripts:     ${RELEASE_VERSION}"
echo "Configured image: ${IMAGE}"

# What the RUNNING container reports about itself. One exec rather than three,
# and empty throughout if the container is not running.
#
#   Running image  — from the VERSION baked in at build time. The only figure
#                    that survives a digest pin: with IMAGE set to a sha256
#                    reference, the configured value says nothing about which
#                    release is actually serving clients.
#   Bundled borg   — the wrapper's encryption check reads the repository's
#                    on-disk manifest and is therefore version-sensitive. The
#                    note at the top of borg-wrapper.sh records which versions
#                    a release was tested against; this is what is actually
#                    running, and the two are worth comparing after any base
#                    image change.
#   Base OS        — for judging whether a Debian advisory applies to you.
RUNTIME_INFO="$(podman exec "$CONTAINER" sh -c '
    printf "version=%s\n" "$(tr -d "[:space:]" < /VERSION 2>/dev/null)"
    printf "borg=%s\n"    "$(borg --version 2>/dev/null)"
    printf "debian=%s\n"  "$(cat /etc/debian_version 2>/dev/null)"
' 2>/dev/null || true)"

RUNNING_VERSION="$(printf '%s\n' "$RUNTIME_INFO" | sed -n 's/^version=//p')"
RUNNING_BORG="$(printf '%s\n' "$RUNTIME_INFO" | sed -n 's/^borg=//p')"
RUNNING_DEBIAN="$(printf '%s\n' "$RUNTIME_INFO" | sed -n 's/^debian=//p')"

[ -n "$RUNNING_VERSION" ] && echo "Running image:    ${RUNNING_VERSION}"
[ -n "$RUNNING_BORG" ]    && echo "Bundled borg:     ${RUNNING_BORG}"
[ -n "$RUNNING_DEBIAN" ]  && echo "Base OS:          Debian ${RUNNING_DEBIAN}"
echo "Source:           ${SOURCE_URL}"

if [ "$RELEASE_VERSION" = "unknown" ]; then
    echo
    echo "→ No VERSION file found. This tree was not installed from a release"
    echo "  tag (see docs/SERVERINSTALL.md step 1)."
elif [ -n "$RUNNING_VERSION" ] && [ "$RUNNING_VERSION" != "$RELEASE_VERSION" ]; then
    echo
    echo "→ MISMATCH: host scripts are ${RELEASE_VERSION}, the running container"
    echo "  is ${RUNNING_VERSION}. The two halves of a release are meant to match."
    echo "  Either the image was not restarted after an upgrade, or IMAGE points"
    echo "  at a different release than the checkout these scripts came from."
fi

echo
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
