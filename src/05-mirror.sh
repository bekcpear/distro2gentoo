#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

_D2G_GIT_MIRROR="https://github.com/gentoo-mirror/gentoo.git"

_uris_from_xml() {
	local xmllint_cmd_fmt="xmllint --xpath '/mirrors/mirrorgroup[@country=\"@@COUNTRYCODE@@\"]/mirror/uri'"
	local old_xmllint=1 xmllint_cmd uris
	if [[ $(xmllint --version 2>&1 | head -1 | cut -d' ' -f5 | cut -d'-' -f1) -ge 20909 ]]; then
		xmllint_cmd_fmt="${xmllint_cmd_fmt%\'}/text()'"
		unset old_xmllint
	fi
	xmllint_cmd="${xmllint_cmd_fmt/@@COUNTRYCODE@@/$1}"

	uris=""
	if uris=$(eval "$xmllint_cmd" "$2"); then
		if [[ -n $old_xmllint ]]; then
			uris="${uris//<\/uri>/$'\n'}"
			uris="$(echo "$uris" | cut -d'>' -f2)"
		fi
		# remove rsync uris
		uris="$(echo -n "$uris" | sed -E '/^rsync/d')"
	fi
	echo -n "$uris"
}

setupMirror() {
	_log i "Getting mirror list..."

	set +e
	[[ $(downloadCat -H 'I-Agree-To-Use-Only-For-The-Distro2Gentoo-Script: True' 'https://ip7.d0a.io/self') =~ \"IsoCode\":\"([[:upper:]]{2})\" ]]
	local country_code=${BASH_REMATCH[1]}
	local mirrors
	: "${country_code:=CN}"

	local distfiles_xml="${TMP_DIR}/distfiles.xml"
	download "https://api.gentoo.org/mirrors/distfiles.xml" "$distfiles_xml"

	mirrors="$(_uris_from_xml "$country_code" "$distfiles_xml")"
	if [[ $mirrors == "" ]]; then
		country_code="CN" # fallback to CN
		mirrors="$(_uris_from_xml "$country_code" "$distfiles_xml")"
	fi
	set -e

	if [[ $country_code == "CN" ]]; then
		_D2G_GIT_MIRROR="https://mirrors.bfsu.edu.cn/git/gentoo-portage.git"
	fi

	local uri selected
	local -a mirrors_arr
	mapfile -t mirrors_arr <<<"$mirrors"

	_log i "Setting mirror url ..."
	_log n "mirror list in ${country_code}:"
	for (( i = 0; i < ${#mirrors_arr[@]}; ++i )); do
		uri=${mirrors_arr[i]}
		if [[ "${uri}" =~ ^https ]] && [[ -z ${MIRROR} ]]; then
			MIRROR="${uri}"
			_log n " -*-[${i}] ${uri}"
		else
			_log n "    [${i}] ${uri}"
		fi
	done
	mirrors_arr+=( "CUSTOM" )
	_log n "    [${i}] <Enter custom URL>"
	while [[ ${#mirrors_arr[@]} -gt 0 ]]; do
		read -r -p "Choose prefered mirror (enter the num, empty for default): " selected
		[[ -n ${selected} ]] || break
		if [[ ${selected} =~ ^[[:digit:]]+$ ]] && [[ -n ${mirrors_arr[${selected}]} ]]; then
			MIRROR=${mirrors_arr[${selected}]}
			break;
		else
			_log w "out of range!"
		fi
	done
	if [[ ${MIRROR} == CUSTOM ]]; then
		_set_custom_mirror() {
			read -r -p "Enter your custom URL: " MIRROR
			if [[ ! ${MIRROR} =~ ^(http[s]?|ftp):// ]]; then
				_log e "Please use http[s] or ftp URL."
				_set_custom_mirror
			fi
		}
		_set_custom_mirror
	fi
	if [[ -z ${MIRROR} ]]; then
		MIRROR="https://gentoo.osuosl.org/"
	fi
	_log i "Mirror has been set to '${MIRROR}'."
}

