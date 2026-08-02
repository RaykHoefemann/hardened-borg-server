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

# Resolve the repository root relative to whichever script sourced this
# file (dirname "$0" is that script's own directory, e.g. ".../scripts"),
# not the caller's current working directory. This makes every path below
# correct regardless of where a script is invoked from.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
# NOTE (beta phase): no stable release has been tagged yet, so ":latest" does
# NOT exist on GHCR yet — only pre-release tags like "0.1.0-beta.16" do (see
# .github/workflows/docker.yml: ":latest" is only published for tags without
# a "-" suffix). If you are testing a beta build, override this to the exact
# pre-release tag you want to run, e.g.:
#   IMAGE="ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.16"
# This will be updated back to a real, existing tag once a stable release
# ships; until then ":latest" here is a forward-looking placeholder and will
# fail to pull if used as-is.
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server:latest"
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
