> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Best Practices](../BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> Chapter numbers are kept from the original single-file README. Where they live now: **1–3** → Design · **5–6** → Deployment · **7–9** → Operations · **11** → Roadmap.

---

# Operations

Day-to-day configuration and operation: client/quota configuration, SSH keys, the read-only client info channel, and the host-management scripts.

---

# 7. Configuration

All client access is config-driven. Nothing is provisioned automatically beyond what is explicitly defined in `/config`.

## 7.1. clients.conf

- **File:** `config/clients.conf`
- **Format:** `<client>:<group>:<repo>:<quota>`
- **Groups:**
  - `OWN` – internal clients from your own network
  - `MIRROR` – external clients (e.g. friends, offsite partners)
- **Quota:** mandatory, format `<number>G` (e.g. `10G`, `50G`). There is no `unlimited` value — every client must have an explicit quota.

**Example:**

```
user1-os1-pc1:OWN:/repo/OWN/user1-os1-pc1:50G
user2-os1-pc1:OWN:/repo/OWN/user2-os1-pc1:50G
user-pc2:OWN:/repo/OWN/user-pc2:20G
friend1:MIRROR:/repo/MIRROR/friend1:200G
```

> Quota enforcement happens at the host filesystem level via enforcing XFS project quotas (see Chapter 1.1.3) — when the host is set up as required, exceeding the configured quota is a hard limit, not merely advisory. The value in `clients.conf` is read and validated by the application and used to provision the per-repository project limit; the actual hard enforcement is provided by the underlying XFS project-quota mechanism, not by the application itself. Live usage against this limit is reported to the client through the `info` command (see Chapter 8), read directly from the enforcing quota via `statvfs()`.

## 7.2. SSH Keys

- Each client has a dedicated public key stored in `config/keys/<client>.pub`
- The file name must match the client name exactly

**Example structure:**

```
config/keys/
├── user1-os1-pc1.pub
├── user2-os1-pc1.pub
├── user-pc2.pub
└── friend1.pub
```

## 7.3. server_info.conf

- **File:** `config/server_info.conf`
- **Format:** `key=value`
- **Required keys:** `name`, `location`, `contact`

**Example:**

```
name=backup01.example.com
location=Frankfurt, DE
contact=admin@example.com
```

This file describes the server itself (not any individual client) and is shown to every client via the `info` command (Chapter 8). All three keys are mandatory — the container will refuse to start `authorized_keys` generation if any are missing.

## 7.4. Visual Overview

```
clients.conf + keys/ + server_info.conf ---> hardened-borg-server ---> Repositories (/repo/...)
```

---

---

# 8. Client Info Channel

Each client can query basic server and account information over the same SSH connection used for backups — no additional service, port, or protocol is involved.

```bash
ssh -p 2222 borg@<server-host> info
```

This returns two things: a small, read-only text file (`info.txt`, stored inside the client's own repository path) describing the server and the client's account, followed by a single live line reporting current storage usage against the client's quota:

```
[server]
name: backup01.example.com
location: Frankfurt, DE
contact: admin@example.com

[client]
user: user1-os1-pc1
quota: 50G

Used: 12.4 GiB of 50.0 GiB (24%)
```

- `info.txt` is generated and updated automatically whenever `authorized_keys` is rebuilt (i.e. on every container start), based on `clients.conf` and `server_info.conf`. It is read-only from the client's perspective — clients cannot modify it.
- The `Used:` line is computed **live at query time** from the client's own repository directory via `statvfs()`. Because the repository sits under an enforcing XFS project quota (Chapter 1.1.3), `statvfs()` reports the quota's limit and current consumption directly, so no elevated privileges, quota tooling, or host-side helper are needed inside the container. The reported limit is the actual filesystem-enforced quota, not merely the configured `clients.conf` value.
  - *Diagnostic:* if this line reports the size of the whole underlying disk instead of the per-client limit, project-quota enforcement is not active on the repository mount (i.e. the mount is missing `prjquota` / is `pqnoenforce`).
- No interactive shell, TTY, or any command other than `info` and the normal Borg protocol is accepted; any other command is rejected.
- See Chapter 2.4 for the privacy rationale behind what this channel does and does not expose.

---

---

# 9. Host Management Scripts

> **These scripts run on the HOST, never on a client.** Nothing here is
> installed on, or needed by, the machines being backed up — clients only
> ever need an SSH key and a `borg` invocation (see Chapter 5). All scripts
> below are administrative tools for the person operating the backup server
> itself.

Helper scripts under `scripts/` manage the server's clients, quotas, the systemd service, and the container's lifecycle (start/stop/restart/status). All of them source `scripts/config.sh` — the single source of truth for paths, the container image, and runtime values (see Chapter 9.1 below) — so nothing here needs separate configuration.

## 9.1. config.sh

**Before running any other script in this chapter, review and adjust `scripts/config.sh`.** It is sourced by every script below and is the single place where host-specific values live — nothing else in the repo should need to be edited to get the server running.

**Must be adjusted for your installation:**

- `HOST_REPO_BASE` — the host path holding client repositories. **Must** point at an XFS filesystem with enforcing project quotas (`prjquota`) already active (see Chapter 1.1.3 / BEST_PRACTICES.md Chapter 1). This is also bind-mounted as `/repo` in the generated systemd unit (Chapter 6.2), so the container and the host scripts are always guaranteed to operate on the same directory.
- `IMAGE` — the container image reference to run, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:latest`. During the beta phase, `:latest` does not exist yet (no stable release has shipped) — set this to the exact pre-release tag you want to run instead, e.g. `ghcr.io/raykhoefemann/hardened-borg-server:0.1.0-beta.9` (see the [package's version list](https://github.com/RaykHoefemann/hardened-borg-server/pkgs/container/hardened-borg-server/versions) for current tags).

**Derived automatically — normally left alone:**

- `REPO_ROOT` — computed from the location of whichever script sourced `config.sh`; correct regardless of the directory you run scripts from.
- `HOST_CONFIG_BASE`, `HOST_LOG_BASE` — kept inside the repo checkout (`${REPO_ROOT}/config`, `${REPO_ROOT}/log`) unless you have a reason to move them elsewhere.
- `CONF`, `KEYDIR` — the exact `clients.conf` and key-storage paths used by `00`/`01`/`02`/`09`, derived from `HOST_CONFIG_BASE`.
- `CONTAINER_REPO_BASE` — the container-side path prefix (`/repo/`); only relevant if you change the container's internal mount point, which the shipped image does not expect.

**Fixed values — only change if you know why:**

- `CONTAINER`, `SERVICE` — the Podman container name and systemd unit filename.
- `SSH_PORT` — the port the container's SSH listens on (bind-mounted in the generated unit).
- `PROJID_BASE` — the floor for auto-allocated XFS project IDs (Chapter 9.2 scans existing repos and starts above this).
- `BORG_UID`, `BORG_GID` — the `borg` user's UID/GID **inside the container image**, fixed at build time in the Dockerfile. These must match the image you are actually running; only change them if you rebuilt the image with different values yourself. Used by `00-ssh-create-user.sh` to set correct host-side ownership via `podman unshare`.

## 9.2. 00-ssh-create-user.sh

Creates a new Borg client end-to-end: the host-side repository directory, an XFS project quota assigned and set to the given hard limit (requires enforcing `prjquota`, see Chapter 1.1.3), the `clients.conf` entry, and an empty public-key placeholder. Also sets correct host ownership on the new directory via `podman unshare` so the container's `borg` user can write to it.

Must be run as root (or with equivalent `CAP_SYS_ADMIN`) for the `xfs_quota` operations.

```bash
./scripts/00-ssh-create-user.sh <username> <group> <quota>
```

- `<group>`: `OWN` or `MIRROR`
- `<quota>`: mandatory, format `<number>G` (e.g. `50G`)

**Example:**

```bash
sudo ./scripts/00-ssh-create-user.sh user1-os1-pc1 OWN 50G
```

## 9.3. 01-ssh-set-user-key.sh

Sets (or overwrites, with confirmation) the public SSH key for an existing client. Accepts either a path to a key file or the key string directly.

```bash
./scripts/01-ssh-set-user-key.sh <username> <keyfile|keystring>
```

**Examples:**

```bash
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 ~/.ssh/id_ed25519.pub
./scripts/01-ssh-set-user-key.sh user1-os1-pc1 "ssh-ed25519 AAAA… user1-os1-pc1"
```

## 9.4. 02-change-user-quota.sh

Changes the quota of an existing client. Looks up its host repository directory and existing XFS project id, applies the new hard limit immediately via `xfs_quota` (takes effect right away — no container restart needed for enforcement), and updates the `quota:` field in `clients.conf`.

> The container still needs a restart to refresh the *displayed* `quota:` value in the client's `info.txt` (see Chapter 8) — the actual enforced limit and the live `Used: X of Y` figure update immediately regardless, since both are read straight from the filesystem quota.

Must be run as root (or with equivalent `CAP_SYS_ADMIN`).

```bash
sudo ./scripts/02-change-user-quota.sh <username> <new-quota>
```

**Example:**

```bash
sudo ./scripts/02-change-user-quota.sh user1-os1-pc1 100G
```

## 9.5. 09-show-all-users.sh

Prints an overview of every configured client, grouped by `OWN`/`MIRROR`, with each client's configured quota and its **live** storage usage — read the same way the client `info` channel reads it (directly from the enforcing XFS project quota via `df`, see Chapter 8), not just the static `clients.conf` value. Also reports total physical disk usage of the underlying storage volume. Read-only, does not require root.

```bash
./scripts/09-show-all-users.sh
```

## 9.6. 50-service-install.sh

Generates the systemd unit's `EnvironmentFile` from `config.sh`, renders the unit template (`systemd/container-borg-server.service`), and installs it as a symlink under `~/.config/systemd/user/` (see Chapter 6.2.2). Re-run after any change to `config.sh` (for example, bumping `IMAGE` to a new tag), then restart the service for the change to take effect.

```bash
./scripts/50-service-install.sh
systemctl --user restart container-borg-server.service
```

## 9.7. 90-container-start.sh

Starts the container via the systemd user service and confirms it reached the active state.

```bash
./scripts/90-container-start.sh
```

## 9.8. 91-container-stop.sh

Stops the container via the systemd user service and confirms it reached the inactive state.

```bash
./scripts/91-container-stop.sh
```

## 9.9. 92-container-restart.sh

Restarts the container via the systemd user service. **Run this after any change to `clients.conf`** (e.g. after `00-ssh-create-user.sh`, `01-ssh-set-user-key.sh`, or `02-change-user-quota.sh`) — `authorized_keys` is rebuilt from `clients.conf` only at container start, so client additions, key changes, or quota updates only take effect for SSH access after a restart.

```bash
./scripts/92-container-restart.sh
```

## 9.10. 99-container-status.sh

Shows a combined status view: the systemd service state, `podman ps` output, a detailed `podman inspect` (image, PID, network, mounts) if the container is currently registered with Podman, and the last 20 lines of the service's journal log.

```bash
./scripts/99-container-status.sh
```

> Because the unit uses `--rm` (see Chapter 6.2.4), a stopped container is removed rather than left in an exited state — so `podman ps -a` normally shows nothing for it between runs. This is expected; the script accounts for it and falls back to reporting that the container may be running transiently under systemd.

---
