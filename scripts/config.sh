#!/bin/sh
#
# config.sh
# ---------
# Central configuration for all borg-server scripts AND for the systemd
# service (via the generated EnvironmentFile — see 50-service-install.sh).
# This file is the single source of truth: nothing below should be
# duplicated as a literal value anywhere else in the repo.
#
# Source this file at the beginning of each script:
#
#   . "$(dirname "$0")/config.sh"
#
# shellcheck disable=SC2034
#
# Every variable below is consumed by the scripts that SOURCE this file (and
# by the generated systemd EnvironmentFile), never within the file itself.
# Static analysis cannot see across that boundary and reports each one as
# unused, which is why the file-scoped suppression above exists. Real findings
# in this file are still reported.
#
# The last section adds shell FUNCTIONS rather than values: the quota helpers
# shared by 00/02/09. They live here for the same reason the values do — the
# definition of "the enforced quota" must exist exactly once, not once per
# script. They are pure, read-only, and never invoked while sourcing, so the
# generated EnvironmentFile is unaffected.

# Resolve the repository root relative to whichever script sourced this
# file (dirname "$0" is that script's own directory, e.g. ".../scripts"),
# not the caller's current working directory. This makes every path below
# correct regardless of where a script is invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The release this tree came from. Single source of truth for the version:
# the VERSION file is what SERVERINSTALL clones by tag, what IMAGE below is
# derived from, and what 99-container-status.sh reports — so host side and
# container side cannot drift apart by forgetting to bump one of them. A CI
# check enforces that VERSION, the git tag and the documented image tag agree.
# "unknown" means this tree was assembled by hand rather than installed from a
# release.
RELEASE_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo unknown)"

# Where this software comes from. The image carries the same constant (see
# build_authorized_keys.sh, which reports it to clients through the info
# channel); a CI check enforces that the two agree, so an operator and a
# client are never pointed at different sources.
SOURCE_URL="https://github.com/RaykHoefemann/hardened-borg-server"

# --- Host-side paths -------------------------------------------------------

# Config and log storage: kept inside the repo checkout itself.
HOST_CONFIG_BASE="${REPO_ROOT}/config"
HOST_LOG_BASE="${REPO_ROOT}/log"

# Repository storage: MUST point at the XFS filesystem that has ENFORCING
# project quotas (prjquota) enabled — see README Chapter 1.1.3 /
# BEST_PRACTICES.md Chapter 1. ADJUST THIS to your actual storage volume.
# This is also the exact value used to bind-mount /repo in the generated
# systemd unit (see 50-service-install.sh) — so the container is
# guaranteed to mount the same directory that 00/02/09 operate on.
# A trailing slash is optional — every script normalizes this value itself,
# so either "/path/to/repo" or "/path/to/repo/" works the same.
HOST_REPO_BASE="/var/mnt/extern1/borg-server/"

# Container-side path prefix (as seen inside the container).
CONTAINER_REPO_BASE="/repo/"

# Scripts' view of config/keys (used by 00/01/02/09).
CONF="${HOST_CONFIG_BASE}/clients.conf"
KEYDIR="${HOST_CONFIG_BASE}/keys"

# Starting project id for auto-allocation (00-ssh-create-user.sh scans
# existing repo dirs and takes max+1, starting from this floor).
PROJID_BASE=1000

# --- Client roster ---------------------------------------------------------

# The client lines of clients.conf: everything that is neither a comment nor
# blank. There is exactly one place that decides what counts as a client, and
# this is it.
#
# clients.conf is not necessarily bare data. On a fresh installation the
# container's build_authorized_keys.sh creates it with a header explaining the
# format — which is the normal state of every installation whose container was
# started before its first client existed, i.e. the documented order in
# SERVERINSTALL.md. Reading the file without this filter parses that header as
# client data: the format legend becomes a group, the example line becomes a
# client, and a line count becomes the client total.
#
# Matches the container's own parser (build_authorized_keys.sh) and the count
# VERIFICATION.md test 3 performs by hand, so all three agree on who exists.
clients_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null || true
}

# --- Container runtime -----------------------------------------------------

CONTAINER="borg-server"
SERVICE="container-borg-server.service"
# Derived from VERSION above, so a checkout of a release tag already points at
# the image built from that same commit — no editing needed to get a working
# pull. This used to default to ":latest", which does NOT exist during the beta
# phase (see .github/workflows/docker.yml: ":latest" is only published for tags
# without a "-" suffix), so a fresh install could not pull anything at all.
#
# Override this to pin a digest instead of a tag once you have verified the
# image — tags are mutable, digests are not. See docs/VERIFICATION.md, Test 0:
#   IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server:${RELEASE_VERSION}"
SSH_PORT=2222

# UID/GID of the 'borg' user INSIDE the container. Baked into the image at
# build time (Dockerfile: useradd -u ${PUID} -g ${PGID} ... borg) and fixed
# from then on — entrypoint.sh never reads runtime PUID/PGID env vars, so
# the systemd unit does not pass any; only change this if the image is
# rebuilt with different values. Used exclusively by 00-ssh-create-user.sh
# to set correct host ownership on new repo directories via
# `podman unshare` (rootless Podman UID mapping).
BORG_UID=1111
BORG_GID=1111

# --- Quota helpers ---------------------------------------------------------
#
# Shared by 00 (set a quota), 02 (change a quota) and 09 (report quotas), so
# that "the enforced quota" has exactly one definition everywhere: the value
# the kernel reports through statvfs() on the client's repository directory.
# For a directory covered by an XFS project quota, statvfs() reports the
# project's hard limit as the filesystem size and the project's usage as the
# used blocks — which is also precisely what the client sees in the info
# channel (README Chapter 7). Reading it back this way therefore verifies the
# thing that actually matters (the limit the client will hit), not merely that
# the xfs_quota command exited 0.
#
# All of these are read-only and need no privileges.

# "<n>G" -> KiB. Prints nothing and fails for any other input.
quota_kib() {
    case "$1" in
        *G) ;;
        *) return 1 ;;
    esac
    _q_num="${1%G}"
    case "$_q_num" in
        ''|*[!0-9]*|0) return 1 ;;
    esac
    echo $((_q_num * 1048576))
}

# KiB -> human readable. Mirrors the wrapper's info-channel formatting, so
# host and client never present the same number in two different shapes.
quota_human() {
    awk -v k="$1" 'BEGIN{
        if (k>=1048576) printf "%.1f GiB", k/1048576;
        else if (k>=1024) printf "%.1f MiB", k/1024;
        else printf "%d KiB", k; }'
}

# Hard limit currently enforced on directory $1, in KiB (empty if unreadable).
quota_enforced_kib() { df -kP "$1" 2>/dev/null | awk 'NR==2{print $2}'; }

# Blocks currently used by directory $1's project, in KiB (empty if unreadable).
quota_used_kib() { df -kP "$1" 2>/dev/null | awk 'NR==2{print $3}'; }

# quota_verify <repo-dir> <quota>
#
# Confirm that <quota> is really the hard limit the kernel now enforces on
# <repo-dir>, and print what is in effect. Returns non-zero with an
# explanation if it is not — a limit that was accepted by xfs_quota but does
# not reach the directory (wrong project id, missing inheritance, quotas not
# enforcing) would otherwise look like success while the client stays
# effectively unlimited until the volume itself runs full.
quota_verify() {
    _qv_dir="$1"
    _qv_want_kib=$(quota_kib "$2") || {
        echo "ERROR: internal: quota_verify called with invalid quota '$2'."
        return 1
    }

    _qv_have_kib=$(quota_enforced_kib "$_qv_dir")
    case "$_qv_have_kib" in
        ''|*[!0-9]*)
            echo "ERROR: could not read back the enforced quota for '$_qv_dir'."
            return 1
            ;;
    esac

    if [ "$_qv_have_kib" -ne "$_qv_want_kib" ]; then
        echo "ERROR: the quota is NOT enforced as requested on '$_qv_dir'."
        echo "       requested: $2 ($(quota_human "$_qv_want_kib"))"
        echo "       enforced:  $(quota_human "$_qv_have_kib")"
        echo "       If the enforced value matches the size of the whole volume,"
        echo "       no project quota applies to this directory at all."
        return 1
    fi

    _qv_used_kib=$(quota_used_kib "$_qv_dir")
    case "$_qv_used_kib" in
        ''|*[!0-9]*) _qv_used_kib=0 ;;
    esac

    echo "[quota] Verified on host: hard limit $(quota_human "$_qv_have_kib") is in effect"
    echo "[quota] Used now: $(quota_human "$_qv_used_kib") of $(quota_human "$_qv_have_kib") ($((_qv_used_kib * 100 / _qv_have_kib))%)"
}
