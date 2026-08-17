> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> How to build a throwaway environment that gets you from nothing to a
> completed [Verification](VERIFICATION.md) run — without dedicating hardware,
> and without touching anything you care about.

---

# Test Environment

Two audiences, one setup. If you are **evaluating** this project, this is how
to try it without provisioning a Fedora CoreOS host. If you are **running** it,
this is where you rehearse an upgrade or a recovery before doing it for real.

## You need fewer machines than you think

**One virtual machine.** Clients are not machines — to this server a client is
an SSH key and a repository path. Two keys on your own workstation are two
clients, which is enough for every test on the verification page, including
client isolation (test 7): the repository path is fixed *per key* in
`authorized_keys`, so pointing key A at key B's repository is refused whether
or not both keys live on the same computer.

[Verification](VERIFICATION.md) test 0 needs no VM at all — it checks the
published image's build provenance and runs wherever `gh` is installed.

---

## 1. Choose the guest OS

Use **Fedora Server**. Not Fedora Workstation, and not Debian or Ubuntu.

| | Why it matters here |
|---|---|
| `/bin/sh` is **bash** | Every host script carries `#!/bin/sh`, so the guest decides which shell interprets them. On Fedora CoreOS — the platform this project targets — `/bin/sh` is bash; on Debian and Ubuntu it is dash |
| SELinux enforcing by default | [Best Practices](BEST_PRACTICES.md) Chapter 1 requires it; Ubuntu ships AppArmor instead |
| XFS root by default | Fedora **Workstation** defaults to btrfs |

The shell point is not theoretical. A bug that made the client overview print
no clients at all existed only under bash, survived three releases, and would
have been invisible on a Debian test VM while breaking every real deployment.
A guest from the wrong family gives you a green test run and false confidence.

**Fedora CoreOS itself** is possible but not worth the effort here: it has no
interactive installer, so it needs an Ignition config delivered through a
config drive, which is fiddly under VirtualBox. No test on the verification
page examines immutability, so a Fedora Server guest exercises the same
properties with far less setup.

> On a Linux host, KVM/virt-manager is generally less friction than VirtualBox
> — particularly if you later do want to try CoreOS, since libvirt can pass an
> Ignition config directly. VirtualBox works fine for everything below.

---

## 2. Create the VM

Modest is enough: **2 vCPU, 2 GB RAM**. What matters is the rest.

**Two disks.** The system disk, plus a second one that becomes the repository
volume. **At least 20 GB**: the data written here is trivial — the append-only
probe in test 9 writes 1 MB — but the two clients below are given 5G each, and
`00-ssh-create-user.sh` refuses a quota above 99% of the volume because such a
limit cannot be enforced at all (OPERATIONS Chapter 9.2). A disk of a few GB
would make the documented steps fail for that reason rather than any other.
Keeping repositories on their own volume also matches
[Best Practices](BEST_PRACTICES.md) Chapter 1, which requires dedicated
storage.

**Two network adapters:**

- **NAT** — so the VM can reach GHCR to pull the image
- **Host-only** — so your workstation can reach the VM's SSH port

NAT alone is the classic dead end: the VM reaches the internet, and nothing
reaches the VM.

---

## 3. Prepare the repository volume

This is the part the tests actually care about, and the one most likely to be
wrong. Inside the VM, with the second disk as `/dev/sdb`:

```bash
sudo mkfs.xfs -m reflink=1 /dev/sdb
sudo mkdir -p /var/mnt/borg-repo

# Mount by UUID rather than device name — device order is not guaranteed
sudo blkid /dev/sdb
echo 'UUID=<uuid>  /var/mnt/borg-repo  xfs  defaults,prjquota  0 0' | sudo tee -a /etc/fstab

sudo systemctl daemon-reload
sudo mount -a
```

Confirm that quotas are **enforcing**, not merely accounting — this is the
single most common misconfiguration and it is invisible until a client fills
the disk:

```bash
findmnt -no OPTIONS /var/mnt/borg-repo          # must contain prjquota
sudo xfs_quota -x -c 'state -p' /var/mnt/borg-repo   # Enforcement: ON
```

`reflink=1` is not needed by anything today; it is there so the same volume can
later be used to try the snapshot mechanism from [Roadmap](../ROADMAP.md) 11.5.

---

## 4. Open the port

Fedora Server runs firewalld, and a blocked port looks exactly like a broken
server:

```bash
sudo firewall-cmd --add-port=2222/tcp --permanent
sudo firewall-cmd --reload
```

---

## 5. Check the prerequisites, then install

Work through [Server Installation](SERVERINSTALL.md) from step 0. Its
prerequisite table is the checklist; everything above exists to satisfy it.
Two things worth confirming before you start, because they fail late and
confusingly:

```bash
podman info --format '{{.Host.Security.Rootless}}'     # true
grep "^$(whoami):" /etc/subuid /etc/subgid             # both present
```

Use `/var/mnt/borg-repo` as `HOST_REPO_BASE` in step 3.

---

## 6. Create two client identities

On your **workstation**, not in the VM:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/borg_clientA -N '' -C clientA
ssh-keygen -t ed25519 -f ~/.ssh/borg_clientB -N '' -C clientB
```

The workstation also needs `borg` itself, from the **1.x** line — **BorgBackup
2.x is not supported** and would make the run meaningless
([Supported BorgBackup versions](../README.md#supported-borgbackup-versions-1x-only)).
Check with `borg --version` before starting.

```
# ~/.ssh/config
Host borgA
    HostName <vm-host-only-ip>
    Port 2222
    User borg
    IdentityFile ~/.ssh/borg_clientA
    IdentitiesOnly yes

Host borgB
    HostName <vm-host-only-ip>
    Port 2222
    User borg
    IdentityFile ~/.ssh/borg_clientB
    IdentitiesOnly yes
```

Provision both in the VM (SERVERINSTALL steps 8–9), then restart the container
so `authorized_keys` is rebuilt:

```bash
./scripts/00-ssh-create-user.sh clientA OWN 5G     # shows the quota against
./scripts/01-ssh-set-user-key.sh clientA /path/to/borg_clientA.pub
./scripts/00-ssh-create-user.sh clientB OWN 5G     # the volume, then asks
./scripts/01-ssh-set-user-key.sh clientB /path/to/borg_clientB.pub
./scripts/92-container-restart.sh
```

Watch what the two `00-…` runs print. On a 20 GB volume each 5G quota is a
quarter of it, and the `Enforced total` line reaches 50% after the second
client — the invariant from OPERATIONS Chapter 10.2, stated before the change
rather than reconstructed after it. Two things are worth trying once here,
since a check that has only ever passed has not been shown to discriminate:
ask for a third client at `15G` and watch the total cross the volume and be
marked `(!)`, and ask for `50G` and watch it be refused outright.

From the workstation, `ssh borgA info` should now answer. Follow
[Client Usage](CLIENTUSE.md) from Chapter 2 to initialize and take a first
backup.

---

## 7. Snapshot the VM before testing

Take a VirtualBox (or libvirt) snapshot now. Several verification tests leave
permanent traces **by design**:

- test 8 leaves an unusable `repokey` repository the client cannot remove
- tests 9 and 10 leave probe data that append-only makes unreclaimable
- the recovery drill below deliberately damages a repository

A VM snapshot makes all of that free to repeat. This is unrelated to the
storage snapshots discussed in [Roadmap](../ROADMAP.md) 11.5.

---

## 8. Run the verification

Work through [Verification](VERIFICATION.md) in order. Test 7 is the one that
needs both identities; everything else uses `borgA`.

**Then do the part that matters more: make the tests fail.** A test that has
only ever passed on a correct system has not been shown to discriminate — it
may be passing for the wrong reason. Break something deliberately and confirm
the test notices:

| Break this | Expect |
|---|---|
| Switch enforcement off at the volume (`sudo xfs_quota -x -c 'disable -p' <mount>`) | 5A reports `pqnoenforce` and 5B `Enforcement: OFF`; 5.5A lists `none (!)` against a `CONFIGURED` of `50G (!)`, and 5.5B fails at the client, where `info` reports the whole disk instead of the quota. Restore with `enable -p` |
| Append a line to the container's `authorized_keys` without the `command=` prefix | 3A counts it; drop only the `,restrict` from an otherwise correct line and it still does |
| Initialize a repository with `--encryption=repokey` | Test 8 is refused on the next connection |
| Mount an `sshd_config` over the image's own with a `Match User borg` block reopening `PermitTTY` | 1.5A still reports ten correct lines — 1.5B is what catches it |
| Edit `IMAGE` in `config.sh` to a different digest and *do not* restart | 0C's two lines diverge, and `99-container-status.sh` reports it as `PIN MISMATCH` — whatever versions the two digests carry. Its `MISMATCH` line stays quiet, because that one compares the host scripts against the running container and an edited pin moves neither (#31). Repair with `50-service-install.sh` *then* `92-container-restart.sh`; a restart alone starts the old image again |
| Delete one client's repository directory (`podman unshare rm -rf <HOST_REPO_BASE>/<group>/<client>`) | 5.5A fails: the client reads `n/a (!)` … `MISSING on host`, with the explanation under the listing. From that client, the next connection is refused with `DENY: repository directory missing – needs operator action` rather than being served from a directory the server made itself. `03-provision-client.sh <client>` is the way back — and it brings back an empty repository, so run it on a client whose archives you are willing to lose |
| Delete a **group** directory (`podman unshare rm -rf <HOST_REPO_BASE>/MIRROR`) | Every client under it reads `MISSING on host` and meets the same refusal. Worth doing once for what it *no longer* does: until beta.30 the wrapper recreated the path here — its parent `/repo` belongs to `borg`, so the `mkdir` succeeded — and served the client from a directory with no project id, bounded by the volume rather than by its limit. That is 5.5B's first failure shape, produced by the server itself, and it needed no mistake inside a client directory at all (#29) |
| Take the search bit off a group directory (`podman unshare chmod 750 <HOST_REPO_BASE>/OWN`) | 5.5A fails with `n/a (!)` … `unreadable` for every client under it, and the hint points at the group directories and the mount. `statfs()` needs search permission on the *parents*, not on the target, so tightening a client's own directory does **not** produce this — there `02-change-user-quota.sh` breaks instead, on `lsattr`. Note that the container's `borg` user is "other" on that directory too, so this takes the clients down with the report rather than blinding the report alone. Restore with `chmod 755` |

> **The one that looks like it works and does not:** `sudo mount -o
> remount,noquota <mount>`. XFS does not accept quota state changes on remount —
> the option is parsed, `mount` exits 0, and the volume goes on enforcing
> project quotas with `prjquota` still in `findmnt`. This table named that
> recipe until beta.28, and it is the natural first thing to reach for, so it is
> worth knowing that it is a no-op rather than a test that "everything still
> passes" (#22). `xfs_quota ... disable -p` is also the kinder recipe: it needs
> no unmount, so the bind mount into `/repo` stays in place and the container
> never has to be touched.

> **The last four rows are owed measurements, and that is why they are here.**
> The `PIN MISMATCH` line and the `(!)` markers for `MISSING on host` and
> `unreadable` are newer than the bench runs that prompted them.
> [Verification](VERIFICATION.md) records them as unverified against a
> deployment — `tests/host-scripts.sh` covers the code, which is a different
> statement from the one that page makes. Running these four rows is what closes
> that gap, and the notes under `0C` and `5.5A` say where each one stands.

Restore the snapshot afterwards. This exercise is worth more than the passing
run: it is the difference between "the tests are green" and "the tests would
have told me".

---

## 9. Rehearse a recovery

While a throwaway VM is available, walk [Recovery](RECOVERY.md) Section 1 once:
delete an archive as a client, then roll the repository back as the operator.

It is a two-party, manual procedure involving hand-moved segment files, and the
first time you read it should not be the day a client calls. You will also see
for yourself that `borg delete` reports success while freeing nothing, which is
the behaviour most likely to mislead someone under pressure.

Chapter 6.3 of [Deployment](DEPLOYMENT.md) is worth rehearsing here too — an
upgrade in a VM costs a snapshot restore if it goes wrong.

---

## What this environment does not prove

Be clear about the boundary, or the exercise becomes its own kind of false
confidence:

- **It is not Fedora CoreOS.** Immutability and atomic updates are untested
  here. No verification test examines them, but your production host still has
  to provide them ([Design](DESIGN.md) Chapter 4.2).
- **It says nothing about your production host.** A green run proves the
  *software* behaves as documented. Whether the machine you actually deploy on
  is hardened is a separate question with the same answer sheet — run the
  verification there too.
- **Scale and performance are not represented.** A 5 GB quota and a 1 MB probe
  tell you nothing about how a multi-terabyte repository behaves.
