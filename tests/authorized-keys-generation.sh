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
command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required" >&2; exit 1; }

# Two ways to give the script its absolute paths. bubblewrap is preferred
# because it needs no privileges, but unprivileged user namespaces are
# restricted on some hosts (Ubuntu 24.04 confines them via AppArmor), so a
# sudo-backed fallback using the real directories exists. If neither works the
# suite fails rather than skipping: a check that quietly stops checking is the
# failure mode this whole test tree exists to prevent.
MODE=""
if command -v bwrap >/dev/null 2>&1 \
   && bwrap --tmpfs / --ro-bind /usr /usr --symlink usr/bin /bin \
            --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
            --symlink usr/sbin /sbin --proc /proc --dev /dev \
            -- /usr/bin/true 2>/dev/null; then
    MODE=bwrap
elif sudo -n true 2>/dev/null; then
    MODE=sudo
    sudo mkdir -p /config/keys /log /repo /home/borg/.ssh /run/borg-info
    sudo chown -R "$(id -u):$(id -g)" /config /log /repo /home/borg /run/borg-info
else
    echo "FAIL neither bubblewrap nor passwordless sudo is available;" >&2
    echo "     the absolute paths this script needs cannot be provided." >&2
    exit 1
fi
echo "sandbox mode: $MODE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A valid key to reuse; generated once.
ssh-keygen -q -t ed25519 -N '' -C 'fixture' -f "$WORK/id" || exit 1
VALID_KEY="$(cat "$WORK/id.pub")"

printf '9.9.9-test\n' > "$WORK/VERSION"

# In sudo mode the script reads /VERSION directly; bwrap binds the fixture in
# place instead. This has to happen after $WORK exists — putting it in the mode
# detection above referenced $WORK before mktemp had run, which only the sudo
# branch reached, so it passed locally under bwrap and failed on the runner.
if [ "$MODE" = sudo ]; then
    sudo install -m 644 "$WORK/VERSION" /VERSION
fi

mkdir -p "$WORK/shim"
printf '#!/bin/sh\nexit 0\n' > "$WORK/shim/chown"
chmod +x "$WORK/shim/chown"

pass=0 fail=0
RC=0; FIX=""

CFG=""; LOGD=""; REPOD=""; SSHD=""; INFOD=""

new_fixture() { # new_fixture — fresh /config, /log, /repo, /home/borg/.ssh, /run/borg-info
    if [ "$MODE" = bwrap ]; then
        FIX="$WORK/case$RANDOM$RANDOM"
        CFG="$FIX/config"; LOGD="$FIX/log"; REPOD="$FIX/repo"; SSHD="$FIX/ssh"
        INFOD="$FIX/info"
        mkdir -p "$CFG/keys" "$LOGD" "$REPOD" "$SSHD" "$INFOD"
    else
        CFG=/config; LOGD=/log; REPOD=/repo; SSHD=/home/borg/.ssh
        INFOD=/run/borg-info
        rm -rf /config/* /log/* /repo/* /home/borg/.ssh/* /run/borg-info/*
        mkdir -p "$CFG/keys"
    fi
    printf 'name=testserver\nlocation=Testville\ncontact=admin@example.com\n' \
        > "$CFG/server_info.conf"
}

add_key() { # add_key <client> [content]
    if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$CFG/keys/$1.pub"
    else printf '%s\n' "$VALID_KEY" > "$CFG/keys/$1.pub"; fi
}

generate() {
    if [ "$MODE" = sudo ]; then
        PATH="$WORK/shim:$PATH" /usr/bin/bash "$SCRIPT" >"$WORK/out" 2>"$WORK/err"
        RC=$?
        return
    fi
    bwrap --tmpfs / \
        --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --symlink usr/sbin /sbin \
        --ro-bind /etc /etc --proc /proc --dev /dev \
        --ro-bind "$SCRIPT" /build_authorized_keys.sh \
        --ro-bind "$WORK/shim" /shim \
        --ro-bind "$WORK/VERSION" /VERSION \
        --bind "$CFG" /config --bind "$LOGD" /log \
        --bind "$REPOD" /repo --bind "$SSHD" /home/borg/.ssh \
        --bind "$INFOD" /run/borg-info \
        --setenv PATH /shim:/usr/bin:/usr/sbin:/bin:/sbin \
        -- /usr/bin/bash /build_authorized_keys.sh >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

keys_file() { cat "$SSHD/authorized_keys" 2>/dev/null; }
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
  echo 'user1:/repo/user1:50G'
  echo 'user2:/repo/user2:20G'
  echo 'friend1:/repo/friend1:200G'
} > "$CFG/clients.conf"
mkdir -p "$REPOD/user1" "$REPOD/user2" "$REPOD/friend1"
add_key user1; add_key user2; add_key friend1
generate

[ "$RC" -eq 0 ] && [ "$(key_lines)" -eq 3 ]; assert "1.1 three valid clients produce three entries" $?

# No non-comment, non-empty line may lack the prefix. This is the DESIGN 4.1
# invariant, checked here at the point the file is written.
# grep -c exits 1 when it counts zero, so the count is captured and compared
# rather than relying on the pipeline status under `set -o pipefail`.
unprefixed=$(keys_file | grep -vE '^[[:space:]]*(#|$)' | grep -cv '^command="/borg-wrapper\.sh ')
[ "$unprefixed" -eq 0 ]; assert "1.2 no entry without the forced command prefix" $?

keys_file | grep -q '^command="/borg-wrapper.sh /repo/user1",restrict ssh-ed25519 '
assert "1.3 entry carries the client's own repo path and 'restrict'" $?

INFO1="$INFOD/repo/user1.txt"

# Labelled, and the label is part of the assertion: the wrapper prints a live
# 'Used: X of Y' line right after this text, whose Y is the enforced limit. An
# unlabelled 'quota:' beside it reads as the same claim, which is how a client
# can be shown two different limits at once (#28).
[ -f "$INFO1" ] && grep -q 'quota (configured): 50G' "$INFO1"
assert "1.4 info text rendered with the client's quota, labelled as configured" $?

[ -f "$INFO1" ] && ! grep -qE '^quota: ' "$INFO1"
assert "1.4b no bare 'quota:' line that could be read as the enforced limit" $?

grep -q 'name: testserver' "$INFO1" 2>/dev/null
assert "1.5 info text carries server_info.conf" $?

# The client is told which software serves it and where to read its source —
# both baked into the image rather than taken from operator-editable config,
# so a deployment cannot claim to be a version it is not.
grep -q 'version: 9.9.9-test' "$INFO1" 2>/dev/null
assert "1.6 info text reports the image's release version" $?

grep -q 'source: https://github.com/RaykHoefemann/hardened-borg-server' "$INFO1" 2>/dev/null
assert "1.7 info text reports the source repository" $?

# The reason it lives under /run at all: `borg init` refuses a directory that
# is not empty, so anything the server leaves in a client's repository makes
# that client's very first command fail. This is the regression guard.
[ -z "$(ls -A "$REPOD/user1")" ]
assert "1.8 the client's repository directory is left empty for borg init" $?

# Two clients, two files — no client's file is reachable from another's path.
[ -f "$INFOD/repo/friend1.txt" ] && grep -q 'user: friend1' "$INFOD/repo/friend1.txt"
assert "1.9 each client gets its own file, mirroring its repo path" $?

# Migration: a leftover from the releases that wrote into the repository is
# removed, or it keeps blocking init for exactly the clients this bug hit.
printf 'stale\n' > "$REPOD/user1/info.txt"
generate
[ "$RC" -eq 0 ] && [ ! -e "$REPOD/user1/info.txt" ]
assert "1.10 a legacy info.txt in the repository is removed" $?

# A client removed from clients.conf must not keep an info text in a live
# container — its key is gone from authorized_keys in the same run.
{
  echo 'user1:/repo/user1:50G'
} > "$CFG/clients.conf"
generate
[ "$RC" -eq 0 ] && [ -f "$INFO1" ] && [ ! -e "$INFOD/repo/user2.txt" ]
assert "1.11 info text of a removed client is pruned" $?

# --- 2. key-file injection ---------------------------------------------------
#
# A key file with several lines must not become several authorized_keys
# entries; the second line is where an attacker would put a key without a
# forced command.

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
add_key user1 "$VALID_KEY
$VALID_KEY evil-second-entry"
generate

[ "$(key_lines)" -eq 1 ]; assert "2.1 multi-line key file yields exactly one entry" $?
! keys_file | grep -q 'evil-second-entry'
assert "2.2 the injected second line is discarded" $?

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
add_key user1 "$VALID_KEY
no-forced-command-here ssh-rsa AAAA"
generate
unprefixed=$(keys_file | grep -vE '^[[:space:]]*(#|$)' | grep -cv '^command=')
[ "$unprefixed" -eq 0 ]; assert "2.3 no unprefixed line can be smuggled in via the key file" $?

# --- 3. clients.conf field validation ---------------------------------------

check_rejected() { # check_rejected <desc> <clients.conf line>
    new_fixture
    printf '%s\n' "$2" > "$CFG/clients.conf"
    # Give every plausible client name a key, so rejection cannot be
    # attributed to a missing key file.
    add_key "$(printf '%s' "$2" | cut -d: -f1)" 2>/dev/null
    add_key user1
    generate
    [ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]
    assert "$1" $?
}

check_rejected "3.1 name with a space rejected"        'bad name:/repo/x:50G'
check_rejected "3.2 name with a semicolon rejected"    'bad;name:/repo/x:50G'
check_rejected "3.3 name with a slash rejected"        '../evil:/repo/x:50G'
check_rejected "3.4 repo field with metacharacter rejected" 'user1:/repo/x;rm:50G'
check_rejected "3.5 relative repo path rejected"       'user1:repo/x:50G'
check_rejected "3.6 repo path with space rejected"     'user1:/repo/x y:50G'
check_rejected "3.7 quota without unit rejected"       'user1:/repo/x:50'
check_rejected "3.8 quota in GB rejected"              'user1:/repo/x:50GB'
check_rejected "3.9 non-numeric quota rejected"        'user1:/repo/x:abcG'
check_rejected "3.10 missing quota field rejected"     'user1:/repo/x'

# --- 4. key-file problems ----------------------------------------------------

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.1 missing key file yields no entry" $?

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
: > "$CFG/keys/user1.pub"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.2 empty key file yields no entry" $?

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
add_key user1 "this is not an ssh key"
generate
[ "$RC" -ne 0 ] || [ "$(key_lines)" -eq 0 ]; assert "4.3 malformed key rejected" $?

# --- 5. an empty result must not destroy a working authorized_keys ----------
#
# If nothing valid remains, a previous authorized_keys must survive: writing an
# empty file over it would lock every client out at once, and a truncated
# clients.conf must never be able to cause that.
#
# Note what the condition is: an existing file, not an empty client list. The
# two used to be conflated, which is why a server could not start before its
# first client existed (section 8).

new_fixture
echo 'bad name:/repo/x:50G' > "$CFG/clients.conf"
printf '# previous file\ncommand="/borg-wrapper.sh /repo/old",restrict ssh-ed25519 AAAA old\n' \
    > "$SSHD/authorized_keys"
generate
[ "$RC" -ne 0 ]; assert "5.1 no valid entries exits non-zero" $?
keys_file | grep -q 'old'
assert "5.2 the existing authorized_keys is preserved, not truncated" $?
[ ! -f "$SSHD/authorized_keys.tmp" ]; assert "5.3 no temporary file left behind" $?

# The same protection has to hold when the client list went empty entirely,
# which is what a truncated clients.conf looks like.
new_fixture
: > "$CFG/clients.conf"
printf '# previous file\ncommand="/borg-wrapper.sh /repo/old",restrict ssh-ed25519 AAAA old\n' \
    > "$SSHD/authorized_keys"
generate
{ [ "$RC" -ne 0 ] && keys_file | grep -q 'old'; }
assert "5.4 an emptied clients.conf does not truncate an existing file" $?

# --- 6. server_info.conf is mandatory ---------------------------------------

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
add_key user1
printf 'name=testserver\n' > "$CFG/server_info.conf"
generate
[ "$RC" -ne 0 ]; assert "6.1 incomplete server_info.conf aborts" $?

# --- 7. comments and blank lines --------------------------------------------

new_fixture
printf '# a comment\n\nuser1:/repo/user1:50G\n' > "$CFG/clients.conf"
add_key user1
generate
[ "$(key_lines)" -eq 1 ]; assert "7.1 comments and blank lines are skipped" $?

# --- 8. cold start: a server with no clients yet ----------------------------
#
# The state every installation passes through: config/ holds server_info.conf
# and nothing else, because clients.conf and keys/ are written by
# 00-ssh-create-user.sh, which has not run yet. This used to abort startup, so
# the container could not run until a client existed — SERVERINSTALL verifies
# the service in step 6 but provisions the first client in step 8.
#
# Starting with no keys is not a weaker position than refusing to start: sshd
# rejects everyone either way (no key in the file can authenticate, and no
# other method is enabled). Refusing merely also prevented the operator from
# checking the container, the mounts and the quota enforcement first.

new_fixture
rm -f "$CFG/clients.conf"
rm -rf "$CFG/keys"
generate
[ "$RC" -eq 0 ]; assert "8.1 a fresh config directory does not abort startup" $?
[ -f "$CFG/clients.conf" ]; assert "8.2 the missing clients.conf is created" $?
[ -d "$CFG/keys" ]; assert "8.3 the missing key directory is created" $?
[ -f "$SSHD/authorized_keys" ]; assert "8.4 an authorized_keys is written" $?
[ "$(key_lines)" -eq 0 ]; assert "8.5 it authorizes nobody" $?

# The created file has to be one 00-ssh-create-user.sh can append to and this
# script can read back, i.e. it must parse as an empty roster rather than as a
# client named "#".
generate
{ [ "$RC" -eq 0 ] && [ "$(key_lines)" -eq 0 ]; }
assert "8.6 the created clients.conf parses as an empty roster on the next run" $?

# An empty (rather than absent) clients.conf is the same state — that is what
# an operator gets after removing the last client.
new_fixture
: > "$CFG/clients.conf"
generate
{ [ "$RC" -eq 0 ] && [ -f "$SSHD/authorized_keys" ] && [ "$(key_lines)" -eq 0 ]; }
assert "8.7 an empty clients.conf starts the server with no keys" $?

# The gap between 00-ssh-create-user.sh and 01-ssh-set-user-key.sh: the client
# is in clients.conf, but its key file is still the empty placeholder that 00
# creates. A restart in that window must not put the container into a loop.
new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
: > "$CFG/keys/user1.pub"
generate
{ [ "$RC" -eq 0 ] && [ "$(key_lines)" -eq 0 ]; }
assert "8.8 a client whose key is not set yet does not abort startup" $?

# server_info.conf stays mandatory, and is checked before anything is created:
# it ships with the release and is never generated, so its absence means the
# /config volume is not the operator's config directory. Creating a clients.conf
# there would dress a mount failure up as a valid state.
new_fixture
rm -f "$CFG/server_info.conf" "$CFG/clients.conf"
generate
[ "$RC" -ne 0 ]; assert "8.9 a missing server_info.conf still aborts" $?
[ ! -f "$CFG/clients.conf" ]
assert "8.10 nothing is created in a /config that failed the canary check" $?

# --- 9. repository directories are the host's to create ---------------------
#
# This script used to `mkdir -p` a client's repository directory when it found
# one missing, and it could not do that job: it runs as root inside the
# container, so the directory came out root-owned — unwritable by the 'borg'
# user the client is served as — and carried no XFS project id, so no quota
# applied to it. Creating one correctly needs `podman unshare` for the
# ownership and `sudo xfs_quota` for the project id, neither of which exists in
# here.
#
# The damage was not only that the directory was wrong. It made the state
# unstable: a client whose directory had been deleted read as MISSING on host
# until the next container start, and as an unquotaed client afterwards — the
# same incident wearing two different faults (issues #29, #30).

new_fixture
echo 'user1:/repo/user1:50G' > "$CFG/clients.conf"
add_key user1
rm -rf "$REPOD/user1"
generate
[ ! -d "$REPOD/user1" ]
assert "9.1 a missing repository directory is not created by the generator" $?

# Still authorized, deliberately. The wrapper answers such a connection with
# 'DENY: repository directory missing – needs operator action', which names the
# problem; dropping the key line would produce an anonymous SSH rejection
# instead and tell the client nothing.
[ "$(key_lines)" -eq 1 ]
assert "9.2 ... and the client is still authorized, to be refused with a reason" $?

grep -q 'Repository directory .* is missing' "$LOGD/build_authorized_keys.log"
assert "9.3 ... and the missing directory is reported in the log" $?

# The info text lives under /run and is this script's to write, so that mkdir
# stays: it is container-owned state, not host-owned state.
[ -f "$INFOD/repo/user1.txt" ]
assert "9.4 the info text is still rendered for that client" $?

# --- summary ----------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
