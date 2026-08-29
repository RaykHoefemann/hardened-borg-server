# -----------------------------------------------------------------------------
# BorgBackup Server Container (Debian-based)
#
# This image provides a complete Borg server that is accessible via SSH
# and runs continuously. It is based on Debian, includes BorgBackup
# and an OpenSSH server, supports append-only repositories, and is
# optimized for use with Podman + systemd (e.g., on Fedora CoreOS).
#
# No WireGuard, no Cron, no Borgmatic – just a minimal, stable,
# secure Borg server that works identically to your Debian test setup.
# -----------------------------------------------------------------------------

# Pinned by digest, not by tag.
#
# "stable" moved once already: Debian promoted trixie, silently changing the
# bundled BorgBackup from 1.2.x to 1.4.0 across a major version, under a wrapper
# whose encryption check reads the repository's on-disk manifest. Nothing broke,
# but nobody decided it. A named tag fixes that half; it does not fix the other
# half, because "trixie-slim" is itself rebuilt whenever Debian ships security
# updates, so two builds of the same commit can differ.
#
# A digest makes the image fully determined by the commit. The cost is that base
# security updates now require a deliberate bump — which is the honest state
# regardless, since users receive nothing except through a release.
# tests/base-image-freshness.sh runs weekly and reports when this pin has fallen
# behind, so "deliberate" does not decay into "forgotten".
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && apt-get install -y \
    borgbackup \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*

# Prepare SSH
RUN mkdir -p /var/run/sshd

# UID/GID of the 'borg' user, baked in at build time only. Not exposed as ENV:
# nothing reads PUID/PGID at runtime (the Quadlet passes no such variable), and
# config.sh's BORG_UID/BORG_GID must match whatever is compiled in here.
ARG PUID=1111
ARG PGID=1111

# -p '*' is not decoration. Without it useradd leaves '!' in /etc/shadow, which
# means "account locked", and sshd runs with UsePAM no — so it performs that
# check itself, in allowed_user(), BEFORE any authentication method is tried.
# Every client authenticates as this one user, so a locked account refuses every
# client with "User borg not allowed because account is locked" while the key is
# never even looked at. '*' says the same thing '!' says about passwords — no
# hash will ever match — without the lock. Nothing is loosened by it:
# PasswordAuthentication no means there is no password path to begin with, and
# what confines a session is the forced command in authorized_keys, not this
# field. The login shell has to stay a real shell for the same reason: sshd runs
# the forced command through it.
# Note: `passwd -S borg` prints L for '*' just as it does for '!'. Use
# `getent shadow borg` or an actual client connection to check this.
RUN groupadd -g ${PGID} borg && \
    useradd -u ${PUID} -g ${PGID} -m -d /home/borg -s /bin/bash -p '*' borg

# Prepare SSH directory
RUN mkdir -p /home/borg/.ssh && \
    chown -R borg:borg /home/borg/.ssh && \
    chmod 700 /home/borg/.ssh

# ---------------------------------------------------------
# Hardened SSH configuration (single source of truth)
# ---------------------------------------------------------
RUN cat <<'EOF' > /etc/ssh/sshd_config
Port 22
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
AllowUsers borg
# --- Disable interactive / forwarding features ---
PermitTTY no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
# --- Key-based auth only ---
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
# --- Hardened algorithms ---
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
HostKeyAlgorithms ssh-ed25519
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com
# --- Host Keys (persistent via volume) ---
HostKey /config/ssh_host_keys/ssh_host_ed25519_key
# --- Logging / runtime ---
PrintMotd no
UsePAM no
LoginGraceTime 15
MaxAuthTries 2
MaxSessions 5
MaxStartups 3:50:10
PerSourceMaxStartups 2
EOF

# The release this image was built from. Baked in rather than mounted: what a
# client is told must describe the software actually serving it, not whatever
# the host happens to have in its installation directory. CI enforces that this
# file, the git tag and the published image tag all agree.
COPY VERSION /VERSION

# Copy scripts into the image
COPY build_authorized_keys.sh /build_authorized_keys.sh
COPY entrypoint.sh /entrypoint.sh
COPY borg-wrapper.sh /borg-wrapper.sh
RUN chmod +x /entrypoint.sh /borg-wrapper.sh /build_authorized_keys.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
