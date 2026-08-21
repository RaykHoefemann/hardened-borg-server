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
# **Values only.** The shell functions the scripts share live in lib.sh, which
# the last line here sources — so a script still sources one file, and this one
# stays short enough to be read by the person who has to edit it. That is the
# whole reason for the split: this file is shipped code *and* per-host
# configuration at once, and an upgrade diffs it to carry HOST_REPO_BASE and
# IMAGE forward (DEPLOYMENT.md chapter 6.3, step 6). While 750 lines of helpers
# sat here too, a release that touched one of them buried the two lines that
# diff exists to show.
#
# shellcheck disable=SC2034
#
# Every variable below is consumed by the scripts that SOURCE this file (and
# by the generated systemd EnvironmentFile), never within the file itself.
# Static analysis cannot see across that boundary and reports each one as
# unused, which is why the file-scoped suppression above exists. Real findings
# in this file are still reported.

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

# --- Container runtime -----------------------------------------------------

CONTAINER="borg-server"
SERVICE="container-borg-server.service"
# Derived from VERSION above, so a checkout of a release tag already points at
# the image built from that same commit — no editing needed to get a working
# pull. This used to default to ":latest", which does not exist for pre-release
# tags (see .github/workflows/docker.yml: ":latest" is only published for tags
# without a "-" suffix), so a fresh install off a pre-release checkout could
# not pull anything at all that way.
#
# The tag below is the starting point, not the end state. SERVERINSTALL step 3
# replaces it with the digest verified in step 2, and VERIFICATION check 0B
# fails an installation that still carries a tag here — a name can be re-pointed
# at other content, a digest cannot, so a tag leaves the next `podman pull` free
# to replace the very image the attestation was checked against:
#   IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
# Resolve it with skopeo, never with `podman image inspect`, which reports this
# host's architecture manifest rather than the signed index (VERIFICATION 0B).
# The tag stays the shipped default so that a fresh checkout can pull at all.
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


# --- Shared functions ------------------------------------------------------
#
# The helper functions the scripts share live in lib.sh beside this file: the
# read-only quota and roster helpers, and the repo_* helpers that write a
# client's directory, project id and limit. They are sourced from here so that
# every script keeps sourcing exactly one file, and so that this file stays
# what an operator actually edits and an upgrade actually diffs
# (DEPLOYMENT.md chapter 6.3, step 6).
#
# Sourced last, deliberately: the helpers read HOST_REPO_BASE, CONF,
# PROJID_BASE and BORG_UID/BORG_GID from the values above.
#
# Checked rather than sourced blind, because the failure is otherwise reported
# as a path with a doubled slash in it and nothing else. REPO_ROOT is derived
# from $0, i.e. from the script that sourced this file, so a REPO_ROOT that
# cannot hold lib.sh means this file was sourced from somewhere that is not a
# script in scripts/ — in which case every path above is wrong too, and saying
# so here is better than letting HOST_CONFIG_BASE point at the wrong directory.
if [ ! -f "${REPO_ROOT}/scripts/lib.sh" ]; then
    echo "ERROR: config.sh could not find '${REPO_ROOT}/scripts/lib.sh'." >&2
    echo "       It resolves every path from the script that sources it, so it" >&2
    echo "       has to be sourced by a script inside scripts/:" >&2
    echo "           . \"\$(dirname \"\$0\")/config.sh\"" >&2
    echo "       Sourced from an interactive shell or another directory, the" >&2
    echo "       paths above are wrong as well." >&2
    # Returns from the sourced file; the exit is the fallback for the case
    # where this file was executed rather than sourced, where return is a no-op.
    return 1 2>/dev/null
    exit 1
fi
. "${REPO_ROOT}/scripts/lib.sh"
