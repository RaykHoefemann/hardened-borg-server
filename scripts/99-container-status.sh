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
# Two questions, two pairs of lines, each pair printed together so that the
# comparison the report makes below can also be made by eye:
#
#   Host scripts / Running version — which RELEASE is installed and which one is
#                    serving. The host half of a release is these scripts, which
#                    the container image does not carry, so neither figure
#                    answers it alone.
#   Configured image / Running image — which OBJECT is configured and which one
#                    the running container was actually started from. A digest
#                    pin makes these two the only figures that speak about
#                    content: a version cannot distinguish two builds of one
#                    release, and cannot see an edited pin at all until
#                    something restarts.
#
# The second pair used to be a reference on one side and a version on the other,
# which is why nothing here noticed an edited pin — see the note under check 0C
# in docs/VERIFICATION.md.
echo "Host scripts:     ${RELEASE_VERSION}"

# What the RUNNING container reports about itself. One exec rather than three,
# and empty throughout if the container is not running.
#
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

# podman's own record of the reference the container was given — not something
# the image reports about itself, and the only value here that survives a digest
# pin as a statement about content. The Quadlet creates a fresh container per
# start and removes it on stop (OPERATIONS.md chapter 9.11), so this is empty
# for the same reason RUNNING_VERSION is: nothing is running.
RUNNING_IMAGE_REF="$(podman inspect "$CONTAINER" --format '{{.ImageName}}' 2>/dev/null || true)"

[ -n "$RUNNING_VERSION" ]   && echo "Running version:  ${RUNNING_VERSION}"
echo "Configured image: ${IMAGE}"
[ -n "$RUNNING_IMAGE_REF" ] && echo "Running image:    ${RUNNING_IMAGE_REF}"
[ -n "$RUNNING_BORG" ]      && echo "Bundled borg:     ${RUNNING_BORG}"
[ -n "$RUNNING_DEBIAN" ]    && echo "Base OS:          Debian ${RUNNING_DEBIAN}"
echo "Source:           ${SOURCE_URL}"

# IMAGE is what the NEXT start would use; ImageName is what this one did use.
# The two part company in one very ordinary way — IMAGE edited, nothing
# restarted — and no comparison of *versions* can see it. The check below leaves
# both of its operands untouched in that state: the container has not changed,
# and neither has the VERSION file in the checkout. A rebuild of a single
# release makes it worse still, carrying the same VERSION under a different
# digest. So this compares references, which is what verification check 0C does
# by hand (docs/VERIFICATION.md) and the only comparison that answers "is the
# object serving clients the one this installation configures".
#
# With a tag in IMAGE the comparison still runs and still catches a pending
# restart, but agreement proves much less than it looks: both sides then name a
# name, and a name can be re-pointed at other content (check 0B).
if [ -n "$RUNNING_IMAGE_REF" ] && [ "$RUNNING_IMAGE_REF" != "$IMAGE" ]; then
    echo
    echo "→ PIN MISMATCH: the running container was not started from IMAGE."
    echo "  The two image lines above name different objects, so the checkout,"
    echo "  the unit and this configuration all describe an image that is not"
    echo "  serving anyone. Reinstall the Quadlet, then restart:"
    echo "      ./scripts/50-service-install.sh"
    echo "      ./scripts/92-container-restart.sh"
    echo "  Both steps, in that order: the generated unit reads IMAGE from the"
    echo "  drop-in the install script writes, so restarting on its own starts"
    echo "  the old image again (DEPLOYMENT.md chapter 6.3, step 7)."
fi

if [ "$RELEASE_VERSION" = "unknown" ]; then
    echo
    echo "→ No VERSION file found. This tree was not installed from a release"
    echo "  tag (see docs/SERVERINSTALL.md step 1)."
elif [ -n "$RUNNING_VERSION" ] && [ "$RUNNING_VERSION" != "$RELEASE_VERSION" ]; then
    echo
    echo "→ MISMATCH: host scripts are ${RELEASE_VERSION}, the running container"
    echo "  is ${RUNNING_VERSION}. The two halves of a release are meant to match."
    echo "  With a PIN MISMATCH above, the restart is what is missing. Without"
    echo "  one, the container is running the configured image and IMAGE itself"
    echo "  names a different release than the checkout these scripts came from."
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
