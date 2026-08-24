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

### Scope: this project's own data only, not the whole disk

The snapshot unit is `HOST_REPO_BASE` — the dedicated, quota-enforcing storage this server's repositories live on — and nothing else. An earlier draft of this entry argued for snapshotting the entire physical volume, on the reasoning that a shared disk "typically holds other operator data next to the Borg repositories" and that protecting all of it costs the same as protecting part of it. That reasoning is withdrawn: a host running this project is not assumed to run only this project. The same disk may carry data belonging to entirely different containers and services, each with its own consistency requirements (a database needs quiescing before a useful snapshot; an append-only Borg repository does not — see "Copy ordering" below) and its own retention needs. A single volume-wide snapshot sweep would couple all of that together — one schedule, one retention policy, one blast radius on restore — for services this project has no visibility into and no business managing.

**This project's snapshot tooling is therefore scoped strictly to its own container's data (`HOST_REPO_BASE`), and only that.** It is not a general-purpose, multi-container host snapshot tool, and it does not try to become one. An operator whose disk hosts other containers needs an equivalent, independently-scheduled mechanism for each of them — outside this project, following whatever consistency rules that container needs — the same way `HOST_REPO_BASE` gets its own.

That does not mean two such mechanisms are free to collide on disk. `HOST_REPO_BASE` and `SNAPSHOT_BASE` (`config.sh` — the latter not yet consumed by any script, since 11.5 itself is still an open design) are both built from the same two values, `HOST_STORAGE_BASE` and `CONTAINER`, rather than one being derived from the other: `${HOST_STORAGE_BASE}/${CONTAINER}/` for the live data, `${HOST_STORAGE_BASE}/.snapshots/${CONTAINER}/` for its snapshots. A second, independently-scheduled instance of this same tooling protecting a different container on the same physical volume therefore lands under its own, distinct `${CONTAINER}` branch automatically — no shared state, no coordination between the two, and no possibility of one instance's prune path ever resolving into the other's data. This is a naming convention for safe coexistence on shared storage, not a shared instance: it is what makes parallel operation of several containers' worth of this tooling on one host possible at all, and it has to be settled before any of the tooling below is written, not layered on afterward. It is also only a *default*: an operator whose layout does not fit this convention still sets `HOST_REPO_BASE` and `SNAPSHOT_BASE` to whatever they need directly — see the constraint below on why the second must never be inferred from the first.

`HOST_CONFIG_BASE`/`HOST_LOG_BASE` (`clients.conf`, `config/keys/`, logs — see `config.sh`) are also out of scope, deliberately, and for a different reason: they live inside the git checkout, not on the quota-enforcing storage volume, and unlike repository contents they are cheap to reconstruct — see "What restoring `HOST_REPO_BASE` alone does not restore" below.

The boundary that does hold: a snapshot lives on the same storage as the origin and is therefore **not** a second copy. Physical media failure, filesystem-level corruption, and site loss remain the domain of offsite mirroring (11.2) and the operator's storage design (Chapter 3, closing note) — snapshots neither replace nor weaken that requirement.

A deliberate attacker holding **root on the host** is out of scope for the same reason, and this is not a shortcoming of the mechanism chosen below. Root can clear an immutable flag, and could equally destroy a block-layer snapshot, a second local disk, or any other copy reachable from the machine. Nothing hosted on a system defends that system against its own root. Snapshots are a recovery path for accidents, bugs, and unprivileged damage; the answer to a root-level compromise is, and can only be, the offsite copy.

That answer is only valid under one condition, and it is a hard dependency of this item: the offsite target must enforce append-only against this server (11.2). If replication runs with credentials that permit deletion, root here reaches both copies and this boundary collapses. Protection against root is never local — it comes from the surviving copy sitting where this machine has no authority to destroy it.

> ✅ **Resolved: where this code lives.** Everything below this point (mechanism, tooling layout, scripts) now assumes the answer below.
>
> The data scope above (`HOST_REPO_BASE` only) was already settled. The remaining question was the *code's* scope: every script in `scripts/` today runs as the normal operator user, with root confined to individual `sudo xfs_quota` calls (`docs/SERVERINSTALL.md`'s prerequisite table says so explicitly: "every remaining step runs as this user unless a step says `sudo`"). What 11.5 needs is categorically different — `chattr +i`/`-i` needs `CAP_LINUX_IMMUTABLE`, i.e. real host root, pervasively rather than for one narrow call, and the prune path (clear the flag, then delete recursively) is already flagged above as the most dangerous code in the deployment. Mixing that into the existing flat, mostly-rootless `scripts/` directory would bury a real privilege boundary that a reader currently doesn't have to go hunting for.
>
> Three shapes were discussed for where the root-heavy code should actually live:
>
> - **`scripts/snapshots/`** — nested under the existing directory. Rejected for the reason above: it still visually mixes the two privilege classes at the top level of `scripts/`, which is exactly what the split exists to avoid.
> - **`snapshots/` at the repository root** — a sibling to `scripts/`, `docs/`, `systemd/`, `tests/`, holding its own scripts, systemd units, and (following the existing one-file-per-topic pattern in `docs/`) probably its own `docs/SNAPSHOTS.md`. **Chosen.** Matches how the repo already separates concerns at the top level, and cleanly marks the privilege boundary without touching `scripts/` at all. Reflects that the mechanism itself is nearly Borg-agnostic — a reflink-snapshot-plus-immutable-flag tool has no real dependency on Borg or on this project's repository format — and could, in principle, be reused for other containers' data on the same host, even though *this project's own use of it* stays scoped to `HOST_REPO_BASE` only (see "Scope" above — that restriction is about what this project protects, not about what the mechanism is capable of).
> - **A separate project entirely**, vendored or referenced from here. Rejected: coupling it to this project's release cycle, `VERSION`, CI and Docker image would be an odd provenance for anyone who'd want to reuse it for an unrelated container if it were genuinely factored out — but at the size 11.5 actually turned out to need (five scripts: creation, prune, listing, comparison, restore — see "Mechanism" below), the real cost was duplicating infrastructure this repo already has (`config.sh`/`lib.sh` conventions, the `tests/host-scripts.sh` stub pattern, the release/CI machinery) for no proportionate benefit.
>
> The middle-ground principle this roadmap already applies to the reflink-vs-block-layer choice, above, held here too: build it behind an interface clean enough that moving it later costs a copy, not a rewrite. That interface turned out to be exactly two inputs — a root path to snapshot, and a namespace label to isolate it under — which is what made `snapshots/` at the top level free to choose: it does not need those two inputs passed in explicitly, because **`config.sh` itself is now split** to hand them to any sibling of `scripts/` for the price of one `source` line.
>
> **The `config.sh` split.** The repository root now has its own `config.sh`, holding exactly the values genuinely shared between `scripts/` and `snapshots/`: `CONTAINER`, `HOST_STORAGE_BASE`, `HOST_REPO_BASE`, `SNAPSHOT_BASE`, `BORG_UID`/`BORG_GID` (the last two because the future restore path needs them too — see the "Restore must re-establish quota identity" constraint below), and the `REPO_ROOT` resolution both sides need to find everything else. `scripts/config.sh` sources it first (`. "$(dirname "$0")/../config.sh"`) and adds what is specific to the Borg side — `IMAGE`, `SSH_PORT`, `HOST_CONFIG_BASE`/`HOST_LOG_BASE`, `CONF`/`KEYDIR`, `PROJID_BASE`. `snapshots/config.sh`, once it exists, will do the same for whatever is specific to that side (retention counts, schedule). No existing script's own `. "$(dirname "$0")/config.sh"` line had to change — only `scripts/config.sh` itself grew a line at the top. See [Operations](docs/OPERATIONS.md) Chapter 9.1 for the full field-by-field split.

### Mechanism: XFS reflink copies plus the immutable flag

XFS has no native snapshot capability, and enforcing `prjquota` on XFS is mandatory (BEST_PRACTICES Chapter 1) and cannot be traded away for a snapshot-capable filesystem — the per-client hard limits and the `info` channel's live usage reporting (Chapter 7, Chapter 8) both depend on it. Ruling out a different filesystem leaves two viable routes, and the chosen one is **XFS reflinks**:

- A snapshot is a copy-on-write copy of one client's top-level directory under `HOST_REPO_BASE` into `${SNAPSHOT_BASE}/<client>/<timestamp>/`, made with `cp -a --reflink=always`. Blocks are shared until they diverge, so a snapshot costs almost nothing at creation. `SNAPSHOT_BASE` (`config.sh`) sits as a **sibling** of `HOST_REPO_BASE`, not nested inside it — `${HOST_STORAGE_BASE}/${CONTAINER}/` for the live data, `${HOST_STORAGE_BASE}/.snapshots/${CONTAINER}/` for its snapshots, both built independently from the same two `config.sh` values (see "Scope" above for why the shared `${CONTAINER}` branch matters once more than one container's tooling shares a volume). Why the client sits above the timestamp, rather than the other way around, is its own question — see "Client isolation" below.
- The finished snapshot tree is then made immutable with `chattr -R +i`. `${SNAPSHOT_BASE}` itself, and each `<client>/` directory under it, stay mutable so new snapshots can be created; each completed `<timestamp>/` snapshot below a client does not.

The immutable flag is what makes this a real protection rather than a convenience copy. It prevents modification, renaming **and** deletion: `unlink()` on an immutable inode fails with `EPERM`. An `rm -rf` against the volume therefore fails on every file in every snapshot, cannot empty a single snapshot directory, and consequently cannot remove one either — it produces a wall of errors and leaves the data intact. The rootless container is structurally unable to defeat this: clearing the flag needs `CAP_LINUX_IMMUTABLE`, which it does not have even if fully compromised.

Two properties make reflinks specifically the right primitive here, where the obvious alternatives are not:

- **Not hardlinks.** A hardlink is a second name for the same inode, so it shares the data: Borg's in-place appends to the newest segment would silently mutate the "snapshot", ransomware encrypting files in place would destroy every generation at once, and `chattr +i` would be unusable because setting it on the copy sets it on the live file the server still needs to write. Reflinks are independent inodes that merely share blocks — CoW breaks the sharing on write, so the copy is a true point-in-time view and can be made immutable on its own.
- **Not a block-layer snapshot.** LVM thin volumes or Stratis would place snapshots outside the filesystem and would additionally survive filesystem-level corruption or an accidental `mkfs` against the origin. That is the *only* class they add: against host root they are no stronger, since `lvremove` is as easy as `chattr -R -i`. Buying that one class costs a destructive storage rebuild of an existing volume plus permanent thin-pool exhaustion monitoring, and the class it covers is precisely the one offsite mirroring (11.2) exists for. The trade is not worth it here. This remains the documented alternative for operators whose risk assessment differs, and the tooling should keep the snapshot mechanism behind a thin enough abstraction that swapping it is not a rewrite. One property this comparison did not originally weigh: a block-layer snapshot is atomic across the entire volume at the instant it is taken, where a `cp -a` tree walk is not — see "Copy ordering" below. The reflink decision stands, but on the understanding that the ordering question there has to be closed, not assumed.

The immutable flag is deliberately **not** extended to the live repositories. Applying it to sealed segments in the repositories themselves would enforce the append-only invariant at the filesystem layer rather than only through the Borg protocol, which is superficially attractive. It is rejected because it would make correct server operation depend on assumptions about Borg's internal segment handling: a future Borg release that touches an older segment for any reason would not merely surprise the operator, it would break the server outright. The flag belongs on the snapshots, where it protects data without sitting anywhere in the write path.

A prerequisite worth stating explicitly: the volume must have been created with reflink support (`xfs_info <mountpoint>` must report `reflink=1`). This is the default on current Fedora, but must be verified rather than assumed — a volume without it cannot use this mechanism at all.

### Copy ordering — open question, not yet verified

A crash-consistent read of a Borg repository — the state any hard host crash mid-write leaves behind — is exactly what Borg's append-only, commit-tagged segment design is built to tolerate: an interrupted transaction is simply invisible until it is retried, and `borg check` recovers the rest. A `cp -a --reflink=always` walk over a live, growing repository tree is not the same guarantee, though: it is not atomic across files, and can span real wall-clock time on a large repository.

If the walk copies `data/` (segments) before `index`/`hints`, and a transaction commits in between, the resulting snapshot could contain an index that names a segment the snapshot never actually captured — a dangling reference, which is not a state Borg's crash recovery is designed to see (it assumes segments can outrun the index, never the reverse). Copying `index`/`hints`/lock files before `data/` should avoid this: any segment the snapshot picks up ahead of what the copied index already knew about is just the ordinary "segment exists, transaction not yet indexed" case Borg already handles.

This has not been tested. Before this mechanism is trusted it needs to be verified empirically — stage a snapshot mid-`borg create`, in both copy orders, and confirm which one opens cleanly and which one does not — per the project's own rule of measuring rather than assuming ([Verification](docs/VERIFICATION.md)).

### Client isolation: why the layout nests by client, not by generation

A layout that swept every client into one shared `<timestamp>/` directory was the original design, and it has a real flaw: the timestamp, not the client, would be the smallest unit that could be pruned. Three ordinary situations expose why that is the wrong smallest unit:

- **A compromised client.** Recovery means deleting that client's repository and rebuilding it, and removing every snapshot that covers the compromise window — a snapshot of already-tampered data is not a safe rollback point. With one shared directory per generation, "remove the snapshots that cover the window" means either destroying every other client's snapshots for that same window too, or hand-editing inside each affected generation to strip out just the one client's subtree.
- **A client's own repository being reset**, at their request, with no compromise involved — the identical mechanical problem, minus the security framing.
- **Complete, residue-free removal of a client**, potentially long after the fact — a year or more of retained history is the case that makes this concrete. Every generation the retention policy has kept since that client's onboarding has to be found and stripped of that one client's data, with zero tolerance for a missed generation, since the entire point of "residue-free" is that nothing survives.

All three, under the shared-generation layout, come down to the same operation repeated once per affected generation: clear the immutable flag on just one client's subtree within it, delete, restore the flag on what remains. That is not a new procedure — it is the prune path already named above as **the most dangerous code in the deployment** (Constraints, below), just invoked N times instead of once, with N growing as retention depth grows and a missed generation failing silently rather than loudly.

Nesting the client above the timestamp — `${SNAPSHOT_BASE}/<client>/<timestamp>/` — turns all three into that same operation invoked exactly once: clear the immutable flag and delete recursively under `${SNAPSHOT_BASE}/<client>/`, in full, in one pass. No loop over history, no possibility of a skipped generation, and — the part the shared-generation layout could never offer — every other client's snapshot history is structurally untouched, because it does not live anywhere near the path being cleared. Retention (below) then also runs per client rather than as one shared counter across `${SNAPSHOT_BASE}`, which falls out of this layout rather than being a separate feature to build.

### Snapshot comparison as a key-less integrity tripwire

Enforced append-only gives the repositories a strong on-disk invariant: existing segment files under `data/` are never modified and never removed — only the newest segment grows, and new ones are added. Comparing two snapshots therefore yields a sharp signal without ever touching archive contents:

- new segments, latest one grown — ordinary backup traffic
- an **existing** segment changed in size or mtime — cannot happen under append-only; indicates tampering or a bug
- segments missing — only `borg compact` removes segments, so outside a deliberate operator run this is an anomaly
- `config` or `nonce` changed — always worth investigating

This fits the privacy model exactly as 11.3 does (Chapter 2.1): it inspects repository *structure*, never content, and needs no key — which is what makes it something the server is actually permitted to do. The two are complementary rather than redundant: `borg check --repository-only` finds corruption *within* a repository at one point in time, while snapshot comparison finds unexpected mutation *across* time. Comparison should work from cheap per-snapshot manifests (path, size, mtime) rather than walking two full trees, so it stays viable at multi-terabyte scale.

### Constraints to preserve

- **`.snapshots/` must not carry a client project ID.** XFS project-quota accounting counts reflinked blocks in full against every inode that references them, so a snapshot placed inside a client's project tree would exhaust that client's quota instantly despite occupying no real space. The snapshot root must live outside all project trees, under project ID 0 — satisfied by construction once it sits as a sibling of `HOST_REPO_BASE` rather than nested inside it (see "Mechanism" above).
- **The prune path is the most dangerous code in the deployment.** Removing an expired snapshot requires clearing the immutable flag first, so a script whose job is to disarm protection and then delete recursively necessarily exists. It must validate that its target resolves inside the snapshot root and refuse everything else, rather than trusting its argument.
- **Immutable snapshots pin blocks.** Space freed by a later `borg compact` is not returned to the filesystem while any snapshot still references those segments. Volume sizing must account for retention depth — the same consideration a thin pool would impose, without the pool.
- **Append-only is untouched (Chapter 1.2.4).** Snapshots add a recovery path for the operator; they are not a justification for relaxing what a client connection may do.
- **Operator-side only (Chapter 1.2.6).** Creation, listing, comparison, and restore are host-side actions. No client-facing interface, no new port, and nothing surfaced through the `info` channel — snapshot existence and timing are operational metadata that clients have no business seeing.
- **Restore must re-establish quota identity.** Copying a repository back out of a snapshot restores file content but not its host context: ownership (`BORG_UID`/`BORG_GID` via `podman unshare`) and the XFS project ID must both be re-applied, as `00-ssh-create-user.sh` does at creation time. Skipping this leaves a working repository whose quota is silently no longer enforced — a failure mode that looks like success.
- **`config.sh` stays the single source of truth (Chapter 9.1).** Snapshot root, schedule, and retention counts belong there, not hardcoded in scripts or a timer unit.
- **The snapshot root is its own `config.sh` value (`SNAPSHOT_BASE`), never parsed out of `HOST_REPO_BASE` at runtime.** Its default is built the same way `HOST_REPO_BASE` is — from `HOST_STORAGE_BASE` and `CONTAINER` directly, not by taking `HOST_REPO_BASE` apart (e.g. `dirname`) to reconstruct a sibling path. The difference matters: an operator whose `HOST_REPO_BASE` does not follow the `${HOST_STORAGE_BASE}/${CONTAINER}/` convention — because they overrode it outright, which remains fully supported — would otherwise get a snapshot root silently computed onto the wrong directory, or the wrong filesystem entirely, which is fatal for a mechanism that requires reflink support on the same volume (see "Mechanism" above). Two independently-set values with related defaults degrade to "the default was not usable, set both explicitly"; one value inferred from the shape of another degrades to a silent wrong answer. `SNAPSHOT_BASE` is recorded in `config.sh` already, even though nothing reads it yet — its shape was the decision that mattered, not the timing of adding the line.

### Retention

Retention should follow how long each failure class takes to notice — accidental deletion is found within hours, a slow compromise possibly only after weeks — so a short dense window is not sufficient on its own; comparison needs enough history to answer *when* a change first appeared. Mutating operator-side operations should additionally take a named snapshot immediately beforehand and retain it until the result has been verified. This covers `borg check --repair` (11.3), any manual reclamation tooling (11.1), and equally the append-only transaction rollback used to undo a client's accidental archive deletion (Recovery, Section 1) — an operation that removes segment files by hand, on a repository whose contents the operator cannot read, and that is today made reversible only by moving those files to a quarantine directory instead of deleting them. A snapshot replaces that improvisation with a proper one.

Retention counts are per client, not one shared counter across `${SNAPSHOT_BASE}` — a direct consequence of the client-first layout ("Client isolation" above), and the reason incident response, a client's own repository reset, or a full client removal never has to reason about, or risk, any other client's history.

### What restoring `HOST_REPO_BASE` alone does not restore

A repository directory and its XFS project id can survive an accident and a subsequent snapshot restore perfectly intact, while the corresponding `clients.conf` entry and key file do not — they live under `HOST_CONFIG_BASE`, outside this feature's scope (see "Scope" above). The identity that actually matters is the client name: everything the server needs to serve a client again — its repository path, quota, project id — is derived from that name and already sits on disk. A lost or freshly regenerated SSH key is not a problem either; nothing about repository access depends on which key was used historically.

**What is missing is the tool to reconnect the two.** Checked against the scripts as they exist today:

- `00-ssh-create-user.sh` (Chapter 9.2) creates a repository directory and a `clients.conf` entry together, and refuses outright if the directory already exists (`ERROR: '$HOST_REPO' already exists on the host. Aborted.`) — the exact state a `HOST_REPO_BASE`-only restore leaves behind.
- `03-provision-client.sh` (Chapter 9.4.1) is the closer relative — it reconciles the filesystem side to match an existing `clients.conf` entry — but it never writes to `clients.conf` itself, by design ("this script makes the filesystem agree with it, never the other way round"). It requires the entry it is reconciling toward to already exist, which is precisely what a config loss removes.

Neither script covers "directory and project id present and correct, `clients.conf` entry missing." Today the only path is manual: read the quota and project id already on the directory — the same values `09-show-all-users.sh` and `02-change-user-quota.sh` already read — write the `clients.conf` line by hand, and drop in a key file. **Not yet implemented, and needed:** a dedicated script — provisionally `04-reattach-client.sh`, following the existing Chapter 9 numbering, companion to `00` the way `03` is companion to `02` — belongs in this project's restore path, not as an afterthought. Without it, this feature protects the data but not, on its own, the ability to serve it again under its original name without manual recovery.

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

## 11.8. Negative-Test Coverage for the Remaining Verification Checks

`docs/VERIFICATION.md` names, per check, whether a deliberately broken deployment has ever been staged and shown to trip that check's own **Fail** criterion (see its "How to read a test" section and the **Negative test** field under each of the 24 checks). A first pass at closing this list, against `v0.1.0-beta.31`, staged six of them — `0B`, `1`, `3B`, `4B`, `6`, `7` — each confirmed to produce its documented `Fail` output. A later pass, still against `v0.1.0-beta.31`, staged two more: blanking `HOST_REPO_BASE` and test 8's reverse direction. A third pass staged the six that remained — `1.5B`, `1.5C`, `2`, `3A`, `4A`, `4C` — at once, closing this list entirely.

Confirmed staged and matching their documented `Fail` output:

- **`1.5B` / `1.5C`** — the `Match User borg` block from [Test Environment](docs/TESTENV.md) chapter 8, mounted over a throwaway bench container's `sshd_config` (same image digest, own port, production instance untouched). `1.5A` stayed blind against that container, reporting ten correct lines regardless. `1.5B`'s `diff` against `-C user=borg` came back non-empty (`permittty` and `allowtcpforwarding` both flipped to `yes`); `1.5C`'s `grep` found the `Match` line. A real connection through a `command=`/`restrict`-less key on the same container, opened with `ssh -tt`, then produced an actual interactive TTY as `borg` — the #20 incident, reproduced against this recipe rather than only the original one. Resolves the discrepancy this entry previously flagged between `VERIFICATION.md` and `TESTENV.md`: the recipe does produce the state, and both checks catch it.
- **`2`** — `borg-wrapper.sh` copied onto the same bench container with its default-deny branch replaced by `eval "$SSH_ORIGINAL_COMMAND"; exit 0`. A forbidden command sent through a real client key then executed and returned real output — this check's `Fail` condition exactly. The same command against the unmodified production instance, with a real client key, still answered `DENY: only 'borg serve' and 'info' are permitted`.
- **`3A`** — both documented variants appended to a live `authorized_keys` in turn (no `command=` at all; then, from a clean state, a correct prefix missing only `,restrict`): the count rose from `0` to `1` for each, one at a time. The `,restrict`-missing variant passed every other check on the page — tests 1 and 2 saw nothing wrong with it — and its practical reach was measured rather than assumed: port forwarding attempted over that key failed only because `AllowTcpForwarding no` in the daemon (check 1.5A) blocked it.
- **`4A`** — the same command, run with `sudo` against the same host's rootful Podman, reported `false`, against `true` for the unprivileged account. No second install was needed, contrary to what an earlier version of this entry assumed — the check answers for whichever account ran it, which is also its documented weakness.
- **`4C`** — a second container, from the *same image digest* as the production instance, started rootful by hand (`sudo podman run`, its own port and directories, production instance untouched). This check's command reported `root`/uid 0 for its conmon and init processes, against `core`/uid 1000 for the production container queried the same way. Removed afterward, with `sudo podman` confirming nothing was left behind.
- **`5.5A` / empty `HOST_REPO_BASE`** — blanking the variable in `config.sh` and running `09-show-all-users.sh` produces exactly the branch `lib.sh` already has for it (`n/a (!) (HOST_REPO_BASE not set or not accessible)` on the `Disk usage:`/`Disk free:` lines, and the matching per-client `n/a (HOST_REPO_BASE not set)`).
- **`8`, reverse direction** — disabling the encryption gate in `/borg-wrapper.sh` on a throwaway bench deployment and repeating test 8's `borg list`/`borg info` against a `repokey` repository lets both succeed, tripping the check's documented **Fail** condition ("if `borg list` succeeds against a repokey repository, the encryption policy is not being enforced").

That closes every check this entry tracked. The one remaining loose end belongs to `VERIFICATION.md` 5.5A itself, not to this list: the `unreadable` sub-case has no recipe that reaches it (both `chmod` candidates were tried and land on `MISSING on host` instead), and the check's own text now records that as a structural conclusion rather than a gap to close.

**Constraints observed while staging the above**, matching `VERIFICATION.md`'s own rules:

- **The recipe must target the property, not a proxy for it.** The `mount -o remount,noquota` non-recipe (#22) is the cautionary example: it looked like it broke enforcement and did not.
- **Destructive or security-weakening recipes ran on throwaway state** — a separate bench container on its own port for `1.5B`/`1.5C`/`2`, a separate rootful container from the same image digest for `4C`, never the production instance (the same rule test 10 already follows).
- **A check moves to ✅ only once both directions have been observed on a real deployment.** Passing the equivalent case against the code alone (`tests/*.sh`) is not sufficient — see 11.6 above, on why "the ⚠️ marks stay attached to the checks... a runner cannot resolve it."
