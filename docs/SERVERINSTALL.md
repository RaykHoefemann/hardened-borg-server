> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
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
| **BorgBackup 1.x on every client** you will onboard — **2.x is not supported** | `borg --version` on the client → `1.x` (see [Supported BorgBackup versions](../README.md#supported-borgbackup-versions-1x-only)) |

Note the mount path of the XFS volume — it's needed as `HOST_STORAGE_BASE` in
step 3.

---

## 1. Create the installation path

The server host only *runs* the pre-built container and the management
scripts — it never builds the image itself, so it has no use for the full
repository (`Dockerfile`, `entrypoint.sh`, CI workflows, docs, ...). Create a
dedicated installation directory and copy in the directories the host
actually needs — `config`, `scripts`, `systemd`, and `snapshots` — plus the
repository root's `config.sh` and `VERSION`. (`snapshots/` is the optional
point-in-time snapshot tooling, [Snapshots](SNAPSHOTS.md); copy it now so it
is there if you want it — it does nothing until you run it.)

```bash
INSTALL_PATH=~/containers/borg-server
RELEASE=v0.2.0-beta.4
mkdir -p "$INSTALL_PATH"

git clone --branch "$RELEASE" --depth 1 \
  https://github.com/RaykHoefemann/hardened-borg-server.git ~/tmp/hardened-borg-server
cp -r ~/tmp/hardened-borg-server/config ~/tmp/hardened-borg-server/scripts \
      ~/tmp/hardened-borg-server/systemd ~/tmp/hardened-borg-server/snapshots "$INSTALL_PATH"/
cp ~/tmp/hardened-borg-server/config.sh ~/tmp/hardened-borg-server/VERSION "$INSTALL_PATH"/
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
podman pull "ghcr.io/raykhoefemann/hardened-borg-server:${RELEASE#v}"
```

Same `$RELEASE` as in step 1, with the leading `v` stripped — the git tag and
the image tag are the two halves of one release, so pulling them from a single
variable makes them match by construction rather than by remembering to.
`:latest` exists too as of this release, but this guide pins the exact tag on
purpose — and step 3 replaces even that with a verified digest, which is the
only reference that cannot silently drift out from under you.

Before trusting this image anywhere that matters, verify that it was built from
this repository — it carries a build provenance attestation for exactly that
purpose. See [Verification](VERIFICATION.md), Test 0. Do it now rather than
later: the digest that check reports is what step 3 pins, so the two steps are
one operation split across a page break.

---

## 3. Configure `config.sh`

The repository root's `config.sh` and `scripts/config.sh` (which sources it)
are together the single source of truth for every path and runtime value used
by both the host-management scripts and the generated systemd unit — see
[Operations](OPERATIONS.md) Chapter 9.1 for the full field-by-field reference,
including why the values are split across the two files. At minimum, set:

```bash
$EDITOR config.sh
```

- `HOST_STORAGE_BASE` → the XFS/`prjquota` mount noted in step 0 (e.g. `/var/mnt/borg-repo`). `HOST_REPO_BASE` is derived from it automatically as `${HOST_STORAGE_BASE}/${CONTAINER}/`, so nothing else needs editing here — the directory name is `CONTAINER`'s value (`borg-server` by default), not a second setting you supply. This keeps storage location and installation identity tied together by construction, and — since the snapshot tooling planned in [ROADMAP.md](../ROADMAP.md) 11.5 will place `.snapshots/${CONTAINER}/` under the same `HOST_STORAGE_BASE`, as a **sibling** of `HOST_REPO_BASE` rather than inside it — leaves that root free to sit right next to the repositories without ever being parsed out of `HOST_REPO_BASE` itself.

  **The resulting `HOST_REPO_BASE` directory has to exist before step 4**: it
  is bind-mounted into the container as `/repo`, and podman will not start a
  container whose bind-mount source is missing. `50-service-install.sh` refuses
  to install the unit until it does, rather than leaving you with a service
  that restart-loops. Create it yourself — `mkdir -p
  /var/mnt/borg-repo/borg-server` — but never create the *mount point* to get past
  that error: on an unmounted volume that succeeds silently and puts client
  repositories on the root filesystem, with no project quotas at all.

- `IMAGE` → replace the tag with the digest you verified in step 2

  It arrives derived from the `VERSION` file copied in step 1, so it already
  pulls the image built from this same release. Pin it anyway. Resolve the
  digest:

  ```bash
  skopeo inspect --format '{{.Digest}}' \
    docker://ghcr.io/raykhoefemann/hardened-borg-server:${RELEASE#v}
  ```

  and write that reference into `scripts/config.sh`, replacing `:tag` with `@sha256:`:

  ```bash
  IMAGE="ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest from the command above>"
  ```

  A tag is a name, and a name can be re-pointed at different content; the
  attestation you checked in step 2 names an *object*. Pinning the digest is
  what ties this installation to the image that was actually verified —
  without it, the next `podman pull` can replace that image without a line of
  configuration changing. This is verification check `0B`, and it fails on an
  unpinned tag ([Verification](VERIFICATION.md), Test 0).

  Take the digest from `skopeo`, not from `podman image inspect`: the published
  artifact is a multi-architecture index, and `podman` reports the manifest for
  the architecture it happens to run on — a different object, and not the one
  the attestation covers. `0B` explains that trap in full.

Leave everything else at its default unless you have a specific reason to
change it (Operations Chapter 9.1 explains what each remaining value does).

---

## 4. Install and enable the systemd service

```bash
./scripts/50-service-install.sh
systemctl --user enable --now container_borg-server.service
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

No clients exist yet at this point, and that is the expected state: the
container starts, generates its SSH host key, and authorizes nobody.
`log/build_authorized_keys.log` says so explicitly:

```
[WARN] No client keys configured – writing an empty authorized_keys.
```

The server is reachable and rejects every connection with
`Permission denied (publickey)` until step 8 provisions the first client. That
is deliberate: it lets you verify the container, the volume mounts and quota
enforcement before handing out any access.

It is also where you obtain the host key fingerprint. Clients are told to
compare it on first connection through a channel that is not this SSH
connection ([CLIENTUSE.md](CLIENTUSE.md) chapter 1), so this is the number you
hand out. Read it from the key the container actually holds:

```bash
podman exec borg-server \
  ssh-keygen -lf /config/ssh_host_keys/ssh_host_ed25519_key.pub
```

Then confirm over the network that the daemon really serves that key — both
readings must print the same fingerprint:

```bash
ssh-keyscan -t ed25519 -p 2222 <server-host> | ssh-keygen -lf -
```

**Name the key type.** Without `-t ed25519`, `ssh-keyscan` probes three key
types over three concurrent connections, and the image's
`PerSourceMaxStartups 2` refuses the third — the scan then returns no key at
all, which reads exactly like an unreachable server rather than like a
deliberate throttle. Two of those three probes could never succeed anyway,
since the image offers ed25519 host keys only.

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
the normal operator user, and specifically as **the same user that runs the
container** — only the individual `xfs_quota` calls inside the script elevate
via `sudo` (you'll be prompted there), while the repository directory is
created and handed to the container's `borg` user through `podman unshare`,
which resolves that user's rootless UID mapping:

```bash
./scripts/00-ssh-create-user.sh user1-os1-pc1 OWN 50G
```

- Group is `OWN` (your own devices) or `MIRROR` (external/offsite partners)
- Quota is mandatory — there is no unlimited option. The script shows it as a
  share of the volume, together with the sum across all clients as it would
  stand afterwards, and asks before creating anything; a quota above 99% of the
  volume is refused, because such a limit cannot be enforced (see
  [Operations](OPERATIONS.md) Chapter 9.2)
- The repository base belongs to the container's `borg` user from the first
  container start onwards (the entrypoint takes ownership of it), which is why
  this step goes through `podman unshare` rather than a plain `mkdir`. Nothing
  is left for you to fix up afterwards

See [Operations](OPERATIONS.md) Chapter 7.1 for the `clients.conf` format
this writes to.

Then set that client's public key (generate one on the *client* machine
first if it doesn't already have one — see [CLIENTUSE.md](CLIENTUSE.md)):

```bash
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 /path/to/client_id_ed25519.pub
```

---

## 9. Apply the new client config

`authorized_keys` and each client's info text are only rebuilt at container
start, so restart after any change to `clients.conf` or a client's key:

```bash
./scripts/92-container-restart.sh
```

---

## 10. Verify end-to-end

From the client machine (or any machine holding that client's private key):

```bash
ssh borgserver info
```

`borgserver` is the `~/.ssh/config` alias from [CLIENTUSE.md](CLIENTUSE.md)
chapter 1, and it is what tells ssh to offer the dedicated backup key —
`borg@<server-host>` would offer the machine's default identities instead and
fail with `Permission denied (publickey,…)` on a server where nothing is wrong.
Without that block, name the key here:

```bash
ssh -i ~/.ssh/borg_backup -o IdentitiesOnly=yes -p 2222 borg@<server-host> info
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
- **Upgrading later:** [Deployment](DEPLOYMENT.md) Chapter 6.3 — do *not* simply
  repeat step 1 against an existing installation, it overwrites both
  `config.sh` files and `server_info.conf`.
