# Archive: original OpenRC-target test cases

## What is archived here

The earliest E2E test run converted each **systemd** cloud host into a
Gentoo **OpenRC** system. At that stage the matrix had one case per host
and used short case names (e.g. `debian-openrc`, `03-ubuntu-openrc`,
`fedora-openrc`), before the matrix was expanded to the current
`<host>-<fs>-<target-init>` naming (e.g. `01-debian-ext4-openrc`).

This directory preserves the record of that original OpenRC-target run.
The case **configuration** itself is the same intent as the current
`*-openrc.conf` cases in `../../cases/aarch64/`, so only this note and
the result references are kept (no duplicated `.conf` files).

## Important clarification: host init vs target init

Throughout the whole test effort **every host golden boots systemd**:

| host golden | host init |
|---|---|
| Debian 12 genericcloud | systemd |
| Ubuntu 24.04 cloudimg | systemd |
| Fedora 44 Cloud Base | systemd |
| Arch Linux ARM (hand-built) | systemd + systemd-networkd |
| openSUSE Tumbleweed JeOS | systemd + wicked/NetworkManager |

There was **never a golden that boots native OpenRC**. The `-openrc`
suffix in case names refers to the **target** init: the conversion
replaces the running system with a Gentoo `stage3-*-openrc-*` tarball.
The corresponding `-systemd` cases use a `stage3-*-systemd-*` tarball on
the same systemd host images.

So the current main matrix already implements the required design:

> native systemd hosts, converted to both Gentoo OpenRC and Gentoo
> systemd.

Nothing needs to be moved out of `cases/aarch64/` for that reason.

## Passing OpenRC-target result runs (aarch64)

Result directories live under `../../results/aarch64/<timestamp>/`.

| host / fs | case (old short name) | run id | result |
|---|---|---|---|
| Debian ext4 | `debian-openrc` | 20261026-234501 | verify PASS |
| Ubuntu ext4 | `03-ubuntu-openrc` | 20261027-000000 | verify PASS |
| Fedora btrfs | `05-fedora-btrfs-openrc` | 20261027-004851 | verify PASS |
| Arch ext4 | `07-arch-ext4-openrc` | 20261027-020041 | verify PASS |
| Debian btrfs | `09-debian-btrfs-openrc` | 20261027-205524 | verify PASS |
| openSUSE btrfs | `11-opensuse-btrfs-openrc` | 20261027-123705 | verify PASS |
| Arch btrfs | `13-arch-btrfs-openrc` | 20261027-163733 | verify PASS |

## Current equivalent cases

See `../../cases/aarch64/`:

`01/03/05/07/09/11/13-*-openrc.conf` — systemd host → Gentoo OpenRC
`02/04/06/08/10/12/14-*-systemd.conf` — systemd host → Gentoo systemd
