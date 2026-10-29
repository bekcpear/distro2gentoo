# distro2gentoo — testing overview

End-to-end (E2E) conversion testing lives in [`qemu/`](qemu/README.md).
The harness is host-OS neutral and runs on **Linux (KVM)** and
**macOS (HVF)** alike, with QEMU TCG software emulation as the
cross-arch fallback. Host requirements and package installation are in
`qemu/README.md`.

## Current status

### aarch64 — 14/14 PASS ✅

Fully automated QEMU matrix of seven host golden images × two target
inits across ext4 and btrfs:

Debian 12, Ubuntu 24.04, Fedora 44, Arch Linux ARM (ext4), Arch Linux
ARM (btrfs), Debian 12 (btrfs), openSUSE Tumbleweed (btrfs/snapper)
→ Gentoo OpenRC and Gentoo systemd.

The recorded passing runs were executed on **macOS / Apple Silicon
under HVF** (local; every one of the 14 cases has a `verify PASS`
record). The cases run unchanged on an aarch64 Linux host with
`/dev/kvm`; accelerator and firmware paths are auto-detected.

See `qemu/README.md` for the full matrix table and
`qemu/results/<arch>/` for raw logs, serial consoles and assertion
output.

### x86_64 (amd64) — 14 cases prepared, runs pending ⏳

The matrix mirrors aarch64 one-for-one (seven host goldens × OpenRC and
systemd across ext4/btrfs): four stock cloud goldens (Debian, Ubuntu,
Fedora, Arch) are downloaded by `golden/fetch.sh`; the Debian btrfs,
openSUSE Tumbleweed btrfs and Arch btrfs goldens are produced by the
arch-aware hand builders (`make-debian-btrfs.sh`,
`fetch-opensuse.sh` + `make-opensuse.sh` using the Tumbleweed
Minimal-VM appliance — the JeOS successor on x86_64, and
`make-arch-btrfs.sh` pivoting the stock Arch cloud image). 

The GitHub Actions workflow
(`.github/workflows/e2e-ubuntu-x86_64.yml`) runs both Ubuntu x86_64
cases (`03` to Gentoo OpenRC and `04` to Gentoo systemd) on KVM-enabled
x64 runners on every trigger; pushes to `dev` and pull requests are
path-filtered to `src/`, `tests/`, `Makefile` and the workflow itself,
and changes touching only `.md` files never trigger a run.
aarch64 is not covered there — GitHub arm64 runners have no KVM and TCG
is too slow (see `qemu/README.md` §8). The remaining x86_64 goldens
still await a first run.

## Reproduce

```sh
# 0. host tools: QEMU, EDK2 firmware, an ISO9660 tool (genisoimage/
#    mkisofs/xorriso on Linux, hdiutil on macOS), bash >= 5.1,
#    coreutils, curl, openssh, nc — see qemu/README.md §2

# 1. build the product script
make

# 2. confirm QEMU/firmware/accelerator resolution
D2G_ARCH=<arch> bash -c '. tests/qemu/config.sh; \
  echo "$QEMU_BIN / $FW / $D2G_ACCEL"'

# 3. fetch the stock cloud goldens for the target arch
D2G_ARCH=<arch> bash tests/qemu/golden/fetch.sh

# 4. hand-built goldens (idempotent; order matters). aarch64 needs the
#    two ALARM tarball goldens plus Debian-btrfs and openSUSE:
D2G_ARCH=aarch64 bash tests/qemu/golden/make-archarm.sh
D2G_ARCH=aarch64 bash tests/qemu/golden/make-archarm-btrfs.sh
D2G_ARCH=aarch64 bash tests/qemu/golden/make-debian-btrfs.sh
D2G_ARCH=aarch64 bash tests/qemu/golden/fetch-opensuse.sh
D2G_ARCH=aarch64 bash tests/qemu/golden/make-opensuse.sh

#    x86_64 pivots the stock images instead (requires KVM — see §status):
D2G_ARCH=x86_64 bash tests/qemu/golden/make-debian-btrfs.sh
D2G_ARCH=x86_64 bash tests/qemu/golden/fetch-opensuse.sh
D2G_ARCH=x86_64 bash tests/qemu/golden/make-opensuse.sh
D2G_ARCH=x86_64 bash tests/qemu/golden/make-arch-btrfs.sh

# 5. run: everything, selected cases (full conf names), or N in parallel
D2G_ARCH=<arch> bash tests/qemu/run.sh
D2G_ARCH=<arch> bash tests/qemu/run.sh -j 3
D2G_ARCH=<arch> bash tests/qemu/run.sh \
  01-debian-ext4-systemd-to-gentoo-openrc \
  05-fedora-btrfs-systemd-to-gentoo-openrc
```

Each run writes to `qemu/results/<arch>/<run-id>/` with per-case
`conversion.log`, `serial.log`, `verify.log`, a `result` file and a
`summary.csv`.

## Archived material

- `qemu/archive/openrc-host-results/` — record of the earliest
  OpenRC-**target** runs (short case names such as `debian-openrc`), with
  the original runner environment, its passing result, and a run-id
  table. Note: every host golden boots **systemd**; `-openrc` denotes the
  conversion **target** init, not the host init. The current main matrix
  keeps all `*-openrc` cases (7) and `*-systemd` cases (7).

## Product changes driven by the tests

The tests found and the suite fixed several real bugs; the annotated
list with evidence is in `qemu/README.md` §7. Headlines:

- chroot `/boot`/ESP visibility for the mount-boot eclass
  (`prepareBootMounts`, `--rbind`)
- GRUB default-entry regex for `gentoo-kernel-bin` menu ids
- interface naming mismatch traced to cloud-init/netplan pinning a
  first-boot name over the udev PCI-path name; resolved by preferring
  `ID_NET_NAME_PATH`, with MAC binding only as fallback
- iproute2 `nhid`/continuation-line route parsing
- stage3 list last-line-without-newline parsing
- data-driven prerequisite package map
- per-VM EFI vars, fixed PCI addrs, SSH hard timeout in the harness
