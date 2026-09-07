#!/bin/sh
#
# 21-check-timer-install.sh
# -------------------------
# Installs and enables the systemd timer that runs the self-balancing sweep
# once a day at 05:00 (docs/OPERATIONS.md 9.13). The mechanism
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

mkdir -p "$SERVICE_DIR"

# Refuse to clobber another installation's timer/service units.
#
# Both are namespaced by CHECK_TIMER_NAME (scripts/config.sh), but two
# checkouts that forgot to give the second a distinct name would both
# resolve to the same $SERVICE_DIR/$TIMER_NAME and $SERVICE_DIR/$SERVICE_NAME
# -- a plain install would silently replace the first checkout's units, and
# because ExecStart embeds that checkout's own REPO_ROOT, the daily sweep
# would end up running the wrong scripts under the second checkout's name.
# Fail loudly instead, the same check 50-service-install.sh already applies
# to the Quadlet: if the symlink is already here and does NOT point at this
# checkout's own file, it belongs to another installation.
check_not_foreign() {
    TARGET="$1"; SOURCE="$2"
    if [ -L "$TARGET" ]; then
        EXISTING_TARGET="$(readlink -f "$TARGET" 2>/dev/null || true)"
        SOURCE_REAL="$(readlink -f "$SOURCE" 2>/dev/null || echo "$SOURCE")"
        if [ "$EXISTING_TARGET" != "$SOURCE_REAL" ]; then
            echo "ERROR: '$TARGET' already exists and points at"
            echo "       '${EXISTING_TARGET:-<unresolvable>}', not this checkout's"
            echo "       '$SOURCE_REAL'."
            echo "       CHECK_TIMER_NAME='${CHECK_TIMER_NAME}' is already in use by"
            echo "       another installation of this project on this host. Give this"
            echo "       one a distinct CHECK_TIMER_NAME in config.sh, or run"
            echo "       ./scripts/22-check-timer-uninstall.sh from the other checkout"
            echo "       first."
            exit 1
        fi
    elif [ -e "$TARGET" ]; then
        echo "ERROR: '$TARGET' exists but is not a symlink this script wrote."
        echo "       Something placed it by hand. Move it aside and re-run."
        exit 1
    fi
}

check_not_foreign "$SERVICE_DIR/$TIMER_NAME" "$TIMER_UNIT"
check_not_foreign "$SERVICE_DIR/$SERVICE_NAME" "$RENDERED_SERVICE"

echo "[install] Installing systemd units as symlinks..."
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

echo "[install] Timer enabled: daily self-balancing sweep (05:00) for CONTAINER=${CONTAINER}."
echo "→ Check schedule:  systemctl --user list-timers $TIMER_NAME"
echo "→ Check last run:  journalctl --user -u $SERVICE_NAME"
echo "→ Functional check: ./scripts/29-check-timer-status.sh"
echo "→ Run it manually right now (does not affect the schedule):"
echo "    systemctl --user start $SERVICE_NAME"
