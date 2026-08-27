#!/bin/sh
#
# config.sh (repository root)
# ----------------------------
# The values genuinely shared between scripts/ (the Borg-side host scripts)
# and, per ROADMAP.md 11.5, the snapshots/ tooling: this installation's
# identity and the storage paths derived from it. Everything specific to one
# side or the other stays in that side's own config.sh instead of here — see
# scripts/config.sh, which sources this file first and then adds what only
# the Borg side needs — so this file stays exactly the intersection, never a
# dumping ground for values only one consumer reads.
#
# Source this file from a script exactly one directory below the repository
# root (today: scripts/*.sh; per ROADMAP.md 11.5, eventually also
# snapshots/*.sh):
#
#   . "$(dirname "$0")/../config.sh"
#
# shellcheck disable=SC2034
#
# Every variable below is consumed by scripts two sourcing steps down the
# chain (e.g. scripts/00-foo.sh -> scripts/config.sh -> this file), never
# within this file itself. Static analysis cannot see across that boundary
# and reports each one as unused, which is why the file-scoped suppression
# above exists. Real findings in this file are still reported.

# Resolve the repository root relative to whichever script originally
# started this sourcing chain (dirname "$0" is that script's own directory,
# e.g. ".../scripts" or ".../snapshots" — $0 is set once, by direct
# invocation, and is unaffected by however many files that script goes on to
# source, so this is correct regardless of how deep the chain is), not the
# caller's current working directory or this file's own location.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# This installation's identity. HOST_REPO_BASE and SNAPSHOT_BASE below are
# both derived from this value rather than set independently, so an
# installation's storage location and its runtime identity can never drift
# apart — and so two independent instances of this project (or, per
# ROADMAP.md 11.5, of its snapshot tooling) on the same host or the same
# shared volume get non-overlapping paths automatically, from distinct
# CONTAINER values, with no coordination required. Change it only if you are
# running more than one instance of this project.
CONTAINER="borg-server"

# UID/GID of the 'borg' user INSIDE the container image. Baked in at build
# time (Dockerfile: useradd -u ${PUID} -g ${PGID} ... borg) and fixed from
# then on; only change these if you rebuilt the image with different values
# yourself. Used today by scripts/00-ssh-create-user.sh to set correct host
# ownership on new repo directories via `podman unshare`. Per ROADMAP.md
# 11.5's "Restore must re-establish quota identity" constraint, the future
# snapshot-restore path will need to re-apply the same ownership — which is
# why these live here rather than in scripts/config.sh alone.
BORG_UID=1111
BORG_GID=1111

# --- Host-side storage paths -------------------------------------------

# The mount point of the dedicated XFS filesystem that has ENFORCING project
# quotas (prjquota) enabled — see README Chapter 1.1.3 / BEST_PRACTICES.md
# Chapter 1. ADJUST THIS to your actual mount point; nothing below needs
# editing once this is right.
HOST_STORAGE_BASE="/var/mnt/extern1"

# Repository storage: this installation's own subdirectory of
# HOST_STORAGE_BASE, named after CONTAINER above rather than an independent
# literal, so storage location and installation identity can never drift
# apart. This is also the exact value used to bind-mount /repo in the
# generated systemd unit (see scripts/50-service-install.sh) — so the
# container is guaranteed to mount the same directory that scripts/00, 02, 09
# operate on. A trailing slash is optional — every consumer normalizes this
# value itself, so either "/path/to/repo" or "/path/to/repo/" works the same.
HOST_REPO_BASE="${HOST_STORAGE_BASE}/${CONTAINER}/"

# Snapshot root for the point-in-time snapshot tooling (ROADMAP.md 11.5).
# Consumed by all four snapshots/ scripts -- 70-create-snapshot.sh,
# 75-list-snapshots.sh, 76-delete-snapshots.sh (the prune path -- manual,
# client-scoped deletion; an unattended, retention-driven prune remains a
# separate, still-open question), and 77-restore-last-snapshot.sh. A fifth
# script, structural comparison between generations, was considered and
# dropped (ROADMAP.md 11.5, "Snapshot comparison"). Its shape: a sibling of
# HOST_REPO_BASE, built from the same two values (HOST_STORAGE_BASE,
# CONTAINER) rather than parsed out of HOST_REPO_BASE at
# runtime -- see the constraint recorded in ROADMAP.md 11.5 for why that
# distinction matters. A trailing slash is optional, as above.
SNAPSHOT_BASE="${HOST_STORAGE_BASE}/.snapshots/${CONTAINER}/"
