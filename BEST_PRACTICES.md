# BEST PRACTICES — hardened-borg-server

This document defines the **required operational baseline** for secure deployments of hardened-borg-server, together with optional additional hardening layers.

Sections are individually marked **MANDATORY**, **RECOMMENDED**, **SHOULD**, or **OPTIONAL** to indicate how critical they are. Only the **MANDATORY** sections are required to achieve the security guarantees described in the README; the rest are defense-in-depth measures operators can add based on their own risk tolerance and resources.

A deployment that does not follow the **MANDATORY** sections MUST be considered insecure.

---

# 🔐 Security Model Context

hardened-borg-server operates as part of a **multi-layer security architecture**:

- Application Layer (this project): access control and repository isolation — provided by the application
- Host Layer (operator responsibility, **mandatory**): OS and container isolation
- Network Perimeter Layer (operator responsibility, **optional**): firewall and VPN access control as an additional hardening measure, on top of an architecture that is already designed to be safely reachable directly from the internet

This document defines the required configuration for the mandatory layers, and example configuration for the optional hardening layers.

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

# 🌐 4. External SSH Access via VPN (OPTIONAL HARDENING)

hardened-borg-server is designed to be safely exposed directly to the internet (see README, Chapter 1) — the application-layer controls (key-only auth, forced commands, no shell access) are built specifically for that threat model and do not depend on a VPN being present.

Restricting SSH access to a VPN-protected network is an **optional additional layer** that further reduces the attack surface and makes it harder for opportunistic attackers or compromised client devices to even reach the SSH port in the first place. It is not required to achieve the security guarantees described in the README.

For deployments that want this extra layer:

- SSH access MAY be restricted to a VPN-protected network
- WireGuard CAN be used as the VPN solution
- SSH MAY only be made reachable after VPN authentication

## Security goal

Where used, this layer reduces internet-wide exposure of the SSH port (e.g. against port scanning and opportunistic brute-force attempts) on top of the existing application-layer protections — it does not replace them.

---

# 🧱 5. Network Perimeter Enforcement (OPNSENSE) (OPTIONAL, ADVANCED)

For operators who choose to add the VPN layer from Chapter 4, a dedicated firewall/gateway MAY be used for additional network access control. This is one more optional, additive layer on top of the application-layer security — not a requirement for a secure deployment.

Example setup:

- OPNsense as primary firewall/router
- WireGuard termination on OPNsense (one possible option)
- SSH port not forwarded to the public internet
- Only the VPN interface may access SSH
- Default-deny inbound firewall policy

## Security rationale

Where implemented, this layer adds protection against:

- internet-wide port scanning
- brute-force attacks on SSH
- unauthorized direct access attempts
- exposure of internal services

It is a defense-in-depth option for operators with the means and requirement for it, not a baseline expectation. Deployments without it are still considered secure as long as the mandatory sections (Chapters 1–3) are followed.

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
- if using the optional VPN/firewall layer (Chapter 4–5): verify firewall and VPN rules, confirm SSH is only reachable as intended

---

# 📌 Security Outcome

A deployment that follows these practices provides:

- Confidential backups (via client-side encryption)
- Strong client isolation (application layer)
- Reduced attack surface (host hardening)
- Optionally, further reduced network exposure (VPN + firewall, if deployed)
- Verified recoverability (restore testing)
- Containment of compromise scenarios (multi-layer isolation)

---

# ⚠️ Non-compliant deployments

Any deployment that does NOT follow the mandatory sections:

- Host Security Baseline
- Backup Encryption
- Secure Transport

must be considered **not security-hardened**, regardless of application configuration.
