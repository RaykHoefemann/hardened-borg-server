> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–4** → Design · **5–6** → Deployment · **7–10** → Operations · **11** → Roadmap.

---

# Design & Threat Model

This document covers the *why* behind hardened-borg-server, organized around its three core focuses — **Security** (Chapter 1), **Privacy** (Chapter 2), and **Data Integrity** (Chapter 3). Deployment, configuration, and operations live in the sibling docs linked above.

**Evaluating whether to run this?** Start with [Chapter 4, Scope & Residual Risk](#4-scope--residual-risk). It states in one place what this project handles, what it hands to you, what is not built yet, and what can never be solved here — then come back for the reasoning.

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
- **XFS as the repository storage filesystem, mounted with enforcing project quotas (`prjquota`, equivalently `pquota`)** — this is what allows per-client storage limits (see `clients.conf`, Chapter 7.1) to be enforced as a hard limit at the filesystem level, rather than merely tracked informationally by the application. The mount must be **enforcing**; the accounting-only variant (`pqnoenforce`) is **not** sufficient, because it neither caps usage nor surfaces per-client usage to the (unprivileged) container. As a useful side effect of enforcing mode, XFS reports each client's quota through `statvfs()`, which is how the `info` channel (Chapter 8) reads live usage without any privileges

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

- **Disk usage of the underlying storage volume** — the `Disk usage:` line of `09-show-all-users.sh` (Chapter 9.5), read directly from the filesystem, independent of any single client's quota.
- **Quota usage of every client** — the same script's per-user `USED` column, read live from each client's enforcing XFS project quota (the same mechanism the client-facing `info` command uses for its own usage, Chapter 8 — but here aggregated for every client at once, for the operator).
- **How long the container has been running** — `systemctl --user status` output (surfaced by `99-container-status.sh`, Chapter 9.11) reports the service's active-since timestamp natively.

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

Logging has two destinations, and they carry deliberately different data.

**`/log` — provisioning and startup.** `entrypoint.log` and `build_authorized_keys.log` record the container's startup sequence and how `authorized_keys` was generated. These entries do reference **client names, groups, repository paths and quotas** — a provisioning log that cannot name what it provisioned is useless for diagnosing a failed client setup. All of it is data that already lives in `clients.conf` on the same host, so this exposes nothing the operator does not already hold.

What `/log` does **not** contain: backup content, archive names, per-backup activity, or client IP addresses. Nothing there records what a client backed up, or when.

**The host journal — SSH connections.** `sshd` runs with `-e` and logs to stderr, which Podman forwards into the systemd journal on the host rather than into `/log`. Those entries include source IP addresses and key fingerprints, as they would for any SSH service. This is host-side only and is never reachable through the client-facing interface (Chapter 1.2.6).

Neither destination records backup *contents* — and that is structural rather than a matter of logging policy: the server never holds a key (Chapter 2.1), so it could not log readable content even if it were configured to try.

## 2.4. Info Channel

The read-only `info` command (see Chapter 8) intentionally exposes only the minimum data necessary:

- **Server:** name, location, contact
- **Software:** the release version of the running image, and the URL of the source repository it was built from
- **Client:** the requesting client's own username, quota, and current storage usage against that quota

The usage figure is the client's own consumption only, derived from its own repository (see Chapter 8). No information about other clients, server internals, or storage contents is ever exposed through this channel.

### Why the version is disclosed deliberately

Announcing a server's software version is conventionally treated as something to avoid. Here it is a considered exception, for three reasons:

- **The source is public anyway.** Withholding the version does not withhold the code; it only makes it harder for the client to know *which* public code is running. That is obscurity purchased entirely at the legitimate user's expense.
- **The channel is authenticated.** Only a client whose key the operator installed can reach it — the same key that already grants a Borg session. It tells an unauthenticated attacker nothing.
- **It is what makes the deployment checkable.** A client can see which release serves it, read that release's source and its notes, and judge whether a fix that matters to it is actually deployed. A project that asks its users to verify rather than believe (see [Verification](VERIFICATION.md)) cannot simultaneously withhold the one fact needed to do so.

The version and source are baked into the image at build time rather than read from operator-editable configuration, so a deployment cannot present itself as a release it is not. Combined with the build provenance attestation on the published image, a client can follow the chain from what it is told, to the release, to the commit it was built from.

---

---

# 3. Data Integrity Model

Alongside security (Chapter 1) and privacy (Chapter 2), the third thing this project focuses on is **data integrity**: the guarantee that a backup, once stored, remains exactly what the client wrote — and that any corruption or tampering is *detectable* rather than silently returned at restore time. A backup that has silently rotted is arguably worse than no backup at all, because it is trusted right up until the moment it is needed.

As with privacy, integrity here is built from several independent layers rather than a single mechanism, and it is bounded by the same client/server trust split: the server can guarantee and verify some things on its own, while the strongest guarantees are anchored on the client side, where the encryption key lives (Chapter 2.1).

> **Note:** this chapter is deliberately an early scaffold. Some of the mechanisms below — in particular proactive `borg check` verification — are still on the roadmap (Chapter 11.3), and this chapter is expected to grow as they land.

## 3.1. Cryptographic Integrity (Borg)

Integrity does not begin at the filesystem — it begins inside Borg. In the enforced keyfile modes (Chapter 2.1.2), every chunk Borg stores is protected by a keyed authentication tag, not merely a plain checksum. Stored data therefore cannot be altered undetectably by anyone who does not hold the client's key — including the server operator, or an attacker who has fully compromised the server. On read, Borg re-verifies these tags, so a modified or corrupted chunk surfaces as an explicit error instead of silently returning wrong bytes.

Because the key never exists on the server (Chapter 2.1), this cryptographic guarantee is anchored on the **client** side: it protects the client against a compromised or faulty server, not just the server against outside tampering.

## 3.2. Immutability Over Time (Append-Only)

Integrity is not only about individual bytes being correct, but about history being preserved. The append-only semantics enforced at the application layer (Chapter 1.2.4) mean existing archives cannot be modified or deleted through a client connection. A compromised client — or a client-side attacker attempting to destroy backup history, e.g. ransomware — therefore cannot rewrite or erase what has already been stored. Existing backups remain intact and verifiable.

## 3.3. Proactive Verification (`borg check`) — Roadmap

Cryptographic tags catch corruption *when data is read*. To catch on-disk corruption (bit rot, a truncated segment, an inconsistent index) *before* it is discovered at restore time, the roadmap adds scheduled, operator-side `borg check` verification (Chapter 11.3).

This is bounded by the same trust split as privacy: the server can run repository-level checks (`borg check --repository-only`) without the key, but deep archive-content verification (`borg check --verify-data`) requires the key and therefore remains a **client-side** responsibility. See Chapter 11.3 for the full design, including how it must respect append-only (repair stays a deliberate operator action) and host-side-only observability.

## 3.4. Integrity of Server-Side Control Files

Beyond the repositories themselves, the server generates control files from configuration — notably `authorized_keys` and each client's `info.txt` (see Chapters 7 and 8). These are written **atomically**: a crash or interruption mid-write cannot leave a half-written, corrupt control file that would break client access or misreport an account. The on-disk state is always either the complete previous version or the complete new version, never a torn mixture of the two.

## 3.5. Scope & Operator Responsibility

As with the host security layer (Chapter 1.1), some parts of integrity live below this application and are the operator's responsibility:

- The storage filesystem (XFS) protects its own metadata with CRCs but does **not** checksum file *data* blocks. Detection of data-block corruption therefore relies on Borg's per-chunk authentication and on `borg check` (3.1, 3.3), not on the filesystem itself.
- Protection against physical media failure — redundancy, scrubbing, replacing failing disks — is a host/storage concern (e.g. RAID and disk monitoring), outside this project's scope in the same way host hardening is (Chapter 1.1). This application makes corruption *detectable*; keeping a second copy so that detected corruption is also *recoverable* is what the offsite mirroring roadmap item (Chapter 11.2) and the operator's own storage design are for.

---

---

# 4. Scope & Residual Risk

Chapters 1–3 describe what this project does and why. This chapter states, in one place, **what it does not do** — what it hands to the operator, what is not built yet, and what can never be solved here at all.

It exists because those boundaries are otherwise scattered across five documents, and scattered honesty reads like hidden honesty. An evaluator should be able to see the full picture without assembling it. Where a property is verifiable, the relevant test in [Verification](VERIFICATION.md) is named — nothing in the first table should be taken on trust.

## 4.1. Handled by this project

| Threat | Mechanism | Verify |
|---|---|---|
| Compromised client deletes archives | Append-only, applied unconditionally to every connection (1.2.4) | Test 9 |
| Compromised client destroys the whole repository | Same | Test 10 |
| Client obtains a shell or runs arbitrary commands | Forced command + `restrict`, default-deny gating (1.2.1) | Tests 1, 2 |
| Client reads another client's data or metadata | Fixed per-key repo path + `--restrict-to-path` (1.2.3, 2.2) | Test 7 |
| Operator or server-side attacker reads backup contents | Client-held keyfile encryption, enforced at connection time (2.1.2) | Tests 6, 8 |
| One client exhausts storage for the others | Enforcing XFS project quota (1.1.3) | Test 5 |
| Undetected modification of stored data | Borg per-chunk authentication tags, verified on read (3.1) | — |
| Password guessing, credential reuse | Key-only SSH; passwords and root login disabled (1.2.1) | Test 1 |

The residual risk across this entire table is the same single point: every one of these properties depends on the client's key being bound to the forced command. One `authorized_keys` line without it voids all of them simultaneously, and nothing else in the system would look wrong. That is why Test 3 exists.

## 4.2. Handed to the operator

This project provides **no host-level security whatsoever** (1.1). These are not shared responsibilities — they are entirely yours, and the application's guarantees inherit their weaknesses:

| Concern | Who handles it |
|---|---|
| Container escape, privilege escalation to host | Rootless Podman, SELinux enforcing, immutable OS — operator |
| Physical media failure, bit rot at the device level | RAID, scrubbing, disk monitoring — operator (3.5) |
| Storage capacity over time | Quota sizing and monitoring — operator ([Operations](OPERATIONS.md) 10) |
| Backing up the server's own configuration | Operator ([Operations](OPERATIONS.md) 7.5) |
| Network exposure of the SSH port | Optional firewall/VPN; the application is designed to be safely exposed without one (1.1.3) |

## 4.3. Not built yet

Documented as roadmap items, and **absent today**. A deployment must be planned as though they do not exist, because they do not:

| Gap | Consequence today | Item |
|---|---|---|
| No offsite replication | Site loss, or loss of the storage volume, means total loss | 11.2 |
| No snapshots of the storage volume | Operator error against the repositories has no local recovery path | 11.5 |
| No scheduled integrity verification | On-disk corruption is detected when data is read, not before | 11.3 |

Deliberately **not** on this list because it will not be built: automated pruning (11.1). Nothing is ever deleted; capacity is bounded by quotas and managed by monitoring instead ([Operations](OPERATIONS.md) 10).

## 4.4. Cannot be solved here

Not gaps, and not roadmap items. These follow from the design and would require giving up the properties in 4.1 to change:

| Situation | Why nothing can be done |
|---|---|
| Client loses its key or passphrase | No key material, escrow or recovery path exists server-side — that absence *is* the privacy guarantee (2.1.1) |
| Attacker holds root on the host | Nothing hosted on a system defends it against its own root. The answer is a copy the machine cannot reach, i.e. an append-only offsite target (11.2) |
| Metadata visible to the server | Repository sizes, backup timing and client names are necessarily known to the server. Only *contents* are protected |
| Space stranded by failed backups | Append-only forbids reclaiming uncommitted segments; raising the quota does not recover them ([Operations](OPERATIONS.md) 10.4) |

## 4.5. How to read this chapter

If you are evaluating whether to run this: 4.1 is what you get, 4.2 is what you must build yourself, 4.3 is what you must plan around, and 4.4 is what you must accept.

A deployment that satisfies 4.1 but not 4.2 is not secure — the application layer alone was never sufficient (1.3). A deployment that satisfies both but ignores 4.3 is secure and will still lose everything to a failed disk.

---
