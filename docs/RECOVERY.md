> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)

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
| Operator destroyed repository data on the host | [5](#5-operator-side-data-loss-on-the-server) | Depends — see section |
| Storage volume lost entirely | [6](#6-total-loss-of-the-storage-volume) | Only from offsite |
| Getting data back from the offsite mirror | [7](#7-recovering-from-the-offsite-mirror) | Not implemented yet |

---

## 1. A client deleted an archive

*Verified against Borg 1.2.8.*

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

If a snapshot mechanism is available (Roadmap 11.5), take a named snapshot before this instead of — or in addition to — the quarantine directory.

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

*Verified against Borg 1.2.8.*

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

Accidental `rm -rf` against the storage volume, a botched maintenance command, or destructive software running on the host.

**Current state: there is no local recovery path.** Snapshots of the storage volume are Roadmap item 11.5 and are not implemented. Until they are, the options are, in order of preference:

1. **The clients still hold their source data.** For repositories whose clients are healthy, the fastest correct answer is often to let the clients re-upload. Archive history before the incident is lost, but current data is not.
2. **The offsite mirror** — Roadmap 11.2, not implemented (see section 7).
3. Nothing else. Repository data destroyed on the host is destroyed.

The append-only guarantee does **not** help here: it constrains what clients may do over the protocol, not what the operator or a process with host access can do to the files directly.

Once 11.5 exists, this section becomes a rollback procedure measured in seconds. Until then, treat host-side destructive commands against `HOST_REPO_BASE` as unrecoverable and act accordingly.

---

## 6. Total loss of the storage volume

Disk failure, filesystem corruption, or loss of the machine.

Snapshots would not help even once implemented — they live on the same storage as the origin (Roadmap 11.5). This is precisely and exclusively what the offsite copy is for.

With no offsite copy in place, repositories are lost and the clients' own source data is all that remains.

---

## 7. Recovering from the offsite mirror

**Not implemented.** Mirroring this server's own repositories to a foreign backup server is Roadmap item 11.2.

Two properties of that design determine what recovery will look like, and both are worth knowing in advance because they shape what an operator should arrange *now*:

- The mirrored repository is a byte-for-byte replica, so a client's key opens it exactly as it opens the original. Recovery does not depend on this server existing at all — a client with its key can restore directly from the foreign server.
- The foreign target must enforce append-only against this server (Roadmap 11.2). Without that, a compromise of this host reaches the offsite copy through the replication credentials, and section 5 and section 6 both lose their answer.

Until 11.2 ships, an operator wanting offsite redundancy has to arrange it outside this project.

---

## What has no recovery path

Worth stating in one place, because these are the cases where preparation is the only defence:

| Loss | Why nothing can be done |
|---|---|
| Client key or passphrase | No key material exists server-side, by design |
| Repository data destroyed on the host, no snapshot, no mirror | Nothing else holds a copy |
| Storage volume lost, no offsite copy | Same |

Everything else in this document is recoverable.
