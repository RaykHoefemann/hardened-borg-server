> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)

---

# RECOVERY — hardened-borg-server

Incident handling for things that went wrong: accidental deletion, operator error, data loss, and getting data back out again.

Each scenario states **what actually happened**, **what is still intact**, **what to do**, and **what the fix costs**. Where a procedure has been verified against a real Borg version, that is noted; where it depends on a feature that is not implemented yet, that is marked explicitly rather than described as if it worked.

---

## ⏱️ Before anything else: stop the clock

For every scenario involving accidental deletion, the first action is **not** a repair — it is preventing the next backup run from the affected client.

Recovery from an accidental deletion works by rolling the repository back to an earlier transaction, and that rollback is **all-or-nothing**: everything written after the target transaction is discarded, including every legitimate backup made since the deletion. A client that keeps backing up on a schedule is actively narrowing the window in which a clean recovery is still cheap.

Disable the client's timer, or remove its key from `clients.conf` and restart the container, before touching anything else.

---

## Quick index

| Situation | Section | Recoverable? |
|---|---|---|
| Client deleted an archive | [1](#1-a-client-deleted-an-archive) | Yes — operator rollback |
| Client tried to delete its whole repository | [2](#2-a-client-tried-to-delete-its-whole-repository) | Nothing to do — blocked by design |
| Client lost its encryption key | [3](#3-a-client-lost-its-key) | **No** — permanent loss |
| Client needs its data back (normal restore) | [4](#4-a-client-restoring-its-own-data) | Yes — client-side, routine |
| Operator destroyed repository data on the host | [5](#5-operator-side-data-loss-on-the-server) | Yes, in seconds, if a snapshot predates the incident — see section |
| Storage volume lost entirely | [6](#6-total-loss-of-the-storage-volume) | Only from a client-side offsite copy |
| Getting data back from an offsite copy | [7](#7-recovering-from-an-offsite-copy) | Client-side only — this server does not mirror |
| Client cannot initialize — `DENY: no repository segments found` | — | Nothing lost — not a recovery case, see [Operations](OPERATIONS.md) Chapter 9.12 |

The last row is a signpost rather than a section. An interrupted `borg init` leaves a repository directory the server refuses on every later attempt, but it holds no backup and nothing needs recovering — the repair is to clear the directory's contents, which Operations Chapter 9.12 describes step by step. It is listed here because that is not obvious from the client's report, and because clearing it the wrong way (removing the directory instead of its contents) silently drops the client's XFS project quota.

---

## 1. A client deleted an archive

*Verified against Borg 1.2.8 and 1.4.0.*

### What actually happened

Nothing was deleted. Under the enforced `--append-only` (Design, Chapter 1.2.4), a client's `borg delete` only **appends** a new transaction containing a manifest that no longer references the archive. Every segment file is still on disk.

This is why the deletion looks completely successful to the client: `borg delete` exits 0, the archive disappears from `borg list`, and no error appears anywhere. The data is intact regardless.

### What the operator can see

Very little, and this is by design — with client-held keyfile encryption the server cannot read archive names or contents. Searching the segment files for archive names returns nothing.

The operator's only plaintext handle is the repository's `transactions` file:

```
transaction  5, UTC time 2026-08-02T11:08:58.340497
transaction  9, UTC time 2026-08-02T11:08:59.683589
transaction 13, UTC time 2026-08-02T11:09:01.046882
transaction 17, UTC time 2026-08-02T11:09:02.438020
```

Transaction numbers and UTC timestamps. Nothing about *what* any transaction did.

**Recovery is therefore necessarily a two-party operation.** The operator has timestamps without meaning; the client has meaning without access. The client must report *when* it deleted; the operator picks the last transaction **before** that moment as the rollback target. Neither side can do this alone — which also means neither side can silently rewrite history.

> **Caveat:** the transaction log only records transactions made while append-only was active. In this project the flag is fixed in `borg-wrapper.sh` for every connection, so the log is complete from repository creation onward. A repository that ever ran without it has a gap and may have no clean target.

### The rollback

Using the log above: the deletion is transaction `17`, so the target is `13`.

**Move the files aside, never delete them.** This makes the entire operation reversible — if the wrong transaction was chosen, move everything back and try another.

```bash
cd <repo>
mkdir -p ../quarantine

# every segment above the target transaction
for s in $(ls data/0); do [ "$s" -gt 13 ] && mv "data/0/$s" ../quarantine/; done

# index/hints/integrity belonging to the deletion transaction
mv index.17 hints.17 integrity.17 ../quarantine/

# drop the deletion from the log
sed -i '/transaction 17,/d' transactions
```

Run `./snapshots/70-create-snapshot.sh` before this instead of — or in addition to — the quarantine directory: a proper, immutable snapshot rather than the improvisation above (see [Snapshots](SNAPSHOTS.md)).

### Operator-side verification

```bash
borg check --repository-only <repo>
```

This runs **without any key** and must exit 0. It validates the repository's own structures, which is exactly the class of check the server is permitted to perform (Design, Chapter 2.1).

**What it does not tell you:** `borg check` validates consistency, not intent. A rollback that went too far produces a perfectly consistent repository that has silently discarded legitimate backups. Structural success is a necessary condition, never the acceptance criterion.

### Client-side cleanup — two directories, not one

The client will otherwise fail with:

```
Cache is newer than repository - do you have multiple, independently updated repos with same ID?
```

`borg delete --cache-only` is **not sufficient** — it exits 0 and the error persists, because Borg also keeps manifest replay-protection state in its security directory. Both must go:

```bash
rm -rf ~/.cache/borg/<REPO-ID> ~/.config/borg/security/<REPO-ID>
```

The repository ID is the `id` value in the repository's `config` file, and is shown by `borg info`.

### Acceptance

The only valid confirmation is the client's own view:

```bash
borg list <repo>     # the deleted archive must be listed again
borg extract <repo>::<archive>
```

Only after the client confirms may the quarantine directory be deleted.

### What it cost

Every backup written after the deletion. If the client deleted on Monday and this runs on Friday, Tuesday through Thursday are gone — which is what the "stop the clock" rule at the top of this document exists to prevent.

---

## 2. A client tried to delete its whole repository

*Verified against Borg 1.2.8 and 1.4.0.*

**Nothing to do — the attempt fails.** `borg delete --force <repository>` against an append-only repository aborts with an error and leaves the repository and all its segments intact. The same command against a repository without append-only destroys it completely.

This is one of the guarantees the forced command exists to provide, and it holds without any operator involvement.

If the repository *did* disappear, append-only was not in effect for that connection — treat it as a configuration incident: verify that every line in `authorized_keys` carries the `command="/borg-wrapper.sh …"` prefix that `build_authorized_keys.sh` generates, since a key without it is exempt from every guarantee in this document.

---

## 3. A client lost its key

**There is no recovery path. The backups are permanently lost.**

The server holds no key material, no escrow, and no master key — by design (Design, Chapter 2.1.1). This is not a limitation to work around; it is the property that makes a full server compromise survivable.

Both the exported key **and** its passphrase are required. Losing either is equivalent to losing both.

See Best Practices, Chapter 2.1 for the custody requirements that prevent this situation. There is nothing to do afterwards.

---

## 4. A client restoring its own data

The routine case, and the one that should be practised regularly rather than discovered during an incident (Best Practices, Chapter 7).

```bash
borg list <repo>                         # find the archive
borg extract <repo>::<archive>           # restore into the current directory
borg extract <repo>::<archive> path/to   # restore a subset
borg mount <repo>::<archive> /mnt/point  # browse before restoring
```

Requires the client's key and passphrase. Nothing on the server participates beyond serving the repository — decryption happens entirely on the client.

### Restoring onto a rebuilt or replacement machine

In keyfile mode the key exists only in the client's own Borg key store (`~/.config/borg/keys/`) — never inside the repository, never on the server. A reinstalled or replacement machine therefore starts with no key and cannot read its own backups until the client puts its key back:

```bash
borg key import <repo> /secure/offline/<client>.borgkey
```

This is the counterpart to the `borg key export` that Best Practices Chapter 2.1 already requires, and it is **entirely client-side**: the client reads its own offline copy back into its own key store. No key material is handed to the server, to the operator, or to a mirror partner at any point — that would contradict the entire privacy model (Design, Chapter 2.1).

The passphrase is needed in addition to the key file, since the export is itself passphrase-protected. Without this step the mandated export would serve no purpose: it exists precisely so that losing the machine does not also mean losing the backups.

---

## 5. Operator-side data loss on the server

Accidental `rm -rf` against a client's repository directory, a botched maintenance command, or destructive software running on the host — anything that destroys data under `HOST_REPO_BASE` without also reaching the rest of the storage volume (a command destructive enough for that is section 6, not this one).

**If a snapshot predates the incident, this is a local rollback measured in seconds.** See [Snapshots](SNAPSHOTS.md) for the full mechanism; the short version:

1. `./snapshots/75-list-snapshots.sh <client>` — find the affected client's most recent generation from before the incident.
2. If the cause was a compromised client rather than plain operator error, `./snapshots/76-delete-snapshots.sh <client>` first, to remove any generation that might already carry tainted data — a snapshot of already-compromised data is not a safe rollback point.
3. `./snapshots/77-restore-last-snapshot.sh <client>` — restores content, host ownership, the XFS project id and the SELinux context in one step, verified before use. If it prints a warning that it could not re-apply the SELinux context and the client then reports a lock/permission error, run `./scripts/92-container-restart.sh` once (it relabels `/repo`).

**If no snapshot predates the incident** — the tooling was never set up, the incident happened before that day's scheduled snapshot ran, or it reached `SNAPSHOT_BASE` itself (see the caveat below) — the options fall back to, in order of preference:

1. **The clients still hold their source data.** For repositories whose clients are healthy, the fastest correct answer is often to let the clients re-upload. Archive history before the incident is lost, but current data is not.
2. **A client-side offsite copy**, if the affected client keeps one (see section 7). This server does not mirror its own repositories — [Design](../docs/DESIGN.md) Chapter 4.6.
3. Nothing else. Repository data destroyed on the host, with nothing to restore it from, is destroyed.

The append-only guarantee does **not** help here either way: it constrains what clients may do over the protocol, not what the operator or a process with host access can do to the files directly. Snapshots are what closes that specific gap — but only within their own boundary: a snapshot lives on the **same physical storage** as the data it protects, as a sibling directory (`SNAPSHOT_BASE`) next to `HOST_REPO_BASE`, not a second copy anywhere else. A destructive command scoped to one client's directory leaves the snapshots untouched; one that reaches the whole storage volume takes them down with it — see section 6.

---

## 6. Total loss of the storage volume

Disk failure, filesystem corruption, or loss of the machine — anything that takes the whole storage volume with it, `HOST_REPO_BASE` and `SNAPSHOT_BASE` (and every snapshot it holds) alike.

Snapshots do not help here, by design — they live on the same storage as the origin (see [Snapshots](SNAPSHOTS.md), "What this does not protect against"). This is precisely and exclusively what an offsite copy is for — and, with server-side mirroring dropped ([Design](../docs/DESIGN.md) Chapter 4.6), that copy is one the client keeps, or the operator's own offline export stored elsewhere.

With no offsite copy in place, repositories are lost and the clients' own source data is all that remains.

---

## 7. Recovering from an offsite copy

**This server does not create one.** Mirroring its own hosted repositories to a foreign backup server was planned and has been **dropped** — the reasoning is in [Design](../docs/DESIGN.md) Chapter 4.6: the server holds no repository key, so it could only ever ship an opaque file-level copy, and no file-copy transport gives the append-only guarantee such a copy would need to survive a compromise of this host.

Offsite redundancy is therefore the **client's** responsibility, and recovery from it is entirely client-side:

- A client that keeps its own independent offsite copy — a second `borg create` target, or `borg serve` against a foreign server it trusts — restores from it with its own key, exactly as from any repository. This server does not need to exist for that recovery to work.
- The operator's own **offline export** (Roadmap 11.2, the manual removable-media helper) is a copy of the hosted repositories (`HOST_REPO_BASE/`) that the operator physically stores off-site. It restores those repositories after a total loss, but every one of them is still ciphertext: each client needs its own key and passphrase to read its own repository back.

An operator wanting offsite redundancy for the hosted data has to arrange it outside this project — or rely on clients keeping their own.

---

## What has no recovery path

Worth stating in one place, because these are the cases where preparation is the only defence:

| Loss | Why nothing can be done |
|---|---|
| Client key or passphrase | No key material exists server-side, by design |
| Repository data destroyed on the host, no snapshot, no offsite copy | Nothing else holds a copy |
| Storage volume lost, no offsite copy (client-side, or the operator's offline export) | Same |

Everything else in this document is recoverable.
