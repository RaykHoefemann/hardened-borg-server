#!/usr/bin/env bash
#
# tests/authorized-keys-generation.sh
# -----------------------------------
# Behavioural tests for build_authorized_keys.sh — the other half of the
# guarantee that borg-wrapper.sh enforces.
#
# The wrapper constrains what a connection may do, but only for keys that
# carry the forced command. This script is what writes it. A key emitted
# without the "command=/borg-wrapper.sh ..." prefix is exempt from append-only,
# path restriction, encryption policy and command gating simultaneously, and
# nothing else in the system would look wrong (DESIGN 4.1, VERIFICATION test 3).
#
# The script uses absolute paths (/config, /log, /repo, /home/borg/.ssh), so
# each case runs inside a bubblewrap sandbox whose root is a tmpfs with the
# fixtures bound at those locations. The real, unmodified script is executed.
#
# LIMIT: `chown borg:borg` is stubbed, because the sandbox has no borg user and
# no real root. Ownership is a property of the container runtime rather than of
# this script's logic, and is covered by VERIFICATION test 3 against a running
# deployment. Everything else here is the genuine behaviour.
#
# Requires: bash, bubblewrap, ssh-keygen.
# Usage:    tests/authorized-keys-generation.sh
#
# shellcheck disable=SC2319
#
# The harness reads `$?` directly after a `[ ... ]` test, which is exactly what
# it means to assert: the condition's own result is the thing being recorded.
# SC2319 warns about capturing a condition's status when a command's was
# intended, which is not the case anywhere below.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/build_authorized_keys.sh"

[ -f "$SCRIPT" ] || { echo "not found: $SCRIPT" >&2; exit 1; }
command -v bwrap      >/dev/null || { echo "bubblewrap is required" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A valid key to reuse; generated once.
ssh-keygen -q -t ed25519 -N '' -C 'fixture' -f "$WORK/id" || exit 1
VALID_KEY="$(cat "$WORK/id.pub")"

mkdir -p "$WORK/shim"
printf '#!/bin/sh\nexit 0\n' > "$WORK/shim/chown"
chmod +x "$WORK/shim/chown"

pass=0 fail=0
RC=0; FIX=""

new_fixture() { # new_fixture — fresh /config, /log, /repo, /home/borg/.ssh
    FIX="$WORK/case$RANDOM$RANDOM"
    mkdir -p "$FIX/config/keys" "$FIX/log" "$FIX/repo" "$FIX/ssh"
    printf 'name=testserver\nlocation=Testville\ncontact=admin@example.com\n' \
        > "$FIX/config/server_info.conf"
}

add_key() { # add_key <client> [content]
    if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$FIX/config/keys/$1.pub"
    else printf '%s\n' "$VALID_KEY" > "$FIX/config/keys/$1.pub"; fi
}

generate() {
    bwrap --tmpfs / \
        --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --symlink usr/sbin /sbin \
        --ro-bind /etc /etc --proc /proc --dev /dev \
        --ro-bind "$SCRIPT" /build_authorized_keys.sh \
        --ro-bind "$WORK/shim" /shim \
        --bind "$FIX/config" /config --bind "$FIX/log" /log \
        --bind "$FIX/repo" /repo --bind "$FIX/ssh" /home/borg/.ssh \
        --setenv PATH /shim:/usr/bin:/usr/sbin:/bin:/sbin \
        -- /usr/bin/bash /build_authorized_keys.sh >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

keys_file() { cat "$FIX/ssh/authorized_keys" 2>/dev/null; }
key_lines() { keys_file | grep -c '^command=' ; }

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() {
    fail=$((fail+1))
    printf 'FAIL %s\n       rc=%s\n' "$1" "$RC"
    printf '       stderr:\n%s\n' "$(tail -5 "$WORK/err" 2>/dev/null | sed 's/^/         /')"
    printf '       authorized_keys:\n%s\n' "$(keys_file | sed 's/^/         /')"
}

assert() { # assert <desc> <condition-result 0|1>
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

echo "# build_authorized_keys.sh — generation and input validation"
echo

# --- 1. the invariant: every emitted line carries the forced command --------

new_fixture
{
  echo 'user1:OWN:/repo/OWN/user1:50G'
  echo 'user2:OWN:/repo/OWN/user2:20G'
  echo 'friend1:MIRROR:/repo/MIRROR/friend1:200G'
} > "$FIX/config/clients.conf"
add_key user1; add_key user2; add_key friend1
generate

[ "$RC" -eq 0 ] && [ "$(key_lines)" -eq 3 ]; assert "1.1 three valid clients produce three entries" $?

# No non-comment, non-empty line may lack the prefix. This is the DESIGN 4.1
# invariant, checked here at the point the file is written.
# grep -c exits 1 when it counts zero, so the count is captured and compared
# rather than relying on the pipeline status under `set -o pipefail`.
unprefixed=$(keys_file | grep -vE '^[[:space:]]*(#|$)' | grep -cv '^command="/borg-wrapper\.sh ')
[ "$unprefixed" -eq 0 ]; assert "1.2 no entry without the forced command prefix" $?

keys_file | grep -q '^command="/borg-wrapper.sh /repo/OWN/user1",restrict ssh-ed25519 '
assert "1.3 entry carries the client's own repo path and 'restrict'" $?

[ -f "$FIX/repo/OWN/user1/info.txt" ] && grep -q 'quota: 50G' "$FIX/repo/OWN/user1/info.txt"
assert "1.4 info.txt generated with the client's quota" $?

grep -q 'name: testserver' "$FIX/repo/OWN/user1/info.txt" 2>/dev/null
assert "1.5 info.txt carries server_info.conf" $?

# --- 2. key-file injection ---------------------------------------------------
#
# A key file with several lines must not become several authorized_keys
# entries; the second line is where an attacker would put a key without a
# forced command.

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
add_key user1 "$VALID_KEY
$VALID_KEY evil-second-entry"
generate

[ "$(key_lines)" -eq 1 ]; assert "2.1 multi-line key file yields exactly one entry" $?
! keys_file | grep -q 'evil-second-entry'
assert "2.2 the injected second line is discarded" $?

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
add_key user1 "$VALID_KEY
no-forced-command-here ssh-rsa AAAA"
generate
unprefixed=$(keys_file | grep -vE '^[[:space:]]*(#|$)' | grep -cv '^command=')
[ "$unprefixed" -eq 0 ]; assert "2.3 no unprefixed line can be smuggled in via the key file" $?

# --- 3. clients.conf field validation ---------------------------------------

check_rejected() { # check_rejected <desc> <clients.conf line>
    new_fixture
    printf '%s\n' "$2" > "$FIX/config/clients.conf"
    # Give every plausible client name a key, so rejection cannot be
    # attributed to a missing key file.
    add_key "$(printf '%s' "$2" | cut -d: -f1)" 2>/dev/null
    add_key user1
    generate
    [ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]
    assert "$1" $?
}

check_rejected "3.1 name with a space rejected"        'bad name:OWN:/repo/OWN/x:50G'
check_rejected "3.2 name with a semicolon rejected"    'bad;name:OWN:/repo/OWN/x:50G'
check_rejected "3.3 name with a slash rejected"        '../evil:OWN:/repo/OWN/x:50G'
check_rejected "3.4 group with metacharacter rejected" 'user1:OWN;rm:/repo/OWN/x:50G'
check_rejected "3.5 relative repo path rejected"       'user1:OWN:repo/OWN/x:50G'
check_rejected "3.6 repo path with space rejected"     'user1:OWN:/repo/OWN/x y:50G'
check_rejected "3.7 quota without unit rejected"       'user1:OWN:/repo/OWN/x:50'
check_rejected "3.8 quota in GB rejected"              'user1:OWN:/repo/OWN/x:50GB'
check_rejected "3.9 non-numeric quota rejected"        'user1:OWN:/repo/OWN/x:abcG'
check_rejected "3.10 missing quota field rejected"     'user1:OWN:/repo/OWN/x'

# --- 4. key-file problems ----------------------------------------------------

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.1 missing key file yields no entry" $?

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
: > "$FIX/config/keys/user1.pub"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.2 empty key file yields no entry" $?

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
add_key user1 "this is not an ssh key"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.3 malformed key rejected" $?

# --- 5. fail-closed on an empty result --------------------------------------
#
# If nothing valid remains, the previous authorized_keys must survive: writing
# an empty file would lock every client out at once.

new_fixture
echo 'bad name:OWN:/repo/OWN/x:50G' > "$FIX/config/clients.conf"
printf '# previous file\ncommand="/borg-wrapper.sh /repo/OWN/old",restrict ssh-ed25519 AAAA old\n' \
    > "$FIX/ssh/authorized_keys"
generate
[ "$RC" -ne 0 ]; assert "5.1 no valid entries exits non-zero" $?
keys_file | grep -q 'old'
assert "5.2 the existing authorized_keys is preserved, not truncated" $?
[ ! -f "$FIX/ssh/authorized_keys.tmp" ]; assert "5.3 no temporary file left behind" $?

# --- 6. server_info.conf is mandatory ---------------------------------------

new_fixture
echo 'user1:OWN:/repo/OWN/user1:50G' > "$FIX/config/clients.conf"
add_key user1
printf 'name=testserver\n' > "$FIX/config/server_info.conf"
generate
[ "$RC" -ne 0 ]; assert "6.1 incomplete server_info.conf aborts" $?

# --- 7. comments and blank lines --------------------------------------------

new_fixture
printf '# a comment\n\nuser1:OWN:/repo/OWN/user1:50G\n' > "$FIX/config/clients.conf"
add_key user1
generate
[ "$(key_lines)" -eq 1 ]; assert "7.1 comments and blank lines are skipped" $?

# --- summary ----------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
