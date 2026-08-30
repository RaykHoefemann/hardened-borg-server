#!/bin/sh
#
# 21-check-timer-install.sh
# -------------------------
# Installs and enables the systemd timer that runs 20-check-repos.sh once a
# week -- Sunday 05:00 -- so that `borg check --repository-only` runs against
# every hosted repository on a schedule (docs/OPERATIONS.md). The mechanism
# scripts/50-service-install.sh and snapshots/71-timer-install.sh already use:
# this checkout's own REPO_ROOT is rendered into the service unit's ExecStart
# (the only value that varies between installations -- 20-check-repos.sh takes
# no arguments and resolves HOST_REPO_BASE via its own config.sh), then both
# units are installed as symlinks under ~/.config/systemd/user/, so a
# `git pull` that changes either unit is picked up without re-running this
# script.
#
# Installed under CHECK_TIMER_NAME (scripts/config.sh), not the fixed name
# "check-repos" -- a host running more than one instance of this tooling
# installs every instance's units into the same shared
# ~/.config/systemd/user/ directory, and a fixed name would let a second
# install silently overwrite the first instance's timer.
#
# Usage:
#   ./scripts/21-check-timer-install.sh
#
# This installs a rootless USER timer, the same kind of unit as the
# container's own service (DEPLOYMENT.md 6.2.1) -- it runs as this same
# operator user, not root, and needs NO sudo: 20-check-repos.sh reaches the
# repositories through `podman exec` into the running container, not through
# any privileged host command. One thing that is NOT set up by this script,
# deliberately:
#
#   - `loginctl enable-linger $USER`. Without it this user's systemd
#     instance, and therefore the timer, stops at logout -- the same
#     requirement 50-service-install.sh already documents for the container
#     service.
#
# Fedora CoreOS has no cron; systemd is the mechanism there (and this project
# already depends on it for the container service itself, so this is not an
# added requirement).
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

TIMER_UNIT="${REPO_ROOT}/scripts/check-repos.timer"
SERVICE_TEMPLATE="${REPO_ROOT}/scripts/check-repos.service"
RENDERED_SERVICE="${REPO_ROOT}/scripts/check-repos.service.rendered"
SCRIPT="${REPO_ROOT}/scripts/20-check-repos.sh"
SERVICE_DIR="$HOME/.config/systemd/user"
TIMER_NAME="${CHECK_TIMER_NAME}.timer"
SERVICE_NAME="${CHECK_TIMER_NAME}.service"

if [ ! -f "$TIMER_UNIT" ]; then
    echo "ERROR: Timer unit not found: $TIMER_UNIT"
    exit 1
fi
if [ ! -f "$SERVICE_TEMPLATE" ]; then
    echo "ERROR: Service unit template not found: $SERVICE_TEMPLATE"
    exit 1
fi
if [ ! -x "$SCRIPT" ]; then
    echo "ERROR: '$SCRIPT' is missing or not executable."
    exit 1
fi

echo "[install] Rendering $RENDERED_SERVICE from template"
sed "s|@@SCRIPT@@|${SCRIPT}|" "$SERVICE_TEMPLATE" > "$RENDERED_SERVICE"

echo "[install] Installing systemd units as symlinks..."
mkdir -p "$SERVICE_DIR"

for TARGET in "$SERVICE_DIR/$TIMER_NAME" "$SERVICE_DIR/$SERVICE_NAME"; do
    if [ -e "$TARGET" ]; then
        echo "[install] Removing old file $TARGET"
        rm -f "$TARGET"
    fi
done

ln -s "$TIMER_UNIT" "$SERVICE_DIR/$TIMER_NAME"
ln -s "$RENDERED_SERVICE" "$SERVICE_DIR/$SERVICE_NAME"

echo "[install] Symlinks created:"
echo "  $SERVICE_DIR/$TIMER_NAME -> $TIMER_UNIT"
echo "  $SERVICE_DIR/$SERVICE_NAME -> $RENDERED_SERVICE"

systemctl --user daemon-reload
systemctl --user enable --now "$TIMER_NAME"

echo "[install] Timer enabled: weekly repository check (Sunday 05:00) for CONTAINER=${CONTAINER}."
echo "→ Check schedule:  systemctl --user list-timers $TIMER_NAME"
echo "→ Check last run:  journalctl --user -u $SERVICE_NAME"
echo "→ Functional check: ./scripts/29-check-timer-status.sh"
echo "→ Run it manually right now (does not affect the schedule):"
echo "    systemctl --user start $SERVICE_NAME"
