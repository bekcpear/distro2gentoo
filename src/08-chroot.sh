#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

prepareChroot() {
	_log i "mounting necessaries ..."
	_do mount -t proc /proc "${NEWROOT}/proc"
	_do mount --rbind /sys "${NEWROOT}/sys"
	_do mount --make-rslave "${NEWROOT}/sys"
	_do mount --rbind /dev "${NEWROOT}/dev"
	_do mount --make-rslave "${NEWROOT}/dev"
	_do mount -t tmpfs -o nosuid,nodev,mode=0755 run "${NEWROOT}/run"

	_log i "copying necessaries ..."
	_do cp -aL /etc/fstab "${NEWROOT}/etc/"
	_do cp -aL /etc/resolv.conf "${NEWROOT}/etc/" || true
	_do cp -aL /etc/hosts "${NEWROOT}/etc/" || true
	_do cp -aL /etc/hostname "${NEWROOT}/etc/" || \
		echo "gentoo" > "${NEWROOT}/etc/hostname"
	_do cp -aL /lib/modules "${NEWROOT}/lib/" || true

	_analyze_mnt
	mount /boot || true

	local rootshadow _newpass _newday
	rootshadow=$(grep -E '^root:' /etc/shadow)
	if [[ $rootshadow =~ ^root:\*: ]]; then
		_log i "setting root password to 'distro2gentoo' ..."
		_newpass=$(openssl passwd -1 distro2gentoo)
		_newday=$(echo "$(date +%s)/24/60/60" | bc)
	else
		_log i "backuping root password ..."
		_newpass=$(echo "$rootshadow" | cut -d':' -f2)
		_newday=$(echo "$rootshadow" | cut -d':' -f3)
	fi
	eval "sed -Ei '/root:\*:.*/s@root:\*:[[:digit:]]+:@root:${_newpass}:${_newday}:@' '${NEWROOT}/etc/shadow'"

	if [[ ${CPUARCH} == amd64 ]]; then
		echo $'\n'"GRUB_PLATFORMS=\"efi-64 pc\"" >> "${NEWROOT}/etc/portage/make.conf"
	else
		echo $'\n'"GRUB_PLATFORMS=\"efi-64\"" >> "${NEWROOT}/etc/portage/make.conf"
	fi
	echo $'\n'"GENTOO_MIRRORS=\"${MIRROR}\"" >> "${NEWROOT}/etc/portage/make.conf"
}

_chroot_exec() {
	local arg cmds=""
	for arg; do
		if [[ $arg =~ [[:space:]] ]]; then
			cmds+=" \"${arg//\"/\\\"}\""
		else
			cmds+=" ${arg}"
		fi
	done
	cmds="${cmds# }"
	_log w ">>> chroot '$NEWROOT' /bin/bash -lc '$cmds'"
	eval "chroot '$NEWROOT' /bin/bash -lc '$cmds'"
}

