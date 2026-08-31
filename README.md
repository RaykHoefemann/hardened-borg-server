# hardened-borg-server

**Security-hardened BorgBackup server for isolated multi-client backup environments**

A minimal, auditable server wrapper around BorgBackup that receives backups from
multiple clients under strict isolation. Every client is confined to its own
repository, encryption keys never reach the server, and per-client storage
limits are enforced by the host filesystem — not merely tracked. No web UI, no
orchestration, no auxiliary interfaces: a small, predictable, privacy-preserving
attack surface by design.

> **Status:** Current stable release `v1.1.0` — adds scheduled repository
> integrity checking (`borg check`). Upgrading from 0.x is a breaking change
> (client groups removed, Podman Quadlet unit); read the upgrade note in
> [Server Installation](docs/SERVERINSTALL.md). Follow
> [Deployment](docs/DEPLOYMENT.md) for how to run it.

---

## Key properties

- **Privacy by design** — client-side keyfile encryption, *enforced* server-side.
  The server never sees plaintext or keys, and rejects any repo that isn't
  keyfile-encrypted.
- **Strict per-client isolation** — no cross-visibility, no metadata leakage
  between clients.
- **Instances stay separate** — a second instance for a different trust level
  is a real boundary: its own SSH port, its own repository tree, SELinux MCS
  categories between them.
- **Hard per-client quotas** — enforced at the host filesystem level via XFS
  project quotas, independent of application-level tracking.
- **Append-only semantics** — protection against retroactive tampering by a
  compromised client.
- **Point-in-time snapshots** — optional immutable reflink copies of the
  repository volume, restored per client, for host-side damage that
  append-only cannot catch.
- **Confined at runtime** — the container drops all but seven Linux
  capabilities, runs no-new-privileges with a read-only root filesystem, and
  is memory- and PID-capped. Defense-in-depth; nothing else here depends on it.
- **Nothing is ever deleted** — there is no pruning and no retention policy,
  by design: deletion is the one operation that can destroy a backup. Storage
  grows without bound, is capped per client by quota, and is managed by
  monitoring and by adding capacity. **If you need archives to expire — for
  retention rules, compliance, or fixed storage — this project is the wrong
  fit.**
- **Verifiable, not just documented** — the published image carries a build
  provenance attestation, and every guarantee above has a test you can run
  yourself.
- **Fully config-driven** — nothing is provisioned beyond what is explicitly
  declared in `/config`.
- **Minimal, auditable surface** — no orchestration layer, deterministic
  execution, centralized logging.
- **Multi-client + offsite-partner ingestion** — own devices and friends'
  machines back up *into* this server; it is a destination, never a source
  that pushes elsewhere.

---

## Requirements and intended use

This is **not** a plug-and-play backup appliance. The application layer is only
as strong as the host it runs on, so the host stack below is **mandatory**, not
a recommendation:

| Requirement | Why it is required |
|---|---|
| **Fedora CoreOS** (immutable OS) | Reduced, atomic, tamper-resistant base system |
| **SELinux** — enforcing | Mandatory access control; containment of a compromised process |
| **rootless Podman** | Required runtime. Rootless execution is a security boundary of the design; rootful containers and Docker are not supported. |
| **XFS with enforcing `prjquota`** | Hard, filesystem-level per-client quotas — `pqnoenforce` (accounting only) does **not** satisfy this |
| **BorgBackup 1.x on every client** | **BorgBackup 2.x is not supported.** Borg 2 is a separate line with its own repository format; this project is built and tested against 1.x only — see [Supported BorgBackup versions](#supported-borgbackup-versions-1x-only) |

This project intentionally targets a narrow deployment model. If your environment doesn't match these requirements, another Borg-based solution will likely be a better fit.

The guarantees above also depend on work outside the server. Because encryption
keys never reach it, verifying archive integrity (`borg check --verify-data`)
and restore-testing are the **client's** to run at sensible intervals — the
server structurally cannot. [Design](docs/DESIGN.md) Chapter 4.2 collects
everything the operator and the client must each do for the guarantees to hold.

### Supported BorgBackup versions: 1.x only

> **BorgBackup 2.x is NOT supported. Do not use a Borg 2 client against this
> server, and do not point it at a repository on it.**

Supported is **BorgBackup 1.x**, and within that line the versions this project
is actually exercised against: **1.2.x and 1.4.x on the client**, **1.4.x** as
bundled in the image (`tests/wrapper-gating.sh` runs both). Client and server do
not have to be the same version inside 1.x; the evidence base today is both a
1.2.8 and a 1.4.0 client against the image's 1.4.0 server.

Why Borg 2 is excluded: it is a separate line with its own repository format,
and nothing here has been run against it. The server's encryption gate reads the
repository manifest's type byte through Borg's own 1.x segment reader; against a
Borg 2 repository neither that on-disk layout nor the type-byte table can be
assumed to hold, and a Borg 2 client and the image's `borg serve` 1.4 would
first have to agree on a client/server protocol across a major version. The gate
is fail-closed, so the expected outcome is a denial rather than a wrong ALLOW —
but a denial you cannot interpret is not support. Separately, BorgBackup 2.x is
itself still pre-release (beta series `2.0.0bNN`, no `2.0.0` stable tag as of
this writing) — the upstream project itself does not recommend it for
production repositories yet, so supporting it here would not be meaningful
even once the format work above is done.

This section is the authoritative statement of the supported set for the whole
project; [Client Usage](docs/CLIENTUSE.md) and `borg-wrapper.sh` defer to it.
Anything outside it is untested: do not assume it works, and bump the base image
and the tests together when the set changes.

A firewall and/or VPN (e.g. WireGuard) in front of the SSH port is **optional**
defense-in-depth — the application layer is designed to be safely reachable
directly from the internet. See [`BEST_PRACTICES.md`](docs/BEST_PRACTICES.md).

---

## Getting started

There is no meaningful one-line `podman run`. The image needs a populated
`/config` — at minimum `server_info.conf`, which ships in the repo — or it
exits on start, and clients are provisioned by the host scripts rather than
baked into a run command. What a real setup involves — the mandatory host
stack, the config, the first client, and the rootless systemd **user** service
that keeps it running across reboot — is [Server Installation](docs/SERVERINSTALL.md),
end to end. [Deployment](docs/DEPLOYMENT.md) covers the architecture, the
`podman run` shape, and upgrading or rolling back.

> **Before running it anywhere you care about,** verify that the image was
> actually built from this repository — it carries a build provenance
> attestation for exactly that purpose, and checking it needs no container run.
> One command, and it is the check every other guarantee rests on:
> [Verification](docs/VERIFICATION.md), Test 0. A real installation then pins
> the digest that check reports, which is what [Server Installation](docs/SERVERINSTALL.md)
> step 3 does.

---

## Documentation

| Document | What it covers |
|---|---|
| [Test Environment](docs/TESTENV.md) | Try it or rehearse on a throwaway VM — from nothing to a completed verification run |
| [Server Installation](docs/SERVERINSTALL.md) | Step by step from a bare host to a running server with its first client |
| [Client Usage](docs/CLIENTUSE.md) | The client side: repo init, key custody, backups, restores, and what append-only changes for you |
| [Design & Threat Model](docs/DESIGN.md) | The *why*: security, privacy, and data-integrity models — plus scope and residual risk (Chapter 4) |
| [Deployment](docs/DEPLOYMENT.md) | Architecture, `podman run`, the systemd user-service setup, and upgrading or rolling back |
| [Operations](docs/OPERATIONS.md) | `clients.conf`, SSH keys, `server_info.conf`, the info channel, host-management scripts |
| [Snapshots](docs/SNAPSHOTS.md) | Point-in-time snapshots of the storage volume: create, list, delete, restore |
| [Recovery](docs/RECOVERY.md) | Incident handling: accidental deletion, operator error, data loss, restoring data |
| [Verification](docs/VERIFICATION.md) | Test every claimed guarantee against your own installation — don't take them on faith |
| [Best Practices](docs/BEST_PRACTICES.md) | Required operational baseline and defense-in-depth hardening |
| [Roadmap](ROADMAP.md) | What is planned but not yet built: offline export helper, executable verification checks, applying config without a restart |
| [Security Policy](SECURITY.md) | Reporting a vulnerability — including a documented guarantee that turns out not to hold |
| [Contributing](CONTRIBUTING.md) | Issues, pull requests, and the non-goals a change has to stay clear of |

New here and evaluating? Read this page, then
[Design & Threat Model](docs/DESIGN.md) — start with its Chapter 4, which
states in one place what this project does, what it leaves to the operator and
the client, and what it cannot do at all. Want to try it before committing hardware? [Test Environment](docs/TESTENV.md)
gets you to a working setup on a single throwaway VM. Ready to run it for real?
Follow [Server Installation](docs/SERVERINSTALL.md) end to end, then hand
[Client Usage](docs/CLIENTUSE.md) to whoever is being backed up.

---

## License

See [LICENSE](LICENSE).
