#!/usr/bin/env bash
#
# tests/host-scripts.sh
# ---------------------
# Behavioural tests for the host-side scripts that need no privileges:
#
#   01-ssh-set-user-key.sh   input validation and key handling
#   09-show-all-users.sh     clients.conf parsing, grouping, quota reporting
#   config.sh                the quota helpers shared by 00/02/09
#
# Plus one packaging check that is not behavioural at all (section 0): the file
# mode git records for every tracked script. It lives here because it guards
# the same scripts, and because the defect it prevents made all of them
# unusable from a release checkout without any of them being wrong.
#
# 00-ssh-create-user.sh and 02-change-user-quota.sh are not covered end to
# end: both require sudo and a real XFS mount with enforcing project quotas,
# which a CI runner does not have. What both of them rely on to decide whether
# a quota really took effect — quota_verify and friends in config.sh — is
# covered here, because every one of those reads the limit through df, and df
# can be substituted (section 2).
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

# --- df substitution -------------------------------------------------------
#
# Every quota figure the host scripts print or verify is read through df: for
# a directory under an XFS project quota, statvfs() reports the project's hard
# limit as the filesystem size. That is the whole mechanism, so replacing df
# with a stub earlier in PATH exercises it exactly — no XFS, no root, no
# xfs_quota. The stub answers from "<path>:<size_kib>:<used_kib>" lines in
# $DF_STUB_DATA and reports 0/0 for anything not listed.
DF_BIN="$WORK/dfstub"
mkdir -p "$DF_BIN"
cat > "$DF_BIN/df" <<'STUB'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
size=0; used=0
while IFS=: read -r path s u; do
    [ "$path" = "$p" ] && { size="$s"; used="$u"; }
done < "$DF_STUB_DATA"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/stub $size $used $((size-used)) 1% /stub"
STUB
chmod +x "$DF_BIN/df"

df_stub() { printf '%s\n' "$@" > "$WORK/df.data"; export DF_STUB_DATA="$WORK/df.data"; }
run_stubbed() { OUT="$(PATH="$DF_BIN:$PATH" "$@" 2>&1)"; RC=$?; }

# Sources config.sh the way the real scripts do and calls one of its helpers,
# so the helpers are tested as the scripts actually reach them.
add_driver() {
    cat > "$T/scripts/helper-driver.sh" <<'DRV'
#!/bin/sh
. "$(dirname "$0")/config.sh"
"$@"
DRV
    chmod +x "$T/scripts/helper-driver.sh"
}
GIB=1048576  # KiB per GiB

echo "# host scripts — file modes, 01-ssh-set-user-key.sh, config.sh quota helpers, 09-show-all-users.sh"
echo

# =========================================================================
# 0. file modes — every tracked script is executable in git
# =========================================================================
#
# The mode that matters is the one git records, not the one the file happens
# to carry in this working tree: those two disagree silently, and a script can
# be executable here while a fresh clone gets 100644. That is exactly how
# v0.1.0-beta.21 shipped every script under scripts/ non-executable — an
# operator following SERVERINSTALL step 4 got "Permission denied" from
# 50-service-install.sh on a clean checkout of the tag, with nothing wrong in
# any script's content.
#
# So the assertion reads the index. Nothing is skipped when git is missing: a
# check that quietly stops checking is how the mode drifted unnoticed in the
# first place.

in_git=1
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    in_git=0
fi
RC=0; OUT="git, or a git checkout, is not available — index modes cannot be read"
[ "$in_git" -eq 0 ]; assert "0.1 running inside a git checkout, so index modes are readable" $?

if [ "$in_git" -eq 0 ]; then
    # ls-files --stage prints "<mode> <sha> <stage>\t<path>"; anything not
    # 100755 is a script a fresh clone would refuse to run.
    RC=0
    OUT="$(git -C "$ROOT" ls-files --stage '*.sh' | grep -v '^100755 ')"
    [ -z "$OUT" ]; assert "0.2 every tracked *.sh is mode 100755 in the index" $?
fi

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
# 2. config.sh — quota helpers (used by 00 to set, 02 to change, 09 to show)
# =========================================================================
echo

new_tree
add_driver
DRV="$T/scripts/helper-driver.sh"

run sh "$DRV" quota_kib 50G
{ [ "$RC" -eq 0 ] && [ "$OUT" = "$((50 * GIB))" ]; }
assert "2.1 quota_kib converts <n>G to KiB" $?

for bad_q in 50 50M 0G "" abc 5.5G; do
    run sh "$DRV" quota_kib "$bad_q"
    [ "$RC" -ne 0 ] || { OUT="accepted '$bad_q' -> $OUT"; break; }
done
[ "$RC" -ne 0 ]; assert "2.2 quota_kib rejects anything that is not <n>G, n>0" $?

# The point of quota_verify: a limit that xfs_quota accepted still has to be
# the limit the kernel enforces on that directory. Only the read-back proves
# it, so the two directions below are what 00 and 02 stake their exit codes on.
df_stub "$T/repo/OWN/user1:$((50 * GIB)):$((5 * GIB))"
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/user1" 50G
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '50.0 GiB is in effect'; }
assert "2.3 quota_verify accepts a limit that is really enforced" $?

printf '%s' "$OUT" | grep -q '5.0 GiB of 50.0 GiB (10%)'
assert "2.4 quota_verify shows current usage against the limit" $?

# The dangerous case: the command succeeded but the directory is governed by
# something else (wrong project id, quotas not enforcing) — here it still
# reports the whole volume.
df_stub "$T/repo/OWN/user1:$((4000 * GIB)):$((5 * GIB))"
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/user1" 50G
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'NOT enforced'; }
assert "2.5 quota_verify rejects a limit that is not in effect" $?

printf '%s' "$OUT" | grep -q '4000.0 GiB'
assert "2.6 quota_verify names the limit that is actually enforced" $?

# An unreadable directory must fail closed, never pass for lack of an answer.
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/nonexistent-and-unstubbed" 50G
[ "$RC" -ne 0 ]; assert "2.7 quota_verify fails when nothing can be read back" $?

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

# --- the ENFORCED column -------------------------------------------------
#
# clients.conf records what was requested; only the filesystem knows what is
# applied. The listing has to make a disagreement visible, otherwise an
# operator planning against the quota sum (OPERATIONS Chapter 10.2) is
# planning against numbers nothing enforces.
setup_09
df_stub \
    "$T/repo:$((4000 * GIB)):$((100 * GIB))" \
    "$T/repo/OWN/user1:$((50 * GIB)):$((5 * GIB))" \
    "$T/repo/OWN/user2:$((20 * GIB)):0" \
    "$T/repo/MIRROR/friend1:$((200 * GIB)):$((10 * GIB))"
run_stubbed "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -qE '^user1 +50G +ok +5\.0 GiB of 50\.0 GiB \(10%\)'
assert "9.7 a limit matching clients.conf is reported as ok" $?

printf '%s' "$OUT" | grep -q '(!)'
[ $? -ne 0 ]; assert "9.8 no drift is flagged when every limit matches" $?

# user2 is enforced at 10G while clients.conf claims 20G.
setup_09
df_stub \
    "$T/repo:$((4000 * GIB)):$((100 * GIB))" \
    "$T/repo/OWN/user1:$((50 * GIB)):$((5 * GIB))" \
    "$T/repo/OWN/user2:$((10 * GIB)):0" \
    "$T/repo/MIRROR/friend1:$((200 * GIB)):$((10 * GIB))"
run_stubbed "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -qE '^user2 +20G +10\.0 GiB \(!\)'
assert "9.9 a limit differing from clients.conf is flagged with its real value" $?

printf '%s' "$OUT" | grep -q 'does not match clients.conf'
assert "9.10 the drift hint is printed once a mismatch was seen" $?

# A directory under no project quota at all: df reports the whole volume,
# which must not be presented as a very generous quota.
setup_09
df_stub \
    "$T/repo:$((4000 * GIB)):$((100 * GIB))" \
    "$T/repo/OWN/user1:$((4000 * GIB)):$((5 * GIB))" \
    "$T/repo/OWN/user2:$((20 * GIB)):0" \
    "$T/repo/MIRROR/friend1:$((200 * GIB)):$((10 * GIB))"
run_stubbed "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -qE '^user1 +50G +none \(!\) +5\.0 GiB \(unlimited\)'
assert "9.11 a directory with no quota in effect is reported as unlimited" $?

# --- summary -------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
