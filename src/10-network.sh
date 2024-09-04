#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

# TODO: support bridge
# TODO: IPv6 RA for netifrc (openrc)
# TODO: DHCP/DHCPv6 for netifrc (net-misc/dhcpcd or net-misc/dhcp does not installed by default for now, 20221113)
configNetwork() {
	local -A _dev_prefix_priority=([en]=9 [wl]=8 [ww]=7 [eth]=6 [wlan]=5)
	local -a _netdev _netproto _netdst _netgateway _netdev6 _netproto6 _netdst6 _netgateway6
	local _ __dst __via __gateway __dev __proto

	_with_high_priority() {
		local __first=${_dev_prefix_priority[${1:0:4}]:-${_dev_prefix_priority[${1:0:3}]:-${_dev_prefix_priority[${1:0:2}]:-0}}}
		local __second=${_dev_prefix_priority[${2:0:4}]:-${_dev_prefix_priority[${2:0:3}]:-${_dev_prefix_priority[${2:0:2}]:-0}}}
		(( __first > __second ))
	}
	_has_priority() {
		[[ -n ${_dev_prefix_priority[${1:0:4}]:-${_dev_prefix_priority[${1:0:3}]:-${_dev_prefix_priority[${1:0:2}]}}} ]]
	}

	_assign_extra_net() {
		local __dst=$1 __via=$2 __gateway=$3 __dev=$4 __proto=$5 __t=$6
		if [[ ${__via} != "via" ]]; then
			__proto=${__dev}
			__dev=${__gateway}
			__gateway=""
		fi
		if [[ -z "${__dev}" ]]; then
			return
		fi
		local __netdevprim="_netdev${__t}[0]"
		if [[ ${!__netdevprim} != "${__dev}" ]] && \
			_has_priority "${__dev}"; then
			eval "_netdev${__t}+=( '${__dev}' )"
			eval "_netproto${__t}+=( '${__proto}' )"
			eval "_netdst${__t}+=( '${__dst}' )"
			eval "_netgateway${__t}+=( '${__gateway}' )"
		fi
	}

	# ipv4 default route/device
	_assign_primary_net() {
		_netdev[0]=${1}
		_netgateway[0]=${2}
		_netproto[0]=${3}
		_netdst[0]="0.0.0.0/0"
	}

	local __iproute_updated=
	while ! [[ $(ip -d -o route show type unicast to default) =~ ^unicast ]]; do
		if [[ -n ${__iproute_updated} ]]; then
			_log ee "iproute2 version is still too old, please solve it manually"
		fi
		_log w "iproute2 version is too old, updating it ..."
		_install_pkg ip
		__iproute_updated=1
	done

	while read -r _ _ _ __gateway _ __dev _ __proto _; do
		if [[ -z ${_netdev[0]} ]] || \
			_with_high_priority "${__dev}" "${_netdev[0]}"; then
			_assign_primary_net "${__dev}" "${__gateway}" "${__proto}"
		fi
	done<<<"$(ip -d -o route show type unicast to default)"

	# ipv4 extra route/device
	while read -r _ __dst __via __gateway _ __dev _ __proto _; do
		_assign_extra_net "${__dst}" "${__via}" "${__gateway}" "${__dev}" "${__proto}" ""
	done<<<"$(ip -d -o route show type unicast)"

	# ipv6 default route/device
	_assign_primary_net6() {
		_netdev6[0]=${1}
		_netgateway6[0]=${2}
		_netproto6[0]=${3}
		_netdst6[0]="::/0"
	}
	while read -r _ _ _ __gateway _ __dev _ __proto _; do
		if [[ -z ${_netdev6[0]} ]] || \
			_with_high_priority "${__dev}" "${_netdev6[0]}"; then
			_assign_primary_net6 "${__dev}" "${__gateway}" "${__proto}"
		fi
	done<<<"$(ip -6 -d -o route show type unicast to default)"

	# ipv6 extra route/device
	while read -r _ __dst __via __gateway _ __dev _ __proto _; do
		_assign_extra_net "${__dst}" "${__via}" "${__gateway}" "${__dev}" "${__proto}" 6
	done<<<"$(ip -6 -d -o route show type unicast | grep -Ev '^unicast[[:space:]]+fe80::')"

	local -a _dev _proto _proto6 _dst _dst6 _gateway _gateway6

	_assign_net() {
		_dev+=( "${1}" )
		_proto+=( "${2}" )
		_proto6+=( "${3}" )
		_dst+=( "${4}" )
		_dst6+=( "${5}" )
		_gateway+=( "${6}" )
		_gateway6+=( "${7}" )
	}

	# check primary network devices
	if [[ ${_netdev[0]} == "${_netdev6[0]}" ]]; then
		_assign_net "${_netdev[0]}" "${_netproto[0]}" "${_netproto6[0]}" "${_netdst[0]}" "${_netdst6[0]}" "${_netgateway[0]}" "${_netgateway6[0]}"
	else
		if [[ -n ${_netdev[0]} ]]; then
		_assign_net "${_netdev[0]}" "${_netproto[0]}" "" "${_netdst[0]}" "" "${_netgateway[0]}" ""
		fi
		if [[ -n ${_netdev6[0]} ]]; then
		_assign_net "${_netdev6[0]}" "" "${_netproto6[0]}" "" "${_netdst6[0]}" "" "${_netgateway6[0]}"
		fi
	fi

	# check extra network devices
	local -i _i _j __j
	local -a __added_j
	local __added
	for (( _i = 1; _i < ${#_netdev[@]}; _i++ )); do
		__dev=${_netdev[$_i]}
		__added=0
		for (( _j = 1; _j < ${#_netdev6[@]}; _j++ )); do
			if [[ ${__dev} == "${_netdev6[$_j]}" ]]; then
				# means _netdev6[_j] must not equal to _netdev[0], safely to add
				__added_j+=( "$_j" )
				_assign_net "${_netdev[$_i]}" "${_netproto[$_i]}" "${_netproto6[$_j]}" "${_netdst[$_i]}" "${_netdst6[$_j]}" "${_netgateway[$_i]}" "${_netgateway6[$_j]}"
				__added=1
				break
			fi
		done
		if [[ ${__added} == 0 ]]; then
			_assign_net "${_netdev[$_i]}" "${_netproto[$_i]}" "" "${_netdst[$_i]}" "" "${_netgateway[$_i]}" ""
		fi
	done
	for (( _j = 1; _j < ${#_netdev6[@]}; _j++ )); do
		__added=0
		for __j in "${__added_j[@]}"; do
			if [[ $_j == "$__j" ]]; then
				__added=1
			fi
		done
		if [[ ${__added} == 0 ]]; then
			# check whether the _netdev6[_j] is equal to _netdev[0]
			if [[ ${_netdev6[$_j]} == "${_netdev[0]}" ]]; then
				# _netdev[0] always has the index 0, assign maunally.
				_proto6[0]="${_netproto6[$_j]}"
				_dst6[0]="${_netdst6[$_j]}"
				_gateway6[0]="${_netgateway6[$_j]}"
			else
				_assign_net "${_netdev6[$_j]}" "" "${_netproto6[$_j]}" "" "${_netdst6[$_j]}" "" "${_netgateway6[$_j]}"
			fi
		fi
	done

	_the_correct_dev_name() {
		# fix to use correct interface name
		# refer to https://www.freedesktop.org/wiki/Software/systemd/PredictableNetworkInterfaceNames/
		local _netdev=$1
		local -a __devs
		if [[ $_netdev =~ ^(eth|wlan) ]] && \
			[[ ! "${D2G_GRUB_CMDLINE_LINUX}${D2G_GRUB_CMDLINE_LINUX_DEFAULT}" =~ net\.ifnames=0 ]]; then
			read -r -a __devs <<<"$(ip link show "${_netdev}" | grep -E '^\s+altname\s' | awk '{print $2}')"
			if [[ ${#__devs[@]} -eq 0 ]]; then
				_log w "cannot found the altname for this legacy network device name: $_netdev"
				_log w "use this legacy name, and set 'net.ifnames=0' to the kernel cmdline ..."
				echo -n "LEGACY"
				# TODO: try to guess the correct modern name
			else
				for __dev in "${__devs[@]}"; do
					case ${__dev:2:1} in
						o)
							_netdev=${__dev}
							break
							;;
						s)
							if [[ ${_netdev:2:1} != o ]]; then
								_netdev=${__dev}
							fi
							;;
						p)
							if [[ ! ${_netdev:2:1} =~ [os] ]]; then
								_netdev=${__dev}
							fi
							;;
					esac
				done
			fi
		fi
		echo -n "${_netdev}"
	}

	# loop to add
	for (( _i = 0; _i < ${#_dev[@]}; _i++ )); do
		local __dev=${_dev[$_i]} \
			__proto=${_proto[$_i]} \
			__proto6=${_proto6[$_i]} \
			__dst=${_dst[$_i]} \
			__dst6=${_dst6[$_i]} \
			__gateway=${_gateway[$_i]} \
			__gateway6=${_gateway6[$_i]}

		###
		local -a __ip=() __ip6=()
		local ___ip=
		if [[ ${__proto} != dhcp ]]; then
			while read -r _ ___ip _; do
				if [[ -n ${___ip} ]]; then
					__ip+=( "${___ip}" )
				fi
			done <<<"$(ip -d addr show dev "${__dev}" scope global | grep -E '^\s+inet\s')"
		fi
		if [[ ${__proto6} != dhcp ]] && [[ ${__proto6} != ra ]]; then
			while read -r _  ___ip _; do
				if [[ -n ${___ip} ]]; then
					__ip6+=( "${___ip}" )
				fi
			done <<<"$(ip -d addr show dev "${__dev}" scope global | grep -E '^\s+inet6\s')"
		fi

		###
		__dev=$(_the_correct_dev_name "${__dev}")
		if [[ ${__dev} =~ ^LEGACY ]]; then
			__dev=${__dev#LEGACY}
			D2G_GRUB_CMDLINE_LINUX+=" net.ifnames=0"
		fi

		###
		local __networkd_match="[Match]" \
			__networkd_network="[Network]" \
			__networkd_address="" \
			__networkd_route="[Route]" \
			__networkd_address6="" \
			__networkd_route6="[Route]" \
			__networkd_dhcp="" \
			__networkd="" \
			__netifrc_config="config_${__dev}=\"" \
			__netifrc_routes="routes_${__dev}=\"" \
			__netifrc="" \
			__networkd_match+=$'\n'"Name=${__dev}"

		###
		for ___ip in "${__ip[@]}"; do
			__networkd_address+=${__networkd_address:+$'\n\n'}"[Address]"$'\n'"Address=${___ip}"
		done
		for ___ip in "${__ip6[@]}"; do
			__networkd_address6+=${__networkd_address6:+$'\n\n'}"[Address]"$'\n'"Address=${___ip}"
		done

		###
		__networkd_route+=$'\n'"Destination=${__dst}"
		__networkd_route+=$'\n'"Gateway=${__gateway}"
		__networkd_route6+=$'\n'"Destination=${__dst6}"
		__networkd_route6+=$'\n'"Gateway=${__gateway6}"

		###
		if [[ ${__proto6} != ra ]]; then
			__networkd_network+=$'\n'"IPv6AcceptRA=false"
		fi

		###
		if [[ "${__proto}${__proto6}" =~ dhcp ]]; then
			if [[ ${__proto6} != dhcp ]]; then
				__networkd_dhcp="ipv4"
			elif [[ ${__proto} != dhcp ]]; then
				__networkd_dhcp="ipv6"
			else
				__networkd_dhcp="yes"
			fi
			__networkd_network+=$'\n'"DHCP=${__networkd_dhcp}"
		fi

		###
		__networkd="${__networkd_match}"$'\n'$'\n'"${__networkd_network}"
		if [[ ${__proto} == dhcp ]]; then
			__netifrc_config+=$'\n'"dhcp"
		elif [[ ${__proto} != "" ]]; then
			__netifrc_config+=$'\n'"${__ip[*]}"
			__networkd+=$'\n'$'\n'"${__networkd_address}"
			if [[ ${__proto} =~ boot|static ]]; then
				__netifrc_routes+=$'\n'"${__dst} via ${__gateway}"
				__networkd+=$'\n'$'\n'"${__networkd_route}"
			fi
		fi
		if [[ ${__proto6} == dhcp ]]; then
			__netifrc_config+=$'\n'"dhcpv6"
		elif [[ ${__proto6} != "" ]]; then
			__netifrc_config+=$'\n'"${__ip6[*]}"
			__networkd+=$'\n'$'\n'"${__networkd_address6}"
			if [[ ${__proto6} =~ boot|static ]]; then
				__netifrc_routes+=$'\n'"${__dst6} via ${__gateway6}"
				__networkd+=$'\n'$'\n'"${__networkd_route6}"
			fi
		fi
		__netifrc_config+=$'\n'"\""
		__netifrc_routes+=$'\n'"\""
		__netifrc="${__netifrc_config}"$'\n'"${__netifrc_routes}"

		mkdir -p "${NEWROOT}/etc/systemd/network"
		mkdir -p "${NEWROOT}/etc/conf.d"

		echo "${__networkd}" >"${NEWROOT}/etc/systemd/network/50-${__dev}.network"
		echo $'\n'"${__netifrc}" >>"${NEWROOT}/etc/conf.d/net"

		if [[ ! ${STAGE3_TARBALL} =~ systemd ]]; then
			ln -s net.lo "${NEWROOT}/etc/init.d/net.${__dev}"
			_chroot_exec rc-update add net.${__dev} default
		fi
	done

	echo $'\n\n'"# fallback nameserver"$'\n'"nameserver 1.1.1.1" >>"${NEWROOT}/etc/resolv.conf"

	if [[ ${STAGE3_TARBALL} =~ systemd ]]; then
		_chroot_exec systemctl enable systemd-networkd.service
	fi
}

