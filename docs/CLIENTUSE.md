> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> This guide covers everything on the **client** side: preparing a machine,
> initializing its repository, taking custody of the encryption key, and
> running backups against a server set up per
> [Server Installation](SERVERINSTALL.md).

---

# Client Usage

Nothing from this project is installed on a client. A client needs only
`borg` itself, an SSH key, and the repository URL its operator assigned.

Throughout, replace `<server>` with your server's hostname, `2222` with the
port your operator gave you, and `<repo>` with your assigned repository URL:

```
ssh://borg@<server>:2222/repo/OWN/user1-os1-pc1
```

> **The one thing that cannot be undone:** if you lose your encryption key or
> its passphrase, your backups are gone. Permanently, with no recourse — the
> server holds no key and no escrow, by design. Chapter 3 is not optional
> reading.

---

## 1. Prepare the client

> **BorgBackup 2.x is NOT supported by this server. Install a 1.x version.**
> Borg 2 writes a different repository format, has never been run against this
> server, and is expected to be refused rather than to work. Supported and
> tested: **1.2.x** and **1.4.x**. See
> [Supported BorgBackup versions](../README.md#supported-borgbackup-versions-1x-only)
> for the authoritative statement.

Install BorgBackup from the 1.x line — your distribution's package is normally
the right one — and confirm what you actually got before going any further:

```bash
borg --version        # must report 1.x, e.g. "borg 1.2.8"
```

Then generate a dedicated key pair for backups — not the key you use for
anything else:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/borg_backup -C "user1-os1-pc1"
```

Send **only** `~/.ssh/borg_backup.pub` to your operator. The private half
never leaves this machine.

Teach SSH about the server so you do not have to repeat the details:

```
# ~/.ssh/config
Host borgserver
    HostName <server>
    Port 2222
    User borg
    IdentityFile ~/.ssh/borg_backup
    IdentitiesOnly yes
```

Your repository URL then shortens to `ssh://borgserver/repo/OWN/user1-os1-pc1`.

### Verify the server's host key on first connection

The server is designed to sit exposed to the internet, so the first
connection is the one moment you are vulnerable to being pointed at the wrong
machine. Ask your operator for the server's host key fingerprint through a
channel that is not this SSH connection, and compare it against what your
client shows you the first time it connects. Accepting it blindly forfeits a
guarantee nothing later can restore.

---

## 2. Check that you can reach the server

Before initializing anything:

```bash
ssh borgserver info
```

```
[server]
name: backup01.example.com
location: Frankfurt, DE
contact: admin@example.com

[software]
version: 0.1.0-beta.23
source: https://github.com/RaykHoefemann/hardened-borg-server

[client]
user: user1-os1-pc1
quota: 50G

Used: 0 KiB of 50.0 GiB (0%)
```

This works before your repository exists and confirms three things at once:
your key is installed, the forced command is in effect, and your quota is
enforced at the filesystem level. If `Used:` reports the size of a whole disk
rather than your quota, tell your operator — per-client limits are not active
(see [Verification](VERIFICATION.md), test 5).

If instead you get a shell prompt, stop and report it. That is a serious
misconfiguration, not a convenience.

---

## 3. Initialize the repository — and take custody of the key

### 3.1. Initialize

The server accepts **only client-held keyfile encryption** and verifies it on
every connection:

```bash
borg init --encryption=keyfile-blake2 ssh://borgserver/repo/OWN/user1-os1-pc1
```

`keyfile` is also accepted. `repokey`, `repokey-blake2`, `authenticated` and
`none` are **rejected** — they either store key material on the server or no
encryption at all.

A repository created with the wrong mode will not be caught during `init`
itself: the directory is still empty at that point, so there is nothing for
the server to inspect. It is refused on the **next** connection, with one of:

```
DENY: repo stores key material server-side (not keyfile mode)
DENY: not a keyfile repository (key type 0x03); only client-held keyfile encryption is permitted
```

If you see either, you initialized with the wrong mode. Ask your operator to
clear the repository directory and start again — you cannot delete it
yourself (Chapter 4).

### 3.2. Export the key and store it offline — now, not later

In keyfile mode the key exists in exactly one place: `~/.config/borg/keys/`
on this machine. It is **not** in the repository, and **not** on the server.
Lose this machine without a copy, and the backups it made become permanently
unreadable ciphertext.

```bash
borg key export ssh://borgserver/repo/OWN/user1-os1-pc1 /secure/offline/user1-os1-pc1.borgkey
```

Then, and this is the part most often skipped:

- Store the exported key **somewhere other than the machine it protects.** A
  key that only exists on the laptop being backed up dies with the laptop.
- Store the **passphrase separately from the key file.** The export is itself
  passphrase-protected; both halves are required, and keeping them together
  defeats the point of protecting either.
- Prefer at least two independent locations — a password manager with its own
  backup, a hardware token, a printed copy in a safe.

Verify that the copy actually works before you rely on it, on a different
machine if you can:

```bash
borg key import ssh://borgserver/repo/OWN/user1-os1-pc1 /secure/offline/user1-os1-pc1.borgkey
```

An untested backup of the key is a guess. See
[Best Practices](BEST_PRACTICES.md) Chapter 2.1 for the full requirement.

---

## 4. What "append-only" means for you

This is the part that behaves differently from every other Borg server you
may have used, and it is worth understanding *before* it surprises you.

The server enforces append-only on every connection. You can write; you
cannot remove.

**`borg delete` and `borg prune` will appear to succeed.** The archive stops
appearing in `borg list`, no error is printed, the exit status is zero — and
not one byte is freed. The data stays on the server, and your quota usage
does not drop. `borg compact` likewise does nothing.

Three consequences follow:

- **Retention policies on the client are pointless here.** Running `borg
  prune` on a schedule only makes archives invisible to you while the server
  keeps them. Storage is bounded by your quota, not by retention (see
  [Operations](OPERATIONS.md) Chapter 10).
- **Your `borg info` will drift from your actual usage.** It reports the
  archives you can currently see; the `info` channel reports what the
  filesystem says you occupy. After any delete, the second number is the
  honest one.
- **A deletion you regret needs your operator.** The data is still there and
  can be restored by rolling the repository back — but that is a manual,
  two-party procedure ([Recovery](RECOVERY.md) Section 1).

> **If you delete something by mistake, stop backing up immediately.** The
> rollback discards everything written after the deletion, so every backup
> your timer makes in the meantime is one more thing lost when the repository
> is restored. Disable the timer first, contact your operator second.

---

## 5. Run backups

```bash
export BORG_REPO=ssh://borgserver/repo/OWN/user1-os1-pc1

borg create --stats --compression zstd \
    ::'{hostname}-{now:%Y-%m-%dT%H:%M:%S}' \
    /home /etc
```

Exclude what you cannot use or do not want stored — caches, build output,
virtual machine images that change entirely on every run:

```bash
borg create --stats --compression zstd \
    --exclude-caches \
    --exclude '/home/*/.cache' \
    --exclude '/var/lib/containers' \
    ::'{hostname}-{now:%Y-%m-%dT%H:%M:%S}' \
    /home /etc
```

### Automating it

For unattended runs, Borg needs the passphrase without a terminal. Do not
embed it in the script — read it from a file only your backup user can open:

```bash
chmod 600 ~/.config/borg/passphrase
export BORG_PASSCOMMAND='cat /home/user/.config/borg/passphrase'
```

A minimal systemd timer on the client:

```ini
# ~/.config/systemd/user/borg-backup.service
[Unit]
Description=Borg backup

[Service]
Type=oneshot
Environment=BORG_REPO=ssh://borgserver/repo/OWN/user1-os1-pc1
Environment=BORG_PASSCOMMAND=cat %h/.config/borg/passphrase
ExecStart=/usr/bin/borg create --compression zstd --exclude-caches ::{hostname}-{now:%%Y-%%m-%%dT%%H:%%M:%%S} %h /etc
```

```ini
# ~/.config/systemd/user/borg-backup.timer
[Unit]
Description=Daily Borg backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now borg-backup.timer
```

**Check that it is actually running.** A backup timer that fails silently is
the classic way to discover, at the worst possible moment, that there is
nothing to restore from:

```bash
systemctl --user list-timers borg-backup.timer
journalctl --user -u borg-backup.service --since '7 days ago'
```

---

## 6. Watch your quota

```bash
ssh borgserver info
```

Because nothing is ever deleted, your usage only grows. Watch it rather than
waiting for a failure, and ask your operator to raise the limit when you
approach the ceiling — roughly 80% is a sensible moment to act.

There is a concrete reason not to leave this to chance. When a backup hits
the quota it aborts partway through, and the data it had already written
cannot be reclaimed — append-only forbids removing it, and raising the quota
afterwards does not recover it. A timer that keeps firing against a full
quota therefore makes the situation *worse* with every run rather than
leaving it unchanged (see [Operations](OPERATIONS.md) Chapter 10.4).

If your backups start failing on space, disable the timer until the quota has
been raised.

---

## 7. Restore

Restores are entirely client-side. The server serves the repository; your key
does the rest.

```bash
borg list ::                                  # which archives exist
borg list ::archive-name                      # what is in one
borg extract ::archive-name                   # restore into the current directory
borg extract ::archive-name home/user/notes   # restore a subset
```

To look before you leap:

```bash
borg mount ::archive-name /mnt/restore
# ... browse ...
borg umount /mnt/restore
```

### Onto a rebuilt machine

A reinstalled machine has no key, so restore that first from the offline copy
you made in Chapter 3.2:

```bash
borg key import ssh://borgserver/repo/OWN/user1-os1-pc1 /secure/offline/user1-os1-pc1.borgkey
borg list ::
```

This is a purely local operation between you and your own offline copy. No
key material is ever sent to the server or to your operator.

---

## 8. Verify that your backups are real

A backup you have never restored is a hypothesis.

**Restore-test on a schedule**, not on suspicion. Extract a few real files
into a scratch directory and compare them against the originals. Do it often
enough that the procedure is familiar before you need it under pressure
([Best Practices](BEST_PRACTICES.md) Chapter 7).

**Verify archive contents periodically** — and note that only you can:

```bash
borg check --verify-data ::
```

This re-reads every chunk and re-checks its authentication tag, which
requires the repository key. The server cannot do it and must not be able to:
it holds no key, which is exactly the property that makes a server compromise
survivable. Repository-*structure* checks are the operator's side of this
split; content verification is permanently yours
([Design](DESIGN.md) Chapter 3.3).

`--verify-data` reads the whole repository, so schedule it accordingly —
monthly or quarterly is more realistic than nightly for a large repository.

---

## What your operator cannot do for you

| Situation | Who can act |
|---|---|
| Lost key or passphrase | **Nobody.** The backups are unrecoverable |
| Accidental archive deletion | Operator, via rollback — act fast ([Recovery](RECOVERY.md) §1) |
| Quota exhausted | Operator raises it; you stop the timer meanwhile |
| Repository initialized with the wrong encryption mode | Operator clears the directory; you re-initialize |
| Verifying archive contents | **Only you** — the server has no key |
