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
trap 'rm -rf "$WORK"' EXIT

export BORG_KEYS_DIR="$WORK/keys" BORG_CACHE_DIR="$WORK/cache"
export BORG_PASSPHRASE=test
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
mkdir -p "$BORG_KEYS_DIR" "$BORG_CACHE_DIR"

SHIM="$WORK/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho "EXEC: borg $*"\n' > "$SHIM/borg"
chmod +x "$SHIM/borg"

pass=0 fail=0
OUT=""; ERR=""; RC=0

run() { # run <repo> <ssh_original_command>
    OUT="$(SSH_ORIGINAL_COMMAND="$2" PATH="$SHIM:$PATH" bash "$WRAPPER" "$1" 2>"$WORK/err")"
    RC=$?
    ERR="$(cat "$WORK/err")"
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

printf '[server]\nname: test\n' > "$WORK/keyfile_blake2/info.txt"

echo "# borg-wrapper.sh — gating and policy"
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

run "$WORK/keyfile_blake2" "info"
assert_ok_contains "C4 'info' returns info.txt" "name: test"

# --- D. repository state ----------------------------------------------------

run "$WORK/does_not_exist_yet" "borg serve"
assert_serves_exactly "D1 uninitialized repo allowed (borg init path)" "$WORK/does_not_exist_yet"

run "$WORK/nocfg" "borg serve"
assert_deny "D2 non-empty repo without config denied" "DENY: repo non-empty but config missing"

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
