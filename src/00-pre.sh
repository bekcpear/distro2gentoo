#!/usr/bin/env bash
##
##  Author: Ryan Tsien @cwittlut <i@bitbili.net>
## License: GPL-2
##

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

# ---------------------------------------------------------------------------
# Global configuration and runtime state.
# All mutable state shared between modules is declared here on purpose;
# the modules below only define functions (and module-local constants).
# ---------------------------------------------------------------------------

# user parameters
BINHOST_ENABLED=1

# Non-interactive knobs for CI/testing (see tests/qemu/README.md):
#   D2G_NONINTERACTIVE=1   accept the auto-detected mirror and the default stage3
#   D2G_MIRROR=<url>       preset the distfiles mirror and skip its prompt
#   D2G_GIT_MIRROR=<url>   preset the portage git mirror
#   D2G_STAGE3_REGEX=<re>  auto-select the first stage3 tarball whose name matches
#   D2G_COUNTDOWN=0        skip every countdown delay

# environment
CPUARCH="$(uname -m)"
CPUARCH="${CPUARCH/x86_64/amd64}"
CPUARCH="${CPUARCH/aarch64/arm64}"
NEWROOT="/root.d2g.${CPUARCH}"
TMP_DIR="$(mktemp -t "distro2gentoo.XXXXXXXX" -d)"
EFI_ENABLED=0
EFIMNT=""

# interactive selections
MIRROR=""
STAGE3_TARBALL=""

# host commands that must exist (solved by prerequisites module if missing)
NECESSARY_CMDS=()

# bootloader
D2G_GRUB_CMDLINE_LINUX=''
D2G_GRUB_CMDLINE_LINUX_DEFAULT=''
D2G_UNUNIFIED_GRUB_CMDLINE_LINUX=''
D2G_UNUNIFIED_GRUB_CMDLINE_LINUX_DEFAULT=''
GRUB_INSTALLED=0
GRUB_CONFIGURED=0

# storage detection, filled by _analyze_mnt
declare -a _D2G_FS_SOURCES _D2G_FS_MOUNTPOINTS _D2G_FS_TYPES _D2G_FS_OPTS
_D2G_LVM_ENABLED=0
declare -a _D2G_LVM_LVS _D2G_LVM_LVS_MOUNTPOINTS
_D2G_LUKS_ENABLED=0
declare -a _D2G_LUKS_PARTS _D2G_LUKS_PARTS_MOUNTPOINTS _D2G_LUKS_PARTS_PARENTS
_D2G_BTRFS_ENABLED=0
_D2G_BTRFS_SUBVOL_ROOTFS=""
declare -a _D2G_BTRFS_MOUNTPOINTS _D2G_BTRFS_SUBVOLS _D2G_BTRFS_OPTS
_D2G_EXCLUDED_READONLY_SUBVOL_PATH_OPTS=""

# packages
declare -a _D2G_DRACUT_MODULES _D2G_ONETIME_PKGS _D2G_EXTRA_DEPS _D2G_BINHOST_ARGS
_D2G_PKG_DB_Updated=0

# finalize
_D2G_ALL_UMOUNTED=1

trap '
rm -rf "$TMP_DIR"
umount -R "$NEWROOT"/* &>/dev/null || true
' EXIT
