> **Docs:** [Overview](README.md) · [Design & Threat Model](docs/DESIGN.md) · [Deployment](docs/DEPLOYMENT.md) · [Operations](docs/OPERATIONS.md) · [Best Practices](BEST_PRACTICES.md) · [Roadmap](ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–3** → Design · **5–6** → Deployment · **7–9** → Operations · **11** → Roadmap.

---

# 11. Roadmap

Planned features, not yet implemented. Listed here for visibility; timelines are not committed.

## 11.1. Automated Archive Pruning

Automated, operator-configurable retention policies (e.g. "keep 7 daily, 4 weekly, 6 monthly" per client), so old archives are cleaned up without a manual `borg prune` run.

This needs to be reconciled carefully with the append-only enforcement described in Chapter 1.2.4: today, deletion is intentionally something a client cannot trigger. Automated pruning will need to be a distinct, deliberate server/operator-side mechanism — not a relaxation of what a client connection is allowed to do — so the existing append-only guarantee is not weakened by this feature.

## 11.2. Mirroring Own Repositories to a Foreign Backup Server

The ability for this server to push/replicate the repositories it hosts to a **different, external backup server** for offsite redundancy — the reverse direction of the existing `MIRROR` client group (Chapter 7.1), which is about *receiving* backups from external/friend clients, not sending this server's own hosted data elsewhere.

This replication is planned as an **exact 1:1 copy** of the repository — a full, byte-for-byte replica, not a selective or filtered transfer. There is no point in this pipeline where the server can inspect, redact, or otherwise limit what the foreign server receives: it gets literally the same repository this server holds.

This makes client-side encryption not just a good idea but an absolute precondition for this feature: the foreign backup server is, by definition, outside this project's trust boundary — a third party whose own security this project has no control over. The entire confidentiality of the mirrored copy depends on the client having already encrypted every archive with a client-held key **before** it ever reached this server in the first place. As with any repository handled by this project, the client-held keyfile encryption model (Chapter 2.1.2) is expected to carry over unchanged: a mirrored copy remains only as readable as the original — the encryption key stays with whoever holds it today, not with either server. An unencrypted repository must never be mirrored this way, since doing so would hand the foreign server a complete, plaintext copy of everything.

## 11.3. Automated Integrity Verification (`borg check`)

Scheduled, operator-side integrity checking of the hosted repositories via `borg check`, so that silent on-disk corruption (bit rot, a truncated segment, an inconsistent index) is detected proactively rather than discovered at restore time.

The privacy model (Chapter 2.1) directly shapes what this feature can and cannot do — this is the central design constraint, not an afterthought:

- **Repository-level checks (`borg check --repository-only`) are possible server-side.** They validate the repository's own structures — segment files, hashes, index/manifest consistency — without decrypting any archive contents, and therefore need no encryption key. This is exactly the class of damage the server is in a position to detect, and where automated server-side checking genuinely adds value.
- **Archive-data verification (`borg check --verify-data`, and the archive-consistency portion of a full check) is *not* possible server-side.** Reading archive metadata and re-verifying chunk contents requires the repository key, which by design never exists on the server (Chapter 2.1). Deep, content-level verification therefore remains a **client-side responsibility**, carried out by whoever holds the key — the server cannot, and must not be able to, perform it.

Two existing guarantees must be preserved when this lands:

- **Append-only (Chapter 1.2.4):** `borg check` has a `--repair` mode that *modifies* the repository. As with automated pruning (11.1), repair must never be reachable from a client connection and must be a distinct, deliberate operator-side action. The scheduled check itself runs strictly read-only; repair stays manual.
- **Host-side-only observability (Chapter 1.2.6):** results surface to the operator on the host (log output and exit status, e.g. driven by a systemd timer), not through a new client-facing interface or port. Whether a "last checked" timestamp is later surfaced to clients through the existing `info` channel (Chapter 8) is a separate, deliberate decision — doing so would widen what that channel reports and is intentionally out of scope for the first iteration.

Practical considerations: `borg check` is I/O-intensive, so scheduling must avoid colliding with active backup windows, and each per-repository check should run under the same isolation the rest of the server uses.

## 11.4. Migration from a hand-written systemd unit to Podman Quadlets

Replacing the current hand-written systemd unit **template** + generated `EnvironmentFile` (Chapter 6.2) with a declarative **Podman Quadlet** — a `.container` file under `~/.config/containers/systemd/`, from which `podman-systemd.generator` produces the actual service unit automatically. This direction is already noted in Chapter 6.2.4 as the recommended long-term approach; this roadmap item is about making it the default deployment path rather than an alternative mentioned in a footnote.

Motivation:

- **More robust lifecycle handling.** Quadlets manage container creation and removal natively, which removes the fragile `--rm` + fixed `--name` + `Restart=on-failure` interaction described in 5.2.4 (the "name already in use" failure after an unclean stop) without needing the `--replace` workaround.
- **Less bespoke plumbing.** The declarative `.container` file replaces the template-rendering + `EnvironmentFile` machinery, simplifying `scripts/50-service-install.sh` and shrinking the amount of hand-maintained systemd glue.

Constraints to preserve:

- **`config.sh` stays the single source of truth (Chapter 9.1).** The `.container` file must still derive its values (`IMAGE`, `SSH_PORT`, the `HOST_*_BASE` bind mounts, `CONTAINER`) from `config.sh`, exactly as the current unit does — most plausibly by having `50-service-install.sh` render the `.container` from `config.sh` the same way it renders the `.service` today. The migration must not reintroduce hardcoded values into a checked-in unit.
- **Rootless user service + lingering stay unchanged (Chapters 6.2.1, 6.2.3).** A Quadlet under `~/.config/containers/systemd/` is still a rootless *user* service and still relies on `loginctl enable-linger` to survive logout and reboot. None of the rootless-operation guarantees from Chapter 1.1 change.

This is a **deployment/lifecycle change only** — it does not alter client-facing behavior, the security model (Chapter 1), or the privacy model (Chapter 2). Existing deployments on the current `.service` unit continue to work; the Quadlet becomes the recommended path for new installations.
