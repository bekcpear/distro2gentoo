#!/usr/bin/env bash
#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

set -e
set -o pipefail
export LC_ALL=C

[[ $(bash --version | head -1) =~ version[[:space:]]([[:digit:]]+)\.([[:digit:]]+)\.[[:digit:]]+\([[:digit:]]+\) ]] || true
BASH_VER_MAJOR="${BASH_REMATCH[1]}"
BASH_VER_MINOR="${BASH_REMATCH[2]}"
if (( BASH_VER_MAJOR < 5 )) && (( BASH_VER_MINOR < 4 )); then
	echo "Please update the bash version to at least 4.4"
	exit 1
fi

BINHOST_ENABLED=1
EFI_ENABLED=0
NECESSARY_CMDS=()
MIRROR=""
STAGE3_TARBALL=""

D2G_GRUB_CMDLINE_LINUX=''
D2G_GRUB_CMDLINE_LINUX_DEFAULT=''
D2G_UNUNIFIED_GRUB_CMDLINE_LINUX=''
D2G_UNUNIFIED_GRUB_CMDLINE_LINUX_DEFAULT=''

EFIMNT=""

GRUB_INSTALLED=0
GRUB_CONFIGURED=0

CPUARCH="$(uname -m)"
CPUARCH="${CPUARCH/x86_64/amd64}"
CPUARCH="${CPUARCH/aarch64/arm64}"
NEWROOT="/root.d2g.${CPUARCH}"
TMP_DIR="$(mktemp -t "distro2gentoo.XXXXXXXX" -d)"

trap '
rm -rf "$TMP_DIR"
umount -R "$NEWROOT"/* &>/dev/null || true
' EXIT

