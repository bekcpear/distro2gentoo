#!/usr/bin/env bash
# Runs inside the guest after conversion + reboot.
# Usage: verify-guest.sh <init: openrc|systemd> <rootfs: ext4|btrfs> <mirror-url>
set -u

INIT=$1
FS=$2
MIRROR=$3
FAIL=0

check() { # <name> <condition-command...>
	local name=$1; shift
	if "$@" >/dev/null 2>&1; then
		echo "CHECK-PASS $name"
	else
		echo "CHECK-FAIL $name"
		FAIL=1
	fi
}

. /etc/os-release 2>/dev/null
check "os-is-gentoo" bash -c "[[ ${NAME:-} == *Gentoo* ]]"
check "portage-tree-present" test -d /var/db/repos/gentoo
check "kernel-is-gentoo-bin" bash -c 'uname -r | grep -q gentoo'

if [[ $INIT == systemd ]]; then
	check "pid1-is-systemd" bash -c '[[ $(cut -d" " -f1 /proc/1/comm) == systemd ]]'
	check "systemd-sshd-active" systemctl is-active --quiet sshd.service
	check "systemd-networkd-or-online" bash -c 'systemctl is-active --quiet systemd-networkd.service || systemctl is-active --quiet NetworkManager.service'
else
	check "pid1-is-openrc-init" bash -c '[[ $(cut -d" " -f1 /proc/1/comm) == init ]]'
	check "openrc-sshd-started" rc-service sshd status
fi

check "sshd-listening-22" bash -c 'grep -qiE ":[[:space:]]*0016" /proc/net/tcp /proc/net/tcp6'
check "default-route-present" ip route show default
mirror_host=${MIRROR#*://}; mirror_host=${mirror_host%%/*}
if bash -c "exec 3<>/dev/tcp/${mirror_host}/443" 2>/dev/null \
		|| bash -c "exec 3<>/dev/tcp/${mirror_host}/80" 2>/dev/null; then
	echo "CHECK-PASS mirror-host-reachable"
else
	echo "CHECK-FAIL mirror-host-reachable"
	FAIL=1
fi

# grub configuration written by the script
check "grubcfg-exists" test -s /boot/grub/grub.cfg
check "grubcfg-has-gentoo-kernel" grep -q gentoo-dist /boot/grub/grub.cfg
check "grub-saved-entry" bash -c 'grub-editenv list 2>/dev/null | grep -q saved_entry'

# preservation / cleanup
check "root-dir-preserved" test -f /root/d2g-marker-root
check "home-dir-preserved" test -f /home/d2g-marker-home
check "old-etc-wiped" bash -c '[[ ! -e /etc/d2g-marker-etc ]]'
check "newroot-removed" bash -c '! ls -d /root.d2g.* 2>/dev/null'

# root filesystem
check "rootfs-type" bash -c "[[ $(findmnt -no FSTYPE /) == $FS ]]"
if [[ $FS == btrfs ]]; then
	check "btrfs-fstab-subvol" grep -q subvol= /etc/fstab
fi

echo
if (( FAIL == 0 )); then
	echo "ALL-CHECKS-PASSED"
else
	echo "SOME-CHECKS-FAILED"
fi
exit $FAIL
