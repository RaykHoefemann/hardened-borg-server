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
- **XFS as the repository storage filesystem, mounted with enforcing project quotas (`prjquota`, equivalently `pquota`)** — this is what allows per-client storage limits (see `clients.conf`, Chapter 6.1) to be enforced as a hard limit at the filesystem level, rather than merely tracked informationally by the application. The mount must be **enforcing**; the accounting-only variant (`pqnoenforce`) is **not** sufficient, because it neither caps usage nor surfaces per-client usage to the (unprivileged) container. As a useful side effect of enforcing mode, XFS reports each client's quota through `statvfs()`, which is how the `info` channel (Chapter 7) reads live usage without any privileges

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
- **XFS filesystem mounted with enforcing project quotas (`prjquota`)** for the repository storage volume — enforcing mode is mandatory; `pqnoenforce` (accounting only) does not satisfy this requirement
- Secure storage configuration

Additionally, as **optional, defense-in-depth hardening** — not a requirement for a secure deployment, since the application layer (Chapter 1.2) is designed to be safely reachable directly from the internet — a firewall and/or VPN restriction (e.g. WireGuard) in front of the SSH port can further reduce the attack surface and make it harder for attackers or compromised client devices to even reach the server. See `BEST_PRACTICES.md`, Chapters 4–5, for details.

When implemented correctly, this layer provides:

- containment of compromised processes
- reduced filesystem and kernel access
- significantly reduced attack surface of the base system
- prevention of trivial privilege escalation paths
- reduced blast radius of application compromise
- hard, filesystem-enforced per-client storage limits (via enforcing XFS project quotas), independent of and in addition to application-level quota tracking

See `BEST_PRACTICES.md` for the required operational baseline.

---

## 1.2. Application Security Layer (this project)

This project enforces security at the application level:

- SSH-based access control for Borg operations
- Repository isolation per client
- Forced command execution (no interactive shell access)
- Append-only enforcement at application layer
- Client-side (keyfile) encryption enforced at connection time — repositories that are unencrypted, `authenticated`-only, or use server-side `repokey` are rejected (see 2.1.2)
- Client isolation via configuration mapping
- Minimal attack surface (SSH-only interface)
- No monitoring, metrics, or status interface exposed to clients — all observability is host-side only (see 1.2.6)

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

### 1.2.6. Monitoring

Monitoring is deliberately **host-side only** and never exposed through the client-facing SSH interface. There is no metrics endpoint, status port, dashboard, or any additional listening service — adding one would widen the exact externally reachable surface that Chapter 1.2.5 keeps minimal. An operator does not need such an interface anyway: everything relevant is already available locally on the host, without opening anything new to the network:

- **Disk usage of the underlying storage volume** — the `Disk usage:` line of `09-show-all-users.sh` (Chapter 8.5), read directly from the filesystem, independent of any single client's quota.
- **Quota usage of every client** — the same script's per-user `USED` column, read live from each client's enforcing XFS project quota (the same mechanism the client-facing `info` command uses for its own usage, Chapter 7 — but here aggregated for every client at once, for the operator).
- **How long the container has been running** — `systemctl --user status` output (surfaced by `99-container-status.sh`, Chapter 8.10) reports the service's active-since timestamp natively.

All of this is read-only, local-only tooling that runs as the operator on the host — it adds no attack surface, since it observes the same host-side data (`clients.conf`, the XFS quotas, systemd/Podman state) that already exists for operational reasons, rather than introducing a new interface to query it.

---

## 1.3. Combined Security Guarantees

When deployed according to `BEST_PRACTICES.md` on a properly hardened host system (Chapter 1.1), the application layer (Chapter 1.2) provides:

- strict repository isolation per client
- no shell or interactive access for clients
- server-side enforced access control via forced commands
- append-only backup semantics at application level
- server-side enforcement of client-held keyfile encryption (non-keyfile/unencrypted repositories rejected at connection time)
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

### 2.1.2. Server-Side Enforcement of Client-Held Encryption

The guarantee in 2.1 — that the server never holds a key capable of decrypting client data — only holds if clients actually use an encryption mode whose key stays on the client. Borg also supports modes that would undermine this: `repokey` stores the (passphrase-wrapped) key **inside the repository on the server**, `authenticated` stores data in **plaintext** (integrity-protected only), and `none` provides no encryption at all. Relying on every client to choose the right mode would make the privacy guarantee a matter of discipline rather than design.

To make it structural, the server **verifies the encryption mode of every repository on each connection** and accepts only client-held keyfile modes:

- **Accepted:** `keyfile`, `keyfile-blake2` — the key material lives exclusively on the client; nothing on the server can decrypt the data, even under full server compromise.
- **Rejected at connection time:**
  - `repokey` / `repokey-blake2` — key stored in the repository; only passphrase-wrapped and therefore offline-crackable if the server is breached.
  - `authenticated` / `authenticated-blake2` — data stored in plaintext (MAC only, no confidentiality).
  - `none` — unencrypted.

Two independent checks must both pass, and the connection is refused on any error or ambiguity (fail-closed): the repository's manifest key type must be a keyfile type, **and** the repository config must contain no server-side key material. Because Borg does not record the mode in the repository config, the manifest key type is used as the authoritative signal. A rejected repository never reaches the Borg session, so no server-decryptable or plaintext data is ever accepted.

> **Client provisioning consequence:** clients must initialize their repositories with `borg init --encryption=keyfile-blake2` (or `keyfile`). A repository created with any other mode will be refused on its first real backup — see the key-custody requirement in 2.1.1, which is especially critical in keyfile mode since the key exists only on the client.

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
- Client-side: the requesting client's own username, quota, and current storage usage against that quota

The usage figure is the client's own consumption only, derived from its own repository (see Chapter 7). No information about other clients, server internals, or storage contents is ever exposed through this channel.

---

# 3. Features

- 🔒 Security-focused design (minimal attack surface)
- 🔐 Privacy-by-design (client-held keyfile encryption enforced server-side; server never sees plaintext or keys)
- 👥 Multi-client backup support
- 🗂️ Strict repository isolation per client
- 🔁 Mirror/offsite backup ingestion support
- 📦 Per-client quota enforcement (hard limit at host filesystem level via enforcing XFS project quotas)
- ℹ️ Read-only client info channel (server contact, quota, and live usage via SSH)
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

> **Beta phase note:** no stable release has been tagged yet, so the `:latest`
> tag below does not exist on GHCR yet. Replace it with the exact pre-release
> tag you want to test, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.8`
> (see the [package's version list](https://github.com/RaykHoefemann/hardened-borg-server/pkgs/container/hardened-borg-server/versions)
> for the current tags). This note will be removed once a stable release ships.

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

For production use, the container should run as a **rootless systemd user service** rather than being started manually. A ready-to-use unit **template** is provided at `systemd/container-borg-server.service`.

This unit contains no hardcoded values — every runtime setting (`${CONTAINER}`, `${IMAGE}`, `${SSH_PORT}`, `${HOST_CONFIG_BASE}`, `${HOST_REPO_BASE}`, `${HOST_LOG_BASE}`) is resolved by systemd at service start from an `EnvironmentFile`, which `scripts/50-service-install.sh` generates directly from `scripts/config.sh` — the single source of truth for the whole project. Nothing needs to be edited in the unit file itself.

```ini
[Unit]
Description=Borg Backup Server (Podman)
Wants=network-online.target
After=network-online.target

[Service]
# Generated by scripts/50-service-install.sh from config.sh — do not edit
# this path by hand, it is rewritten on every install run.
EnvironmentFile=@@ENV_FILE@@

# All values below (${CONTAINER}, ${IMAGE}, ${HOST_*_BASE}, ${SSH_PORT})
# come from config.sh via the EnvironmentFile above — config.sh is the
# single source of truth, nothing here is hardcoded. Note: systemd expands
# ${VAR} in Exec* ARGUMENTS, but not when a variable stands in for the
# executable itself — /usr/bin/podman below must stay a literal path.
#
# No PUID/PGID passed here: the 'borg' user's UID/GID is fixed inside the
# image at build time (Dockerfile useradd), and entrypoint.sh never reads
# runtime PUID/PGID env vars — passing them would be dead configuration.
# See config.sh (BORG_UID/BORG_GID) for the actual build-time value, used
# by 00-ssh-create-user.sh to set matching host-side ownership.
ExecStart=/usr/bin/podman run \
    --name=${CONTAINER} \
    --rm \
    --publish=${SSH_PORT}:22 \
    --volume=${HOST_CONFIG_BASE}:/config:Z \
    --volume=${HOST_REPO_BASE}:/repo:Z \
    --volume=${HOST_LOG_BASE}:/log:Z \
    ${IMAGE}

ExecStop=/usr/bin/podman stop ${CONTAINER}

Restart=on-failure
RestartSec=5

User=%u
Group=%u
Environment=PODMAN_SYSTEMD_UNIT=%n

[Install]
WantedBy=default.target
```

`@@ENV_FILE@@` is the one placeholder the install script substitutes — everything else in the file above is checked into git unchanged and never needs manual editing.

### 5.2.1. Why this is a *user* service, not a system service

This unit is designed to be installed under `~/.config/systemd/user/`, not `/etc/systemd/system/`. This distinction matters specifically because rootless operation is mandatory (see Chapter 1.1):

- Run as a **systemd user service** (`systemctl --user ...`), the unit executes inside your own user session, with the normal rootless Podman environment (`XDG_RUNTIME_DIR`, the user's own `containers/storage.conf`, subuid/subgid mappings, etc.) already in place. This is the supported way to run this project.
- A `User=`/`Group=` directive in a **system-wide** unit (`/etc/systemd/system/`) does not reliably reproduce that environment — Podman can fail to locate the expected runtime directory or rootless storage configuration for that user, since system services don't inherit a full user login session by default. Use the user-service path described here rather than adapting this file into a system unit.

### 5.2.2. Setup

Before installing, review `scripts/config.sh` — in particular `HOST_REPO_BASE` (must point at your enforcing-prjquota XFS volume, see Chapter 1.1.3) and `IMAGE` (during the beta phase, `:latest` does not exist yet — set this to the exact pre-release tag you want to run, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.8`).

```bash
./scripts/50-service-install.sh
systemctl --user enable --now container-borg-server.service
```

`50-service-install.sh` generates the `EnvironmentFile` from `config.sh`, renders the unit template into `systemd/container-borg-server.service.rendered`, and symlinks that into `~/.config/systemd/user/`. Re-run it after any change to `config.sh` (e.g. bumping `IMAGE` to a new tag), then restart the service for the change to take effect — day-to-day start/stop/restart/status is handled by the scripts in Chapter 8.7–8.10:

```bash
./scripts/50-service-install.sh
./scripts/92-container-restart.sh
```

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

> Quota enforcement happens at the host filesystem level via enforcing XFS project quotas (see Chapter 1.1.3) — when the host is set up as required, exceeding the configured quota is a hard limit, not merely advisory. The value in `clients.conf` is read and validated by the application and used to provision the per-repository project limit; the actual hard enforcement is provided by the underlying XFS project-quota mechanism, not by the application itself. Live usage against this limit is reported to the client through the `info` command (see Chapter 7), read directly from the enforcing quota via `statvfs()`.

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

This returns two things: a small, read-only text file (`info.txt`, stored inside the client's own repository path) describing the server and the client's account, followed by a single live line reporting current storage usage against the client's quota:

```
[server]
name: backup01.example.com
location: Frankfurt, DE
contact: admin@example.com

[client]
user: user1-os1-pc1
quota: 50G

Used: 12.4 GiB of 50.0 GiB (24%)
```

- `info.txt` is generated and updated automatically whenever `authorized_keys` is rebuilt (i.e. on every container start), based on `clients.conf` and `server_info.conf`. It is read-only from the client's perspective — clients cannot modify it.
- The `Used:` line is computed **live at query time** from the client's own repository directory via `statvfs()`. Because the repository sits under an enforcing XFS project quota (Chapter 1.1.3), `statvfs()` reports the quota's limit and current consumption directly, so no elevated privileges, quota tooling, or host-side helper are needed inside the container. The reported limit is the actual filesystem-enforced quota, not merely the configured `clients.conf` value.
  - *Diagnostic:* if this line reports the size of the whole underlying disk instead of the per-client limit, project-quota enforcement is not active on the repository mount (i.e. the mount is missing `prjquota` / is `pqnoenforce`).
- No interactive shell, TTY, or any command other than `info` and the normal Borg protocol is accepted; any other command is rejected.
- See Chapter 2.4 for the privacy rationale behind what this channel does and does not expose.

---

# 8. Host Management Scripts

> **These scripts run on the HOST, never on a client.** Nothing here is
> installed on, or needed by, the machines being backed up — clients only
> ever need an SSH key and a `borg` invocation (see Chapter 4). All scripts
> below are administrative tools for the person operating the backup server
> itself.

Helper scripts under `scripts/` manage the server's clients, quotas, the systemd service, and the container's lifecycle (start/stop/restart/status). All of them source `scripts/config.sh` — the single source of truth for paths, the container image, and runtime values (see Chapter 8.1 below) — so nothing here needs separate configuration.

## 8.1. config.sh

**Before running any other script in this chapter, review and adjust `scripts/config.sh`.** It is sourced by every script below and is the single place where host-specific values live — nothing else in the repo should need to be edited to get the server running.

**Must be adjusted for your installation:**

- `HOST_REPO_BASE` — the host path holding client repositories. **Must** point at an XFS filesystem with enforcing project quotas (`prjquota`) already active (see Chapter 1.1.3 / BEST_PRACTICES.md Chapter 1). This is also bind-mounted as `/repo` in the generated systemd unit (Chapter 5.2), so the container and the host scripts are always guaranteed to operate on the same directory.
- `IMAGE` — the container image reference to run, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:latest`. During the beta phase, `:latest` does not exist yet (no stable release has shipped) — set this to the exact pre-release tag you want to run instead, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.9` (see the [package's version list](https://github.com/RaykHoefemann/hardened-borg-server/pkgs/container/hardened-borg-server/versions) for current tags).

**Derived automatically — normally left alone:**

- `REPO_ROOT` — computed from the location of whichever script sourced `config.sh`; correct regardless of the directory you run scripts from.
- `HOST_CONFIG_BASE`, `HOST_LOG_BASE` — kept inside the repo checkout (`${REPO_ROOT}/config`, `${REPO_ROOT}/log`) unless you have a reason to move them elsewhere.
- `CONF`, `KEYDIR` — the exact `clients.conf` and key-storage paths used by `00`/`01`/`02`/`09`, derived from `HOST_CONFIG_BASE`.
- `CONTAINER_REPO_BASE` — the container-side path prefix (`/repo/`); only relevant if you change the container's internal mount point, which the shipped image does not expect.

**Fixed values — only change if you know why:**

- `CONTAINER`, `SERVICE` — the Podman container name and systemd unit filename.
- `SSH_PORT` — the port the container's SSH listens on (bind-mounted in the generated unit).
- `PROJID_BASE` — the floor for auto-allocated XFS project IDs (Chapter 8.2 scans existing repos and starts above this).
- `BORG_UID`, `BORG_GID` — the `borg` user's UID/GID **inside the container image**, fixed at build time in the Dockerfile. These must match the image you are actually running; only change them if you rebuilt the image with different values yourself. Used by `00-ssh-create-user.sh` to set correct host-side ownership via `podman unshare`.

## 8.2. 00-ssh-create-user.sh

Creates a new Borg client end-to-end: the host-side repository directory, an XFS project quota assigned and set to the given hard limit (requires enforcing `prjquota`, see Chapter 1.1.3), the `clients.conf` entry, and an empty public-key placeholder. Also sets correct host ownership on the new directory via `podman unshare` so the container's `borg` user can write to it.

Must be run as root (or with equivalent `CAP_SYS_ADMIN`) for the `xfs_quota` operations.

```bash
./scripts/00-ssh-create-user.sh <username> <group> <quota>
```

- `<group>`: `OWN` or `MIRROR`
- `<quota>`: mandatory, format `<number>G` (e.g. `50G`)

**Example:**

```bash
sudo ./scripts/00-ssh-create-user.sh user1-os1-pc1 OWN 50G
```

## 8.3. 01-ssh-set-user-key.sh

Sets (or overwrites, with confirmation) the public SSH key for an existing client. Accepts either a path to a key file or the key string directly.

```bash
./scripts/01-ssh-set-user-key.sh <username> <keyfile|keystring>
```

**Examples:**

```bash
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 ~/.ssh/id_ed25519.pub
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 "ssh-ed25519 AAAA… user1-os1-pc1"
```

## 8.4. 02-chance-user-quota.sh

Changes the quota of an existing client. Looks up its host repository directory and existing XFS project id, applies the new hard limit immediately via `xfs_quota` (takes effect right away — no container restart needed for enforcement), and updates the `quota:` field in `clients.conf`.

> The container still needs a restart to refresh the *displayed* `quota:` value in the client's `info.txt` (see Chapter 7) — the actual enforced limit and the live `Used: X of Y` figure update immediately regardless, since both are read straight from the filesystem quota.

Must be run as root (or with equivalent `CAP_SYS_ADMIN`).

```bash
sudo ./scripts/02-chance-user-quota.sh <username> <new-quota>
```

**Example:**

```bash
sudo ./scripts/02-chance-user-quota.sh user1-os1-pc1 100G
```

## 8.5. 09-show-all-users.sh

Prints an overview of every configured client, grouped by `OWN`/`MIRROR`, with each client's configured quota and its **live** storage usage — read the same way the client `info` channel reads it (directly from the enforcing XFS project quota via `df`, see Chapter 7), not just the static `clients.conf` value. Also reports total physical disk usage of the underlying storage volume. Read-only, does not require root.

```bash
./scripts/09-show-all-users.sh
```

## 8.6. 50-service-install.sh

Generates the systemd unit's `EnvironmentFile` from `config.sh`, renders the unit template (`systemd/container-borg-server.service`), and installs it as a symlink under `~/.config/systemd/user/` (see Chapter 5.2.2). Re-run after any change to `config.sh` (for example, bumping `IMAGE` to a new tag), then restart the service for the change to take effect.

```bash
./scripts/50-service-install.sh
systemctl --user restart container-borg-server.service
```

## 8.7. 90-container-start.sh

Starts the container via the systemd user service and confirms it reached the active state.

```bash
./scripts/90-container-start.sh
```

## 8.8. 91-container-stop.sh

Stops the container via the systemd user service and confirms it reached the inactive state.

```bash
./scripts/91-container-stop.sh
```

## 8.9. 92-container-restart.sh

Restarts the container via the systemd user service. **Run this after any change to `clients.conf`** (e.g. after `00-ssh-create-user.sh`, `01-ssh-set-user-key.sh`, or `02-chance-user-quota.sh`) — `authorized_keys` is rebuilt from `clients.conf` only at container start, so client additions, key changes, or quota updates only take effect for SSH access after a restart.

```bash
./scripts/92-container-restart.sh
```

## 8.10. 99-container-status.sh

Shows a combined status view: the systemd service state, `podman ps` output, a detailed `podman inspect` (image, PID, network, mounts) if the container is currently registered with Podman, and the last 20 lines of the service's journal log.

```bash
./scripts/99-container-status.sh
```

> Because the unit uses `--rm` (see Chapter 5.2.4), a stopped container is removed rather than left in an exited state — so `podman ps -a` normally shows nothing for it between runs. This is expected; the script accounts for it and falls back to reporting that the container may be running transiently under systemd.

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

---

# 10. Roadmap

Planned features, not yet implemented. Listed here for visibility; timelines are not committed.

## 10.1. Automated Archive Pruning

Automated, operator-configurable retention policies (e.g. "keep 7 daily, 4 weekly, 6 monthly" per client), so old archives are cleaned up without a manual `borg prune` run.

This needs to be reconciled carefully with the append-only enforcement described in Chapter 1.2.4: today, deletion is intentionally something a client cannot trigger. Automated pruning will need to be a distinct, deliberate server/operator-side mechanism — not a relaxation of what a client connection is allowed to do — so the existing append-only guarantee is not weakened by this feature.

## 10.2. Mirroring Own Repositories to a Foreign Backup Server

The ability for this server to push/replicate the repositories it hosts to a **different, external backup server** for offsite redundancy — the reverse direction of the existing `MIRROR` client group (Chapter 6.1), which is about *receiving* backups from external/friend clients, not sending this server's own hosted data elsewhere.

This replication is planned as an **exact 1:1 copy** of the repository — a full, byte-for-byte replica, not a selective or filtered transfer. There is no point in this pipeline where the server can inspect, redact, or otherwise limit what the foreign server receives: it gets literally the same repository this server holds.

This makes client-side encryption not just a good idea but an absolute precondition for this feature: the foreign backup server is, by definition, outside this project's trust boundary — a third party whose own security this project has no control over. The entire confidentiality of the mirrored copy depends on the client having already encrypted every archive with a client-held key **before** it ever reached this server in the first place. As with any repository handled by this project, the client-held keyfile encryption model (Chapter 2.1.2) is expected to carry over unchanged: a mirrored copy remains only as readable as the original — the encryption key stays with whoever holds it today, not with either server. An unencrypted repository must never be mirrored this way, since doing so would hand the foreign server a complete, plaintext copy of everything.

## 10.3. Automated Integrity Verification (`borg check`)

Scheduled, operator-side integrity checking of the hosted repositories via `borg check`, so that silent on-disk corruption (bit rot, a truncated segment, an inconsistent index) is detected proactively rather than discovered at restore time.

The privacy model (Chapter 2.1) directly shapes what this feature can and cannot do — this is the central design constraint, not an afterthought:

- **Repository-level checks (`borg check --repository-only`) are possible server-side.** They validate the repository's own structures — segment files, hashes, index/manifest consistency — without decrypting any archive contents, and therefore need no encryption key. This is exactly the class of damage the server is in a position to detect, and where automated server-side checking genuinely adds value.
- **Archive-data verification (`borg check --verify-data`, and the archive-consistency portion of a full check) is *not* possible server-side.** Reading archive metadata and re-verifying chunk contents requires the repository key, which by design never exists on the server (Chapter 2.1). Deep, content-level verification therefore remains a **client-side responsibility**, carried out by whoever holds the key — the server cannot, and must not be able to, perform it.

Two existing guarantees must be preserved when this lands:

- **Append-only (Chapter 1.2.4):** `borg check` has a `--repair` mode that *modifies* the repository. As with automated pruning (10.1), repair must never be reachable from a client connection and must be a distinct, deliberate operator-side action. The scheduled check itself runs strictly read-only; repair stays manual.
- **Host-side-only observability (Chapter 1.2.6):** results surface to the operator on the host (log output and exit status, e.g. driven by a systemd timer), not through a new client-facing interface or port. Whether a "last checked" timestamp is later surfaced to clients through the existing `info` channel (Chapter 7) is a separate, deliberate decision — doing so would widen what that channel reports and is intentionally out of scope for the first iteration.

Practical considerations: `borg check` is I/O-intensive, so scheduling must avoid colliding with active backup windows, and each per-repository check should run under the same isolation the rest of the server uses.

## 10.4. Migration from a hand-written systemd unit to Podman Quadlets

Replacing the current hand-written systemd unit **template** + generated `EnvironmentFile` (Chapter 5.2) with a declarative **Podman Quadlet** — a `.container` file under `~/.config/containers/systemd/`, from which `podman-systemd.generator` produces the actual service unit automatically. This direction is already noted in Chapter 5.2.4 as the recommended long-term approach; this roadmap item is about making it the default deployment path rather than an alternative mentioned in a footnote.

Motivation:

- **More robust lifecycle handling.** Quadlets manage container creation and removal natively, which removes the fragile `--rm` + fixed `--name` + `Restart=on-failure` interaction described in 5.2.4 (the "name already in use" failure after an unclean stop) without needing the `--replace` workaround.
- **Less bespoke plumbing.** The declarative `.container` file replaces the template-rendering + `EnvironmentFile` machinery, simplifying `scripts/50-service-install.sh` and shrinking the amount of hand-maintained systemd glue.

Constraints to preserve:

- **`config.sh` stays the single source of truth (Chapter 8.1).** The `.container` file must still derive its values (`IMAGE`, `SSH_PORT`, the `HOST_*_BASE` bind mounts, `CONTAINER`) from `config.sh`, exactly as the current unit does — most plausibly by having `50-service-install.sh` render the `.container` from `config.sh` the same way it renders the `.service` today. The migration must not reintroduce hardcoded values into a checked-in unit.
- **Rootless user service + lingering stay unchanged (Chapters 5.2.1, 5.2.3).** A Quadlet under `~/.config/containers/systemd/` is still a rootless *user* service and still relies on `loginctl enable-linger` to survive logout and reboot. None of the rootless-operation guarantees from Chapter 1.1 change.

This is a **deployment/lifecycle change only** — it does not alter client-facing behavior, the security model (Chapter 1), or the privacy model (Chapter 2). Existing deployments on the current `.service` unit continue to work; the Quadlet becomes the recommended path for new installations.
