> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> This guide covers everything on the **client** side: preparing a machine,
> initializing its repository, taking custody of the encryption key, and
> running backups against a server set up per
> [Server Installation](SERVERINSTALL.md).

---

# Client Usage

> ## 🚧 This document is a stub
>
> The sections below are an outline only — none of them are written yet.
> [SERVERINSTALL.md](SERVERINSTALL.md) already links here in three places
> (client key generation, client-side setup, and the "What's next" section),
> so the file exists to keep those references valid.
>
> Until it is filled in, the authoritative sources for each topic are the
> documents cross-referenced under each heading. Nothing here should be
> treated as instructions yet.

---

## 1. Prerequisites on the client

*To be written.* Borg version requirements and the SSH keypair the client
generates for itself — the public half is what the operator feeds to
`01-ssh-set-user-key.sh` (see [Server Installation](SERVERINSTALL.md),
step 9). The private key never leaves the client.

## 2. Initializing the repository

*To be written.* Must use a client-held keyfile mode; the server verifies
this on every connection and refuses anything else before the Borg session
starts. See [Best Practices](BEST_PRACTICES.md) Chapter 2 for the mandatory
requirement and [Design](DESIGN.md) Chapter 2.1.2 for why it is enforced
server-side rather than left to client discipline.

## 3. Key custody — the part that cannot be undone

*To be written.* Exporting the key, storing it offline and separately from
the machine it protects, and retaining the passphrase independently. The
server holds no key material and has no escrow or recovery path: a lost key
is equivalent to total data loss.

Source material: [Best Practices](BEST_PRACTICES.md) Chapter 2.1 — this is
the single most consequential section for a client, and this chapter should
not soften it.

## 4. Running backups

*To be written.* Invocation, useful exclusions, scheduling via a systemd
timer on the client, and what append-only means in practice for the client's
own workflow — in particular that `borg delete` and `borg prune` appear to
succeed while the data is retained server-side (see
[Recovery](RECOVERY.md) Section 1).

## 5. Checking quota and server status

*To be written.* The `info` channel is the only server-side interface a
client has besides `borg serve`:

```bash
ssh -p 2222 borg@<server-host> info
```

See [Operations](OPERATIONS.md) Chapter 8 for what it reports, and
[Best Practices](BEST_PRACTICES.md) Chapter 6 for using it to confirm that
per-client quota enforcement is actually active.

## 6. Restoring data

*To be written.* Routine restores, browsing an archive before restoring, and
restoring onto a rebuilt machine via `borg key import`.

Already covered in [Recovery](RECOVERY.md) Section 4 — this chapter should
reference it rather than duplicate it.

## 7. Verifying that backups actually work

*To be written.* Regular restore testing, and the deep, content-level
integrity check (`borg check --verify-data`) that only the key holder can
perform. The server can validate repository structure but never archive
contents, so this responsibility is permanently client-side
([Roadmap](../ROADMAP.md) 11.3).

See [Best Practices](BEST_PRACTICES.md) Chapter 7.
