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

## 11.2. Replicating Own Repositories Off-Server — foreign-server mirroring dropped; manual offline export planned

Two things have lived under this number. The first — this server replicating its hosted repositories to a **different, external backup server** for live offsite redundancy — was planned and is now **dropped**. The entry is kept, as 11.1 is, so the decision and its reasoning stay on record. What replaces it is smaller and stays inside the trust boundary: a **manual, operator-side helper for copying repositories onto removable media**.

### Why foreign-server mirroring is dropped

The feature only meant something if the foreign server enforced append-only against this one. An offsite copy that accepts deletions is not a second copy in any meaningful sense: an attacker with root here inherits whatever replication credentials this server holds, so if those credentials permit deletion, one compromise destroys the local data and the remote copy in the same session. That requirement cannot be met inside this project's model:

- **This server holds no repository key** (Chapter 2.1.2). The only replication mechanism available to it is a file-level copy of the opaque repository directory — `rsync`/`rclone`, never the Borg protocol, because every archive-moving Borg operation (`borg create`, `borg transfer` in Borg 2.x) must open the manifest and needs the key. This is not a limitation a newer Borg lifts; it follows from the key never being on the server. `borg serve --append-only` is therefore never in the path — "the foreign side enforces append-only" could only mean a pull-based fetch, or filesystem-level immutability and versioning on the remote.
- **rsync has no append-only mode.** `rrsync -no-del` blocks `--delete` and `--remove*`, but nothing stops a hostile or buggy sender from overwriting existing files in place, and `rrsync` can filter client options off but cannot force `--ignore-existing` on. Borg's committed segments are frozen by the protocol; rsynced files are not.
- Closing that gap means trusting the foreign operator's storage layer — remote snapshots, ZFS/btrfs, WORM — which is exactly the third-party integrity this project declines to assume. An unverified remote is a copy that happens to be far away, not an offsite backup.
- The same reasoning runs backwards, so **this project does not offer an inbound rsync mirror endpoint to third parties either.** It could not be locked down to the standard `borg serve` meets — rsync is a large C codebase with a running CVE history, against a narrow purpose-built protocol — and offering it would undercut the standard the rest of the server holds to.

**Offsite redundancy is therefore delegated to the client.** Only the client holds the key, so only the client can make a second, genuinely independent copy: another `borg create` target, or `borg serve` against a foreign server *the client* trusts. This is documented as a client recommendation ([Client Use](docs/CLIENTUSE.md), [Best Practices](docs/BEST_PRACTICES.md)), not built as a server feature. The `MIRROR` client group (Chapter 7.1) already covers the one adjacent thing this server does safely — *receiving* backups from external clients over the same forced-command `borg serve` path every other client uses.

The append-only verification procedure this entry used to carry (probe archive, `borg delete` + `borg compact`, then measure whether physical space is reclaimed — the only signal that discriminates, since Borg refuses nothing and warns nothing) is still useful to a client setting up its own offsite target, and now lives in [Client Use](docs/CLIENTUSE.md) Chapter 9.

### What replaces it: a manual offline export helper

A host-side script that copies the operator's own hosted repositories — `HOST_REPO_BASE/OWN/` — onto a mounted block device (`rsync -a --delete`), for an air-gapped copy the operator physically disconnects and can store elsewhere. This stays inside the project's trust boundary — the operator's own disk, in the operator's hands — so the append-only problem above does not apply: the immutability is physical (the medium is unplugged), not a protocol property. It is the "offline" half of the offline/offsite split; the "offsite" half is the client's job, above.

Scope and constraints:

- **`OWN` only; `MIRROR` is deliberately skipped.** The `MIRROR` group holds external clients' own backups (Chapter 7.1): this server is already *their* offsite copy, their source data lives with them, and their repositories are not the operator's data to carry offsite. The helper therefore sweeps `HOST_REPO_BASE/OWN/` and nothing else. This rests on the assumption that `MIRROR` contains only mirror backups — an operator whose `MIRROR` group also holds something they would themselves need to recover should not rely on that, and should widen the export deliberately. (Snapshots, 11.5, are unaffected — they cover both groups, because they cost nothing and never leave the host.)
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

The hand-written systemd unit **template** + generated `EnvironmentFile` (Chapter 6.2) is replaced by a declarative **Podman Quadlet**: `systemd/borg-server.container`, checked in and carrying no deployment-specific values, installed by `scripts/50-service-install.sh` as `~/.config/containers/systemd/<CONTAINER>.container` (a symlink) with a generated `<CONTAINER>.container.d/10-deployment.conf` drop-in. `podman-system-generator` produces `<CONTAINER>.service` from that on `systemctl --user daemon-reload`.

What it bought:

- **More robust lifecycle handling.** Quadlet creates a fresh container per start and removes it on stop natively, which removes the fragile `--rm` + fixed `--name` + `Restart=on-failure` interaction (the "name already in use" failure after an unclean stop) without a `--replace` workaround.
- **Less bespoke plumbing.** `50-service-install.sh` no longer renders a template, generates an `EnvironmentFile`, or symlinks into `~/.config/systemd/user/`; `51-service-uninstall.sh` shrinks to removing two files and reloading.

Constraints kept:

- **`config.sh` stays the single source of truth (Chapter 9.1).** No deployment value is hardcoded in the checked-in `.container`. The per-host values (`IMAGE`, `SSH_PORT`, the `HOST_*_BASE` bind mounts, `CONTAINER`) land in the generated drop-in rather than in a fully rendered unit — the checked-in file is then genuinely static, and a `git pull` that changes it is live after the next `daemon-reload` with no re-install.
- **Multiple instances on one host.** Every per-instance resource is namespaced by `CONTAINER` through the Quadlet filename (`<CONTAINER>.container` → `<CONTAINER>.container.d/` → `<CONTAINER>.service` → `ContainerName=<CONTAINER>`), so the `container_` prefix the old installed unit carried is gone. Two instances still need distinct `SSH_PORT` values; `50-service-install.sh` refuses to overwrite a `<CONTAINER>.container` that belongs to a different checkout.
- **Rootless user service + lingering unchanged (Chapters 6.2.1, 6.2.3).** Still a rootless *user* unit under `~/.config/containers/systemd/`, still needs `loginctl enable-linger`. No `User=` (Quadlet passes it straight through, so the `status=216/GROUP` trap is unchanged). None of the Chapter 1.1 rootless guarantees change.

This was a **deployment/lifecycle change only** — it did not alter client-facing behavior, the security model (Chapter 1), or the privacy model (Chapter 2). A one-time migration step for deployments still on the `.service` unit is in [Deployment](docs/DEPLOYMENT.md) Chapter 6.3.

> **Follow-up, separate from the migration:** the Quadlet also makes the F4 container-hardening keys (`NoNewPrivileges`, `DropCapability=all` + a minimal `AddCapability`, `ReadOnly`, `PidsLimit`, `Memory`) expressible declaratively. That *is* a security-model change and is tracked on its own, not folded in here.

## 11.5. Point-in-Time Snapshots of the Storage Volume — done

Point-in-time snapshots of `HOST_REPO_BASE`, with a client-scoped restore path, closing the one gap append-only cannot: destructive action originating on the *host* side rather than over a client's connection (operator error, destructive host-side software, a bug in this server's own privileged operations). Not a second copy, and not a substitute for an offsite copy — which, now that server-side foreign mirroring is dropped (11.2), is wholly a client-side responsibility and remains necessary regardless of snapshots.

Shipped as `snapshots/70-create-snapshot.sh` (plus `71-timer-install.sh`), `75-list-snapshots.sh`, `76-delete-snapshots.sh`, and `77-restore-last-snapshot.sh`, plus `scripts/04-reattach-client.sh` for the one gap a `HOST_REPO_BASE`-only restore leaves behind (reconnecting `clients.conf`). See [Snapshots](docs/SNAPSHOTS.md) for scope, requirements, layout, and how to use each script, and [Verification](docs/VERIFICATION.md) Test 11 for the checks proving it holds — immutability survives even root, restore reconstructs the exact quota and project id, and deletion refuses a path outside `SNAPSHOT_BASE`.

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
