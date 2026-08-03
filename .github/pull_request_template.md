<!--
Please read CONTRIBUTING.md first, especially the non-goals.
Security problems do not belong in a pull request either — see SECURITY.md.
-->

## What and why

<!-- What this changes, and the problem it solves. Link the issue if there is one. -->

## Tested setup

<!-- Required. "Not tested on a server" is an acceptable answer for a docs-only
     change — say so instead of leaving the fields blank. -->

- Host OS / version:
- Podman version (rootless?):
- SELinux mode (`getenforce`):
- Filesystem + `prjquota` enforcing (yes/no):
- Client Borg version:
- Image tag or commit tested:

## Checklist

- [ ] Affected documentation updated in this PR (see the table in CONTRIBUTING.md)
- [ ] No new services, daemons or open ports
- [ ] No server-side handling of client keys or passphrases
- [ ] The default-deny command gate in `borg-wrapper.sh` is unchanged, or the new allow-list entry is justified below
- [ ] Enforcing `prjquota` is still required, not optional
- [ ] Code comments are in English
- [ ] Tests under `tests/` added or extended where behaviour changed

## Security-relevant changes

<!-- Anything that touches the wrapper, key handling, permissions, the image
     build or the attack surface: describe what changes and why it is safe.
     "None" is a valid answer if it is true. -->
