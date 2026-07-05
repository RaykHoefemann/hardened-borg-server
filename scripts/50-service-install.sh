#!/bin/sh
#
# 50-service-install.sh
# ----------------------
# Generates the systemd unit's EnvironmentFile from config.sh, renders the
# unit template, and installs it as a symlink (avoiding duplicate files).
#
# config.sh is the single source of truth for all runtime values (container
# name, image, ports, UID/GID, host paths). Nothing is hardcoded in the
# systemd unit itself — it references ${VAR} names that systemd resolves
# from the generated EnvironmentFile at service start. Re-run this script
# after any change to config.sh (then `systemctl --user restart $SERVICE`).
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
if [ -z "${IMAGE:-}" ]; then echo "ERROR: 'IMAGE' is not set in config.sh."; exit 1; fi
if [ -z "${SSH_PORT:-}" ]; then echo "ERROR: 'SSH_PORT' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_CONFIG_BASE:-}" ]; then echo "ERROR: 'HOST_CONFIG_BASE' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_REPO_BASE:-}" ]; then echo "ERROR: 'HOST_REPO_BASE' is not set in config.sh."; exit 1; fi
if [ -z "${HOST_LOG_BASE:-}" ]; then echo "ERROR: 'HOST_LOG_BASE' is not set in config.sh."; exit 1; fi

# Normalize HOST_REPO_BASE the same way 00/02/09 do, so the generated
# EnvironmentFile always matches what those scripts operate on exactly.
HOST_REPO_BASE="${HOST_REPO_BASE%/}"

TEMPLATE_FILE="${REPO_ROOT}/systemd/${SERVICE}"
ENV_FILE="${REPO_ROOT}/systemd/${SERVICE}.env"
RENDERED_FILE="${REPO_ROOT}/systemd/${SERVICE}.rendered"
SERVICE_DIR="$HOME/.config/systemd/user"
TARGET_FILE="$SERVICE_DIR/$SERVICE"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Service template not found: $TEMPLATE_FILE"
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
if [ ! -d "$HOST_REPO_BASE" ]; then
    echo "WARNING: HOST_REPO_BASE '$HOST_REPO_BASE' does not exist yet."
    echo "         Make sure the storage volume is mounted before starting the"
    echo "         container (see BEST_PRACTICES.md Chapter 1)."
fi

# --- Generate the EnvironmentFile from config.sh ------------------------
# Note: BORG_UID/BORG_GID are deliberately NOT included here — the systemd
# unit no longer passes them to the container (see container-borg-server.
# service comments). They are still used directly by 00-ssh-create-user.sh
# (podman unshare chown) and don't need to reach the container's env.
echo "[install] Generating $ENV_FILE from config.sh"
cat > "$ENV_FILE" <<EOF
CONTAINER=${CONTAINER}
IMAGE=${IMAGE}
SSH_PORT=${SSH_PORT}
HOST_CONFIG_BASE=${HOST_CONFIG_BASE}
HOST_REPO_BASE=${HOST_REPO_BASE}
HOST_LOG_BASE=${HOST_LOG_BASE}
EOF

# --- Render the unit template (single substitution: EnvironmentFile path) --
echo "[install] Rendering $RENDERED_FILE from template"
sed "s|@@ENV_FILE@@|${ENV_FILE}|" "$TEMPLATE_FILE" > "$RENDERED_FILE"

# --- Install as symlink --------------------------------------------------
echo "[install] Installing systemd unit as symlink..."
mkdir -p "$SERVICE_DIR"

if [ -e "$TARGET_FILE" ]; then
    echo "[install] Removing old file $TARGET_FILE"
    rm -f "$TARGET_FILE"
fi

ln -s "$RENDERED_FILE" "$TARGET_FILE"

echo "[install] Symlink created:"
echo "  $TARGET_FILE -> $RENDERED_FILE"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE"

echo "[install] Service enabled for rootless container."
echo "→ To start the service use 90-container-start.sh"
echo "→ To start the service on boot without login, run:"
echo "  loginctl enable-linger $USER"
