#!/usr/bin/env bash
#
# tests/host-scripts.sh
# ---------------------
# Behavioural tests for the host-side scripts that need no privileges:
#
#   00-ssh-create-user.sh    creating a client: the repository directory, its
#                            ownership, project-id allocation, the abort paths
#   01-ssh-set-user-key.sh   input validation and key handling
#   09-show-all-users.sh     clients.conf parsing, grouping, quota reporting
#   config.sh                the quota helpers shared by 00/02/09
#
# Plus two packaging checks that are not behavioural at all (section 0): the
# file mode git records for every tracked script, and the absence of
# User=/Group= from the systemd unit template. Neither is about what a script
# computes; both are about defects that made a correct release unusable on the
# host without a single line of logic being wrong.
#
# 02-change-user-quota.sh is not covered end to end: it requires sudo and a
# real XFS mount with enforcing project quotas, which a CI runner does not
# have. What it relies on to decide whether a quota really took effect —
# quota_verify and friends in config.sh — is covered here, because every one of
# those reads the limit through df, and df can be substituted (section 2).
# 00-ssh-create-user.sh is covered (section 10) by substituting all four of the
# commands it reaches outside itself; see the note there for why that is enough
# to test what actually broke.
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

echo "# host scripts — packaging, 00/01 client creation, config.sh quota helpers, 09-show-all-users.sh"
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
for a in "$@"; do
    case "$a" in
        "state -p") echo "Enforcement: ON" ;;
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

run_create() { # run_create <args...> — 00-ssh-create-user.sh under all stubs
    export PODMAN_LOG="$WORK/podman.log"
    : > "$PODMAN_LOG"
    OUT="$(PATH="$STUB:$DF_BIN:$PATH" "$T/scripts/00-ssh-create-user.sh" "$@" 2>&1)"
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
OUT="$(PATH="$STUB:$DF_BIN:$PATH" "$WORK/sh" "$T/scripts/00-ssh-create-user.sh" user1 OWN 50G 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q "^podman unshare chown 1111:1111 $T/repo/OWN/user1$" "$WORK/podman.log"
assert "10.17 the same run under bash-as-sh behaves identically" $?

# podman missing is checked before anything is created, not halfway through.
setup_create
NOPODMAN="$WORK/nopodman"; mkdir -p "$NOPODMAN"
cp "$STUB/sudo" "$STUB/xfs_quota" "$STUB/lsattr" "$NOPODMAN/"
df_stub "$T/repo:$((4000 * GIB)):0"
OUT="$(PATH="$NOPODMAN:$DF_BIN:/usr/bin:/bin" "$T/scripts/00-ssh-create-user.sh" user1 OWN 50G 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'podman not found'
assert "10.18 a missing podman is reported before anything is created" $?

[ ! -d "$T/repo/OWN/user1" ]; assert "10.19 ... and nothing was created" $?

# --- summary -------------------------------------------------------------

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
