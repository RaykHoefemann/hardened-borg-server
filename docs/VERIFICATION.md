> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)

---

# Verification

**Do not trust this project's claims. Test them.**

Every security property described in [Design](DESIGN.md) and required by
[Best Practices](BEST_PRACTICES.md) is stated as a fact somewhere in this
documentation. A reader has no reason to accept any of it on faith, and a
deployment can be misconfigured in ways that leave every document still
reading correctly while the guarantee is silently absent.

This document turns each claim into a procedure you run against **your own
installation**, with an explicit pass criterion. Work through it after a new
installation, after changing anything about the host or the container, and
periodically thereafter.

## How to read a test

Each entry states:

- **Claim** — what the documentation asserts, and where
- **Why it matters** — what an attacker or an accident gains if it is false
- **Run** — the exact commands
- **Pass** — what a correct installation produces
- **Fail** — what the observed output means and what to do

Status markers:

- ✅ **Verified** — the underlying behaviour has been reproduced against
  Borg 1.2.8. The test still has to be run against *your* deployment; what is
  confirmed is that the test itself discriminates correctly.
- ⚠️ **Unverified** — the procedure follows from the implementation but has
  not been executed end to end against a live instance. Treat an unexpected
  result as a possible flaw in the test, not only in the deployment, and
  please report it.

## Before you start

You need a client machine with an SSH key already provisioned on the server
(see [Server Installation](SERVERINSTALL.md), step 9), and a willingness to
write a small amount of throwaway data into the repository. Test 0
additionally needs the GitHub CLI (`gh`), authenticated — and is best run
*before* the installation, since its whole purpose is to decide whether the
image should be run at all.

Several tests leave roughly 1 MB behind permanently — under a correctly
functioning server you cannot delete it, which is precisely the point.

Throughout, replace `<server>` with your server host, `2222` with your
configured `SSH_PORT`, and `<repo>` with the repository URL assigned to the
client, e.g. `ssh://borg@<server>:2222/repo/OWN/user1-os1-pc1`.

---

## 0. The image was built from this source ⚠️

**Run this before the others.** Every test below examines the behaviour of a
running container. If that container was not built from the source you
reviewed, all of them verify the wrong artifact — correctly, and pointlessly.
This is the only test whose failure invalidates the entire rest of the page.

**Claim** — each published image carries a Sigstore build-provenance
attestation, produced by this repository's own workflow
(`.github/workflows/docker.yml`), tying the image digest to the commit and
workflow run that built it.

**Why it matters** — the documentation, the wrapper's source, and this test
page are all public and auditable. The thing you actually run is a binary blob
pulled from a registry. Without this check, reviewing the source proves
nothing about what is executing.

**Run**

```bash
gh attestation verify \
  oci://ghcr.io/raykhoefemann/hardened-borg-server:<tag> \
  --repo RaykHoefemann/hardened-borg-server
```

**Pass** — verification succeeds, and the attestation names **this**
repository and the `.github/workflows/docker.yml` workflow, at the git tag
matching the image tag you pulled.

**Fail** — no attestation found, verification errors, or an attestation naming
a different repository or workflow. Do not run the image; obtain it again from
the documented location and re-check.

**Where the attestation lives:** it is uploaded to GitHub's Attestations API
and deliberately *not* pushed into the registry, so `gh attestation verify`
finds it by default. Tools that verify strictly against the OCI registry
(`cosign` against the registry, Kyverno or Sigstore policy-controller
admission checks) will **not** find it and will report its absence — that is a
property of where it is stored, not evidence that it is missing.

**Then pin what you verified.** Tags are mutable: verifying
`:0.1.0-beta.17` today says nothing about what that tag points to next month.
Resolve it once and pin the digest in `scripts/config.sh`:

```bash
podman pull ghcr.io/raykhoefemann/hardened-borg-server:<tag>
podman image inspect --format '{{.Digest}}' ghcr.io/raykhoefemann/hardened-borg-server:<tag>
```

```sh
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
```

A pinned digest is the only form in which the result of this test stays true
over time, and it makes every later upgrade a deliberate act.

> Marked unverified because it was derived from the published workflow rather
> than executed against a live tag. If you run it, the output is worth
> reporting back.

---

> **Tests 1, 2 and 8 are also checked automatically.** `tests/wrapper-gating.sh`
> drives `borg-wrapper.sh` directly against real Borg repositories and runs on
> every push — 27 cases covering path validation, default-deny gating,
> injected commands, and the keyfile-only encryption policy. It asserts, among
> other things, that the exec line is *exactly* the wrapper's own invocation,
> so no client-supplied argument can widen `--restrict-to-path` or disable
> `--append-only`.
>
> That suite tests the code. The tests below test **your deployment** — that
> the code is what is actually running, wired up as intended. Neither replaces
> the other, and you can run the suite yourself against a checkout.

## 1. No interactive shell ⚠️

**Claim** — [Design](DESIGN.md) Chapter 1.2: a client key grants no shell
access. Enforced by the forced command in `authorized_keys` plus `restrict`.

**Why it matters** — a shell on the server would make every other guarantee
in this document irrelevant.

**Run**

```bash
ssh -p 2222 borg@<server>
```

**Pass**

```
DENY: only 'borg serve' and 'info' are permitted
```

The connection closes immediately. No prompt, no banner, no shell.

**Fail** — any prompt, or any output resembling a shell, means the forced
command is not in effect for this key. Stop and go to test 3.

---

## 2. Default-deny on commands ⚠️

**Claim** — `borg-wrapper.sh` gates on `$SSH_ORIGINAL_COMMAND` and permits
exactly two things: the literal string `info`, and a `borg serve` invocation.
Everything else is rejected.

**Why it matters** — a key that can run arbitrary commands can read other
clients' repositories, alter quotas, or disable the wrapper itself.

**Run**

```bash
ssh -p 2222 borg@<server> "ls /"
ssh -p 2222 borg@<server> "cat /etc/passwd"
ssh -p 2222 borg@<server> "borg serve; rm -rf /"
ssh -p 2222 borg@<server> info
```

**Pass** — the first three produce:

```
DENY: only 'borg serve' and 'info' are permitted
```

The fourth returns the info channel output (server contact details, your
quota, your usage). Note the third case: it begins with `borg serve` but does
not match the permitted patterns, and is rejected.

**Fail** — any command that executes is a complete bypass of the security
model. Treat as an incident: the wrapper is not being invoked, or has been
modified.

---

## 3. Every key is bound to the forced command ⚠️

**Claim** — [Operations](OPERATIONS.md): `build_authorized_keys.sh` generates
every entry as `command="/borg-wrapper.sh <repo>",restrict <key>`.

**Why it matters** — this is the single point on which every other guarantee
depends. One line without the prefix exempts that key from append-only, path
restriction, encryption enforcement and command gating simultaneously — and
nothing else in the system would look wrong.

**Run** (on the host)

```bash
podman exec borg-server cat /home/borg/.ssh/authorized_keys \
  | grep -vE '^\s*#' | grep -vE '^\s*$' \
  | grep -cv '^command="/borg-wrapper\.sh '
```

**Pass** — output is `0`. Every non-comment, non-empty line carries the
prefix.

Also confirm the count matches your client list:

```bash
podman exec borg-server grep -c '^command=' /home/borg/.ssh/authorized_keys
grep -cvE '^\s*(#|$)' config/clients.conf
```

**Fail** — any nonzero count in the first command identifies keys that bypass
the wrapper entirely. Remove them, regenerate the file by restarting the
container, and re-run tests 1 and 2.

> The file is regenerated from `clients.conf` on every container start and
> swapped atomically, so a manually added line does not survive a restart.
> That limits exposure; it does not remove the need to check.

---

## 4. The container runs rootless ⚠️

**Claim** — [Best Practices](BEST_PRACTICES.md) Chapter 1: rootless Podman is
mandatory, not a recommendation.

**Why it matters** — rootless execution is what makes a container escape land
on an unprivileged user rather than on host root. It is also why a
compromised container cannot clear an immutable flag: it holds no
`CAP_LINUX_IMMUTABLE`.

**Run** (on the host, as the service user)

```bash
podman info --format '{{.Host.Security.Rootless}}'
systemctl --user status container-borg-server.service | head -3
ps -o user=,pid=,cmd= -C conmon
```

**Pass** — `true`; the unit is a **user** service; the container processes
belong to your unprivileged service user, never to `root`.

**Fail** — `false`, or processes owned by root, means the deployment is not
security-hardened in the sense this project uses the term, regardless of
anything else being correct.

---

## 5. Quota is enforcing, not merely accounting ⚠️

**Claim** — [Best Practices](BEST_PRACTICES.md) Chapter 1 and Chapter 6:
repository storage on XFS mounted with **enforcing** `prjquota`.
`pqnoenforce` (accounting only) does not satisfy this.

**Why it matters** — with accounting only, a single client can fill the
volume and deny service to every other client. The limits shown to clients
would be advisory fiction.

**Run** (on the host)

```bash
findmnt -no OPTIONS /var/mnt/extern1 | tr ',' '\n' | grep -E 'prjquota|pqnoenforce'
sudo xfs_quota -x -c 'state' /var/mnt/extern1 | grep -i enforce
```

Then, from the client:

```bash
ssh -p 2222 borg@<server> info
```

**Pass** — the mount reports `prjquota` and **not** `pqnoenforce`;
`xfs_quota` reports project quota enforcement as ON; and the info channel
reports *your own* limit:

```
Used: 2.4 GiB of 50.0 GiB (5%)
```

**Fail** — if the second figure is the size of the whole underlying disk
rather than your configured quota, project quota enforcement is not active
for that repository. This is the single most common misconfiguration, and it
is invisible until a client fills the volume.

---

## 6. No key material exists on the server ⚠️

**Claim** — [Design](DESIGN.md) Chapter 2.1: the server holds no key, no
escrow, no recovery path. Only client-held keyfile modes are accepted.

**Why it matters** — this is what makes a full server compromise survivable.
If key material were present, a breach would eventually mean plaintext.

**Run** (on the host, for each repository)

```bash
grep -c '^key' /var/mnt/extern1/borg-server/OWN/*/config
find /var/mnt/extern1/borg-server -name '*.borgkey' -o -name 'keyfile*'
```

**Pass** — every count is `0` and the `find` returns nothing. A keyfile-mode
repository stores no key material server-side; a repokey repository would
show a `key = ...` line in its `config`.

**Fail** — any match means a repository is in a forbidden mode. Test 8 should
already be preventing its use; if it is not, both checks have failed and the
repository's confidentiality depends entirely on its passphrase strength.

---

## 7. Clients cannot reach each other's repositories ⚠️

**Claim** — [Design](DESIGN.md) Chapter 1.2: strict per-client isolation, via
the forced command's fixed repo path plus borg's `--restrict-to-path`. The
path a client sends is never trusted.

**Why it matters** — cross-client access would leak both data and metadata
between unrelated parties, including between `OWN` devices and external
`MIRROR` partners.

**Run** — from client A, aim at client B's repository path:

```bash
borg list ssh://borg@<server>:2222/repo/OWN/<other-client>
borg list ssh://borg@<server>:2222/repo/
borg list ssh://borg@<server>:2222/etc/
```

**Pass** — all three fail. The client's own repository remains accessible;
no path outside it is.

**Fail** — if any listing succeeds, isolation is broken for that key. Verify
the `command=` path in `authorized_keys` matches the repo assigned in
`clients.conf`.

---

## 8. Only client-held keyfile encryption is accepted ⚠️

**Claim** — [Best Practices](BEST_PRACTICES.md) Chapter 2: the server
verifies the encryption mode of every repository on each connection and
rejects anything that is not a keyfile mode, making the guarantee structural
rather than a matter of client discipline.

**Why it matters** — `repokey` stores a passphrase-wrapped key inside the
repository, which is offline-crackable after a breach. `none` stores
plaintext.

**Note on timing:** a brand-new empty directory is allowed through so that
`borg init` can run — the wrapper cannot inspect a repository that does not
exist yet. The rejection therefore happens on the **next** connection, not
during init. This is expected behaviour, and the test is written around it.

**Run** — using a throwaway repository path if your operator will provision
one, otherwise understand that this leaves an unusable directory behind:

```bash
borg init --encryption=repokey <repo-test>     # succeeds — nothing to inspect yet
borg list <repo-test>                          # must be refused
```

**Pass** — the second command fails with one of:

```
DENY: repo stores key material server-side (not keyfile mode)
DENY: not a keyfile repository (key type 0x03); only client-held keyfile encryption is permitted
```

Both checks are independent and fail closed; either message is a pass.

**Fail** — if `borg list` succeeds against a repokey repository, the
encryption policy is not being enforced, and test 6 will start finding key
material on the server.

---

## 9. Append-only is enforced ✅

**Claim** — [Design](DESIGN.md) Chapter 1.2.4: a client cannot delete data.
`borg-wrapper.sh` appends `--append-only` to every `borg serve` invocation,
on both code paths, with no configuration switch that could be set wrongly.

**Why it matters** — this is what protects the repository against a
compromised or malicious client, and what makes [Recovery](RECOVERY.md)
Section 1 possible at all.

**The intuitive test does not work.** Under append-only, Borg reports
nothing: `borg delete` exits 0, the archive disappears from `borg list`, and
`borg compact` exits 0 with no output. The client-visible behaviour is
identical to an unprotected server. Waiting for an error means waiting
forever.

The only criterion that discriminates is whether **physical space is
reclaimed** — read through the `info` channel, which reports the enforcing
XFS project quota rather than Borg's own accounting.

**Run**

```bash
ssh -p 2222 borg@<server> info                      # note "Used:"
head -c 1M /dev/urandom > /tmp/probe.bin
borg create <repo>::verify-probe /tmp/probe.bin
ssh -p 2222 borg@<server> info                      # must have grown
borg delete <repo>::verify-probe
borg compact <repo>
ssh -p 2222 borg@<server> info                      # decisive
```

**Pass** — usage after the final step stays at the raised value, or is
marginally *higher* — the deletion transaction is itself appended. Measured
against Borg 1.2.8:

| | unprotected | append-only |
|---|---|---|
| empty repository | 42,293 B | 42,293 B |
| after 1 MB probe | 1,092,326 B | 1,092,377 B |
| after delete + compact | 42,329 B | 1,093,846 B |

**Fail** — usage returning to its starting value means append-only is **not**
in effect. A compromised client can erase your backups, and the recovery
procedure in [Recovery](RECOVERY.md) Section 1 will not work when you need
it.

**Why 1 MB is enough:** every `borg create` writes into fresh segment files
rather than extending existing ones, so the probe sits alone in its own
segment. Deleting it leaves that segment essentially fully unused — far above
the threshold `borg compact` requires before rewriting a segment
(`--threshold`, default 10%). A larger probe buys nothing.

**Why the data must be incompressible:** deduplication and compression would
reduce a nominal megabyte to a few kilobytes and leave the measurement in the
noise.

---

## 10. A client cannot destroy its whole repository ✅

**Claim** — follows from append-only: destroying a repository requires
removing segments, which append-only forbids.

**Why it matters** — an attacker who cannot delete archives one by one would
otherwise simply delete the repository.

**Run**

```bash
BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES borg delete --force <repo-test>
```

**Pass** — the command fails and the repository remains intact with all its
segments. Verified against Borg 1.2.8: the same command against a repository
without append-only destroys it completely.

**Fail** — a repository that actually disappears means append-only was not in
effect for that connection. Return to test 3.

---

## Summary checklist

| # | Property | Status |
|---|---|---|
| 0 | Image built from this source (do this first) | ☐ |
| 1 | No interactive shell | ☐ |
| 2 | Default-deny on commands | ☐ |
| 3 | Every key bound to the forced command | ☐ |
| 4 | Container runs rootless | ☐ |
| 5 | Quota enforcing, not accounting | ☐ |
| 6 | No key material on the server | ☐ |
| 7 | Clients isolated from each other | ☐ |
| 8 | Keyfile-only encryption enforced | ☐ |
| 9 | Append-only enforced | ☐ |
| 10 | Repository destruction blocked | ☐ |

A deployment that fails **test 0** has not been verified at all — the
remaining results describe an artifact of unknown origin. A deployment that
fails any of 1–5 should not be considered hardened. A deployment that fails
6–10 is not providing the guarantees this project exists to provide.

## What this document does not cover

- **Restore testing** — that backups can actually be restored is a separate
  and equally mandatory discipline; see [Best Practices](BEST_PRACTICES.md)
  Chapter 7 and [Recovery](RECOVERY.md) Section 4.
- **Verifying a foreign mirror target** — checking that someone *else's*
  server enforces append-only is a different problem with a different answer,
  because you cannot read its physical usage. See [Roadmap](../ROADMAP.md)
  11.2.
- **Host hardening itself** — SELinux enforcing, immutable OS, kernel
  isolation. Those are host-layer properties this project asserts as
  requirements but does not implement; verify them with the tooling of the OS
  you chose.
