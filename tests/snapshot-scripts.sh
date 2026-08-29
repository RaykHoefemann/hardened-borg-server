#!/usr/bin/env bash
#
# tests/snapshot-scripts.sh
# --------------------------
# Behavioural tests for snapshots/70-create-snapshot.sh, 75-list-snapshots.sh,
# 76-delete-snapshots.sh and 77-restore-last-snapshot.sh -- the four scripts
# with real destructive or privileged logic (docs/SNAPSHOTS.md). Not covered
# here: 71-/72-timer-install/uninstall.sh and 79-timer-status.sh, which are
# mostly systemd-unit rendering rather than the immutable-flag/quota/copy
# logic this file exists to exercise; a fake-systemctl suite for those is a
# separate, later task.
#
# Neither CI nor this file is a substitute for docs/VERIFICATION.md's tests
# 11A-11G, all of which are measured directly against a real deployment
# (FCOS-BorgBackupServer) with real XFS project quotas, real chattr
# immutability enforced by the kernel, and real SELinux -- none of which a
# GitHub-hosted runner can reproduce faithfully (no SELinux stack at all, no
# XFS+prjquota volume without extra loop-device setup). What THIS file adds
# is automated, on-every-push coverage of the same class of logic bug that
# went unnoticed until a live VM test found it (issue #35): argument
# validation, call ordering, path safety, and refusal paths -- checked with
# fake `sudo`/`chattr`/`lsattr`/`xfs_quota`/`podman`/`cp`/`xfs_info`, the same
# substitution technique tests/host-scripts.sh already uses for 00-/02-, and
# the same one used by hand against a throwaway tree during 70-/75-/76-/77-'s
# own development (this project's own git history).
#
# The `rm` and `chattr`/`lsattr` stubs below track a fake "this path is
# immutable" state well enough that a plain `rm -rf` against a path 70- just
# protected genuinely fails here too (mirrors VERIFICATION.md 11A), and that
# 76-'s clear-then-verify-then-delete sequence is actually load-bearing, not
# merely called in the right order on paper.
#
# Requires: bash.
# Usage:    tests/snapshot-scripts.sh
#
# shellcheck disable=SC2319
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0
OUT=""; RC=0; T=""

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n       rc=%s\n       output:\n%s\n' \
        "$1" "$RC" "$(printf '%s' "$OUT" | sed 's/^/         /')"; }
assert() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ============================================================================
# Fixture: a throwaway installation tree, config.sh pointed at it
# ============================================================================
#
# HOST_STORAGE_BASE/CONTAINER derive both HOST_REPO_BASE and SNAPSHOT_BASE
# (repository root config.sh) -- pointing HOST_STORAGE_BASE at the fixture is
# enough to move both, the same way REPO_ROOT is resolved from $0 rather than
# the caller's cwd (see config.sh's own header for why).
new_snap_tree() {
    T="$WORK/tree$RANDOM$RANDOM"
    mkdir -p "$T/scripts" "$T/snapshots" "$T/storage/repo"
    cp "$ROOT/config.sh" "$T/config.sh"
    cp "$ROOT/scripts/config.sh" "$T/scripts/config.sh"
    cp "$ROOT/scripts/lib.sh" "$T/scripts/lib.sh"
    cp "$ROOT"/snapshots/*.sh "$T/snapshots/"
    chmod +x "$T"/snapshots/*.sh
    sed -i "s|^HOST_STORAGE_BASE=.*|HOST_STORAGE_BASE=\"$T/storage\"|" "$T/config.sh"
    sed -i 's|^CONTAINER=.*|CONTAINER="repo"|' "$T/config.sh"
    # Resolved for convenience in the test cases below.
    HRB="$T/storage/repo"
    SB="$T/storage/.snapshots/repo"
}

mkclient() { # mkclient <group> <name> — a live client directory with content
    mkdir -p "$HRB/$1/$2"
    echo "payload for $2" > "$HRB/$1/$2/marker.txt"
}

mkgen() { # mkgen <group> <client> <timestamp> — a pre-existing snapshot generation
    mkdir -p "$SB/$1/$2/$3"
    echo "generation $3 of $2" > "$SB/$1/$2/$3/marker.txt"
}

# ============================================================================
# Stubs: sudo, podman, xfs_quota, xfs_info, chattr, lsattr, cp, rm, df
# ============================================================================
#
# sudo/podman/xfs_quota patterns copied from tests/host-scripts.sh's own
# stubs (sections 10/12), which have already been exercising the exact same
# scripts/lib.sh functions 77- reuses (repo_dir_create, repo_projid,
# repo_projid_assign, repo_xfs_mount, repo_quota_enforcing, quota_enforced_kib).
STUB="$WORK/stubs"
mkdir -p "$STUB"

cat > "$STUB/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat > "$STUB/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "${PODMAN_LOG:-/dev/null}"
[ "$1" = "unshare" ] || exit 0
shift
case "$1" in
    chown) exit 0 ;;
    stat)  echo "${PODMAN_STAT_UID:-0}"; exit 0 ;;
    *) exec "$@" ;;
esac
EOF

cat > "$STUB/xfs_quota" <<'EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        "state -p") echo "Enforcement: ON" ;;
        project*|limit*) [ -n "${XFS_LOG:-}" ] && echo "$a" >> "$XFS_LOG" ;;
    esac
done
exit 0
EOF

cat > "$STUB/xfs_info" <<'EOF'
#!/bin/sh
if [ "${XFS_INFO_NO_REFLINK:-}" = "1" ]; then
    echo "naming   = version 2"
else
    echo "naming   = version 2   bigtime=1 inobtcount=1"
    echo "reflink=1"
fi
EOF

# --reflink=* stripped, then a real copy -- this fixture has no XFS reflink
# support to exercise; the same substitution 70-/77-'s own development used
# by hand against a sandbox without one.
cat > "$STUB/cp" <<'EOF'
#!/bin/sh
[ "${CP_FAIL:-}" = "1" ] && { echo "cp: stub forced failure" >&2; exit 1; }
set -- $(for a in "$@"; do case "$a" in --reflink=*) ;; *) echo "$a" ;; esac; done)
exec /bin/cp "$@"
EOF

# chattr -R +i|-i <path>. Records the result in $CHATTR_STATE (one line per
# currently-"immutable" real path) for lsattr -d and the rm stub below to
# read back -- not a real kernel flag, but tracked precisely enough that the
# same trust-but-verify sequence 70-/76- perform is genuinely meaningful here.
cat > "$STUB/chattr" <<'EOF'
#!/bin/sh
[ "${CHATTR_FAIL:-}" = "1" ] && exit 1
mode="" path=""
for a in "$@"; do
    case "$a" in
        +i) mode=set ;;
        -i) mode=clear ;;
        -R) ;;
        *) path="$a" ;;
    esac
done
[ -n "$path" ] || exit 1
real="$(cd "$path" 2>/dev/null && pwd -P)" || exit 1
# CHATTR_LIE=1: claim success without recording the change, to test the
# scripts' own lsattr read-back catching a lying chattr.
[ "${CHATTR_LIE:-}" = "1" ] && exit 0
: > "${CHATTR_STATE:?}.tmp"
[ -f "$CHATTR_STATE" ] && grep -vF "$real" "$CHATTR_STATE" > "$CHATTR_STATE.tmp"
mv "$CHATTR_STATE.tmp" "$CHATTR_STATE"
[ "$mode" = "set" ] && echo "$real" >> "$CHATTR_STATE"
exit 0
EOF

# Two forms this project actually uses:
#   lsattr -p -d <dir>   -> project id, from $LSATTR_STUB_DATA ("<path>:<id>")
#   lsattr -d <dir>      -> attribute string; 'i' present iff <path> resolves
#                           to a line in $CHATTR_STATE
cat > "$STUB/lsattr" <<'EOF'
#!/bin/sh
want_p=0 path=""
for a in "$@"; do
    case "$a" in
        -p) want_p=1 ;;
        -d) ;;
        *) path="$a" ;;
    esac
done
if [ "$want_p" = "1" ]; then
    while IFS=: read -r p id; do
        [ "$p" = "$path" ] && { echo "$id --------------- $path"; exit 0; }
    done < "${LSATTR_STUB_DATA:-/dev/null}"
    exit 1
fi
real="$(cd "$path" 2>/dev/null && pwd -P)" || real="$path"
if [ -f "${CHATTR_STATE:-/dev/null}" ] && grep -qF "$real" "$CHATTR_STATE"; then
    echo "----i----------------- $path"
else
    echo "----------------------- $path"
fi
exit 0
EOF

# A real block, the way a genuinely immutable file refuses `rm` on a real
# filesystem: any target still listed in $CHATTR_STATE is refused with the
# same "Operation not permitted" wording, everything else is deleted for
# real. This is what makes 76-'s clear-before-delete order load-bearing here.
cat > "$STUB/rm" <<'EOF'
#!/bin/sh
fail=0
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    real="$(cd "$a" 2>/dev/null && pwd -P)" || continue
    if [ -f "${CHATTR_STATE:-/dev/null}" ] && grep -qF "$real" "$CHATTR_STATE"; then
        echo "rm: cannot remove '$a': Operation not permitted" >&2
        fail=1
    fi
done
[ "$fail" = 0 ] || exit 1
exec /bin/rm "$@"
EOF

# Answers repo_xfs_mount (df -P, column 6) and quota_enforced_kib (df -kP,
# column 2) alike, exactly like tests/host-scripts.sh's own df stub -- plus
# an optional switch-after-N-calls knob, used to test 77-'s own before/after
# quota-identity comparison catching a real mismatch without needing a race.
cat > "$STUB/df" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
n=0
if [ -n "${DF_CALL_COUNTER:-}" ]; then
    n=$(cat "$DF_CALL_COUNTER" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$DF_CALL_COUNTER"
fi
DATA="${DF_STUB_DATA:-/dev/null}"
if [ -n "${DF_STUB_DATA_AFTER:-}" ] && [ "$n" -gt "${DF_STUB_SWITCH_AT:-999999}" ]; then
    DATA="$DF_STUB_DATA_AFTER"
fi
size=0; used=0; avail=""
while IFS=: read -r path s u av; do
    [ "$path" = "$p" ] && { size="$s"; used="$u"; avail="$av"; }
done < "$DATA"
[ -n "$avail" ] || avail=$((size - used))
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/stub $size $used $avail 99% /stub"
EOF

chmod +x "$STUB"/*

df_stub()     { printf '%s\n' "$@" > "$WORK/df.data"; export DF_STUB_DATA="$WORK/df.data"; }
lsattr_pdata() { printf '%s\n' "$@" > "$WORK/lsattr_p.data"; export LSATTR_STUB_DATA="$WORK/lsattr_p.data"; }

reset_env() {
    unset CHATTR_FAIL CHATTR_LIE CP_FAIL XFS_INFO_NO_REFLINK
    unset DF_STUB_DATA_AFTER DF_STUB_SWITCH_AT DF_CALL_COUNTER
    export CHATTR_STATE="$WORK/chattr.state"
    : > "$CHATTR_STATE"
    export PODMAN_LOG="$WORK/podman.log"; : > "$PODMAN_LOG"
    export XFS_LOG="$WORK/xfs.log"; : > "$XFS_LOG"
    df_stub ""
    lsattr_pdata ""
}

run() { OUT="$(PATH="$STUB:$PATH" "$@" 2>&1)"; RC=$?; }
run_confirm() { # run_confirm <answer> <script> <args...>
    ans="$1"; shift
    OUT="$(printf '%s\n' "$ans" | PATH="$STUB:$PATH" "$@" 2>&1)"; RC=$?
}

# ============================================================================
# 75. 75-list-snapshots.sh
# ============================================================================

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh"
[ "$RC" -ne 0 ]; assert "75.1 missing <client> argument is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh" '../etc'
[ "$RC" -ne 0 ]; assert "75.2 a path-traversal client name is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh" nobody
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"No snapshots found"* ]]; }
assert "75.3 an unknown client reports nothing found, not an error" $?

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh" client1 not-a-timestamp
[ "$RC" -ne 0 ]; assert "75.4 a malformed [from] is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh" client1 20260101T000000Z not-a-timestamp
[ "$RC" -ne 0 ]; assert "75.5 a malformed [to] is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/75-list-snapshots.sh" client1 20260901T000000Z 20260101T000000Z
[ "$RC" -ne 0 ]; assert "75.6 [from] later than [to] is refused" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client1 20260215T000000Z
mkgen OWN client1 20260301T000000Z
run "$T/snapshots/75-list-snapshots.sh" client1
{ [ "$RC" -eq 0 ] \
  && [[ "$OUT" == *"20260101T000000Z"*"20260215T000000Z"*"20260301T000000Z"* ]] \
  && [[ "$OUT" == *"3 generation(s) listed"* ]]; }
assert "75.7 every generation is listed, oldest first" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client1 20260215T000000Z
mkgen OWN client1 20260301T000000Z
run "$T/snapshots/75-list-snapshots.sh" client1 20260201T000000Z 20260401T000000Z
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"20260215T000000Z"* ]] && [[ "$OUT" == *"20260301T000000Z"* ]] \
  && [[ "$OUT" != *"20260101T000000Z"* ]]; }
assert "75.8 a [from]/[to] range only lists what falls inside it" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run "$T/snapshots/75-list-snapshots.sh" client1 20270101T000000Z 20270201T000000Z
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"in the given range"* ]]; }
assert "75.9 a valid range matching nothing says so, not an error" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkdir -p "$SB/OWN/client1/.creating-20260215T000000Z"
run "$T/snapshots/75-list-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" != *".creating"* ]] && [[ "$OUT" == *"1 generation(s) listed"* ]]; }
assert "75.10 a stale .creating-* is silently skipped, not listed" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen MIRROR client1 20260101T000000Z
run "$T/snapshots/75-list-snapshots.sh" client1
[ "$RC" -ne 0 ]; assert "75.11 a client under both OWN and MIRROR is refused, not guessed" $?

# ============================================================================
# 76. 76-delete-snapshots.sh
# ============================================================================

new_snap_tree; reset_env
run "$T/snapshots/76-delete-snapshots.sh"
[ "$RC" -ne 0 ]; assert "76.1 missing <client> argument is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/76-delete-snapshots.sh" '../etc'
[ "$RC" -ne 0 ]; assert "76.2 a path-traversal client name is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/76-delete-snapshots.sh" nobody
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Nothing to delete"* ]] && [[ "$OUT" != *"Type Y"* ]]; }
assert "76.3 an unknown client is a no-op, never reaches the confirmation" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run "$T/snapshots/76-delete-snapshots.sh" client1 20270101T000000Z 20270201T000000Z
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Nothing in scope"* ]] && [[ "$OUT" != *"Type Y"* ]] \
  && [ -d "$SB/OWN/client1/20260101T000000Z" ]; }
assert "76.4 an empty range never prompts and deletes nothing" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run_confirm "y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Aborted"* ]] && [ -d "$SB/OWN/client1/20260101T000000Z" ]; }
assert "76.5 lowercase 'y' aborts -- only exact uppercase Y confirms" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run_confirm "" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Aborted"* ]] && [ -d "$SB/OWN/client1/20260101T000000Z" ]; }
assert "76.6 empty input aborts" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [ ! -e "$SB/OWN/client1/20260101T000000Z" ] \
  && [[ "$OUT" == *"1/1 generation(s) deleted"* ]]; }
assert "76.7 exact 'Y' deletes the generation" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client1 20260215T000000Z
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [ ! -e "$SB/OWN/client1/20260101T000000Z" ] \
  && [ ! -e "$SB/OWN/client1/20260215T000000Z" ]; }
assert "76.8 omitting [from]/[to] deletes the entire history" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client1 20260215T000000Z
mkgen OWN client1 20260301T000000Z
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1 20260201T000000Z 20260228T000000Z
{ [ "$RC" -eq 0 ] && [ -d "$SB/OWN/client1/20260101T000000Z" ] \
  && [ ! -e "$SB/OWN/client1/20260215T000000Z" ] && [ -d "$SB/OWN/client1/20260301T000000Z" ]; }
assert "76.9 a [from]/[to] range deletes only what falls inside it" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen MIRROR client1 20260101T000000Z
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -ne 0 ] && [ -d "$SB/OWN/client1/20260101T000000Z" ] && [ -d "$SB/MIRROR/client1/20260101T000000Z" ]; }
assert "76.10 a client under both groups is refused, nothing deleted" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
echo "$SB/OWN/client1/20260101T000000Z" > "$CHATTR_STATE"   # mark it "immutable"
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [ ! -e "$SB/OWN/client1/20260101T000000Z" ] \
  && ! grep -qF "$SB/OWN/client1/20260101T000000Z" "$CHATTR_STATE"; }
assert "76.11 an immutable generation is cleared first, then actually deleted" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
ext="$WORK/external-target$RANDOM"; mkdir -p "$ext"; echo keep > "$ext/marker"
rm -rf "$SB/OWN/client1/20260101T000000Z"
ln -s "$ext" "$SB/OWN/client1/20260101T000000Z"
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"does not resolve inside SNAPSHOT_BASE"* ]] \
  && [ -f "$ext/marker" ]; }
assert "76.12 a generation symlinked outside SNAPSHOT_BASE is refused, target untouched" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client2 20260101T000000Z
echo "$SB/OWN/client1/20260101T000000Z" > "$CHATTR_STATE"
run_confirm "Y" "$T/snapshots/76-delete-snapshots.sh" client1
{ [ "$RC" -eq 0 ] && [ -d "$SB/OWN/client2/20260101T000000Z" ]; }
assert "76.13 deleting one client never touches another client's history" $?

# ============================================================================
# 70. 70-create-snapshot.sh
# ============================================================================

new_snap_tree; reset_env
run "$T/snapshots/70-create-snapshot.sh"
[ "$RC" -eq 0 ]; assert "70.1 no clients at all is a clean no-op" $?

new_snap_tree; reset_env
rm -rf "$HRB"
run "$T/snapshots/70-create-snapshot.sh"
[ "$RC" -ne 0 ]; assert "70.2 a missing HOST_REPO_BASE is refused, not silently created" $?

new_snap_tree; reset_env
mkclient OWN client1
export XFS_INFO_NO_REFLINK=1
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"reflink"* ]] && [ ! -d "$SB/OWN" ]; }
assert "70.3 a filesystem without reflink support is refused up front" $?
unset XFS_INFO_NO_REFLINK

new_snap_tree; reset_env
mkclient OWN client1
mkclient OWN client2
run "$T/snapshots/70-create-snapshot.sh"
GEN1="$(find "$SB/OWN/client1" -mindepth 1 -maxdepth 1 -type d)"
GEN2="$(find "$SB/OWN/client2" -mindepth 1 -maxdepth 1 -type d)"
{ [ "$RC" -eq 0 ] && [ -f "$GEN1/marker.txt" ] && [ -f "$GEN2/marker.txt" ] \
  && [[ "$OUT" == *"2/2 client(s) snapshotted successfully"* ]]; }
assert "70.4 every client under HOST_REPO_BASE gets a generation, with its content" $?

new_snap_tree; reset_env
mkclient OWN client1
run "$T/snapshots/70-create-snapshot.sh"
GEN="$(find "$SB/OWN/client1" -mindepth 1 -maxdepth 1 -type d | head -1)"
run sudo rm -rf "$GEN"
{ [ "$RC" -ne 0 ] && [ -d "$GEN" ]; }
assert "70.5 the completed generation genuinely resists deletion (mirrors VERIFICATION 11A)" $?

new_snap_tree; reset_env
mkclient OWN client1
mkclient OWN 'bad name'
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"1/2 client(s)"* || "$OUT" == *"1/2"* ]] \
  && [ -d "$SB/OWN/client1" ] && [ ! -d "$SB/OWN/bad name" ]; }
assert "70.6 one client's invalid name does not stop the others" $?

new_snap_tree; reset_env
mkclient OWN client1
export CP_FAIL=1
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"reflink copy failed"* ]]; }
assert "70.7 a failed copy is reported and that client is skipped" $?
unset CP_FAIL

new_snap_tree; reset_env
mkclient OWN client1
export CHATTR_FAIL=1
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"chattr +i failed"* ]]; }
assert "70.8 a failing chattr is reported, not silently accepted" $?
unset CHATTR_FAIL

new_snap_tree; reset_env
mkclient OWN client1
export CHATTR_LIE=1
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"NOT showing the immutable flag on read-back"* ]]; }
assert "70.9 chattr claiming success is not trusted without a read-back match" $?
unset CHATTR_LIE

new_snap_tree; reset_env
mkclient OWN client1
mkdir -p "$SB/OWN/client1/.creating-20200101T000000Z/data"
echo stale > "$SB/OWN/client1/.creating-20200101T000000Z/data/leftover"
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"removing stale incomplete snapshot"* ]] \
  && [ ! -e "$SB/OWN/client1/.creating-20200101T000000Z" ]; }
assert "70.10 a leftover .creating-* from an interrupted run is cleaned up" $?

new_snap_tree; reset_env
LOCK_HELD="$T/storage/.snapshots/repo"
mkdir -p "$LOCK_HELD"
exec 8>"$LOCK_HELD/.lock"
flock -n 8
mkclient OWN client1
run "$T/snapshots/70-create-snapshot.sh"
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"still in progress"* ]]; }
assert "70.11 a concurrent run is refused via the lock, not silently interleaved" $?
flock -u 8; exec 8>&-

# ============================================================================
# 77. 77-restore-last-snapshot.sh
# ============================================================================

new_snap_tree; reset_env
run "$T/snapshots/77-restore-last-snapshot.sh"
[ "$RC" -ne 0 ]; assert "77.1 missing <client> argument is refused" $?

new_snap_tree; reset_env
run "$T/snapshots/77-restore-last-snapshot.sh" nobody
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"No snapshots found"* ]] && [[ "$OUT" != *"Type Y"* ]]; }
assert "77.2 no snapshot history at all is refused before any prompt, exit 1" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
run "$T/snapshots/77-restore-last-snapshot.sh" client1
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"no existing repository directory found"* ]] \
  && [[ "$OUT" == *"00-ssh-create-user.sh"* ]] && [[ "$OUT" == *"04-reattach-client.sh"* ]] \
  && [[ "$OUT" == *"does not help here either"* ]]; }
assert "77.3 a live directory that is entirely gone is refused, points at 00- not 04-" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen MIRROR client1 20260101T000000Z
mkclient OWN client1
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run "$T/snapshots/77-restore-last-snapshot.sh" client1
[ "$RC" -ne 0 ]; assert "77.4 a client with snapshots under both groups is refused" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkclient OWN client1
mkclient MIRROR client1
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run "$T/snapshots/77-restore-last-snapshot.sh" client1
[ "$RC" -ne 0 ]; assert "77.5 a live directory under both groups is refused" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkgen OWN client1 20260215T000000Z
mkclient OWN client1
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run_confirm "N" "$T/snapshots/77-restore-last-snapshot.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"20260215T000000Z"* ]] && [[ "$OUT" != *"20260101T000000Z "* ]]; }
assert "77.6 the display picks the newest generation, not just any" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkclient OWN client1
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run_confirm "n" "$T/snapshots/77-restore-last-snapshot.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"Aborted"* ]] && [ -f "$HRB/OWN/client1/marker.txt" ]; }
assert "77.7 lowercase 'n' (or anything but Y) aborts, live repo untouched" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
echo "restored payload" > "$SB/OWN/client1/20260101T000000Z/marker.txt"
mkclient OWN client1
echo "drift, added after the snapshot" > "$HRB/OWN/client1/drift.txt"
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run_confirm "Y" "$T/snapshots/77-restore-last-snapshot.sh" client1
{ [ "$RC" -eq 0 ] && [[ "$OUT" == *"quota identity matches"* ]] \
  && [ ! -e "$HRB/OWN/client1/drift.txt" ] \
  && [ "$(cat "$HRB/OWN/client1/marker.txt")" = "restored payload" ]; }
assert "77.8 a clean restore replaces drifted content with the snapshot's own" $?

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
mkclient OWN client1
lsattr_pdata "$HRB/OWN/client1:1011"
export DF_CALL_COUNTER="$WORK/df.calls"; : > "$DF_CALL_COUNTER"
df_stub "$HRB/OWN/client1:1048576:0"
export DF_STUB_DATA_AFTER="$WORK/df.after"
printf '%s\n' "$HRB/OWN/client1:2097152:0" > "$DF_STUB_DATA_AFTER"
export DF_STUB_SWITCH_AT=2   # df calls: #1 repo_xfs_mount, #2 OLD kib, #3 NEW kib -- only #3 sees the new value
run_confirm "Y" "$T/snapshots/77-restore-last-snapshot.sh" client1
{ [ "$RC" -ne 0 ] && [[ "$OUT" == *"is NOT"*"correctly quota-protected"* ]] \
  && [ ! -e "$HRB/OWN/client1/marker.txt" ]; }
assert "77.9 a quota mismatch after re-applying the project id aborts, restores nothing" $?
unset DF_STUB_DATA_AFTER DF_STUB_SWITCH_AT DF_CALL_COUNTER

new_snap_tree; reset_env
mkgen OWN client1 20260101T000000Z
echo "restored payload" > "$SB/OWN/client1/20260101T000000Z/marker.txt"
mkclient OWN client1
lsattr_pdata "$HRB/OWN/client1:1011"
df_stub "$HRB/OWN/client1:1048576:0"
run_confirm "Y" "$T/snapshots/77-restore-last-snapshot.sh" client1
grep -qF "project -s -p ${HRB}/OWN/client1 1011" "$XFS_LOG"
assert "77.10 the SAME project id read before deletion is re-applied, not a fresh one" $?

# ============================================================================
echo ""
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
