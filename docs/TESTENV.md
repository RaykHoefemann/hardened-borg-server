> **Docs:** [Overview](../README.md) · [Design & Threat Model](../docs/DESIGN.md) · [Deployment](../docs/DEPLOYMENT.md) · [Operations](../docs/OPERATIONS.md) · [Snapshots](../docs/SNAPSHOTS.md) · [Recovery](../docs/RECOVERY.md) · [Verification](../docs/VERIFICATION.md) · [Best Practices](../docs/BEST_PRACTICES.md) · [Roadmap](../ROADMAP.md)
>
> How to build a throwaway environment that gets you from nothing to a
> completed [Verification](VERIFICATION.md) run — without dedicating hardware,
> and without touching anything you care about.

---

# Test Environment

Two paths, depending on what you need.

**[Path A](#path-a-quick-evaluation-fedora-server)** gets you from nothing to
a completed [Verification](VERIFICATION.md) run with the least possible
setup: any Linux, macOS or Windows host with VirtualBox, no dedicated
hardware, nothing on your own machine touched. This is enough for everyone
**evaluating** the project, and for most rehearsals.

**[Path B](#path-b-full-fidelity-lab-fedora-coreos)** builds a close-to-
production lab instead: the actual target OS (Fedora CoreOS), a real block
device for the repository volume, and one VM per client rather than one VM
playing several roles. It costs more setup, and needs a Linux host with
KVM/libvirt. Reach for it once you need something Path A structurally
cannot show you — immutability, the point-in-time snapshot mechanism from
[Roadmap](../ROADMAP.md) 11.5, or behavior across more than one BorgBackup
version — or once you are **running** this project and want to rehearse an
upgrade or a recovery on the real OS before doing it for real. It is
deliberately built to grow: adding another client is one more VM of the same
shape, and the same approach extends to a second server VM standing in for
the foreign server a client mirrors to for its own offsite copy
([Roadmap](../ROADMAP.md) 11.2).

Both are throwaway. Neither touches hardware or software you use for
anything else, and both are meant to be discarded and rebuilt freely.

---

# Path A: Quick Evaluation (Fedora Server)

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
properties with far less setup — that gap is what [Path B](#path-b-full-fidelity-lab-fedora-coreos)
below is for.

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

Use `/var/mnt/borg-repo` as `HOST_STORAGE_BASE` in step 3.

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
| Take the search bit off a group directory (`podman unshare chmod 750 <HOST_REPO_BASE>/OWN`) | **Does not produce `unreadable` — confirmed on a live deployment (#33).** `09-show-all-users.sh` runs directly on the host, not through `podman unshare`, and the group directory was left "owned by namespace root" by `00-ssh-create-user.sh`; under rootless Podman that namespace-root uid maps back to the very host user who runs the reporting script, so the script keeps owner access while `750` only removes it from "other". What actually happens: the report stays green while the container's `borg` user — a different, unprivileged mapped uid, genuinely "other" here — loses access and its clients are locked out with `DENY: repository directory missing – needs operator action`, invisibly. `chmod 000` on the same directory does not reach `unreadable` either: it also removes the owner's search bit, so `[ -d ]` itself fails, and the script cannot tell that apart from "does not exist" — it reports `MISSING on host` instead. Restore with `chmod 755` |
| Take the search bit off `HOST_REPO_BASE` itself | **Also does not produce `unreadable` — tried and ruled out.** The ownership assumption behind this row did hold: the mount point is owned by the container's mapped `borg` uid, not by the host user who runs the reporting scripts, unlike the group directories underneath it. But the outcome is the same as the row above — `chmod 000` removes the owner's search bit too, so `[ -d "$d" ]` fails before `df -kP` ever runs, and `09-show-all-users.sh` reports `MISSING on host` for every client at once instead of `unreadable`. Confirmed independently three times (two sessions against beta.31, one against beta.32). Treat `unreadable` as reachable only by a genuine `statfs()` failure (a real mount problem), not by any host-side permission change — see [Verification](VERIFICATION.md) 5.5A |

> **The one that looks like it works and does not:** `sudo mount -o
> remount,noquota <mount>`. XFS does not accept quota state changes on remount —
> the option is parsed, `mount` exits 0, and the volume goes on enforcing
> project quotas with `prjquota` still in `findmnt`. This table named that
> recipe until beta.28, and it is the natural first thing to reach for, so it is
> worth knowing that it is a no-op rather than a test that "everything still
> passes" (#22). `xfs_quota ... disable -p` is also the kinder recipe: it needs
> no unmount, so the bind mount into `/repo` stays in place and the container
> never has to be touched.

> **Rows five through eight are owed measurements, and that is why they are
> here.** The `PIN MISMATCH` line and the `(!)` markers for `MISSING on host`
> and `unreadable` are newer than the bench runs that prompted them.
> [Verification](VERIFICATION.md) records them as unverified against a
> deployment — `tests/host-scripts.sh` covers the code, which is a different
> statement from the one that page makes. Running those four rows is what
> closes that gap, and the notes under `0C` and `5.5A` say where each one
> stands. The row for `unreadable` is now measured — and the recipe it named
> turned out wrong (#33) — which is why a ninth row followed it rather than
> replacing it outright: a wrong recipe that gets silently swapped for an
> unverified new one repeats the mistake it was replacing. That ninth row has
> since been measured too, and ruled out the same way.

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

# Path B: Full-Fidelity Lab (Fedora CoreOS)

The real target OS, on a hypervisor that can hand it a real Ignition config
and a real block device — for whatever [Path A](#path-a-quick-evaluation-fedora-server)
cannot show you: immutability, the point-in-time snapshot mechanism
([Roadmap](../ROADMAP.md) 11.5), or behavior across more than one BorgBackup
version. Built on QEMU/KVM with libvirt; VirtualBox cannot pass an Ignition
config directly, which is the whole reason Path A avoids CoreOS in the first
place.

One server VM plus one VM per client — deliberately more than the "clients
are just SSH keys" minimalism of Path A. The point here is closeness to a
real deployment: separate machines, separate BorgBackup versions, a repository
volume that is an actual attached disk rather than a VM's system disk.

**If your KVM host also runs other, unrelated VMs:** every command below that
touches a domain (`virsh`, `virt-install`, `virt-xml`, especially `undefine`,
`destroy`, `vol-delete`) must name exactly one of the VMs this lab creates.
None of them should ever touch a VM this lab did not create.

**Extending it.** Another client is one more VM of the same shape as Chapter
15. A second server VM, provisioned the same way as Chapter 11, stands in for
the foreign server a client keeps its own offsite copy on
([Roadmap](../ROADMAP.md) 11.2) — nothing below is specific to there being
exactly one of each.

---

## 10. Overview

What gets built:

- **One server VM** running Fedora CoreOS, with a second disk for the
  repository volume (Chapters 11–12).
- **One VM per client**, each a different distribution and a different
  BorgBackup version, so the supported range gets exercised rather than
  assumed (Chapter 15).

All VMs need a real LAN address, not just a NAT address the host can't reach
back into — see the bridge in Chapter 11.1.

---

## 11. Set up the server VM

### 11.1 Create a bridge on the host

A libvirt NAT network (`default`) is not enough: it gives the VM outbound
internet access but no address your workstation can reach back into. A real
bridge is what's needed.

> **Why not macvtap instead?** It would also give the VM a LAN address, but
> host and VM then cannot reach each other — `ssh core@<vm-ip>` from the host
> would not work.

The host's own IP moves from the NIC onto the bridge; a brief network blip
during the switch is normal.

```bash
NIC="<your-host-nic>"                 # e.g. eth0 / enp0s31f6
OLD="<existing NetworkManager connection name>"   # e.g. "Wired connection 1"

nmcli con add type bridge ifname br0 con-name br0 stp no
nmcli con mod br0 ipv4.method auto ipv6.method auto connection.autoconnect yes
nmcli con add type ethernet ifname "$NIC" con-name br0-port master br0
nmcli con mod "$OLD" connection.autoconnect no
nmcli con down "$OLD"
nmcli con up br0-port
nmcli con up br0
```

Check:

```bash
ip -br addr show br0          # bridge has the DHCP address
ls /sys/class/net/br0/brif/   # must contain the host NIC
ip route | grep default       # default route via br0
```

> **`br0` gets a freshly generated MAC**, not the NIC's own — expect DHCP to
> hand the host a *different* address than before. If you have static DHCP
> reservations, assign the NIC's MAC to the bridge instead:
> `nmcli con mod br0 bridge.mac-address <nic-mac>`

### 11.2 Build an Ignition config

Write a [Butane](https://coreos.github.io/butane/) config for the server VM —
hostname, an SSH authorized key for the `core` user, and whatever else you
want set on first boot — then convert it:

```bash
butane --strict -o server.ign server.bu
```

(Butane itself: download a release binary from the
[Butane releases page](https://github.com/coreos/butane/releases) and put it
on your `PATH`.)

### 11.3 Prepare a self-installing live ISO

`coreos-installer iso customize` bakes the install target and the Ignition
config directly into the ISO, so it installs itself with nothing to type at
the VM console:

```bash
coreos-installer iso customize \
  --dest-device /dev/vda \
  --dest-ignition server.ign \
  --dest-console tty0 \
  --dest-console ttyS0,115200n8 \
  --live-karg-append console=tty0 \
  --live-karg-append console=ttyS0,115200n8 \
  -o /var/lib/libvirt/images/server-install.iso \
  ~/Downloads/fedora-coreos-<version>-live-iso.x86_64.iso

chmod 644 /var/lib/libvirt/images/server-install.iso
```

- `--dest-device /dev/vda` — the VM's virtio disk
- `--dest-console` / `--live-karg-append` — a serial console alongside the
  graphical one, so `virsh console` works

> **Always start from the current stable ISO — that's the entire time
> saving.** Whatever the ISO carries is what gets installed; anything older
> is fetched live by Zincati afterward, with a reboot per intermediate
> version. A nine-month-old ISO cost three reboots and roughly 15 minutes on
> a two-minute install here. A current ISO leaves Zincati nothing to do.
>
> Get the current release and checksum from the stream metadata, not from
> memory:
>
> ```bash
> curl -s https://builds.coreos.fedoraproject.org/streams/stable.json | python3 -c "
> import sys,json
> a=json.load(sys.stdin)['architectures']['x86_64']['artifacts']['metal']
> d=a['formats']['iso']['disk']
> print('release:', a['release']); print('url    :', d['location']); print('sha256 :', d['sha256'])"
> ```
>
> Verify the checksum after downloading, then re-run `iso customize` against
> the new base ISO. If a customized ISO already exists at the target path,
> `-o` fails with `File exists` — and since the file is owned by
> `libvirt-qemu` after the first `virt-install`, `-f` doesn't help either.
> Build alongside it and swap instead:
>
> ```bash
> coreos-installer iso customize … -o …/server-install-new.iso <base-iso>
> rm -f /var/lib/libvirt/images/server-install.iso
> mv …/server-install-new.iso /var/lib/libvirt/images/server-install.iso
> chmod 644 /var/lib/libvirt/images/server-install.iso
> ```
>
> The `rm` needs no `sudo` if the images directory is yours — unmounting
> cares about the directory's permissions, not the file's owner.

### 11.4 Create the VM

Example: 2 vCPU, 4 GB RAM, 50 GB disk.

```bash
virt-install \
  --connect qemu:///system \
  --name FCOS-BorgBackupServer \
  --memory 4096 \
  --vcpus 2 \
  --osinfo fedora-coreos-stable \
  --disk path=/var/lib/libvirt/images/FCOS-BorgBackupServer.qcow2,size=50,format=qcow2,bus=virtio \
  --cdrom /var/lib/libvirt/images/server-install.iso \
  --network bridge=br0,model=virtio \
  --graphics spice \
  --console pty,target_type=serial \
  --events on_reboot=destroy \
  --noautoconsole
```

> **`--events on_reboot=destroy` matters.** Fedora CoreOS reboots after
> installing. Without this, the VM would boot the ISO again and reinstall
> itself in a loop. This makes it shut down cleanly instead.

> **Pick the disk size correctly up front.** Fedora CoreOS's system partition
> is XFS, and XFS can only grow, never shrink — there is no shrinking a qcow2
> back down afterward short of reinstalling. Growing is always available,
> though: `qemu-img resize <disk>.qcow2 +XG`, then inside the VM
> `sudo growpart /dev/vda 4 && sudo xfs_growfs /var`. The qcow2 is thin
> provisioned regardless — it only uses the space actually written, the
> stated size is just the ceiling.

Watch progress (done once the domain state is `shut off`):

```bash
virsh -c qemu:///system domstate FCOS-BorgBackupServer
```

### 11.5 After installation

`virt-install` already removed the ISO medium and set boot order to disk.
Only the reboot behavior needs putting back:

```bash
virt-xml --connect qemu:///system FCOS-BorgBackupServer --edit --events on_reboot=restart
virsh -c qemu:///system start FCOS-BorgBackupServer
```

Leave autostart off — start the VM by hand when you need it.

### 11.6 Verify the result

Read the IP address without logging in (shows the login screen as an image):

```bash
virsh -c qemu:///system screenshot FCOS-BorgBackupServer /tmp/fcos.png
virsh -c qemu:///system domiflist FCOS-BorgBackupServer    # the VM's MAC
```

Then from the host:

```bash
ping -c3 <vm-ip>
ssh -i ~/.ssh/id_rsa core@<vm-ip>
```

> Installed is always exactly the ISO's own version. If it's current, Zincati
> has nothing to catch up on and the system is ready immediately. If it's
> older, Zincati updates shortly after first boot and reboots while doing
> it — normal Fedora CoreOS behavior, but it costs time; see the box in 11.3.

---

## 12. Attach the repository volume (simulated removable disk)

For payload data — the backup repository — the VM gets a second disk,
separate from the system disk. It stands in for an external USB disk and is
therefore deliberately **not** wired up through Ignition:

- Ignition only ever runs during provisioning. A disk that's allowed to be
  absent at boot doesn't belong there.
- The disk isn't even attached to the VM during installation, so the
  installer can't touch it regardless of what the Ignition config says.
- Reinstalling the system then leaves it untouched — same qcow2, same
  filesystem, same UUID.

### 12.1 Create and attach

Only **after** installation finishes — like plugging in a USB device
afterward:

```bash
qemu-img create -f qcow2 /var/lib/libvirt/images/FCOS-BorgBackupServer-repo.qcow2 100G

virsh -c qemu:///system attach-disk FCOS-BorgBackupServer \
  /var/lib/libvirt/images/FCOS-BorgBackupServer-repo.qcow2 vdb \
  --targetbus virtio --driver qemu --subdriver qcow2 --persistent

virsh -c qemu:///system domblklist FCOS-BorgBackupServer
```

`--persistent` writes the disk into the VM definition, so it survives a
restart. Without it the attachment only lasts until shutdown.

### 12.2 Format

Only the first time — an already-formatted disk is simply reused:

```bash
sudo mkfs.xfs -L borg-repo /dev/vdb
sudo blkid /dev/vdb
```

### 12.3 Mount permanently

Via `/etc/fstab`, by UUID rather than device name — `vdb` can shift, the UUID
can't:

```bash
sudo mkdir -p /var/mnt/borg-repo
UUID=$(sudo blkid -s UUID -o value /dev/vdb)
echo "UUID=$UUID /var/mnt/borg-repo xfs defaults,prjquota,noatime,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=5s 0 0" \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
sudo chown core:core /var/mnt/borg-repo
```

Mount options:

| Option | Why |
| --- | --- |
| `prjquota` | XFS project quotas, needed to enforce a per-client limit |
| `noatime` | Don't write back access times. A `borg check` reads half the repository — without this, every read generates a metadata write. Atime is worthless for backup data |
| `nodev,nosuid,noexec` | No device files, no setuid, no execution. A plain data volume needs none of it; it takes away the path to execution from an attacker who can write files into the repository |
| `nofail` | If the disk is missing at boot, the system still starts — instead of dropping into emergency mode. Exactly the behavior a removable disk needs |
| `x-systemd.device-timeout=5s` | systemd waits only 5 seconds for the device instead of the default 90 |

Deliberately **not** set:

- **`discard`** (continuous TRIM) — Fedora CoreOS already runs
  `fstrim.timer` weekly out of the box, batched, without slowing down every
  delete. Freed space still makes it back into the qcow2.
- **`noauto` + `x-systemd.automount`** — mounting only on first access buys
  nothing over `nofail` while the disk stays permanently attached.
- **`context=…`** (a fixed SELinux label) — saves the recursive relabel
  `:Z` does on container start for a large repository, but removes MCS
  isolation between containers. Only worth it once container start is
  noticeably slow.

Mount points for extra disks belong under `/var/mnt/` on Fedora CoreOS — `/var`
is the only writable part of the system.

### 12.4 Verify

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS /var/mnt/borg-repo
sudo xfs_quota -x -c 'state -p' /var/mnt/borg-repo
df -h /var/mnt/borg-repo
```

Expect `prjquota` in the mount options and:

```
Project quota state on /var/mnt/borg-repo (/dev/vdb)
  Accounting: ON
  Enforcement: ON
```

> **`Enforcement: ON` is the point that matters.** If it reads `OFF`, or the
> volume was mounted with `pqnoenforce`, quotas are only counted, not
> enforced — a client could fill the whole disk.

---

## 13. What this lab lets you verify that Path A cannot

Point `HOST_STORAGE_BASE` at `/var/mnt/borg-repo` and everything from
[Server Installation](SERVERINSTALL.md) onward is identical to Path A. What's
different here is that the volume is real, and the following can actually be
measured rather than assumed. **The paths below are only for measuring the
underlying mechanism** — the project's actual snapshot layout is
`HOST_REPO_BASE` / `SNAPSHOT_BASE` as defined in `config.sh` and
[Roadmap](../ROADMAP.md) 11.5 (nested by client, not shown here). Once
`HOST_STORAGE_BASE`/`CONTAINER` point at this volume, `./snapshots/70-create-snapshot.sh`
can be run directly against real client repositories, end to end.

**Reflink copies are effectively free — measured, not assumed.** A single
`cp -a --reflink=always` over a 250 MB repository directory: **0.072 s.**

**Append-only repositories cost nothing to snapshot, measured by deleting
them again.** The repositories never overwrite anything; appended data lands
past the previous end of file, no shared extent is touched, so no
copy-on-write is triggered:

| | apparent | real |
| --- | --- | --- |
| 3 snapshots | 300 MB | **64 KB** |
| live repository | 150 MB | 153,632 KB |

The obvious sizing formula, `(snapshot count + 1) × sum of quotas`, only
applies to repositories rewritten by `prune`/`compact`. That never happens
here, so the formula doesn't apply. The one thing that does grow with
snapshot count: Borg rewrites `index.*`/`hints.*` on every transaction, and
each snapshot pins one old generation of them — that scales with chunk count,
not repository size.

**Quotas must never apply to the snapshot root.** XFS accounts quota against
*apparent* file size, not blocks actually used. Measured: 3 snapshots
totaling 300 MB of apparent content report as `300M` in a quota report, but
cost **64 KB** for real. A quota on the snapshot root would read as full
after a handful of runs while nothing is physically consumed. Capacity is
therefore watched with `df` on the volume, never with the sum of quotas.

**Snapshots must live beside the client's repository tree, never inside it,**
for the same reason from the other direction. Measured: a 100 MB file inside
a client's project shows the project at 102,400 KB used; a reflink copy of it
made *inside the same project* brings that to **204,800 KB** — the client
reads as twice as full after one snapshot. A copy made outside the project
leaves the figure unchanged. (Reflink only works within a single filesystem
in any case, so the snapshot root has to stay on the same volume regardless.)

**`chattr +i` needs real host root — confirmed across every combination that
matters for a rootless deployment.** The kernel checks
`capable(CAP_LINUX_IMMUTABLE)` against the **initial** user namespace. A
rootless container sits in its own namespace by definition and cannot
acquire that capability — `--cap-add` is a no-op there:

| Where it runs | `chattr +i` |
| --- | --- |
| Host, as root | ✅ |
| Host, as an unprivileged user | ❌ |
| Rootless container, default caps | ❌ |
| Rootless container, `--cap-add=LINUX_IMMUTABLE` | ❌ |
| Rootful container, `--cap-add=LINUX_IMMUTABLE` | ✅ |

This is exactly why the snapshot tooling runs on the host, not inside the
server's rootless container — see `snapshots/70-create-snapshot.sh`'s own
header.

**A measurement pitfall worth knowing before trusting a number here:** XFS
speculatively pre-allocates blocks on append. `du` and quota reports read too
high while that's in flight (242.9 MB measured for a 150 MB file, mid-write)
and settle afterward; a remount discards the pre-allocation immediately.
Never judge a measurement taken mid-write.

**Consistency.** A `cp` taken while a backup is in progress is a
crash-consistent snapshot, not a clean one — Borg's transaction log usually
tolerates that (see [Snapshots](SNAPSHOTS.md), "Creating snapshots", for
exactly how far that holds up empirically). A snapshot is only clean by
construction outside the backup window, or with the container briefly
stopped.

**With more than one container sharing the volume,** `:Z` stops working —
each container claims its own MCS label and locks the others out. Use `:z`
instead, or pin the label at the mount:

```
context=system_u:object_r:container_file_t:s0
```

That also saves the recursive relabel on every container start; MCS
isolation between containers is already given up once access is shared.

---

## 14. Rehearse restoring after a compromised client

The scenario: a client is taken over and writes garbage into its repository.
If it isn't noticed immediately, the garbage ends up in the following
snapshots too. Walked through once here, with real measurements from that
run.

### What the damage does and doesn't reach

The project quota caps it. The client writes up to its limit and then gets
`No space left on device`; every other client and the volume itself stay
untouched. Append-only additionally guarantees existing archives are never
deleted or altered — the garbage only ever *adds*.

The space it occupies is only freed once **the last reference** to it is
gone: the live directory *and* every snapshot taken after the incident.
Older snapshots don't contain the garbage and can stay.

### First: cut the client off

Nothing happens server-side before the affected client is silenced and
cleaned. A restore attempted while the client is still compromised is
worthless — it writes the garbage straight back in, and the next snapshot
picks it up again.

Revoke that one client's access, specifically: remove its entry from
`config/clients.conf` (or its key from `config/keys/`) and restart the
container — `authorized_keys` is only rebuilt at start:

```bash
./scripts/92-container-restart.sh
```

Only then the steps below. Re-admit the client once it's demonstrably clean —
not before.

### Quota and disk space are two different things

The point that's easy to get backwards:

| Action | Frees | Does **not** free |
| --- | --- | --- |
| Delete the broken client repository | the client's **quota** — but only once the container is stopped, see below | disk space (snapshots still hold the blocks) |
| Delete the wrong snapshots | **disk space** | quota (snapshots live in project 0) |

Snapshots never count against a client's quota, however many there are. A
restore only needs the quota — which is free as soon as the live directory
is emptied. The snapshots themselves can safely stay in place until the very
end.

### Order: delete first, then write back

> **The obvious order fails.** Writing back from the snapshot first and
> cleaning up afterward doesn't work: the client's quota is still full of
> garbage, so the restore has nowhere to write. A reflink restore costs
> nothing physically, but the quota accounts for it at full apparent size
> regardless.
>
> ```
> cp: cannot create regular file '…/segment.0.restore': No space left on device
> ```

> **Stop the container first.** As long as a process still holds a deleted
> file open, the kernel doesn't release its blocks — the quota stays full
> even though the directory looks empty, and the restore keeps failing with
> `No space left on device`. Measured: 50 MB deleted with an open handle
> still on it → quota unchanged at `50M`; after the handle closes → `0`.
>
> In a real incident this is the normal case, not the edge case: the
> compromised client typically has an open SSH session and is still
> writing. Cleaning up without stopping the container accomplishes nothing.
>
> ```bash
> systemctl --user stop container_borg-server.service
> ```

```bash
CLIENT=client1
GROUP=OWN                                       # OWN or MIRROR — see Design 1.2.3
REPO=/var/mnt/borg-repo/repo/$GROUP/$CLIENT      # HOST_REPO_BASE/<group>/<client>
SNAP=$SNAPSHOT_BASE/$CLIENT/<last-known-good>    # SNAPSHOT_BASE from config.sh; then <client>/<timestamp>

# 1. Remove the garbage -- frees the quota, not yet the disk space.
#    find rather than "rm -rf dir/*": also catches dotfiles and doesn't hit
#    the command-line length limit.
find "$REPO" -mindepth 1 -delete

# 2. Write back from the last known-good snapshot (reflink, costs nothing)
cp -a --reflink=always "$SNAP/." "$REPO/"

# 3. Delete every snapshot from the incident onward -- only now is the
#    space actually freed
for s in <affected snapshots>; do
    chattr -R -i "$s" && rm -rf "$s"
done
```

The shipped `76-delete-snapshots.sh` and `77-restore-last-snapshot.sh` do
exactly steps 1–3 — with path-safety checks, an immutable-flag read-back, and
quota/project-id reconstruction on restore — and resolve every path from
`config.sh` rather than hard-coding one. For a compromised client the order is
`76-` first (drop any generation that may already carry tainted data), then
`77-` (restore what remains); `77-` also refuses if the client's `.source-group`
marker disagrees with the group its live directory sits under. Use them once
you have understood what the hand-run form above is doing.

Step 3 deliberately comes **last**: every snapshot stays in place until the
restore is confirmed to have worked. Get "last known-good" wrong and delete
too early, and that snapshot is gone for good. The disk space can wait.

Measured run (client with a 100 MB quota, 40 MB of real backups, 60 MB of
garbage):

| Step | Client quota | Used (`df`) |
| --- | --- | --- |
| After the incident | 100M / 100M | +102,432 KB |
| Garbage deleted | **0** / 100M | unchanged, still high |
| Restored from good snapshot | 40M / 100M | unchanged |
| Affected snapshots deleted | 40M / 100M | **−61,440 KB** |

The file written back does **not** carry the immutable flag — `cp` doesn't
copy it. Borg can go straight back to work, nothing needs resetting.

### Finding the right snapshot

So this step doesn't turn into forensics, record the fill level alongside
every snapshot — costs nothing and makes the jump immediately visible:

```bash
xfs_quota -x -c 'report -p -N -h' /var/mnt/borg-repo > "$SNAP.usage"
```

The last known-good state is then the snapshot right before the first
suspicious jump.

### Detection

Since the quota caps the damage, fill level alone isn't a good alarm signal —
a client is allowed to become full. **Growth rate** is what's telling: a
repository jumping from 40% to 100% overnight is suspicious, one growing
steadily over months isn't. Retention depth should also be at least as deep
as the realistic time-to-detection — otherwise the last known-good state has
already rotated out by the time the incident is noticed.

### After the restore

The repository now sits at an older transaction than the client's cache
expects. Borg notices on the next run and reconciles; when in doubt, discard
the client-side cache or run `borg check`.

---

## 15. Set up client VMs

At least two, deliberately with **different BorgBackup versions**. The
project requires "BorgBackup 1.2 or newer" in
[Client Usage](CLIENTUSE.md), while `borg-wrapper.sh`'s own OPERATING
REQUIREMENTS name only `1.2.x or 1.4.x` and explicitly warns against assuming
an untested version works. The actually-supported set is therefore
`{1.2.x, 1.4.x}` — cover both ends, not just one (the contradiction itself is
tracked as an issue).

Two clients are needed regardless: Verification test 7 checks whether clients
can reach each other's repositories, and that needs two distinct identities.

### 15.1 Overview

Each VM: 2 vCPU, 4 GB RAM, 50 GB `vda`, on the same bridge as the server VM,
autostart off. Pick a distro/version pair that actually brackets your
supported range — for example one older LTS-style distro shipping Borg 1.2.x,
and one shipping the same Borg version your server image itself is built on
(1.4.x), so the pair matches what the project promises rather than just what
happens to be convenient.

### 15.2 Backup keys

Per [Client Usage](CLIENTUSE.md): one **dedicated** ed25519 pair per client,
separate from whatever key administers the machine itself.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/borg_backup -N '' -C '<client-name>'
```

No passphrase, so an unattended run later doesn't block on one — a production
machine should decide that differently. The private half never leaves its
VM; the public half goes to the server for provisioning with
`01-ssh-set-user-key.sh`.

### 15.3 Things that cost setup time — worth knowing in advance

**The SSH agent breaks the connection.** If it offers more than one key, the
server disconnects before the right one is even tried:

```
Received disconnect from …: Too many authentication failures
```

The Borg server runs `MaxAuthTries 2`, so two wrong offers are enough. Scope
every connection explicitly:

```bash
ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i <key> …
```

The message is also misleading on its own — it looks like a server problem.
`-o PreferredAuthentications=publickey` gets the honest
`Permission denied (publickey)` instead.

**A minimal desktop distro may not ship an SSH server.** Not needed for
backup operation itself — the client connects outbound to the server, never
the other way — but useful for remotely administering the test VM.

**A distro that skips `sudo` when a root password is set during install**
(Debian does this) needs `su` instead to elevate. Not a defect, just that
distro's default.

**A distro installed from optical media may leave a `deb cdrom:`-style line**
in its package manager config, and then block the first `apt`/equivalent
run waiting for the medium back. Comment it out.

**Finding a VM's IP without a guest agent.** `virsh domifaddr` returns
nothing without one. The reliable way is via the VM's MAC:

```bash
for n in $(seq 2 254); do ping -c1 -W1 <subnet>.$n >/dev/null 2>&1 & done; wait
ip neigh | grep -i '<vm-mac>'
```

**Clipboard sharing** between host and a graphical guest usually needs a
guest-side agent package (e.g. `spice-vdagent`) — without it, copy/paste
between desktop and VM silently does nothing.

### 15.4 Snapshots

Unlike the server (Chapter 11, where a two-minute reinstall makes a snapshot
not worth the trouble), client VMs are worth snapshotting: an interactive
distro installer takes meaningfully longer to redo than the server does.

One `baseline` snapshot per client, taken `shut off`, right after setup is
complete — system installed, Borg present, backup key generated, temp files
cleaned up:

```bash
virsh -c qemu:///system snapshot-create-as --domain <VM> --name baseline --atomic \
  --description "…"
```

Roll back (the VM must be shut down first):

```bash
virsh -c qemu:///system snapshot-revert <VM> baseline
```

The backup key is captured in the snapshot too, so a rollback doesn't throw
it away — the public half already provisioned on the server stays valid.
That's deliberate: rolling back the *test state*, not the client's identity.

---

## What this environment does not prove

Be clear about the boundary, or the exercise becomes its own kind of false
confidence.

**Path A specifically:**

- **It is not Fedora CoreOS.** Immutability and atomic updates are untested
  on Path A — [Path B](#path-b-full-fidelity-lab-fedora-coreos) is what
  covers that gap. No verification test examines them either, but your
  production host still has to provide them ([Design](DESIGN.md) Chapter
  4.2).
- **Scale and performance are not represented.** A 5 GB quota and a 1 MB
  probe tell you nothing about how a multi-terabyte repository behaves.

**Both paths:**

- **Neither says anything about your production host.** A green run proves
  the *software* behaves as documented. Whether the actual machine you
  deploy on is hardened is a separate question with the same answer sheet —
  run the verification there too.
