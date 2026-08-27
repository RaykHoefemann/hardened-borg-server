#!/bin/sh
#
# 79-timer-status.sh
# -------------------
# Shows whether the snapshot-creation timer and service (SNAPSHOT_TIMER_NAME,
# snapshots/config.sh) are actually functional -- installed, scheduled, and
# last known to have succeeded -- not just "installed" the way `systemctl
# --user list-timers` alone would show it. Mirrors scripts/99-container-
# status.sh for the timer/service half of this project.
#
# Usage:
#   ./snapshots/79-timer-status.sh
#
# WHY THIS IS A DIFFERENT SHAPE THAN 99-container-status.sh. The container's
# unit is a long-running daemon: ActiveState=active means "currently serving,
# right now". snapshot-create.service is a Type=oneshot, triggered once a
# day -- ActiveState=inactive between runs is the NORMAL state, not a
# problem, and checking it the way 99- checks the container would report a
# healthy installation as broken every hour of every day but the one it
# fires in. What actually answers "is this working" here is three different
# questions: is the TIMER enabled and scheduled to fire again; did the LAST
# run of the SERVICE succeed; and -- the one failure mode with no equivalent
# on the container side -- can `70-create-snapshot.sh`'s `sudo cp`/`chattr`/
# `rm` calls actually run unattended at all, since a systemd timer has no
# terminal to answer a password prompt on (see that script's own PRIVILEGES
# section, and docs/SNAPSHOTS.md "Privileges").
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

TIMER_NAME="${SNAPSHOT_TIMER_NAME}.timer"
SERVICE_NAME="${SNAPSHOT_TIMER_NAME}.service"

echo "------------------------------------------------------------"
echo "[status] Timer Schedule"
echo "------------------------------------------------------------"

TIMER_PROPS="$(systemctl --user show "$TIMER_NAME" \
    -p LoadState -p UnitFileState -p ActiveState -p SubState \
    -p NextElapseUSecRealtime -p LastTriggerUSec 2>/dev/null || true)"
timer_prop() { printf '%s\n' "$TIMER_PROPS" | sed -n "s/^$1=//p"; }

TIMER_OK=1
if [ -z "$TIMER_PROPS" ] || [ "$(timer_prop LoadState)" = "not-found" ]; then
    echo "Timer:       ${TIMER_NAME} — not installed for this user."
    echo "→ Install it with ./snapshots/71-timer-install.sh"
    TIMER_OK=""
else
    TIMER_ACTIVE="$(timer_prop ActiveState)"
    TIMER_ENABLED="$(timer_prop UnitFileState)"
    NEXT="$(timer_prop NextElapseUSecRealtime)"
    LAST="$(timer_prop LastTriggerUSec)"

    echo "Timer:       ${TIMER_NAME} (${TIMER_ENABLED})"
    echo "State:       ${TIMER_ACTIVE} ($(timer_prop SubState))"
    [ -n "$NEXT" ] && echo "Next run:    ${NEXT}"
    [ -n "$LAST" ] && [ "$LAST" != "0" ] && echo "Last run:    ${LAST}"

    # Scheduled to fire again is decided on ActiveState alone, deliberately
    # NOT on UnitFileState: these units are installed as plain symlinks
    # (71-timer-install.sh), the same way scripts/50-service-install.sh
    # installs the container's unit, and systemd reports that as
    # UnitFileState=alias rather than "enabled" even while the timer is
    # genuinely active and will fire -- confirmed against a real deployment
    # (FCOS-BorgBackupServer, 2026-08-27); gating on "enabled" reported this
    # exact, correctly-scheduled state as broken. UnitFileState is still
    # printed above, for the same reason 99-container-status.sh prints it:
    # informational, not a pass/fail signal on its own.
    #
    # A disabled or inactive timer never fires again on its own -- silently,
    # since nothing about "70-create-snapshot.sh ran fine every day for a
    # month" tells you the day it stopped being scheduled at all. This is
    # the one check on this page that stands in for `systemctl --user
    # list-timers`, which shows the same thing but only for timers that are
    # still listed -- a disabled timer drops out of that list entirely
    # rather than showing up as a problem in it.
    if [ "$TIMER_ACTIVE" != "active" ]; then
        echo "→ NOT SCHEDULED: this timer will not fire on its own. Re-enable it"
        echo "  with ./snapshots/71-timer-install.sh, or if that is deliberate"
        echo "  (e.g. before running ./snapshots/72-timer-uninstall.sh), ignore this."
        TIMER_OK=""
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Last Snapshot Run"
echo "------------------------------------------------------------"

SERVICE_PROPS="$(systemctl --user show "$SERVICE_NAME" \
    -p LoadState -p ActiveState -p SubState -p Result \
    -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus \
    2>/dev/null || true)"
service_prop() { printf '%s\n' "$SERVICE_PROPS" | sed -n "s/^$1=//p"; }

RUN_OK=1
if [ -z "$SERVICE_PROPS" ] || [ "$(service_prop LoadState)" = "not-found" ]; then
    echo "Service:     ${SERVICE_NAME} — not installed for this user."
    RUN_OK=""
else
    RESULT="$(service_prop Result)"
    STARTED="$(service_prop ExecMainStartTimestamp)"
    FINISHED="$(service_prop ExecMainExitTimestamp)"
    EXIT_STATUS="$(service_prop ExecMainStatus)"

    echo "Service:     ${SERVICE_NAME}"
    # Result, not the Exec* timestamps, is the "has this run at all" signal:
    # a run started automatically by the timer's own Persistent=true catch-up
    # (71-timer-install.sh) leaves ExecMainStartTimestamp/ExecMainExitTimestamp
    # empty even though Result and ExecMainStatus are populated correctly --
    # confirmed against a real deployment (FCOS-BorgBackupServer, 2026-08-27),
    # where a manually-started run populated every property but a
    # catch-up-triggered run left the timestamps blank. Gating on STARTED
    # reported that exact successful run as "never run". The timestamps are
    # still printed when available, since a manual/normal run does have them.
    if [ -z "$RESULT" ]; then
        echo "Last run:    never (no run recorded yet for this installation)"
    else
        echo "Result:      ${RESULT}$( [ -n "$EXIT_STATUS" ] && echo " (exit status ${EXIT_STATUS})" )"
        [ -n "$STARTED" ] && echo "Started:     ${STARTED}"
        [ -n "$FINISHED" ] && echo "Finished:    ${FINISHED}"

        # Result=success means 70-create-snapshot.sh's own exit status was 0,
        # i.e. every client it found was snapshotted successfully that run --
        # not merely that systemd did not kill the unit. A partial failure
        # (one client's cp/chattr failing, see 70-'s own header) is exactly
        # what this catches and ActiveState alone would not: the unit still
        # reaches "inactive" either way, since Type=oneshot has no notion of
        # "degraded".
        if [ "$RESULT" != "success" ]; then
            echo "→ LAST RUN FAILED: at least one client was not snapshotted that run."
            echo "  See [status] Last Log Lines below for which one and why."
            RUN_OK=""
        fi
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Unattended Sudo"
echo "------------------------------------------------------------"

# Unattended firing needs passwordless sudo for the specific commands
# 70-create-snapshot.sh elevates (cp, chattr, rm -- see that script's own
# PRIVILEGES section and docs/SNAPSHOTS.md "Privileges"); this is not scoped
# to exactly those three, it is the same operator-facing question
# 71-timer-install.sh's own header already raises and deliberately does not
# configure on your behalf. `sudo -n` never prompts -- it fails immediately
# if a password would have been required, which is exactly the failure mode
# a timer with no terminal hits.
SUDO_OK=1
if sudo -n true 2>/dev/null; then
    echo "Passwordless sudo: yes (sudo -n true succeeded)"
else
    echo "Passwordless sudo: NO — sudo would prompt for a password here."
    echo "→ A systemd timer has no terminal to answer that prompt on: the next"
    echo "  scheduled run will hang until it times out, then fail. See"
    echo "  70-create-snapshot.sh's own header (PRIVILEGES) and"
    echo "  docs/SNAPSHOTS.md (\"Privileges\") for exactly which commands need a"
    echo "  passwordless sudoers entry, and why this project does not write"
    echo "  one for you."
    SUDO_OK=""
fi

echo
echo "------------------------------------------------------------"
echo "[status] Last Log Lines"
echo "------------------------------------------------------------"
journalctl --user -u "$SERVICE_NAME" -n 20 --no-pager 2>&1 || true

echo
if [ -n "$TIMER_OK" ] && [ -n "$RUN_OK" ] && [ -n "$SUDO_OK" ]; then
    echo "[status] Functional: scheduled, last run succeeded, sudo is unattended-ready."
else
    echo "[status] NOT fully functional -- see the → lines above."
fi
echo "------------------------------------------------------------"
