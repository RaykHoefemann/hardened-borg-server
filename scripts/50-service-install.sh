#!/bin/sh
#
# 50-service-install.sh
# ----------------------
# Installs the Podman Quadlet for the Borg server container and generates its
# deployment drop-in from config.sh. (ROADMAP 11.4: replaces the hand-written
# systemd/container.service template + generated EnvironmentFile.)
#
# Two files land under ~/.config/containers/systemd/, from which
# `systemctl --user daemon-reload` makes podman-system-generator produce the
# actual ${CONTAINER}.service unit:
#
#   ${CONTAINER}.container                     -> symlink to the checked-in
#                                                systemd/borg-server.container
#                                                (static, no deployment values;
#                                                a `git pull` that changes it is
#                                                picked up without re-running
#                                                this script)
#   ${CONTAINER}.container.d/10-deployment.conf -> generated here from config.sh:
#                                                Image, ContainerName, the
#                                                published port and the three
#                                                bind mounts
#
# config.sh stays the single source of truth for every runtime value
# (DEPLOYMENT 9.1). Nothing deployment-specific is hardcoded in the
# checked-in .container file. Re-run this script after any change to
# config.sh (e.g. pinning IMAGE to a digest), then restart the service
# (92-container-restart.sh).
#
# Installed as ${CONTAINER}.container -- namespaced by CONTAINER through the
# filename, so a host running more than one instance of this project does not
# have a second install silently overwrite the first's Quadlet in the shared
# ~/.config/containers/systemd/ directory.
#
# Usage:
#   ./scripts/50-service-install.sh
#

set -e
#load setup for all scripts
. "$(dirname "$0")/config.sh"

# --- Validate required values are present -----------------------------
if [ -z "${CONTAINER:-}" ]; then echo "ERROR: 'CONTAINER' is not set in config.sh."; exit 1; fi
if [ -z "${SERVICE:-}" ]; then echo "ERROR: 'SERVICE' is not set in config.sh."; exit 1; fi
if [ -z "${QUADLET_SOURCE_NAME:-}" ]; then echo "ERROR: 'QUADLET_SOURCE_NAME' is not set in config.sh."; exit 1; fi
if [ -z "${IMAGE:-}" ]; then echo "ERROR: 'IMAGE' is not set in config.sh."; exit 1; fi
if [ -z "${SSH_PORT:-}" ]; then echo "ERROR: 'SSH_PORT' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_CONFIG_BASE:-}" ]; then echo "ERROR: 'HOST_CONFIG_BASE' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_REPO_BASE:-}" ]; then echo "ERROR: 'HOST_REPO_BASE' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_LOG_BASE:-}" ]; then echo "ERROR: 'HOST_LOG_BASE' is not set in config.sh."; exit 1; fi

# Normalize HOST_REPO_BASE the same way 00/02/09 do, so the bind mount in the
# generated drop-in always matches what those scripts operate on exactly.
HOST_REPO_BASE="${HOST_REPO_BASE%/}"

SOURCE_FILE="${REPO_ROOT}/systemd/${QUADLET_SOURCE_NAME}"
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="${QUADLET_DIR}/${CONTAINER}.container"
DROPIN_DIR="${QUADLET_DIR}/${CONTAINER}.container.d"
DROPIN_FILE="${DROPIN_DIR}/10-deployment.conf"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: Quadlet source not found: $SOURCE_FILE"
    exit 1
fi

# --- Ensure host directories used by the container exist ---------------
# HOST_CONFIG_BASE/HOST_LOG_BASE are plain directories inside the repo
# checkout — safe to create here. HOST_REPO_BASE is deliberately NOT
# created or touched by this script: it must already exist on an XFS
# filesystem with enforcing project quotas (00-ssh-create-user.sh
# validates this before ever writing to it). Silently mkdir'ing it here
# could mask a not-yet-mounted storage volume.
mkdir -p "$HOST_CONFIG_BASE" "$HOST_LOG_BASE"

# A missing HOST_REPO_BASE is fatal, not a warning.
#
# It is the source of the container's /repo bind mount, and podman refuses to
# start a container whose bind-mount source does not exist. Installing the unit
# anyway produced the worst possible shape of that failure: `systemctl --user
# daemon-reload` still exits 0, the unit does not reach `failed` but sits in
# `activating (auto-restart)`, and the only evidence is "statfs ...: no such
# file or directory" in the journal — one step after the warning that predicted
# it has scrolled off the screen.
#
# The directory is still not created here, for the reason above: an unmounted
# volume usually leaves its mount point behind as an empty directory on the
# root filesystem, where a mkdir succeeds and client repositories then land on
# the system disk with no project quotas at all.
if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "ERROR: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist."
    echo "       It is bind-mounted into the container as /repo, and podman will"
    echo "       not start a container whose bind-mount source is missing."
    echo ""
    PARENT_DIR="$(dirname "$HOST_REPO_BASE")"
    if [ -d "$PARENT_DIR" ] && [ "$(stat -c %m "$PARENT_DIR" 2>/dev/null)" = "$PARENT_DIR" ]; then
        echo "       '$PARENT_DIR' is a mount point, so the storage volume looks"
        echo "       mounted and only this subdirectory is missing. Create it and"
        echo "       re-run this script:"
        echo ""
        echo "           mkdir -p $HOST_REPO_BASE"
    else
        echo "       '$PARENT_DIR' is not a mount point, so the storage volume is"
        echo "       probably not mounted. Do NOT create the directory to get past"
        echo "       this: on an unmounted mount point that succeeds silently, and"
        echo "       client repositories end up on the root filesystem without the"
        echo "       enforcing XFS project quotas this server depends on"
        echo "       (BEST_PRACTICES.md Chapter 1). Mount the volume first."
    fi
    exit 1
fi

# --- Install the Quadlet source as ${CONTAINER}.container --------------
# A symlink, not a copy: a release ships systemd/borg-server.container, and a
# `git pull` that changes it is then live after the next daemon-reload with no
# re-run of this script. podman-system-generator resolves symlinks in its
# search directories.
mkdir -p "$QUADLET_DIR"

# Refuse to clobber another installation's Quadlet.
#
# Every per-instance resource of this project is namespaced by CONTAINER
# (repo-root config.sh): the Quadlet filename, its .container.d drop-in, the
# generated ${CONTAINER}.service, the podman container name, HOST_REPO_BASE,
# SNAPSHOT_BASE, the snapshot timer. Two checkouts on one host that forgot to
# give the second a distinct CONTAINER would both resolve to this same
# ${CONTAINER}.container, and a plain install would silently replace the
# first. Fail loudly instead: if the file is already here and is NOT this
# checkout's own symlink, it belongs to another installation.
if [ -L "$QUADLET_FILE" ]; then
    EXISTING_TARGET="$(readlink -f "$QUADLET_FILE" 2>/dev/null || true)"
    SOURCE_REAL="$(readlink -f "$SOURCE_FILE" 2>/dev/null || echo "$SOURCE_FILE")"
    if [ "$EXISTING_TARGET" != "$SOURCE_REAL" ]; then
        echo "ERROR: '$QUADLET_FILE' already exists and points at"
        echo "       '${EXISTING_TARGET:-<unresolvable>}', not this checkout's"
        echo "       '$SOURCE_REAL'."
        echo "       CONTAINER='${CONTAINER}' is already in use by another"
        echo "       installation of this project on this host. Give this one a"
        echo "       distinct CONTAINER (and SSH_PORT) in config.sh, or run"
        echo "       ./scripts/51-service-uninstall.sh from the other checkout first."
        exit 1
    fi
elif [ -e "$QUADLET_FILE" ]; then
    echo "ERROR: '$QUADLET_FILE' exists but is not a symlink this script wrote."
    echo "       Something placed it by hand. Move it aside and re-run, or pick a"
    echo "       different CONTAINER in config.sh."
    exit 1
fi

echo "[install] Installing Quadlet: $QUADLET_FILE -> $SOURCE_FILE"
rm -f "$QUADLET_FILE"
ln -s "$SOURCE_FILE" "$QUADLET_FILE"

# --- Generate the deployment drop-in from config.sh -------------------
# The values that differ per host. Quadlet merges *.conf from
# <name>.container.d/ before generating the unit, so these complete the
# otherwise deployment-agnostic source file.
#
# BORG_UID/BORG_GID are deliberately NOT here — the container's 'borg' user is
# fixed in the image at build time and entrypoint.sh reads no runtime PUID/PGID
# (see systemd/borg-server.container). They are used directly by
# 00-ssh-create-user.sh (podman unshare chown) and need not reach the
# container's env.
#
# ContainerName=${CONTAINER}: the host scripts do `podman exec ${CONTAINER}` /
# `podman ps --filter name=${CONTAINER}`; without this Quadlet would name the
# container systemd-${CONTAINER}.
echo "[install] Generating $DROPIN_FILE from config.sh"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
# Auto-generated by scripts/50-service-install.sh from config.sh.
# Do not edit by hand — it is rewritten on every install run.
[Container]
Image=${IMAGE}
ContainerName=${CONTAINER}
PublishPort=${SSH_PORT}:22
Volume=${HOST_CONFIG_BASE}:/config:Z
Volume=${HOST_REPO_BASE}:/repo:Z
Volume=${HOST_LOG_BASE}:/log:Z
EOF

# --- Regenerate units from the Quadlet -------------------------------
echo "[install] Reloading the user manager (regenerates ${SERVICE} from the Quadlet)"
systemctl --user daemon-reload

# Do NOT `systemctl --user enable ${SERVICE}` here: it is a generated unit and
# cannot be enabled directly. The [Install] WantedBy=default.target in
# borg-server.container is transcribed into the generated unit and honoured on
# the daemon-reload above; linger is what carries it across reboot/logout.
if ! systemctl --user cat "$SERVICE" >/dev/null 2>&1; then
    echo "ERROR: '${SERVICE}' was not generated from the Quadlet."
    echo "       Check 'systemctl --user status ${SERVICE}' and the journal;"
    echo "       a Quadlet syntax error is reported there, not here."
    echo "       This also needs podman with Quadlet drop-in support"
    echo "       (podman >= 5.0)."
    exit 1
fi

echo "[install] Quadlet installed; ${SERVICE} generated."
echo "→ Start it:            ./scripts/90-container-start.sh"
echo "→ Survive reboot/logout: loginctl enable-linger $USER"
