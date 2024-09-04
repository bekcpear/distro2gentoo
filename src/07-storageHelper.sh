#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

declare -a _D2G_FS_SOURCES _D2G_FS_MOUNTPOINTS _D2G_FS_TYPES _D2G_FS_OPTS

_D2G_LVM_ENABLED=0
declare -a _D2G_LVM_LVS _D2G_LVM_LVS_MOUNTPOINTS

_D2G_LUKS_ENABLED=0
declare -a _D2G_LUKS_PARTS _D2G_LUKS_PARTS_MOUNTPOINTS _D2G_LUKS_PARTS_PARENTS

_D2G_BTRFS_ENABLED=0
_D2G_BTRFS_SUBVOL_ROOTFS=""
declare -a _D2G_BTRFS_MOUNTPOINTS _D2G_BTRFS_SUBVOLS _D2G_BTRFS_OPTS

# TODO, the above variables are scattered throughout different scripts, improve it

_analyze_mnt() {
	local _name _source _mp __mp _type _opts
	while read -r _source _mp _type _opts _; do
		_D2G_FS_SOURCES+=("${_source}")
		_D2G_FS_MOUNTPOINTS+=("${_mp}")
		_D2G_FS_TYPES+=("${_type}")
		_D2G_FS_OPTS+=("${_opts}")
	done <<<"$(findmnt --noheadings -loSOURCE,TARGET,FSTYPE,OPTIONS)"

	local _sys_path_pattern='^(/|\[SWAP\])'
	while read -r _name _type _mp; do
		case "$_type" in
			crypt)
				while read -r __mp; do
					if [[ ${__mp} =~ ${_sys_path_pattern} ]]; then
						_D2G_LUKS_ENABLED=1
						_D2G_LUKS_PARTS+=("${_name}")
						_D2G_LUKS_PARTS_MOUNTPOINTS+=("${__mp}")
						_D2G_LUKS_PARTS_PARENTS+=("$(lsblk -tpo NAME | grep -B1 "${_name}" | head -1 | cut -d'-' -f2)")
						break
					fi
				done <<<"$(lsblk -lnoMOUNTPOINTS "${_name}")"
				;;
			lvm)
				if [[ ${_mp} =~ ${_sys_path_pattern} ]]; then
					_D2G_LVM_ENABLED=1
					_D2G_LVM_LVS+=("${_name}")
					_D2G_LVM_LVS_MOUNTPOINTS+=("${_mp}")
				fi
				;;
			*)
				:
				;;
		esac
	done <<<"$(lsblk -lpnoNAME,TYPE,MOUNTPOINT)"

	local -i i
	local __subvol
	for (( i = 0; i < ${#_D2G_FS_TYPES[@]}; ++i )); do
		if [[ ${_D2G_FS_TYPES[i]} == btrfs ]]; then
			if [[ ${_D2G_FS_MOUNTPOINTS[i]} =~ ^/ ]]; then
				_D2G_BTRFS_ENABLED=1
				_D2G_BTRFS_MOUNTPOINTS+=("${_D2G_FS_MOUNTPOINTS[i]}")
				__subvol="$(<<<"${_D2G_FS_SOURCES[i]}" sed -nE 's/^[^[]+\[([^]]+)\]/\1/p')"
				_D2G_BTRFS_SUBVOLS+=("${__subvol}")
				_D2G_BTRFS_OPTS+=("${_D2G_FS_OPTS[i]}")
				if [[ ${_D2G_FS_MOUNTPOINTS[i]} == / ]]; then
					_D2G_BTRFS_SUBVOL_ROOTFS="${__subvol}"
				fi
			fi
		fi
	done
}

prepareBtrfsStuffs() {
	# detect btrfs readonly subvol
	while read -r _ _ _ _ _ _ _ _ __subvol_path; do
		for (( i = 0; i < ${#_D2G_BTRFS_SUBVOLS[@]}; ++i )); do
			__subvol_path=${__subvol_path#<FS_TREE>}
			__subvol_path_remaining=${__subvol_path#"${_D2G_BTRFS_SUBVOLS[i]}"}
			if [[ ${__subvol_path_remaining} != "${__subvol_path}" ]]; then
				__subvol_path_readonlys+=("${_D2G_BTRFS_MOUNTPOINTS[i]}${__subvol_path_remaining}")
			fi
		done
	done <<<"$(btrfs subvolume list -ar /)"

	for __subvol_path_readonly in "${__subvol_path_readonlys[@]}"; do
		_log w "'${__subvol_path_readonly}' is a readonly subvolume."
		_D2G_EXCLUDED_READONLY_SUBVOL_PATH_OPTS+=" -and ! -regex '${__subvol_path_readonly}.*'"
	done

	# tune btrfs rootfs opts in /etc/fstab
	if [[ -n ${_D2G_BTRFS_SUBVOL_ROOTFS} ]]; then
		__btrfs_fstab_rootfs_subvol_sed_pattern="/subvol/!s/^([[:space:]]*[^#][^[:space:]]+[[:space:]]+\/[[:space:]]+btrfs[[:space:]]+[^[:space:]]+)[[:space:]]+([[:digit:]].+)$/\1,subvol=${_D2G_BTRFS_SUBVOL_ROOTFS//\//\\\/}  \2/"
		_log i ">>> sed -Ei '${__btrfs_fstab_rootfs_subvol_sed_pattern}' ${NEWROOT}/etc/fstab"
		eval "sed -Ei '${__btrfs_fstab_rootfs_subvol_sed_pattern}' ${NEWROOT}/etc/fstab"

		# keep the contents within the root subvol but with different path
		# TODO, should be imporved
		#for (( i = 0; i < ${#_D2G_BTRFS_SUBVOLS[@]}; ++i )); do
		#	if [[ ${_D2G_BTRFS_SUBVOL_ROOTFS} == "${_D2G_BTRFS_SUBVOLS[i]}" ]]; then
		#		continue
		#	fi
		#	__btrfs_subvol_rootfs_remaining=${_D2G_BTRFS_SUBVOL_ROOTFS#"${_D2G_BTRFS_SUBVOLS[i]}"}
		#	if [[ ${__btrfs_subvol_rootfs_remaining} != "${_D2G_BTRFS_SUBVOL_ROOTFS}" ]]; then
		#		_D2G_EXCLUDED_ROOTFS_SUBVOL_PATH_OPTS=" -and ! -regex '${_D2G_BTRFS_MOUNTPOINTS[i]}${__btrfs_subvol_rootfs_remaining}.*'"
		#	fi
		#done

	fi
}

# TODO, other formats

