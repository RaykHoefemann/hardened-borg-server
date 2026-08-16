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

You need a client machine with **BorgBackup 1.x** installed (**2.x is not
supported** — see
[Supported BorgBackup versions](../README.md#supported-borgbackup-versions-1x-only))
and an SSH key already provisioned on the server
(see [Server Installation](SERVERINSTALL.md), step 9), and a willingness to
write a small amount of throwaway data into the repository. Test 0
additionally needs the GitHub CLI (`gh`), logged in to github.com, and
`skopeo` (part of the Fedora CoreOS base image) — and is best run *before* the
installation, since its whole purpose is to decide whether the image should be
run at all. It needs no registry credential of any kind, and an unusable one
already stored will stop it; see the note under that test. `jq` is optional,
and only for the machine-readable form of the result shown there.

No hardware to spare? [Test Environment](TESTENV.md) builds a throwaway bench
on one VM that covers every test on this page, and shows how to make each test
*fail* on purpose — a test that has only ever passed has not been shown to
discriminate.

Several tests leave roughly 1 MB behind permanently — under a correctly
functioning server you cannot delete it, which is precisely the point.

Throughout, replace `<server>` with your server host, `2222` with your
configured `SSH_PORT`, and `<repo>` with the repository URL assigned to the
client, e.g. `ssh://borg@<server>:2222/repo/OWN/user1-os1-pc1`. Host paths
appear as this project's own example layout: `/var/mnt/extern1` is the mount
point of the storage volume and `/var/mnt/extern1/borg-server` is
`HOST_REPO_BASE` from `scripts/config.sh` — substitute your own.

---

## 0. The image was built from this source ✅

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

**Pass** — the command exits `0`, and the attestation names **this**
repository and the `.github/workflows/docker.yml` workflow, at the git tag
matching the image tag you pulled.

**Fail** — no attestation found, verification errors, or an attestation naming
a different repository or workflow. Do not run the image; obtain it again from
the documented location and re-check.

**Success is silent off a terminal.** `gh` prints its `✓ Verification
succeeded!` only when stdout is a terminal. Redirected, piped or run from a
script it prints **nothing at all** on success, which is indistinguishable from
having done nothing — so read the exit status, or ask for the result in a form
that is always printed:

```bash
gh attestation verify \
  oci://ghcr.io/raykhoefemann/hardened-borg-server:<tag> \
  --repo RaykHoefemann/hardened-borg-server --format json \
| jq -r '.[].verificationResult | .statement.subject[0] as $s |
    "subject : \($s.name)@sha256:\($s.digest.sha256)",
    "repo    : \(.signature.certificate.sourceRepositoryURI)",
    "workflow: \(.signature.certificate.buildSignerURI)",
    "ref     : \(.signature.certificate.sourceRepositoryRef)",
    "commit  : \(.signature.certificate.sourceRepositoryDigest)"'
```

```
subject : ghcr.io/raykhoefemann/hardened-borg-server@sha256:9b0d7e8b0574f26cc7b8346c7e22c2849f5b2828422a605e247a89b52aef4da3
repo    : https://github.com/RaykHoefemann/hardened-borg-server
workflow: https://github.com/RaykHoefemann/hardened-borg-server/.github/workflows/docker.yml@refs/tags/v0.1.0-beta.25
ref     : refs/tags/v0.1.0-beta.25
commit  : 293d1f1e06bb651435de7305e6731cbfee114c77
```

Those five lines *are* the pass criterion, spelled out: the repository, the
workflow, the tag and the commit that produced the image — and the subject
digest, which is the index digest you pin below.

**It needs no registry credential, and a bad one will stop it.** The image is
public, so the registry side of this command works anonymously. What `gh` does
not use for it is your `gh auth login` session: for an `oci://` reference it
authenticates against the registry through the OCI keychain —
`~/.docker/config.json`, or `${XDG_RUNTIME_DIR}/containers/auth.json` for
podman — exactly as `podman pull` would. So an unusable `ghcr.io` entry sitting
in that file is enough to stop the first test on the page. The ordinary case is
a classic PAT from a `docker login ghcr.io` months ago that has since expired,
been revoked, or never carried `read:packages` — it keeps being sent long after
anyone remembers storing it. The obvious repair is a trap of its own:
`docker login ghcr.io -p "$(gh auth token)"` stores the OAuth token
`gh auth login` holds (`gho_…`), which GHCR refuses for package reads whether
`read:packages` is granted or not, and the message does not change. What you
see either way is

```
Error: the provided token was denied access to the requested resource, please
check the token's expiration and repository access
```

which reads like an expiry or a scope problem and is neither. `gh attestation
download` names the step that actually failed — `failed to digest artifact` —
the registry lookup that resolves the tag to a digest, reached before any
signature is examined. Granting scopes will not help, and neither will pinning
the digest in the `oci://` reference: the same lookup runs either way. Drop the
credential with `docker logout ghcr.io` (or `podman logout ghcr.io`), or step
around it for one command:

```bash
DOCKER_CONFIG=$(mktemp -d) gh attestation verify \
  oci://ghcr.io/raykhoefemann/hardened-borg-server:<tag> \
  --repo RaykHoefemann/hardened-borg-server
```

A private image would be the other way round — there the keychain entry is
what makes the lookup possible — but nothing this project publishes is private.

**Where the attestation lives:** it is uploaded to GitHub's Attestations API
and deliberately *not* pushed into the registry, so `gh attestation verify`
finds it by default. Tools that verify strictly against the OCI registry
(`cosign` against the registry, Kyverno or Sigstore policy-controller
admission checks) will **not** find it and will report its absence — that is a
property of where it is stored, not evidence that it is missing. Such a tool
will, however, find *something*: the published index carries two
`attestation-manifest` entries of its own. Those are buildx's provenance and
SBOM attestations, generated by the build, and they are not the Sigstore bundle
this test is about — do not read their presence as this test having passed by
another route.

**Then pin what you verified.** Tags are mutable: verifying
`:0.1.0-beta.25` today says nothing about what that tag points to next month.
Resolve it once and pin the digest in `scripts/config.sh`:

```bash
skopeo inspect --format '{{.Digest}}' \
  docker://ghcr.io/raykhoefemann/hardened-borg-server:<tag>
```

```sh
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
```

**Pin the index digest, not a platform manifest.** The published artifact is an
OCI image index listing one manifest per architecture, and the attestation
verified above names the index. `skopeo inspect` above returns that digest —
the same object `gh attestation verify oci://…:<tag>` resolved — and needs no
prior `podman pull`. `podman image inspect --format '{{.Digest}}'` looks
equally plausible and is the trap: it reports the **platform manifest** for the
architecture of the host it runs on, so it yields one digest on amd64 and a
different one on arm64, and the attestation covers neither. An image pinned
that way pulls and runs perfectly, which is why nothing afterwards reveals that
the pin and the verification refer to two different objects.

Without `skopeo`, `podman images --format '{{.Digest}}' <image>` reports the
index digest of an image already pulled — but it prints one line per locally
present tag of that repository, so make sure you know which line belongs to the
tag you verified.

A pinned digest is the only form in which the result of this test stays true
over time, and it makes every later upgrade a deliberate act.

> Marked verified: executed end to end against the published
> `v0.1.0-beta.25` tag, signature check included, producing the five lines
> above. What that shows is that the test passes on a correct image — not that
> it rejects a tampered one, which cannot be staged without a second signing
> identity. The `--repo` argument is the part doing that work, so keep it as
> written: `gh` requires either it or the looser `--owner`, and `--owner` would
> accept an attestation from any repository of that account.

---

> **Tests 1, 2 and 8 are also checked automatically.** `tests/wrapper-gating.sh`
> drives `borg-wrapper.sh` directly against real Borg repositories and runs on
> every push — 31 cases covering path validation, default-deny gating,
> injected commands, and the keyfile-only encryption policy. It asserts, among
> other things, that the exec line is *exactly* the wrapper's own invocation,
> so no client-supplied argument can widen `--restrict-to-path` or disable
> `--append-only`.
>
> That suite tests the code. The tests below test **your deployment** — that
> the code is what is actually running, wired up as intended. Neither replaces
> the other, and you can run the suite yourself against a checkout.

## 0.5. A provisioned client can actually connect ✅

**Claim** — [Server Installation](SERVERINSTALL.md) step 10: once a client is
in `clients.conf`, its key is in `/config/keys/`, and the container has been
restarted, that client can reach the server and initialize its repository.

**Why it matters** — every other test on this page starts *after* a working
connection and examines what happens beyond it. Nothing checks the connection
itself, and both of the bugs that made a fresh install unusable lived exactly
there: a `borg` account left locked in `/etc/shadow`, which `sshd` refuses
before it ever looks at a key, and a server-written file inside the client's
repository directory, which made the client's first `borg init` fail. Neither
is visible from the server side — `authorized_keys` looks perfect in both
cases. This is the cheapest test here and the one with the widest reach.

**Run** — from the client machine, with its own key:

```bash
ssh -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -i ~/.ssh/borg_backup -p 2222 borg@<server> info

borg init --encryption=keyfile-blake2 ssh://borg@<server>:2222/repo/OWN/<client>
```

`PreferredAuthentications=publickey` matters: without it a rejected key falls
through to `keyboard-interactive`, and `MaxAuthTries 2` then reports "Too many
authentication failures" — which points at the client's key agent rather than
at the server.

**Pass** — the first command prints the server's identity, this client's
account and its quota usage; the second creates the repository and prints
Borg's key-custody warning. Take custody of the key now
([Client Usage](CLIENTUSE.md) chapter 3) — it exists only on the client.

**Fail**

- `Permission denied (publickey,...)` — check the container log for
  `User borg not allowed because account is locked`. That is the `/etc/shadow`
  bug; a server built from current sources sets the password field to `*`.
  Confirm with `podman exec <container> getent shadow borg` → `borg:*:…`.
  Note that `passwd -S borg` prints `L` either way and cannot tell you.
- `There is already something at /repo/...` — the repository directory is not
  empty, and `borg init` refuses it. Current sources render the client's info
  text under `/run/borg-info/` and remove the leftover from older releases at
  container start; if a file is still there, it was put there by something
  else, and [Recovery](RECOVERY.md) applies rather than a fresh init.
- A hanging connection or a host-key mismatch is a network or identity
  problem, not an authorization one — resolve it before reading the two cases
  above into it.

> Verified: both failure modes above were reproduced against a container built
> from this source, and both disappear with the fixes described. The run used
> a Borg 1.2.8 client against the image's bundled 1.4.0.

---

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

Then, for every client at once (on the host):

```bash
./scripts/09-show-all-users.sh
```

And from the client:

```bash
ssh -p 2222 borg@<server> info
```

**Pass** — the mount reports `prjquota` and **not** `pqnoenforce`;
`xfs_quota` reports project quota enforcement as ON; every client's
`CONFIGURED` column repeats each client's `clients.conf` value unmarked, with
no `(!)` in the `QUOTA` or `CONFIGURED` columns and no drift hint under the
listing; and the info channel reports *your own* limit:

```
Used: 2.4 GiB of 50.0 GiB (5%)
```

A `(!)` on the `Committed:` line is a different statement and does not decide
this test. It reports that the quotas jointly reach the volume (OPERATIONS
Chapter 10.2) — a capacity decision, and a legitimate one: three clients at
50G/50G/10G on a 100 GB volume are each enforced to the byte. Both markers
mean "look here"; only the ones in the columns are about whether quotas are
*enforcing*.

**Fail** — if the second figure is the size of the whole underlying disk
rather than your configured quota, project quota enforcement is not active
for that repository. This is the single most common misconfiguration, and it
is invisible until a client fills the volume. On the host side the same
condition appears as `none (!)` in the `QUOTA` column; a marked value in
`CONFIGURED` means a limit *is* enforced, but not the one `clients.conf`
records — the `QUOTA` column is the one in force. Re-apply the intended value
with `02-change-user-quota.sh` (OPERATIONS Chapter 9.4).

One route into this state is closed by the tooling itself: `00-` and `02-`
refuse a quota above 99% of the volume, because a limit at or above the volume
size is reported back through `statvfs()` as the whole volume and is therefore
indistinguishable from no limit at all — the very condition this test looks
for. Asking for one is a quick way to see that the refusal works.

---

## 6. No key material exists on the server ⚠️

**Claim** — [Design](DESIGN.md) Chapter 2.1: the server holds no key, no
escrow, no recovery path. Only client-held keyfile modes are accepted.

**Why it matters** — this is what makes a full server compromise survivable.
If key material were present, a breach would eventually mean plaintext.

**Run** (on the host, for each repository)

Both commands go through `podman unshare`. The repository files belong to the
container's `borg` user, which on the host is a subuid the operator is not, and
Borg creates them `0600`/`0700` — so a correctly working installation is
precisely the case in which the operator cannot read them directly.
`podman unshare` enters the same user namespace the container runs in, where
those files are readable; it is the same mechanism `00-ssh-create-user.sh` uses
to create them. Run it as the same user that runs the container — any other
account maps to a different namespace and is no better off than before.

```bash
podman unshare sh -c "grep -c '^key' /var/mnt/extern1/borg-server/*/*/config"
podman unshare find /var/mnt/extern1/borg-server -name '*.borgkey' -o -name 'keyfile*'
```

The `*/*/config` glob covers both groups: a `MIRROR` repository has to satisfy
this claim exactly as an `OWN` one does.

**Pass** — every count is `0` and the `find` returns nothing. A keyfile-mode
repository stores no key material server-side; a repokey repository would
show a `key = ...` line in its `config`.

**Fail** — any match means a repository is in a forbidden mode. Test 8 should
already be preventing its use; if it is not, both checks have failed and the
repository's confidentiality depends entirely on its passphrase strength.

**`Permission denied` is not a pass.** Run without `podman unshare`, both
commands fail on every repository — and the `find` then prints only
`Permission denied` lines and no matches, which reads exactly like the pass
criterion above. It means the check never looked inside a repository. Re-run it
through `podman unshare`; a count of `0` printed per `config` file is what a
test that actually ran looks like.

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
| 0.5 | A provisioned client can connect and initialize | ☐ |
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
fails **test 0.5** is not a deployment yet: no client can use it, and every
test below it is unrunnable. A deployment that
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
