# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting instead — the **Security** tab of
this repository, then **Report a vulnerability**. That channel is private
between you and the maintainer until an advisory is published.

A useful report names **which documented property is violated**. This project
states its guarantees explicitly in
[Design & Threat Model](docs/DESIGN.md) Chapters 1–4, so a report is most
actionable when it points at one of them:

- what you did, in enough detail to reproduce
- which claimed guarantee it breaks
- what you observed instead
- the version or image tag, and enough of the host setup to matter (Podman
  rootless or not, SELinux state, mount options on the repository volume)

## A disproved claim is a security report

This project asks its users not to trust it — [Verification](docs/VERIFICATION.md)
exists so that every asserted guarantee can be tested rather than believed.

That cuts both ways. **If you run one of those tests and it does not produce
the documented result, that is a vulnerability report**, whether or not you
have an exploit. A guarantee that is documented but not actually enforced is a
security problem in itself, because deployments are being built on it. The same
applies to a claim in any other document that the code does not support.

Reports of this kind are explicitly wanted and will be treated as security
issues, not as documentation bugs.

## Scope

**In scope** — the application layer this project actually ships:

- `borg-wrapper.sh` — the forced command: command gating, path restriction,
  append-only enforcement, the keyfile-encryption check
- `build_authorized_keys.sh` and `entrypoint.sh` — key provisioning, input
  validation, generated file permissions
- the container image and its build
- the host-management scripts under `scripts/`
- any documented guarantee that does not hold in practice (see above)

**Out of scope** — not because such issues do not matter, but because they are
not this project's to fix:

- **Host hardening.** SELinux, rootless Podman, the immutable OS and the XFS
  mount configuration are the operator's responsibility and explicitly outside
  scope ([Design](docs/DESIGN.md) 1.1 and 4.2). "The host was not hardened as
  required" is a deployment problem.
- **BorgBackup itself.** Report vulnerabilities in Borg to
  [the Borg project](https://github.com/borgbackup/borg/security). This project
  will track and respond to them, but is not their origin.
- **Known and documented limitations.** Everything in
  [Design](docs/DESIGN.md) 4.3 and 4.4 is already published as a gap or an
  accepted consequence. An attacker with root on the host defeating the
  server is documented behaviour, not a finding.
- Missing hardening that is documented as optional
  ([Best Practices](docs/BEST_PRACTICES.md) Chapters 4–5).

If you are unsure whether something is in scope, report it. Deciding is the
maintainer's job, not yours.

## Supported versions

This project ships both stable (`X.Y.Z`) and pre-release (`X.Y.Z-beta.N`) tags
on GHCR.

| Version | Supported |
|---|---|
| Latest stable tag | ✅ |
| Older tags (stable or pre-release) | ❌ — upgrade first |

There is no backporting to older tags. If you can reproduce an issue only on
an older tag, please confirm it against the current one before reporting.

## What to expect

This is a small project maintained by one person. Setting a response-time
guarantee it cannot keep would be its own kind of dishonesty, so instead:

- reports are read as soon as they are seen, and acknowledged when read
- confirmed issues are fixed before new features
- once fixed, an advisory is published describing the problem, the affected
  versions and what operators need to do
- reporters are credited unless they ask not to be

If a report is disputed, the reasoning will be given in writing rather than the
report simply being closed.

## Coordinated disclosure

Please give the maintainer a reasonable opportunity to publish a fix before
disclosing publicly. If a problem is being actively exploited, or if a report
goes unanswered, disclose — protecting users comes before protecting the
project's reputation.
