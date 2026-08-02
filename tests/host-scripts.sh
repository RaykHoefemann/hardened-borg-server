#!/usr/bin/env bash
#
# tests/host-scripts.sh
# ---------------------
# Behavioural tests for the host-side scripts that need no privileges:
#
#   01-ssh-set-user-key.sh   input validation and key handling
#   09-show-all-users.sh     clients.conf parsing and grouping
#
# 00-ssh-create-user.sh and 02-change-user-quota.sh are not covered: both
# require sudo and a real XFS mount with enforcing project quotas, which a CI
# runner does not have. Only their input validation would be testable without
# one, and that is not where their risk lies.
#
# The scripts derive every path from the location of the config.sh they source,
# so each case runs against a throwaway installation tree rather than the
# repository itself.
#
# 09 is deliberately exercised under bash-invoked-as-sh as well. Its shebang is
# /bin/sh, which is dash on Debian but bash on Fedora CoreOS — the platform this
# project requires — and a bug that only appears under bash is exactly what
# slipped through before (see the GROUPS regression, section 9.1).
#
# Requires: bash, ssh-keygen.
# Usage:    tests/host-scripts.sh
#
# shellcheck disable=SC2319
#
# The harness reads `$?` directly after a `[ ... ]` test, which is exactly what
# it means to assert: the condition's own result is the thing being recorded.
# SC2319 warns about capturing a condition's status when a command's was
# intended, which is not the case anywhere below.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ssh-keygen -q -t ed25519 -N '' -C 'fixture' -f "$WORK/id" || exit 1
ssh-keygen -q -t ed25519 -N '' -C 'second' -f "$WORK/id2" || exit 1

# bash reached under the name "sh" — how /bin/sh behaves on Fedora CoreOS.
ln -sf "$(command -v bash)" "$WORK/sh"

pass=0 fail=0
OUT=""; RC=0; T=""

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n       rc=%s\n       output:\n%s\n' \
        "$1" "$RC" "$(printf '%s' "$OUT" | sed 's/^/         /')"; }
assert() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

new_tree() { # fresh installation tree with scripts/ and config/
    T="$WORK/tree$RANDOM$RANDOM"
    mkdir -p "$T/config/keys" "$T/repo"
    cp -r "$ROOT/scripts" "$T/scripts"
    # HOST_REPO_BASE is the one value every operator edits for their host.
    sed -i "s|^HOST_REPO_BASE=.*|HOST_REPO_BASE=\"$T/repo/\"|" "$T/scripts/config.sh"
}

run() { OUT="$("$@" 2>&1)"; RC=$?; }
run_in() { local sh="$1"; shift; OUT="$("$sh" "$@" 2>&1)"; RC=$?; }

echo "# host scripts — 01-ssh-set-user-key.sh, 09-show-all-users.sh"
echo

# =========================================================================
# 01-ssh-set-user-key.sh
# =========================================================================

new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"

run sh "$T/scripts/01-ssh-set-user-key.sh"
[ "$RC" -ne 0 ]; assert "1.1 missing arguments rejected" $?

run sh "$T/scripts/01-ssh-set-user-key.sh" nosuchuser "$WORK/id.pub"
{ [ "$RC" -ne 0 ] && [ ! -f "$T/config/keys/nosuchuser.pub" ]; }
assert "1.2 unknown user rejected, no key file created" $?

run sh "$T/scripts/01-ssh-set-user-key.sh" user1 "$WORK/id.pub"
{ [ "$RC" -eq 0 ] && [ -s "$T/config/keys/user1.pub" ]; }
assert "1.3 valid key from a file is stored" $?

new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"
run sh "$T/scripts/01-ssh-set-user-key.sh" user1 "$(cat "$WORK/id.pub")"
{ [ "$RC" -eq 0 ] && grep -q 'ssh-ed25519' "$T/config/keys/user1.pub"; }
assert "1.4 valid key passed as a string is stored" $?

new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"
run sh "$T/scripts/01-ssh-set-user-key.sh" user1 "this is not a key"
{ [ "$RC" -ne 0 ] && [ ! -e "$T/config/keys/user1.pub" ]; }
assert "1.5 malformed key rejected and the partial file removed" $?

# Overwrite confirmation
new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"
cp "$WORK/id.pub" "$T/config/keys/user1.pub"
OUT="$(printf 'n\n' | sh "$T/scripts/01-ssh-set-user-key.sh" user1 "$WORK/id2.pub" 2>&1)"; RC=$?
diff -q "$WORK/id.pub" "$T/config/keys/user1.pub" >/dev/null
assert "1.6 declining the overwrite prompt keeps the existing key" $?

new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"
cp "$WORK/id.pub" "$T/config/keys/user1.pub"
OUT="$(printf 'y\n' | sh "$T/scripts/01-ssh-set-user-key.sh" user1 "$WORK/id2.pub" 2>&1)"; RC=$?
diff -q "$WORK/id2.pub" "$T/config/keys/user1.pub" >/dev/null
assert "1.7 confirming the overwrite replaces the key" $?

# A failed overwrite must not destroy the key that was already working: the
# client would lose access on the next container restart, and the operator
# would have no copy left to restore from.
new_tree
printf 'user1:OWN:/repo/OWN/user1:50G\n' > "$T/config/clients.conf"
cp "$WORK/id.pub" "$T/config/keys/user1.pub"
OUT="$(printf 'y\n' | sh "$T/scripts/01-ssh-set-user-key.sh" user1 "not a key" 2>&1)"; RC=$?
[ -s "$T/config/keys/user1.pub" ] && diff -q "$WORK/id.pub" "$T/config/keys/user1.pub" >/dev/null
assert "1.8 a rejected overwrite leaves the previous key intact" $?

# =========================================================================
# 09-show-all-users.sh
# =========================================================================
echo

setup_09() {
    new_tree
    {
      echo 'user1:OWN:/repo/OWN/user1:50G'
      echo 'user2:OWN:/repo/OWN/user2:20G'
      echo 'friend1:MIRROR:/repo/MIRROR/friend1:200G'
    } > "$T/config/clients.conf"
    mkdir -p "$T/repo/OWN/user1" "$T/repo/OWN/user2" "$T/repo/MIRROR/friend1"
}

# 9.1 The GROUPS regression. In bash, GROUPS is a built-in array of the
# operator's numeric group IDs and assignments to it are silently ignored, so
# the group loop iterated over those instead of the configured group names —
# printing no clients at all on any host where /bin/sh is bash.
setup_09
run_in "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -q '=== OWN ===' && printf '%s' "$OUT" | grep -q '=== MIRROR ==='
assert "9.1 group headers come from clients.conf under bash-as-sh" $?

printf '%s' "$OUT" | grep -qE '^=== [0-9]+ ==='
[ $? -ne 0 ]; assert "9.2 no numeric group ID is printed as a header" $?

for u in user1 user2 friend1; do printf '%s' "$OUT" | grep -q "$u" || { false; break; }; done
assert "9.3 every configured client is listed" $?

# Same run under the system /bin/sh, whatever that is on this machine.
setup_09
run sh "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -q '=== OWN ===' && printf '%s' "$OUT" | grep -q '=== MIRROR ==='
assert "9.4 same result under the system /bin/sh" $?

printf '%s' "$OUT" | grep -q 'Total clients: 3'
assert "9.5 client count reported" $?

# A repository directory that is absent on the host must be reported as such
# rather than silently shown as empty usage.
setup_09
rm -rf "$T/repo/OWN/user2"
run_in "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -q 'MISSING on host'
assert "9.6 a missing repository directory is flagged" $?

# --- summary -------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
