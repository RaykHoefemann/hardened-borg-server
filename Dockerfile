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

FROM debian:stable-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && apt-get install -y \
    borgbackup \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get autoremove -y

# Prepare SSH
RUN mkdir -p /var/run/sshd

# Set User for Borg
ENV PUID=1111
ENV PGID=1111

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
HostKey /config/ssh_host_keys/ssh_host_rsa_key
# --- Logging / runtime ---
PrintMotd no
UsePAM no
LoginGraceTime 15
MaxAuthTries 2
MaxSessions 5
MaxStartups 3:50:10
PerSourceMaxStartups 2
EOF

# Copy scripts into the image
COPY build_authorized_keys.sh /build_authorized_keys.sh
COPY entrypoint.sh /entrypoint.sh
COPY borg-wrapper.sh /borg-wrapper.sh
RUN chmod +x /entrypoint.sh /borg-wrapper.sh /build_authorized_keys.sh

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
