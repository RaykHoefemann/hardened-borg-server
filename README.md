# hardened-borg-server

**Security-hardened BorgBackup server for controlled multi-client environments**

hardened-borg-server is a minimal, security-focused server wrapper around BorgBackup designed to receive backups from multiple clients in a strictly controlled environment.

It intentionally avoids feature complexity such as web interfaces, orchestration systems, or multi-purpose APIs in order to maintain a small, auditable, and predictable security surface.

---

# 🔐 Security Model Overview

hardened-borg-server is designed as a **two-layer security system**:

## 1. Application Security Layer (this project)

This project enforces security at the application level:

- SSH-based access control for Borg operations
- Repository isolation per client
- Forced command execution (no interactive shell access)
- Append-only enforcement at application layer
- Client isolation via configuration mapping
- Minimal attack surface (SSH-only interface)

## 2. Host Security Layer (OPERATOR RESPONSIBILITY)

The host system is a **mandatory security boundary** and is explicitly outside the scope of this project.

Secure operation requires a hardened host environment provided and maintained by the operator.

---

## 🧱 Host Security Layer (CRITICAL SECURITY BOUNDARY)

### ⚠️ This project does NOT provide host-level security.

The application alone is NOT sufficient to ensure secure operation.

The host layer must provide isolation and containment guarantees that cannot be enforced by the application.

---

## 🎯 Why this layer is required

This layer protects against **system-level compromise scenarios** that cannot be mitigated at application level.

Without it, a vulnerability in the backup service could lead to:

- full access to the host filesystem
- access to other clients’ backup data
- privilege escalation from container to host
- persistence beyond application scope

---

## 🧨 Threat Scenarios mitigated by the Host Layer

### 1. Container escape / runtime breakout
If an attacker exploits a vulnerability in Borg or the runtime:
- Rootless containers and SELinux confinement limit host access
- Compromise is contained within restricted namespaces

### 2. Full compromise of the borg-server process
If the application is fully compromised:
- SELinux restricts filesystem and process access
- Host-level isolation prevents unrestricted system access

### 3. Cross-client isolation failure
If application isolation fails:
- Host-level separation provides an additional enforcement boundary

### 4. Persistence attacks
If attacker gains execution inside container:
- Immutable host systems reduce persistence opportunities
- System modifications require explicit host-level changes

---

## 🧱 Security Effect of the Host Layer

When implemented correctly (e.g. Fedora CoreOS + SELinux + rootless containers), this layer provides:

- containment of compromised processes
- reduced filesystem and kernel access
- significantly reduced attack surface of the base system
- prevention of trivial privilege escalation paths
- reduced blast radius of application compromise

---

## 🧱 Required Host Stack (Operator Responsibility)

A secure deployment typically includes:

- Fedora CoreOS (immutable operating system)
- SELinux in enforcing mode (mandatory access control)
- Rootless container runtime (e.g. Podman)
- Proper firewall and network segmentation
- Secure storage configuration

---

## 🔐 Core Principle

Security is achieved only when BOTH layers are present:

> Application enforcement + hardened host isolation = secure system

Neither layer is sufficient on its own.

Also see best_practices.md to improve your security setup.

---

# 🔒 Security Guarantees (when correctly deployed)

When deployed according to `BEST_PRACTICES.md` on a properly hardened host system, the application layer provides:

- strict repository isolation per client
- no shell or interactive access for clients
- server-side enforced access control via forced commands
- append-only backup semantics at application level
- no cross-client access via configuration isolation
- minimal external attack surface (SSH only)

---

# ⚠️ Deployment Requirement

hardened-borg-server is NOT a standalone secure system.

It MUST be deployed on a properly hardened host system as described above.

Failure to implement the host layer removes a critical security boundary.

---

# ✨ Features

- 🔒 Security-focused design (minimal attack surface)
- 👥 Multi-client backup support
- 🗂️ Strict repository isolation per client
- 🔁 Mirror/offsite backup ingestion support
- ⚙️ Fully config-driven behavior
- 🧪 Safe testing environment for backup validation
- 📝 Centralized logging in `/log`
- 🚫 No orchestration layer (deterministic execution only)

---

# 🔐 Application Security Model

## Access Control

- SSH key-based authentication only
- Password authentication disabled
- Root login disabled
- Dedicated SSH key per client
- Forced command execution prevents shell access
- Clients restricted to assigned repository paths

---

## SSH Hardening

- Modern cryptographic algorithms only
- Legacy algorithms disabled
- No TTY, X11, forwarding, or tunneling
- Connection limits enforced
- Persistent SSH host keys for stable identity

---

## Repository Isolation

- Each client mapped to a dedicated repository path
- Access enforced via configuration + forced commands
- No cross-repository filesystem access via application layer

---

## Append-Only Semantics

- Backup archives can only be appended
- Deletion/modification of existing archives is prevented via application enforcement
- Historical backups remain immutable via Borg interface

---

## Network Exposure

- No web interface
- No HTTP API
- SSH is the only external interface

---

# 🧱 Architecture Overview

- Base image: `debian:stable-slim` with BorgBackup installed
- Containerized runtime (Podman or Docker recommended)
- Rootless execution strongly recommended
- Systemd-compatible deployment supported

### Storage Model

- Separate volume for repositories
- Separate volume for logs
- Separate volume for configuration

---

## Backup Flows

- Client → Server (SSH / optionally VPN)
- Server → Server (mirror/offsite replication)

---

# 🛠 Deployment Example

```bash
podman run \
  --name=hardened-borg-server \
  --rm \
  --publish=2222:22 \
  --volume=$HOME/containers/borg-server/config:/config:Z \
  --volume=$HOME/containers/borg-server/repo:/repo:Z \
  --volume=$HOME/containers/borg-server/log:/log:Z \
  ghcr.io/raykhoefemann/hardened-borg-server:0.1# hardened-borg-server
