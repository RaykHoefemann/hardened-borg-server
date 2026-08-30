#!/bin/sh
#
# 22-check-timer-uninstall.sh
# ---------------------------
# Reverses 21-check-timer-install.sh: disables and stops the systemd timer,
# removes its symlink and the rendered service unit's symlink from
# ~/.config/systemd/user/, and deletes the rendered service unit.
#
# Targets CHECK_TIMER_NAME (scripts/config.sh) -- the same CONTAINER-namespaced
# name 21- installs under -- so this only ever touches this installation's own
# timer, never a different container's instance of this tooling sharing the
# same ~/.config/systemd/user/ directory.
#
# Does NOT touch any repository. This only removes the schedule;
# 20-check-repos.sh still works exactly as before when run by hand, and no
# repository is modified by a `borg check --repository-only` in any case.
#
# Unlike snapshots/72-, this does NOT refuse while a run is in progress:
# `borg check --repository-only` is read-only and releases its lock when it
# exits, so a check interrupted mid-sweep leaves nothing half-made. Stopping
# the TIMER does not stop an already-running service anyway; if a run is
# active it is noted and left to finish on its own.
#
# Usage:
#   ./scripts/22-check-timer-uninstall.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

SERVICE_DIR="$HOME/.config/systemd/user"
TIMER_NAME="${CHECK_TIMER_NAME}.timer"
SERVICE_NAME="${CHECK_TIMER_NAME}.service"
TIMER_LINK="$SERVICE_DIR/$TIMER_NAME"
SERVICE_LINK="$SERVICE_DIR/$SERVICE_NAME"
RENDERED_SERVICE="${REPO_ROOT}/scripts/check-repos.service.rendered"

SERVICE_STATE="$(systemctl --user show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null || true)"
case "$SERVICE_STATE" in
    ""|inactive|failed) ;;
    *)
        echo "[uninstall] Note: $SERVICE_NAME is currently $SERVICE_STATE -- a check run is"
        echo "            in progress. It is read-only and will finish on its own;"
        echo "            removing the timer does not interrupt it."
        ;;
esac

if systemctl --user is-active --quiet "$TIMER_NAME" 2>/dev/null; then
    echo "[uninstall] Stopping $TIMER_NAME..."
    systemctl --user stop "$TIMER_NAME"
fi

if systemctl --user is-enabled --quiet "$TIMER_NAME" 2>/dev/null; then
    echo "[uninstall] Disabling $TIMER_NAME..."
    systemctl --user disable "$TIMER_NAME"
fi

for LINK in "$TIMER_LINK" "$SERVICE_LINK"; do
    if [ -e "$LINK" ]; then
        echo "[uninstall] Removing unit symlink $LINK"
        rm -f "$LINK"
    fi
done

systemctl --user daemon-reload

if [ -f "$RENDERED_SERVICE" ]; then
    echo "[uninstall] Removing rendered unit $RENDERED_SERVICE"
    rm -f "$RENDERED_SERVICE"
fi

echo "[uninstall] Timer uninstalled. No more scheduled repository checks."
echo "→ Left untouched: every repository, and 20-check-repos.sh itself -- run it"
echo "  by hand any time (./scripts/20-check-repos.sh [<client>])."
