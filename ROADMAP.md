> **Docs:** [Overview](README.md) · [Design & Threat Model](docs/DESIGN.md) · [Deployment](docs/DEPLOYMENT.md) · [Operations](docs/OPERATIONS.md) · [Recovery](docs/RECOVERY.md) · [Verification](docs/VERIFICATION.md) · [Best Practices](docs/BEST_PRACTICES.md) · [Roadmap](ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–4** → Design · **5–6** → Deployment · **7–10** → Operations · **11** → Roadmap.

---

# 11. Roadmap

This chapter tracks work that is **planned but not yet built**. A feature that
ships is not kept here — it moves into the documents that describe it, and its
design history stays in git. Timelines are not committed.

Section numbers are historical and are not resequenced. Four have left this page:
**11.1** (automated archive pruning) and server-side mirroring were **dropped** —
the reasoning is now in [Design](docs/DESIGN.md) Chapter 4.6 — and **11.4**
(migration to a Podman Quadlet), **11.5** (point-in-time snapshots of the storage
volume) and **11.8** (negative-test coverage for the verification checks)
**shipped in 1.0.0**, documented in [Deployment](docs/DEPLOYMENT.md) Chapter 6.2,
[Snapshots](docs/SNAPSHOTS.md) and [Verification](docs/VERIFICATION.md).

## 11.2. Manual Offline Export to Removable Media

A host-side script that copies the hosted repositories — `HOST_REPO_BASE/` — onto
a mounted block device with host-side `rsync`, for an air-gapped copy the operator
physically disconnects and can store elsewhere. This stays inside the project's
trust boundary — the operator's own disk, in the operator's hands — so the
append-only problem that ruled out server-side mirroring ([Design](docs/DESIGN.md)
Chapter 4.6) does not apply here: the immutability is physical (the medium is
unplugged), not a protocol property. It is the "offline" half of the
offline/offsite split; the "offsite" half — a live copy on infrastructure this
host cannot reach — is the client's, because only the client holds the key.

Scope and constraints:

- **Which repositories to export is an operator choice.** A repository holding an external partner's own backups is one this server is already the offsite copy *of* — its source data lives with that partner, and it is not the operator's data to carry offsite. The helper cannot tell those apart from a name, so the sweep set is either "everything under `HOST_REPO_BASE`" or an explicit allow/deny list the operator maintains. (Snapshots are unaffected — they cover every client, because they cost nothing and never leave the host.)
- **Manual and attended.** No timer, no schedule, no client-facing surface — the category of `99-container-status.sh`. Nothing about it is reachable from a client connection (Chapter 1.2.6).
- **The copy is ciphertext.** A keyfile-mode repository copied this way cannot be restored without the client's exported key and passphrase (Chapter 2.1.1), which exist only on the client. The helper produces half of a usable offline backup; the client-side key archive ([Best Practices](docs/BEST_PRACTICES.md) Chapter 2.1) is the other half. The server cannot hold that half without becoming the key escrow the same chapter rules out.
- **Not against a live repository.** Run it in an idle window, or from a storage snapshot ([Snapshots](docs/SNAPSHOTS.md)). Borg repositories are transactional — a copy taken mid-commit rolls back to the last committed transaction on next access rather than tearing — but a coordinated quiet window is cleaner still.
- **The source is verified before, the copy after.** `borg check --repository-only` on the source (11.3, or work from a storage snapshot) keeps a known-bad repository from being propagated; the same check on the finished copy catches damage the transfer or the medium introduced. Neither is a hard gate — a structurally broken repository may still hold recoverable archives — but a failed check on the copy must stop it from replacing the last good one (see the layout below).
- **Destination-agnostic, but only removable media is supported.** The same `rsync` invocation can point anywhere the operator can write. Doing so is the operator's own decision and carries every caveat above; it is not a mirroring feature and is not documented as one.

### Crash-safe layout on the medium (sketch — revisit at implementation)

A plain in-place `rsync -a --delete` over the previous copy is **not** crash-safe: mid-run the destination is a mix of old and new, and an interruption — power loss, a full medium, a source that turns out to be corrupt — leaves no intact copy behind. The offline copy should be written with the same all-or-nothing discipline the server applies to its control files ([Design](docs/DESIGN.md) Chapter 3.4), and never by mutating the last good copy in place.

The intended shape mirrors `70-create-snapshot.sh`: **dated, independent, immutable generation directories** on the medium with manual retention, not a single mirrored tree.

**Protection target: a completed generation should be no easier to damage than a storage snapshot.** The offline copy already beats a snapshot on the threats that matter most — once unplugged it is outside the host's fate entirely (host compromise, ransomware reaching the host, array failure, a bug in the server's own privileged tooling), and it can be stored off-site. It reaches parity on tampering via `chattr -R +i` on finished generations, exactly as `70-` does. Two places it is *weaker* unless the helper closes them: it is read-write on the host for the duration of the export (keep that window minimal — mount, export, verify, `+i`, unmount — and do not leave the medium attached between runs; the generational layout already confines in-window damage to `.incoming-*`), and a fresh medium's files are operator-owned rather than mapped-subuid, so on a filesystem without `chattr +i` nothing stops an unprivileged `rm` (hence the ext4/xfs requirement below, with read-only-except-during-export as the fallback).

```
<medium>/borg-export/
    2026-08-28T0300/     immutable, verified
    2026-08-29T0300/     immutable, verified
    2026-08-30T0300/     new this run
    latest -> 2026-08-30T0300
```

Per run:

1. `rsync -a --link-dest=../latest <source>/ <medium>/borg-export/.incoming-<ts>/` — `--link-dest` hard-links every unchanged file against the previous generation. Because the repositories are append-only, almost every segment file is byte-identical between runs, so only the new segments cost space, not a full second copy.
2. rsync exits 0 → `mv .incoming-<ts> <ts>` (atomic within the filesystem).
3. `borg check --repository-only --bypass-lock <ts>` on the fresh generation.
4. Pass → `chattr -R +i <ts>`, then repoint `latest` atomically.
5. Fail, or an earlier step aborted → the partial `.incoming-<ts>` or the unverified `<ts>` is left for inspection, `latest` still points at the previous generation, and no existing generation was touched.

Every failure mode this must survive: a crash mid-transfer (the partial directory is never named `latest`), a corrupt source (the pre-run check aborts before anything is written), a copy that transfer or media damaged (the post-run check keeps it from becoming `latest`). In none of them is an existing verified generation modified. Retention is a `76-`-style manual operation that refuses to remove `latest` or the last remaining generation.

Open, to settle at implementation:

- **Full generation history vs. two alternating directories (`A`/`B`).** History gives an offline point-in-time series almost for free (via `--link-dest`); `A`/`B` is less space and no history. Leaning toward history, for consistency with the snapshot model.
- **Medium filesystem.** Hard-links and `chattr +i` need ext4/xfs; exFAT/FAT provide neither. The helper must detect this and either fall back to full independent copies or refuse with a clear message — the same "bring your own POSIX filesystem" line `70-` already draws for XFS.
- **`chattr +i` on the medium** hardens completed generations against a later run or a fat-fingered `rm`, but is bypassed by mounting the medium read-write elsewhere — a convenience, not a security boundary.
- **Mount discipline.** Whether the helper mounts and unmounts the medium itself (minimising the read-write window, and able to keep it read-only between the transfer and the `chattr` step) or leaves mounting to the operator. The tighter the helper controls this, the closer the medium's exposure gets to a snapshot's.
- **Beyond a snapshot (optional).** Rotating several media so no single medium failure loses history, and a detached `sha256` manifest of each generation kept on the host so medium-side tampering or rot is detectable on re-attach without a key — machinery the snapshots deliberately skipped because they sit inside the append-only boundary and the medium does not.

## 11.3. Automated Integrity Verification (`borg check`)

Scheduled, operator-side integrity checking of the hosted repositories via `borg check`, so that silent on-disk corruption (bit rot, a truncated segment, an inconsistent index) is detected proactively rather than discovered at restore time.

The privacy model (Chapter 2.1) directly shapes what this feature can and cannot do — this is the central design constraint, not an afterthought:

- **Repository-level checks (`borg check --repository-only`) are possible server-side.** They validate the repository's own structures — segment files, hashes, index/manifest consistency — without decrypting any archive contents, and therefore need no encryption key. This is exactly the class of damage the server is in a position to detect, and where automated server-side checking genuinely adds value.
- **Archive-data verification (`borg check --verify-data`, and the archive-consistency portion of a full check) is *not* possible server-side.** Reading archive metadata and re-verifying chunk contents requires the repository key, which by design never exists on the server (Chapter 2.1). Deep, content-level verification therefore remains a **client-side responsibility**, carried out by whoever holds the key — the server cannot, and must not be able to, perform it.

Two existing guarantees must be preserved when this lands:

- **Append-only (Chapter 1.2.4):** `borg check` has a `--repair` mode that *modifies* the repository. Repair must never be reachable from a client connection and must be a distinct, deliberate operator-side action. The scheduled check itself runs strictly read-only; repair stays manual.
- **Host-side-only observability (Chapter 1.2.6):** results surface to the operator on the host (log output and exit status, e.g. driven by a systemd timer), not through a new client-facing interface or port. Whether a "last checked" timestamp is later surfaced to clients through the existing `info` channel (Chapter 8) is a separate, deliberate decision — doing so would widen what that channel reports and is intentionally out of scope for the first iteration.

Practical considerations: `borg check` is I/O-intensive, so scheduling must avoid colliding with active backup windows, and each per-repository check should run under the same isolation the rest of the server uses.

## 11.6. Executable Verification Checks

A runner that performs the host-side checks of [Verification](docs/VERIFICATION.md) as code — `tests/verify.sh 5B`, or all of them at once — so that an operator or a security researcher can obtain a machine-readable result without working through the page command by command by hand.

This became possible rather than merely desirable when the page moved to one criterion per check: each host-side check now names exactly one thing, has exactly one measurement, and has exactly one repair. A script per check is a transcription of that structure, not a reinterpretation of it.

Scope is deliberately the **host side** only. The checks that run from a client machine holding a provisioned key — writing throwaway data into a real repository, and in one case leaving roughly a megabyte behind permanently — stay manual: driving them from the host would mean the server holding a client key, which contradicts Chapter 2.1 outright. The runner should say so rather than silently reporting a partial pass as a whole one.

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

This is orthogonal to the Quadlet deployment ([Deployment](docs/DEPLOYMENT.md) Chapter 6.2): the apply path is about the running container, not about how the unit that starts it is written, and either order of implementation works.
