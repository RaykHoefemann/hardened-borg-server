> **Docs:** [Overview](README.md) · [Design & Threat Model](docs/DESIGN.md) · [Deployment](docs/DEPLOYMENT.md) · [Operations](docs/OPERATIONS.md) · [Recovery](docs/RECOVERY.md) · [Verification](docs/VERIFICATION.md) · [Best Practices](docs/BEST_PRACTICES.md) · [Roadmap](ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–4** → Design · **5–6** → Deployment · **7–10** → Operations · **11** → Roadmap.

---

# 11. Roadmap

Planned features, not yet implemented. Listed here for visibility; timelines are not committed.

One entry (11.1) records a feature that was deliberately **dropped**. It is kept rather than removed so the decision and its reasoning stay visible — a roadmap that silently loses items teaches readers nothing about how the project makes choices.

## 11.1. Automated Archive Pruning — dropped

Previously planned: operator-configurable retention policies (e.g. "keep 7 daily, 4 weekly, 6 monthly" per client), so old archives would be cleaned up without a manual `borg prune` run.

**This is no longer a goal.** The entry is kept rather than deleted so that the decision is on record and the chapter numbering stays stable.

The reasoning is the one this project applies everywhere else: deletion is the single operation that can destroy a backup, and an automated retention mechanism would perform it regularly, unattended, against repositories whose contents the server cannot read and cannot verify afterwards. Its failure mode is silent and irreversible. Weighed against unbounded storage growth — which is visible, gradual, and answerable by adding a disk — the trade is not close.

The consequence is deliberate, and is documented as normal operation rather than as a gap: nothing is ever deleted, consumption is bounded by per-client quotas instead of retention policies, and capacity is managed by monitoring and by raising limits. See [Operations](docs/OPERATIONS.md) Chapter 10.

What this does **not** rule out is a **manual, operator-side** reclamation tool for exceptional situations. Space stranded by repeatedly failed backups (Operations, Chapter 10.4) currently has no answer other than the transaction rollback in [Recovery](docs/RECOVERY.md) Section 1, which is designed for accidents rather than for cleanup. Any such tool would be a deliberate, attended action — never a schedule, and never reachable from a client connection.

## 11.2. Mirroring Own Repositories to a Foreign Backup Server

The ability for this server to push/replicate the repositories it hosts to a **different, external backup server** for offsite redundancy — the reverse direction of the existing `MIRROR` client group (Chapter 7.1), which is about *receiving* backups from external/friend clients, not sending this server's own hosted data elsewhere.

This replication is planned as an **exact 1:1 copy** of the repository — a full, byte-for-byte replica, not a selective or filtered transfer. There is no point in this pipeline where the server can inspect, redact, or otherwise limit what the foreign server receives: it gets literally the same repository this server holds.

This makes client-side encryption not just a good idea but an absolute precondition for this feature: the foreign backup server is, by definition, outside this project's trust boundary — a third party whose own security this project has no control over. The entire confidentiality of the mirrored copy depends on the client having already encrypted every archive with a client-held key **before** it ever reached this server in the first place. As with any repository handled by this project, the client-held keyfile encryption model (Chapter 2.1.2) is expected to carry over unchanged: a mirrored copy remains only as readable as the original — the encryption key stays with whoever holds it today, not with either server. An unencrypted repository must never be mirrored this way, since doing so would hand the foreign server a complete, plaintext copy of everything.

### The foreign server must enforce append-only (mandatory)

Encryption protects the mirrored copy's confidentiality. It does nothing for its **survival**, and that is a separate, equally hard requirement: the foreign server MUST refuse deletions from this server. Mirroring to a target that accepts deletions does not produce a second copy in any meaningful sense.

The reason is the threat this copy exists to answer. Snapshots (11.5) explicitly do not cover an attacker holding root on this host, because root can clear an immutable flag or destroy a block-layer snapshot just as easily. The offsite copy is the designated answer to that scenario — but only if it is beyond this host's reach. An attacker with root here inherits whatever replication credentials this server holds, and if those credentials permit deletion, one compromise destroys the local data and the offsite copy in the same session. The remote copy would then protect against fire and disk failure, not against compromise, and the scope boundary drawn in 11.5 would be hollow.

Two consequences follow directly:

- **Enforcement must live on the foreign side.** This server cannot usefully restrict itself: any local flag, config value, or wrapper limiting outbound deletion is advisory only, because the same root that mounts the attack can change it. The guarantee has to be that the *remote* refuses the operation, exactly as this server's own wrapper refuses it for its clients (Chapter 1.2.4).
- **Or the flow is inverted.** A pull-based design, in which the foreign server fetches and this server holds no outbound credentials at all, satisfies the requirement by construction and is the stronger form where the remote operator can be persuaded to run it.

This is the same guarantee this project already provides to its own clients, applied one level up: when mirroring outward, **this server is the client**, and it must be treated with exactly the distrust it applies to everyone connecting to it. Where the foreign server runs this project too, the property already exists and only needs to be configured deliberately. Where it is a third party's infrastructure, append-only must be **verified before the target is used**, not assumed from a description — an unverified remote is not an offsite backup, it is a copy that happens to be far away.

Practical consequence to plan for: an append-only remote never reclaims space on its own. Compaction there becomes a coordinated, deliberate operator action on the foreign side, subject to the same reasoning this project applies to every mutating operation — it must not be reachable from the replication connection.

### Verifying the guarantee

Every intuitive check fails here, because Borg reports nothing. Measured against an append-only repository: `borg delete` exits 0, the archive stops appearing in `borg list`, and `borg compact` exits 0 with no output either. Nothing is refused and nothing warns — the client-visible behaviour is indistinguishable from that of an unprotected target. An operator who deletes a test archive and watches it vanish, or who waits for `compact` to be rejected as confirmation that the guarantee holds, is misled in both directions.

The only criterion that discriminates is whether **physical space is reclaimed**. Run before the first mirror, while the target repository is still empty, the signal is unambiguous (measured with Borg 1.2.8):

| | unprotected target | append-only target |
|---|---|---|
| after `borg init` | 42,293 B | 42,293 B |
| after a 1 MB probe archive | 1,092,326 B | 1,092,377 B |
| after `borg delete` + `borg compact` | 42,329 B | 1,093,846 B |

The protected repository does not merely keep the data — it grows slightly, because the deletion transaction is itself appended.

The procedure:

1. read the repository's physical size
2. create a throwaway archive of ~1 MB of incompressible data (`head -c 1M /dev/urandom`)
3. confirm the size grew
4. `borg delete` that archive
5. run `borg compact`
6. read the size again — a return to the starting value means the target accepts real deletions and is unusable as the offsite copy 11.5 depends on

Three points counterintuitive enough to be worth recording:

- **Step 5 is not optional.** Since Borg 1.2 an ordinary repository does not release space on `delete` either. A procedure that omits `compact` reports every target as protected, including the ones that are not.
- **One megabyte is sufficient, and a larger probe buys nothing** — including against a target that is not empty. Every `borg create` writes into fresh segment files rather than extending existing ones, so the probe archive sits alone in its own segment; deleting it leaves that segment essentially fully unused, far above the threshold `borg compact` requires before it rewrites a segment (`--threshold`, default 10%).
- **The probe data must be incompressible.** Deduplication and compression would otherwise reduce a nominal megabyte to a few kilobytes and leave the measurement in the noise. Since the probe cannot be removed from a correctly configured target, it stays there permanently — which is the reason to keep it small.

#### The measurement channel is the hard part

Steps 1 and 6 are the ones without a general solution, and this shapes the whole feature: **Borg offers no way to read a remote repository's physical size.** Verified against Borg 1.2.8:

- `borg info` reports live archive and chunk statistics, not occupied segments. After the deletion, the protected and the unprotected repository report byte-identical output — `All archives: 0 B`, empty chunk index. The field that would discriminate does not exist.
- `borg config <repo> append_only` refuses remote repositories outright (`Repository must be local`), so the repository-level flag cannot be read across the wire. It would not be conclusive anyway: server-side `borg serve --append-only` is a property of the connection and is not written into the repository config.
- No `borg debug` subcommand exposes repository size, and debug commands are not a basis for an operational procedure regardless.
- Shell access on the target, which would settle it with `du`, is precisely what a hardened server does not grant.

Physical usage therefore has to come from a channel the target deliberately provides. This project's `info` channel (Chapter 8) is exactly such a channel — it reports live usage read from the enforcing XFS project quota, the filesystem's own accounting rather than Borg's — and is the reference for what a verifiable mirror target has to offer. Against a target exposing nothing comparable, the only remaining option is to obtain the figure from the remote operator out of band; the client cannot establish the guarantee by itself.

This consequence should be stated plainly rather than worked around: **the ability to verify this guarantee is a criterion for choosing a mirror partner**, not an afterthought once one has been chosen. And verification is not a one-time acceptance test — the remote's configuration can change at any point without announcing itself, so it belongs on the same recurring schedule as restore testing (BEST_PRACTICES Chapter 7).

The mirror image of this check applies to this server's own append-only guarantee. That guarantee rests entirely on every key being bound to the forced command generated by `build_authorized_keys.sh`; a single `authorized_keys` line lacking the `command="/borg-wrapper.sh …"` prefix silently exempts that key, and nothing else in the system would look wrong. Regeneration on container start limits how long such a line can survive, but an explicit read-only audit — every non-comment line carries the prefix, line count matches the configured clients — is worth having alongside the remote test.

## 11.3. Automated Integrity Verification (`borg check`)

Scheduled, operator-side integrity checking of the hosted repositories via `borg check`, so that silent on-disk corruption (bit rot, a truncated segment, an inconsistent index) is detected proactively rather than discovered at restore time.

The privacy model (Chapter 2.1) directly shapes what this feature can and cannot do — this is the central design constraint, not an afterthought:

- **Repository-level checks (`borg check --repository-only`) are possible server-side.** They validate the repository's own structures — segment files, hashes, index/manifest consistency — without decrypting any archive contents, and therefore need no encryption key. This is exactly the class of damage the server is in a position to detect, and where automated server-side checking genuinely adds value.
- **Archive-data verification (`borg check --verify-data`, and the archive-consistency portion of a full check) is *not* possible server-side.** Reading archive metadata and re-verifying chunk contents requires the repository key, which by design never exists on the server (Chapter 2.1). Deep, content-level verification therefore remains a **client-side responsibility**, carried out by whoever holds the key — the server cannot, and must not be able to, perform it.

Two existing guarantees must be preserved when this lands:

- **Append-only (Chapter 1.2.4):** `borg check` has a `--repair` mode that *modifies* the repository. Repair must never be reachable from a client connection and must be a distinct, deliberate operator-side action. The scheduled check itself runs strictly read-only; repair stays manual.
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

## 11.5. Point-in-Time Snapshots of the Storage Volume

Automatic, operator-side, point-in-time snapshots of the **entire storage volume** that carries the repositories, with a retention policy, a restore path, and snapshot-to-snapshot comparison.

Unlike the other items on this list, this is **not an optional enhancement**. For a server that calls itself hardened it belongs to the baseline: today the design has no answer at all for destructive action originating on the *host* side. Append-only (Chapter 1.2.4) closes the client-triggered path completely — a client cannot delete anything — but nothing protects the stored data against:

- **Operator error.** A mistyped `rm -rf` against the storage volume destroys every hosted repository at once, and the only remaining copy is offsite.
- **Destructive software running on the host.** Ransomware or a runaway process acting outside the rootless container is beyond anything the application layer can defend against — up to, but not including, an attacker who holds root (see the scope boundary below).
- **The server's own mutating operations.** `borg check --repair` (11.3) deliberately writes to repositories from the operator side, bypassing append-only by design, as would any manual reclamation tooling (11.1). Each is an opportunity to destroy data through a bug or a wrong parameter — and 11.3 is a planned feature, so this is a risk the project is about to create for itself.

Without snapshots, every one of these ends in the same place: a full restore from the offsite mirror (11.2). That is slow, depends on a third party's availability, and is a disproportionate response to what is usually a small, local, entirely recoverable mistake. Snapshots turn it into a local rollback measured in seconds, and — because a snapshot can be compared against the live tree — they also answer *what* changed and *when* it started, which no restore from offsite can tell you.

### Scope: the whole volume, not just the repositories

The snapshot unit is the complete storage volume (`/var/mnt/…`, the filesystem `HOST_REPO_BASE` lives on), not `HOST_REPO_BASE` alone. The volume typically holds other operator data next to the Borg repositories, and that data is subject to exactly the same accidents. Most of it may be reproducible in principle, but reproducing it is expensive, and there is no reason to protect a subdirectory when protecting the filesystem costs the same.

The boundary that does hold: a snapshot lives on the same storage as the origin and is therefore **not** a second copy. Physical media failure, filesystem-level corruption, and site loss remain the domain of offsite mirroring (11.2) and the operator's storage design (Chapter 3, closing note) — snapshots neither replace nor weaken that requirement.

A deliberate attacker holding **root on the host** is out of scope for the same reason, and this is not a shortcoming of the mechanism chosen below. Root can clear an immutable flag, and could equally destroy a block-layer snapshot, a second local disk, or any other copy reachable from the machine. Nothing hosted on a system defends that system against its own root. Snapshots are a recovery path for accidents, bugs, and unprivileged damage; the answer to a root-level compromise is, and can only be, the offsite copy.

That answer is only valid under one condition, and it is a hard dependency of this item: the offsite target must enforce append-only against this server (11.2). If replication runs with credentials that permit deletion, root here reaches both copies and this boundary collapses. Protection against root is never local — it comes from the surviving copy sitting where this machine has no authority to destroy it.

### Mechanism: XFS reflink copies plus the immutable flag

XFS has no native snapshot capability, and enforcing `prjquota` on XFS is mandatory (BEST_PRACTICES Chapter 1) and cannot be traded away for a snapshot-capable filesystem — the per-client hard limits and the `info` channel's live usage reporting (Chapter 7, Chapter 8) both depend on it. Ruling out a different filesystem leaves two viable routes, and the chosen one is **XFS reflinks**:

- A snapshot is a copy-on-write copy of every top-level directory of the volume into `.snapshots/<timestamp>/`, made with `cp -a --reflink=always`. Blocks are shared until they diverge, so a snapshot costs almost nothing at creation.
- The finished snapshot tree is then made immutable with `chattr -R +i`. `.snapshots/` itself stays mutable so new snapshots can be created; each completed snapshot below it does not.

The immutable flag is what makes this a real protection rather than a convenience copy. It prevents modification, renaming **and** deletion: `unlink()` on an immutable inode fails with `EPERM`. An `rm -rf` against the volume therefore fails on every file in every snapshot, cannot empty a single snapshot directory, and consequently cannot remove one either — it produces a wall of errors and leaves the data intact. The rootless container is structurally unable to defeat this: clearing the flag needs `CAP_LINUX_IMMUTABLE`, which it does not have even if fully compromised.

Two properties make reflinks specifically the right primitive here, where the obvious alternatives are not:

- **Not hardlinks.** A hardlink is a second name for the same inode, so it shares the data: Borg's in-place appends to the newest segment would silently mutate the "snapshot", ransomware encrypting files in place would destroy every generation at once, and `chattr +i` would be unusable because setting it on the copy sets it on the live file the server still needs to write. Reflinks are independent inodes that merely share blocks — CoW breaks the sharing on write, so the copy is a true point-in-time view and can be made immutable on its own.
- **Not a block-layer snapshot.** LVM thin volumes or Stratis would place snapshots outside the filesystem and would additionally survive filesystem-level corruption or an accidental `mkfs` against the origin. That is the *only* class they add: against host root they are no stronger, since `lvremove` is as easy as `chattr -R -i`. Buying that one class costs a destructive storage rebuild of an existing volume plus permanent thin-pool exhaustion monitoring, and the class it covers is precisely the one offsite mirroring (11.2) exists for. The trade is not worth it here. This remains the documented alternative for operators whose risk assessment differs, and the tooling should keep the snapshot mechanism behind a thin enough abstraction that swapping it is not a rewrite.

The immutable flag is deliberately **not** extended to the live repositories. Applying it to sealed segments in the repositories themselves would enforce the append-only invariant at the filesystem layer rather than only through the Borg protocol, which is superficially attractive. It is rejected because it would make correct server operation depend on assumptions about Borg's internal segment handling: a future Borg release that touches an older segment for any reason would not merely surprise the operator, it would break the server outright. The flag belongs on the snapshots, where it protects data without sitting anywhere in the write path.

A prerequisite worth stating explicitly: the volume must have been created with reflink support (`xfs_info <mountpoint>` must report `reflink=1`). This is the default on current Fedora, but must be verified rather than assumed — a volume without it cannot use this mechanism at all.

### Snapshot comparison as a key-less integrity tripwire

Enforced append-only gives the repositories a strong on-disk invariant: existing segment files under `data/` are never modified and never removed — only the newest segment grows, and new ones are added. Comparing two snapshots therefore yields a sharp signal without ever touching archive contents:

- new segments, latest one grown — ordinary backup traffic
- an **existing** segment changed in size or mtime — cannot happen under append-only; indicates tampering or a bug
- segments missing — only `borg compact` removes segments, so outside a deliberate operator run this is an anomaly
- `config` or `nonce` changed — always worth investigating

This fits the privacy model exactly as 11.3 does (Chapter 2.1): it inspects repository *structure*, never content, and needs no key — which is what makes it something the server is actually permitted to do. The two are complementary rather than redundant: `borg check --repository-only` finds corruption *within* a repository at one point in time, while snapshot comparison finds unexpected mutation *across* time. Comparison should work from cheap per-snapshot manifests (path, size, mtime) rather than walking two full trees, so it stays viable at multi-terabyte scale.

### Constraints to preserve

- **`.snapshots/` must not carry a client project ID.** XFS project-quota accounting counts reflinked blocks in full against every inode that references them, so a snapshot placed inside a client's project tree would exhaust that client's quota instantly despite occupying no real space. The snapshot root must live outside all project trees, under project ID 0.
- **The prune path is the most dangerous code in the deployment.** Removing an expired snapshot requires clearing the immutable flag first, so a script whose job is to disarm protection and then delete recursively necessarily exists. It must validate that its target resolves inside the snapshot root and refuse everything else, rather than trusting its argument.
- **Immutable snapshots pin blocks.** Space freed by a later `borg compact` is not returned to the filesystem while any snapshot still references those segments. Volume sizing must account for retention depth — the same consideration a thin pool would impose, without the pool.
- **Append-only is untouched (Chapter 1.2.4).** Snapshots add a recovery path for the operator; they are not a justification for relaxing what a client connection may do.
- **Operator-side only (Chapter 1.2.6).** Creation, listing, comparison, and restore are host-side actions. No client-facing interface, no new port, and nothing surfaced through the `info` channel — snapshot existence and timing are operational metadata that clients have no business seeing.
- **Restore must re-establish quota identity.** Copying a repository back out of a snapshot restores file content but not its host context: ownership (`BORG_UID`/`BORG_GID` via `podman unshare`) and the XFS project ID must both be re-applied, as `00-ssh-create-user.sh` does at creation time. Skipping this leaves a working repository whose quota is silently no longer enforced — a failure mode that looks like success.
- **`config.sh` stays the single source of truth (Chapter 9.1).** Snapshot root, schedule, and retention counts belong there, not hardcoded in scripts or a timer unit.

### Retention

Retention should follow how long each failure class takes to notice — accidental deletion is found within hours, a slow compromise possibly only after weeks — so a short dense window is not sufficient on its own; comparison needs enough history to answer *when* a change first appeared. Mutating operator-side operations should additionally take a named snapshot immediately beforehand and retain it until the result has been verified. This covers `borg check --repair` (11.3), any manual reclamation tooling (11.1), and equally the append-only transaction rollback used to undo a client's accidental archive deletion (Recovery, Section 1) — an operation that removes segment files by hand, on a repository whose contents the operator cannot read, and that is today made reversible only by moving those files to a quarantine directory instead of deleting them. A snapshot replaces that improvisation with a proper one.

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
