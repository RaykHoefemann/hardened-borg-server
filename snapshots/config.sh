#!/bin/sh
#
# config.sh (snapshots/)
# -----------------------
# snapshots/-side configuration: the shared core one directory up
# (CONTAINER, HOST_STORAGE_BASE, HOST_REPO_BASE, SNAPSHOT_BASE,
# BORG_UID/BORG_GID, REPO_ROOT — see the repository root's config.sh for what
# each holds and why), plus SNAPSHOT_TIMER_NAME below. Creation runs on a
# fixed daily schedule, and retention is a manual operator decision made
# with 75-/76- directly (docs/SNAPSHOTS.md) rather than a configured policy
# -- if an unattended, age-based prune is ever built, its settings belong
# here too. Mirrors the same split scripts/config.sh already does, for the
# same reason: an upgrade diffs this file to carry per-host settings
# forward without dragging shared plumbing through the diff.
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

# --- systemd unit naming -------------------------------------------------
#
# Base name for the snapshot-creation timer/service pair, namespaced by
# CONTAINER for the same reason SNAPSHOT_BASE is: a host running more than
# one instance of this tooling (one per container) installs each instance's
# units as symlinks into the SAME shared ~/.config/systemd/user/ directory
# -- unlike SNAPSHOT_BASE and HOST_REPO_BASE, which live on disk under their
# own CONTAINER branch and can never collide, systemd's user unit namespace
# has no such separation built in. Without this, a second install would
# silently overwrite the first instance's timer under the identical name
# "snapshot-create.timer". 71-timer-install.sh/72-timer-uninstall.sh use
# this for both the .timer and the .service symlink -- systemd pairs a
# timer with the service of the same base name by default, so keeping both
# on this one value is what makes that implicit pairing keep working.
SNAPSHOT_TIMER_NAME="snapshot_${CONTAINER}"
