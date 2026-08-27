#!/bin/sh
#
# 71-timer-install.sh
# --------------------
# Installs and enables the systemd timer that runs 70-create-snapshot.sh
# once a day at 03:00 (docs/SNAPSHOTS.md). The mechanism scripts/50-
# service-install.sh already uses for the container: this checkout's own
# REPO_ROOT is rendered into the service unit's ExecStart (the only value
# that varies between installations -- 70-create-snapshot.sh itself takes
# no arguments and resolves HOST_REPO_BASE/SNAPSHOT_BASE via its own
# config.sh), then both units are installed as symlinks under
# ~/.config/systemd/user/, same as 50-service-install.sh does, so a
# `git pull` that changes either unit is picked up without re-running this
# script.
#
# Installed under SNAPSHOT_TIMER_NAME (snapshots/config.sh), not the fixed
# name "snapshot-create" -- a host running more than one instance of this
# tooling installs every instance's units into the same shared
# ~/.config/systemd/user/ directory, and a fixed name would let a second
# install silently overwrite the first instance's timer.
#
# Usage:
#   ./snapshots/71-timer-install.sh
#
# This installs a rootless USER timer, the same kind of unit as the
# container's own service (DEPLOYMENT.md 6.2.1) -- it runs as this
# same operator user, not root. Two things that are NOT set up by this
# script, both deliberate:
#
#   - Passwordless sudo for `cp` and `chattr`. 70-create-snapshot.sh's own
#     `sudo cp`/`sudo chattr` calls need a sudoers entry that does not
#     prompt, since a systemd timer has no terminal to answer one on (see
#     that script's own header for exactly which commands). This is a host
#     security decision for the operator to make deliberately -- not
#     something to write to /etc/sudoers.d/ silently on their behalf.
#   - `loginctl enable-linger $USER`. Without it this user's systemd
#     instance, and therefore the timer, stops at logout -- the same
#     requirement 50-service-install.sh already documents for the
#     container service.
#
# Fedora CoreOS has no cron; systemd is the mechanism there (and this
# project already depends on it for the container service itself, so this
# is not an added requirement).
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

TIMER_UNIT="${REPO_ROOT}/snapshots/snapshot-create.timer"
SERVICE_TEMPLATE="${REPO_ROOT}/snapshots/snapshot-create.service"
RENDERED_SERVICE="${REPO_ROOT}/snapshots/snapshot-create.service.rendered"
SCRIPT="${REPO_ROOT}/snapshots/70-create-snapshot.sh"
SERVICE_DIR="$HOME/.config/systemd/user"
TIMER_NAME="${SNAPSHOT_TIMER_NAME}.timer"
SERVICE_NAME="${SNAPSHOT_TIMER_NAME}.service"

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

echo "[install] Timer enabled: daily snapshot creation at 03:00 for CONTAINER=${CONTAINER}."
echo "→ Check schedule:  systemctl --user list-timers $TIMER_NAME"
echo "→ Check last run:  journalctl --user -u $SERVICE_NAME"
echo "→ Run it manually right now (does not affect the schedule):"
echo "    systemctl --user start $SERVICE_NAME"
