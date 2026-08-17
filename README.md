# hardened-borg-server

**Security-hardened BorgBackup server for isolated multi-client backup environments**

A minimal, auditable server wrapper around BorgBackup that receives backups from
multiple clients under strict isolation. Every client is confined to its own
repository, encryption keys never reach the server, and per-client storage
limits are enforced by the host filesystem — not merely tracked. No web UI, no
orchestration, no auxiliary interfaces: a small, predictable, privacy-preserving
attack surface by design.

> **Status:** Beta. No stable release has been tagged yet — see
> [Deployment](docs/DEPLOYMENT.md) for the current pre-release tags on GHCR.

---

## Key properties

- **Privacy by design** — client-side keyfile encryption, *enforced* server-side.
  The server never sees plaintext or keys, and rejects any repo that isn't
  keyfile-encrypted.
- **Strict per-client isolation** — no cross-visibility, no metadata leakage
  between clients.
- **Hard per-client quotas** — enforced at the host filesystem level via XFS
  project quotas, independent of application-level tracking.
- **Append-only semantics** — protection against retroactive tampering by a
  compromised client.
- **Nothing is ever deleted** — there is no pruning and no retention policy,
  by design: deletion is the one operation that can destroy a backup. Storage
  grows without bound, is capped per client by quota, and is managed by
  monitoring and by adding capacity. **If you need archives to expire — for
  retention rules, compliance, or fixed storage — this project is the wrong
  fit.** See [Operations](docs/OPERATIONS.md) Chapter 10.
- **Verifiable, not just documented** — the published image carries a build
  provenance attestation, and every guarantee above has a test you can run
  yourself. See [Verification](docs/VERIFICATION.md).
- **Fully config-driven** — nothing is provisioned beyond what is explicitly
  declared in `/config`.
- **Minimal, auditable surface** — no orchestration layer, deterministic
  execution, centralized logging.
- **Multi-client + mirror/offsite ingestion** — client→server and
  server→server flows.

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

### Supported BorgBackup versions: 1.x only

> **BorgBackup 2.x is NOT supported. Do not use a Borg 2 client against this
> server, and do not point it at a repository on it.**

Supported is **BorgBackup 1.x**, and within that line the versions this project
is actually exercised against: **1.2.x on the client**, **1.4.x** as bundled in
the image (`tests/wrapper-gating.sh` runs both). Client and server do not have
to be the same version inside 1.x; the evidence base today is a 1.2.8 client
against the image's 1.4.0 server.

Why Borg 2 is excluded: it is a separate line with its own repository format,
and nothing here has been run against it. The server's encryption gate reads the
repository manifest's type byte through Borg's own 1.x segment reader; against a
Borg 2 repository neither that on-disk layout nor the type-byte table can be
assumed to hold, and a Borg 2 client and the image's `borg serve` 1.4 would
first have to agree on a client/server protocol across a major version. The gate
is fail-closed, so the expected outcome is a denial rather than a wrong ALLOW —
but a denial you cannot interpret is not support.

This section is the authoritative statement of the supported set for the whole
project; [Client Usage](docs/CLIENTUSE.md) and `borg-wrapper.sh` defer to it.
Anything outside it is untested: do not assume it works, and bump the base image
and the tests together when the set changes.

A firewall and/or VPN (e.g. WireGuard) in front of the SSH port is **optional**
defense-in-depth — the application layer is designed to be safely reachable
directly from the internet. See [`BEST_PRACTICES.md`](docs/BEST_PRACTICES.md).

---

## Quickstart (container test)

> **Beta:** the `:latest` tag does not exist on GHCR yet. Replace it with a
> current pre-release tag, e.g.
> `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.31`
> ([version list](https://github.com/RaykHoefemann/hardened-borg-server/pkgs/container/hardened-borg-server/versions)).

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

This is fine for testing, but does **not** survive reboot/logout and has no
automatic restart. For production, run it as a rootless systemd **user** service
— see [Deployment](docs/DEPLOYMENT.md).

> **Before running it anywhere you care about,** verify that the image was
> actually built from this repository — it carries a build provenance
> attestation for exactly that purpose. One command, and it is the check every
> other guarantee rests on: [Verification](docs/VERIFICATION.md), Test 0. The
> tag above is fine for the throwaway run; a real installation pins the digest
> that check reports, which is what [Server Installation](docs/SERVERINSTALL.md)
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
| [Recovery](docs/RECOVERY.md) | Incident handling: accidental deletion, operator error, data loss, restoring data |
| [Verification](docs/VERIFICATION.md) | Test every claimed guarantee against your own installation — don't take them on faith |
| [Best Practices](docs/BEST_PRACTICES.md) | Required operational baseline and defense-in-depth hardening |
| [Roadmap](ROADMAP.md) | Mirroring, `borg check`, Quadlet migration, storage snapshots — and why pruning was dropped |
| [Security Policy](SECURITY.md) | Reporting a vulnerability — including a documented guarantee that turns out not to hold |
| [Contributing](CONTRIBUTING.md) | Issues, pull requests, and the non-goals a change has to stay clear of |

New here and evaluating? Read this page, then
[Design & Threat Model](docs/DESIGN.md) — start with its Chapter 4, which
states in one place what this project does, what it leaves to you, and what it
cannot do at all. Want to try it before committing hardware? [Test Environment](docs/TESTENV.md)
gets you to a working setup on a single throwaway VM. Ready to run it for real?
Follow [Server Installation](docs/SERVERINSTALL.md) end to end, then hand
[Client Usage](docs/CLIENTUSE.md) to whoever is being backed up.

---

## License

See [LICENSE](LICENSE).
