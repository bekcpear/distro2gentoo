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

	prepareBootMounts
}

# The mount-boot eclass (used by grub and gentoo-kernel-bin) aborts in
# pkg_pretend when fstab lists /boot or an ESP that is not mounted *as seen
# from inside the chroot*. /proc/mounts in a chroot only exposes mounts
# under the chroot root, so the host's /boot and ESP must be made visible
# at the matching paths before anything is emerged.
prepareBootMounts() {
	local boot_in_fstab=0 boot_rbound=0

	# A separate /boot filesystem declared in fstab (a partition or, on
	# Fedora, a btrfs subvolume) often has the ESP mounted underneath it.
	if awk '$2 == "/boot" {found=1} END{exit !found}' /etc/fstab; then
		boot_in_fstab=1
		mountpoint -q /boot || mount /boot 2>/dev/null || true
	fi

	# Mount the ESP on the host *before* /boot is rbound below: rbind only
	# captures submounts that exist at that moment, so an unmounted
	# /boot/efi would otherwise enter the chroot as an empty directory.
	local esp_mp=
	if (( EFI_ENABLED == 1 )); then
		# candidates understood by the mount-boot eclass, plus Ubuntu's /boot/firmware
		local mp
		for mp in /efi /boot/efi /boot/EFI /boot/firmware; do
			awk -v m="$mp" '$2 == m {found=1} END{exit !found}' /etc/fstab || continue
			mountpoint -q "$mp" || _do mount "$mp" 2>/dev/null || true
			if mountpoint -q "$mp"; then
				esp_mp="$mp"
			else
				_log w "ESP '${mp}' is in fstab but cannot be mounted, the grub/kernel emerge may fail."
			fi
			break
		done
	fi

	# rbind propagates those submounts as one coherent tree, which lets
	# grub-install resolve the ESP's underlying block device.
	if (( boot_in_fstab )) && mountpoint -q /boot && \
		! mountpoint -q "${NEWROOT}/boot"; then
		_do mount --rbind /boot "${NEWROOT}/boot"
		boot_rbound=1
	fi

	(( EFI_ENABLED == 1 )) || return 0
	[[ -n $esp_mp ]] || return 0

	# an ESP nested under /boot already arrived via the rbind above;
	# a plain nested bind there would break grub's device resolution
	if (( boot_rbound == 1 )) && [[ $esp_mp == /boot/* ]]; then
		EFIMNT="$esp_mp"
		return
	fi
	mkdir -p "${NEWROOT}${esp_mp}"
	if ! mountpoint -q "${NEWROOT}${esp_mp}"; then
		_do mount --bind "$esp_mp" "${NEWROOT}${esp_mp}"
	fi
	EFIMNT="$esp_mp"
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

