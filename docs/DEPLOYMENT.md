> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–4** → Design · **5–6** → Deployment · **7–10** → Operations · **11** → Roadmap.

---

# Deployment

Architecture overview and how to run the server — from an ad-hoc test container to a persistent rootless systemd user service, and how to move an existing installation to a new release (Chapter 6.3) or back to an old one (Chapter 6.4).

---

# 5. Architecture Overview

- Base image: `debian:trixie-slim`, **pinned by digest**, with BorgBackup installed. A named release rather than the moving `stable` alias — which once carried the bundled Borg from 1.2.x to 1.4.0 unannounced — and a digest rather than the tag, because Debian rebuilds that tag for security updates, so two builds of one commit could otherwise differ. The cost is that base updates need a deliberate bump; `tests/base-image-freshness.sh` runs weekly and reports when the pin has fallen behind, so that stays deliberate rather than becoming forgotten. See the note in the `Dockerfile`.
- Containerized runtime: **Podman** — required, not just recommended; on the assumed Fedora CoreOS host (Chapter 1.1), Podman is the only runtime that supports rootless operation, and rootless execution is mandatory (see Chapter 1.1). Docker is not supported in this setup.
- Systemd-compatible deployment supported

## 5.1. Storage Model

- Separate volume for repositories
- Separate volume for logs
- Separate volume for configuration

## 5.2. Backup Flows

- Client → Server (SSH / optionally VPN) — your own devices and any external partners; a partner's own server connects here as a client too
- Server → removable media — the operator's manual offline export ([Roadmap](../ROADMAP.md) 11.2). The server never pushes to another server ([Design](../docs/DESIGN.md) Chapter 4.6); offsite redundancy is a client-side second `borg create` target (see [Client Usage](CLIENTUSE.md) Chapter 9)

---

---

# 6. Deployment Example

## 6.1. Manual / Ad-hoc Start

```bash
podman run \
  --name=hardened-borg-server \
  --rm \
  --publish=2222:22 \
  --volume=$HOME/containers/borg-server/config:/config:Z \
  --volume=$HOME/containers/borg-server/repo:/repo:Z \
  --volume=$HOME/containers/borg-server/log:/log:Z \
  ghcr.io/raykhoefemann/hardened-borg-server:latest
```

Useful for testing, but the container does not survive a reboot or a logout, and there is no automatic restart on failure.

> **Verify the image before you trust it.** Every published image carries a Sigstore build-provenance attestation tying its digest to the commit and workflow that produced it, so you can confirm it was built from this repository rather than merely named after it. For anything beyond a throwaway test, verify it and then pin the resulting digest in `scripts/config.sh` instead of a mutable tag — see [Verification](VERIFICATION.md), Test 0.

## 6.2. Persistent Deployment via systemd (Recommended)

For production use, the container runs as a **rootless systemd user service** rather than being started manually. It is deployed as a **Podman Quadlet**: a checked-in `.container` file that `podman-system-generator` turns into a real `.service` unit at `systemctl --user daemon-reload`. This needs **podman ≥ 5.0** (Quadlet drop-in directories); Fedora CoreOS has satisfied this since well before this project's supported baseline.

The checked-in `systemd/borg-server.container` carries only host-independent values — the runtime settings and the container hardening:

```ini
[Unit]
Description=Borg Backup Server (Podman Quadlet)
Wants=network-online.target
After=network-online.target

[Container]
# Image=, ContainerName=, PublishPort= and the three Volume= lines are NOT
# here — they are written by scripts/50-service-install.sh into a drop-in,
# from config.sh (see 6.2.2). This file alone is an incomplete unit, exactly
# as the old container.service was incomplete without its EnvironmentFile.
LogDriver=passthrough

# Hardening — determined empirically against the shipped image (see below).
NoNewPrivileges=true
DropCapability=all
AddCapability=chown dac_override fowner setuid setgid sys_chroot net_bind_service
ReadOnly=true
Tmpfs=/run
Tmpfs=/tmp
Tmpfs=/home/borg/.ssh:mode=0700
PidsLimit=128
Memory=512m

[Service]
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

- **`LogDriver=passthrough`** hands the container's stdout/stderr straight to the generated unit instead of having podman journal it a second time — the same reasoning the hand-written unit gave. The cost is `podman logs` for this container, which then has nothing of its own to show.
- **No `--rm`, no `--name`, no `PODMAN_SYSTEMD_UNIT`.** Quadlet creates a fresh container per start, removes it on stop, and sets `PODMAN_SYSTEMD_UNIT` itself. This is what removes the fragile `--rm` + fixed `--name` + `Restart=on-failure` "name already in use" interaction the hand-written unit had after an unclean stop.
- **No `User=`/`Group=`.** See 6.2.1 — the trap is unchanged, because Quadlet passes `User=` straight through to the generated unit.
- **The hardening block** drops the container from the eleven default rootless caps to the seven it actually uses, forbids privilege gain (`NoNewPrivileges`), makes the image filesystem read-only (only `/run`, `/tmp` and `/home/borg/.ssh` are writable `tmpfs`; `/config`, `/repo`, `/log` are bind mounts), and bounds pids and memory. Each cap is annotated in the file with what needs it — `chown`/`dac_override`/`fowner` for `entrypoint.sh` touching the borg-owned `/home/borg/.ssh`, `setuid`/`setgid`/`sys_chroot` for sshd privilege separation, `net_bind_service` for port 22. A full client cycle, the `info` channel and the keyfile check were all verified against this set; `kill`, `fsetid`, `setfcap` and `setpcap` were confirmed unnecessary. This is host-level defense in depth on top of what Chapter 1.1 already requires (rootless, SELinux, immutable OS) — it does not replace any of it.

Everything host-specific is written by `scripts/50-service-install.sh` into a drop-in it generates from `scripts/config.sh` — the single source of truth for the whole project:

```ini
# ~/.config/containers/systemd/<CONTAINER>.container.d/10-deployment.conf
# Auto-generated — rewritten on every install run.
[Container]
Image=ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest>
ContainerName=borg-server
PublishPort=2222:22
Volume=/path/to/checkout/config:/config:Z
Volume=/var/mnt/extern1/borg-server:/repo:Z
Volume=/path/to/checkout/log:/log:Z
```

Quadlet merges the drop-in before generating the unit, so the checked-in file stays genuinely static: a `git pull` that changes `borg-server.container` is live after the next `daemon-reload`, with no re-install. `BORG_UID`/`BORG_GID` are deliberately absent — the container's `borg` user is fixed in the image at build time and `entrypoint.sh` reads no runtime `PUID`/`PGID` (they are used only host-side, by `00-ssh-create-user.sh`).

### 6.2.1. Why this is a *user* service, not a system service

The Quadlet is installed under `~/.config/containers/systemd/`, not `/etc/containers/systemd/`. This distinction matters specifically because rootless operation is mandatory (see Chapter 1.1):

- Generated as a **systemd user service** (`systemctl --user ...`), the unit executes inside your own user session, with the normal rootless Podman environment (`XDG_RUNTIME_DIR`, the user's own `containers/storage.conf`, subuid/subgid mappings, etc.) already in place. This is the supported way to run this project.
- A `User=`/`Group=` directive in a **system-wide** Quadlet (`/etc/containers/systemd/`) does not reliably reproduce that environment — Podman can fail to locate the expected runtime directory or rootless storage configuration for that user, since system services don't inherit a full user login session by default. Use the user path described here.

**Do not add `User=`/`Group=` to `borg-server.container`.** Carrying them over is the natural mistake — they read as a correct restatement of who the service runs as. Quadlet copies them into the generated unit verbatim, and in a *user* unit they are fatal. `systemd.exec(5)` permits `User=` there in principle (*"the only valid setting is the same user the user's service manager is running as"*), but using it makes systemd re-initialize the supplementary group list, which requires `CAP_SETGID`. An unprivileged user manager does not have it, and the kernel refuses even when the resulting group list would be byte-for-byte identical. The generated unit then fails at the `GROUP` step:

```
borg-server.service: Failed to determine supplementary groups: Operation not permitted
borg-server.service: Failed at step GROUP spawning /usr/bin/podman: Operation not permitted
borg-server.service: Main process exited, code=exited, status=216/GROUP
```

`podman` is never executed — the failure happens while systemd prepares the process. With `Restart=on-failure` the service loops instead of starting. Nothing needs to replace these directives: the user manager already runs as the target user, and every child process inherits that identity.

### 6.2.2. Setup

Before installing, review the repository root's `config.sh` — in particular `HOST_STORAGE_BASE`, which must point at your enforcing-`prjquota` XFS volume (see Chapter 1.1.3); `HOST_REPO_BASE` is derived from it automatically. In `scripts/config.sh`, `IMAGE` needs no editing: it is derived from the `VERSION` file, so a checkout of a release tag already points at the image built from that same commit. Change it only to pin a digest instead of a mutable tag, which is worth doing once you have verified the image ([Verification](VERIFICATION.md), Test 0). If you run **more than one instance** of this project on one host, each also needs its own `CONTAINER` (repo-root `config.sh`) and its own `SSH_PORT` (`scripts/config.sh`) — see 6.2.4.

```bash
./scripts/50-service-install.sh
./scripts/90-container-start.sh
```

`50-service-install.sh` installs the Quadlet as `~/.config/containers/systemd/<CONTAINER>.container` (a symlink to the checked-in `systemd/borg-server.container`), writes `<CONTAINER>.container.d/10-deployment.conf` from `config.sh`, and runs `systemctl --user daemon-reload` so `<CONTAINER>.service` is (re)generated. There is **no `systemctl --user enable`** step — a generated unit cannot be enabled directly; the `[Install] WantedBy=default.target` in the `.container` is honoured on `daemon-reload`, and linger (6.2.3) is what carries it across reboot. Re-run `50-service-install.sh` after any change to `config.sh` (e.g. bumping `IMAGE`) **and after updating the checkout to a new release**; then restart:

```bash
./scripts/50-service-install.sh
./scripts/92-container-restart.sh
```

Day-to-day start/stop/restart/status is handled by the scripts in Chapter 9.8–9.11.

### 6.2.3. Lingering: surviving logout and reboot

By default, systemd stops all user services once the user fully logs out, and user services do not start automatically at boot without an active login session. Since this server needs to run continuously, **enable lingering** for the user running the container:

```bash
loginctl enable-linger <username>
```

This tells systemd to start that user's systemd instance (and therefore this service) at boot and keep it running independently of whether that user is logged in interactively. Without this step, the backup server will stop the next time the host reboots or the session ends, even though `Restart=on-failure` is configured.

### 6.2.4. Running more than one instance on one host

Every per-instance resource is namespaced by `CONTAINER` (repo-root `config.sh`) through the Quadlet filename: `CONTAINER=foo` installs `foo.container` → `foo.container.d/` → generates `foo.service` → `ContainerName=foo`, and `HOST_REPO_BASE` / `SNAPSHOT_BASE` / the snapshot timer all carry `foo` too. There is no `container_` prefix any more — the filename itself is the namespace.

Two things are **not** derived and must be set per instance:

- **`SSH_PORT`** (`scripts/config.sh`) — two containers cannot publish the same host port.
- **`CONTAINER`** (repo-root `config.sh`) — the namespace key itself. `50-service-install.sh` refuses to overwrite a `<CONTAINER>.container` that already points at a different checkout, so a forgotten change fails loudly rather than silently replacing the other instance.

Both instances share the same rootless Podman image store (content-addressed, so a shared image digest is fine) and, because each mounts its own `HOST_STORAGE_BASE/<CONTAINER>` subdirectory `:Z`, SELinux relabels two disjoint paths — no contention.

---

## 6.3. Upgrading to a new release

A release has two halves and an upgrade moves both. The container image carries `borg-wrapper.sh`, `entrypoint.sh` and `build_authorized_keys.sh`; everything else an operator runs — the provisioning scripts, the systemd unit, both `config.sh` files — comes from the git checkout. Since the `VERSION` file is baked into the image, **every release changes the image**, even ones whose only substantive changes are host-side.

### What you must not lose

Three files in an installation are yours, not the release's, and a careless upgrade overwrites all three:

- **The repository root's `config.sh`** — holds `HOST_STORAGE_BASE` (which `HOST_REPO_BASE` and `SNAPSHOT_BASE` are derived from) and `CONTAINER`. It is shipped code *and* per-host configuration in one file, which is why the procedure below backs it up and diffs rather than simply copying.
- **`scripts/config.sh`** — holds your `IMAGE` digest pin, sourcing the root `config.sh` first. It holds values only — the shared shell functions live in `scripts/lib.sh`, which is release code with nothing of yours in it, so the diffs in step 6 stay about your settings. Note that the pin is the one setting an upgrade must *not* carry over unchanged: a new release is a new image and therefore a new digest, so step 6 re-resolves it rather than restoring the old value.
- **`config/server_info.conf`** — you edited it in SERVERINSTALL step 7; the repository ships it with placeholder values.

> ⚠️ **Do not re-run SERVERINSTALL step 1 against an existing installation.** `cp -r` merges into existing directories and overwrites same-named files, so copying `config/` would replace your `server_info.conf` with the template, and copying `scripts/` would replace your `scripts/config.sh`; the plain `cp` of the repository root's `config.sh` overwrites it unconditionally, the same way. Your `clients.conf` and `config/keys/` survive only because the repository does not ship them.

> ⚠️ **One-time step whenever the installed unit changes shape** — most consequentially the **Quadlet migration** (new in 1.0.0): the old install put a symlinked `.service` in `~/.config/systemd/user/` plus a rendered unit and `EnvironmentFile` under `systemd/`; the new one is a Podman Quadlet in `~/.config/containers/systemd/` generating `<CONTAINER>.service`. The `51-service-uninstall.sh` in the *new* release only knows about the Quadlet, so it cannot remove the old unit — and if step 7 below installs the Quadlet while the old unit is still running, the two collide on the container name and the published port. The same applies to the earlier rename from the fixed `container-borg-server.service` to `container_<CONTAINER>.service`. **Before step 5 overwrites `scripts/`, tear the currently installed unit down with the `51-service-uninstall.sh` you still have — it targets whatever this checkout installed:**
>
> ```bash
> ./scripts/51-service-uninstall.sh
> ```
>
> This stops and disables the installed unit and removes it (plus, on the pre-Quadlet releases, the rendered unit and `EnvironmentFile`). It does not touch the container image or any data. Only needed once, on the first upgrade past each such change.

### Procedure

Run it outside a backup window: the restart interrupts any transfer in progress, and a client caught mid-run has to repeat it.

```bash
cd "$INSTALL_PATH"
NEW=v1.0.0

# 1. Record where you are, so you can tell afterwards that something changed
./scripts/99-container-status.sh | head -10

# 2. Keep what is yours
cp config.sh /tmp/config.sh.previous
cp scripts/config.sh /tmp/scripts-config.sh.previous

# 3. Fetch the new release
git clone --branch "$NEW" --depth 1 \
  https://github.com/RaykHoefemann/hardened-borg-server.git ~/tmp/upgrade
```

Verify the new image **before** pulling it — the provenance attestation is what makes the next step something other than trust ([Verification](VERIFICATION.md), Test 0). It needs no registry credential; if it reports that a token was denied access, that is a stored `ghcr.io` credential getting in the way rather than a permission you are missing, and Test 0 says what to do about it:

```bash
# 4. Verify, resolve the new digest, then pull
gh attestation verify "oci://ghcr.io/raykhoefemann/hardened-borg-server:${NEW#v}" \
  --repo RaykHoefemann/hardened-borg-server
skopeo inspect --format '{{.Digest}}' \
  "docker://ghcr.io/raykhoefemann/hardened-borg-server:${NEW#v}"
podman pull "ghcr.io/raykhoefemann/hardened-borg-server:${NEW#v}"

# 5. Replace only the release's own files — note that config/ is NOT copied
cp -r ~/tmp/upgrade/scripts ~/tmp/upgrade/systemd ~/tmp/upgrade/snapshots "$INSTALL_PATH"/
cp ~/tmp/upgrade/config.sh ~/tmp/upgrade/VERSION "$INSTALL_PATH"/
rm -rf ~/tmp/upgrade

# 6. Restore your settings into both new config.sh files
diff /tmp/config.sh.previous config.sh
$EDITOR config.sh                  # re-apply HOST_STORAGE_BASE
diff /tmp/scripts-config.sh.previous scripts/config.sh
$EDITOR scripts/config.sh          # set IMAGE to the digest from step 4

# 7. Reinstall the Quadlet from config.sh and restart
./scripts/50-service-install.sh
./scripts/92-container-restart.sh
```

The `diff`s in step 6 are the point of the backup: each shows both your own settings and any new fields the release introduced, which a blind copy of the old file back into place would silently discard.

### Confirm the upgrade actually landed

```bash
./scripts/99-container-status.sh | head -10
```

The report opens with two pairs, and an upgrade has to move both ([Operations](OPERATIONS.md) Chapter 9.11). `Host scripts` and `Running version` must both name the new release; `Configured image` and `Running image` must both carry the digest resolved in step 4:

```
Host scripts:     1.0.0
Running version:  1.0.0
Configured image: ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest from step 4>
Running image:    ghcr.io/raykhoefemann/hardened-borg-server@sha256:<digest from step 4>
```

A pinned image deliberately cannot be read as a version — that is what the pin trades away, and why the versions are compared against each other and the references against each other rather than across. If `Configured image` still shows the *old* digest, step 6 was skipped: the container then runs whatever that digest names, which is the previous release, no matter what the checkout says.

Forgetting step 7 produces both reported differences at once — a `PIN MISMATCH` because the container was started from the old digest, and a `MISMATCH` because the files on disk are new while that old image is still serving. Note that the two halves of step 7 are not interchangeable: `92-container-restart.sh` on its own restarts the generated unit against the `10-deployment.conf` drop-in as `50-service-install.sh` last wrote it, so an upgrade that skips the install step restarts straight back into the old image, with the report unchanged.

From a client, `ssh borgserver info` should now report the new version in its `[software]` section, since each client's info text is re-rendered at container start.

### What an upgrade does not touch

Repositories, client encryption keys, quotas and XFS project IDs are all untouched: nothing in the procedure writes to `HOST_REPO_BASE`, and there is no schema migration. Borg's on-disk format is not changed by a release of this project.

The one thing to read release notes for is a change of the **bundled Borg version**. The wrapper's encryption check reads the repository manifest, so it is version-sensitive by nature — see the note at the top of `borg-wrapper.sh`, which records which Borg versions a release was tested against.

## 6.4. Rolling back

Rollback is deliberately symmetric with the upgrade: it verifies and pins the target image the same way step 4 of 6.3 does, because a digest names exactly one image forever, so going back is only unambiguous if that digest was actually checked rather than assumed.

> ⚠️ **The mirror image of 6.3's one-time systemd-unit note applies here too.** Rolling back across the Quadlet migration (new in 1.0.0) — or the earlier `container-borg-server` → `container_<CONTAINER>` rename — overwrites `scripts/` with an older install mechanism, while the *currently installed* unit is the newer one and nothing removes it just because `scripts/` was replaced. Reaching the `50-service-install.sh` step below with both still runnable fails the same way: two units contending for the same container name and published port. **Before overwriting `scripts/`, uninstall the currently installed unit while today's `scripts/` can still find it:**
>
> ```bash
> ./scripts/51-service-uninstall.sh
> ```
>
> Only needed once, rolling back across such a change in either direction.

```bash
cd "$INSTALL_PATH"
OLD=v0.1.0-beta.18

git clone --branch "$OLD" --depth 1 \
  https://github.com/RaykHoefemann/hardened-borg-server.git ~/tmp/rollback

# Verify the old image before pulling it back, exactly as in an upgrade
gh attestation verify "oci://ghcr.io/raykhoefemann/hardened-borg-server:${OLD#v}" \
  --repo RaykHoefemann/hardened-borg-server
skopeo inspect --format '{{.Digest}}' \
  "docker://ghcr.io/raykhoefemann/hardened-borg-server:${OLD#v}"
podman pull "ghcr.io/raykhoefemann/hardened-borg-server:${OLD#v}"

cp -r ~/tmp/rollback/scripts ~/tmp/rollback/systemd "$INSTALL_PATH"/
cp ~/tmp/rollback/config.sh ~/tmp/rollback/VERSION "$INSTALL_PATH"/
# snapshots/ only if the target release still has it — and drop a newer one
# left over from before the rollback (its scripts source scripts/lib.sh)
rm -rf "$INSTALL_PATH/snapshots"
[ -d ~/tmp/rollback/snapshots ] && cp -r ~/tmp/rollback/snapshots "$INSTALL_PATH"/
rm -rf ~/tmp/rollback

$EDITOR config.sh                  # re-apply HOST_STORAGE_BASE
$EDITOR scripts/config.sh          # set IMAGE to the digest verified above
./scripts/50-service-install.sh
./scripts/92-container-restart.sh
```

The checked-out `scripts/config.sh` ships the tag-based default (`IMAGE="...:${RELEASE_VERSION}"`, see `scripts/config.sh`), not a pinned digest — copying it over `$INSTALL_PATH` without editing `IMAGE` leaves that mutable tag in place, so the restart pulls whatever it currently names, unverified. Pin `IMAGE` to the digest confirmed above, the same way step 6 of 6.3 pins the upgrade target; only then do the two halves move together in both directions.

Rolling back the software does not roll back data, and cannot: append-only means nothing written since the upgrade is removed by going back. That is the intended behaviour, not a limitation — for undoing damage to a repository, see [Recovery](RECOVERY.md) Section 1.

---
