> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)

---

> [!CAUTION]
> **This page is long, and length is not the same as completeness.** Assume
> this project still has gaps this page does not check for, and assume this
> page — the test overview itself — has gaps too: properties nobody has
> written a criterion for yet, criteria nobody has staged a failure against,
> mistakes in the criteria themselves. A long checklist with most rows ✅ is
> easy to misread as "someone thought of everything." Nobody has. Read
> [How to read a test](#how-to-read-a-test) and
> [What this document does not cover](#what-this-document-does-not-cover)
> before trusting any row of it.

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

> **This page does not claim to be a complete test.** It checks the specific
> properties [Design](DESIGN.md) and [Best Practices](BEST_PRACTICES.md)
> assert, each against one explicit criterion — nothing wider. A full pass
> means those properties held on the day you ran them; it is not a statement
> about the deployment as a whole, and it does not by itself mean a check
> would have caught the same property failing (see **Negative test** under
> each entry), nor that nothing outside this page's scope is wrong (see
> [What this document does not cover](#what-this-document-does-not-cover) at
> the end). Read "24 of 24 passed" as "no defect found in what this page
> measures," not as "no defect exists."

## How to read a test

Each entry states:

- **Claim** — what the documentation asserts, and where
- **Why it matters** — what an attacker or an accident gains if it is false
- **Run** — the exact commands
- **Pass** — what a correct installation produces
- **Fail** — what the observed output means and what to do
- **Negative test** — the deliberate way to break the property and confirm
  this specific check notices, run against a real deployment. Present
  wherever one exists; marked **not yet staged** where it does not.
- **What this does not show** — the edge of the criterion: what a pass here
  leaves unmeasured, and which test covers it instead

That last field is not modesty. Every defect reported against this page so far
has been of one kind — a criterion reaching further than the measurement under
it — so the boundary is written down where the claim is made, rather than left
for a reader to discover.

A run through this page that only exercises **Run** and **Pass** has shown the
property looks right — not that this check would catch it being wrong. Those
are two different claims, and folding them into one green result is exactly
the mistake this page exists to avoid. **Negative test** says, per check,
which of the two the record actually supports.

**Tests that measure more than one thing name their checks.** Test 5 is `5A`
and `5B`; test 4 is `4A` through `4C`. Each check has its own command, its own
pass criterion and its own repair, because they fail for different reasons and
mean different things. A test with a single criterion keeps its plain number and
gets no letter. The summary checklist at the end has one row per check, and a
report that names `5B` says in two characters what "test 5 failed" cannot.

**Status markers sit on the check, not on the test.** A test with lettered
checks carries no marker of its own, because its checks do not have to be at the
same stage: 1.5A has been measured in both directions and 1.5B was written
afterwards, in response to what 1.5A missed, and has not. An aggregate marker
would hide exactly the distinction this page exists to make.

- ✅ **Verified** — the underlying behaviour has been reproduced against a live
  instance, in both directions where that can be staged: the check passes on a
  correct deployment *and* fails on a broken one. The check still has to be run
  against *your* deployment; what is confirmed is that it discriminates.
- (✅) **Verified, capped** — the passing direction has been reproduced against
  a live instance, and the failing direction is not staged because it cannot
  be, not because nobody has gotten to it yet. This is a ceiling, not a
  placeholder: unlike ⚠️, it does not mean "still to do" — the check will not
  move to a plain ✅ later, because the missing half cannot be produced. 0A is
  the only check on this page in this state.
- ⚠️ **Unverified** — the procedure follows from the implementation, or only
  its passing direction has been observed. Treat an unexpected result as a
  possible flaw in the check, not only in the deployment, and please report it.
  Where a check has been partly measured, the note under it says which part.

## Before you start

You need a client machine with **BorgBackup 1.x** installed (**2.x is not
supported** — see
[Supported BorgBackup versions](../README.md#supported-borgbackup-versions-1x-only))
and an SSH key already provisioned on the server
(see [Server Installation](SERVERINSTALL.md), step 9), and a willingness to
write a small amount of throwaway data into the repository. Test 0 additionally
needs the GitHub CLI (`gh`), logged in to github.com, for `0A`, and `skopeo`
(part of the Fedora CoreOS base image) for `0B` — and is best run *before* the
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

Throughout, replace `<server>` with your server host (a name or a bare IP),
`2222` with your configured `SSH_PORT`, `<client>` with the client's name in
`clients.conf`, and `<repo>` with the repository URL assigned to it, e.g.
`ssh://borgserver/repo/OWN/user1-os1-pc1`. Host paths appear as this project's
own example layout: `/var/mnt/extern1` is the mount point of the storage volume
and `/var/mnt/extern1/borg-server` is `HOST_REPO_BASE`, derived in the repository root's `config.sh`
— substitute your own.

### How client-side commands are written here

Commands run from a client use the `borgserver` alias established in
[Client Usage](CLIENTUSE.md) chapter 1 — `ssh borgserver info`, and repository
URLs as `ssh://borgserver/repo/OWN/<client>`. The alias carries the one thing
these commands otherwise leave unsaid: **which key to offer**.

A client that followed CLIENTUSE holds a *dedicated* key at
`~/.ssh/borg_backup`, and that name is not among the identities ssh tries by
itself (`id_rsa`, `id_ecdsa`, `id_ed25519`, …). Being dedicated is precisely
what makes it invisible. Address the server as `borg@<server>` and ssh offers
those defaults instead, the server rejects every one of them, and the answer is
`Permission denied (publickey,keyboard-interactive)` — the same text 0.5A
attributes to the locked-account bug, on a server where nothing is wrong (#24).

Writing the expanded form does not merely lose the shorthand: `Host borgserver`
in `~/.ssh/config` matches **the name you type**, not the machine you reach, so
`borg@<server>` silently bypasses the block that would have named the key, even
when its `HostName` is that very host.

**No config block, or a server reachable only by IP.** Then name the key on the
command line. Every client-side command on this page translates the same way:

| This page writes | Equivalent without `~/.ssh/config` |
|---|---|
| `ssh borgserver <cmd>` | `ssh -i ~/.ssh/borg_backup -o IdentitiesOnly=yes -p 2222 borg@<server> <cmd>` |
| `borg <cmd> ssh://borgserver/repo/OWN/<client>` | `BORG_RSH="ssh -i ~/.ssh/borg_backup -o IdentitiesOnly=yes" borg <cmd> ssh://borg@<server>:2222/repo/OWN/<client>` |

Borg takes no `-i` of its own — `BORG_RSH` is where the key goes, because borg
reaches the server by running ssh itself.

`IdentitiesOnly=yes` is not decoration. Without it ssh offers the default
identities and everything in the agent *in addition* to the key named by `-i`,
and `MaxAuthTries 2` in the image cuts the connection after two rejections —
often before the right key is ever tried. The failure then reads "Too many
authentication failures", which points at the client's agent rather than at the
missing key.

Check 0.5A keeps the expanded form deliberately: it is the check that
establishes whether the key works at all, and it must not depend on a
configuration block being right.

Where you hold more than one client identity, substitute your own alias per
client — the bench in [Test Environment](TESTENV.md) defines `borgA` and
`borgB` for exactly that, and test 7 is the one that needs both.

---

## 0. The image was built from this source

**Run 0A and 0B before the others.** Every test below examines the behaviour of
a running container. If that container was not built from the source you
reviewed, all of them verify the wrong artifact — correctly, and pointlessly.
This is the only test whose failure invalidates the entire rest of the page.

`0C` is the exception to that order: it needs a running container, so it comes
after installation. The three are one argument in sequence — this image was
built here (`0A`), your configuration names that image (`0B`), and the process
serving clients was started from it (`0C`).

**Claim** — each published image carries a Sigstore build-provenance
attestation, produced by this repository's own workflow
(`.github/workflows/docker.yml`), tying the image digest to the commit and
workflow run that built it.

**Why it matters** — the documentation, the wrapper's source, and this test
page are all public and auditable. The thing you actually run is a binary blob
pulled from a registry. Without this check, reviewing the source proves
nothing about what is executing.

### 0A — the attestation verifies and names this repository (✅)

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
digest, which is the index digest you pin below. The output above is the
recorded run against `v0.1.0-beta.25`, kept as measured rather than updated
with each release: it is evidence, not an example, and rewriting the tag in it
would turn it into a claim nobody checked. Yours will name the tag you pulled.

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

**Negative test** — not staged, and cannot be: forging a valid attestation from
a different signing identity is outside what this project can produce to test
against. That is why this check carries `(✅)` rather than a plain ✅ — see
"How to read a test". See the note under 0B for what has been measured
instead.

### 0B — what you verified is what you pinned ✅

Tags are mutable: verifying `:0.1.0-beta.25` today says nothing about what that
tag points to next month. 0A is a statement about an object; this check is what
ties your deployment to that object rather than to a name.

**Run**

```bash
skopeo inspect --format '{{.Digest}}' \
  docker://ghcr.io/raykhoefemann/hardened-borg-server:<tag>
```

**Pass** — the digest printed here is the one in `IMAGE`, and it is the same
digest `0A` reported as `subject`:

```sh
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
```

[Server Installation](SERVERINSTALL.md) step 3 sets `IMAGE` to exactly this, and
[Deployment](DEPLOYMENT.md) Chapter 6.3 step 4 re-resolves it on every upgrade —
a new release is a new image and therefore a new digest. An installation that
followed those guides passes this check without further editing; if `IMAGE`
still ends in `:<tag>`, that is the state this check exists to catch (#25).

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

**Fail** — a digest in `IMAGE` that differs from the one printed here, or no
digest at all. A mutable tag means the next `podman pull` can replace the image
0A verified, without changing a line of configuration.

A pinned digest is the only form in which the result of this test stays true
over time, and it makes every later upgrade a deliberate act.

**What this does not show** — that the *source* the attestation names is
trustworthy. 0A proves the image was built by this repository's workflow from a
named commit; whether that commit deserves your trust is a review question, and
this page cannot answer it. Nor does either check say anything about the running
container: an operator can verify an image, pin it, and still have a different
one serving clients. That is 0C.

**Negative test** — staged and confirmed (v0.1.0-beta.31): the wrong-tool trap
(`podman image inspect` in place of `skopeo`) was shown to print a different
digest for the same tag on the same host (#25), which is why this check must
use `skopeo`. The check's own criterion has since been staged too: `IMAGE`
was re-pinned, without a restart, to the real `v0.1.0-beta.30` digest, and
this **Run** reported the correct `v0.1.0-beta.31` digest against it —
exactly the divergence **Fail** describes.

> **0A is marked `(✅)`:** executed end to end against the published
> `v0.1.0-beta.25` tag, signature check included, producing the five lines
> above, and again against `v0.1.0-beta.27`. What that shows is that the check
> passes on a correct image — not that it rejects a tampered one, which cannot
> be staged without a second signing identity, and never will be. This is the
> one place on the page where the counter-check is impossible rather than
> merely undone, which is what the parentheses mean. The `--repo`
> argument is the part doing that work, so keep it as written: `gh` requires
> either it or the looser `--owner`, and `--owner` would accept an attestation
> from any repository of that account.
>
> **0B is marked verified too, as of `v0.1.0-beta.31`.** The identity of the
> two digests was measured — for `v0.1.0-beta.27`, `skopeo inspect` printed
> exactly the digest 0A reported as `subject`. The trap the check exists for
> is measured too, on amd64: against `v0.1.0-beta.28` on Fedora CoreOS,
> `skopeo` and `podman image inspect` printed **different** digests for the
> same tag on the same host, and `gh attestation verify` named the `skopeo`
> one as `subject` (#25). Reading the index directly shows why, and covers the
> other architecture:
>
> ```
> mediaType: application/vnd.oci.image.index.v1+json
>   linux/amd64      sha256:f645a463c78be951e6f…   ← what podman prints there
>   linux/arm64      sha256:7fa27c87a8a9ad39957…   ← a third, different object
>   unknown/unknown  sha256:6dfb4aca342db376b8f…   ← buildx provenance
>   unknown/unknown  sha256:a9b74479c97edd49791…   ← buildx SBOM
> ```
>
> against an index digest of `sha256:d2378b97…`. So the three digests are
> distinct objects as a matter of measurement rather than of reasoning. What
> closes the check's own mark, rather than just the trap beside it, is a
> direct measurement against `v0.1.0-beta.31`: `IMAGE` re-pinned, without a
> restart, to the real `v0.1.0-beta.30` digest, and `skopeo inspect` reporting
> the correct `v0.1.0-beta.31` digest against it — the divergence **Fail**
> describes, produced and observed rather than argued for.
>
> What remains untested is only the last step of the wrong-tool chain — that
> `podman image inspect` on an *arm64 host* prints that host's manifest, as it
> demonstrably does on amd64. That gap sits beside the check's mark now, not
> under it.

### 0C — the container is running the object you verified ✅

0A and 0B are answered before a container exists; they are about an artifact in
a registry. This is the return visit after installation, and it asks a
different question: not what `config.sh` configures, but what the process
serving clients right now was actually started from. Those two drift apart in
one very ordinary way that no comparison of *versions* can detect, which is why
this check reads references rather than release numbers.

**Run** — on the host, as the service user, from `$INSTALL_PATH`:

```bash
podman inspect borg-server --format '{{.ImageName}}'
grep '^IMAGE=' scripts/config.sh
```

**Pass** — both name the same `@sha256:` reference, and it is the digest 0A
reported as `subject`:

```
ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>
IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>"
```

With `IMAGE` pinned the way [Server Installation](SERVERINSTALL.md) step 3
prescribes, this is a statement about *content*: a reference that names its
object by hash cannot have been resolved to different bytes, so a container
started from it is running what 0A verified.

**Fail** — the two differ. The ordinary cause is an edit without a restart: an
upgrade re-pinned `IMAGE` ([Deployment](DEPLOYMENT.md) 6.3 step 6) while the old
container kept running, so the checkout, the unit and the configuration all
describe a release that is not serving anyone.

The repair is both halves of [Deployment](DEPLOYMENT.md) 6.3 step 7, in that
order:

```bash
./scripts/50-service-install.sh
./scripts/92-container-restart.sh
```

Restarting alone does not do it. The unit takes `IMAGE` from the
`EnvironmentFile` that `50-service-install.sh` generates, not from `config.sh`
directly, so a restart without the install step re-reads the *old* value and
starts the old image again — leaving this check failing exactly as it was.

`99-container-status.sh` reports the same disagreement as a `PIN MISMATCH` line
(OPERATIONS Chapter 9.11), and reads the same two references to do it. That is
the operational echo of this check; running it here is the deliberate one, and
it is the only form available if the report itself is what you doubt. What the
status script's *other* line — `MISMATCH` — compares is something else entirely:
the host scripts' `VERSION` against the running container's, neither of which an
edited pin changes.

**Weaker when `IMAGE` carries a tag.** Then both sides can agree while the
object underneath has been replaced, because a name is all either of them
names. That is 0B's argument, seen from the running end.

**Do not reach for `podman image inspect --format '{{.Digest}}'` to make this
stricter.** It reports the per-architecture manifest, not the signed index, so
it prints a digest that differs from the pinned one on a perfectly correct
installation — the trap 0B describes, arriving this time from your own tooling
rather than from the registry.

**Negative test** — staged and confirmed on a live deployment; see below.

**What this does not show** — that the image podman holds under that name is
unmodified in local storage. This check reads podman's own record of what it
started; it is not an independent hash of the bytes on disk. Nor does it say
anything about the container's behaviour, which is every test below it.

> **Verified in both directions.** Correct state: on an installation pinned and
> restarted the way [Server Installation](SERVERINSTALL.md) step 3 prescribes,
> both commands print the same `@sha256:` reference. Broken state, staged from
> the "Break this" table of [Test Environment](TESTENV.md): with `v0.1.0-beta.30`
> running and `IMAGE` re-pinned to the `beta.29` index digest without a restart,
> the two lines diverged on exactly that difference (#31).
>
> **What that measurement also settled** is why this check reads references.
> `99-container-status.sh` stayed silent throughout — its `MISMATCH` line
> compared the host scripts against the running container, and an edited pin
> moves neither. The page claimed here, and in TESTENV, that the status script
> covered the cross-version case and left only same-version rebuilds to `0C`; it
> covered neither. The `PIN MISMATCH` line described above was written in
> response and compares the two references directly, so both cases are now
> reported without being run for. **That line has since been verified against a
> deployment** (v0.1.0-beta.31): with the container running and `IMAGE` re-pinned
> to a different digest without a restart, `99-container-status.sh` reported
> `PIN MISMATCH` exactly as documented, and the two-step repair
> (`50-service-install.sh` then `92-container-restart.sh`) cleared it.
> `tests/host-scripts.sh` asserts the same line across four states — a pin
> edited to a second digest of the same release, a stale checkout with a
> matching pin, a pin the container was started from, and a stopped container —
> which is the suite testing the code, a different statement from the one this
> page makes; the bench run above is what closes that gap.
>
> A stronger variant is being measured: reading the digest from podman's own
> storage record (`RepoDigests`) rather than from the reference string, which
> would also catch a re-pulled tag. It is not prescribed here until the output
> has been observed on a real installation — including whether that field
> carries the index digest or the per-architecture one, which is exactly the
> distinction this check must not get wrong.

---

> **Tests 1, 2 and 8 are also checked automatically.** `tests/wrapper-gating.sh`
> drives `borg-wrapper.sh` directly against real Borg repositories and runs on
> every push — 32 cases covering path validation, default-deny gating,
> injected commands, and the keyfile-only encryption policy. It asserts, among
> other things, that the exec line is *exactly* the wrapper's own invocation,
> so no client-supplied argument can widen `--restrict-to-path` or disable
> `--append-only`.
>
> That suite tests the code. The tests below test **your deployment** — that
> the code is what is actually running, wired up as intended. Neither replaces
> the other, and you can run the suite yourself against a checkout.

## 0.5. A provisioned client can actually connect

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

The two halves fail for unrelated reasons — one in the daemon before a key is
ever read, one in the filesystem after the connection already worked — so they
are checked and reported separately.

### 0.5A — the key authenticates and the info channel answers ✅

**Run** — from the client machine, with its own key:

```bash
ssh -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
    -i ~/.ssh/borg_backup -p 2222 borg@<server> info
```

`PreferredAuthentications=publickey` matters: without it a rejected key falls
through to `keyboard-interactive`, and `MaxAuthTries 2` then reports "Too many
authentication failures" — which points at the client's key agent rather than
at the server.

**Pass** — the command prints the server's identity, this client's account and
its quota usage.

**Fail** — `Permission denied (publickey,...)`: check the container log for
`User borg not allowed because account is locked`. That is the `/etc/shadow`
bug; a server built from current sources sets the password field to `*`.
Confirm with `podman exec <container> getent shadow borg` → `borg:*:…`. Note
that `passwd -S borg` prints `L` either way and cannot tell you.

A hanging connection or a host-key mismatch is a network or identity problem,
not an authorization one — resolve it before reading the case above into it.

**Negative test** — staged during earlier development, not deliberately
re-staged since: the locked-account state above is the actual bug this check
was written to catch, reproduced against a container built before the fix and
cleared by it. See the note under 0.5B.

### 0.5B — the client can initialize its repository ✅

**Run** — from the same client:

```bash
borg init --encryption=keyfile-blake2 ssh://borgserver/repo/OWN/<client>
```

**Pass** — the repository is created and Borg prints its key-custody warning.
Take custody of the key now ([Client Usage](CLIENTUSE.md) chapter 3) — it exists
only on the client.

**Fail** — two refusals, from opposite sides of the connection, and they are not
the same problem.

`There is already something at /repo/...` is borg's own: the repository
directory is not empty, and `borg init` refuses it. Current sources render the
client's info text under `/run/borg-info/` and remove the leftover from older
releases at container start; if a file is still there, it was put there by
something else, and [Recovery](RECOVERY.md) applies rather than a fresh init.

`Remote: DENY: no repository segments found` is the **server's**, and it means
the connection was refused before borg ran at all. The directory holds a
`config` and a `README` but no segment — what an *interrupted* `borg init`
leaves behind, because borg creates those on the server before it asks the
client for a passphrase. A Ctrl-C at that prompt, a mistyped repeat or a run
without a terminal is enough. The wrapper cannot tell that apart from a
repository whose segments are gone, so it refuses both; this is the gate working
as designed, and it is why retrying the init never clears it. The repair is
operator-side and documented: [Operations](OPERATIONS.md) Chapter 9.12, which
clears the directory's contents without disturbing its XFS project id.

**What this does not show** — anything about what the client may do once
connected. A working connection is the precondition for tests 1 through 10, not
evidence for any of them: 0.5A passing means a key was accepted, not that it is
confined, and 0.5B passing means a directory was writable, not that its contents
are protected.

**Negative test** — staged (#26): see below.

> Verified: both failure modes above were reproduced against a container built
> from this source, and both disappear with the fixes described. The run used
> a Borg 1.2.8 client against the image's bundled 1.4.0.
>
> The third refusal was reproduced deterministically on both bench clients
> (Borg 1.2.8 on Linux Mint 22.3, Borg 1.4.0 on Debian 13) against
> `v0.1.0-beta.29`: an `init` ended at the passphrase prompt leaves the
> skeleton, every later attempt is refused with `DENY: no repository segments
> found`, and clearing the directory as Chapter 9.12 describes lets the same
> client initialize normally and 0.5B pass (#26).

---

## 1. No interactive shell ✅

**Claim** — [Design](DESIGN.md) Chapter 1.2: a client key grants no shell
access. Enforced by the forced command in `authorized_keys` plus `restrict`.

**Why it matters** — a shell on the server would make every other guarantee
in this document irrelevant.

**Run**

```bash
ssh borgserver
```

**Pass**

```
DENY: only 'borg serve' and 'info' are permitted
```

The connection closes immediately. No prompt, no banner, no shell.

**Fail** — any prompt, or any output resembling a shell, means the forced
command is not in effect for this key. Stop and go to 3A.

**Negative test** — staged and confirmed (v0.1.0-beta.31): a raw key without
`command=`/`restrict` was appended directly to `authorized_keys`, and
connecting with it returned a live interactive shell (`whoami`, `hostname`
both answered) instead of the `DENY` line above — 3A's failing state, paired
with this check, does exactly what **Fail** says it would.

**What this does not show** — anything about keys other than the one you used,
and anything about what the daemon would allow if the forced command were
missing. Test 3 answers the first, test 1.5 the second. A pass here is a
statement about one line of `authorized_keys`, not about the file.

---

## 1.5. The SSH daemon permits nothing beyond the forced command

**Claim** — [Design](DESIGN.md) Chapter 1.2.2: the forced command is not the
only thing standing between a client and a shell. Interactive TTYs, every form
of forwarding, password authentication and root login are disabled in the
daemon itself, and only the `borg` account may authenticate at all.

**Why it matters** — test 1 shows that a client cannot get a shell *today*,
with the forced command in place. This one shows what is left if that line is
ever wrong. A key that reaches `authorized_keys` without `command=` and
`restrict` — a hand edit, a restored backup, an operator experiment, a
regression in the generator — still cannot open a TTY, forward a port, or
authenticate as anyone but `borg`. It is the lock behind the lock, and the only
one that does not depend on a file being generated correctly.

Tests 1 and 3 examine what the generator produced. This one examines what the
daemon will accept regardless.

All three checks run on the host, in `bash`, and share one filter:

```bash
KEYS='^(permitrootlogin|passwordauthentication|permitemptypasswords|allowusers|permittty|allowtcpforwarding|x11forwarding|permittunnel|gatewayports|pubkeyauthentication) '
```

`sshd -T` prints the configuration the running daemon actually resolved — not
the file it was meant to read. That distinction is the whole test: reading
`/etc/ssh/sshd_config`, or the `Dockerfile` it was written from, proves what
was *intended*. A configuration mounted over the image's own, or an image
rebuilt locally from modified source, leaves both those files looking correct
and shows up in 1.5A.

### 1.5A — the daemon's own configuration is hardened ✅

**Run**

```bash
podman exec borg-server sshd -T | grep -Ei "$KEYS" | sort
```

**Pass** — exactly these ten lines:

```
allowtcpforwarding no
allowusers borg
gatewayports no
passwordauthentication no
permitemptypasswords no
permitrootlogin no
permittty no
permittunnel no
pubkeyauthentication yes
x11forwarding no
```

`sshd -T` prints every keyword it resolved, defaults included, so all ten lines
appear on any daemon — what decides this check is the value on each.

**Fail** — any other value on any of those lines. `permittty yes`, a missing or
widened `allowusers`, or `passwordauthentication yes` each mean the daemon would
permit what only the forced command is currently preventing — the second lock is
open, and nothing but a generated file stands between a client and a shell.
Re-pull the image and verify it (test 0); if the deployment mounts its own
`sshd_config`, that file is now the thing to review, not the image.

**Negative test** — staged (#20): see the note below. This is the reason the
markers moved onto individual checks in the first place.

### 1.5B — the account that can log in gets the same answer ✅

**Run** (uses process substitution, so `bash` rather than `sh`)

```bash
diff <(podman exec borg-server sshd -T | grep -Ei "$KEYS" | sort) \
     <(podman exec borg-server sshd -T -C user=borg,host=localhost,addr=127.0.0.1 \
       | grep -Ei "$KEYS" | sort)
```

**Without `-C`, `sshd -T` prints the global configuration and does not evaluate
`Match` at all** — so a `Match User borg` that reopens TTY allocation,
forwarding or password authentication for the one account `AllowUsers` permits
stays invisible to 1.5A, which goes on printing ten correct lines. That is not
hypothetical: staged on a bench, it produced a real interactive shell for a key
this test was written to contain (#20). This check asks the same daemon what
applies to that account and requires the two answers to be identical; `sshd`
derives group membership from `user=`, so a `Match Group` is covered here too.

**Pass** — no output.

**Fail** — any difference. A value that is correct globally and wrong under
`-C user=borg` means exactly what a wrong value in 1.5A means, reached by the
one route the global output cannot show.

**Negative test** — staged and confirmed: the `Match User borg` block from
[Test Environment](TESTENV.md) Chapter 8, mounted over a throwaway bench
container's `sshd_config` (own port, own image copy, production instance
untouched). 1.5A stayed blind against that same container, reporting ten
correct lines regardless. This check's `diff` was not empty — `permittty` and
`allowtcpforwarding` both flipped to `yes` under `-C user=borg` — catching
exactly what 1.5A could not. A real connection through a
`command=`/`restrict`-less key on the same container, opened with `ssh -tt`,
then produced an actual interactive TTY as `borg` — the #20 incident,
reproduced against this recipe rather than only the original one.

### 1.5C — nothing in the configuration can make it conditional ✅

**Run**

```bash
podman exec borg-server grep -rnE '^[[:space:]]*(Match|Include)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null
```

A block keyed on the connection rather than the account — `Match Address`,
`LocalPort`, `RDomain` — escapes any fixed connection spec, and so escapes 1.5B.
This check covers that from the other side: the image ships no `Match` and no
`Include` at all, so any occurrence is something to account for, whoever put it
there.

**Pass** — no output. `/etc/ssh/sshd_config.d/` need not exist; a missing
directory is silenced by the redirect and is not a finding.

**Fail** — any line. Read the block it names and decide what it does to the ten
settings above; if it is not yours, treat the daemon's configuration as
untrusted and re-pull the image.

**Negative test** — staged and confirmed, against the same bench container as
1.5B: the mounted `Match User borg` block was reported by this check's `grep`
(`/etc/ssh/sshd_config:32:Match User borg`), exactly as a block of that shape
must be.

**What this does not show** — that the ten settings are *sufficient*. They are
the ones this project asserts; a hardening review of the full `sshd -T` output
is a wider exercise, and the cipher suite is deliberately outside the criterion
(see below). 1.5B also cannot enumerate every possible `Match` outcome — it
measures the one account that `AllowUsers` permits, and 1.5C is what stands in
for the rest.

> **Also worth a look, but not part of the pass criterion:** 1.5A without its
> filter shows `kexalgorithms`, `ciphers`, `macs` and
> `hostkeyalgorithms`. The image pins modern ones (curve25519, ChaCha20-Poly1305
> and AES-GCM, HMAC-SHA2-512-ETM, ed25519 host keys only). They are deliberately
> left out of the criterion because their names shift between OpenSSH releases,
> and a test that fails on a base-image upgrade teaches people to skip it.
>
> One line from the unfiltered output is worth reading whatever else you skip:
> `maxauthtries 2`. It is the mechanism behind the "Too many authentication
> failures" message that 0.5A and [Client Usage](CLIENTUSE.md) both warn
> about — here it can be confirmed in the resolved configuration instead of
> inferred from the symptom.

> **1.5A is marked verified, and it is the reason the markers moved onto the
> checks.** Against a live `v0.1.0-beta.26` container it produced exactly the
> ten lines above; staged against the same image with a widened `sshd_config`
> mounted over the image's own, it reported five wrong values and failed as it
> should. Both directions, measured — which is what ✅ means here.
>
> **1.5B and 1.5C are now marked verified too.** A staged bench container
> reproduced exactly that setup — 1.5A reporting ten correct lines while a key
> without `command=` and `restrict` opened an interactive shell (#20) — this
> time against the recipe itself rather than only the original incident:
> 1.5B's `diff` and 1.5C's `grep` both caught it, on the same container, in the
> same run.

---

## 2. Default-deny on commands ✅

**Claim** — `borg-wrapper.sh` gates on `$SSH_ORIGINAL_COMMAND` and permits
exactly two things: the literal string `info`, and a `borg serve` invocation.
Everything else is rejected.

**Why it matters** — a key that can run arbitrary commands can read other
clients' repositories, alter quotas, or disable the wrapper itself.

**Run**

```bash
ssh borgserver "ls /"
ssh borgserver "cat /etc/passwd"
ssh borgserver "borg serve; rm -rf /"
ssh borgserver info
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

**Negative test** — staged and confirmed: `borg-wrapper.sh` copied onto a
throwaway bench container (own port, same image digest, production instance
untouched) with its default-deny branch replaced by
`eval "$SSH_ORIGINAL_COMMAND"; exit 0`. A forbidden command (`id -un; ls /`)
sent through a real client key then executed and returned real output —
exactly this check's **Fail** condition. The same command against the
unmodified production instance, with a real client key, still answered
`DENY: only 'borg serve' and 'info' are permitted`.

**What this does not show** — that the two permitted commands are themselves
safe. This check establishes that everything else is refused; that `borg serve`
is invoked with `--append-only` and `--restrict-to-path`, and cannot be widened
by a client-supplied argument, is what `tests/wrapper-gating.sh` asserts and
what tests 7 and 9 measure on your deployment.

---

## 3. Every key is bound to the forced command

**Claim** — [Operations](OPERATIONS.md): `build_authorized_keys.sh` generates
every entry as `command="/borg-wrapper.sh <repo>",restrict <key>`.

**Why it matters** — this is the single point on which every other guarantee
depends. One line without the prefix exempts that key from append-only, path
restriction, encryption enforcement and command gating simultaneously — and
nothing else in the system would look wrong. Losing only `restrict` is the
smaller half of that and still real: the wrapper keeps gating the command, while
the key regains forwarding, TTY allocation and agent access from SSH itself.

Two different questions, asked separately: whether every key is gated at all,
and whether each gated key points where `clients.conf` says it should.

### 3A — every entry carries the forced command and `restrict` ✅

**Run** (on the host)

```bash
podman exec borg-server cat /home/borg/.ssh/authorized_keys \
  | grep -vE '^\s*#' | grep -vE '^\s*$' \
  | grep -cvE '^command="/borg-wrapper\.sh [^"]*",restrict '
```

Both halves of the generated entry are checked, because the claim names both.
`command=` routes the session through the wrapper; `restrict` is what withdraws
port and agent forwarding, X11, TTY allocation and `~` escapes from that key. A
line carrying the first without the second passes any check that looks only for
the prefix, and it is a plausible hand edit — the automated suite
(`tests/authorized-keys-generation.sh` 1.3) asserts both, so the check that
examines a real deployment should not ask for less. Test 1.5 is what still
refuses those things when this line is wrong, which is the reason to run both
tests rather than either.

**Pass** — output is `0`.

**Fail** — a nonzero count identifies keys that bypass the wrapper entirely, or
keys that run through it without `restrict`. Remove them, regenerate the file by
restarting the container, and re-run tests 1 and 2.

**Negative test** — staged and confirmed: both documented variants appended
to a live `authorized_keys` in turn — a key with no `command=` at all, then
(from a clean state) one with a correct prefix but no `,restrict` — and this
check's count rose from `0` to `1` for each, one at a time. The
`,restrict`-missing variant passed every other check on this page: tests 1
and 2, run against it, saw nothing wrong. Its practical reach was measured
directly rather than assumed — port forwarding attempted over that key
failed, but only because `AllowTcpForwarding no` in the daemon (check 1.5A)
blocked it, confirming the "lock behind the lock" 1.5 describes. Restored by
a container restart, which regenerates the file from `clients.conf`.

### 3B — every entry points at the repository `clients.conf` assigns ✅

**Run** (on the host, in `bash` — process substitution)

```bash
diff <(podman exec borg-server \
         grep -oE '^command="/borg-wrapper\.sh [^"]*"' /home/borg/.ssh/authorized_keys \
       | sed -E 's|^command="/borg-wrapper\.sh ||; s|"$||' | sort) \
     <(grep -vE '^\s*(#|$)' config/clients.conf | cut -d: -f3 | sort)
```

This answers what no count can. An entry with a correct prefix and *another
client's* path is a complete isolation failure that leaves 3A at `0`. Test 7
asks for this comparison in its `Fail` paragraph, one client at a time; this is
the same comparison made for every client at once.

**Pass** — no output.

A `>` line is the one output that can be legitimate: it names a repository
configured in `clients.conf` for which no key has been provisioned yet.
`build_authorized_keys.sh` skips such a client with
`[WARN] No public key found for '<name>'` in the container log, which is where
to confirm it. A `<` line never is — it names a forced command with no matching
line in `clients.conf`, either a repository nobody configured or one claimed by
more keys than were assigned to it. A `diff` reporting a change (`<` and `>`
together) is the second case with a name: one client's key carrying another
client's path.

**Fail** — any `<` line. Remove the entry, regenerate the file by restarting the
container, and if it named another client's path, treat test 7 as failed for
that key until you have re-run it.

**Negative test** — staged and confirmed (v0.1.0-beta.31): a second key was
appended with a correct `command=` prefix but pointed at
`/repo/OWN/mint-client` — another client's path. The `diff` reported a `<`
line for exactly that path, since `clients.conf` names it once and
`authorized_keys` then carried it twice.

**What this does not show** — that the wrapper named in `command=` is the
wrapper this project ships. Both checks read a path; test 0 is what establishes
that the binary behind it came from this source, and tests 1, 2 and 7 are what
show it behaves accordingly.

> The file is regenerated from `clients.conf` on every container start and
> swapped atomically, so a manually added line does not survive a restart.
> That limits exposure; it does not remove the need to check.

---

## 4. The container runs rootless

**Claim** — [Best Practices](BEST_PRACTICES.md) Chapter 1: rootless Podman is
mandatory, not a recommendation.

**Why it matters** — rootless execution is what makes a container escape land
on an unprivileged user rather than on host root. It is also why a
compromised container cannot clear an immutable flag: it holds no
`CAP_LINUX_IMMUTABLE`.

All three run on the host, **as the service user**. The order matters: 4A and 4B
describe the environment, and only 4C describes this container.

### 4A — podman itself is rootless ✅

**Run**

```bash
podman info --format '{{.Host.Security.Rootless}}'
```

**Pass** — `true`.

**Fail** — `false`. Note what this answers: the podman that ran the command, for
the account that ran it. Under the wrong account it reports `true` while the
container runs rootful under another, which is why it is the weakest of the
three and why 4C exists.

**Negative test** — staged and confirmed: the same command, run with `sudo`
against the same host's rootful Podman, reported `false`, against `true` for
the unprivileged account queried the same way. No separate installation was
needed — the check's own weakness, named above, is exactly why: it answers
for whichever account ran it.

### 4B — the container is a user service ✅

**Run**

```bash
systemctl --user show container-borg-server.service \
    -p LoadState -p ActiveState -p SubState -p FragmentPath
```

**Pass** — loaded, running, and a unit file that belongs to this user:

```
LoadState=loaded
ActiveState=active
SubState=running
FragmentPath=/var/home/<user>/.config/systemd/user/container-borg-server.service
```

`--user` already carries half the claim — it addresses the calling user's own
manager, in which a system-wide unit does not exist — and `FragmentPath` is
what makes that visible instead of implicit.

**Fail** — a system-level unit, or a user unit that is not running. A container
started by hand outside systemd also fails here, and should: nothing restarts it
and nothing records why it stopped.

`systemctl --user status … | head -3` stood here before and cannot show this:
on Fedora CoreOS the distribution ships a service drop-in whose path prints on
its own continuation line, which puts `Active:` on line 5 — and the number of
drop-ins is not fixed, so no larger constant is reliable either (#23). `show`
prints the properties themselves and stays a measurement rather than a
rendering, which is why `99-container-status.sh` reads the unit state the same
way.

**Negative test** — staged and confirmed (v0.1.0-beta.31): the previous
criterion (`head -3`) was shown to fail to display `Active:` on Fedora CoreOS
(#23), which is why this check reads properties with `show` rather than a
fixed number of lines from `status`. The check's own criterion has since been
staged too: with the unit stopped, this **Run** reported
`ActiveState=inactive` / `SubState=dead` in place of `active`/`running`.

### 4C — the container's own processes belong to an unprivileged user ✅

**Run**

```bash
ps -o user=,uid=,pid=,cmd= \
   -p "$(podman inspect -f '{{.State.ConmonPid}},{{.State.Pid}}' borg-server)"
```

`State.Pid` is the container's own init process as the host sees it and
`State.ConmonPid` its supervisor, so this asks the host who owns precisely those
two — not every `conmon` on the machine, and not the account that happened to
type the command.

**Pass** — both processes belong to your unprivileged service user, with a
nonzero uid. Rootless podman maps the container's internal root into that user's
subuid range, so nothing on the host side of this container is uid 0.

**Fail** — either process owned by `root` (uid 0) means the deployment is not
security-hardened in the sense this project uses the term, regardless of
anything else being correct.

**Negative test** — staged and confirmed: a second container, built from the
*same image digest* as the production instance, started rootful by hand
(`sudo podman run`, its own port and directories, the production container on
its own port left untouched). This check's command, run against its conmon
and init PIDs, reported `root`/uid 0 for both — against `core`/uid 1000 for
the production container queried the same way. Removed afterward; `sudo
podman` confirmed no container, image or directory was left behind.

**What this does not show** — that the host itself is hardened. Rootless podman
bounds what a container escape reaches; SELinux enforcing, an immutable OS and
kernel isolation are host-layer properties this project requires and does not
implement, and this page does not verify them (see the closing section).

---

## 5. The volume's quota is enforcing, not merely accounting

**Claim** — [Best Practices](BEST_PRACTICES.md) Chapter 1 and Chapter 6:
repository storage on XFS mounted with **enforcing** `prjquota`.
`pqnoenforce` (accounting only) does not satisfy this.

**Why it matters** — with accounting only, a single client can fill the
volume and deny service to every other client. The limits shown to clients
would be advisory fiction.

Both checks run on the host and describe the **volume**. Whether each client is
then held to the limit `clients.conf` records is a different question with a
different repair, and is test 5.5.

### 5A — the mount enforces project quotas ✅

**Run**

```bash
findmnt -no OPTIONS /var/mnt/extern1 | tr ',' '\n' | grep -E 'prjquota|pqnoenforce'
```

**Pass** — `prjquota`, and **not** `pqnoenforce`.

**Fail** — `pqnoenforce` is accounting only: usage is counted, limits are never
applied. No limit set anywhere above this line means anything until the mount is
fixed — [Server Installation](SERVERINSTALL.md) step 0.

**Negative test** — staged (#22): see below.

### 5B — the filesystem reports project quota as enforcing ✅

**Run**

```bash
sudo xfs_quota -x -c 'state -p' /var/mnt/extern1 | grep -i enforce
```

`-p` restricts the report to project quota. Without it, `state` describes all
three quota types and prints `Enforcement: OFF` twice — user and group quota,
which nobody enabled here — while the `grep` removes the lines that say which is
which; the answer then cannot be read off its own output in either direction
(#18).

**Pass** — one line:

```
  Enforcement: ON
```

**Fail** — `Enforcement: OFF`. The mount option and this reading are checked
together because a `pqnoenforce` volume looks exactly like this; 5A is what
tells the two apart. Fix it at the volume, not at the client's quota.

**What this does not show** — that any particular client has a limit, or the
right one. A volume can enforce project quotas perfectly while a client's
project id carries no limit at all, which is test 5.5.

**Negative test** — staged (#18, #22): see below.

> **Both checks are verified, in both directions**, on Fedora CoreOS 44
> (kernel 6.12) with an XFS volume mounted `prjquota`. Correct state: 5A
> reported `prjquota` without `pqnoenforce`, 5B `Enforcement: ON` (#18). Broken
> state, produced with `sudo xfs_quota -x -c 'disable -p' <mount>`: 5A reported
> `pqnoenforce`, 5B `Enforcement: OFF`; both returned to passing after
> `enable -p` (#22).
>
> **What does not produce that state is `mount -o remount,noquota`.** XFS does
> not accept quota state changes on remount: the option is parsed, `mount` exits
> 0, and enforcement stays on. This page nominated that recipe until beta.28,
> which would have shown an operator every check still passing and taught them
> the checks do not discriminate — the precise opposite of the exercise (#22).

---

## 5.5. Each client is held to the limit `clients.conf` records

**Claim** — [Operations](OPERATIONS.md) Chapter 9: the quota in `clients.conf`
is the quota in force, for every client, and both the operator's listing and the
client's own info channel report it truthfully.

**Why it matters** — an enforcing volume with a client whose project id carries
no limit is the same outage as no enforcement at all, for that client. And a
limit that is enforced but *different* from the recorded one is worse than
either: every document, preview and listing describes a number that is not the
one holding.

### 5.5A — the operator's listing agrees with `clients.conf` ✅

**Run** (on the host)

```bash
./scripts/09-show-all-users.sh
```

**Pass** — every client's `CONFIGURED` column repeats that client's
`clients.conf` value unmarked, with no `(!)` in the `QUOTA` or `CONFIGURED`
columns and no hint under the listing. Every client `clients.conf` names
appears with a repository on disk: `MISSING on host` in the `USED` column is a
failure, not an empty value.

A `(!)` on the `Committed:` line is a different statement and does not decide
this check. It reports that the quotas jointly reach the volume (OPERATIONS
Chapter 10.2) — a capacity decision, and a legitimate one: three clients at
50G/50G/10G on a 100 GB volume are each enforced to the byte. Both markers mean
"look here"; only the ones in the columns are about whether the recorded limit
is the one in force (#17).

**Fail** — `none (!)` in the `QUOTA` column means no limit is enforced for that
client; with 5B passing, the volume is fine and the project id is not. A marked
value in `CONFIGURED` means a limit *is* enforced, but not the one
`clients.conf` records — the `QUOTA` column is the one in force. Re-apply the
intended value with `02-change-user-quota.sh` (OPERATIONS Chapter 9.4).

**Fail** — `n/a (!)` beside `MISSING on host` means the repository directory
`clients.conf` names does not exist. That client is not under the wrong limit;
it cannot connect at all: the wrapper answers `DENY: repository directory
missing – needs operator action` rather than creating a directory it could give
neither the right owner nor an XFS project id. `03-provision-client.sh` provisions
it again (OPERATIONS Chapter 9.4.1) — the directory, its ownership and its
project id, from what `clients.conf` still records. What it restores is the
client's access, not its archives: those went with the directory, so establish
where the directory went before running it.

Such a client also drops out of the `Committed:` sum, which is correct — no
directory means no enforced quota to add — but it leaves `Total clients:` and
the count on the `Committed:` line disagreeing. That disagreement is a second
tell for the same condition, and worth knowing about before it looks like an
arithmetic bug.

**Fail** — `n/a (!)` beside `unreadable` means the directory is there and `df`
reported nothing for it. This check cannot be answered for that client in
either direction, which is why it fails rather than passes: a measurement that
did not happen is not agreement. `statfs()` needs search permission on every
*parent* of the path, so look at the group directories and `HOST_REPO_BASE`
rather than at the client's own directory — and at whether the volume is still
mounted. A `(!)` on the `Disk usage:` or `Disk free:` line says the same thing
about the volume as a whole, and then no row of the listing is trustworthy.

**Negative test** — staged for the volume-wide and single-client drift cases
(#17, #22, #28), for the `MISSING on host` case (#30), and, as of
v0.1.0-beta.31, for an empty `HOST_REPO_BASE` too: blanking the variable and
running `09-show-all-users.sh` produces exactly the `n/a (!)` /
`HOST_REPO_BASE not set` branch `lib.sh` already carries for it. For
`unreadable`, both host-side `chmod` candidates named in [Test
Environment](TESTENV.md) chapter 8 have now been tried and ruled out — one on
a group directory (#33), one on `HOST_REPO_BASE` itself — and both land on
`MISSING on host` instead, not `unreadable`, because `report_for()` in
`09-show-all-users.sh` checks `[ -d "$d" ]` before it runs `df -kP "$d"`, and
both calls need the same search permission on the same parent directories: any
`chmod` that breaks one breaks the other first. See [Roadmap](../ROADMAP.md)
11.8 for the resulting conclusion — this branch is believed reachable only by
a genuine `statfs()` failure, not by any host-side permission change. See
below.

### 5.5B — the client is told its own limit ✅

**Run** — from the client:

```bash
ssh borgserver info
```

**Pass** — the total in the `Used:` line is *your own* configured limit:

```
quota (configured): 50G
Used: 2.4 GiB of 50.0 GiB (5%)
```

The channel prints two limits, and the criterion is deliberately about the
second one. `quota (configured):` is the value `clients.conf` held when the
container last rendered this text; the `Used:` total is read from the enforcing
filesystem quota at the moment you ask, and **that is the figure in force**.
They agree on a deployment that has not drifted, which is what a pass looks
like.

**Fail** — the two disagree, in either of two shapes:

- The `Used:` total is **the size of the whole underlying disk**. Project-quota
  enforcement is not active at all: this client is bounded by nothing but the
  volume. The single most common misconfiguration, invisible until a client
  fills the disk.
- The `Used:` total is **some other figure** than `quota (configured):` — 20 GiB
  against a recorded 50G, say. Enforcement works, but this client's project id
  carries a limit nobody recorded. The enforced one is what holds; the recorded
  one is what every document, preview and listing will keep claiming.

Both are the operator's to repair (`02-change-user-quota.sh`, OPERATIONS Chapter
9.4), and 5.5A is where the host side sees them — `none (!)` in the `QUOTA`
column for the first, a marked `CONFIGURED` value for the second. What makes
this check worth running separately is that it needs nobody on the host: it is
the one failure of this kind a client can see for itself.

One route into this state is closed by the tooling itself: `00-` and `02-`
refuse a quota above 99% of the volume, because a limit at or above the volume
size is reported back through `statvfs()` as the whole volume and is therefore
indistinguishable from no limit at all — the very condition this check looks
for. Asking for one is a quick way to see that the refusal works.

**What this does not show** — that the limit is *appropriate*. Whether the
recorded quotas oversubscribe the volume is a capacity decision the listing
reports on its `Committed:` line and this test deliberately does not judge.

**Negative test** — staged (#17, #22, #28): see below.

> **Both checks are verified, in both directions.** Correct state: on a
> deliberately overcommitted installation with three clients at 50G/50G/10G,
> 5.5A listed every `CONFIGURED` value unmarked and 5.5B reported each client
> its own limit (#17). Broken state, with enforcement switched off at the volume
> (`sudo xfs_quota -x -c 'disable -p' <mount>`): 5.5A listed `none (!)` as the
> enforced quota against a `CONFIGURED` of `50G (!)` for every client, and 5.5B
> reported `Used: 1.9 GiB of 99.9 GiB` — the whole volume against a 50G quota,
> which is this check's failure text word for word (#22).
>
> **The narrower case is now staged too**, and it is the one 5.5A is really for:
> a *single* client whose project id carries a wrong limit while the volume
> enforces normally for everyone else. The measurement above takes enforcement
> away from all clients at once, so it shows the listing reacting to a
> disagreement, not that it localizes one. Drifting one client alone
> (`sudo xfs_quota -x -c 'limit -p bhard=20g <projid>' <mount>`, leaving
> `clients.conf` untouched) settles that: 5.5A marked `50G (!)` on exactly that
> client, listed its enforced `20.0 GiB`, and left the other two unmarked;
> `02-change-user-quota.sh <client> 50G` restored it (#28).
>
> 5.5B did **not** see that state as it was then written, and that is what its
> criterion above was rewritten for. The client was shown `quota: 50G` beside
> `Used: 1.1 MiB of 20.0 GiB` — two limits, neither of them the whole disk, so
> the old failure text did not apply and the check read as a pass while the
> client was held to a limit nobody had recorded. The recorded value is now
> labelled `quota (configured):` at the source, and the criterion decides on the
> `Used:` total (#28).
>
> **A third state was staged afterwards and 5.5A did not see it either**:
> a client whose repository directory had been deleted outright
> (`podman unshare rm -rf <HOST_REPO_BASE>/OWN/<client>`). The listing reported
> it honestly as `MISSING on host`, but in the `USED` column only — `QUOTA` read
> `n/a`, `CONFIGURED` was unmarked, and nothing had drifted, so all three
> clauses of the criterion above were satisfied by a client that could not
> connect at all (#30). `09-show-all-users.sh` now marks that row `n/a (!)` and
> explains it under the listing, which is what makes the criterion decide it.
> **That marker has since been verified against a deployment** (v0.1.0-beta.31):
> a client's own repository directory, and separately a whole group directory
> under it, were each removed, and the listing marked the affected rows exactly
> `n/a (!)` / `MISSING on host` as documented, for every client under a removed
> group directory at once in the second case. `03-provision-client.sh` restored
> access afterwards.
>
> The same reasoning was then applied to the other states this listing cannot
> measure — `unreadable`, and a `HOST_REPO_BASE` that names nothing — which are
> now marked as well. `(!)` means one thing everywhere in that report: this
> needs attention, something here is not right. A figure that could not be read
> qualifies, because a criterion deciding on those columns would otherwise call
> a failed measurement an agreement. **An empty `HOST_REPO_BASE` has since been
> staged on a bench and confirmed (v0.1.0-beta.31). `unreadable` has not been
> staged — and, per [Roadmap](../ROADMAP.md) 11.8, both `chmod` candidates for
> it have since been tried and ruled out, so it may not be stageable by a
> host-side permission change at all.**

---

## 6. No key material exists on the server ✅

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

A nonzero count does not automatically mean test 8 is failing, though. Test 8
creates a repokey repository (`<repo-repokey>`) to prove the wrapper refuses
it, and that repository is meant to be cleared right after — see test 8's
Cleanup step, [Operations](OPERATIONS.md) 9.12. If that cleanup was skipped,
the leftover repository is what this check is finding: enforcement is still
working, the repository is just still there. Confirm which case you're in
before assuming enforcement broke — repeat test 8's **Run** against the
flagged repository. `borg list` still refused means this is the uncleaned
leftover: clear it via 9.12 and re-run this check. `borg list` succeeding
means enforcement has actually failed and the passphrase-strength caveat
above applies.

**Negative test** — staged and confirmed (v0.1.0-beta.31): the repokey
repository test 8 leaves behind was read with `grep -H` instead of a bare
count. It reported one `key = ...` line for that repository and none for any
keyfile-mode repository on the same host — the check finds key material where
it exists and stays silent where it does not.

**`Permission denied` is not a pass.** Run without `podman unshare`, both
commands fail on every repository — and the `find` then prints only
`Permission denied` lines and no matches, which reads exactly like the pass
criterion above. It means the check never looked inside a repository. Re-run it
through `podman unshare`; a count of `0` printed per `config` file is what a
test that actually ran looks like.

**What this does not show** — that no key material ever reaches the server in
future. This is a measurement of the repositories as they are now; test 8 is the
mechanism that keeps it true, and the two belong together. It also says nothing
about key material outside the repository tree — a client that mails its keyfile
to the operator has defeated the claim in a way no server-side check can see.

---

## 7. Clients cannot reach each other's repositories ✅

**Claim** — [Design](DESIGN.md) Chapter 1.2: strict per-client isolation, via
the forced command's fixed repo path plus borg's `--restrict-to-path`. The
path a client sends is never trusted.

**Why it matters** — cross-client access would leak both data and metadata
between unrelated parties, including between `OWN` devices and external
`MIRROR` partners.

**Run** — from client A, aim at client B's repository path:

```bash
borg list ssh://borgserver/repo/OWN/<other-client>
borg list ssh://borgserver/repo/
borg list ssh://borgserver/etc/
```

**Pass** — all three fail. The client's own repository remains accessible;
no path outside it is.

**Fail** — if any listing succeeds, isolation is broken for that key. Verify
the `command=` path in `authorized_keys` matches the repo assigned in
`clients.conf` — 3B is that comparison for every client at once.

**Negative test** — staged and confirmed (v0.1.0-beta.31), using 3B's own
failing state: with a second key authorized for `/repo/OWN/mint-client`
(another client's path), `--restrict-to-path` let the connection through —
none of the `Repository path not allowed` refusal a genuinely foreign key
gets. The attempt stalled afterwards only on the client-side passphrase
prompt, which is test 8's protection, not this check's; the path itself was
reached, which is the isolation failure this check exists to catch.

**What this does not show** — isolation for keys you did not test with. This is
measured per key, from the client that holds it; 3B is what covers the rest of
the file. Nor does it say anything about what the *operator* can reach, which is
everything: this project isolates clients from each other, not from the host.

---

## 8. Only client-held keyfile encryption is accepted ✅

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

**Run** — `<repo-repokey>` is a *separate* repository path from your `<repo>`,
provisioned for this one test. Ask your operator for one; running this against
your real repository is not possible anyway, since it already exists and
`borg init` refuses a directory that is not empty.

```bash
borg init --encryption=repokey <repo-repokey>   # succeeds — nothing to inspect yet
borg list <repo-repokey>                        # must be refused
```

**This path is spent after the test.** Every later connection to it dies at the
same gate, which is the result being demonstrated — so `<repo-repokey>` is not a
scratch path that later tests can reuse, and no test below refers to it. Getting
it back into a usable state is an operator-side repair: [Operations](OPERATIONS.md)
Chapter 9.12, second row of its table. Note that clearing it destroys the
repokey repository along with anything written into it, which is why nothing but
throwaway data belongs in it.

**Pass** — the second command fails with one of:

```
DENY: repo stores key material server-side (not keyfile mode)
DENY: not a keyfile repository (key type 0x03); only client-held keyfile encryption is permitted
```

Both checks are independent and fail closed; either message is a pass.

**Fail** — if `borg list` succeeds against a repokey repository, the
encryption policy is not being enforced, and test 6 will start finding key
material on the server.

**Cleanup — do this before treating the pass as finished.** A *passing* test 8
leaves `<repo-repokey>` sitting on the server in repokey mode — that is the
"spent" state described above. Left in place, it is exactly what check 6
finds key material on the next time this checklist is run, which reads as a
check-6 failure even though nothing is wrong. Clear it now:
[Operations](OPERATIONS.md) 9.12, second row of its table. Skipping this
turns a one-time test artifact into a standing false alarm on every later
pass.

**Negative test** — staged and confirmed in both directions (v0.1.0-beta.31).
The **Run** above already stages the broken-mode repository itself, so this
check's own **Pass** criterion *is* one negative observation: the current,
correct wrapper refuses it, with the exact `DENY: repo stores key material
server-side` text reproduced. The other direction — deliberately disabling the
encryption gate and confirming this check would then let `borg list` succeed —
has since been staged too, on a throwaway bench deployment (own port, own
repository, own client) rather than the production instance: the gate in
`/borg-wrapper.sh` was disabled by replacing its guard with `if ! true`, and
against the same `repokey` repository both `borg list` and `borg info`
succeeded, matching this check's **Fail** condition exactly. The bench
container, checkout and repository were removed afterwards; the production
instance was not touched. `tests/wrapper-gating.sh` covers the same direction
against the code.

**What this does not show** — that the client's key is well kept. The server can
refuse to hold key material; it cannot verify that the client stored its keyfile
somewhere other than next to the backup, or that the passphrase is strong. That
half is [Client Usage](CLIENTUSE.md) chapter 3, and no server-side test reaches
it.

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
ssh borgserver info        # note "Used:"
head -c 1M /dev/urandom > /tmp/probe.bin
borg create <repo>::verify-probe /tmp/probe.bin
ssh borgserver info        # must have grown
borg delete <repo>::verify-probe
borg compact <repo>
ssh borgserver info        # decisive
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

**Negative test** — built into **Run** itself: the table under **Pass** is a
correct-state measurement beside the broken-state one it would produce, both
recorded against Borg 1.2.8.

> Verified again against `v0.1.0`, on both bench clients (Borg 1.2.8 on Linux
> Mint 22.3, Borg 1.4.0 on Debian 13): usage stayed at the raised level after
> delete + compact on both (Mint: 3.9→5.0→5.0 MiB, Debian: 3.0→4.1→4.1 MiB) —
> no rollback on either client version.

**Why 1 MB is enough:** every `borg create` writes into fresh segment files
rather than extending existing ones, so the probe sits alone in its own
segment. Deleting it leaves that segment essentially fully unused — far above
the threshold `borg compact` requires before rewriting a segment
(`--threshold`, default 10%). A larger probe buys nothing.

**Why the data must be incompressible:** deduplication and compression would
reduce a nominal megabyte to a few kilobytes and leave the measurement in the
noise.

**What this does not show** — that deleted data is *recoverable*. Append-only
means the segments are still there; turning that into a restored archive is a
manual, two-party procedure ([Recovery](RECOVERY.md) Section 1), and a
deployment that passes this test has not thereby rehearsed it. The measurement
also depends on 5B: it reads physical usage through the enforcing project quota,
so on a volume that is not enforcing, this test cannot be read at all.

---

## 10. A client cannot destroy its whole repository ✅

**Claim** — follows from append-only: destroying a repository requires
removing segments, which append-only forbids.

**Why it matters** — an attacker who cannot delete archives one by one would
otherwise simply delete the repository.

**Run** — against `<repo>`, the client's own working keyfile repository, exactly
as test 9 does:

```bash
BORG_DELETE_I_KNOW_WHAT_I_AM_DOING=YES borg delete --force <repo>
```

**This is a test with a stake in it.** It really does attempt the destruction:
if append-only holds, nothing happens, and if it does not, the repository is
gone. Run it against a repository whose loss you can afford — the bench client
from [Test Environment](TESTENV.md), not a repository already holding backups
you rely on. That is the price of measuring the claim instead of deducing it.

**Pass** — the command fails, borg names the reason, and the repository remains
intact with all its segments:

```
ValueError: /repo/OWN/<client> is in append-only mode
```

Verified against Borg 1.2.8: the same command against a repository without
append-only destroys it completely.

> Verified again against `v0.1.0`, on both bench clients (Borg 1.2.8 and Borg
> 1.4.0): identical `ValueError: … is in append-only mode`, exit 2, repository
> unchanged on both.

The message is the part that discriminates, which is why the criterion names it.
A `DENY:` line instead means the connection was refused *before* append-only was
ever consulted — most likely the repository aimed at was `<repo-repokey>` from
test 8, which the encryption gate rejects on every connection. The command fails
and the repository survives in that case too, so the outcome looks like a pass
while nothing about append-only was measured (#27). Check which repository you
addressed and run it again.

**Fail** — a repository that actually disappears means append-only was not in
effect for that connection. Return to test 3.

**Negative test** — staged (#27): a repository without append-only was
destroyed by the same command, confirming this check's criterion discriminates.
See below.

**Read the traceback while you have it.** Borg prints the server's own command
line beside the error:

```
Borg server: sys.argv: ['/usr/bin/borg', 'serve', '--restrict-to-path', '/repo/OWN/<client>', '--append-only']
Borg server: SSH_ORIGINAL_COMMAND: 'borg serve'
```

The client sent `borg serve`; the server ran it with both flags of its own
accord. That is the cheapest confirmation on this page that no client-supplied
argument widened `--restrict-to-path` or `--append-only`, and it comes free with
a correctly aimed test 10.

**What this does not show** — protection against the operator. This is a
statement about what a *client* can do; anyone with host access can remove the
repository directory outright, which is why off-site copies and the mirror
arrangement exist rather than being optional.

> Verified, in both readings, against `v0.1.0-beta.29` with a Borg 1.2.8 client.
> Against the client's own keyfile repository the command stops at
> `ValueError: … is in append-only mode`, and `borg info` afterwards reports the
> repository with its ID unchanged. Against the repokey path from test 8 it
> stops at `DENY: repo stores key material server-side` instead. Both exit `2`
> and both leave the repository standing — which is why this entry names the
> message rather than the exit code (#27).

---

## 11. Point-in-time snapshots survive host-side destruction

**Claim** — [Snapshots](SNAPSHOTS.md) / [Roadmap](../ROADMAP.md) 11.5: a completed snapshot generation under `SNAPSHOT_BASE` is made immutable (`chattr +i`) and cannot be removed by an ordinary command, not even the operator's own `sudo rm -rf`, and restoring one reconstructs the client's XFS project id and enforced quota exactly as they were — not a freshly allocated approximation of them.

**Why it matters** — this is the local, fast half of recovering from operator error or destructive host-side software ([Recovery](RECOVERY.md) Chapter 5). If a completed generation could be removed the same way its live source can, the rollback path is exposed to exactly the class of accident it exists to survive. And a restore that silently drops or mis-applies the quota leaves a repository that looks recovered but is no longer protected — the failure mode [`77-restore-last-snapshot.sh`](SNAPSHOTS.md#7-restoring-the-most-recent-snapshot--77-restore-last-snapshotsh)'s own header calls out by name.

Three checks, each against a different part of the claim. All run on the host, against a disposable client — see [Snapshots](SNAPSHOTS.md) for `SNAPSHOT_BASE`'s default layout.

### 11A — a completed generation resists deletion, even by root ✅

**Run**

```bash
./snapshots/70-create-snapshot.sh
GEN=$(ls -d /var/mnt/extern1/.snapshots/borg-server/<client>/*/ | tail -1)
lsattr -d "$GEN"
sudo rm -rf "$GEN"
```

**Pass** — `lsattr -d` shows the immutable flag (`i` in the fifth column), and the deletion fails, on the directory itself and every file under it:

```
rm: cannot remove '.../marker.txt': Operation not permitted
```

The generation and its contents are unchanged afterward.

**Fail** — `lsattr` does not show `i`, or `rm` succeeds. Either means this generation is not actually protected. Check that `chattr +i` genuinely ran (the script's own read-back after setting it is what `70-create-snapshot.sh` exists to not skip) and that the kernel/filesystem combination supports `CAP_LINUX_IMMUTABLE` on this volume.

**Negative test** — measured directly, both readings, against `FCOS-BorgBackupServer` (2026-08-27): a generation with the flag confirmed set by `lsattr` was attempted for deletion with `sudo rm -rf` and failed with `Operation not permitted` on every file it reached. The identical directory tree — same ownership, same mode, same content — deleted cleanly once `sudo chattr -R -i` was run against it first, which is exactly the two-step sequence `76-delete-snapshots.sh` performs deliberately, and only after its own confirmation prompt.

**What this does not show** — protection against an attacker holding root who *clears the flag first*. `chattr -i` is reversible by root by design; a permanently unclearable copy is not the property this mechanism provides, and is not claimed to be — offsite mirroring, not snapshots, is the answer to a root-level host compromise (see [Snapshots](SNAPSHOTS.md), "What this does not protect against").

### 11B — restore reconstructs the exact quota and project id ✅

**Run** — against a client with at least one snapshot generation:

```bash
lsattr -p -d <live-repo>                            # note the project id
df -kP <live-repo> | awk 'NR==2{print $2}'          # note the enforced KiB
echo drift > <live-repo>/some-file-added-after-the-last-snapshot
./snapshots/77-restore-last-snapshot.sh <client>    # type Y
lsattr -p -d <live-repo>                            # must match
df -kP <live-repo> | awk 'NR==2{print $2}'          # must match, exactly
ls <live-repo>                                      # the drift file must be gone
```

**Pass** — the project id and enforced KiB read identical before and after, the script's own `[restore] Verified: quota identity matches what this client had before (...)` line appears, and the drift file is gone — the directory holds the snapshot's content, not whatever the live directory had accumulated since.

**Fail** — the comparison doesn't fire: after a mismatch is introduced (see **Negative test**), the script prints no error and copies content back regardless, leaving a repository that looks recovered but is no longer held to its limit — silently, since nothing about a working repository announces that its quota stopped applying. A plain run of **Run** above cannot produce this by itself; the script's own check exists precisely to prevent a normal restore from ever reaching this state.

**Negative test** — staged directly against `FCOS-BorgBackupServer` (2026-08-27), both readings:

The passing direction is the drift-file measurement above: a disposable client (project id `1011`, a 2.0 GiB limit) restored cleanly, drift file gone, project id and enforced KiB (2,097,152) identical before and after.

The failing direction needed a genuine race, not a sequential recipe — `OLD_ENFORCED_KIB` is read once early in the script and `NEW_ENFORCED_KIB` once near the end, and nothing between those two reads normally changes the project id's limit. So the script was started in the background, its output polled for the `[restore] Deleting current repository:` line, and the process was frozen with `kill -STOP` the instant that line appeared — reliable because the whole run is a fraction of a second and that line prints well before either quota is read. While frozen, `sudo xfs_quota -x -c 'limit -p bhard=999m 1011' /var/mnt/borg-repo` changed the *same* project id's limit out from under it (a plausible real event: nothing about `77-` locks a client's XFS project quota against a concurrent `02-change-user-quota.sh` or a manual `xfs_quota` call — only `SNAPSHOT_BASE/.lock` against other snapshot tooling). `kill -CONT` released it. The script's own comparison caught the mismatch and stopped before copying any content back:

```
ERROR: after re-applying project id 1011, the enforced quota on
       '/var/mnt/borg-repo/repo/OWN/racetest01' is '1022976', not the original
       2.0 GiB. The directory exists but is NOT
       correctly quota-protected -- needs manual attention before this
       client is used again.
```

The directory was left exactly as that message describes — present, empty, quota-mismatched, no snapshot content copied in — and the snapshot generation itself was untouched throughout. Restoring the tampered limit back to 2 GiB and re-running the identical restore, on the same client, immediately afterward, reproduced the passing direction again: `[restore] Verified: quota identity matches what this client had before (2.0 GiB)`, content restored.

**What this does not show** — that the restored *content* is byte-correct beyond what this one drift file demonstrates; `cp -a --reflink=always`'s own copy correctness against a live, actively-written repository is upstream of this project's code, and was measured separately (see [Snapshots](SNAPSHOTS.md), "Creating snapshots").

### 11C — deletion refuses to follow a path outside `SNAPSHOT_BASE` ✅

**Run** — replace a generation with a symlink pointing outside `SNAPSHOT_BASE`, then delete it through the normal tooling:

```bash
mkdir -p /tmp/external-target && echo keep > /tmp/external-target/marker
ln -s /tmp/external-target /var/mnt/extern1/.snapshots/borg-server/<client>/<a-valid-timestamp>
./snapshots/76-delete-snapshots.sh <client> <that-timestamp> <that-timestamp>   # type Y
cat /tmp/external-target/marker
```

**Pass** — refused before anything is touched:

```
ERROR: '/tmp/external-target' does not resolve inside SNAPSHOT_BASE
       ('/var/mnt/extern1/.snapshots/borg-server') -- refusing to touch it.
```

`/tmp/external-target/marker` reads back unchanged.

**Fail** — the external file is modified or removed. `SNAPSHOT_BASE`'s own canonicalization check (`cd ... && pwd -P`, resolving symlinks before anything is compared) is not doing its job, and this is the most dangerous code in the deployment trusting an unverified path.

**Negative test** — measured directly against `FCOS-BorgBackupServer` (2026-08-27): the symlink above was created and `76-delete-snapshots.sh` was run against it with an affirmative `Y` at the confirmation prompt; it refused with the message shown under **Pass**, and the external file survived untouched. The positive direction is 11A's own deletions: the same run that produced 11A's evidence also deleted several genuine generations cleanly, so this check's refusal is measured against a tool that is otherwise known to actually delete what it is pointed at.

**What this does not show** — resistance to an attacker who already has host-level write access to `SNAPSHOT_BASE` itself. The check is that a *generation name resolving somewhere else* is caught; a target that genuinely lives inside `SNAPSHOT_BASE` but was tampered with in place is a different threat this check says nothing about.

---

## Summary checklist

One row per check, not per test: a test with lettered checks is only complete
when every letter is. **Check** repeats the marker from the entry — whether the
check itself has been shown to discriminate — and **Your run** is yours to tick.

| # | Property | Check | Your run |
|---|---|---|---|
| 0A | Attestation verifies and names this repository (do this first) | (✅) | ☐ |
| 0B | The verified index digest is the one pinned in `IMAGE` | ✅ | ☐ |
| 0C | The running container was started from that digest | ✅ | ☐ |
| 0.5A | The key authenticates and the info channel answers | ✅ | ☐ |
| 0.5B | The client can initialize its repository | ✅ | ☐ |
| 1 | No interactive shell | ✅ | ☐ |
| 1.5A | The daemon's own configuration is hardened | ✅ | ☐ |
| 1.5B | The `borg` account resolves to the same configuration | ✅ | ☐ |
| 1.5C | No `Match` or `Include` makes it conditional | ✅ | ☐ |
| 2 | Default-deny on commands | ✅ | ☐ |
| 3A | Every entry carries the forced command and `restrict` | ✅ | ☐ |
| 3B | Every entry points at the repository `clients.conf` assigns | ✅ | ☐ |
| 4A | Podman itself is rootless | ✅ | ☐ |
| 4B | The container is a user service | ✅ | ☐ |
| 4C | The container's processes belong to an unprivileged user | ✅ | ☐ |
| 5A | The mount enforces project quotas | ✅ | ☐ |
| 5B | The filesystem reports project quota as enforcing | ✅ | ☐ |
| 5.5A | The operator's listing agrees with `clients.conf` | ✅ | ☐ |
| 5.5B | The client is told its own limit | ✅ | ☐ |
| 6 | No key material on the server | ✅ | ☐ |
| 7 | Clients isolated from each other | ✅ | ☐ |
| 8 | Keyfile-only encryption enforced | ✅ | ☐ |
| 9 | Append-only enforced | ✅ | ☐ |
| 10 | Repository destruction blocked | ✅ | ☐ |
| 11A | A completed snapshot resists deletion, even by root | ✅ | ☐ |
| 11B | Restore reconstructs the exact quota and project id | ✅ | ☐ |
| 11C | Deletion refuses a path outside `SNAPSHOT_BASE` | ✅ | ☐ |

Twenty-six ✅ and one `(✅)` out of twenty-seven — every check on this page is
now either fully verified or capped, none still resting on a single
successful run. 0A is the sole capped exception, at `(✅)` rather than plain
✅, because its counter-example cannot be produced at all — not because
nobody has tried (see "How to read a test"). That does not make the page
complete — see [What this document does not cover](#what-this-document-does-not-cover)
below, and 5.5A's own note on the one sub-case (`unreadable`) no recipe has
reached — only that no row still rests on reasoning alone where measurement
was possible.

A deployment that fails **0A** has not been verified at all — the remaining
results describe an artifact of unknown origin, and **0B** is what keeps that
result true past the next `podman pull`. A deployment that fails either half of
**0.5** is not a deployment yet: no client can use it, and every test below it
is unrunnable. A deployment that fails any check from **1 through 5.5** should
not be considered hardened. A deployment that fails **6–10** is not providing
the guarantees this project exists to provide. A deployment that fails **11**
is a narrower gap than any of those — every guarantee through 10 still holds —
but it means [Recovery](RECOVERY.md) Chapter 5's local rollback is not
actually available when an operator reaches for it, which is the moment its
absence is most expensive to discover.

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
- **Running any of this automatically** — every check here is invoked by hand,
  on purpose. A runner for the host-side ones is planned and scoped in
  [Roadmap](../ROADMAP.md) 11.6, including why the client-side checks stay
  manual: driving them from the server would mean the server holding a client
  key.
- **Unattended, retention-driven pruning of old snapshot generations** — does
  not exist. Test 11 checks what the shipped `snapshots/` scripts actually do;
  an age-based "keep the last N generations" mode remains an open question
  (Roadmap 11.5), and there is nothing to verify until one is built.
