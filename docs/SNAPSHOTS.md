> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)

---

# Snapshots

Point-in-time snapshots of `HOST_REPO_BASE` — the storage this server's client repositories live on — with a client-scoped restore path. This is the local, fast half of the recovery story: a rollback measured in seconds, for the damage classes append-only (Chapter 1.2.4) cannot see at all, because they originate on the *host* side rather than over a client's SSH connection:

- an operator's own mistyped `rm -rf` against the storage volume,
- destructive software running on the host outside the rootless container,
- a bug in this server's own privileged, mutating operations (`borg check --repair`, manual reclamation tooling).

**This is not a second copy, and it is not a substitute for offsite mirroring.** A snapshot lives on the same physical storage as the data it protects. Media failure, filesystem corruption, site loss, and an attacker who holds root on this host (root can clear the immutable flag as easily as anything else here) are all outside what this tooling can do anything about — that is what offsite mirroring with an append-only-enforcing target (ROADMAP.md 11.2) is for, and it remains mandatory regardless of whether this tooling is in use. See [ROADMAP.md 11.5](../ROADMAP.md#115-point-in-time-snapshots-of-the-storage-volume) for the full threat model, the reasoning behind every design choice below, and the "Snapshot comparison — considered and dropped" section explaining why this is a recovery aid rather than a tamper-detection system.

## 1. Scope

Only `HOST_REPO_BASE` — client repositories — is snapshotted. `HOST_CONFIG_BASE` (`clients.conf`, `config/keys/`) and `HOST_LOG_BASE` are deliberately out of scope: they live inside the git checkout, not on the quota-enforcing storage volume, and are cheap to reconstruct. If a client's directory survives a `HOST_REPO_BASE`-only restore but its `clients.conf` entry does not, that is what [`04-reattach-client.sh`](OPERATIONS.md#921-04-reattach-clientsh) is for.

This is also not a general-purpose, multi-container host snapshot tool. If this host runs other containers with their own data on the same physical disk, each needs its own, independently-scheduled equivalent — this tooling only ever touches its own `${CONTAINER}` branch (see "Layout" below), by construction.

## 2. Requirements

- `HOST_REPO_BASE` on an XFS filesystem with **reflink support** (`mkfs.xfs` default since XFS's reflink feature became standard; verify with `xfs_info <mount> | grep reflink`). This is what makes snapshot creation near-instant and near-free regardless of repository size — see ROADMAP.md 11.5, "Mechanism".
- The same enforcing `prjquota` this project already requires for client repositories (BEST_PRACTICES.md Chapter 1) — snapshots don't need it themselves, but they live on the same volume.
- `SNAPSHOT_BASE` set in the repository root's `config.sh` — by default `${HOST_STORAGE_BASE}/.snapshots/${CONTAINER}/`, a **sibling** of `HOST_REPO_BASE` rather than nested inside it. This is not cosmetic: a snapshot root nested inside a client's project tree would have its reflinked blocks counted in full against that client's XFS project quota, exhausting it instantly despite occupying no real extra space. If your `HOST_REPO_BASE` does not follow the `HOST_STORAGE_BASE`/`CONTAINER` convention (an explicit override), set `SNAPSHOT_BASE` explicitly too — it is never derived by parsing `HOST_REPO_BASE` apart, exactly so an unconventional layout can never make it resolve onto the wrong volume.
- `snapshots/config.sh` sources the repository root's `config.sh` for all of this; there is nothing snapshot-specific to configure there today.
- Root, for a narrow set of privileged operations — see "Privileges" below.

## 3. Layout on disk

```
${SNAPSHOT_BASE}/<client>/<timestamp>/
```

Nested by **client first, timestamp second** — not the reverse. A generation-first layout (`<timestamp>/<client>/...`) would make the timestamp, not the client, the smallest unit that could be pruned, so removing one compromised client's history would mean touching every other client's snapshots for the same window too. Client-first nesting turns "remove everything belonging to client X" — the actual operation needed for a compromised client, a client's own repository reset, or complete client removal — into clearing the immutable flag and deleting once under `${SNAPSHOT_BASE}/<client>/`, full stop, with every other client's history structurally untouched. See ROADMAP.md 11.5, "Client isolation" for the reasoning in full.

Timestamps are `YYYYMMDDTHHMMSSZ` (UTC, ISO-8601 basic, e.g. `20260825T210335Z`) — the exact value every script below both produces and accepts, so one is always copy-pasteable out of another's output.

## 4. Creating snapshots — `70-create-snapshot.sh`

```bash
./snapshots/70-create-snapshot.sh
```

No arguments. Sweeps every client currently found under `HOST_REPO_BASE` (discovered by walking the filesystem, not by reading `clients.conf` — a client with a missing or wrong config entry is still protected) and, for each: `sudo cp -a --reflink=always` into a new `${SNAPSHOT_BASE}/<client>/<timestamp>/`, then `sudo chattr -R +i` to make it read-only, rename-proof and delete-proof — verified back with `lsattr` rather than trusting the exit code. One client failing does not stop the others; the run's exit status reflects whether all of them succeeded.

Meant to run unattended, on a schedule — there is no confirmation prompt, since this operation only ever adds a directory and never changes or removes anything. Two ways to schedule it:

- **systemd timer** (the only option on Fedora CoreOS, which has no cron):

  ```bash
  ./snapshots/71-timer-install.sh
  ```

  Installs `snapshot-create.timer` (daily at 03:00) and its service unit as a rootless *user* timer, the same mechanism `scripts/50-service-install.sh` uses for the container itself (DEPLOYMENT.md 6.2.1). Requires `loginctl enable-linger $USER` so the timer keeps running after logout — the same requirement the container service already documents. Check it with:

  ```bash
  systemctl --user list-timers snapshot-create.timer
  journalctl --user -u snapshot-create.service
  ```

- **plain crontab**, on a host that has cron:

  ```
  0 * * * *  /path/to/borg-server/snapshots/70-create-snapshot.sh >> /path/to/borg-server/log/snapshots.log 2>&1
  ```

Either way, unattended operation needs the `sudo` calls below to be passwordless — see "Privileges".

A run in progress is detected and refused (`flock` on `SNAPSHOT_BASE/.lock`), so a slow run never overlaps the next firing. Set `SNAPSHOT_DEBUG_LOG=/path/to/log` for a one-off debugging session to get one extra line per client (timestamp, directory, result, duration) beyond the normal stdout output; unset it again for routine operation.

## 5. Listing snapshots — `75-list-snapshots.sh`

```bash
./snapshots/75-list-snapshots.sh <client> [from] [to]
./snapshots/75-list-snapshots.sh user1-os1-pc1
./snapshots/75-list-snapshots.sh user1-os1-pc1 20260801T000000Z 20260901T000000Z
```

Lists one client's snapshot generations — timestamp and size (`du -sh`, the generation's own full size, not its marginal reflink cost — an operator scanning for an anomaly wants "this generation looks different from its neighbours," which needs the real number, not the aggregate storage bill). `<client>` is required and is **not** cross-checked against `clients.conf` or `HOST_REPO_BASE`, so a client since removed from either is still listable. `[from]`/`[to]` are optional, inclusive bounds in the same timestamp format — worth using on a client with a long history, since each generation shown is sized with a real `du -sh` walk.

Purely read-only reporting: no anomaly thresholds, no flagging. What counts as a normal size for one client says nothing about another, so interpreting the numbers is left to the operator on purpose. Needs no `sudo`.

## 6. Deleting snapshots — `76-delete-snapshots.sh`

```bash
./snapshots/76-delete-snapshots.sh <client> [from] [to]
```

Same arguments as `75-`. Omitting `[from]`/`[to]` deletes the client's **entire** snapshot history in one pass — the intended way to handle a compromised client, a client's own repository reset, or complete/residue-free client removal, without touching any other client's history (see "Layout" above).

Always shows exactly what is in scope first (calls `75-list-snapshots.sh` with the same arguments) before asking for confirmation. **The confirmation must be an exact, uppercase `Y`** — anything else, including lowercase `y`, aborts with nothing touched. This is deliberately stricter than the `[y/N]` prompts elsewhere in this project (`scripts/lib.sh`'s `quota_confirm`), because those guard reversible configuration changes and this guards an irreversible deletion of the only local copy this action is capable of destroying.

This is the "prune path" ROADMAP.md 11.5 calls the most dangerous code in the deployment: clearing the immutable flag and then deleting recursively, necessarily. It validates that every target it touches resolves inside `SNAPSHOT_BASE` before doing anything, rather than trusting its arguments. Unattended/scripted use is deliberately not supported — the confirmation step exists precisely because deletion here is meant to be a witnessed act, not something a cron job decides on its own. **An unattended, retention-driven prune (age-based, "keep the last N generations") does not exist and remains an open question** — if one is ever built, it will be a separate, non-interactive script; today, retention is a manual operator decision made with `75-`/`76-` directly.

## 7. Restoring the most recent snapshot — `77-restore-last-snapshot.sh`

```bash
./snapshots/77-restore-last-snapshot.sh <client>
```

Only argument: the client. No timestamp — the intended workflow is:

1. `75-list-snapshots.sh` to find the anomaly.
2. `76-delete-snapshots.sh` to remove every generation covering the compromise window.
3. `77-restore-last-snapshot.sh` — whatever is left as "last" after that step *is* the most recent known-good generation, by construction. Picking a timestamp by hand here would just be re-deriving what step 2 already established.

Shows the chosen generation's timestamp and size, and the current live repository's path, then the same exact-uppercase-`Y` confirmation as `76-`. On confirmation: **deletes the current live repository outright** (not quarantined — there is nowhere safe for a compromised client's tainted history to sit once `76-` has already removed the snapshots that covered it), recreates the directory, and re-applies the **same** XFS project id the old directory had (read before deletion, never a freshly allocated one and never a quota consulted from `clients.conf`) before copying the snapshot's content in — verified read back before any content is copied, so the restored directory ends up exactly as quota-protected as it was before.

What is restored: the repository's file content, its host ownership, and its XFS project id. What is **not** touched, because it was never affected: `clients.conf` and the client's SSH key — the directory never stopped existing, so nothing about the client's declaration needed to change.

**Refuses rather than attempting a from-scratch rebuild if the client has no existing live repository directory at all.** That is a different situation — the directory itself is gone, not merely out of date — and needs [`00-ssh-create-user.sh`](OPERATIONS.md#92-00-ssh-create-usersh) (new project id, an operator-chosen limit, a fresh `clients.conf` entry) instead; `04-reattach-client.sh` does not help here either, since it reattaches `clients.conf` to a directory that is already on disk, not recreate one that is not. Also refuses if the client's snapshot history is empty, or if its directory is found under more than one group (ambiguous, refuses to guess).

## 8. Privileges

Every script above runs as the normal operator user — **the same user that runs the container**, never root directly — with root confined to specific commands elevated internally via `sudo`:

| Script | Elevated commands | Why |
|---|---|---|
| `70-create-snapshot.sh` | `cp -a --reflink=always`, `chattr -R +i` | `cp` needs `CAP_CHOWN` to preserve the mapped-subuid ownership `scripts/lib.sh`'s `repo_dir_create` gives client directories; `chattr +i` needs `CAP_LINUX_IMMUTABLE`, which not even the file's owner has without it. |
| `76-delete-snapshots.sh` | `chattr -R -i`, `rm -rf` | Clearing the immutable flag alone is **not** sufficient to delete a snapshot: the reflinked files still carry the original client directories' restrictive mode and mapped-subuid ownership, so an unprivileged `rm -rf` fails with `Permission denied` — a different failure from the flag's `Operation not permitted` — even after the flag is gone. |
| `77-restore-last-snapshot.sh` | `rm -rf`, `cp -a --reflink=always`, plus (via `scripts/lib.sh`) `xfs_quota` and `podman unshare` | Same reasoning as above for the live directory, plus the same project-id/ownership mechanics `00-ssh-create-user.sh` uses. |
| `75-list-snapshots.sh` | none | Purely read-only; the directories it walks are mode 755 by construction, readable without root. |

**Interactive use needs nothing extra** — `sudo` simply prompts, the same as every other privileged script in this project. **Unattended use of `70-create-snapshot.sh` under the systemd timer or cron needs passwordless `sudo` for exactly `cp` and `chattr`**, since neither has a terminal to answer a password prompt on. This project deliberately does not write that sudoers entry for you — it is a host security decision for the operator to make, not something to drop into `/etc/sudoers.d/` silently. A starting point, narrower still if your `sudo` supports argument restrictions:

```
operator ALL=(root) NOPASSWD: /usr/bin/cp, /usr/sbin/chattr
```

`76-`/`77-` are interactive by design (the exact-`Y` confirmation, see above) and are never run unattended, so they need no passwordless entry — a human is present to authenticate `sudo` normally.

## 9. Rehearsing this before you need it

[Test Environment](TESTENV.md) Chapter 14 walks through a full compromised-client drill against a real deployment: cutting the client off, finding the right snapshot with `75-`, the quota-vs-disk-space distinction that trips people up, delete-then-restore ordering, and why the container has to be stopped first (open file handles keep a deleted file's quota allocated). Worth running once on a disposable VM ([Test Environment](TESTENV.md) Part B) before relying on any of this for real — see [Verification](VERIFICATION.md) for this project's general position on testing claimed guarantees against your own installation rather than taking them on faith.

## What this does not protect against

- **Media failure, filesystem corruption, or site loss.** A snapshot lives on the same storage as the origin. Offsite mirroring (ROADMAP.md 11.2) is the only answer here, and it is mandatory regardless of whether this tooling is in use.
- **An attacker holding root on this host.** Root can clear the immutable flag exactly as easily as it can destroy anything else on the filesystem. Protection against a root-level compromise is never local — it is the surviving copy sitting where this machine has no authority to destroy it, i.e. offsite mirroring again, and only if the remote target genuinely enforces append-only against this server.
- **Genuine tamper detection.** There is no structural comparison between generations — a "does an existing segment's size or hash disagree with what it was last time" check was designed, scrutinized, and dropped: append-only already prevents a compromised client from producing that signal in the first place, and the server's own mutating operations (`borg check --repair`, reclamation tooling) would trip the same signal a real problem would, making it noise rather than a diagnosis. See ROADMAP.md 11.5, "Snapshot comparison — considered and dropped". What this tooling gives the operator is fast, local rollback and a minimal safety net against their own mistakes — not a substitute for the broader protection offsite/offline copies provide.
