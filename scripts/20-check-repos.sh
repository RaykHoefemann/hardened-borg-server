#!/bin/sh
#
# 20-check-repos.sh
# ----------------
# Runs `borg check -v --repository-only` against hosted client repositories,
# inside the running container via `podman exec`, so on-disk corruption (bit
# rot, a truncated segment, an inconsistent index) is found here rather than by
# a client at restore time. Design 3.3, Operations 9.13.
#
# TWO MODES.
#
#   ./scripts/20-check-repos.sh <client>
#       Check that one repository, unconditionally -- regardless of when it was
#       last checked, not bounded by any budget or CHECK_MAX_RUNTIME. The form
#       to use by hand, and after any mutating operation (`borg compact`, `borg
#       check --repair`, a snapshot restore -- Operations 9.14). It still writes
#       its history line below, so a manual check counts toward the schedule and the
#       next timer run will not re-check that repository straight away.
#
#   ./scripts/20-check-repos.sh            (no argument -- what the timer runs)
#       Self-balancing sweep. Each run checks the repositories that have gone
#       longest without a check, oldest first, until a size budget is spent:
#           budget = (total size of every repository) / CHECK_CYCLE_DIVISOR
#       The single oldest is always checked (progress guarantee) even if it
#       alone exceeds the budget. A daily timer with the default divisor 6 gets
#       through everything about every 6 days, with ~1 run/week of slack.
#       Nothing is ever dropped -- the oldest is always next -- so a run that
#       fails partway, a new repository, or a slow store all self-correct: the
#       repositories not reached this run are simply the oldest next run.
#
# STATE -- one append-only history file, HOST_LOG_BASE/check-repos.history, tab-separated:
#       <epoch>  <iso8601-utc>  <client>  <du-KiB>  <duration-s>  <ok|partial|fail>  <days-since-prev>
#   Field 7 is this client's gap to its own previous check, in whole days,
#   rounded to nearest ((now - prev + 43200) / 86400); `-` on the client's first
#   ever check. It is written for the eye only -- nothing reads it back.
#   A repository's "last checked" for ordering is its most recent `ok` OR
#   `partial` line; its "last full check" (for the CHECK_STALE_DAYS warning) is
#   its most recent `ok` line. No line ever = never checked = first in line.
#   Lines written before this field existed have 6 fields; readers key on field
#   number, so the mixed width is harmless and no migration is needed.
#
#   Plus one file per client, HOST_LOG_BASE/check-state/<client>, overwritten
#   each check: `<last-result>  <last-check-date>  <last-full-pass-date>`. It
#   holds only that client, so borg-wrapper.sh can surface a "last checked" line
#   in the client's own `info` session without touching the multi-client history
#   (DESIGN 2.2 / 2.4). A no-argument run also removes check-state files whose
#   repository no longer exists on disk.
#
# WHAT IS CHECKED. `--repository-only`: segment checksums and the repository
#   index -- no key, no passphrase, nothing decrypted. Deep archive-content
#   verification (`borg check --verify-data`) needs the client's key and stays
#   the client's job (Design 2.1, Client Usage 8). `--repair` is NEVER passed
#   here, on any path -- it is a deliberate manual operator action (Operations
#   9.14). `-v` is load-bearing: without it borg 1.2.8/1.4.0 print nothing on a
#   clean check, so a `--max-duration` partial run would be indistinguishable
#   from a full pass. With `-v` borg always ends on one of
#       Finished full repository check, no problems found.
#       Finished partial repository check, no problems found.
#       Finished full repository check, errors found.
#
# REPOSITORY SIZE is read from the enforcing XFS project quota (`df` on the
#   repository directory -- the figure 09-show-all-users.sh reports), so it
#   needs no `sudo` and no extra `podman exec`. A repository with no project
#   quota (mis-provisioned -- check 5.5A) makes `df` report the whole volume; it
#   is treated as size 0 (always fits, never dominates the budget) and flagged.
#
# KNOBS (environment overrides, non-negative integers; kept out of
#   scripts/config.sh so that file stays short enough to diff on upgrade):
#     CHECK_CYCLE_DIVISOR  6      budget per run = total size / this. Lower it
#                                 for a bigger budget per run; add a second
#                                 daily timer, or split the biggest
#                                 repositories out (Operations 9.13), if a
#                                 single daily run cannot keep up.
#     CHECK_MAX_RUNTIME    3600   seconds; a run stops STARTING repositories
#                                 past this. It cannot interrupt one already
#                                 running -- `borg check` has no clean mid-repo
#                                 stop without --max-duration.
#     CHECK_STALE_DAYS     9      a full check older than this is a warning in
#                                 the summary and in 29-check-timer-status.sh,
#                                 and makes a no-argument run exit non-zero. NOT
#                                 a scheduling override: with a right-sized
#                                 budget nothing reaches it, and with an
#                                 undersized one an override would only blow
#                                 CHECK_MAX_RUNTIME.
#     CHECK_MIN_AGE_DAYS   0      if >0, a run does not re-check a repository
#                                 checked more recently than this even when the
#                                 budget has room (the oldest is still always
#                                 checked).
#     CHECK_LOCK_WAIT      600    --lock-wait: a check firing during a backup
#                                 waits for the repository lock instead of
#                                 failing. Does not delay the client.
#     CHECK_MAX_DURATION   0      >0 => `borg check --max-duration`. Opt-in, and
#                                 a WEAKER check: borg's manual -- a
#                                 --max-duration check "can only perform
#                                 non-cryptographic checksum checks on the
#                                 segment files" and skips the repository index
#                                 check, so it only ever reports "partial". For
#                                 a single repository too large to check within
#                                 CHECK_MAX_RUNTIME; borg recommends it "with
#                                 very large repositories only".
#     CHECK_NICE           19     nice(1) for the borg process in the container.
#
# EXIT STATUS. A no-argument run exits 0 only if every check it ran came back
#   clean AND no repository is over CHECK_STALE_DAYS. A <client> run exits with
#   that one check's result. One failing repository never stops the sweep.
#
# CONCURRENCY. A run in progress is detected and refused (flock under
#   HOST_LOG_BASE), so the timer and a manual invocation never overlap.
#
# PRIVILEGES. Runs as the operator user, no sudo. borg runs in the container as
#   the unprivileged `borg` user (`podman exec --user borg`), so any lock or
#   index file it writes under a repository is owned like the rest of it.
#   Requires the container to be running. Must run on the HOST -- Operations
#   9.13.
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

TAB="$(printf '\t')"

# --- Tuning knobs (environment overrides, see the header) -------------------
CHECK_CYCLE_DIVISOR="${CHECK_CYCLE_DIVISOR:-6}"
CHECK_MAX_RUNTIME="${CHECK_MAX_RUNTIME:-3600}"
CHECK_STALE_DAYS="${CHECK_STALE_DAYS:-9}"
CHECK_MIN_AGE_DAYS="${CHECK_MIN_AGE_DAYS:-0}"
CHECK_LOCK_WAIT="${CHECK_LOCK_WAIT:-600}"
CHECK_MAX_DURATION="${CHECK_MAX_DURATION:-0}"
CHECK_NICE="${CHECK_NICE:-19}"

for _kv in \
    "CHECK_CYCLE_DIVISOR=$CHECK_CYCLE_DIVISOR" \
    "CHECK_MAX_RUNTIME=$CHECK_MAX_RUNTIME" \
    "CHECK_STALE_DAYS=$CHECK_STALE_DAYS" \
    "CHECK_MIN_AGE_DAYS=$CHECK_MIN_AGE_DAYS" \
    "CHECK_LOCK_WAIT=$CHECK_LOCK_WAIT" \
    "CHECK_MAX_DURATION=$CHECK_MAX_DURATION" \
    "CHECK_NICE=$CHECK_NICE"
do
    _name="${_kv%%=*}"
    _val="${_kv#*=}"
    case "$_val" in
        ''|*[!0-9]*)
            echo "ERROR: $_name must be a non-negative integer (got '$_val')." >&2
            exit 1
            ;;
    esac
done
if [ "$CHECK_CYCLE_DIVISOR" -lt 1 ]; then
    echo "ERROR: CHECK_CYCLE_DIVISOR must be at least 1." >&2
    exit 1
fi

CHECK_HISTORY="${HOST_LOG_BASE}/check-repos.history"

# check_client <username>
#
# Runs `borg check -v --repository-only` on one client's live repository inside
# the container. Returns 0 if borg reported it clean (a time-boxed partial pass
# counts), 1 on any problem. Sets CC_VERDICT to full|partial|unknown|fail for
# check_and_time to log. Locals are prefixed `_cc_` -- POSIX sh has no `local`.
check_client() {
    _cc_username="$1"
    CC_VERDICT=fail

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

    echo "[check] ${_cc_username}: borg check -v --repository-only ${_cc_repo}"

    # BORG_BASE_DIR -> the container's /tmp tmpfs: the image root filesystem is
    # read-only and borg wants to create config/cache/security dirs. Nothing
    # there is persisted. No BORG_PASSPHRASE and no TTY: --repository-only
    # decrypts nothing, so it must not need one; a prompt would hit EOF and fail
    # loudly here rather than hang.
    if [ "$CHECK_MAX_DURATION" -gt 0 ]; then
        _cc_out="$(podman exec --user borg --env BORG_BASE_DIR=/tmp/borg-check-base "$CONTAINER" \
            nice -n "$CHECK_NICE" borg check -v --repository-only \
            --lock-wait "$CHECK_LOCK_WAIT" --max-duration "$CHECK_MAX_DURATION" \
            "$_cc_repo" 2>&1)" || _cc_rc=$?
    else
        _cc_out="$(podman exec --user borg --env BORG_BASE_DIR=/tmp/borg-check-base "$CONTAINER" \
            nice -n "$CHECK_NICE" borg check -v --repository-only \
            --lock-wait "$CHECK_LOCK_WAIT" \
            "$_cc_repo" 2>&1)" || _cc_rc=$?
    fi

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
        CC_VERDICT=fail
        return 1
    fi

    case "$_cc_out" in
        *"partial repository check"*)
            echo "[check] ${_cc_username}: PARTIAL pass (time-boxed at ${CHECK_MAX_DURATION}s) -- borg resumes from here next run."
            CC_VERDICT=partial
            ;;
        *"full repository check, no problems found"*)
            echo "[check] ${_cc_username}: FULL pass, no problems found."
            CC_VERDICT=full
            ;;
        *)
            echo "[check] ${_cc_username}: passed (exit 0), but borg's summary line was not recognised -- see its output above for whether the whole repository was checked."
            CC_VERDICT=unknown
            ;;
    esac
    return 0
}

# check_and_time <client-dir> [du-KiB]
#
# Timing/counting wrapper around one check_client call, plus the check-repos.history line.
# TOTAL and FAILED are the script's own globals. If du-KiB is omitted it is
# read from the quota.
check_and_time() {
    _cat_user="$(basename "$1")"
    _cat_dukib="${2:-}"
    [ -n "$_cat_dukib" ] || _cat_dukib="$(repo_used_kib "$_cat_user")"
    TOTAL=$((TOTAL + 1))

    _cat_start="$(date +%s)"
    if check_client "$_cat_user"; then
        _cat_result="ok"
    else
        _cat_result="failed"
        FAILED=$((FAILED + 1))
    fi
    _cat_end="$(date +%s)"
    _cat_dur=$((_cat_end - _cat_start))

    echo "[check] ${_cat_user}: ${_cat_result} in ${_cat_dur}s"

    case "${CC_VERDICT:-}" in
        full|unknown) _cat_tok=ok ;;
        partial)      _cat_tok=partial ;;
        *)            _cat_tok=fail ;;
    esac
    _cat_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Field 7: whole days since this client's previous check (any verdict),
    # rounded to nearest. `-` if this is its first line. Computed before the
    # append so the scan sees only prior runs.
    _cat_prevage="-"
    if [ -f "$CHECK_HISTORY" ]; then
        _cat_prevage="$(awk -F"$TAB" -v c="$_cat_user" -v now="$_cat_end" \
            '$3 == c && $1 + 0 > e { e = $1 + 0 }
             END { if (e) print int((now - e + 43200) / 86400); else print "-" }' \
            "$CHECK_HISTORY" 2>/dev/null)"
        [ -n "$_cat_prevage" ] || _cat_prevage="-"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_cat_end" "$_cat_now" "$_cat_user" \
        "$_cat_dukib" "$_cat_dur" "$_cat_tok" "$_cat_prevage" >> "$CHECK_HISTORY"

    # Per-client status for the info channel (DESIGN 2.4): one file per client,
    # containing ONLY this client, so borg-wrapper.sh can read it in the
    # client's own session without touching the multi-client history. Three
    # tab-separated fields: <last-result> <last-check-date> <last-full-pass-date>.
    _cat_day="${_cat_now%%T*}"
    if [ "$_cat_tok" = "ok" ]; then
        _cat_lastok="$_cat_day"
    else
        _cat_lastok="$(awk -F"$TAB" -v c="$_cat_user" \
            '$3 == c && $6 == "ok" && $1 + 0 > e { e = $1 + 0; d = $2 }
             END { sub(/T.*/, "", d); print d }' \
            "$CHECK_HISTORY" 2>/dev/null)"
        [ -n "$_cat_lastok" ] || _cat_lastok="-"
    fi
    mkdir -p "${HOST_LOG_BASE}/check-state"
    printf '%s\t%s\t%s\n' "$_cat_tok" "$_cat_day" "$_cat_lastok" \
        > "${HOST_LOG_BASE}/check-state/${_cat_user}"
}

# repo_is_initialized <client>
#
# True once the client has run `borg init` -- borg writes `config` into the
# repository directory before it asks for a passphrase. A directory that
# 00-ssh-create-user.sh provisioned but the client has not initialized yet is
# not a repository to check; skipping it is not a failure.
repo_is_initialized() { [ -f "${HOST_REPO_BASE}/$1/config" ]; }

# repo_used_kib <client>
#
# On-disk size in KiB from the enforcing XFS project quota. 0 if the repository
# has no project quota (df then reports the whole volume -- unusable as a size).
repo_used_kib() {
    _ruk_dir="${HOST_REPO_BASE}/$1"
    _ruk_used="$(quota_used_kib "$_ruk_dir")"
    case "$_ruk_used" in ''|*[!0-9]*) echo 0; return ;; esac
    _ruk_lim="$(quota_enforced_kib "$_ruk_dir")"
    _ruk_vol="$(volume_kib)"
    if [ -n "$_ruk_lim" ] && [ "$_ruk_lim" = "${_ruk_vol:-x}" ]; then
        echo 0
        return
    fi
    echo "$_ruk_used"
}

# repo_epochs <client>  ->  "<checked-epoch> <full-epoch>"  (0 0 if never)
#
# checked-epoch = most recent ok|partial line; full-epoch = most recent ok line.
repo_epochs() {
    _re_u="$1"
    _re_any=0
    _re_full=0
    if [ -f "$CHECK_HISTORY" ]; then
        while IFS="$TAB" read -r _re_ep _re_iso _re_cl _re_du _re_dur _re_res _re_rest; do
            [ "$_re_cl" = "$_re_u" ] || continue
            case "$_re_ep" in ''|*[!0-9]*) continue ;; esac
            case "$_re_res" in
                ok)
                    [ "$_re_ep" -gt "$_re_any" ] && _re_any="$_re_ep"
                    [ "$_re_ep" -gt "$_re_full" ] && _re_full="$_re_ep"
                    ;;
                partial)
                    [ "$_re_ep" -gt "$_re_any" ] && _re_any="$_re_ep"
                    ;;
            esac
        done < "$CHECK_HISTORY"
    fi
    echo "$_re_any $_re_full"
}

# run_scheduler
#
# The no-argument mode. Sets TOTAL, FAILED, and STALE_COUNT / OLDEST_U /
# OLDEST_AGE for the summary. Prints everything as it goes.
run_scheduler() {
    NOW="$(date +%s)"
    ORDER_FILE="$(mktemp "${TMPDIR:-/tmp}/check-repos.XXXXXX")"

    _total=0
    for _d in "${HOST_REPO_BASE}"/*; do
        [ -d "$_d" ] || continue
        _u="$(basename "$_d")"
        case "$_u" in
            ''|-*|*[!a-zA-Z0-9_-]*)
                echo "[check] skipping '$_u' -- not a valid client name."
                continue
                ;;
        esac
        if ! repo_is_initialized "$_u"; then
            echo "[check] ${_u}: no repository yet (provisioned, awaiting first 'borg init') -- skipped."
            continue
        fi
        _sz="$(repo_used_kib "$_u")"
        if [ "$_sz" -eq 0 ]; then
            echo "[check] note: ${_u} reports no project quota (check 5.5A) -- size unknown, counted as 0 (always fits the budget)."
        fi
        # shellcheck disable=SC2046
        set -- $(repo_epochs "$_u")          # $1 = checked-epoch, $2 = full-epoch
        printf '%s\t%s\t%s\t%s\n' "$1" "$_u" "$_sz" "$2" >> "$ORDER_FILE"
        _total=$((_total + _sz))
    done

    # Drop check-state files for repositories that no longer exist on disk
    # (deprovisioned client) -- mirrors build_authorized_keys.sh's cleanup of a
    # departed client's /run/borg-info text.
    if [ -d "${HOST_LOG_BASE}/check-state" ]; then
        for _sf in "${HOST_LOG_BASE}/check-state"/*; do
            [ -e "$_sf" ] || continue
            [ -d "${HOST_REPO_BASE}/$(basename "$_sf")" ] && continue
            rm -f "$_sf"
            echo "[check] removed stale check-state for '$(basename "$_sf")' (no repository directory)."
        done
    fi

    if [ ! -s "$ORDER_FILE" ]; then
        echo "[check] No client repositories found under $HOST_REPO_BASE. Nothing to do."
        STALE_COUNT=0
        return 0
    fi

    _count="$(wc -l < "$ORDER_FILE" | tr -d ' ')"
    _limit=$((_total / CHECK_CYCLE_DIVISOR))
    [ "$_limit" -lt 1 ] && _limit=1

    echo "[check] scheduler: ${_count} repositories, total $(quota_human "$_total"), budget this run $(quota_human "$_limit") (total/${CHECK_CYCLE_DIVISOR})"
    echo ""

    sort -t "$TAB" -k1,1n -k2,2 "$ORDER_FILE" > "${ORDER_FILE}.sorted"

    _remaining="$_limit"
    _first=1
    _minage_s=$((CHECK_MIN_AGE_DAYS * 86400))
    while IFS="$TAB" read -r _ep _u _sz _full; do
        if [ "$_first" -eq 0 ]; then
            [ "$_remaining" -le 0 ] && break
            if [ "$(( $(date +%s) - RUN_START ))" -ge "$CHECK_MAX_RUNTIME" ]; then
                echo "[check] CHECK_MAX_RUNTIME (${CHECK_MAX_RUNTIME}s) reached -- stopping. The repositories not reached are the oldest next run."
                break
            fi
            if [ "$CHECK_MIN_AGE_DAYS" -gt 0 ] && [ "$((NOW - _ep))" -lt "$_minage_s" ]; then
                break        # sorted oldest-first: everything after is at least this fresh
            fi
            if [ "$_sz" -gt "$_remaining" ]; then
                echo "[check] ${_u}: skipped this run -- $(quota_human "$_sz") does not fit the $(quota_human "$_remaining") left in the budget."
                continue
            fi
        fi
        check_and_time "${HOST_REPO_BASE}/${_u}" "$_sz"
        _remaining=$((_remaining - _sz))
        _first=0
    done < "${ORDER_FILE}.sorted"

    if [ "$TOTAL" -lt "$_count" ]; then
        echo "[check] reached ${TOTAL} of ${_count} repositories this run; the rest are the oldest next run."
    fi

    # Coverage, read back from the post-run log. A repository that has never had
    # a full check is "awaiting its first check", not "stale" -- it is first in
    # line and a healthy sweep reaches it within a cycle; only a repository that
    # HAS a full check now older than CHECK_STALE_DAYS means the sweep is behind.
    NOW="$(date +%s)"
    STALE_COUNT=0
    NEVER_COUNT=0
    OLDEST_U=""
    OLDEST_FULL_AGE=-1
    while IFS="$TAB" read -r _ep _u _sz _full0; do
        # shellcheck disable=SC2046
        set -- $(repo_epochs "$_u")
        _full="$2"
        if [ "$_full" -eq 0 ]; then
            NEVER_COUNT=$((NEVER_COUNT + 1))
            continue
        fi
        _age=$(( (NOW - _full) / 86400 ))
        if [ "$_age" -gt "$OLDEST_FULL_AGE" ]; then
            OLDEST_FULL_AGE="$_age"
            OLDEST_U="$_u"
        fi
        [ "$_age" -ge "$CHECK_STALE_DAYS" ] && STALE_COUNT=$((STALE_COUNT + 1))
    done < "$ORDER_FILE"

    rm -f "$ORDER_FILE" "${ORDER_FILE}.sorted"
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
# Refuse to overlap with another run. The lock lives under HOST_LOG_BASE (in
# this checkout, so already one-per-installation). Held via fd 9 for the whole
# run; released on exit however the script exits.
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
STALE_COUNT=0
RUN_START="$(date +%s)"

if [ "$#" -eq 1 ]; then
    # -------------------------------------------------------------------
    # <client> mode: that one repository, unconditionally, still logged.
    # -------------------------------------------------------------------
    ONE="$1"
    if [ ! -d "${HOST_REPO_BASE}/${ONE}" ]; then
        echo "ERROR: no repository directory '${HOST_REPO_BASE}/${ONE}'." >&2
        echo "       Clients are discovered on disk; check the name with" >&2
        echo "           ./scripts/09-show-all-users.sh" >&2
        exit 1
    fi
    if ! repo_is_initialized "$ONE"; then
        echo "[check] ${ONE}: no repository yet (provisioned, awaiting first 'borg init') -- nothing to check."
        exit 0
    fi
    check_and_time "${HOST_REPO_BASE}/${ONE}"
    echo ""
    if [ "$FAILED" -gt 0 ]; then
        echo "[check] ${ONE}: did NOT come back clean -- see above."
        exit 1
    fi
    echo "[check] ${ONE}: checked, logged."
    exit 0
fi

# ---------------------------------------------------------------------------
# no argument: the self-balancing sweep
# ---------------------------------------------------------------------------
run_scheduler

echo ""
if [ "$TOTAL" -eq 0 ]; then
    exit 0
fi

OK=$((TOTAL - FAILED))
echo "[check] this run: ${OK}/${TOTAL} checked clean in $(( $(date +%s) - RUN_START ))s."
RC=0
if [ "$FAILED" -gt 0 ]; then
    echo "[check] ${FAILED} repository/-ies did NOT come back clean -- see ERROR lines above."
    RC=1
fi
if [ "${NEVER_COUNT:-0}" -gt 0 ]; then
    echo "[check] ${NEVER_COUNT} repository/-ies awaiting their first full check -- first in line."
fi
if [ -n "${OLDEST_U:-}" ] && [ "${OLDEST_FULL_AGE:--1}" -ge 0 ]; then
    echo "[check] coverage: oldest full check is '${OLDEST_U}', ${OLDEST_FULL_AGE} day(s) ago."
fi
if [ "$STALE_COUNT" -gt 0 ]; then
    echo "[check] WARNING: ${STALE_COUNT} repository/-ies have no full check within CHECK_STALE_DAYS (${CHECK_STALE_DAYS})."
    echo "        The sweep is falling behind. Lower CHECK_CYCLE_DIVISOR (bigger budget"
    echo "        per run), add a second daily timer, or split the biggest repositories"
    echo "        out (OPERATIONS.md 9.13)."
    RC=1
fi
exit "$RC"
