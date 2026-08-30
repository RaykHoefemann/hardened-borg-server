#!/usr/bin/env bash
#
# tests/check-repos-scripts.sh
# ----------------------------
# Behavioural tests for the repository-check tooling under scripts/:
# 20-check-repos.sh (the sweep, its result-state classification and exit
# aggregation) and its systemd timer companions 21-check-timer-install.sh,
# 22-check-timer-uninstall.sh and 29-check-timer-status.sh.
#
# Not a substitute for docs/VERIFICATION.md section 13, whose checks are
# measured against a real deployment with a real container, a real borg and
# a genuinely corrupted segment -- none of which a GitHub-hosted runner can
# reproduce. What THIS file adds is automated, on-every-push coverage of the
# logic around the borg call: argument validation, client discovery, the
# lock, the "container is down" guard, and the FULL / PARTIAL / lock-timeout
# / structural-damage / exec-failure classification -- checked with a fake
# `podman` that stands in for `borg check` and the same fake `systemctl`
# tests/snapshot-scripts.sh already uses for 71-/72-/79-.
#
# Requires: bash.
# Usage:    tests/check-repos-scripts.sh
#
# shellcheck disable=SC2319
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
OUT=""; RC=0; T=""

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n       rc=%s\n       output:\n%s\n' \
        "$1" "$RC" "$(printf '%s' "$OUT" | sed 's/^/         /')"; }
assert() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ============================================================================
# Fixture: a throwaway installation tree, config.sh pointed at it
# ============================================================================
#
# HOST_STORAGE_BASE + CONTAINER derive HOST_REPO_BASE (repository root
# config.sh); REPO_ROOT is resolved from $0, so HOST_LOG_BASE and
# CHECK_TIMER_NAME follow the fixture automatically. Same technique as
# tests/snapshot-scripts.sh.
new_check_tree() {
    T="$WORK/tree$RANDOM$RANDOM"
    mkdir -p "$T/scripts" "$T/storage/repo" "$T/home/.config/systemd/user"
    cp "$ROOT/config.sh" "$T/config.sh"
    cp "$ROOT/VERSION" "$T/VERSION" 2>/dev/null || echo "0.0.0-test" > "$T/VERSION"
    cp "$ROOT/scripts/config.sh" "$T/scripts/config.sh"
    cp "$ROOT/scripts/lib.sh" "$T/scripts/lib.sh"
    cp "$ROOT/scripts/20-check-repos.sh" \
       "$ROOT/scripts/21-check-timer-install.sh" \
       "$ROOT/scripts/22-check-timer-uninstall.sh" \
       "$ROOT/scripts/29-check-timer-status.sh" "$T/scripts/"
    cp "$ROOT/scripts/check-repos.timer" "$ROOT/scripts/check-repos.service" "$T/scripts/"
    chmod +x "$T"/scripts/*.sh
    sed -i "s|^HOST_STORAGE_BASE=.*|HOST_STORAGE_BASE=\"$T/storage\"|" "$T/config.sh"
    sed -i 's|^CONTAINER=.*|CONTAINER="repo"|' "$T/config.sh"
    HRB="$T/storage/repo"
    LOGDIR="$T/log"
    UNIT_DIR="$T/home/.config/systemd/user"
    TIMER_NAME="check-repos_repo.timer"
    SERVICE_NAME="check-repos_repo.service"
    CONTAINER_UNIT="repo.service"                 # ${CONTAINER}.service
    RENDERED="$T/scripts/check-repos.service.rendered"
}

mkclient() { mkdir -p "$HRB/$1"; echo "payload for $1" > "$HRB/$1/config"; }

# ============================================================================
# Stubs: podman (stands in for `borg check`), systemctl, journalctl
# ============================================================================
STUB="$WORK/stubs"
mkdir -p "$STUB"

# `podman exec ... borg check --repository-only [--max-duration N] /repo/<c>`
# The full command line is logged to $PODMAN_LOG so a test can assert which
# repositories were reached and whether --max-duration was passed. The
# outcome per client is $BORG_STATE_DIR/<client> if present, else $BORG_RESULT,
# else "full":
#   full     -> "Finished full repository check, no problems found."   rc 0
#   partial  -> "... partial repository check ..."                     rc 0
#   damage   -> an integrity error                                     rc 2
#   lock     -> "Failed to create/acquire the lock"                    rc 2
#   execfail -> podman exec itself fails                               rc 125
cat > "$STUB/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "${PODMAN_LOG:-/dev/null}"
[ "$1" = "exec" ] || exit 0
repo=""
for a in "$@"; do case "$a" in /repo/*) repo="$a" ;; esac; done
client="${repo##*/}"
state="${BORG_RESULT:-full}"
[ -n "$client" ] && [ -f "${BORG_STATE_DIR:-/nonexistent}/$client" ] && state="$(cat "$BORG_STATE_DIR/$client")"
case "$state" in
    full)
        echo "Starting repository check"
        echo "Finished full repository check, no problems found."
        exit 0 ;;
    partial)
        echo "Starting repository check"
        echo "Finished partial repository check, first segment checked is 3, last is 41."
        exit 0 ;;
    damage)
        echo "Starting repository check"
        echo "Index mismatch for key b'...'. wanted (1, 2), got (3, 4)"
        echo "Data integrity error: Object id ... not found."
        exit 2 ;;
    lock)
        echo "Failed to create/acquire the lock /repo/... (timeout)." >&2
        exit 2 ;;
    execfail)
        echo "Error: can only create exec sessions on running containers" >&2
        exit 125 ;;
    *) exit 0 ;;
esac
EOF

cat > "$STUB/journalctl" <<'EOF'
#!/bin/sh
echo "-- no journal entries in this fixture --"
exit 0
EOF

# The exact subset of "systemctl --user ..." 20-/21-/22-/29- use. Copied from
# tests/snapshot-scripts.sh -- state lives in $SYSTEMCTL_STATE/<unit>, one
# KEY=VALUE per line; a unit with no file behaves like one systemd never
# heard of (LoadState=not-found, every other property empty).
cat > "$STUB/systemctl" <<'EOF'
#!/bin/sh
[ "$1" = "--user" ] || { echo "systemctl stub: expected --user first" >&2; exit 1; }
shift
cmd="$1"; shift

state_file() { echo "${SYSTEMCTL_STATE:?}/$1"; }
set_prop() {
    f="$(state_file "$1")"
    mkdir -p "$(dirname "$f")"
    : > "$f.tmp"
    [ -f "$f" ] && grep -v "^$2=" "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    echo "$2=$3" >> "$f"
}
get_prop() {
    f="$(state_file "$1")"
    [ -f "$f" ] || return 1
    sed -n "s/^$2=//p" "$f" | tail -1
}

case "$cmd" in
    daemon-reload) exit 0 ;;
    enable)
        now=0 unit=""
        for a in "$@"; do case "$a" in --now) now=1 ;; *) unit="$a" ;; esac; done
        set_prop "$unit" LoadState loaded
        set_prop "$unit" UnitFileState alias
        if [ "$now" = 1 ]; then
            set_prop "$unit" ActiveState active
            set_prop "$unit" SubState waiting
        fi
        exit 0 ;;
    disable) set_prop "$1" UnitFileState disabled; exit 0 ;;
    stop)
        set_prop "$1" ActiveState inactive
        set_prop "$1" SubState dead
        exit 0 ;;
    is-active)
        unit=""
        for a in "$@"; do case "$a" in --quiet) ;; *) unit="$a" ;; esac; done
        [ "$(get_prop "$unit" ActiveState 2>/dev/null)" = "active" ] && exit 0
        exit 3 ;;
    is-enabled)
        unit=""
        for a in "$@"; do case "$a" in --quiet) ;; *) unit="$a" ;; esac; done
        v="$(get_prop "$unit" UnitFileState 2>/dev/null)"
        case "$v" in enabled|alias|static|linked*) exit 0 ;; *) exit 1 ;; esac ;;
    show)
        unit="" props="" value=0
        while [ $# -gt 0 ]; do
            case "$1" in
                -p) props="$props $2"; shift 2 ;;
                --value) value=1; shift ;;
                *) unit="$1"; shift ;;
            esac
        done
        f="$(state_file "$unit")"
        for p in $props; do
            if [ ! -f "$f" ]; then
                [ "$p" = "LoadState" ] && v="not-found" || v=""
            else
                v="$(sed -n "s/^$p=//p" "$f" | tail -1)"
            fi
            if [ "$value" = 1 ]; then printf '%s\n' "$v"
            else printf '%s=%s\n' "$p" "$v"; fi
        done
        exit 0 ;;
    *) exit 0 ;;
esac
EOF

chmod +x "$STUB"/*

seed_unit() { # seed_unit <unit> <KEY=value>...
    f="$SYSTEMCTL_STATE/$1"; shift
    : > "$f"
    for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}
set_borg() { printf '%s\n' "$2" > "$BORG_STATE_DIR/$1"; }   # set_borg <client> <state>

reset_env() {
    unset BORG_RESULT CHECK_MAX_DURATION CHECK_LOCK_WAIT CHECK_NICE
    export BORG_STATE_DIR="$WORK/borgstate"; rm -rf "$BORG_STATE_DIR"; mkdir -p "$BORG_STATE_DIR"
    export PODMAN_LOG="$WORK/podman.log"; : > "$PODMAN_LOG"
    export SYSTEMCTL_STATE="$T/systemctl-state"; rm -rf "$SYSTEMCTL_STATE"; mkdir -p "$SYSTEMCTL_STATE"
    export HOME="$T/home"
    # The container is up unless a test says otherwise.
    seed_unit "$CONTAINER_UNIT" "LoadState=loaded" "ActiveState=active" "SubState=running"
}

run() { OUT="$(PATH="$STUB:$PATH" "$@" 2>&1)"; RC=$?; }

# ============================================================================
# 20. 20-check-repos.sh
# ============================================================================

new_check_tree; reset_env
run "$T/scripts/20-check-repos.sh" a b
[ "$RC" -ne 0 ]; assert "20.1 more than one argument is refused" $?

new_check_tree; reset_env
run "$T/scripts/20-check-repos.sh" ghost
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"no repository directory"* ]] && [[ "$OUT" == *"09-show-all-users.sh"* ]]; }
assert "20.2 a client with no directory on disk is refused, points at 09-" $?

new_check_tree; reset_env
mkclient client1
seed_unit "$CONTAINER_UNIT" "LoadState=loaded" "ActiveState=inactive"
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"not active"* ]] && [ ! -s "$PODMAN_LOG" ]; }
assert "20.3 with the container down, nothing is checked" $?

new_check_tree; reset_env
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"No client repositories found"* ]]; }
assert "20.4 no client directories at all is a clean no-op" $?

new_check_tree; reset_env
mkclient client1
mkclient client2
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -eq 0 ] \
  && [[ "$OUT" == *"client1: FULL pass"* ]] && [[ "$OUT" == *"client2: FULL pass"* ]] \
  && [[ "$OUT" == *"2/2 repositories came back clean"* ]]; }
assert "20.5 every client on disk is checked; all clean exits 0" $?

new_check_tree; reset_env
mkclient client1
mkclient client2
set_borg client1 damage
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] \
  && [[ "$OUT" == *"client1: failed"* ]] && [[ "$OUT" == *"problem with the repository structure"* ]] \
  && [[ "$OUT" == *"client2: ok"* ]] \
  && [[ "$OUT" == *"repositories need attention"* ]]; }
assert "20.6 a damaged repository is reported, the sweep still checks the rest, exit 1" $?

new_check_tree; reset_env
mkclient client1
set_borg client1 lock
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"lock could not be taken"* ]] && [[ "$OUT" == *"retry"* ]]; }
assert "20.7 a lock timeout is classified as 'could not check', not as damage" $?

new_check_tree; reset_env
mkclient client1
set_borg client1 execfail
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"podman exec"* ]] && [[ "$OUT" == *"did not run"* ]]; }
assert "20.8 a failed 'podman exec' (container gone mid-sweep) is its own message" $?

new_check_tree; reset_env
mkclient client1
set_borg client1 partial
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"client1: PARTIAL pass"* ]] && [[ "$OUT" == *"1/1 repositories came back clean"* ]]; }
assert "20.9 a time-boxed partial pass counts as clean, is labelled PARTIAL" $?

new_check_tree; reset_env
mkclient client1
mkclient client2
run "$T/scripts/20-check-repos.sh" client1
{ [ "$RC" -eq 0 ] && grep -q "/repo/client1" "$PODMAN_LOG" && ! grep -q "/repo/client2" "$PODMAN_LOG"; }
assert "20.10 a single-client run checks only that client" $?

new_check_tree; reset_env
mkclient client1
run "$T/scripts/20-check-repos.sh"
grep -q -- "--max-duration 3600" "$PODMAN_LOG"
assert "20.11 the default CHECK_MAX_DURATION is passed to borg check" $?

new_check_tree; reset_env
mkclient client1
export CHECK_MAX_DURATION=0
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -eq 0 ] && ! grep -q -- "--max-duration" "$PODMAN_LOG"; }
assert "20.12 CHECK_MAX_DURATION=0 drops --max-duration entirely" $?
unset CHECK_MAX_DURATION

new_check_tree; reset_env
mkclient client1
export CHECK_MAX_DURATION=abc
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"non-negative integer"* ]] && [ ! -s "$PODMAN_LOG" ]; }
assert "20.13 a non-numeric tuning knob is refused before anything runs" $?
unset CHECK_MAX_DURATION

new_check_tree; reset_env
mkclient client1
mkdir -p "$LOGDIR"
exec 8>"$LOGDIR/.check-repos.lock"
flock -n 8
run "$T/scripts/20-check-repos.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"still in progress"* ]] && [ ! -s "$PODMAN_LOG" ]; }
assert "20.14 a concurrent run is refused via the lock, nothing checked" $?
flock -u 8; exec 8>&-

# ============================================================================
# 21. 21-check-timer-install.sh
# ============================================================================

new_check_tree; reset_env
rm -f "$T/scripts/check-repos.timer"
run "$T/scripts/21-check-timer-install.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"Timer unit not found"* ]]; }
assert "21.1 a missing timer unit template is refused" $?

new_check_tree; reset_env
rm -f "$T/scripts/check-repos.service"
run "$T/scripts/21-check-timer-install.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"Service unit template not found"* ]]; }
assert "21.2 a missing service unit template is refused" $?

new_check_tree; reset_env
chmod -x "$T/scripts/20-check-repos.sh"
run "$T/scripts/21-check-timer-install.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"is missing or not executable"* ]]; }
assert "21.3 a missing or non-executable 20-check-repos.sh is refused" $?

new_check_tree; reset_env
run "$T/scripts/21-check-timer-install.sh"
{ [ "$RC" -eq 0 ] \
  && [ -L "$UNIT_DIR/$TIMER_NAME" ] \
  && [ "$(readlink "$UNIT_DIR/$TIMER_NAME")" = "$T/scripts/check-repos.timer" ] \
  && [ -L "$UNIT_DIR/$SERVICE_NAME" ] && [ "$(readlink "$UNIT_DIR/$SERVICE_NAME")" = "$RENDERED" ] \
  && grep -qF "$T/scripts/20-check-repos.sh" "$RENDERED" \
  && [ "$(sed -n 's/^ActiveState=//p' "$SYSTEMCTL_STATE/$TIMER_NAME")" = "active" ]; }
assert "21.4 a clean install symlinks both units, renders @@SCRIPT@@, enables --now" $?

new_check_tree; reset_env
run "$T/scripts/21-check-timer-install.sh"
run "$T/scripts/21-check-timer-install.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Removing old file"* ]] \
  && [ -L "$UNIT_DIR/$TIMER_NAME" ] && [ -L "$UNIT_DIR/$SERVICE_NAME" ]; }
assert "21.5 re-running is idempotent -- old symlinks replaced, not duplicated" $?

# ============================================================================
# 22. 22-check-timer-uninstall.sh
# ============================================================================

new_check_tree; reset_env
run "$T/scripts/22-check-timer-uninstall.sh"
[ "$RC" -eq 0 ]; assert "22.1 uninstalling when nothing was ever installed is a clean no-op" $?

new_check_tree; reset_env
run "$T/scripts/21-check-timer-install.sh"
run "$T/scripts/22-check-timer-uninstall.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Timer uninstalled"* ]] \
  && [ ! -e "$UNIT_DIR/$TIMER_NAME" ] && [ ! -e "$UNIT_DIR/$SERVICE_NAME" ] \
  && [ ! -e "$RENDERED" ] \
  && [ "$(sed -n 's/^ActiveState=//p' "$SYSTEMCTL_STATE/$TIMER_NAME")" = "inactive" ]; }
assert "22.2 a clean uninstall removes both symlinks and the rendered unit" $?

new_check_tree; reset_env
run "$T/scripts/21-check-timer-install.sh"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "ActiveState=activating" "SubState=start"
run "$T/scripts/22-check-timer-uninstall.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"read-only and will finish on its own"* ]] \
  && [[ "$OUT" == *"Timer uninstalled"* ]] \
  && [ ! -e "$UNIT_DIR/$TIMER_NAME" ]; }
assert "22.3 a run in progress is noted, not refused -- read-only check, uninstall proceeds" $?

# ============================================================================
# 29. 29-check-timer-status.sh
# ============================================================================

new_check_tree; reset_env
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"not installed for this user"* ]] && [[ "$OUT" == *"NOT fully functional"* ]]; }
assert "29.1 nothing installed is reported as not installed, not functional" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=active" "SubState=waiting"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "ActiveState=inactive" "SubState=dead" "Result=success" "ExecMainStatus=0"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Functional: scheduled, last run came back clean, container is up."* ]]; }
assert "29.2 scheduled + last run clean + container up -- fully functional" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=active" "SubState=waiting"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "Result=success"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" != *"NOT SCHEDULED"* ]]; }
assert "29.3 UnitFileState=alias (symlink install) is not mistaken for unscheduled" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=inactive" "SubState=dead"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "Result=success"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"NOT SCHEDULED"* ]] && [[ "$OUT" == *"NOT fully functional"* ]]; }
assert "29.4 an inactive timer is reported NOT SCHEDULED" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=active" "SubState=waiting"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "Result=failed" "ExecMainStatus=1"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"DID NOT COME BACK CLEAN"* ]] && [[ "$OUT" == *"NOT fully functional"* ]]; }
assert "29.5 a failed last run is reported, not just 'ran'" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=active" "SubState=waiting"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "Result=success"
seed_unit "$CONTAINER_UNIT" "LoadState=loaded" "ActiveState=inactive"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"is NOT active"* ]] && [[ "$OUT" == *"NOT fully functional"* ]]; }
assert "29.6 a scheduled, clean-last-run timer is still NOT functional if the container is down" $?

new_check_tree; reset_env
seed_unit "$TIMER_NAME" "LoadState=loaded" "UnitFileState=alias" "ActiveState=active" "SubState=waiting"
seed_unit "$SERVICE_NAME" "LoadState=loaded" "Result=success"
run "$T/scripts/29-check-timer-status.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" != *"never (no run recorded"* ]] && [[ "$OUT" != *"DID NOT COME BACK CLEAN"* ]]; }
assert "29.7 a Persistent=true catch-up run (Result set, no Exec* timestamps) still counts as clean" $?

# ============================================================================
echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
