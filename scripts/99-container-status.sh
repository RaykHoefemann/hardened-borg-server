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

# `systemctl status` used to stand here, and most of what it printed worked
# against this report. It ends with a ten-line journal tail that [status] Last
# Log Lines prints again below, and its CGroup block renders the full command
# line of every process in the cgroup — for conmon some forty
# --exit-command-arg arguments — between the service state and the container
# state, which are what the report is opened for. The resolved `podman run`
# line, the one genuinely useful part of that block, is in [status] Container
# Details as podman itself reports it.
#
# Read in one call and picked apart below, the way the container's runtime
# info is handled above; `systemctl show` prints Key=Value and says nothing
# when a property is unset.
UNIT_PROPS="$(systemctl --user show "$SERVICE" \
    -p LoadState -p UnitFileState -p ActiveState -p SubState -p Result \
    -p NRestarts -p ExecMainStartTimestamp -p ExecMainStatus 2>/dev/null || true)"
unit_prop() { printf '%s\n' "$UNIT_PROPS" | sed -n "s/^$1=//p"; }

if [ -z "$UNIT_PROPS" ] || [ "$(unit_prop LoadState)" = "not-found" ]; then
    echo "Unit:        ${SERVICE} — not installed for this user."
    echo "→ Install it with ./scripts/50-service-install.sh"
else
    ACTIVE_STATE="$(unit_prop ActiveState)"
    NRESTARTS="$(unit_prop NRestarts)"
    STARTED="$(unit_prop ExecMainStartTimestamp)"

    echo "Unit:        ${SERVICE} ($(unit_prop UnitFileState))"
    echo "State:       ${ACTIVE_STATE} ($(unit_prop SubState))"
    [ -n "$STARTED" ] && echo "Started:     ${STARTED}"
    [ -n "$NRESTARTS" ] && echo "Restarts:    ${NRESTARTS}"

    # A unit that keeps failing spends most of its time in 'activating
    # (auto-restart)' rather than 'failed', so neither the state above nor a
    # zero exit status from `systemctl enable --now` says anything is wrong.
    # The restart counter is what does.
    RESULT="$(unit_prop Result)"
    if [ -n "$RESULT" ] && [ "$RESULT" != "success" ]; then
        echo "Result:      ${RESULT} (last exit status $(unit_prop ExecMainStatus))"
    fi
    if [ -n "$NRESTARTS" ] && [ "$NRESTARTS" != "0" ] || [ "$ACTIVE_STATE" = "failed" ]; then
        echo "→ The service is not running steadily. [status] Last Log Lines below"
        echo "  shows why it stopped; a repeating error there is a restart loop."
    fi
fi

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
