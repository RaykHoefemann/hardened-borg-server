#!/bin/sh
#
# 72-timer-uninstall.sh
# ----------------------
# Reverses 71-timer-install.sh: disables and stops the systemd timer,
# removes its symlink and the rendered service unit's symlink from
# ~/.config/systemd/user/, and deletes the rendered service unit.
#
# Does NOT touch HOST_REPO_BASE, SNAPSHOT_BASE, or any snapshot already
# taken -- this only removes the schedule that creates new ones. Existing
# generations, and the tooling to list/delete/restore them (75-/76-/77-),
# are untouched and still work exactly as before; only 70-create-snapshot.sh
# stops running automatically.
#
# REFUSES rather than interrupts if a snapshot creation is currently
# running (snapshot-create.service in "activating" state -- Type=oneshot
# has no other state while its ExecStart is still executing). Unlike
# 51-service-uninstall.sh, which stops the long-running container service
# outright, `systemctl --user stop` here would send SIGTERM into the middle
# of 70-create-snapshot.sh's `sudo cp -a`/`sudo chattr` sequence for
# whichever client it is on, and -- because this script is about to remove
# the very timer that would otherwise clean up a stale `.creating-*` on its
# next firing -- any half-made staging directory left behind would have no
# future run left to find it. Safer to ask the operator to wait it out (or
# stop it themselves, deliberately) and run this again.
#
# Usage:
#   ./snapshots/72-timer-uninstall.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

SERVICE_DIR="$HOME/.config/systemd/user"
TIMER_NAME="snapshot-create.timer"
SERVICE_NAME="snapshot-create.service"
TIMER_LINK="$SERVICE_DIR/$TIMER_NAME"
SERVICE_LINK="$SERVICE_DIR/$SERVICE_NAME"
RENDERED_SERVICE="${REPO_ROOT}/snapshots/${SERVICE_NAME}.rendered"

SERVICE_STATE="$(systemctl --user show -p ActiveState --value "$SERVICE_NAME" 2>/dev/null || true)"
case "$SERVICE_STATE" in
    ""|inactive|failed) ;;
    *)
        echo "ERROR: $SERVICE_NAME is currently $SERVICE_STATE -- a snapshot run is"
        echo "       in progress. Stopping the timer now would interrupt it mid-copy,"
        echo "       and removing the timer in the same step leaves no future run to"
        echo "       clean up whatever it leaves half-made."
        echo "       Wait for it to finish (journalctl --user -u $SERVICE_NAME -f),"
        echo "       or stop it yourself if you understand the risk, then run this"
        echo "       script again."
        exit 1
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

echo "[uninstall] Timer uninstalled. No more scheduled snapshot creation."
echo "→ Left untouched: HOST_REPO_BASE, SNAPSHOT_BASE, and every snapshot"
echo "  generation already taken -- 75-/76-/77- still work on them normally."
echo "→ If you added a passwordless sudoers entry for unattended operation"
echo "  (see 70-create-snapshot.sh's own header), remove it by hand now if"
echo "  it is no longer needed."
