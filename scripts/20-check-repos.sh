#!/bin/sh
#
# 20-check-repos.sh
# ----------------
# Runs `borg check --repository-only` against each hosted client repository,
# inside the running container via `podman exec`, so that on-disk corruption
# (bit rot, a truncated segment, an inconsistent index) is found here rather
# than discovered by a client at restore time. This is the executable half of
# [Design](../docs/DESIGN.md) Chapter 3.3, [Operations](../docs/OPERATIONS.md)
# Chapter 9.13.
#
# WHAT THIS CHECKS, AND WHAT IT DELIBERATELY DOES NOT.
#   - `--repository-only` validates the repository's own structures -- segment
#     files, their hashes, the index/manifest consistency -- and needs NO
#     encryption key and NO passphrase. It never decrypts anything.
#   - Deep archive-content verification (`borg check --verify-data`, and the
#     archive-consistency half of a full check) needs the client's key, which
#     by design never exists on the server ([Design](../docs/DESIGN.md)
#     Chapter 2.1). That check stays a client-side responsibility and is not
#     something this script can or should do.
#   - `--repair` is NEVER passed here, on any code path. It modifies the
#     repository and must stay a deliberate, manual operator action -- take a
#     snapshot first (snapshots/70-create-snapshot.sh), investigate, then
#     repair on purpose. See docs/OPERATIONS.md chapter 9.14.
#
# LIVE REPOSITORIES ONLY. This checks HOST_REPO_BASE/<client>, the repositories
# the container has mounted at /repo. It does not touch storage snapshots or an
# offline export copy -- those live outside what the container can see and are
# checked with a throwaway container instead (docs/OPERATIONS.md chapter 9.13).
#
# Usage:
#   ./scripts/20-check-repos.sh              # every client found on disk
#   ./scripts/20-check-repos.sh <client>     # just that one
#
#   Clients are discovered by walking the filesystem (HOST_REPO_BASE/<client>),
#   not by reading clients.conf -- same as snapshots/70-create-snapshot.sh, and
#   for the same reason: the point is to check whatever is physically on disk.
#
# WHEN TO RUN IT.
#   - Unattended, weekly, via the systemd timer (scripts/21-check-timer-
#     install.sh, scripts/check-repos.timer). A full check reads about half the
#     repository, so weekly and off-peak -- not daily.
#   - By hand, any time, and in particular AFTER any privileged mutating
#     operation on a repository (`borg compact`, `borg check --repair`, a
#     snapshot restore), and around an offline export ([Roadmap](../ROADMAP.md)
#     11.2). Those are the ways a repository changes between scheduled runs.
#
# CONCURRENCY. A run already in progress is detected and refused (flock on a
# lock file under HOST_LOG_BASE), so the weekly timer and a manual invocation
# never overlap -- mirrors snapshots/70-create-snapshot.sh.
#
# CHECK_LOCK_WAIT (default 600). `borg check` takes the repository's exclusive
# lock -- the same lock a client `borg create` needs. Passed as `--lock-wait`
# so that a check firing while a backup is running WAITS for it rather than
# failing outright. This does not delay the client: the client already holds
# the lock and proceeds normally; only this check waits.
#
# CHECK_MAX_DURATION (default 3600, 0 disables). Passed as `borg check
# --max-duration` (valid only together with `--repository-only`). It time-boxes
# each repository per run: when the budget runs out borg stops cleanly, records
# how far it got, and the NEXT run resumes from there. A large repository is
# therefore covered over several runs and a single run never grows into the
# backup window. The cost: one run of a large repository is a slice, not a full
# pass -- the per-client line says PARTIAL vs FULL. That label is best-effort,
# read from borg's own output, whose exact wording is version-dependent
# (confirmed against the shipped borg in docs/VERIFICATION.md); a missed label
# only mis-prints a partial pass as FULL, it does not affect the exit status.
#
# CHECK_NICE (default 19). nice(1) increment for the borg process inside the
# container -- a pure fairness knob, never needs privilege. `ionice` is
# deliberately NOT used: the container drops CAP_SYS_NICE
# (systemd/borg-server.container), so an idle I/O class cannot be guaranteed
# there. Off-peak weekly scheduling is the substitute; real I/O throttling, if
# it is ever shown to be needed, belongs on the container's cgroup.
#
# These three are environment overrides, not entries in scripts/config.sh --
# same category as snapshots/70-'s SNAPSHOT_DEBUG_LOG. config.sh is what an
# operator edits and an upgrade diffs (DEPLOYMENT.md 6.3); it stays short.
#
# EXIT STATUS. One repository failing does not stop the sweep: every client
# found is attempted. Exit 0 only if every repository came back clean (a clean
# time-boxed partial pass counts as clean); exit 1 if any repository reported
# problems or could not be checked. That non-zero status is the signal a
# systemd OnFailure= unit or a cron MAILTO is meant to catch.
#
# PRIVILEGES. Runs as the normal operator user, the same user that runs the
# container -- same as every script in scripts/. No sudo. The borg process runs
# inside the container as the unprivileged `borg` user (`podman exec --user
# borg`), so any lock or index file it writes under the repository is owned
# exactly like the rest of that repository -- not root-in-container-owned.
#
# Requires the container to be running (it is reached through `podman exec`).
# If it is not, this script stops with a clear message and does nothing.
#
# Must run on the HOST, not inside the container -- see docs/OPERATIONS.md
# chapter 9.13.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

# --- Tuning knobs (environment overrides, see the header) -------------------
CHECK_LOCK_WAIT="${CHECK_LOCK_WAIT:-600}"
CHECK_MAX_DURATION="${CHECK_MAX_DURATION:-3600}"
CHECK_NICE="${CHECK_NICE:-19}"

for _kv in "CHECK_LOCK_WAIT=$CHECK_LOCK_WAIT" "CHECK_MAX_DURATION=$CHECK_MAX_DURATION" "CHECK_NICE=$CHECK_NICE"; do
    _name="${_kv%%=*}"
    _val="${_kv#*=}"
    case "$_val" in
        ''|*[!0-9]*)
            echo "ERROR: $_name must be a non-negative integer (got '$_val')." >&2
            exit 1
            ;;
    esac
done

# check_client <username>
#
# Runs `borg check --repository-only` on one client's live repository inside
# the container. Returns 0 if borg reported the repository clean (a clean
# time-boxed partial pass counts as clean); returns 1 on any problem -- borg
# found errors, the lock could not be taken within CHECK_LOCK_WAIT, or the
# `podman exec` itself failed. Every failure explains itself on stdout before
# returning. Locals are prefixed `_cc_` -- POSIX sh has no `local` -- the same
# convention scripts/lib.sh and snapshots/70- use.
check_client() {
    _cc_username="$1"

    # Validated before use: it is interpolated into the container-side repo
    # path passed to borg.
    case "$_cc_username" in
        ''|-*|*[!a-zA-Z0-9_-]*)
            echo "ERROR: skipping '$_cc_username' -- a client name may use only"
            echo "       a-z, 0-9, _ and -, and must not start with '-'."
            return 1
            ;;
    esac

    _cc_repo="${CONTAINER_REPO_BASE%/}/${_cc_username}"
    _cc_rc=0
    _cc_out=""

    echo "[check] ${_cc_username}: borg check --repository-only ${_cc_repo}"

    # BORG_BASE_DIR points borg's config/cache/security dirs at the container's
    # /tmp tmpfs: the image root filesystem is read-only
    # (systemd/borg-server.container, ReadOnly=true) and borg wants to create
    # those dirs. Nothing there is persisted or needs to be -- --repository-only
    # keeps no useful cache. No BORG_PASSPHRASE and no TTY on the exec:
    # --repository-only does not decrypt anything, so it must not need one; if a
    # future borg somehow asks, the prompt hits EOF and the check fails loudly
    # here rather than hanging.
    if [ "$CHECK_MAX_DURATION" -gt 0 ]; then
        _cc_out="$(podman exec --user borg --env BORG_BASE_DIR=/tmp/borg-check-base "$CONTAINER" \
            nice -n "$CHECK_NICE" borg check --repository-only \
            --lock-wait "$CHECK_LOCK_WAIT" --max-duration "$CHECK_MAX_DURATION" \
            "$_cc_repo" 2>&1)" || _cc_rc=$?
    else
        _cc_out="$(podman exec --user borg --env BORG_BASE_DIR=/tmp/borg-check-base "$CONTAINER" \
            nice -n "$CHECK_NICE" borg check --repository-only \
            --lock-wait "$CHECK_LOCK_WAIT" \
            "$_cc_repo" 2>&1)" || _cc_rc=$?
    fi

    # Echo borg's own output, indented, so the log carries the evidence next to
    # the verdict rather than a bare PASS/FAIL.
    if [ -n "$_cc_out" ]; then
        printf '%s\n' "$_cc_out" | sed 's/^/    /'
    fi

    if [ "$_cc_rc" -ne 0 ]; then
        echo "ERROR: ${_cc_username}: 'borg check' exited ${_cc_rc}."
        case "$_cc_rc" in
            125|126|127)
                echo "       The 'podman exec' itself failed -- the container may have"
                echo "       stopped mid-sweep. borg did not run for ${_cc_username}."
                ;;
            *)
                case "$_cc_out" in
                    *[Ll]ock*timeout*|*"Failed to create/acquire the lock"*|*LockTimeout*)
                        echo "       The repository lock could not be taken within"
                        echo "       ${CHECK_LOCK_WAIT}s (a backup still running?). ${_cc_username}"
                        echo "       was not checked this run; the next run will retry it."
                        ;;
                    *)
                        echo "       borg reported a problem with the repository structure --"
                        echo "       this is what this check exists to catch. Do NOT run"
                        echo "       'borg check --repair' blindly: take a snapshot first,"
                        echo "       investigate, then repair deliberately (OPERATIONS.md 9.14)."
                        ;;
                esac
                ;;
        esac
        return 1
    fi

    case "$_cc_out" in
        *[Pp]"artial repository check"*|*"will be continued"*|*"resume"*)
            echo "[check] ${_cc_username}: PARTIAL pass (time-boxed at ${CHECK_MAX_DURATION}s); next run resumes."
            ;;
        *)
            echo "[check] ${_cc_username}: FULL pass, no problems found."
            ;;
    esac
    return 0
}

# check_and_time <client-dir>
#
# The timing/counting wrapper around one check_client call, so the loop below
# stays a loop. TOTAL and FAILED are the script's own globals (a POSIX sh
# function shares the caller's namespace).
check_and_time() {
    _cat_dir="$1"
    _cat_user="$(basename "$_cat_dir")"
    TOTAL=$((TOTAL + 1))

    _cat_start="$(date +%s)"
    if check_client "$_cat_user"; then
        _cat_result="ok"
    else
        _cat_result="failed"
        FAILED=$((FAILED + 1))
    fi
    _cat_end="$(date +%s)"

    echo "[check] ${_cat_user}: ${_cat_result} in $((_cat_end - _cat_start))s"
}

# ---------------------------------------------------------------------------
# Config sanity
# ---------------------------------------------------------------------------
if [ -z "${HOST_REPO_BASE:-}" ]; then
    echo "ERROR: HOST_REPO_BASE is not set in config.sh." >&2
    exit 1
fi
if [ -z "${CONTAINER:-}" ]; then
    echo "ERROR: CONTAINER is not set in config.sh." >&2
    exit 1
fi

HOST_REPO_BASE="${HOST_REPO_BASE%/}"
case "$HOST_REPO_BASE" in
    /*) ;;
    *) echo "ERROR: HOST_REPO_BASE ('$HOST_REPO_BASE') must be an absolute path." >&2; exit 1 ;;
esac
if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "ERROR: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist or is not a directory." >&2
    echo "       Check that the intended storage volume is mounted." >&2
    exit 1
fi

CONTAINER_REPO_BASE="${CONTAINER_REPO_BASE:-/repo/}"

if [ "$#" -gt 1 ]; then
    echo "ERROR: too many arguments." >&2
    echo "Usage: $0 [<client>]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The container has to be up -- this works through `podman exec`.
# ---------------------------------------------------------------------------
if ! systemctl --user is-active --quiet "$SERVICE"; then
    echo "ERROR: the container service '$SERVICE' is not active." >&2
    echo "       20-check-repos.sh runs 'borg check' inside the running container" >&2
    echo "       via 'podman exec'. Start it first:" >&2
    echo "           ./scripts/90-container-start.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Refuse to overlap with another run (the timer vs. a manual invocation, or
# two manual ones). Mirrors snapshots/70-create-snapshot.sh. The lock lives
# under HOST_LOG_BASE, which is inside this checkout and so already
# one-per-installation. Held via fd 9 for the whole run; released on exit,
# however the script exits.
# ---------------------------------------------------------------------------
mkdir -p "$HOST_LOG_BASE"
LOCK_FILE="${HOST_LOG_BASE}/.check-repos.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another 20-check-repos.sh run is still in progress" >&2
    echo "       (lock held: $LOCK_FILE). Nothing was done." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
TOTAL=0
FAILED=0
RUN_START="$(date +%s)"

if [ "$#" -eq 1 ]; then
    ONE="$1"
    if [ ! -d "${HOST_REPO_BASE}/${ONE}" ]; then
        echo "ERROR: no repository directory '${HOST_REPO_BASE}/${ONE}'." >&2
        echo "       Clients are discovered on disk; check the name with" >&2
        echo "           ./scripts/09-show-all-users.sh" >&2
        exit 1
    fi
    check_and_time "${HOST_REPO_BASE}/${ONE}"
else
    # Same one-level-deep enumeration snapshots/70- and lib.sh's
    # repo_projid_next use for "every client directory on disk".
    for CLIENT_DIR in "${HOST_REPO_BASE}"/*; do
        [ -d "$CLIENT_DIR" ] || continue
        check_and_time "$CLIENT_DIR"
    done
fi

RUN_END="$(date +%s)"

echo ""
if [ "$TOTAL" -eq 0 ]; then
    echo "[check] No client repositories found under $HOST_REPO_BASE. Nothing to do."
    exit 0
fi

OK=$((TOTAL - FAILED))
echo "[check] ${OK}/${TOTAL} repositories came back clean in $((RUN_END - RUN_START))s total."
if [ "$FAILED" -gt 0 ]; then
    echo "[check] ${FAILED} repositories need attention -- see ERROR lines above."
    exit 1
fi
exit 0
