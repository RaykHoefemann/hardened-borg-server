# BEST PRACTICES — hardened-borg-server

This document defines the **required operational baseline** for secure deployments of hardened-borg-server.

These practices are not enforced by the application layer itself, but are **mandatory to achieve the security guarantees described in the README**.

A deployment that does not follow these practices MUST be considered insecure.

---

# 🔐 Security Model Context

hardened-borg-server operates as part of a **two-layer security system**:

- Application Layer (this project): access control and repository isolation
- Host Layer (operator responsibility): system-level isolation and containment

This document focuses on the correct configuration of both layers.

---

# 🧱 1. Host Security Baseline (MANDATORY)

A secure deployment requires a hardened host environment.

## Required host characteristics

- Immutable or minimal OS (recommended: Fedora CoreOS)
- SELinux in enforcing mode (or equivalent MAC system)
- Rootless container runtime (recommended: Podman)
- Kernel-level isolation mechanisms enabled (namespaces, cgroups)
- Strict firewall configuration (default deny, only SSH exposed)
- Dedicated storage volumes for:
  - repositories
  - logs
  - configuration

---

## ⚠️ Security rationale

These controls mitigate system-level threats such as:

- container escape or runtime breakout
- privilege escalation to host system
- unauthorized access to other services or data
- persistence outside the application scope

Without these controls, application-level security guarantees are significantly weakened.

---

# 🔐 2. Backup Encryption (MANDATORY)

- Backups MUST be encrypted at the source before transmission.
- Encryption must NOT rely on the server side.

## Why this matters

This ensures that:

- mirrored/offsite backups remain confidential
- a compromised server does not expose backup contents
- trust is not placed on the storage endpoint

---

# 🔗 3. Secure Transport (MANDATORY)

- All communication MUST use SSH
- Password authentication MUST be disabled
- Root login MUST be disabled
- Only required SSH port(s) may be exposed

## Optional (recommended for untrusted networks)

- Use a VPN tunnel (e.g. WireGuard) in addition to SSH

---

# 📝 4. Monitoring & Verification (SHOULD)

- Monitor logs in `/log` regularly
- Run periodic `borg check` integrity validation
- Maintain audit visibility of backup execution

---

# 🧪 5. Restore Testing (SHOULD — CRITICAL OPERATIONAL CONTROL)

- Regular restore tests MUST be performed
- Backup existence alone is not sufficient for reliability
- Restoration procedures must be validated under real conditions

## Why this matters

Backups are only valid if recovery is confirmed.

---

# ⚙️ 6. Operational Hygiene (SHOULD)

- Keep borg-server and base system updated regularly
- Use clear separation of:
  - repositories
  - logs
  - configuration
- Avoid mixing operational and storage concerns

---

# 🧱 7. Deployment Testing (SHOULD)

Before production use:

- Validate client configuration in a test environment
- Simulate restore scenarios
- Verify repository isolation between clients
- Test mirror/offsite workflows

---

# 📌 Security Outcome

A deployment following this baseline provides:

- Confidential backup storage (via encryption at source)
- Strong client isolation
- Reduced attack surface via minimal exposure
- Verified restore capability (operational integrity)
- Containment of system-level compromise via host isolation

---

# ⚠️ Non-compliant deployments

Any deployment that does NOT follow the mandatory sections:

- Host Security Baseline
- Backup Encryption
- Secure Transport

must be considered **not security-hardened**, regardless of application configuration.
