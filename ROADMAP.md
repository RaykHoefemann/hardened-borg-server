> **Docs:** [Overview](README.md) · [Design & Threat Model](docs/DESIGN.md) · [Deployment](docs/DEPLOYMENT.md) · [Operations](docs/OPERATIONS.md) · [Recovery](docs/RECOVERY.md) · [Verification](docs/VERIFICATION.md) · [Best Practices](docs/BEST_PRACTICES.md) · [Roadmap](ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–4** → Design · **5–6** → Deployment · **7–10** → Operations · **11** → Roadmap.

---

# 11. Roadmap

What is still planned and not yet built. Timelines are not committed.

Numbers are stable — nothing is renumbered when an item resolves. A **dropped** feature (11.1, and the foreign-mirroring half of 11.2) keeps its full section as a tombstone, so the decision and its reasoning stay visible. A **shipped** feature (11.4, 11.5, 11.8) is cut down to a one-paragraph pointer into the docs that now carry it — the design history is in git.

## 11.1. Automated Archive Pruning — dropped

Previously planned: operator-configurable retention policies (e.g. "keep 7 daily, 4 weekly, 6 monthly" per client), so old archives would be cleaned up without a manual `borg prune` run.

**This is no longer a goal.** The entry is kept rather than deleted so that the decision is on record and the chapter numbering stays stable.

The reasoning is the one this project applies everywhere else: deletion is the single operation that can destroy a backup, and an automated retention mechanism would perform it regularly, unattended, against repositories whose contents the server cannot read and cannot verify afterwards. Its failure mode is silent and irreversible. Weighed against unbounded storage growth — which is visible, gradual, and answerable by adding a disk — the trade is not close.

The consequence is deliberate, and is documented as normal operation rather than as a gap: nothing is ever deleted, consumption is bounded by per-client quotas instead of retention policies, and capacity is managed by monitoring and by raising limits. See [Operations](docs/OPERATIONS.md) Chapter 10.

What this does **not** rule out is a **manual, operator-side** reclamation tool for exceptional situations. Space stranded by repeatedly failed backups (Operations, Chapter 10.4) currently has no answer other than the transaction rollback in [Recovery](docs/RECOVERY.md) Section 1, which is designed for accidents rather than for cleanup. Any such tool would be a deliberate, attended action — never a schedule, and never reachable from a client connection.

## 11.2. Replicating Own Repositories Off-Server — foreign-server mirroring dropped; manual offline export planned

Two things have lived under this number. The first — this server replicating its hosted repositories to a **different, external backup server** for live offsite redundancy — was planned and is now **dropped**. The entry is kept, as 11.1 is, so the decision and its reasoning stay on record. What replaces it is smaller and stays inside the trust boundary: a **manual, operator-side helper for copying repositories onto removable media**.

### Why foreign-server mirroring is dropped

The feature only meant something if the foreign server enforced append-only against this one. An offsite copy that accepts deletions is not a second copy in any meaningful sense: an attacker with root here inherits whatever replication credentials this server holds, so if those credentials permit deletion, one compromise destroys the local data and the remote copy in the same session. That requirement cannot be met inside this project's model:

- **This server holds no repository key** (Chapter 2.1.2). The only replication mechanism available to it is a file-level copy of the opaque repository directory — `rsync`/`rclone`, never the Borg protocol, because every archive-moving Borg operation (`borg create`, `borg transfer` in Borg 2.x) must open the manifest and needs the key. This is not a limitation a newer Borg lifts; it follows from the key never being on the server. `borg serve --append-only` is therefore never in the path — "the foreign side enforces append-only" could only mean a pull-based fetch, or filesystem-level immutability and versioning on the remote.
- **rsync has no append-only mode.** `rrsync -no-del` blocks `--delete` and `--remove*`, but nothing stops a hostile or buggy sender from overwriting existing files in place, and `rrsync` can filter client options off but cannot force `--ignore-existing` on. Borg's committed segments are frozen by the protocol; rsynced files are not.
- Closing that gap means trusting the foreign operator's storage layer — remote snapshots, ZFS/btrfs, WORM — which is exactly the third-party integrity this project declines to assume. An unverified remote is a copy that happens to be far away, not an offsite backup.
- The same reasoning runs backwards, so **this project does not offer an inbound rsync mirror endpoint to third parties either.** It could not be locked down to the standard `borg serve` meets — rsync is a large C codebase with a running CVE history, against a narrow purpose-built protocol — and offering it would undercut the standard the rest of the server holds to.

**Offsite redundancy is therefore delegated to the client.** Only the client holds the key, so only the client can make a second, genuinely independent copy: another `borg create` target, or `borg serve` against a foreign server *the client* trusts. This is documented as a client recommendation ([Client Use](docs/CLIENTUSE.md), [Best Practices](docs/BEST_PRACTICES.md)), not built as a server feature. Receiving backups from external clients is the one adjacent thing this server does safely — over the same forced-command `borg serve` path every other client uses.

The append-only verification procedure this entry used to carry (probe archive, `borg delete` + `borg compact`, then measure whether physical space is reclaimed — the only signal that discriminates, since Borg refuses nothing and warns nothing) is still useful to a client setting up its own offsite target, and now lives in [Client Use](docs/CLIENTUSE.md) Chapter 9.

### What replaces it: a manual offline export helper

A host-side script that copies the hosted repositories — `HOST_REPO_BASE/` — onto a mounted block device (`rsync -a --delete`), for an air-gapped copy the operator physically disconnects and can store elsewhere. This stays inside the project's trust boundary — the operator's own disk, in the operator's hands — so the append-only problem above does not apply: the immutability is physical (the medium is unplugged), not a protocol property. It is the "offline" half of the offline/offsite split; the "offsite" half is the client's job, above.

Scope and constraints:

- **Which repositories to export is an operator choice.** A repository holding an external partner's own backups is one this server is already the offsite copy *of* — its source data lives with that partner, and it is not the operator's data to carry offsite. With client groups gone (1.0.0), the helper cannot tell those apart from a name, so the sweep set is either "everything under `HOST_REPO_BASE`" or an explicit allow/deny list the operator maintains. (Snapshots, 11.5, are unaffected — they cover every client, because they cost nothing and never leave the host.)
- **Manual and attended.** No timer, no schedule, no client-facing surface — the category of `99-container-status.sh`. Nothing about it is reachable from a client connection (Chapter 1.2.6).
- **The copy is ciphertext.** A keyfile-mode repository copied this way cannot be restored without the client's exported key and passphrase (Chapter 2.1.1), which exist only on the client. The helper produces half of a usable offline backup; the client-side key archive ([Best Practices](docs/BEST_PRACTICES.md) Chapter 2.1) is the other half. The server cannot hold that half without becoming the key escrow the same chapter rules out.
- **Not against a live repository.** Run it in an idle window, or from a storage snapshot (11.5). Borg repositories are transactional — a copy taken mid-commit rolls back to the last committed transaction on next access rather than tearing — but a coordinated quiet window is cleaner still.
- **`borg check --repository-only` on the copy** validates it structurally without a key, exactly as for the primary (11.3).
- **Destination-agnostic, but only removable media is supported.** The same `rsync` invocation can point anywhere the operator can write. Doing so is the operator's own decision and carries every caveat above; it is not a mirroring feature and is not documented as one.

## 11.3. Automated Integrity Verification (`borg check`)

Scheduled, operator-side integrity checking of the hosted repositories via `borg check`, so that silent on-disk corruption (bit rot, a truncated segment, an inconsistent index) is detected proactively rather than discovered at restore time.

The privacy model (Chapter 2.1) directly shapes what this feature can and cannot do — this is the central design constraint, not an afterthought:

- **Repository-level checks (`borg check --repository-only`) are possible server-side.** They validate the repository's own structures — segment files, hashes, index/manifest consistency — without decrypting any archive contents, and therefore need no encryption key. This is exactly the class of damage the server is in a position to detect, and where automated server-side checking genuinely adds value.
- **Archive-data verification (`borg check --verify-data`, and the archive-consistency portion of a full check) is *not* possible server-side.** Reading archive metadata and re-verifying chunk contents requires the repository key, which by design never exists on the server (Chapter 2.1). Deep, content-level verification therefore remains a **client-side responsibility**, carried out by whoever holds the key — the server cannot, and must not be able to, perform it.

Two existing guarantees must be preserved when this lands:

- **Append-only (Chapter 1.2.4):** `borg check` has a `--repair` mode that *modifies* the repository. Repair must never be reachable from a client connection and must be a distinct, deliberate operator-side action. The scheduled check itself runs strictly read-only; repair stays manual.
- **Host-side-only observability (Chapter 1.2.6):** results surface to the operator on the host (log output and exit status, e.g. driven by a systemd timer), not through a new client-facing interface or port. Whether a "last checked" timestamp is later surfaced to clients through the existing `info` channel (Chapter 8) is a separate, deliberate decision — doing so would widen what that channel reports and is intentionally out of scope for the first iteration.

Practical considerations: `borg check` is I/O-intensive, so scheduling must avoid colliding with active backup windows, and each per-repository check should run under the same isolation the rest of the server uses.

## 11.4. Migration from a hand-written systemd unit to Podman Quadlets — done

Shipped in 1.0.0. The hand-written unit template + generated `EnvironmentFile` is now a checked-in Podman Quadlet `systemd/borg-server.container` plus a `<CONTAINER>.container.d/10-deployment.conf` drop-in that `scripts/50-service-install.sh` renders from `config.sh`; `podman-system-generator` produces `<CONTAINER>.service` on `daemon-reload` (needs podman ≥ 5.0). Container hardening landed with it, in its own commit: `NoNewPrivileges=true`, `DropCapability=all` + seven annotated caps, `ReadOnly=true` + three `tmpfs`, `PidsLimit=128`, `Memory=512m` — determined empirically against the shipped image, defence in depth beyond what Chapter 1.1 requires (no Chapter 1 guarantee depends on it). Deployment/lifecycle change only — client-facing behaviour and the security/privacy models (Chapters 1, 2) are unchanged. See [Deployment](docs/DEPLOYMENT.md) Chapter 6.2 (6.2.4 for running more than one instance, 6.3 for the one-time migration step) and the header of `systemd/borg-server.container` for the per-cap rationale. Verified: [Verification](docs/VERIFICATION.md) checks 4A–4C and section 12.

## 11.5. Point-in-Time Snapshots of the Storage Volume — done

Shipped as `snapshots/70-create-snapshot.sh` (plus the `71-`/`72-`/`79-` timer scripts), `75-list-snapshots.sh`, `76-delete-snapshots.sh`, `77-restore-last-snapshot.sh`, and `scripts/04-reattach-client.sh` for reconnecting `clients.conf` after a `HOST_REPO_BASE`-only restore. Reflink point-in-time copies of `HOST_REPO_BASE`, made immutable (`chattr +i`), with a client-scoped restore — closing the one gap append-only cannot: destruction originating host-side rather than over a client connection. Not a second copy, and not a substitute for an offsite copy (client-side, see 11.2). See [Snapshots](docs/SNAPSHOTS.md) and [Verification](docs/VERIFICATION.md) Test 11.

## 11.6. Executable Verification Checks

A runner that performs the host-side checks of [Verification](docs/VERIFICATION.md) as code — `tests/verify.sh 5B`, or all of them at once — so that an operator or a security researcher can obtain a machine-readable result without transcribing twenty-four commands by hand.

This became possible rather than merely desirable when the page moved to one criterion per check: `0A`–`0C`, `1.5A`–`1.5C`, `3A`, `3B`, `4A`–`4C`, `5A`, `5B` and `5.5A` each now name exactly one thing, have exactly one measurement, and have exactly one repair. A script per check is a transcription of that structure, not a reinterpretation of it.

Scope is deliberately the **host side** only. The remaining checks — `0.5A`, `0.5B`, `1`, `2`, `5.5B`, `6`'s namespace entry, `7`, `8`, `9`, `10` — run from a client machine holding a provisioned key, write throwaway data into a real repository, and in the case of `9` leave roughly a megabyte behind permanently. Driving those from the host would mean the server holding a client key, which contradicts Chapter 2.1 outright. They stay manual, and the runner should say so rather than silently reporting a partial pass as a whole one.

Constraints to preserve:

- **The measurement is the output, not a verdict.** Every defect reported against the verification page so far has been a criterion that reached further than the command under it (#17, #18, #20, #23, #24) — never a command that ran wrongly. A runner that prints `5B PASS` and nothing else would have reproduced all five faults in a form nobody could inspect. Each check prints what it measured alongside its verdict, so that a wrong criterion stays visible instead of being compressed into a green line.
- **Read-only, and no credentials.** Nothing in scope modifies the deployment, and `0A` needs no registry credential of any kind (the page says why, and an unusable stored one is enough to stop it). `5B` is the only check needing `sudo`, for `xfs_quota`; the runner must degrade to reporting that it could not measure, rather than skipping the check silently.
- **The page stays the source of truth.** A script that drifts from the documented command is worse than no script: it certifies something other than what a reader was told is being certified. This is the same failure `tests/doc-image-tags.sh` exists to prevent for release identifiers, and it wants the same treatment — a check in CI asserting that every check id in `VERIFICATION.md` has an implementation and every implementation has a documented id.
- **It does not replace the manual run, and must not read as if it does.** The page's own status markers distinguish a check that passes on a correct deployment from one shown to fail on a broken one; a runner inherits that distinction and cannot resolve it. The `⚠️` marks stay attached to the checks, not to the runner's exit status.
- **Not a service.** No timer, no scheduling, no client-facing surface, no result reported through the `info` channel. This is a tool an operator invokes deliberately, in the same category as `99-container-status.sh`.

The natural output format is one line per check — id, verdict, measured value — plus a non-zero exit status if any check failed, so a report pasted into an issue carries the evidence with it. That is how every defect on this page has arrived so far, and the format should make it easier rather than harder.

## 11.7. Applying Configuration Without Restarting the Container

Every routine configuration change — a client added, a key set or replaced, a client removed, a quota changed — is published by exactly one mechanism: `build_authorized_keys.sh`, run by `entrypoint.sh` at container start. There is no second trigger, so `92-container-restart.sh` is the only way to apply anything, and `00`, `01` and `02` each end by naming it ([Operations](docs/OPERATIONS.md) Chapters 9.2–9.4).

The unit uses `--rm`, so that is not a reload but a teardown: `podman stop` ends every SSH session at once, a `borg create` in progress included. Under append-only an interrupted run is more than a failed transfer — the segments it already wrote stay on disk uncommitted, `borg compact` is not part of this server's operation, and that space is consumed permanently (Chapter 10.4). **Adding a line to `clients.conf` therefore has an unbounded, unreclaimable cost for whoever happened to be backing up at that moment.** For a server whose central promise is that nothing is ever deleted, the routine administrative act should not be the one operation that strands storage.

**It is mechanically possible today, with the pieces already in the image.**

- The generator is written for a live re-run. It renders each info text to `.tmp` and `mv`s it into place precisely because, in a live container, "an `info` request may read the file at the very moment it is rewritten", and it builds `authorized_keys` by the same validate-then-swap route. Running it a second time inside a running container is the case it was designed for, not a new one.
- `sshd` reads `authorized_keys` on every new connection. A regenerated file governs the next client that connects — no reload, no signal, no restart.
- `/config` is a bind mount, so the container sees what the host scripts just wrote.
- The container's processes run as root (the image sets no `USER`), which is what the generator needs for its `chown borg:borg`, and `podman exec` lands in that same identity. `99-container-status.sh` already uses the pattern.

The feature is therefore a host-side script — `93-apply-config.sh`, by the numbering of Chapter 9 — that runs the generator inside the running container, reports what changed, and becomes what `00`, `01` and `02` point at. `92` stays for the changes that genuinely need a new container.

### What still needs a restart, and must keep saying so

- Everything the entrypoint does and the generator does not: the SSH host key, `sshd` configuration, the `/repo` ownership check.
- A new image or digest pin, a changed unit or `EnvironmentFile`, a changed bind mount.
- **Immediate revocation.** A regenerated `authorized_keys` governs the *next* connection; a session already open runs until it ends. Where access has to stop now, stopping the container is the honest answer.

That last point shapes how the tool must be written. An apply command that quietly does nine tenths of what an operator believes it does is worse than the restart it replaces, because the gap only shows in the situation where it matters most.

### Constraints to preserve

- **Host-side only (Chapter 1.2.6).** `podman exec` needs host access by construction; nothing here becomes reachable from a client connection, and nothing about it surfaces through the `info` channel.
- **The generator stays the single renderer.** The live path must execute the same `build_authorized_keys.sh` the entrypoint executes. A second implementation that patches the info text or an `authorized_keys` line directly would pin the rendering format in two places and drift from it in one.
- **A failed apply leaves the previous state standing.** The validate-then-swap in the generator already provides this; the apply script must not report success when the exec failed, and must name the restart as the fallback.
- **~~`mkdir -p` on repository directories wants settling first.~~ Settled.** The generator used to create a client's repository directory when it found one missing — as root inside the container, with no ownership fix-up and no XFS project id. At container start that was rare; as a routine command it would have fired far more often, and a directory created that way is writable by nobody the client can use and covered by no quota. That was the prerequisite this item could not be built over, and it has been removed rather than worked around: neither the generator nor `borg-wrapper.sh` creates a repository directory any more. Both report a missing one instead — the generator to its log, the wrapper as `DENY: repository directory missing – needs operator action` — and creating one stays with the host, which is the only side holding both privileges it takes (`podman unshare` for the ownership, `sudo xfs_quota` for the project id). Running the generator repeatedly in a live container is therefore no longer capable of manufacturing an unquotaed client.
- **`config.sh` stays the single source of truth (Chapter 9.1).** The container name comes from there, as in every other script.

### Testability

The `podman` stub in `tests/host-scripts.sh` records every non-`unshare` invocation and returns 0, so both halves are cheap to assert: that the apply script issues its exec against `$CONTAINER`, and that a stopped or missing container produces a named fallback rather than a silent success. The generator's own behaviour is already covered by `tests/authorized-keys-generation.sh`, which runs the real script against fixtures.

This is orthogonal to the Quadlet migration (11.4): the apply path is about the running container, not about how the unit that starts it is written, and either order of implementation works.

## 11.8. Negative-Test Coverage for the Verification Checks — done

Every check in `docs/VERIFICATION.md` now records, in its own **Negative test** field, a deliberately broken deployment staged against a live instance and shown to trip that check's **Fail** criterion — never against production, always on a throwaway bench, and targeting the property rather than a proxy for it. The Summary checklist at the end of that page is the live status: as of 1.0.0 all forty checks have both directions demonstrated except the two `(✅)` *capped* ones, whose counter-example cannot be produced at all — **0A** (a forged provenance attestation that still verifies) and **12C** (two instances sharing one SELinux MCS category, which needs `setenforce 0` or dropping `:Z` and so breaks more than the one property). The single open sub-case is 5.5A's `unreadable` branch, believed reachable only by a genuine `statfs()` failure — recorded in that check's own text, not here.
