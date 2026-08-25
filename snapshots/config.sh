#!/bin/sh
#
# config.sh (snapshots/)
# -----------------------
# snapshots/-side configuration: today, exactly the shared core one directory
# up (CONTAINER, HOST_STORAGE_BASE, HOST_REPO_BASE, SNAPSHOT_BASE,
# BORG_UID/BORG_GID, REPO_ROOT) — see the repository root's config.sh for what
# each holds and why. Nothing snapshot-specific exists yet; retention counts
# and a schedule (ROADMAP.md 11.5) belong here once the scripts that need them
# (prune, and whatever else) exist. Mirrors the same split scripts/config.sh
# already does, for the same reason: an upgrade diffs this file to carry
# per-host settings forward without dragging shared plumbing through the diff.
#
# Source this file at the beginning of each script:
#
#   . "$(dirname "$0")/config.sh"
#
# shellcheck disable=SC2034
#
# Every variable below is consumed by the scripts that source this file,
# never within the file itself. Static analysis cannot see across that
# boundary and reports each one as unused, which is why the file-scoped
# suppression above exists.

# --- Shared core -------------------------------------------------------
#
# REPO_ROOT, CONTAINER, HOST_STORAGE_BASE, HOST_REPO_BASE, SNAPSHOT_BASE,
# BORG_UID, BORG_GID — see ../config.sh for the rationale and for how
# REPO_ROOT is resolved.
. "$(dirname "$0")/../config.sh"
