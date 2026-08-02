> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> This guide walks through a complete server installation, start to finish, on
> a fresh host. It stitches together material that otherwise lives spread
> across DESIGN.md, DEPLOYMENT.md, OPERATIONS.md, and BEST_PRACTICES.md — for
> the *why* behind any step, follow the link given at that step rather than
> looking for it repeated here.

---

# Server Installation

This is the one path to follow when setting up hardened-borg-server on a new
machine, in order, from a bare host to a running server with its first client
provisioned. For day-to-day operation afterwards (adding more clients,
changing quotas, restarting the service), see [Operations](OPERATIONS.md)
Chapter 9. For what the *client* does after this is done, see
[CLIENTUSE.md](CLIENTUSE.md).

---

## 0. Prerequisites

This guide starts at "get the code." Everything the host needs *before* that
is assumed already in place — how you get there is your own business (there
are as many valid ways to provision a CoreOS box or format a volume as there
are operators), so it isn't prescribed here. What follows is the checklist of
what the host must already provide for the rest of this guide to produce a
correct, secure setup. If your host can't tick every box, stop here — see
[Design & Threat Model](DESIGN.md) Chapter 1.1 and
[Best Practices](BEST_PRACTICES.md) Chapter 1 for why each item is
non-negotiable rather than a nice-to-have.

| Requirement | Quick check |
|---|---|
| **Immutable/minimal OS** (Fedora CoreOS assumed) | — |
| **SELinux, enforcing** | `getenforce` → `Enforcing` |
| **Rootless Podman working**, with `subuid`/`subgid` configured for the user that will run the service | `podman info --format '{{.Host.Security.Rootless}}'` → `true`; `grep "^$(whoami):" /etc/subuid /etc/subgid` → both present |
| **A dedicated volume, formatted XFS and mounted with *enforcing* project quotas (`prjquota`)**, for repository storage | `xfs_quota -x -c 'state -p' <mount>` → `Enforcement: ON` (accounting-only `pqnoenforce` is not sufficient — see [Design & Threat Model](DESIGN.md) Chapter 1.1.3) |
| **A non-root user** to own and run the service — every remaining step runs as this user unless a step says `sudo` | — |

Note the mount path of the XFS volume — it's needed as `HOST_REPO_BASE` in
step 3.

---

## 1. Create the installation path

The server host only *runs* the pre-built container and the management
scripts — it never builds the image itself, so it has no use for the full
repository (`Dockerfile`, `entrypoint.sh`, CI workflows, docs, ...). Create a
dedicated installation directory and copy in just the three directories the
host actually needs: `config`, `scripts`, `systemd`.

```bash
INSTALL_PATH=~/containers/borg-server
RELEASE=v0.1.0-beta.14
mkdir -p "$INSTALL_PATH"

git clone --branch "$RELEASE" --depth 1 \
  https://github.com/RaykHoefemann/hardened-borg-server.git ~/tmp/hardened-borg-server
cp -r ~/tmp/hardened-borg-server/config ~/tmp/hardened-borg-server/scripts ~/tmp/hardened-borg-server/systemd "$INSTALL_PATH"/
rm -rf ~/tmp/hardened-borg-server

cd "$INSTALL_PATH"
```

**Clone a tag, not the default branch.** The host scripts are as much a part
of a release as the container image is, and they are the half that the image
does *not* carry — `09-show-all-users.sh`, the provisioning scripts and the
systemd unit all run on the host, from this checkout. Cloning `main` would
leave you with an unversioned mixture: a pinned image alongside whatever
happened to be committed that day, with no way to state which combination you
are running.

`$RELEASE` and the image tag in `scripts/config.sh` are meant to match. A CI
check enforces that the two stay in step, so following this guide gives you a
host side and a container side that were released together.

All remaining steps in this guide are run from `$INSTALL_PATH` —
`scripts/config.sh` derives every other path (`HOST_CONFIG_BASE`,
`HOST_LOG_BASE`) relative to wherever `scripts/` itself lives, so this
installation directory becomes the new root all scripts operate from.

---

## 2. Get the container image

```bash
podman pull ghcr.io/raykhoefemann/hardened-borg-server:latest
```

---

## 3. Configure `scripts/config.sh`

This file is the single source of truth for every path and runtime value used
by both the host-management scripts and the generated systemd unit — see
[Operations](OPERATIONS.md) Chapter 9.1 for the full field-by-field reference.
At minimum, set:

```bash
$EDITOR scripts/config.sh
```

- `HOST_REPO_BASE` → the XFS/`prjquota` mount noted in step 0 (e.g. `/var/mnt/borg-repo`)
- `IMAGE` → the exact tag pulled in step 2

Leave everything else at its default unless you have a specific reason to
change it (Operations Chapter 9.1 explains what each remaining value does).

---

## 4. Install and enable the systemd service

```bash
./scripts/50-service-install.sh
systemctl --user enable --now container-borg-server.service
```

This generates the `EnvironmentFile` from `config.sh`, renders the unit, and
symlinks it into `~/.config/systemd/user/`. See
[Deployment](DEPLOYMENT.md) Chapter 6.2 for what this does under the hood and
why it must be a *user* service, not a system-wide one.

---

## 5. Enable lingering

Without this, the service stops the moment you log out and does not come back
after a reboot — regardless of `Restart=on-failure` in the unit:

```bash
sudo loginctl enable-linger "$(whoami)"
```

See [Deployment](DEPLOYMENT.md) Chapter 6.2.3 for why this is necessary.

---

## 6. Verify the container is running

```bash
./scripts/99-container-status.sh
```

This shows the systemd unit state, `podman ps`/`inspect` output, and the tail
of the service's journal log — confirm the container is active before moving
on.

---

## 7. Set the server's identity

Edit `config/server_info.conf` — copied over in step 1 with placeholder
values — this is shown to every client via the `info` command (see
[Operations](OPERATIONS.md) Chapter 7.3). All three keys are mandatory:

```bash
$EDITOR config/server_info.conf
```

```
name=backup01.example.com
location=Frankfurt, DE
contact=admin@example.com
```

---

## 8. Create the first client

This is where the client's repository directory, XFS project quota,
`clients.conf` entry, and key placeholder all get created together. Run it as
the normal operator user — only the individual `xfs_quota` calls inside the
script elevate via `sudo` (you'll be prompted there):

```bash
./scripts/00-ssh-create-user.sh user1-os1-pc1 OWN 50G
```

- Group is `OWN` (your own devices) or `MIRROR` (external/offsite partners)
- Quota is mandatory — there is no unlimited option

See [Operations](OPERATIONS.md) Chapter 7.1 for the `clients.conf` format
this writes to.

Then set that client's public key (generate one on the *client* machine
first if it doesn't already have one — see [CLIENTUSE.md](CLIENTUSE.md)):

```bash
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 /path/to/client_id_ed25519.pub
```

---

## 9. Apply the new client config

`authorized_keys` and each client's `info.txt` are only rebuilt at container
start, so restart after any change to `clients.conf` or a client's key:

```bash
./scripts/92-container-restart.sh
```

---

## 10. Verify end-to-end

From the client machine (or any machine holding that client's private key):

```bash
ssh -p 2222 borg@<server-host> info
```

Expected output includes the server identity from step 7 and the client's own
quota — e.g. `Used: 0.0 GiB of 50.0 GiB (0%)`. If the reported total instead
looks like the size of the whole disk rather than the client's quota, the
repo mount checked in step 0 is not actually enforcing `prjquota` — go back
and check `xfs_quota -x -c 'state -p'` again.

At this point the server is fully installed, has one client provisioned, and
is verified reachable with correct quota enforcement.

---

## What's next

- **Add more clients:** repeat steps 8–9 for each additional client.
- **Client-side setup** (repo init, encryption key handling, running actual
  backups): [CLIENTUSE.md](CLIENTUSE.md).
- **Harden further / confirm compliance:** [Best Practices](BEST_PRACTICES.md)
  — Chapters 1–3 are mandatory, the rest is optional defense-in-depth.
- **Day-to-day administration** (quota changes, status checks, more scripts):
  [Operations](OPERATIONS.md) Chapter 9.
