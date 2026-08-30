#!/usr/bin/env bash
#
# tests/wrapper-gating.sh
# -----------------------
# Behavioural tests for borg-wrapper.sh — the forced command on which every
# guarantee in docs/DESIGN.md Chapter 4.1 depends.
#
# The wrapper is a pure function of two inputs: its argv[1] (the repo path,
# fixed per key in authorized_keys) and $SSH_ORIGINAL_COMMAND (attacker-
# controlled). That makes its gating logic directly testable without a
# server, a container, or an SSH session.
#
# The final action on the permitted path is
#     exec borg serve --restrict-to-path <repo> --append-only
# so a fake `borg` is placed on PATH: it prints its arguments instead of
# starting a protocol session, which lets the tests assert that
# --append-only and --restrict-to-path are present on EVERY permitted path.
# The keyfile-encryption check uses the borg *Python module*, which PATH
# does not affect.
#
# Requires: bash, borgbackup (1.2.x), python3.
# Usage:    tests/wrapper-gating.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Defaults to the wrapper in this checkout. Override to point at the copy
# installed in a built image (WRAPPER=/borg-wrapper.sh), so the suite can be
# run against the artifact that actually ships rather than only the source.
WRAPPER="${WRAPPER:-$ROOT/borg-wrapper.sh}"

[ -f "$WRAPPER" ] || { echo "not found: $WRAPPER" >&2; exit 1; }
command -v borg    >/dev/null || { echo "borgbackup is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"    >&2; exit 1; }

# The wrapper rejects any repo path outside [a-zA-Z0-9/_-] — which includes
# the dot in mktemp's default "tmp.XXXX" template. Use a dotless one.
WORK="$(mktemp -d /tmp/borgwrappertest_XXXXXX)"

# The info channel reads /run/borg-info<repo>.txt — an absolute path, so the
# fixture for it needs privileges the rest of this suite does not. Skipping the
# case instead is not an option: it is the only coverage the info channel has,
# and a check that quietly stops checking is the failure mode this test tree
# exists to prevent (same position as tests/authorized-keys-generation.sh).
# Three ways, in order of preference:
#   root   how the run inside the built image works — write it directly
#   bwrap  no privileges: a private tmpfs at /run, wrapper run inside it
#   sudo   write it on the real /run
INFO_MODE=""
if [ "$(id -u)" = 0 ]; then
    INFO_MODE=root
elif command -v bwrap >/dev/null 2>&1 \
     && bwrap --dev-bind / / --tmpfs /run -- /usr/bin/true 2>/dev/null; then
    INFO_MODE=bwrap
elif sudo -n true 2>/dev/null; then
    INFO_MODE=sudo
else
    echo "FAIL the info channel needs a fixture under /run/borg-info, which this" >&2
    echo "     user cannot create: run as root, or provide bubblewrap or" >&2
    echo "     passwordless sudo." >&2
    exit 1
fi

cleanup() {
    rm -rf "$WORK"
    case "$INFO_MODE" in
        root) rm -rf "/run/borg-info$WORK" ;;
        sudo) sudo rm -rf "/run/borg-info$WORK" ;;
    esac
}
trap cleanup EXIT

export BORG_KEYS_DIR="$WORK/keys" BORG_CACHE_DIR="$WORK/cache"
export BORG_PASSPHRASE=test
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
mkdir -p "$BORG_KEYS_DIR" "$BORG_CACHE_DIR"

SHIM="$WORK/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho "EXEC: borg $*"\n' > "$SHIM/borg"
chmod +x "$SHIM/borg"

# The 'info' channel's live "last check" line reads $CHECK_STATE_DIR/<client>
# (fixed at /log/check-state in the image; overridable here, never by a client).
export CHECK_STATE_DIR="$WORK/checkstate"
mkdir -p "$CHECK_STATE_DIR"

pass=0 fail=0
OUT=""; ERR=""; RC=0

run() { # run <repo> <ssh_original_command>
    OUT="$(SSH_ORIGINAL_COMMAND="$2" PATH="$SHIM:$PATH" bash "$WRAPPER" "$1" 2>"$WORK/err")"
    RC=$?
    ERR="$(cat "$WORK/err")"
}

INFO_TEXT='[server]
name: test
'

run_info() { # run_info <repo>  — 'info' with this client's rendered text in place
    local repo="$1" file="/run/borg-info$1.txt"
    case "$INFO_MODE" in
        root)
            mkdir -p "$(dirname "$file")"
            printf '%s' "$INFO_TEXT" > "$file"
            run "$repo" info
            ;;
        sudo)
            sudo mkdir -p "$(dirname "$file")"
            printf '%s' "$INFO_TEXT" | sudo tee "$file" >/dev/null
            sudo chmod 644 "$file"
            run "$repo" info
            ;;
        bwrap)
            # Fixture and wrapper have to share the sandbox: the tmpfs at /run
            # exists only for the duration of this one command.
            OUT="$(bwrap --dev-bind / / --tmpfs /run -- \
                   env SSH_ORIGINAL_COMMAND=info PATH="$SHIM:$PATH" \
                   bash -c 'mkdir -p "$(dirname "$2")" && printf "%s" "$3" > "$2" \
                            && exec bash "$0" "$1"' \
                   "$WRAPPER" "$repo" "$file" "$INFO_TEXT" 2>"$WORK/err")"
            RC=$?
            ERR="$(cat "$WORK/err")"
            ;;
    esac
}

run_unset() { # run_unset <repo>   — SSH_ORIGINAL_COMMAND not set at all
    OUT="$(env -u SSH_ORIGINAL_COMMAND PATH="$SHIM:$PATH" bash "$WRAPPER" "$1" 2>"$WORK/err")"
    RC=$?
    ERR="$(cat "$WORK/err")"
}

ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n       rc=%s\n       out=%s\n       err=%s\n' "$1" "$RC" "$OUT" "$ERR"; }

assert_deny() { # <desc> <substring expected on stderr>
    if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qF -- "$2"; then ok "$1"; else bad "$1"; fi
}

assert_ok_contains() { # <desc> <substring expected on stdout>
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1"; fi
}

assert_ok_lacks() { # <desc> <substring that must NOT appear on stdout>
    if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1"; fi
}

# Strongest form: the exec line must be EXACTLY our own invocation. Any client
# string leaking into it — an extra flag, an overridden path — fails here.
assert_serves_exactly() { # <desc> <repo>
    if [ "$RC" -eq 0 ] \
       && [ "$OUT" = "EXEC: borg serve --restrict-to-path $2 --append-only" ]; then ok "$1"; else bad "$1"; fi
}

assert_not_executed() { # <desc> <path that must not exist>
    if [ ! -e "$2" ]; then ok "$1"; else bad "$1"; rm -f "$2"; fi
}

# --- fixtures --------------------------------------------------------------

mkdir -p "$WORK/emptydir" "$WORK/nocfg"
: > "$WORK/nocfg/stray-file"

borg init -e keyfile-blake2 "$WORK/keyfile_blake2" >/dev/null 2>&1
borg init -e keyfile        "$WORK/keyfile_plain"  >/dev/null 2>&1
borg init -e repokey        "$WORK/repokey"        >/dev/null 2>&1
borg init -e none           "$WORK/unencrypted"    >/dev/null 2>&1
borg init -e authenticated  "$WORK/authenticated"  >/dev/null 2>&1

echo "# borg-wrapper.sh — gating and policy"
echo "# info fixture mode: $INFO_MODE"
echo

# --- A. repo path validation (argv[1]) -------------------------------------

run "/tmp/has.a.dot"        "borg serve"; assert_deny "A1 path with dot rejected"          "DENY: invalid repo path"
run "relative/path"         "borg serve"; assert_deny "A2 relative path rejected"          "DENY: invalid repo path"
run '/tmp/semi;rm -rf /'    "borg serve"; assert_deny "A3 path with metacharacter rejected" "DENY: invalid repo path"
run '/tmp/space here'       "borg serve"; assert_deny "A4 path with space rejected"        "DENY: invalid repo path"

# --- B. command gating: default-deny ---------------------------------------

DENYMSG="DENY: only 'borg serve' and 'info' are permitted"

run        "$WORK/emptydir" ""                    ; assert_deny "B1 empty command denied"            "$DENYMSG"
run_unset  "$WORK/emptydir"                       ; assert_deny "B2 unset command denied"            "$DENYMSG"
run        "$WORK/emptydir" "ls /"                ; assert_deny "B3 arbitrary command denied"        "$DENYMSG"
run        "$WORK/emptydir" "cat /etc/passwd"     ; assert_deny "B4 file read denied"                "$DENYMSG"
run        "$WORK/emptydir" "borgserve"           ; assert_deny "B5 near-miss 'borgserve' denied"    "$DENYMSG"
run        "$WORK/emptydir" "INFO"                ; assert_deny "B6 wrong-case 'INFO' denied"        "$DENYMSG"
run        "$WORK/emptydir" "info extra"          ; assert_deny "B7 'info' with argument denied"     "$DENYMSG"
run        "$WORK/emptydir" "/bin/sh"             ; assert_deny "B8 shell request denied"            "$DENYMSG"

# --- B'. injected commands are never executed -------------------------------
#
# $SSH_ORIGINAL_COMMAND is inspected to CLASSIFY the connection; it is never
# passed to a shell. Two cases matter, and the marker file proves both:
#   - a string that fails the pattern is denied
#   - a string that PASSES the pattern ("borg serve " prefix) is still inert,
#     because its remainder is discarded rather than run

run "$WORK/emptydir" "borg serve; touch $WORK/pwned_denied"
assert_deny         "B9 injection after ';' is denied" "$DENYMSG"
assert_not_executed "B10 ... and was not executed"     "$WORK/pwned_denied"

run "$WORK/emptydir" "borg serve && touch $WORK/pwned_allowed"
assert_serves_exactly "B11 injection after '&&' is classified as a borg connection" "$WORK/emptydir"
assert_not_executed   "B12 ... and was discarded, not executed" "$WORK/pwned_allowed"

# --- C. permitted commands --------------------------------------------------

run "$WORK/emptydir" "borg serve"
assert_serves_exactly "C1 'borg serve' reaches hardened serve" "$WORK/emptydir"

run "$WORK/emptydir" "borg serve --umask=077 --info"
assert_serves_exactly "C2 client args do not reach the exec" "$WORK/emptydir"

# A client trying to widen its own access: both flags are supplied by the
# wrapper, never by the caller, so the exec line must be unchanged.
run "$WORK/emptydir" "borg serve --restrict-to-path / --append-only=no"
assert_serves_exactly "C3 client cannot override --restrict-to-path or --append-only" "$WORK/emptydir"

run_info "$WORK/keyfile_blake2"
assert_ok_contains "C4 'info' returns the client's rendered info text" "name: test"

# The text is rendered at container start, so it can legitimately be absent
# (a server that has not generated it yet). The channel must still answer with
# the live quota line rather than fail — this is the connection check every
# client is told to run first.
run "$WORK/emptydir" "info"
assert_ok_contains "C5 'info' still answers when no text is rendered" "Used:"

# --- C6-C9. the live 'last check' line (from $CHECK_STATE_DIR/<client>) -----

TAB="$(printf '\t')"
rm -f "$CHECK_STATE_DIR"/*

run "$WORK/keyfile_blake2" "info"
assert_ok_lacks "C6 no check-state file -> no 'Last Repo Structure Check' line, no false claim" "Last Repo Structure Check"

printf 'ok%s2026-08-30T05:00:04Z%s2026-08-30T05:00:04Z\n' "$TAB" "$TAB" > "$CHECK_STATE_DIR/keyfile_blake2"
run "$WORK/keyfile_blake2" "info"
assert_ok_contains "C7 an 'ok' check-state -> the exact timestamp with (ok)" \
    "Last Repo Structure Check: 2026-08-30T05:00:04Z (ok)"

printf 'partial%s2026-08-30T05:00:02Z%s2026-08-24T05:00:11Z\n' "$TAB" "$TAB" > "$CHECK_STATE_DIR/keyfile_blake2"
run "$WORK/keyfile_blake2" "info"
assert_ok_contains "C8 a 'partial' check-state -> the partial run's timestamp with (partial)" \
    "Last Repo Structure Check: 2026-08-30T05:00:02Z (partial)"

printf 'fail%s2026-08-30T05:00:01Z%s2026-08-24T05:00:11Z\n' "$TAB" "$TAB" > "$CHECK_STATE_DIR/keyfile_blake2"
run "$WORK/keyfile_blake2" "info"
assert_ok_contains "C9 a 'fail' check-state -> the failing run's timestamp with (fail)" \
    "Last Repo Structure Check: 2026-08-30T05:00:01Z (fail)"
run "$WORK/keyfile_blake2" "info"
assert_ok_lacks "C9b a 'fail' check-state never leaks borg's own error text" "integrity error"
rm -f "$CHECK_STATE_DIR"/*

# --- D. repository state ----------------------------------------------------

# A path with no directory behind it is provisioning, not serving, and the
# wrapper does not provision. It used to `mkdir -p` here, which could only ever
# produce a directory owned by 'borg' and covered by no XFS project id — a
# client bounded by the volume instead of by its limit, created by the server
# itself. Only the host can make one correctly, because the ownership needs
# `podman unshare` and the project id needs `sudo xfs_quota`. D5 below is the
# state a provisioned client actually reaches.
run "$WORK/does_not_exist_yet" "borg serve"
assert_deny "D1 a missing repository directory is refused" "DENY: repository directory missing"

run "$WORK/nocfg" "borg serve"
assert_deny "D2 non-empty repo without config denied" "DENY: repo non-empty but config missing"

# The emptiness test is strict, and nothing is exempt from it. Earlier releases
# excused info.txt, because the server itself wrote that file into every
# client's repository directory — which also made the client's first `borg
# init` fail, since borg refuses a directory that is not empty. The info text
# now lives under /run, so an empty directory is a state a new client actually
# reaches, and a file in there means something else put it there.
mkdir -p "$WORK/onlyinfo"
printf '[server]\nname: test\n' > "$WORK/onlyinfo/info.txt"
run "$WORK/onlyinfo" "borg serve"
assert_deny "D3 a leftover info.txt in the repo is not exempt" "DENY: repo non-empty but config missing"

# Hidden files count too: dotglob is set, so a dotfile cannot pass as empty.
mkdir -p "$WORK/dotonly"
: > "$WORK/dotonly/.hidden"
run "$WORK/dotonly" "borg serve"
assert_deny "D4 a hidden file does not pass as an empty repo" "DENY: repo non-empty but config missing"

# The empty directory an operator creates for a new client: this is the state
# in which `borg init` has to be allowed through.
mkdir -p "$WORK/freshdir"
run "$WORK/freshdir" "borg serve"
assert_serves_exactly "D5 an empty repo directory is allowed (borg init path)" "$WORK/freshdir"

# Belongs with D1 and is appended here rather than renumbered in: refusing is
# only half the requirement, the other half is that the refused path is still
# not there afterwards. A wrapper that created the directory and then denied
# would pass D1 and still have produced the unquotaed directory D1 exists to
# prevent — the next connection would find it and be served from it.
assert_not_executed "D6 ... and the refusal created nothing" "$WORK/does_not_exist_yet"

# --- E. encryption policy: client-held keyfile only -------------------------

run "$WORK/keyfile_blake2" "borg serve"
assert_serves_exactly "E1 keyfile-blake2 accepted" "$WORK/keyfile_blake2"

run "$WORK/keyfile_plain" "borg serve"
assert_serves_exactly "E2 keyfile accepted" "$WORK/keyfile_plain"

run "$WORK/repokey" "borg serve"
assert_deny "E3 repokey rejected (key material server-side)" "DENY:"

run "$WORK/unencrypted" "borg serve"
assert_deny "E4 unencrypted repo rejected" "DENY:"

run "$WORK/authenticated" "borg serve"
assert_deny "E5 authenticated-only repo rejected" "DENY:"

# --- summary ----------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
