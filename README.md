# hardened-borg-server

**Security-hardened BorgBackup server for controlled multi-client environments**

hardened-borg-server is a minimal, security‑focused server wrapper around BorgBackup designed to receive backups from multiple clients in a strictly controlled environment.
It is built around two non‑negotiable principles: uncompromising security and uncompromising privacy.

The system processes only the minimum information required for Borg operations, exposes no auxiliary interfaces, and isolates every client to prevent metadata leakage or cross‑visibility.
It intentionally avoids feature complexity such as web interfaces, orchestration systems, or multi‑purpose APIs in order to maintain a small, auditable, privacy‑preserving, and predictable security surface.

This document is split into two core chapters reflecting these two principles — **Security** (Chapter 1) and **Privacy** (Chapter 2) — followed by general feature, architecture, and configuration documentation.

---

# 1. Security Model

This server is typically deployed in a **DMZ (demilitarized zone)** — it must be reachable from outside the trusted internal network (by clients, mirror partners, or both) and is therefore inherently exposed to the public internet. This exposure makes it a realistic target for attacks: unlike an internal-only service, it cannot rely on network perimeter trust as a primary defense.

This exposed position is a key reason why this project places uncompromising emphasis on security (Chapter 1) rather than treating it as an afterthought: a service sitting in the DMZ has to assume it will be probed and potentially attacked directly, and must be designed to withstand that without relying on the rest of the network being secure.

hardened-borg-server is designed as a **two-layer security system**:

> Application enforcement + hardened host isolation = secure system
>
> Neither layer is sufficient on its own.

## 1.1. Host Security Layer (OPERATOR RESPONSIBILITY)

### ⚠️ This project does NOT provide host-level security.

The host system is a **mandatory security boundary** and is explicitly outside the scope of this project. The application alone is NOT sufficient to ensure secure operation. The host layer must provide isolation and containment guarantees that cannot be enforced by the application.

**Without a solid foundation — a securely hardened host system — no meaningful security can be achieved, no matter how well the application layer itself is secured.** All application-level measures described in Chapter 1.2 operate on top of this foundation and inherit its weaknesses if it is not properly hardened.

For this reason, this project explicitly recommends and is designed around a specific hardened host stack, rather than leaving this as a vague "harden your host" suggestion:

- **Fedora CoreOS** with an **immutable root filesystem** — the base system cannot be modified at runtime, which removes most persistence and tampering opportunities
- **SELinux** in enforcing mode — mandatory access control confines what the container process can do even if it is compromised
- **Rootless containers via Podman** — Podman is the only container runtime that supports rootless operation on the assumed Fedora CoreOS host; the container runtime itself never runs with host root privileges, removing a major class of escape-to-host vulnerabilities
- **XFS as the repository storage filesystem, with project quotas (pquota) enabled** — this is what allows per-client storage limits (see `clients.conf`, Chapter 6.1) to be enforced as a hard limit at the filesystem level, rather than merely tracked informationally by the application

These four building blocks work together: immutability prevents persistence, SELinux constrains behavior, rootless execution removes the easiest privilege-escalation path, and XFS project quotas guarantee that no client can exceed its assigned storage allowance regardless of application-level behavior. Together they form the minimum baseline this project assumes is in place.

Note: these four components are the **complete mandatory host baseline**. Firewall and VPN restrictions (covered separately in Chapter 1.1.3 and in `BEST_PRACTICES.md`, Chapters 4–5) are additional, optional hardening on top of this baseline — not a fifth mandatory component.

### 1.1.1. Why this layer is required

This layer protects against **system-level compromise scenarios** that cannot be mitigated at application level.

Without it, a vulnerability in the backup service could lead to:

- full access to the host filesystem
- access to other clients' backup data
- privilege escalation from container to host
- persistence beyond application scope

### 1.1.2. Threat Scenarios mitigated by the Host Layer

**Container escape / runtime breakout**
If an attacker exploits a vulnerability in Borg or the runtime:
- Rootless containers and SELinux confinement limit host access
- Compromise is contained within restricted namespaces

**Full compromise of the borg-server process**
If the application is fully compromised:
- SELinux restricts filesystem and process access
- Host-level isolation prevents unrestricted system access

**Cross-client isolation failure**
If application isolation fails:
- Host-level separation provides an additional enforcement boundary

**Persistence attacks**
If an attacker gains execution inside the container:
- Immutable host systems reduce persistence opportunities
- System modifications require explicit host-level changes

### 1.1.3. Required Host Stack

Building on the four core components introduced above, a secure deployment must include:

- **Fedora CoreOS** (immutable operating system)
- **SELinux** in enforcing mode (mandatory access control)
- **Podman as rootless container runtime** — the only runtime supporting rootless operation on Fedora CoreOS
- **XFS filesystem with project quotas (pquota) enabled** for the repository storage volume
- Secure storage configuration

Additionally, as **optional, defense-in-depth hardening** — not a requirement for a secure deployment, since the application layer (Chapter 1.2) is designed to be safely reachable directly from the internet — a firewall and/or VPN restriction (e.g. WireGuard) in front of the SSH port can further reduce the attack surface and make it harder for attackers or compromised client devices to even reach the server. See `BEST_PRACTICES.md`, Chapters 4–5, for details.

When implemented correctly, this layer provides:

- containment of compromised processes
- reduced filesystem and kernel access
- significantly reduced attack surface of the base system
- prevention of trivial privilege escalation paths
- reduced blast radius of application compromise
- hard, filesystem-enforced per-client storage limits (via XFS pquota), independent of and in addition to application-level quota tracking

See `BEST_PRACTICES.md` for the required operational baseline.

---

## 1.2. Application Security Layer (this project)

This project enforces security at the application level:

- SSH-based access control for Borg operations
- Repository isolation per client
- Forced command execution (no interactive shell access)
- Append-only enforcement at application layer
- Client isolation via configuration mapping
- Minimal attack surface (SSH-only interface)

### 1.2.1. Access Control

- SSH key-based authentication only
- Password authentication disabled
- Root login disabled
- Dedicated SSH key per client
- Forced command execution prevents shell access
- Clients restricted to assigned repository paths

### 1.2.2. SSH Hardening

- Modern cryptographic algorithms only
- Legacy algorithms disabled
- No TTY, X11, forwarding, or tunneling
- Connection limits enforced
- Persistent SSH host keys for stable identity

### 1.2.3. Repository Isolation

- Each client mapped to a dedicated repository path
- Access enforced via configuration + forced commands
- No cross-repository filesystem access via application layer

### 1.2.4. Append-Only Semantics

- Backup archives can only be appended
- Deletion/modification of existing archives is prevented via application enforcement
- Historical backups remain immutable via Borg interface

### 1.2.5. Network Exposure

Given the DMZ-facing position described at the start of this chapter, the externally reachable surface is kept as small as possible:

- No web interface
- No HTTP API
- SSH is the only external interface

---

## 1.3. Combined Security Guarantees

When deployed according to `BEST_PRACTICES.md` on a properly hardened host system (Chapter 1.1), the application layer (Chapter 1.2) provides:

- strict repository isolation per client
- no shell or interactive access for clients
- server-side enforced access control via forced commands
- append-only backup semantics at application level
- no cross-client access via configuration isolation
- minimal external attack surface (SSH only)

### ⚠️ Deployment Requirement

hardened-borg-server is NOT a standalone secure system. It MUST be deployed on a properly hardened host system as described in Chapter 1.1. Failure to implement the host layer removes a critical security boundary.

---

# 2. Privacy Model

While Chapter 1 covers protection against attackers and system compromise, this chapter covers a separate guarantee: **the server itself never has access to readable backup content.**

## 2.1. Client-Side Encryption

All backup data is encrypted **on the client** before it is ever transmitted to the server.

- Borg performs encryption locally, on the client side, before any data leaves the client machine
- The server only ever receives and stores already-encrypted data
- The encryption key/passphrase is never transmitted to or stored on the server
- As a direct consequence, the server operator cannot decrypt, inspect, or read any client's backup content — even with full access to the repository storage

This is the central privacy guarantee of the system: **the server is, by design, structurally unable to see client data in plaintext.**

### 2.1.1. Key Management & Loss of Access

This privacy guarantee has a direct and unavoidable consequence: **if a client loses their encryption key/passphrase, the corresponding backups are permanently and irrecoverably lost.**

- There is no recovery mechanism, master key, backdoor, or escrow at the server side — this is by design, not an oversight. Any such mechanism would itself be a way for the server (or an attacker who compromises it) to access client data, which would directly contradict the privacy guarantee in 2.1.
- The server cannot reconstruct, derive, or recover a lost key under any circumstances. Repository data without the matching key is, and remains, unreadable ciphertext.
- This places full responsibility for key custody on the **client**, not the server or its operator.

**Operational consequence for clients:** every client must treat their Borg encryption key/passphrase with the same care as the data it protects — arguably more, since losing the key is equivalent to losing the backup entirely.

Recommended practice for clients:

- Keep a secure **offline backup of the encryption key/passphrase**, stored separately from the client machine itself (e.g. in a password manager with its own independent backup, a hardware security device, or a physically secured offline copy)
- Never store the only copy of the key on the same machine that is being backed up — if that machine is lost, stolen, or destroyed, an on-device-only key is lost along with it
- Treat key loss as equivalent in severity to total data loss when planning a backup strategy

## 2.2. Client Isolation & No Cross-Visibility

- Each client is mapped to its own dedicated repository path (see 1.2.3)
- Configuration-level isolation prevents one client from seeing that other clients exist, what they are named, or any details about their repositories
- There is no shared namespace, listing function, or admin view exposed to clients

## 2.3. Logging

- Centralized logs are stored in `/log`
- Logs do **not** contain client-identifying information such as client names or IP addresses
- Logs are limited to operational data needed for diagnosing the service itself, not for tracking client activity

## 2.4. Info Channel

The read-only `info` command (see Chapter 7) intentionally exposes only the minimum data necessary:

- Server-side: name, location, contact
- Client-side: the requesting client's own username and quota

No information about other clients, server internals, or storage contents is ever exposed through this channel.

---

# 3. Features

- 🔒 Security-focused design (minimal attack surface)
- 🔐 Privacy-by-design (client-side encryption, server never sees plaintext or keys)
- 👥 Multi-client backup support
- 🗂️ Strict repository isolation per client
- 🔁 Mirror/offsite backup ingestion support
- 📦 Per-client quota enforcement (hard limit at host filesystem level via XFS pquota)
- ℹ️ Read-only client info channel (server contact + quota info via SSH)
- ⚙️ Fully config-driven behavior
- 🧪 Safe testing environment for backup validation
- 📝 Centralized logging in `/log`
- 🚫 No orchestration layer (deterministic execution only)

---

# 4. Architecture Overview

- Base image: `debian:stable-slim` with BorgBackup installed
- Containerized runtime: **Podman** — required, not just recommended; on the assumed Fedora CoreOS host (Chapter 1.1), Podman is the only runtime that supports rootless operation, and rootless execution is mandatory (see Chapter 1.1). Docker is not supported in this setup.
- Systemd-compatible deployment supported

## 4.1. Storage Model

- Separate volume for repositories
- Separate volume for logs
- Separate volume for configuration

## 4.2. Backup Flows

- Client → Server (SSH / optionally VPN)
- Server → Server (mirror/offsite replication)

---

# 5. Deployment Example

## 5.1. Manual / Ad-hoc Start

```bash
podman run \
  --name=hardened-borg-server \
  --rm \
  --publish=2222:22 \
  --volume=$HOME/containers/borg-server/config:/config:Z \
  --volume=$HOME/containers/borg-server/repo:/repo:Z \
  --volume=$HOME/containers/borg-server/log:/log:Z \
  ghcr.io/raykhoefemann/hardened-borg-server:latest
```

Useful for testing, but the container does not survive a reboot or a logout, and there is no automatic restart on failure.

## 5.2. Persistent Deployment via systemd (Recommended)

For production use, the container should run as a **rootless systemd user service** rather than being started manually. A ready-to-use unit file is provided at `systemd/container-borg-server.service`.

```ini
[Unit]
Description=Borg Backup Server (Podman)
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/podman run \
    --name=borg-server \
    --rm \
    -e PUID=1111 \
    -e PGID=1111 \
    --publish=2222:22 \
    --volume=%h/containers/borg-server/config:/config:Z \
    --volume=%h/containers/borg-server/repo:/repo:Z \
    --volume=%h/containers/borg-server/log:/log:Z \
    ghcr.io/raykhoefemann/borg-server:0.1

ExecStop=/usr/bin/podman stop borg-server

Restart=on-failure
RestartSec=5

User=%u
Group=%u
Environment=PODMAN_SYSTEMD_UNIT=%n

[Install]
WantedBy=default.target
```

### 5.2.1. Why this is a *user* service, not a system service

This unit is designed to be installed under `~/.config/systemd/user/`, not `/etc/systemd/system/`. This distinction matters specifically because rootless operation is mandatory (see Chapter 1.1):

- Run as a **systemd user service** (`systemctl --user ...`), the unit executes inside your own user session, with the normal rootless Podman environment (`XDG_RUNTIME_DIR`, the user's own `containers/storage.conf`, subuid/subgid mappings, etc.) already in place. This is the supported way to run this project.
- A `User=`/`Group=` directive in a **system-wide** unit (`/etc/systemd/system/`) does not reliably reproduce that environment — Podman can fail to locate the expected runtime directory or rootless storage configuration for that user, since system services don't inherit a full user login session by default. Use the user-service path described here rather than adapting this file into a system unit.

### 5.2.2. Setup

```bash
mkdir -p ~/.config/systemd/user
cp systemd/container-borg-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now container-borg-server.service
```

Before relying on this for production, adjust `PUID`/`PGID` in the unit file: `1111` is an example value in the file shown above and must match the actual UID/GID you want the container's internal `borg` user mapped to — copying it unchanged may not match your host user.

### 5.2.3. Lingering: surviving logout and reboot

By default, systemd stops all user services once the user fully logs out, and user services do not start automatically at boot without an active login session. Since this server needs to run continuously, **enable lingering** for the user running the container:

```bash
loginctl enable-linger <username>
```

This tells systemd to start that user's systemd instance (and therefore this service) at boot and keep it running independently of whether that user is logged in interactively. Without this step, the backup server will stop the next time the host reboots or the session ends, even though `Restart=on-failure` is configured.

### 5.2.4. A note on `--rm` combined with `Restart=on-failure`

The provided unit uses `--rm` (remove the container on stop) together with a fixed `--name` and `Restart=on-failure`. This is a known, slightly fragile combination: if the container is not cleanly removed after a crash (for example, after an OOM kill), a subsequent automatic restart can fail with a "name already in use" error, because `podman run` tries to create a container with a name that technically still exists.

In practice this is uncommon, but operators who want a more robust setup can:

- add `--replace` to the `podman run` line, which tells Podman to remove any existing container with the same name before creating a new one, or
- migrate to a **Podman Quadlet** (`.container` file under `~/.config/containers/systemd/`) instead of a hand-written `.service` file, which manages the container lifecycle more robustly and is the currently recommended long-term approach for new Podman/systemd deployments.

The unit as provided is functional and sufficient for most deployments; this is a hardening suggestion, not a required change.

---

# 6. Configuration

All client access is config-driven. Nothing is provisioned automatically beyond what is explicitly defined in `/config`.

## 6.1. clients.conf

- **File:** `config/clients.conf`
- **Format:** `<client>:<group>:<repo>:<quota>`
- **Groups:**
  - `OWN` – internal clients from your own network
  - `MIRROR` – external clients (e.g. friends, offsite partners)
- **Quota:** mandatory, format `<number>G` (e.g. `10G`, `50G`). There is no `unlimited` value — every client must have an explicit quota.

**Example:**

```
user1-os1-pc1:OWN:/repo/OWN/user1-os1-pc1:50G
user2-os1-pc1:OWN:/repo/OWN/user2-os1-pc1:50G
user-pc2:OWN:/repo/OWN/user-pc2:20G
friend1:MIRROR:/repo/MIRROR/friend1:200G
```

> Quota enforcement happens at the host filesystem level via XFS project quotas (see Chapter 1.1.3) — when the host is set up as required, exceeding the configured quota is a hard limit, not merely advisory. The value in `clients.conf` is read and validated by the application and also surfaced via the `info` command (see Chapter 7), but the actual hard enforcement is provided by the underlying XFS pquota mechanism, not by the application itself.

## 6.2. SSH Keys

- Each client has a dedicated public key stored in `config/keys/<client>.pub`
- The file name must match the client name exactly

**Example structure:**

```
config/keys/
├── user1-os1-pc1.pub
├── user2-os1-pc1.pub
├── user-pc2.pub
└── friend1.pub
```

## 6.3. server_info.conf

- **File:** `config/server_info.conf`
- **Format:** `key=value`
- **Required keys:** `name`, `location`, `contact`

**Example:**

```
name=backup01.example.com
location=Frankfurt, DE
contact=admin@example.com
```

This file describes the server itself (not any individual client) and is shown to every client via the `info` command (Chapter 7). All three keys are mandatory — the container will refuse to start `authorized_keys` generation if any are missing.

## 6.4. Visual Overview

```
clients.conf + keys/ + server_info.conf ---> hardened-borg-server ---> Repositories (/repo/...)
```

---

# 7. Client Info Channel

Each client can query basic server and account information over the same SSH connection used for backups — no additional service, port, or protocol is involved.

```bash
ssh -p 2222 borg@<server-host> info
```

This returns a small, read-only text file (`info.txt`, stored inside the client's own repository path) containing:

```
[server]
name: backup01.example.com
location: Frankfurt, DE
contact: admin@example.com

[client]
user: user1-os1-pc1
quota: 50G
```

- `info.txt` is generated and updated automatically whenever `authorized_keys` is rebuilt (i.e. on every container start), based on `clients.conf` and `server_info.conf`.
- It is read-only from the client's perspective — clients cannot modify it.
- No interactive shell, TTY, or any command other than `info` and the normal Borg protocol is accepted; any other command is rejected.
- See Chapter 2.4 for the privacy rationale behind what this channel does and does not expose.

---

# 8. Client Management Scripts

Helper scripts under `scripts/` simplify adding and managing clients on the host side. They operate on the host-side configuration directory (`config/clients.conf`, `config/keys/`) before the container is started or restarted.

## 8.1. 00-ssh-create-user.sh

Creates a new client entry and an empty key placeholder.

```bash
./scripts/00-ssh-create-user.sh <username> <group> <quota>
```

- `<group>`: `OWN` or `MIRROR`
- `<quota>`: mandatory, format `<number>G` (e.g. `50G`)

**Example:**

```bash
./scripts/00-ssh-create-user.sh user1-os1-pc1 OWN 50G
```

## 8.2. 01-ssh-set-user-key.sh

Sets (or overwrites, with confirmation) the public SSH key for an existing client. Accepts either a path to a key file or the key string directly.

```bash
./scripts/01-ssh-set-user-key.sh <username> <keyfile|keystring>
```

**Examples:**

```bash
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 ~/.ssh/id_ed25519.pub
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 "ssh-ed25519 AAAA… user1-os1-pc1"
```

---

# 9. Security & Best Practices

hardened-borg-server enforces strict server-side security measures (see Chapter 1) and a structural privacy guarantee via client-side encryption (see Chapter 2).
However, secure operation also depends on proper configuration and operational practices by the administrator.

⚠️ **Important:** Please review the [Best Practices Guide](./BEST_PRACTICES.md) for recommendations on secure usage, including:

- Encrypting backups before mirroring
- Using tunneled connections for remote replication
- Exposing only the necessary SSH port
- Regular monitoring and verification of backups
- Secure, offline backup of each client's encryption key/passphrase (see Chapter 2.1.1) — this is a client-side responsibility that the server cannot help with or recover from
