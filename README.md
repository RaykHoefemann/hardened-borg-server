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

This project intentionally targets a narrow deployment model. If your environment doesn't match these requirements, another Borg-based solution will likely be a better fit.

A firewall and/or VPN (e.g. WireGuard) in front of the SSH port is **optional**
defense-in-depth — the application layer is designed to be safely reachable
directly from the internet. See [`BEST_PRACTICES.md`](docs/BEST_PRACTICES.md).

---

## Quickstart (container test)

> **Beta:** the `:latest` tag does not exist on GHCR yet. Replace it with a
> current pre-release tag, e.g.
> `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.8`
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

---

## Documentation

| Document | What it covers |
|---|---|
| [Design & Threat Model](docs/DESIGN.md) | The *why*: security, privacy, and data-integrity models (the deep dive) |
| [Deployment](docs/DEPLOYMENT.md) | Architecture, `podman run`, and the systemd user-service setup |
| [Operations](docs/OPERATIONS.md) | `clients.conf`, SSH keys, `server_info.conf`, the info channel, host-management scripts |
| [Best Practices](docs/BEST_PRACTICES.md) | Required operational baseline and defense-in-depth hardening |
| [Roadmap](ROADMAP.md) | Pruning, mirroring, `borg check`, Quadlet migration |

New here and evaluating? Read this page, then
[Design & Threat Model](docs/DESIGN.md). Ready to run it? Go straight to
[Deployment](docs/DEPLOYMENT.md).

---

## License

See [LICENSE](LICENSE).
