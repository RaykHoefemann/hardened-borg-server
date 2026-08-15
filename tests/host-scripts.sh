#!/usr/bin/env bash
#
# tests/host-scripts.sh
# ---------------------
# Behavioural tests for the host-side scripts that need no privileges:
#
#   00-ssh-create-user.sh    creating a client: the repository directory, its
#                            ownership, project-id allocation, the quota
#                            preview and confirmation, the abort paths
#   01-ssh-set-user-key.sh   input validation and key handling
#   02-change-user-quota.sh  the preview, the refusal of a limit that cannot be
#                            enforced, and the rollback of one that does not
#                            verify
#   09-show-all-users.sh     clients.conf parsing, grouping, quota reporting
#   99-container-status.sh   how a unit's state is rendered
#   config.sh                the quota helpers shared by 00/02/09
#
# Plus two packaging checks that are not behavioural at all (section 0): the
# file mode git records for every tracked script, and the absence of
# User=/Group= from the systemd unit template. Neither is about what a script
# computes; both are about defects that made a correct release unusable on the
# host without a single line of logic being wrong.
#
# 00-ssh-create-user.sh (section 10) and 02-change-user-quota.sh (section 12)
# are covered by substituting the commands they reach outside themselves —
# sudo, xfs_quota, lsattr, podman and df. Both were once excluded for needing
# sudo and a real XFS mount with enforcing project quotas, and both broke in
# ways that had nothing to do with either: see the notes at those sections.
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

echo "# host scripts — packaging, config.sh quota helpers, 00/01/02 client management, 09 listing, 99 status"
echo

# =========================================================================
# 0. packaging — what a release checkout hands the operator
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

# --- the systemd unit template -------------------------------------------
#
# User=/Group= must not appear in this unit. It is installed into
# ~/.config/systemd/user/ and started with systemctl --user, where the manager
# is already the target user and unprivileged. systemd.exec(5) permits User=
# there in principle — "the only valid setting is the same user the user's
# service manager is running as" — but setting it makes systemd re-initialize
# the supplementary group list, which needs CAP_SETGID. The kernel refuses even
# when the resulting list would be identical, so the service dies at the GROUP
# step with status=216/GROUP before podman runs at all, and Restart=on-failure
# loops it. The unit shipped that way through v0.1.0-beta.21 and could never
# start once.
#
# The directives read as a correct restatement of who the service runs as,
# which is exactly why they survive a copy from a system-unit template. The
# copy embedded in DEPLOYMENT.md 6.2 is checked too: it is presented to the
# reader as the file's contents, so it can reintroduce them by being followed.
#
# A plain grep is the right tool here, blunt as it looks. Static validation
# does not catch this: `systemd-analyze --user verify` run against the unit as
# it shipped in v0.1.0-beta.21 reports nothing at all, because the directives
# are syntactically valid and the value is the permitted one. The failure only
# exists at process-spawn time, which no offline check reaches.

UNIT="$ROOT/systemd/container-borg-server.service"
RC=0; OUT="not found: $UNIT"
[ -f "$UNIT" ]; assert "0.3 the systemd unit template exists" $?

n=4
for f in "$UNIT" "$ROOT/docs/DEPLOYMENT.md"; do
    # basename is resolved into a variable first, deliberately. Calling it
    # inside the assert's description would run it during argument expansion,
    # i.e. after the [ ... ] below but before $? is read — so the assertion
    # would record basename's exit status instead of the test's and pass
    # unconditionally.
    base="$(basename "$f")"
    RC=0
    OUT="$(grep -nE '^(User|Group)=' "$f" 2>/dev/null)"
    [ -z "$OUT" ]
    assert "0.$n no User=/Group= directive in $base" $?
    n=$((n + 1))
done

# podman runs in the foreground under this unit, so systemd already captures
# its output. Without passthrough, podman's default journald driver logs the
# container a second time under the same unit — every line present twice for
# anyone reading `journalctl --user -u container-borg-server`, a failed start
# included.
RC=0
OUT="$(grep -A6 '^ExecStart=' "$UNIT")"
grep -q -- '--log-driver=passthrough' "$UNIT"
assert "0.6 the unit hands container output to systemd rather than journalling it twice" $?

# DEPLOYMENT.md 6.2 presents the unit as the file's contents, so a reader can
# reintroduce anything the two copies disagree about by following the document
# — which is why the User=/Group= check above already covers both. Comparing
# them outright is the general form of that: whatever the template says, the
# documented copy says the same.
RC=0
OUT="$(diff <(awk '/^```ini$/{f=1;next} f&&/^```$/{exit} f' "$ROOT/docs/DEPLOYMENT.md") "$UNIT")"
[ -z "$OUT" ]
assert "0.7 the unit quoted in DEPLOYMENT.md is identical to the template" $?

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

# A shell multiplies in signed 64 bits. 13 digits of GiB wrap it, and the
# result comes back small or negative — which would pass the check that
# refuses a quota larger than the volume, the one thing standing between a
# typo and a client the filesystem does not bound.
for huge_q in 9999999999999G 99999999999999999999G; do
    run sh "$DRV" quota_kib "$huge_q"
    [ "$RC" -ne 0 ] || { OUT="accepted '$huge_q' -> $OUT"; break; }
done
[ "$RC" -ne 0 ]; assert "2.3 quota_kib rejects a value that would overflow the arithmetic" $?

# The largest value it does accept still has to convert correctly.
run sh "$DRV" quota_kib 999999999999G
[ "$RC" -eq 0 ] && [ "$OUT" = "1048575999998951424" ]
assert "2.4 ... and converts the largest value it accepts exactly" $?

# The point of quota_verify: a limit that xfs_quota accepted still has to be
# the limit the kernel enforces on that directory. Only the read-back proves
# it, so the two directions below are what 00 and 02 stake their exit codes on.
df_stub "$T/repo/OWN/user1:$((50 * GIB)):$((5 * GIB))"
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/user1" 50G
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '50.0 GiB is in effect'; }
assert "2.5 quota_verify accepts a limit that is really enforced" $?

printf '%s' "$OUT" | grep -q '5.0 GiB of 50.0 GiB (10%)'
assert "2.6 quota_verify shows current usage against the limit" $?

# The dangerous case: the command succeeded but the directory is governed by
# something else (wrong project id, quotas not enforcing) — here it still
# reports the whole volume.
df_stub "$T/repo/OWN/user1:$((4000 * GIB)):$((5 * GIB))"
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/user1" 50G
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'NOT enforced'; }
assert "2.7 quota_verify rejects a limit that is not in effect" $?

printf '%s' "$OUT" | grep -q '4000.0 GiB'
assert "2.8 quota_verify names the limit that is actually enforced" $?

# An unreadable directory must fail closed, never pass for lack of an answer.
run_stubbed sh "$DRV" quota_verify "$T/repo/OWN/nonexistent-and-unstubbed" 50G
[ "$RC" -ne 0 ]; assert "2.9 quota_verify fails when nothing can be read back" $?

# =========================================================================
# 09-show-all-users.sh
# =========================================================================
echo

# The fixture carries the comment header the container's
# build_authorized_keys.sh writes into a clients.conf it finds missing — which
# is every installation whose server was started before its first client
# existed, i.e. the order SERVERINSTALL.md documents. The old fixture was bare
# data, so a parser that treats comments as clients passed all of section 9
# while producing a phantom group, two spurious "MISSING on host" rows and a
# client count of 12 on real installations.
#
# The two trailing lines are not from the real header. They are the shapes a
# filter has to survive regardless of how that header is worded: a blank line,
# and a comment that does not begin in column one.
clients_conf_header() {
    cat <<'HDR'
# Client roster — one line per client:
#
#   name:group:repo:quota
#
# e.g.  user1-os1-pc1:OWN:/repo/OWN/user1-os1-pc1:50G
#
# group is OWN (your own devices) or MIRROR (external partners); quota is
# mandatory and has the form <digits>G. Written by scripts/00-ssh-create-user.sh
# — there is normally no reason to edit this file by hand.

   # indented comment
HDR
}

setup_09() {
    new_tree
    {
      clients_conf_header
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
printf '%s' "$OUT" | grep -qE '^user1 +50G +1% +ok +5\.0 GiB of 50\.0 GiB \(10%\)'
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
printf '%s' "$OUT" | grep -qE '^user2 +20G +0% +10\.0 GiB \(!\)'
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
printf '%s' "$OUT" | grep -qE '^user1 +50G +1% +none \(!\) +5\.0 GiB \(unlimited\)'
assert "9.11 a directory with no quota in effect is reported as unlimited" $?

# --- comment lines are not clients ---------------------------------------
#
# Everything above runs against a clients.conf that carries the real header
# (see setup_09). These three name what that header must not turn into. The
# damage is not cosmetic: "MISSING on host" is the marker for a real client
# whose repository is gone, and emitting it on every healthy installation
# trains the operator to ignore the one signal this listing exists to raise.
setup_09
run_in "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -E '^=== ' | grep -qvE '^=== (OWN|MIRROR) ===$'
[ $? -ne 0 ]; assert "9.12 the format legend does not become a group of its own" $?

printf '%s' "$OUT" | grep -q 'MISSING on host'
[ $? -ne 0 ]; assert "9.13 no client is invented from a comment line" $?

# The example line in the header has OWN as its second field, so it lands in a
# real group rather than a phantom one — the count is where it shows up.
printf '%s' "$OUT" | grep -q 'Total clients: 3'
assert "9.14 the count is of clients, not of lines" $?

# A clients.conf holding only that header is not an empty file, but it
# describes no clients — 00-ssh-create-user.sh has never run here.
new_tree
clients_conf_header > "$T/config/clients.conf"
run_in "$WORK/sh" "$T/scripts/09-show-all-users.sh"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'no users configured yet'
assert "9.15 a header-only clients.conf reports no clients, not a listing" $?

# --- the committed total -------------------------------------------------
#
# Chapter 10.2's invariant, computed rather than left to the operator.

setup_09
df_stub "$T/repo:$((4000 * GIB)):$((100 * GIB))" \
    "$T/repo/OWN/user1:$((50 * GIB)):$((5 * GIB))" \
    "$T/repo/OWN/user2:$((20 * GIB)):0" \
    "$T/repo/MIRROR/friend1:$((200 * GIB)):$((10 * GIB))"
run_stubbed "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -q 'Committed:     270.0 GiB of 4000.0 GiB volume (6%) across 3 client(s)'
assert "9.16 the enforced limits are summed against the volume" $?

printf '%s' "$OUT" | grep -qE '^user1 +50G +1% +ok'
assert "9.17 each client's own quota is shown as a share of the volume too" $?

# A client nothing limits is not left out of the total. It counts as
# everything the limited ones have not claimed, so a single one commits the
# volume in full — otherwise the figure would look better the more dangerous
# the installation gets, which is the opposite of what it is for.
setup_09
df_stub "$T/repo:$((4000 * GIB)):$((100 * GIB))" \
    "$T/repo/OWN/user1:$((4000 * GIB)):$((5 * GIB))" \
    "$T/repo/OWN/user2:$((20 * GIB)):0" \
    "$T/repo/MIRROR/friend1:$((200 * GIB)):$((10 * GIB))"
run_stubbed "$WORK/sh" "$T/scripts/09-show-all-users.sh"
printf '%s' "$OUT" | grep -q 'Committed:     4000.0 GiB of 4000.0 GiB volume (100%) (!)'
assert "9.18 one client without a limit commits the whole volume" $?

printf '%s' "$OUT" | grep -q '1 of them has no limit in effect' \
    && printf '%s' "$OUT" | grep -q '3780.0 GiB the others have not claimed'
assert "9.19 ... and the total says which part of it that is" $?

# What is promised and what is left are different questions: 3.9 TiB can be
# committed on a volume that is almost empty, and that is not a contradiction.
# Free space is df's own Available figure, not size minus used — a filesystem
# may reserve blocks that are counted as neither.
printf '%s' "$OUT" | grep -q 'Disk usage:    100.0 GiB of 4000.0 GiB (1%)' \
    && printf '%s' "$OUT" | grep -q 'Disk free:     3900.0 GiB'
assert "9.20 physical usage and free space are reported alongside the promises" $?

# =========================================================================
# 10. 00-ssh-create-user.sh — creating a client
# =========================================================================
#
# This script had no coverage at all, which is why it reached operators unable
# to create the first client on any installation whose server had ever been
# started: entrypoint.sh chowns the bind-mounted repository base to the
# container's 'borg' user, which under rootless podman is a host uid the
# operator is not, so a plain `mkdir` there fails with Permission denied.
#
# What kept it untested is real — the script needs sudo, an XFS mount with
# enforcing project quotas, and a rootless podman — but none of that is needed
# to check the part that was wrong. Each of the four external commands is
# replaced by a stub that records how it was called:
#
#   podman     records argv and executes `unshare <cmd>` for real, which is
#              what a working user namespace would do to a writable path
#   sudo       runs the rest of the command line, so xfs_quota is reached
#   xfs_quota  reports enforcement ON, accepts project/limit assignments
#   lsattr     answers project ids from a data file, like a real XFS mount
#   df         the existing stub, so quota_verify reads back what was "set"
#
# The stubs make the environment; the script's own logic is untouched.

STUB="$WORK/createstubs"
mkdir -p "$STUB"

cat > "$STUB/podman" <<'PSTUB'
#!/bin/sh
# Records every invocation, then performs the namespaced command on the host —
# the path is operator-owned in this fixture, so the effect is the same as a
# real user namespace would have. chown is recorded only: mapping a container
# uid onto the host is exactly what an unprivileged test cannot do.
echo "podman $*" >> "$PODMAN_LOG"
[ "$1" = "unshare" ] || exit 0
shift
case "$1" in
    chown) exit 0 ;;
    # Inside a real namespace the operator's own files show as uid 0, and the
    # container's as BORG_UID. $PODMAN_STAT_UID is what this mapping reports.
    stat)  echo "${PODMAN_STAT_UID:-0}"; exit 0 ;;
    *) exec "$@" ;;
esac
PSTUB

cat > "$STUB/sudo" <<'SSTUB'
#!/bin/sh
exec "$@"
SSTUB

cat > "$STUB/xfs_quota" <<'XSTUB'
#!/bin/sh
# Answers the two reads the scripts make and records the writes:
#   state -p   enforcement is on
#   report -p  the hard limit currently on each project id, from
#              "<projid>:<kib>" lines in $XFS_REPORT_DATA
#   limit -p   appended to $XFS_LOG, so a test can see what was applied and in
#              which order — which is how a rollback is observed at all
for a in "$@"; do
    case "$a" in
        "state -p")
            echo "Enforcement: ON"
            ;;
        report*)
            if [ -n "${XFS_REPORT_DATA:-}" ]; then
                while IFS=: read -r pid kib; do
                    [ -n "$pid" ] && echo "#$pid 0 0 $kib 00 [--------]"
                done < "$XFS_REPORT_DATA"
            fi
            ;;
        limit*)
            [ -n "${XFS_LOG:-}" ] && echo "$a" >> "$XFS_LOG"
            ;;
    esac
done
exit 0
XSTUB

cat > "$STUB/lsattr" <<'LSTUB'
#!/bin/sh
# "<path>:<projid>" lines in $LSATTR_STUB_DATA; unknown paths report nothing,
# which is how an unreadable directory behaves.
for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
while IFS=: read -r path pid; do
    [ "$path" = "$p" ] && { echo "$pid --------------- $p"; exit 0; }
done < "$LSATTR_STUB_DATA"
exit 1
LSTUB

chmod +x "$STUB/podman" "$STUB/sudo" "$STUB/xfs_quota" "$STUB/lsattr"

lsattr_stub() { printf '%s\n' "$@" > "$WORK/lsattr.data"; export LSATTR_STUB_DATA="$WORK/lsattr.data"; }

# The script states the quota as a share of the volume and asks before it
# creates anything, so every run below answers that prompt. CONFIRM_INPUT is
# what gets typed; the cases that decline set it to "n".
CONFIRM_INPUT="y"

run_create() { # run_create <args...> — 00-ssh-create-user.sh under all stubs
    export PODMAN_LOG="$WORK/podman.log"
    : > "$PODMAN_LOG"
    OUT="$(printf '%s\n' "$CONFIRM_INPUT" \
        | PATH="$STUB:$DF_BIN:$PATH" "$T/scripts/00-ssh-create-user.sh" "$@" 2>&1)"
    RC=$?
}

setup_create() { # a tree whose repo base exists, with no clients yet
    new_tree
    printf 'name=testserver\nlocation=Testville\ncontact=admin@example.com\n' \
        > "$T/config/server_info.conf"
    lsattr_stub ""
    df_stub "$T/repo:$((4000 * GIB)):0"
}

# The bug itself: the directory has to be created through `podman unshare`,
# because on a running installation the base belongs to the container's mapped
# uid and the operator cannot write into it.
setup_create
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((50 * GIB)):0"
run_create user1 OWN 50G
[ "$RC" -eq 0 ]; assert "10.1 a client is created" $?

grep -q "^podman unshare mkdir -p $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.2 the repository directory is created inside the user namespace" $?

grep -q "^podman unshare chown 1111:1111 $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.3 ownership is handed to the container's borg user from BORG_UID/BORG_GID" $?

[ -d "$T/repo/OWN/user1" ]; assert "10.4 the directory exists afterwards" $?

grep -q '^user1:OWN:/repo/OWN/user1:50G$' "$T/config/clients.conf"
assert "10.5 the clients.conf entry carries the container-side path" $?

[ -f "$T/config/keys/user1.pub" ]; assert "10.6 an empty key placeholder is created" $?

# The NOTE that used to end this script told the operator to sort the
# ownership out by hand. It is now done, and said so.
printf '%s' "$OUT" | grep -q 'no further action needed'
assert "10.7 the operator is told ownership is already correct" $?

# Project ids: max+1 over what the existing directories report.
setup_create
mkdir -p "$T/repo/OWN/existing1" "$T/repo/MIRROR/existing2"
lsattr_stub "$T/repo/OWN/existing1:1000" "$T/repo/MIRROR/existing2:1007"
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((50 * GIB)):0"
run_create user1 OWN 50G
printf '%s' "$OUT" | grep -q 'project id 1008'
assert "10.8 the next project id is one above the highest in use" $?

# ... and a directory whose id cannot be read aborts, rather than being
# skipped: skipping hands out an id that is already in use, and two clients
# then share one quota without either of them being told.
setup_create
mkdir -p "$T/repo/OWN/unreadable"
lsattr_stub ""
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((50 * GIB)):0"
run_create user1 OWN 50G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'cannot read the XFS project id'
assert "10.9 an unreadable project id aborts instead of risking a shared quota" $?

grep -q "^podman unshare rmdir $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.10 the half-created directory is removed through the namespace too" $?

[ ! -f "$T/config/clients.conf" ] || ! grep -q '^user1:' "$T/config/clients.conf"
assert "10.11 no clients.conf entry is left behind by the abort" $?

# A quota that does not read back is the other abort path, and the one the
# script exists to protect: an unlimited client is worse than no client.
setup_create
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((4000 * GIB)):0"
run_create user1 OWN 50G
[ "$RC" -ne 0 ]; assert "10.12 a quota that does not take effect aborts the creation" $?

grep -q "^podman unshare rmdir $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.13 ... and the directory is cleaned up" $?

# The base has to belong to a mapping this user shares with the container. A
# uid that is neither means somebody else runs the container, and creating the
# directory anyway would produce a client whose backups cannot be written.
setup_create
PODMAN_STAT_UID=65534 run_create user1 OWN 50G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'same user that runs the container'
assert "10.14 a repository base under a foreign uid mapping is refused" $?

[ ! -d "$T/repo/OWN/user1" ]; assert "10.15 ... before anything is created" $?

# The base already owned by the container's borg user is the normal state of
# every installation whose server has started once.
setup_create
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((50 * GIB)):0"
PODMAN_STAT_UID=1111 run_create user1 OWN 50G
[ "$RC" -eq 0 ]; assert "10.16 a base already owned by the container is the normal case" $?

# Under bash-invoked-as-sh as well: this script's shebang is /bin/sh, which is
# dash where these tests usually run but bash on Fedora CoreOS — the platform
# the project requires. Section 9 exists because of a bug that appeared only
# under bash; the same exposure applies here.
setup_create
df_stub "$T/repo:$((4000 * GIB)):0" "$T/repo/OWN/user1:$((50 * GIB)):0"
export PODMAN_LOG="$WORK/podman.log"; : > "$PODMAN_LOG"
OUT="$(printf 'y\n' | PATH="$STUB:$DF_BIN:$PATH" "$WORK/sh" "$T/scripts/00-ssh-create-user.sh" user1 OWN 50G 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q "^podman unshare chown 1111:1111 $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.17 the same run under bash-as-sh behaves identically" $?

# podman missing is checked before anything is created, not halfway through.
setup_create
NOPODMAN="$WORK/nopodman"; mkdir -p "$NOPODMAN"
cp "$STUB/sudo" "$STUB/xfs_quota" "$STUB/lsattr" "$NOPODMAN/"
df_stub "$T/repo:$((4000 * GIB)):0"
OUT="$(printf 'y\n' | PATH="$NOPODMAN:$DF_BIN:/usr/bin:/bin" "$T/scripts/00-ssh-create-user.sh" user1 OWN 50G 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'podman not found'
assert "10.18 a missing podman is reported before anything is created" $?

[ ! -d "$T/repo/OWN/user1" ]; assert "10.19 ... and nothing was created" $?

# --- the quota, before it is applied -------------------------------------
#
# This is where a client's quota is chosen for the first time, with nothing to
# compare the number against. What it is as a share of the volume is stated
# before anything exists, and a limit that cannot be enforced is refused.

setup_create
df_stub "$T/repo:$((100 * GIB)):0" "$T/repo/OWN/user1:$((60 * GIB)):0"
run_create user1 OWN 60G
printf '%s' "$OUT" | grep -qE '^ +user1 +60\.0 GiB +60% +after this change'
assert "10.20 the new quota is stated as a share of the volume" $?

# 200G on a 100 GiB volume: xfs_quota would accept it and clamp it, and the
# client would then be told it may use the whole volume.
setup_create
df_stub "$T/repo:$((100 * GIB)):0"
run_create user1 OWN 200G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '200% of the volume'
assert "10.21 a quota larger than the volume is refused" $?

[ ! -d "$T/repo/OWN/user1" ] && ! grep -q '^user1:' "$T/config/clients.conf"
assert "10.22 ... before anything is created" $?

# A limit equal to the volume is refused for the same reason: through
# statvfs() it is indistinguishable from having no limit at all.
setup_create
df_stub "$T/repo:$((100 * GIB)):0"
run_create user1 OWN 100G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'above 99% of the volume are refused'
assert "10.23 a quota equal to the volume is refused too" $?

setup_create
df_stub "$T/repo:$((100 * GIB)):0" "$T/repo/OWN/user1:$((60 * GIB)):0"
# Set rather than prefixed: in bash an assignment preceding a *function* call
# stays in effect after it returns, which would silently answer every later run
# with "n".
CONFIRM_INPUT="n"
run_create user1 OWN 60G
CONFIRM_INPUT="y"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Aborted'
assert "10.24 declining the prompt exits cleanly" $?

[ ! -d "$T/repo/OWN/user1" ] && ! grep -q '^user1:' "$T/config/clients.conf"
assert "10.25 ... and creates nothing" $?

# =========================================================================
# 11. 99-container-status.sh — the service-status section
# =========================================================================
#
# The report used to print `systemctl status`, whose ten-line journal tail the
# script then printed again below — and with the container's output journalled
# twice (see 0.6), a single log event appeared four times in one run. What it
# prints instead is read from `systemctl show`, so the state a reader needs is
# stated rather than buried in a cgroup dump.
#
# Everything the script reaches outside itself is substituted: systemctl
# answers from a properties file, podman and journalctl are inert. That is
# enough, because what is asserted here is how a given unit state is rendered.

STATUS_STUB="$WORK/statusstub"
mkdir -p "$STATUS_STUB"
# `status` answers the way systemd really does — the cgroup tree and the
# ten-line journal tail included — so 11.2 and 11.3 fail against a script that
# calls it, instead of merely describing what this one happens to print.
cat > "$STATUS_STUB/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
    *show*)
        cat "$UNIT_PROPS_DATA"
        ;;
    *status*)
        cat <<'REAL'
● container-borg-server.service - Borg Backup Server (Podman)
     Loaded: loaded (/home/core/.config/systemd/user/container-borg-server.service; enabled)
     Active: active (running) since Fri 2026-08-15 16:00:13 CEST; 2h ago
   Main PID: 5214 (podman)
     CGroup: /user.slice/user-1000.slice/user@1000.service/app.slice/container-borg-server.service
             |-5214 /usr/bin/podman run --name=borg-server --rm --log-driver=passthrough
             `-5243 /usr/bin/conmon --api-version 1 -c e601e84e5c8b --exit-command-arg --root
Aug 15 16:00:13 host borg-server[5243]: Server listening on 0.0.0.0 port 22.
REAL
        ;;
    *)
        exit 0
        ;;
esac
STUB
cat > "$STATUS_STUB/podman" <<'STUB'
#!/bin/sh
case "$1" in ps) echo "CONTAINER ID  IMAGE  STATUS  NAMES" ;; *) exit 1 ;; esac
STUB
cat > "$STATUS_STUB/journalctl" <<'STUB'
#!/bin/sh
echo "Aug 15 16:00:13 host borg-server[5243]: Server listening on 0.0.0.0 port 22."
STUB
chmod +x "$STATUS_STUB"/*

unit_state() { printf '%s\n' "$@" > "$WORK/unit.props"; export UNIT_PROPS_DATA="$WORK/unit.props"; }
run_status() {
    new_tree
    OUT="$(PATH="$STATUS_STUB:$PATH" "$WORK/sh" "$T/scripts/99-container-status.sh" 2>&1)"; RC=$?
}

unit_state 'LoadState=loaded' 'UnitFileState=enabled' 'ActiveState=active' \
    'SubState=running' 'Result=success' 'NRestarts=0' \
    'ExecMainStartTimestamp=Fri 2026-08-15 16:00:13 CEST' 'ExecMainStatus=0'
run_status
printf '%s' "$OUT" | grep -qE '^State: +active \(running\)'
assert "11.1 a healthy unit is stated in one line" $?

printf '%s' "$OUT" | grep -q 'CGroup:'
[ $? -ne 0 ]; assert "11.2 no cgroup process dump between service and container state" $?

# The journal appears once, in its own section — not also as the tail of a
# `systemctl status` a few lines earlier.
[ "$(printf '%s\n' "$OUT" | grep -c 'Server listening on 0.0.0.0 port 22.')" -eq 1 ]
assert "11.3 a log line is printed once per run" $?

# The state a restart loop actually sits in. 'activating' is not 'failed', and
# `systemctl enable --now` exits 0 on the way into it, so the restart counter
# is the thing that has to be visible.
unit_state 'LoadState=loaded' 'UnitFileState=enabled' 'ActiveState=activating' \
    'SubState=auto-restart' 'Result=exit-code' 'NRestarts=7' \
    'ExecMainStartTimestamp=Fri 2026-08-15 16:04:51 CEST' 'ExecMainStatus=125'
run_status
printf '%s' "$OUT" | grep -qE '^Restarts: +7' \
    && printf '%s' "$OUT" | grep -q 'last exit status 125' \
    && printf '%s' "$OUT" | grep -q 'not running steadily'
assert "11.4 a restart loop is named, with its exit status" $?

unit_state 'LoadState=not-found' 'UnitFileState=' 'ActiveState=inactive' 'SubState=dead'
run_status
printf '%s' "$OUT" | grep -q 'not installed for this user' \
    && printf '%s' "$OUT" | grep -q '50-service-install.sh'
assert "11.5 an uninstalled unit says so and names the script that installs it" $?

# =========================================================================
# 12. 02-change-user-quota.sh — changing a quota
# =========================================================================
#
# This script used to be excluded from the suite for needing sudo and a real
# XFS mount with enforcing project quotas. It needs neither: section 10's
# stubs are exactly the four commands it reaches outside itself, and the one
# addition — xfs_quota answering `report -p` and recording `limit -p` — is what
# makes the rollback observable.
#
# What went untested was not a detail. The script applied the new limit first
# and verified it afterwards, so a verification failure left the limit on the
# filesystem while reporting that nothing had changed; with a quota larger than
# the volume, the result was a client the filesystem no longer bounded at all.

setup_02() {
    new_tree
    {
      clients_conf_header
      echo 'user1:OWN:/repo/OWN/user1:10G'
      echo 'user2:OWN:/repo/OWN/user2:20G'
    } > "$T/config/clients.conf"
    mkdir -p "$T/repo/OWN/user1" "$T/repo/OWN/user2"
    lsattr_stub "$T/repo/OWN/user1:1000" "$T/repo/OWN/user2:1001"
    XFS_LOG="$WORK/xfs.log"; : > "$XFS_LOG"; export XFS_LOG
    printf '1000:%s\n1001:%s\n' "$((10 * GIB))" "$((20 * GIB))" > "$WORK/xfs.report"
    export XFS_REPORT_DATA="$WORK/xfs.report"
}

run_quota() { # run_quota <args...> — 02-change-user-quota.sh under all stubs
    OUT="$(printf '%s\n' "$CONFIRM_INPUT" \
        | PATH="$STUB:$DF_BIN:$PATH" "$T/scripts/02-change-user-quota.sh" "$@" 2>&1)"
    RC=$?
}

# --- what the operator is shown before deciding --------------------------

setup_02
df_stub "$T/repo:$((100 * GIB)):$((2 * GIB))" \
        "$T/repo/OWN/user1:$((10 * GIB)):$((1 * GIB))" \
        "$T/repo/OWN/user2:$((20 * GIB)):0"
CONFIRM_INPUT="n"
run_quota user1 60G
CONFIRM_INPUT="y"
printf '%s' "$OUT" | grep -qE '^ +user1 +10\.0 GiB +10% +current \(enforced\)' \
    && printf '%s' "$OUT" | grep -qE '^ +user1 +60\.0 GiB +60% +after this change'
assert "12.1 both the current and the intended limit are shown against the volume" $?

# Chapter 10.2's invariant, at the moment it is being changed: user2's 20 GiB
# plus the 60 GiB about to be granted, against a 100 GiB volume.
printf '%s' "$OUT" | grep -q 'Committed after this change: 80.0 GiB of 100.0 GiB — 80% of the volume, across 2 client(s)'
assert "12.2 the resulting sum across all clients is stated" $?

[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Aborted' && [ ! -s "$XFS_LOG" ]
assert "12.3 declining applies nothing at all" $?

# Overcommitment is not refused — thin provisioning is a legitimate choice —
# but it is not allowed to happen quietly either.
setup_02
df_stub "$T/repo:$((100 * GIB)):$((2 * GIB))" \
        "$T/repo/OWN/user1:$((10 * GIB)):0" \
        "$T/repo/OWN/user2:$((20 * GIB)):0"
CONFIRM_INPUT="n"
run_quota user1 90G
CONFIRM_INPUT="y"
printf '%s' "$OUT" | grep -q '110% of the volume (!)' \
    && printf '%s' "$OUT" | grep -q 'stop protecting it'
assert "12.4 a change that overcommits the volume is marked as such" $?

# --- the limit that cannot be enforced -----------------------------------
#
# The reported failure: xfs_quota accepts a quota larger than the volume and
# clamps it, the read-back cannot match, and the script aborted — leaving the
# clamped limit in place, which is the whole volume. The client was then bound
# by nothing.

setup_02
df_stub "$T/repo:$((100 * GIB)):0" "$T/repo/OWN/user1:$((10 * GIB)):0"
run_quota user1 200G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '200% of the volume'
assert "12.5 a quota larger than the volume is refused" $?

[ ! -s "$XFS_LOG" ] && grep -q '^user1:OWN:/repo/OWN/user1:10G$' "$T/config/clients.conf"
assert "12.6 ... without reaching xfs_quota, and clients.conf is untouched" $?

# --- applying a limit that does take effect ------------------------------

setup_02
df_stub "$T/repo:$((100 * GIB)):0" \
        "$T/repo/OWN/user1:$((60 * GIB)):0" \
        "$T/repo/OWN/user2:$((20 * GIB)):0"
run_quota user1 60G
[ "$RC" -eq 0 ] && grep -q 'limit -p bhard=60G 1000' "$XFS_LOG"
assert "12.7 a confirmed change is applied to the client's project id" $?

grep -q '^user1:OWN:/repo/OWN/user1:60G$' "$T/config/clients.conf"
assert "12.8 ... and recorded in clients.conf once it verified" $?

# --- the abort that has to mean nothing changed --------------------------
#
# df keeps reporting 10 GiB, so the read-back cannot confirm the 60G that was
# just applied. OPERATIONS.md Chapter 9.4 promises a failed change is never
# recorded; that has to hold for the filesystem too, not only for clients.conf.

setup_02
df_stub "$T/repo:$((100 * GIB)):0" \
        "$T/repo/OWN/user1:$((10 * GIB)):0" \
        "$T/repo/OWN/user2:$((20 * GIB)):0"
run_quota user1 60G
[ "$RC" -ne 0 ] && grep -q "limit -p bhard=$((10 * GIB))k 1000" "$XFS_LOG"
assert "12.9 a limit that does not verify is rolled back to the previous one" $?

printf '%s' "$OUT" | grep -q 'Restored' \
    && grep -q '^user1:OWN:/repo/OWN/user1:10G$' "$T/config/clients.conf"
assert "12.10 ... and the abort reports that state truthfully" $?

# The previous limit is read from xfs_quota, not from df: df reports the volume
# size when nothing is enforced, so a rollback taking its figure would write a
# limit in volume size and make the unbounded state permanent.
setup_02
: > "$WORK/xfs.report"
df_stub "$T/repo:$((100 * GIB)):0" \
        "$T/repo/OWN/user1:$((10 * GIB)):0" \
        "$T/repo/OWN/user2:$((20 * GIB)):0"
run_quota user1 60G
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'could not be read, so it was not' \
    && ! grep -q "bhard=$((100 * GIB))k" "$XFS_LOG"
assert "12.11 an unreadable previous limit is reported, never guessed" $?

# user2 is bounded by nothing (df reports the whole volume for it), so the
# preview cannot promise the change leaves room: whatever user1 is granted,
# user2 can still take the rest.
setup_02
df_stub "$T/repo:$((100 * GIB)):0" \
        "$T/repo/OWN/user1:$((10 * GIB)):0" \
        "$T/repo/OWN/user2:$((100 * GIB)):0"
CONFIRM_INPUT="n"
run_quota user1 20G
CONFIRM_INPUT="y"
printf '%s' "$OUT" | grep -q '100% of the volume (!)' \
    && printf '%s' "$OUT" | grep -q 'no limit in effect'
assert "12.12 a change made alongside an unlimited client commits the volume" $?

# --- summary -------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
