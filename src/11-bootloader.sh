#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

# convert grub cmdline opts to Dracut specifics
# $1: result variable name
# $2...: cmdline opts
# TODO more options
_unify_cmdline_opts() {
	local _name=${1} _opt _opts_str_converted _tmpv _tmpv_luks_name _tmpv_luks_names
	local -a _opts _luks_opts _lvm_vg_opts _lvm_lv_opts
	local _uuid_pattern='[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{12}'
	shift

	__add_ununified_cmd_opt() {
		eval "D2G_UNUNIFIED${_name#_D2G}+=' $1'"
		_opts_str_converted+=" $1"
	}

	mapfile -t _opts <<<"$(echo "$*" | tr ' ' '\n' | sort -du)"
	for _opt in "${_opts[@]}"; do
		case "$_opt" in
			root=*)
				if [[ ${_opts_str_converted} =~ (^|[[:space:]])root= ]]; then
					_log e "Multiple 'root=' options, ignore '$_opt'!"
					__add_ununified_cmd_opt "$_opt"
				else
					_opts_str_converted+=" ${_opt}"
				fi
				;;
			dolvm)
				:
				;;
			rd.lvm.vg=*)
				_lvm_vg_opts+=( "${_opt}" )
				;;
			rd.lvm.lv=*)
				_lvm_lv_opts+=( "${_opt}" )
				;;
			crypt_root=*)
				if [[ ${_opt} =~ ^crypt_root=UUID=${_uuid_pattern}$ ]]; then
					_luks_opts+=( "rd.luks.uuid=${_opt/#crypt_root=UUID=/}" )
				else
					_log e "Unrecognized cmdline option: ${_opt}"
					__add_ununified_cmd_opt "$_opt"
				fi
				;;
			luks=*|rd.luks=*)
				_tmpv=${_opt/#*luks=/}
				if [[ ${_tmpv} =~ [[:digit:]]+ ]]; then
					_opts_str_converted+=" rd.luks=${_tmpv}"
				else
					case ${_tmpv} in
						yes)
							_opts_str_converted+=" rd.luks=1"
							;;
						no)
							_opts_str_converted+=" rd.luks=0"
							;;
						*)
							_log e "Unrecognized cmdline option: ${_opt}"
							__add_ununified_cmd_opt "$_opt"
							;;
					esac
				fi
				;;
			luks.crypttab=*|rd.luks.crypttab=*)
				_tmpv=${_opt/#*luks.crypttab=/}
				if [[ ${_tmpv} =~ [[:digit:]]+ ]]; then
					_opts_str_converted+=" rd.luks.crypttab=${_tmpv}"
				else
					case ${_tmpv} in
						yes)
							_opts_str_converted+=" rd.luks.crypttab=1"
							;;
						no)
							_opts_str_converted+=" rd.luks.crypttab=0"
							;;
						*)
							_log e "Unrecognized cmdline option: ${_opt}"
							__add_ununified_cmd_opt "$_opt"
							;;
					esac
				fi
				;;
			luks.uuid=*|rd.luks.uuid=*)
				_tmpv=${_opt/#*luks.uuid=/}
				_tmpv=${_tmpv/#luks-/}
				if [[ ${_tmpv} =~ ^${_uuid_pattern}$ ]]; then
					_luks_opts+=( "rd.luks.uuid=${_tmpv}" )
				else
					_log e "Unrecognized cmdline option: ${_opt}"
					__add_ununified_cmd_opt "$_opt"
				fi
				;;
			luks.name=*|rd.luks.name=*)
				_tmpv=${_opt/#*luks.name=/}
				_tmpv=${_tmpv/#luks-/}
				_tmpv_luks_name=${_tmpv/#*=/}
				_tmpv=${_tmpv/%=*/}
				if [[ ${_tmpv} =~ ^${_uuid_pattern}$ ]]; then
					_luks_opts+=( "rd.luks.uuid=${_tmpv}" )
					if [[ -n ${_tmpv_luks_name} ]]; then
						_log w "Name '${_tmpv_luks_name}' of cmdline option '${_opt}' has been stripped."
						_tmpv_luks_names+=" ${_tmpv_luks_name}"
					fi
				else
					_log e "Unrecognized cmdline option: ${_opt}"
					__add_ununified_cmd_opt "$_opt"
				fi
				;;
			luks.key=*|rd.luks.key=*)
				_tmpv=${_opt/#*luks.key=/}
				local _tmpv_luksdev _tmpv_keydev
				if [[ ${_tmpv} =~ ^${_uuid_pattern}= ]]; then
					_tmpv_luksdev=":UUID=${_tmpv/%=*/}"
					_tmpv=${_tmpv/#${_tmpv_luksdev/#UUID=}=/}
				fi
				if [[ ${_tmpv} =~ : ]]; then
					_tmpv_keydev=":${_tmpv/#*:/}"
				fi
				_opts_str_converted+=" rd.luks.key=${_tmpv/%:*/}${_tmpv_keydev}${_tmpv_luksdev}"
				;;
			*)
				__add_ununified_cmd_opt "$_opt"
				;;
		esac
	done

	# replace the root device with UUID
	if [[ ${_opts_str_converted} =~ [[:space:]]root=/dev/mapper/ ]]; then
		local _tmpv_root_name
		_tmpv_root_name=$(echo "${_opts_str_converted}" | sed -nE 's/.*\sroot=\/dev\/mapper\/([^\/[:space:]]+)\s.*/\1/p')
		for _tmpv in ${_tmpv_luks_names}; do
			if [[ ${_tmpv} == "${_tmpv_root_name}" ]]; then
				_opts_str_converted="${_opts_str_converted//root=\/dev\/mapper\/${_tmpv_root_name}/}"
				_opts_str_converted+=" root=UUID=$(lsblk -noUUID "/dev/mapper/${_tmpv_root_name}" | head -1)"
			fi
		done
	fi

	if [[ ${_name} == "D2G_GRUB_CMDLINE_LINUX" ]]; then
		if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
			local _tmpv_lvm_lv _tmpv_lvm_vg _tmpv_lvm_lv_val
			for (( i = 0; i < ${#_D2G_LVM_LVS[@]}; ++i )); do
				local _this_is_set=0 _first_line=0
				while read -r _tmpv_lvm_lv _tmpv_lvm_vg; do
					if [[ ${_tmpv_lvm_lv} == "LV" ]]; then
						_first_line=1
						continue
					elif [[ ${_first_line} == 0 ]]; then
						_log e "Cannot get LV and VG for '${_D2G_LVM_LVS[i]}'"
						break
					fi
					_tmpv_lvm_lv_val="rd.lvm.lv=${_tmpv_lvm_vg}/${_tmpv_lvm_lv}"
				done <<<"$(lvdisplay -Co lv_name,vg_name "${_D2G_LVM_LVS[i]}")"

				for _lvm_lv_opt in "${_lvm_lv_opts[@]}"; do
					if [[ "${_lvm_lv_opt}" == "${_tmpv_lvm_lv_val}" ]]; then
						_this_is_set=1
					fi
				done
				if [[ ${_this_is_set} == 0 ]]; then
					_lvm_lv_opts+=( "${_tmpv_lvm_lv_val}" )
				fi
			done
		fi

		if [[ ${_D2G_LUKS_ENABLED} == 1 ]]; then
			local _tmpv_luks_uuid _tmpv_luks_uuid_val
			for (( i = 0; i < ${#_D2G_LUKS_PARTS_PARENTS[@]}; ++i )); do
				local _this_is_set=0
				read -r _tmpv_luks_uuid _ <<<"$(lsblk -tnoUUID,NAME "${_D2G_LUKS_PARTS_PARENTS[i]}" | head -1)"
				_tmpv_luks_uuid_val="rd.luks.uuid=${_tmpv_luks_uuid}"
				for _luks_opt in "${_luks_opts[@]}"; do
					if [[ "${_luks_opt}" == "${_tmpv_luks_uuid_val}" ]]; then
						_this_is_set=1
					fi
				done
				if [[ ${_this_is_set} == 0 ]]; then
					_luks_opts+=("${_tmpv_luks_uuid_val}")
				fi
			done
		fi

	fi

	for _opt in "${_lvm_lv_opts[@]}" "${_lvm_vg_opts[@]}" "${_luks_opts[@]}"; do
		_opts_str_converted+=" ${_opt}"
	done

	eval "${_name}='${_opts_str_converted/#[[:space:]]/}'"

	unset _name _opts _opt _opts_str_converted _tmpv _tmpv_luks_name _tmpv_luks_names _luks_opts _lvm_vg_opts _lvm_lv_opts
}

# TODO, other bootloaders
setupGRUBCmdline() {
	local _cmdline _cmdline_default

	if [[ -f /etc/default/grub ]]; then
		cp -aL /etc/default/grub "${NEWROOT}/etc/default/._old_grub" || true
	else
		_log e "Cannot stat old GRUB configure file!"
		return
	fi

	_cmdline="$(. /etc/default/grub; echo "${GRUB_CMDLINE_LINUX}")"
	_cmdline="${_cmdline//quiet/}"
	_cmdline="${_cmdline//splash=silent/}"
	_cmdline="${_cmdline//splash/}"
	_cmdline="${_cmdline//rhgb/}"
	_unify_cmdline_opts D2G_GRUB_CMDLINE_LINUX "$_cmdline"

	_cmdline_default="$(. /etc/default/grub; echo "${GRUB_CMDLINE_LINUX_DEFAULT}")"
	_cmdline_default="${_cmdline_default//quiet/}"
	_cmdline_default="${_cmdline_default//splash=silent/}"
	_cmdline_default="${_cmdline_default//splash/}"
	_cmdline_default="${_cmdline_default//rhgb/}"
	_unify_cmdline_opts D2G_GRUB_CMDLINE_LINUX_DEFAULT "$_cmdline_default"
}

installGRUB() {
	sed -i "/GRUB_CMDLINE_LINUX=\"\"/aGRUB_CMDLINE_LINUX=\"${D2G_GRUB_CMDLINE_LINUX}\"" \
		"${NEWROOT}/etc/default/grub"
	sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/aGRUB_CMDLINE_LINUX_DEFAULT=\"${D2G_GRUB_CMDLINE_LINUX_DEFAULT}\"" \
		"${NEWROOT}/etc/default/grub"
	sed -i "/GRUB_DEFAULT=/aGRUB_DEFAULT=\"saved\"" "${NEWROOT}/etc/default/grub"
	echo $'\n'"GRUB_DISABLE_OS_PROBER=false" >>"${NEWROOT}/etc/default/grub"

	# keep the old /boot dir or mountpoint
	cp -a "${NEWROOT}"/boot/* /boot/
	mount --bind /boot "${NEWROOT}/boot"

	# find the boot device
	if [[ ${CPUARCH} =~ amd64 ]]; then
		# for pc target only
		local _bootdev
		if _bootdev=$(findmnt -no SOURCE /boot); then
			:
		else
			_bootdev=$(findmnt -no SOURCE /)
		fi
		_bootdev=$(lsblk -npsro TYPE,NAME "${_bootdev}" | awk '($1 == "disk") { print $2}')
		if [[ ! ${_bootdev} =~ ^/dev/mapper ]]; then
			if _chroot_exec grub-install --target=i386-pc "${_bootdev}"; then
				GRUB_INSTALLED=1
			fi
		else
			_log e "Boot device is a mapper, skip i386-pc target grub installation."
		fi
	fi
	# prepare efi
	if (( EFI_ENABLED == 1 )); then
		local _bootcurrent _partuuid _partuuid_alt
		local -a _boot_orders
		while read -r _head _val; do
			if [[ $_head == "BootCurrent:" ]]; then
				_bootcurrent="${_val}"
				continue
			fi
			if [[ $_head == "BootOrder:" ]]; then
				IFS="," read -r -a _boot_orders <<< "$_val"
				continue
			fi
			if [[ $_head =~ Boot${_bootcurrent} ]]; then
				_partuuid=$(echo "$_val" | sed -nE '/HD\(/s/.*HD\([^,]+,[^,]+,([^,]+),.*/\1/p')
				if [[ -n $_partuuid ]]; then
					break
				fi
			fi
			if [[ $_head =~ Boot${_boot_orders[0]} ]]; then
				_partuuid_alt=$(echo "$_val" | sed -nE '/HD\(/s/.*HD\([^,]+,[^,]+,([^,]+),.*/\1/p')
			fi
		done <<<"$(efibootmgr)"

		local efi_dev
		if [[ ${_partuuid} != "" ]]; then
			read -r efi_dev EFIMNT <<<"$(lsblk -noPATH,MOUNTPOINT "/dev/disk/by-partuuid/${_partuuid}")"
		else
			# hazily matching a possibile efi partition
			if [[ ${_partuuid_alt} != "" ]]; then
				read -r efi_dev EFIMNT <<<"$(lsblk -noPATH,MOUNTPOINT "/dev/disk/by-partuuid/${_partuuid_alt}")"
			else
				_log w "matching a possibile efi partition hazily ..."
				local _efidevs
				_efidevs="$(findmnt --fstab -nlt vfat -o TARGET,SOURCE)"
				if [[ $(<<<"${_efidevs}" wc -l) -ge 1 ]]; then
					local _efidev_m_f
					while read -r _efidev_m _efidev_d; do
						case ${_efidev_m} in
							*[eE][fF][iI]*)
								EFIMNT=${_efidev_m}
								efi_dev=${_efidev_d}
								_efidev_m_f=e
								;;
							*[bB][oO][oO][tT]*)
								if [[ ${_efidev_m_f} != "e" ]]; then
									EFIMNT=${_efidev_m}
									efi_dev=${_efidev_d}
									_efidev_m_f=b
								fi
								;;
							*)
								if [[ ${_efidev_m_f} == "" ]]; then
									EFIMNT=${_efidev_m}
									efi_dev=${_efidev_d}
								fi
								;;
						esac
					done <<<"${_efidevs}"
				fi
			fi
		fi

		if [[ -n ${efi_dev} ]]; then
			if [[ ${EFIMNT} == "" ]]; then
				if ! EFIMNT=$(findmnt --fstab -nlt vfat -oTARGET -S"${efi_dev}"); then
					# set a default efi mount point
					EFIMNT="/boot/efi"
				fi
			fi
			mkdir -p "${NEWROOT}${EFIMNT}"
			_do mount "${efi_dev}" "${NEWROOT}${EFIMNT}"
			if [[ ${CPUARCH} == amd64 ]]; then
				local _target="x86_64-efi"
			else
				local _target="arm64-efi"
			fi
			_chroot_exec grub-install --target="${_target}" --efi-directory="${EFIMNT}" --bootloader-id=Gentoo
			_chroot_exec grub-install --target="${_target}" --efi-directory="${EFIMNT}" --removable
			GRUB_INSTALLED=1
		else
			_log e "Cannot find EFI device!"
		fi
	fi
	if [[ ${GRUB_INSTALLED} == 0 ]]; then
		_log e "GRUB install failed!"
	fi
}

_get_menuentry_id_option_from_line() {
	local line="$1"
	local index=0 _inp=0 field="" next_is_id=0
	__echo_and_ret() {
		if [[ $next_is_id == 1 ]]; then
			echo -n "$field"
			return 1
		fi
	}
	while (( index < ${#line} )); do
		char="${line:$index:1}"
		((index++))
		case "$char" in
			\')
				if [[ $_inp == 0 ]]; then
					_inp=1
				else
					_inp=0
				fi
				;;
			" "|$'\t')
				if [[ $_inp == 0 ]]; then
					__echo_and_ret || return 0
					if [[ $field == '$menuentry_id_option' ]]; then
						next_is_id=1
					fi
					field=""
				else
					field+="$char"
				fi
				;;
			*)
				field+="$char"
				;;
		esac
	done
	if [[ -n "$field" ]]; then
		__echo_and_ret || return 0
	fi
}

ConfigureGRUB() {
	local _submenu _menuentry __menuentry _line
	local -a _menuentries

	_log w ">>> grub-mkconfig -o /boot/grub/grub.cfg"
	grub-mkconfig -o /boot/grub/grub.cfg

	_submenu=$(_get_menuentry_id_option_from_line "$(grep -E '^submenu ' /boot/grub/grub.cfg | head -1)")
	while read -r _line; do
		_menuentries+=( "$(_get_menuentry_id_option_from_line "$_line")" )
	done <<<"$(grep -E '^[[:space:]]+menuentry ' /boot/grub/grub.cfg)"
	for __menuentry in "${_menuentries[@]}"; do
		# match the first gentoo-dist kernel
		if [[ ${__menuentry} =~ gentoo-dist-adv ]]; then
			_menuentry=${__menuentry}
			break
		fi
	done
	if [[ -n "$_submenu" && -n "$_menuentry" ]]; then
		_log w ">>> grub-set-default '${_submenu}>${_menuentry}'"
		eval "grub-set-default '${_submenu}>${_menuentry}'"
		GRUB_CONFIGURED=1
	else
		return 1
	fi
}

