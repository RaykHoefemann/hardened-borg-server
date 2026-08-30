#!/bin/sh
#
# 29-check-timer-status.sh
# ------------------------
# Shows whether the repository-check timer and service (CHECK_TIMER_NAME,
# scripts/config.sh) are actually functional -- installed, scheduled, and last
# known to have succeeded -- not just "installed" the way `systemctl --user
# list-timers` alone would show it. Mirrors snapshots/79-timer-status.sh.
#
# scripts/99-container-status.sh calls this at the end of its own report, so a
# single `./scripts/99-container-status.sh` covers the container and the check
# schedule together.
#
# Usage:
#   ./scripts/29-check-timer-status.sh
#
# SIMPLER THAN 79-. There is no "unattended sudo" section: 20-check-repos.sh
# needs no sudo -- it reaches the repositories through `podman exec` into the
# running container. In its place is a check that the container is actually up,
# since a scheduled run can do nothing without it.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

TIMER_NAME="${CHECK_TIMER_NAME}.timer"
SERVICE_NAME="${CHECK_TIMER_NAME}.service"

# Same knobs and log 20-check-repos.sh uses, so the coverage section below does
# the same budget / staleness arithmetic.
CHECK_LOG="${HOST_LOG_BASE}/check-repos.log"
CHECK_CYCLE_DIVISOR="${CHECK_CYCLE_DIVISOR:-6}"
CHECK_STALE_DAYS="${CHECK_STALE_DAYS:-9}"
CHECK_MAX_RUNTIME="${CHECK_MAX_RUNTIME:-3600}"

# _flog <client>  ->  "<last-any-epoch> <last-full-epoch> <last-duration-s>"
_flog() {
    [ -f "$CHECK_LOG" ] || { echo "0 0 0"; return; }
    awk -F'	' -v c="$1" '
        $3 == c {
            if ($1 + 0 > any)   any = $1 + 0
            if ($6 == "ok" && $1 + 0 > full) full = $1 + 0
            if ($1 + 0 >= lastep) { lastep = $1 + 0; dur = $5 + 0 }
        }
        END { printf "%d %d %d\n", any, full, dur }
    ' "$CHECK_LOG" 2>/dev/null
}

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
    echo "→ Install it with ./scripts/21-check-timer-install.sh"
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

    # "Scheduled to fire again" is decided on ActiveState alone, deliberately
    # NOT on UnitFileState: these units are installed as plain symlinks
    # (21-check-timer-install.sh), the same way scripts/50-service-install.sh
    # installs the container's unit, and systemd reports that as
    # UnitFileState=alias rather than "enabled" even while the timer is
    # genuinely active and will fire -- the same behaviour snapshots/79- had to
    # account for. UnitFileState is still printed above, informationally.
    if [ "$TIMER_ACTIVE" != "active" ]; then
        echo "→ NOT SCHEDULED: this timer will not fire on its own. Re-enable it"
        echo "  with ./scripts/21-check-timer-install.sh, or if that is deliberate"
        echo "  (e.g. before running ./scripts/22-check-timer-uninstall.sh), ignore this."
        TIMER_OK=""
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Last Check Run"
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
    # "Has this run at all?" cannot be read from Result alone: systemd reports
    # Result=success / ExecMainStatus=0 for a oneshot service that has been
    # loaded (21-check-timer-install.sh's daemon-reload + enable) but never
    # executed -- verified on the VM, 2026-08-30. What separates "never ran"
    # from "a Persistent=true catch-up ran" (which also leaves ExecMain*
    # timestamps empty) is the TIMER's LastTriggerUSec: 0/empty until the timer
    # has actually fired once. snapshots/79- keys on Result alone and has the
    # same latent gap; worth syncing there in a follow-up.
    if [ -z "$RESULT" ] || { [ "$RESULT" = "success" ] && [ -z "$STARTED" ] && { [ -z "${LAST:-}" ] || [ "${LAST:-0}" = "0" ]; }; }; then
        echo "Last run:    never (no run recorded yet for this installation)"
        echo "→ The timer is scheduled but has not fired yet. Run one now to confirm"
        echo "  it works: systemctl --user start ${SERVICE_NAME}"
        RUN_OK=""
    else
        echo "Result:      ${RESULT}$( [ -n "$EXIT_STATUS" ] && echo " (exit status ${EXIT_STATUS})" )"
        [ -n "$STARTED" ] && echo "Started:     ${STARTED}"
        [ -n "$FINISHED" ] && echo "Finished:    ${FINISHED}"

        # Result=success means 20-check-repos.sh's own exit status was 0, i.e.
        # every repository it found came back clean that run -- not merely that
        # systemd did not kill the unit. A repository reporting corruption, a
        # lock it could not take, or the container being down all make
        # 20-check-repos.sh exit 1, which surfaces here as Result != success.
        if [ "$RESULT" != "success" ]; then
            echo "→ LAST RUN DID NOT COME BACK CLEAN: at least one repository was not"
            echo "  checked, or was checked and reported a problem. See [status] Last"
            echo "  Log Lines below for which one and why."
            RUN_OK=""
        fi
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Container"
echo "------------------------------------------------------------"

# 20-check-repos.sh runs `borg check` inside the container via `podman exec`;
# with the container down, every scheduled run exits early having checked
# nothing. This is the equivalent of 79-'s "unattended sudo" section -- the one
# environmental prerequisite a timer with no terminal cannot arrange for
# itself.
CONTAINER_OK=1
if systemctl --user is-active --quiet "$SERVICE"; then
    echo "Container:    ${SERVICE} is active -- 'podman exec' can reach borg."
else
    echo "Container:    ${SERVICE} is NOT active."
    echo "→ A scheduled check cannot run: 20-check-repos.sh reaches borg through"
    echo "  'podman exec' into the running container. Start it with"
    echo "  ./scripts/90-container-start.sh"
    CONTAINER_OK=""
fi

echo
echo "------------------------------------------------------------"
echo "[status] Coverage (check-repos.log)"
echo "------------------------------------------------------------"

# What the self-balancing sweep has actually got through: the per-repository
# "last full check" ages from HOST_LOG_BASE/check-repos.log, against
# CHECK_STALE_DAYS and the daily budget. A repository never fully checked is
# "awaiting its first check" (first in line), not stale; one whose last full
# check is older than CHECK_STALE_DAYS means the sweep is behind.
COV_OK=1
if [ ! -f "$CHECK_LOG" ]; then
    echo "Log:         $CHECK_LOG — none yet. The sweep has not run."
    COV_OK=""
else
    NOW="$(date +%s)"
    _n=0 _totkib=0 _never=0 _stale=0
    _oldest_u="" _oldest_age=-1
    for _d in "${HOST_REPO_BASE%/}"/*; do
        [ -d "$_d" ] || continue
        _u="$(basename "$_d")"
        case "$_u" in ''|-*|*[!a-zA-Z0-9_-]*) continue ;; esac
        _n=$((_n + 1))
        _kib="$(quota_used_kib "$_d")"
        case "$_kib" in ''|*[!0-9]*) _kib=0 ;; esac
        _lim="$(quota_enforced_kib "$_d")"
        _vol="$(volume_kib)"
        [ -n "$_lim" ] && [ "$_lim" = "${_vol:-x}" ] && _kib=0
        _totkib=$((_totkib + _kib))
        # shellcheck disable=SC2046
        set -- $(_flog "$_u")
        if [ "${2:-0}" -eq 0 ]; then
            _never=$((_never + 1))
            continue
        fi
        _age=$(( (NOW - $2) / 86400 ))
        if [ "$_age" -gt "$_oldest_age" ]; then _oldest_age="$_age"; _oldest_u="$_u"; fi
        [ "$_age" -ge "$CHECK_STALE_DAYS" ] && _stale=$((_stale + 1))
        if [ "${3:-0}" -gt "$CHECK_MAX_RUNTIME" ]; then
            echo "→ ${_u}: last check took ${3}s, over CHECK_MAX_RUNTIME (${CHECK_MAX_RUNTIME}s)."
            echo "  It cannot complete in one run on this store. Set CHECK_MAX_DURATION for"
            echo "  it, or use a snapshot-based check (OPERATIONS 9.13)."
            COV_OK=""
        fi
    done

    if [ "$_n" -eq 0 ]; then
        echo "Repositories: none under $HOST_REPO_BASE."
    else
        _budget=$((_totkib / CHECK_CYCLE_DIVISOR))
        [ "$_budget" -lt 1 ] && _budget=1
        echo "Repositories: ${_n}   Total size: $(quota_human "$_totkib")   Daily budget: $(quota_human "$_budget") (total/${CHECK_CYCLE_DIVISOR})"
        if [ -n "$_oldest_u" ]; then
            echo "Oldest full check: '${_oldest_u}', ${_oldest_age} day(s) ago (warn at ${CHECK_STALE_DAYS})."
        fi
        [ "$_never" -gt 0 ] && echo "Awaiting first check: ${_never} — first in line."
        if [ "$_stale" -gt 0 ]; then
            echo "→ ${_stale} repository/-ies have no full check within CHECK_STALE_DAYS (${CHECK_STALE_DAYS})."
            echo "  The sweep is falling behind: lower CHECK_CYCLE_DIVISOR, add a second"
            echo "  daily timer, or split the biggest repositories out (OPERATIONS 9.13)."
            COV_OK=""
        fi
    fi
fi

echo
echo "------------------------------------------------------------"
echo "[status] Last Log Lines"
echo "------------------------------------------------------------"
journalctl --user -u "$SERVICE_NAME" -n 20 --no-pager 2>&1 || true

echo
if [ -n "$TIMER_OK" ] && [ -n "$RUN_OK" ] && [ -n "$CONTAINER_OK" ] && [ -n "$COV_OK" ]; then
    echo "[status] Functional: scheduled, last run came back clean, container up, coverage current."
else
    echo "[status] NOT fully functional -- see the → lines above."
fi
echo "------------------------------------------------------------"
