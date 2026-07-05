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
- Repository storage on **XFS mounted with enforcing project quotas (`prjquota`)** — mandatory; the accounting-only variant `pqnoenforce` is **not** sufficient. Enforcing mode caps each client's storage as a hard filesystem limit and, as a side effect, surfaces live per-client usage to the unprivileged container via `statvfs()` (see README, Chapters 1.1.3 and 7)
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

- Backups MUST be encrypted on the client, before any data leaves the client machine.
- Encryption MUST use a **client-held keyfile** mode: `keyfile-blake2` (recommended) or `keyfile`. Initialize repositories with:

  ```bash
  borg init --encryption=keyfile-blake2 <repo-url>
  ```

  where `<repo-url>` is the client's assigned repository, e.g. `ssh://borg@<server-host>:2222/<assigned-repo-path>`.

- The key MUST NOT be stored on the server. Server-side or plaintext modes are **forbidden**: `repokey`/`repokey-blake2` (store the passphrase-wrapped key inside the repository on the server), `authenticated`/`authenticated-blake2` (store data in plaintext, integrity-protected only), and `none` (unencrypted).

The server **enforces** this: it verifies the encryption mode of every repository on each connection and rejects anything other than a keyfile mode before the Borg session starts (see README, Chapter 2.1.2). This makes the guarantee structural rather than a matter of client discipline — but clients must still initialize their repositories correctly, or the first real backup will be refused.

## Why this matters

- protects confidentiality even if the server is fully compromised — with keyfile mode there is no key material on the server to steal or brute-force
- rules out `repokey`, whose passphrase-wrapped key lives in the repository and would be offline-crackable after a server breach
- prevents exposure of data in mirror/offsite setups
- ensures trust is not placed on storage infrastructure

## 2.1. Key Custody & Recovery (MANDATORY)

Keyfile encryption moves the entire burden of key custody to the client. The server has **no** master key, escrow, or recovery path — by design (see README, Chapter 2.1.1). **If a client loses its key, the corresponding backups are permanently and irrecoverably lost.**

Therefore, for every client:

- Export the repository key and store it **offline, separately from the client machine**:

  ```bash
  borg key export <repo-url> /secure/offline/<client>.borgkey
  ```

- Retain the repository **passphrase** as well: in keyfile mode the exported key is itself passphrase-protected, and both the key file and the passphrase are required to access the repository. Store the passphrase independently of the key export.
- Keep these in at least one location that is independent of the machine being backed up (e.g. a password manager with its own backup, a hardware security device, or a physically secured offline copy).
- Never keep the only copy of the key on the machine it protects — if that machine is lost, so is the key, and with it the backup.
- Treat key loss as equivalent in severity to total data loss.

This step is **not optional**: a correctly encrypted backup whose key has been lost is indistinguishable from no backup at all.

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
- Verify quota enforcement is active: `ssh -p 2222 borg@<server-host> info` must report the client's own limit (e.g. `of 50.0 GiB`), not the size of the whole underlying disk. A whole-disk figure indicates the repository mount is missing enforcing `prjquota` (see README, Chapter 7) — meaning per-client hard limits are not in effect

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

- Confidential backups (via enforced client-held keyfile encryption; server holds no keys)
- Strong client isolation (application layer)
- Hard, filesystem-enforced per-client storage limits (enforcing XFS project quotas)
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
