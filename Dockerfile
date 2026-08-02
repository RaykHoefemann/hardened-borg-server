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
FROM debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && apt-get install -y \
    borgbackup \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*

# Prepare SSH
RUN mkdir -p /var/run/sshd

# Set User for Borg
ARG ENV PUID=1111
ARG ENV PGID=1111

RUN groupadd -g ${PGID} borg && \
    useradd -u ${PUID} -g ${PGID} -m -d /home/borg -s /bin/bash borg

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
