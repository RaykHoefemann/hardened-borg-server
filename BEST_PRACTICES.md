# BEST PRACTICES — hardened-borg-server

This document defines the **required operational baseline** for secure deployments of hardened-borg-server.

These practices are not enforced by the application layer itself, but are **mandatory to achieve the security guarantees described in the README**.

A deployment that does not follow these practices MUST be considered insecure.

---

# 🔐 Security Model Context

hardened-borg-server operates as part of a **multi-layer security architecture**:

- Application Layer (this project): access control and repository isolation
- Host Layer (operator responsibility): OS and container isolation
- Network Perimeter Layer (operator responsibility): firewall and VPN access control

This document defines the required configuration for all layers.

---

# 🧱 1. Host Security Baseline (MANDATORY)

A secure deployment requires a hardened host environment.

## Required host characteristics

- Immutable or minimal OS (recommended: Fedora CoreOS)
- SELinux in enforcing mode (or equivalent MAC system)
- Rootless container runtime (recommended: Podman)
- Kernel-level isolation mechanisms enabled (namespaces, cgroups)
- Dedicated storage volumes for:
  - repositories
  - logs
  - configuration
- Strict local privilege separation

---

## ⚠️ Security rationale

These controls mitigate system-level threats such as:

- container escape or runtime breakout
- privilege escalation to host system
- unauthorized access to other services or data
- persistence outside the application scope

Without these controls, application-level security guarantees are significantly reduced.

---

# 🔐 2. Backup Encryption (MANDATORY)

- Backups MUST be encrypted at the source before transmission.
- Encryption MUST NOT depend on the server.

## Why this matters

- protects confidentiality even if the server is compromised
- prevents exposure of data in mirror/offsite setups
- ensures trust is not placed on storage infrastructure

---

# 🔗 3. Secure Transport (MANDATORY)

- All communication MUST use SSH
- Password authentication MUST be disabled
- Root login MUST be disabled
- Only required SSH port(s) may be exposed

SSH is the only application-layer transport mechanism.

---

# 🌐 4. External SSH Access (VPN-RESTRICTED) (RECOMMENDED)

When access from external networks is required, SSH MUST NOT be exposed directly to the internet.

Instead:

- SSH access MUST be restricted to a VPN-protected network
- WireGuard SHOULD be used as the VPN solution
- SSH MUST only be reachable after VPN authentication

## Security goal

SSH is never directly exposed to untrusted networks.

---

# 🧱 5. Network Perimeter Enforcement (OPNSENSE) (ADVANCED REQUIREMENT)

A dedicated firewall/gateway SHOULD be used for external access control.

Recommended setup:

- OPNsense as primary firewall/router
- WireGuard termination on OPNsense (preferred)
- SSH port NOT forwarded to public internet
- Only VPN interface may access SSH
- Default-deny inbound firewall policy

## Security rationale

This layer protects against:

- internet-wide port scanning
- brute-force attacks on SSH
- unauthorized direct access attempts
- exposure of internal services

It enforces a strict network boundary in front of the system.

---

# 📝 6. Monitoring & Verification (SHOULD)

- Monitor logs in `/log` regularly
- Run periodic `borg check` integrity validation
- Audit backup execution behavior
- Ensure backups are actually being created and not silently failing

---

# 🧪 7. Restore Testing (SHOULD — CRITICAL)

- Regular restore tests MUST be performed
- Backups are only valid if restoration works
- Test recovery under realistic conditions

---

# ⚙️ 8. Operational Hygiene (SHOULD)

- Keep borg-server and base system updated
- Separate clearly:
  - repositories
  - logs
  - configuration
- Avoid mixing operational and storage concerns
- Use consistent and documented client configurations

---

# 🧱 9. Deployment Validation (SHOULD)

Before production deployment:

- validate client isolation in test environment
- simulate restore scenarios
- test mirror/offsite replication
- verify firewall and VPN rules
- confirm SSH is not publicly exposed

---

# 📌 Security Outcome

A deployment that follows these practices provides:

- Confidential backups (via client-side encryption)
- Strong client isolation (application layer)
- Reduced attack surface (host hardening)
- Controlled network exposure (VPN + firewall)
- Verified recoverability (restore testing)
- Containment of compromise scenarios (multi-layer isolation)

---

# ⚠️ Non-compliant deployments

Any deployment that does NOT follow the mandatory sections:

- Host Security Baseline
- Backup Encryption
- Secure Transport

must be considered **not security-hardened**, regardless of application configuration.
