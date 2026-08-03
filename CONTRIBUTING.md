# Contributing

Thanks for looking at this project closely enough to want to change something.

This is a small, deliberately narrow project maintained by one person. The
sections below describe what is welcome, what is explicitly out of scope, and
what a change has to come with to be reviewable.

> **Security problems do not belong here.** Do not open an issue for a
> vulnerability — including a documented guarantee that turns out not to hold.
> Use the private channel described in [SECURITY.md](SECURITY.md).

---

## 1. Before you start

**Issues are welcome** — bug reports, questions about intended behaviour,
documentation that is wrong or unclear, and proposals. If something in the
documentation does not match what the code does, that is worth an issue on its
own; this project treats a false claim as a defect.

**Small pull requests** — a typo, a broken link, a wrong path in a doc, a
narrow bug fix — are fine to send directly.

**For anything larger, open an issue first.** That includes new behaviour,
changes to `borg-wrapper.sh`, changes to the container build, and restructuring
of documentation. The point is not bureaucracy: the design has a stated threat
model ([Design & Threat Model](docs/DESIGN.md)), and a change that conflicts
with it cannot be merged no matter how well it is implemented. Finding that out
before you write it saves your time, not the maintainer's.

---

## 2. Non-goals

These are not open questions. A pull request that does any of the following
will be declined, and it is not a judgement of the code:

- **No new services and no additional open ports.** The server exposes SSH and
  nothing else. No web UI, no API, no metrics endpoint, no auxiliary daemon
  inside the container. A small attack surface is the feature.
- **No server-side key handling.** The server never generates, stores,
  transports, escrows or recovers client encryption keys or passphrases.
  Repositories must be keyfile-encrypted and the key stays with the client —
  see [Design](docs/DESIGN.md) Chapter 2. "Convenience" features around key
  custody are exactly the thing this project refuses to build.
- **No weakening of the default-deny gate.** `borg-wrapper.sh` permits an
  explicitly listed set of commands and rejects everything else. New
  functionality may add a specific, justified entry to that allow-list; it may
  not invert the default, add a wildcard, or introduce an escape hatch that
  passes arbitrary arguments through.
- **XFS project quotas stay mandatory.** Enforcing `prjquota` is a hard
  requirement, not a recommendation, and accounting-only (`pqnoenforce`) does
  not satisfy it. Changes that make quotas optional, emulate them in
  application code, or degrade gracefully when they are missing are not wanted.

If you think one of these is wrong, that is a discussion for an issue — with
the threat-model argument, not with the patch.

---

## 3. What a pull request needs

**English code comments.** The documentation and all code comments are in
English, regardless of what language the issue discussion happened in. Comments
should explain *why*, not restate the line below them; the existing scripts are
the reference for the expected level of detail.

**Documentation kept in step.** If a change alters behaviour, requirements or
operator-visible output, update the affected documents in the same pull
request:

| If you touch | Check |
|---|---|
| `borg-wrapper.sh`, gating, isolation, append-only | [docs/DESIGN.md](docs/DESIGN.md), [docs/VERIFICATION.md](docs/VERIFICATION.md) |
| `Dockerfile`, `entrypoint.sh`, image tags | [README.md](README.md), [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| `scripts/`, `config/`, client or quota management | [docs/OPERATIONS.md](docs/OPERATIONS.md), [docs/SERVERINSTALL.md](docs/SERVERINSTALL.md) |
| client-facing behaviour | [docs/CLIENTUSE.md](docs/CLIENTUSE.md) |

A documented guarantee that the code does not support is a security issue in
this project (see [SECURITY.md](SECURITY.md)), so drifting documentation is not
a cosmetic problem.

**The test setup you used.** State it in the pull request, even if the change
looks trivial:

- Fedora CoreOS version
- Podman version
- SELinux mode (`getenforce`)
- Filesystem and whether `prjquota` is enforcing
- Borg version on the client

Everything except the client Borg version is also what a bug report needs, and
for the same reason: this project's behaviour is a property of the host stack
as much as of its own code. If you tested on the throwaway bench from
[docs/TESTENV.md](docs/TESTENV.md) rather than on real hardware, say so — that
is useful, not disqualifying.

**Tests where they exist.** The suites under `tests/` run in CI on every pull
request (see `.github/workflows/test.yml`) and can be run locally. If you
change wrapper behaviour, extend `tests/wrapper-gating.sh` to cover it; a new
guarantee without a test is a claim, and this project tries not to make those.

---

## 4. Commits and tags

Commit messages use a short `type: summary` subject line — `feat:`, `fix:`,
`docs:`, `test:`, `ci:`, `build:`, `chore:`, `release:`. Recent history is the
reference; the oldest commits predate the convention. Keep unrelated changes in
separate commits.

Release tags are `v<version>` and are what triggers the image build and publish
(`.github/workflows/docker.yml`). Newer release tags are **annotated** tags
(`git tag -a`) rather than lightweight ones: an annotated tag carries its own
message, so a state that has actually been verified on real hardware — not only
in CI or on a throwaway VM — can say so in the tag itself and stay
distinguishable later. Tagging is the maintainer's job; you do not need to tag
anything in a pull request.

---

## 5. Review

Expect review to focus on the threat model first and the implementation second.
A change that is correct but widens the attack surface will get pushback about
the surface, not about the code. If a pull request is declined, the reasoning
will be given in writing.
