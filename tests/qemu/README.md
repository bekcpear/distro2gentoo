# distro2gentoo — QEMU end-to-end (E2E) test harness

Converts a running Linux distribution into Gentoo Linux **in place**,
inside disposable QEMU virtual machines, then hard reboots into Gentoo
and asserts the resulting system is healthy.

The harness is host-OS independent:

- **Linux**: same-arch guests use hardware virtualization via **KVM**
  (`-accel kvm -cpu host`); cross-arch guests fall back to TCG.
- **macOS (Apple Silicon)**: aarch64 guests use **HVF**; x86_64 has no
  HVF support and falls back to TCG.
- Any other combination runs under QEMU **TCG** software emulation
  (roughly an order of magnitude slower).

Accelerator, QEMU binaries and firmware paths are auto-detected in
[`config.sh`](config.sh) and can be overridden; see
[§2](#2-host-requirements).

## 1. What it does

For each test case the harness:

1. Boots an official (or prepared) **golden** cloud image as a read-only
   qcow2 backing file with a throwaway overlay.
2. Injects an SSH key via a cloud-init NoCloud seed ISO.
3. Uploads the built `distro2gentoo.sh` and runs it non-interactively
   (a regex selects the desired stage3 variant).
4. Hard-resets the VM and waits for it to boot the converted Gentoo.
5. Runs `verify-guest.sh` over SSH, which performs 16–18 assertions.
6. Discards the overlay; golden images are never modified.

All guest traffic is NAT through QEMU `user-mode` networking (no bridge,
no host network changes).

## 2. Host requirements

The harness is plain bash; the host only needs QEMU, an EDK2 UEFI
firmware and a handful of standard command line tools.

### 2.1 Tools

| tool | purpose | notes |
|---|---|---|
| `bash >= 5.1` | harness shell | macOS ships 3.2; use the Homebrew bash |
| `qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-img` | VMs | QEMU 9+ recommended |
| EDK2 firmware (AAVMF / OVMF) | UEFI guest boot | shipped via distro packages / Homebrew |
| `hdiutil` **or** `genisoimage` / `mkisofs` / `xorrisofs` | cloud-init seed ISO | first one found is used |
| `ssh`, `scp`, `ssh-keygen` | guest control | OpenSSH client |
| `nc` | QEMU monitor | any netcat flavor |
| `curl` | golden-image downloads | |
| GNU coreutils (`timeout`, `wc`) | harness timers/checksums | macOS: install coreutils |
| `expect` | optional; only a few manual probes use it | |

### 2.2 Linux (KVM preferred)

Same-arch guests are accelerated with KVM automatically when
`/dev/kvm` exists and is accessible; on most distributions the invoking
user must be in the `kvm` group (log in again after adding yourself).
Cross-arch guests, and hosts without KVM access, fall back to TCG.

Distro packages (examples):

```sh
# Debian / Ubuntu
sudo apt install --no-install-recommends \
  qemu-system-arm qemu-system-x86 qemu-utils qemu-efi-aarch64 ovmf \
  genisoimage coreutils curl openssh-client netcat-openbsd bash

# Fedora
sudo dnf install \
  qemu-system-aarch64-core qemu-system-x86-core qemu-img \
  edk2-aarch64 edk2-ovmf genisoimage coreutils curl openssh-clients \
  nmap-ncat bash

# Arch Linux
sudo pacman -S qemu-system-aarch64 qemu-system-x86 edk2-aarch64 \
  edk2-ovmf libisoburn coreutils curl openssh nc bash
```

Firmware is looked up in the standard EDK2 locations (first hit wins):

| guest | searched firmware paths |
|---|---|
| aarch64 | `/usr/share/AAVMF/AAVMF_CODE.fd` + `AAVMF_VARS.fd` (Debian/Ubuntu/Arch); `/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw` + `vars-template-pflash.raw` (Fedora); `/usr/share/edk2/aarch64/QEMU_EFI.fd` + `QEMU_VARS.fd` (Arch fallback); `/usr/share/qemu/aavmf-aarch64-code.bin` + `aavmf-aarch64-suse-vars.bin` (openSUSE) |
| x86_64 | `/usr/share/OVMF/OVMF_CODE.fd` + `OVMF_VARS.fd`; `/usr/share/edk2/ovmf/OVMF_CODE.fd`; `/usr/share/OVMF/x64/OVMF_CODE.fd`; `/usr/share/qemu/ovmf-x86_64-code.bin` (openSUSE) |

If the firmware ships under a different path, override with `FW`
(readonly code fd) and `FW_VARS_TEMPLATE` (writable vars image). Binary
locations can be overridden with `QEMU_BIN` / `QEMU_IMG`; force the
accelerator with `D2G_ACCEL` (e.g. `D2G_ACCEL=tcg,thread=multi`).

### 2.3 macOS

```sh
brew install qemu bash coreutils
```

- aarch64 guests run under HVF (`-accel hvf -cpu host`), near native
  speed; x86_64 guests use TCG and are slow;
- firmware and QEMU binaries come from Homebrew
  (`/opt/homebrew/...`);
- the harness calls GNU `timeout`, which Homebrew installs as
  `gtimeout`; add the GNU names to your PATH once:

  ```sh
  echo 'export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"' >> ~/.zshrc
  ```

### 2.4 Acceleration matrix

| host | aarch64 guest | x86_64 guest |
|---|---|---|
| Linux aarch64 with `/dev/kvm` | KVM (fast) | TCG (slow) |
| Linux x86_64 with `/dev/kvm` | TCG (slow) | KVM (fast) |
| macOS Apple Silicon | HVF (fast) | TCG (slow) |
| cross-arch / no KVM access | TCG | TCG |

## 3. Layout

```
tests/qemu/
├── config.sh                 # arch-aware config: paths, VM shape, ports, mirror
├── run.sh                    # case selector / scheduler / lifecycle
├── verify-guest.sh           # in-guest assertions (uploaded, run post-reboot)
├── lib/
│   ├── common.sh             # say/die logging
│   ├── cloudinit.sh          # hdiutil/genisoimage/xorrisofs -> CIDATA seed.iso
│   └── vm.sh                 # vm_start/vm_stop/vm_ssh/vm_wait_ssh/vm_monitor
├── cases/
│   ├── aarch64/NN-*.conf     # 14 aarch64 case definitions
│   └── x86_64/NN-*.conf      # 14 x86_64 case definitions
├── golden/
│   ├── fetch.sh              # official cloud images (arch-aware)
│   ├── make-archarm.sh       # aarch64: Arch ARM ext4 golden from ALARM tarball
│   ├── make-archarm-btrfs.sh # aarch64: Arch ARM btrfs (@/@home) golden
│   ├── make-debian-btrfs.sh  # both arches: Debian btrfs golden via rsync pivot
│   ├── make-arch-btrfs.sh    # x86_64: Arch btrfs golden via rsync pivot
│   ├── make-opensuse.sh      # both arches: openSUSE TW btrfs (snapper subvols)
│   ├── *-guest.sh            # scripts executed inside the helper VM
│   └── fetch-opensuse.sh     # download Tumbleweed JeOS/Minimal-VM image
├── assets/
│   ├── id_ed25519(.pub)      # generated test SSH key
│   ├── downloads/<arch>/     # upstream images / tarballs
│   └── golden/<arch>/        # promoted golden qcow2 files
├── results/<arch>/<run-id>/  # per-case logs, serial console, verify output
└── archive/openrc-host-results/  # archived original OpenRC-host cases
```

## 4. Usage

### 4.1 Prepare and check the host

```sh
# build the distributable single-file script first (repo root)
make

# show what the harness resolved for the current host/arch:
# QEMU binary, firmware, accelerator/cpu and timeouts
D2G_ARCH=aarch64 bash -c '. tests/qemu/config.sh; \
  echo "qemu:  $QEMU_BIN ($D2G_ACCEL, -cpu $D2G_CPU)"; \
  echo "fw:    $FW"; echo "vars:  $FW_VARS_TEMPLATE"'
```

`FW` must point at an existing file; on Linux an empty value means the
EDK2 package is missing (see §2.2).

### 4.2 Prepare golden images

```sh
# stock cloud goldens (both arches): Debian, Ubuntu, Fedora (+Arch on x86_64)
D2G_ARCH=<arch> bash tests/qemu/golden/fetch.sh

# hand-built goldens, in dependency order (skip ones that do not exist
# for the target arch — see the tables in §5). Every builder is
# idempotent — it exits immediately when its golden already exists — and
# boots its throwaway helper VM with the same accelerator selection as
# the test VMs (KVM/HVF/TCG).

# aarch64: 7 goldens = 3 stock + 4 hand-built
D2G_ARCH=aarch64 bash tests/qemu/golden/make-archarm.sh         # Arch ARM, ext4
D2G_ARCH=aarch64 bash tests/qemu/golden/make-archarm-btrfs.sh   # Arch ARM, btrfs
D2G_ARCH=aarch64 bash tests/qemu/golden/make-debian-btrfs.sh    # Debian 12, btrfs
D2G_ARCH=aarch64 bash tests/qemu/golden/fetch-opensuse.sh       # download TW JeOS
D2G_ARCH=aarch64 bash tests/qemu/golden/make-opensuse.sh        # openSUSE TW, btrfs

# x86_64: 7 goldens = 4 stock + 3 hand-built
D2G_ARCH=x86_64 bash tests/qemu/golden/make-debian-btrfs.sh     # Debian 12, btrfs
D2G_ARCH=x86_64 bash tests/qemu/golden/make-arch-btrfs.sh       # Arch, btrfs
D2G_ARCH=x86_64 bash tests/qemu/golden/fetch-opensuse.sh        # download TW Minimal-VM
D2G_ARCH=x86_64 bash tests/qemu/golden/make-opensuse.sh         # openSUSE TW, btrfs
```

Where stock images exist (Debian/Ubuntu/Fedora on both arches, Arch on
x86_64) they are used directly; the aarch64 Arch goldens have no
official upstream cloud image and are bootstrapped from ALARM tarballs,
while the x86_64 Arch btrfs golden pivots the stock Arch cloud image
(`make-arch-btrfs.sh`).

### 4.3 Run the matrix

```sh
# whole matrix of the selected arch
D2G_ARCH=aarch64 bash tests/qemu/run.sh

# specific cases (exact conf-file names, without the .conf suffix)
D2G_ARCH=aarch64 bash tests/qemu/run.sh \
  01-debian-ext4-systemd-to-gentoo-openrc \
  05-fedora-btrfs-systemd-to-gentoo-openrc

# run up to N cases in parallel (default 3)
D2G_ARCH=aarch64 bash tests/qemu/run.sh -j 3

# x86_64 on a native Linux/KVM host: fetch.sh plus the three hand-built
# goldens from §4.2, then run the same matrix
D2G_ARCH=x86_64 bash tests/qemu/golden/fetch.sh
D2G_ARCH=x86_64 bash tests/qemu/run.sh   # after building the §4.2 goldens
```

`run.sh -h` lists the cases available for the selected arch. The
conversion runs non-interactively; to drive the product script manually
inside a guest use `--yyy` to skip its prompts (non-TTY sessions do so
automatically).

### 4.4 Configuration overrides

All optional, see `config.sh` for the full list:

| variable | default | meaning |
|---|---|---|
| `D2G_ARCH` | host arch | `aarch64` or `x86_64` |
| `QEMU_BIN` / `QEMU_IMG` | Homebrew paths on macOS, `PATH` lookup on Linux | QEMU binaries |
| `FW` / `FW_VARS_TEMPLATE` | auto-detected EDK2 paths | UEFI code / vars images |
| `D2G_ACCEL` / `D2G_CPU` / `D2G_MACHINE` | `kvm`/`hvf` or `tcg,thread=multi` per host | force QEMU accelerator/CPU/machine |
| `VM_SMP` / `VM_MEM_MB` / `VM_DISK_SIZE` | accel dependent | guest shape |
| `BOOT_TIMEOUT` / `REBOOT_TIMEOUT` | 300/480 KVM/HVF; 600/900 TCG | SSH readiness windows |
| `RUN_TIMEOUT` | 7200 | cap for the in-guest conversion |
| `D2G_TEST_MIRROR` | BFSU Gentoo mirror | distfiles/binhost/portage mirror |
| `D2G_SSH_TIMEOUT` | 30 | hard cap for one short ssh probe |

Results are written to `results/<arch>/<YYYYMMDD-HHMMSS>/<case>/`:

- `conversion.log` — full stdout/stderr of the conversion
- `serial.log` — virtual serial console across both boots
- `verify.log` — per-assertion output
- `d2g-runner.sh` — exact environment/options used
- `result` — `prepare|convert|reboot|verify PASS|FAIL`
- `summary.csv` in the run directory

## 5. Golden images

The product must run on distributions booted with their **native
init**, so every host image is a systemd cloud image; the converted
Gentoo target may be OpenRC or systemd.

### aarch64 golden set

| golden file | source | fs | how produced |
|---|---|---|---|
| `debian-bookworm-ext4-arm64.qcow2` | Debian 12 genericcloud | ext4 | `golden/fetch.sh` |
| `ubuntu-noble-ext4-arm64.qcow2` | Ubuntu 24.04 cloudimg | ext4 | `golden/fetch.sh` |
| `fedora44-btrfs-arm64.qcow2` | Fedora 44 Cloud Base | btrfs | `golden/fetch.sh` |
| `arch-ext4-arm64.qcow2` | ALARM tarball | ext4 | `make-archarm.sh` (Debian helper + pacstrap) |
| `arch-btrfs-arm64.qcow2` | ALARM tarball | btrfs `@`,`@home` | `make-archarm-btrfs.sh` |
| `debian-bookworm-btrfs-arm64.qcow2` | Debian 12 pivot | btrfs `@`,`@home` | `make-debian-btrfs.sh` (rsync pivot) |
| `opensuse-leap-btrfs-arm64.qcow2` | openSUSE **Tumbleweed** JeOS | btrfs + snapper | `make-opensuse.sh` |

Notes on choices:

- There is **no official aarch64 Arch Linux cloud image**. Arch ARM
  goldens are built from the official ALARM tarball inside a throwaway
  Debian helper VM (partition + mkfs + pacstrap + grub + injected key).
- openSUSE **Leap 15.6 aarch64 JeOS is ext4**, not btrfs. The btrfs case
  therefore uses **Tumbleweed aarch64 JeOS**, whose default is btrfs with
  snapper subvolumes. Its cloud image has no cloud-init and boots with
  SELinux enforcing; the preparation step injects the key into the
  `@/root` subvolume, disables SELinux policy load, and pins the boot
  entry.
- Debian cloud images are ext4 by default; the btrfs golden is made by
  rsync-pivoting the live Debian root onto freshly created
  `@`/`@home` btrfs subvolumes and reinstalling grub.

### x86_64 golden set

| golden file | source | fs | how produced |
|---|---|---|---|
| `debian-bookworm-ext4-amd64.qcow2` | Debian 12 genericcloud | ext4 | `golden/fetch.sh` |
| `ubuntu-noble-ext4-amd64.qcow2` | Ubuntu 24.04 cloudimg | ext4 | `golden/fetch.sh` |
| `fedora44-btrfs-amd64.qcow2` | Fedora 44 Cloud Base | btrfs | `golden/fetch.sh` |
| `arch-ext4-amd64.qcow2` | Arch Linux x86_64 cloudimg | ext4 | `golden/fetch.sh` |
| `debian-bookworm-btrfs-amd64.qcow2` | Debian 12 pivot | btrfs `@`,`@home` | `make-debian-btrfs.sh` (rsync pivot) |
| `opensuse-tumbleweed-btrfs-amd64.qcow2` | openSUSE **Tumbleweed Minimal-VM** (JeOS successor on x86_64) | btrfs + snapper | `fetch-opensuse.sh` + `make-opensuse.sh` |
| `arch-btrfs-amd64.qcow2` | Arch cloud image pivot | btrfs `@`,`@home` | `make-arch-btrfs.sh` (rsync pivot) |

Notes:

- Unlike aarch64 (no official Arch cloud image → ALARM tarball
  bootstrap), x86_64 has an official Arch cloud image; the ext4 golden
  is that stock image and the btrfs golden pivots it onto fresh
  subvolumes, reinstalling GRUB in the chroot (the stock image itself
  uses systemd-boot with the ESP mounted at `/boot`).
- openSUSE no longer publishes an x86_64 JeOS qcow2; the JeOS line was
  renamed to **Minimal-VM**. The `kvm-and-xen` variant (GRUB2, btrfs
  with snapper) is used. The offline key-injection script locates the
  btrfs partition by filesystem type, so partition-index differences
  between ARM JeOS and x86_64 Minimal-VM are handled automatically.

## 6. Test cases

A case is a small key=value file named to make the conversion explicit:

```
NN-<host>-<hostfs>-systemd-to-gentoo-<targetinit>.conf
```

Every host golden boots **systemd**; the last component is the Gentoo
**target** init installed by the conversion. File contents:

```sh
NAME=debian-ext4-systemd-to-gentoo-openrc   # VM/domain and result dir
GOLDEN=$GOLDEN_DEBIAN                        # image under golden/<arch>/
STAGE3_REGEX='^stage3-aarch64-openrc-'       # stage3 variant to install
```

The expected root filesystem (`ext4`/`btrfs`) and the expected PID1
(`openrc`/`systemd`) used to be `FS=`/`INIT=` keys; they are now derived
from the case file name by `run.sh`, so a case cannot be internally
inconsistent. A case therefore contains only `NAME`, `GOLDEN`, and
`STAGE3_REGEX`.

The product script also asks for confirmation before the first-tip
countdown and again before the “Following actions will affect the real
system” countdown: answer `y`/`Y` to proceed; anything else (including
just pressing Enter) aborts. Pass `--yyy` to skip all prompts for
unattended runs; non-TTY/`D2G_NONINTERACTIVE=1` sessions proceed
automatically (this is what the harness uses).

### aarch64 matrix (all 14 PASS)

| case | host | host fs | target init |
|---|---|---|---|
| 01-debian-ext4-systemd-to-gentoo-openrc | Debian 12 | ext4 | openrc |
| 02-debian-ext4-systemd-to-gentoo-systemd | Debian 12 | ext4 | systemd |
| 03-ubuntu-ext4-systemd-to-gentoo-openrc | Ubuntu 24.04 | ext4 | openrc |
| 04-ubuntu-ext4-systemd-to-gentoo-systemd | Ubuntu 24.04 | ext4 | systemd |
| 05-fedora-btrfs-systemd-to-gentoo-openrc | Fedora 44 | btrfs | openrc |
| 06-fedora-btrfs-systemd-to-gentoo-systemd | Fedora 44 | btrfs | systemd |
| 07-arch-ext4-systemd-to-gentoo-openrc | Arch ARM | ext4 | openrc |
| 08-arch-ext4-systemd-to-gentoo-systemd | Arch ARM | ext4 | systemd |
| 09-debian-btrfs-systemd-to-gentoo-openrc | Debian 12 | btrfs | openrc |
| 10-debian-btrfs-systemd-to-gentoo-systemd | Debian 12 | btrfs | systemd |
| 11-opensuse-btrfs-systemd-to-gentoo-openrc | openSUSE TW | btrfs | openrc |
| 12-opensuse-btrfs-systemd-to-gentoo-systemd | openSUSE TW | btrfs | systemd |
| 13-arch-btrfs-systemd-to-gentoo-openrc | Arch ARM | btrfs | openrc |
| 14-arch-btrfs-systemd-to-gentoo-systemd | Arch ARM | btrfs | systemd |

### x86_64 matrix (14 cases, prepared — pending a Linux/KVM run, see §8/§9)

| case | host | host fs | target init |
|---|---|---|---|
| 01-debian-ext4-systemd-to-gentoo-openrc | Debian 12 | ext4 | openrc |
| 02-debian-ext4-systemd-to-gentoo-systemd | Debian 12 | ext4 | systemd |
| 03-ubuntu-ext4-systemd-to-gentoo-openrc | Ubuntu 24.04 | ext4 | openrc |
| 04-ubuntu-ext4-systemd-to-gentoo-systemd | Ubuntu 24.04 | ext4 | systemd |
| 05-fedora-btrfs-systemd-to-gentoo-openrc | Fedora 44 | btrfs | openrc |
| 06-fedora-btrfs-systemd-to-gentoo-systemd | Fedora 44 | btrfs | systemd |
| 07-arch-ext4-systemd-to-gentoo-openrc | Arch Linux | ext4 | openrc |
| 08-arch-ext4-systemd-to-gentoo-systemd | Arch Linux | ext4 | systemd |
| 09-debian-btrfs-systemd-to-gentoo-openrc | Debian 12 | btrfs | openrc |
| 10-debian-btrfs-systemd-to-gentoo-systemd | Debian 12 | btrfs | systemd |
| 11-opensuse-btrfs-systemd-to-gentoo-openrc | openSUSE TW | btrfs | openrc |
| 12-opensuse-btrfs-systemd-to-gentoo-systemd | openSUSE TW | btrfs | systemd |
| 13-arch-btrfs-systemd-to-gentoo-openrc | Arch Linux | btrfs | openrc |
| 14-arch-btrfs-systemd-to-gentoo-systemd | Arch Linux | btrfs | systemd |

`verify-guest.sh` checks (subset; count varies by init/fs):

- OS is Gentoo, portage tree present, kernel is `*-gentoo-dist-bin*`
- PID1 is the expected init; sshd active/listening on 22
- default route present and the Gentoo mirror reachable
- grub.cfg exists, references the Gentoo kernel, and `saved_entry` is set
- `/root` and `/home` markers preserved, old `/etc` wiped, NEWROOT removed
- root fs type (and `subvol=` in fstab for btrfs)

## 7. Product changes discovered by the tests

The harness was built test-first; every item below is a real defect or
compatibility gap proven by a failing conversion, then fixed and
re-verified.

### 7.1 Mount/boot visibility

- **Chroot cannot see the host’s mounted `/boot`/ESP.** `/proc/mounts`
  inside a chroot only exposes mounts under the chroot root, so the
  mount-boot eclass aborted grub/kernel emerge with `/boot/efi not
  mounted`. `prepareBootMounts()` (`src/08-chroot.sh`) now bind-mounts
  the host’s `/boot` (rbind, to propagate a nested ESP — needed by
  Fedora’s btrfs `/boot` subvolume with `/boot/efi` nested under it)
  and any real, fstab-declared ESP (`/efi`, `/boot/efi`, `/boot/firmware`
  — the last for Ubuntu).
- A standalone re-mount of `/boot` in front of the rbind produced a
  second, incomplete mount tree. The publish step now uses
  `cp -ax` (does not cross filesystems) plus a pre-emptive rbind, and is
  idempotent when an ESP is only a plain directory (Fedora case).

### 7.2 GRUB default entry

- The packaged kernel is `gentoo-kernel-bin`, whose menu entry id is
  `gnulinux-...-gentoo-dist-bin-advanced-<uuid>`. The old regex matched
  only `gentoo-dist-adv`, silently dropping the default for every modern
  stage3. Fixed to `gentoo-dist(-bin)?-advanced-` (`src/11-bootloader.sh`).

### 7.3 Network interface name: netplan pinning vs udev PCI-path name

Symptom: after converting the hand-built Debian btrfs golden, Gentoo
came up on `enp0s3` while the generated netifrc configured `enp0s4`, so
the NIC had no address/route after reboot. Investigation (`lspci`,
`udevadm info`, `udevadm test-builtin net_setup_link`):

- **The device never moved.** The card is always at PCI `0000:00:03.0`
  (fixed QEMU `addr=0x3`), and the systemd/udev hardware-derived name is
  identical under every kernel:
  `ID_NET_NAME_PATH=enp0s3`.
- The mismatch is **not** a kernel naming difference. Debian/Ubuntu cloud
  images run **cloud-init + netplan**. On first boot cloud-init writes
  `/etc/netplan/50-cloud-init.yaml` with an explicit `set-name:` (here
  `enp0s4`, the name probed while the image was being built) plus a MAC
  match; netplan renders `/run/systemd/network/10-netplan-*.link` with
  `Name=enp0s4`. That `.link` wins over the default naming policy
  (`udevadm`: “Policies didn't yield a name, using specified Name”).
- The converted Gentoo has no netplan/cloud-init, so systemd-networkd /
  netifrc fall back to the default policy and use the hardware-path name
  `enp0s3`. openSUSE does not use netplan, which is why it always stayed
  consistent.

`src/10-network.sh` therefore picks the target name in this priority:

1. **udev `ID_NET_NAME_PATH`** — the hardware PCI-path name, kernel
   independent and identical to what Gentoo's default policy produces;
2. keep the host name when it already equals the path name (or via the
   legacy `eth*` altname handling);
3. **last resort only:** bind by MAC, rename to `eth<index>` via netifrc
   `mac_ethN=…`, and add `net.ifnames=0`.

A `MACAddress=` match is additionally added to every generated systemd
unit as drift insurance, without forcing a rename. The IPv4/IPv6 address
configuration is always preserved.

Related harness-side fix: every QEMU PCI device gets a fixed `addr`
(disk `0x2`, NIC `0x3`, seed ISO `0x4`) so attaching/removing the seed
cannot shift the NIC slot.

- New iproute2 versions print IPv6 default routes as
  `default nhid <n> via fe80::2 dev …` plus an indented continuation
  line. The parser now strips the `nhid` token and skips continuation
  lines (`_normalize_routes`), which previously generated an illegal
  `config_fe80::2=…` that broke parsing of the whole netifrc file.

### 7.4 Stage3 list parsing

- The downloaded/decrypted stage3 list’s last line has **no trailing
  newline**. A plain `while read` returns non-zero for that line and the
  loop body never runs, silently dropping the last entry — which is
  `stage3-<arch>-systemd-…`, so every systemd selection failed.
  Fixed with the standard `while read … || [[ -n $field ]]` form
  (`src/06-stage3.sh`).

### 7.5 Packaging layer

- The legacy package map keyed off command names (`gawk`, coreutils,
  iproute2, findmnt, xz, efibootmgr, …) and emitted bogus install keys
  on Arch (`gawk → gawk`, a non-existent Arch package) and missed real
  ones. `src/04-prerequisites.sh` now drives one data table keyed by
  command with per-package-manager package names, a for-loop dispatcher,
  default `root` devices, and an early boot (vs EFI) path.
- The x86_64 grub platforms and aarch64 EFI vars are handled explicitly.

### 7.6 Test harness robustness

- A single writable per-VM EFI variable store (`edk2-aarch64-code.fd`
  copy) is required; a read-only pflash makes grub-install fail with
  “EFI variables are unsupported”. Chroot grub-install additionally
  needs an explicit `efivarfs` bind mount.
- Every QEMU PCI device is given a fixed `addr` (`disk=0x2`,
  `nic=0x3`, `seed=0x4`) so attaching/detaching the seed ISO cannot
  shift the NIC’s PCI slot.
- `vm_ssh` has a hard `timeout` cap and aggressive ServerAlive settings;
  an established TCP connection to a half-ready sshd used to hang for the
  full 60-minute ServerAlive window. The long conversion channel opts out
  of the cap.
- Helper QEMU processes are started in the background (`nohup … &`);
  a foreground launch silently blocked the golden build scripts.
- Golden builds wait for the dpkg/apt lock (cloud-init’s first-boot
  unattended-upgrade races the build script).

## 8. Open items / negotiation points

- **amd64 (x86_64) matrix is prepared (14 cases, seven goldens) but not
  yet run green.** The case set mirrors aarch64 one-for-one; the four
  stock cloud goldens download via `golden/fetch.sh`, and the three
  hand-built goldens are produced by `make-debian-btrfs.sh`,
  `make-arch-btrfs.sh` and `fetch-opensuse.sh` + `make-opensuse.sh`
  (all now arch-aware). The intended execution platform is a **native
  x86_64 Linux host with KVM**; the same `run.sh` works there without
  modification. On Apple Silicon x86_64 has no HVF acceleration; under
  TCG the images boot (TCP forwards to sshd) but the SSH **banner
  exchange does not complete** within the probe window — software
  emulation is too slow to finish crypto/auth while cloud-init/sshd is
  still loading. Options to resolve:
  1. run the amd64 matrix on a native x86_64 Linux/KVM host (preferred),
  2. substantially raise the boot/SSH timeouts (`BOOT_TIMEOUT`,
     `REBOOT_TIMEOUT`) and use a persistent qcow2 so cloud-init only
     runs once,
  3. drop cloud-init for amd64 and prepare images like the aarch64
     hand-built goldens (key injected offline).
  See §9.
- The openSUSE golden disables SELinux (`selinux=0`) because files
  injected offline lack the expected labels and enforcing mode rejects
  the authorized_keys. Acceptable for a throwaway test image; revisit if
  the matrix should validate SELinux-preserving conversions.
- `os-prober-9999` (live git ebuild pulled when a binhost package is
  missing) occasionally fails on transient git/SSL errors; a retry
  normally succeeds. Pinning os-prober or pre-seeding the distfiles would
  remove the flake.
- Some host kernels emit benign warnings (unused kernel-module symlinks
  on Fedora, mkinitcpio microcode hook on aarch64). They do not affect
  the result.

## 9. Pending amd64 work checklist

- [ ] On an x86_64 Linux host with KVM: install the packages from §2.2
      and confirm `D2G_ACCEL=kvm` with the §4.1 one-liner.
- [ ] `D2G_ARCH=x86_64 bash tests/qemu/golden/fetch.sh` (four stock
      goldens; already promoted names are reused).
- [ ] Build the three hand-built goldens per §4.2:
      `make-debian-btrfs.sh`, `fetch-opensuse.sh` + `make-opensuse.sh`
      (Tumbleweed Minimal-VM), and `make-arch-btrfs.sh`.
- [ ] Run `D2G_ARCH=x86_64 bash tests/qemu/run.sh` — all 14 cases
      (seven host goldens × OpenRC/systemd).
- [ ] Resolve TCG SSH readiness (see §8) if no KVM host is available.
- [ ] Promote passing x86_64 results into this matrix table.
