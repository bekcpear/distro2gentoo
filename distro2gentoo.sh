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

[[ -z ${_BASHFUNC_DO} ]] || return 0
_BASHFUNC_DO=1

if [[ -z ${_BASHFUNC_DO_OFD} ]]; then
	eval "exec {_BASHFUNC_DO_OFD}>&1"
fi

: "${_BASHFUNC_DO_DATE:=on}"
: "${_BASHFUNC_DO_DATE_FORMAT:=+[%Y-%m-%d %H:%M:%S] }"

_do() {
	local prefix
	if [[ ${1} == "-p" ]]; then
		shift
		prefix="${1}"
		shift
	fi

	[[ -n ${1} ]] || return 0

	local msg='\x1b[1m\x1b[32m'
	if [[ ${_BASHFUNC_DO_DATE} == "on" ]]; then
		msg+=$(date "${_BASHFUNC_DO_DATE_FORMAT}")
	fi
	msg+="${prefix}${prefix:+ }"
	msg+='>>>\x1b[0m '
	msg+="$*"
	eval ">&${_BASHFUNC_DO_OFD} echo -e \${msg}"
	"${@}"
}
[[ -z ${_BASHFUNC_LOG} ]] || return 0
_BASHFUNC_LOG=1

: "${_BASHFUNC_LOG_LEVEL:=info}"
: "${_BASHFUNC_LOG_OUT_FD:=1}"
: "${_BASHFUNC_LOG_ERR_FD:=2}"
: "${_BASHFUNC_LOG_DATE:=on}"
: "${_BASHFUNC_LOG_DATE_FORMAT:=+[%Y-%m-%d %H:%M:%S] }"
: "${_BASHFUNC_LOG_ECHO_FUNC:=echo}"

declare -A _BASHFUNC_LOG_LEVEL_INTERNAL=(
	[debug]=3
	[info]=2
	[normal]=1
	[warning]=0
	[error]=-1
)

_log() {
	: "${_BASHFUNC_LAST_EXIT:=$?}" # this should always at the first line of this function
	[[ -n ${2} ]] || return 0

	local lv=${_BASHFUNC_LOG_LEVEL_INTERNAL[${_BASHFUNC_LOG_LEVEL}]}
	local out='' fatal='' endfunc='' msg="" is_normal=0
	case ${1} in
		d)
			if [[ ${lv} -lt 3 ]]; then
				return 0
			fi
			out=${_BASHFUNC_LOG_OUT_FD}
			msg='\x1b[1m'
			;;
		i)
			if [[ ${lv} -lt 2 ]]; then
				return 0
			fi
			out=${_BASHFUNC_LOG_OUT_FD}
			;;
		n)
			if [[ ${lv} -lt 1 ]]; then
				return 0
			fi
			out=${_BASHFUNC_LOG_OUT_FD}
			msg='\x1b[36m'
			is_normal=1
			;;
		w)
			if [[ ${lv} -lt 0 ]]; then
				return 0
			fi
			out=${_BASHFUNC_LOG_ERR_FD}
			msg='\x1b[1m\x1b[33m'
			;;
		e)
			out=${_BASHFUNC_LOG_ERR_FD}
			msg='\x1b[1m\x1b[31m'
			;;
		ee)
			out=${_BASHFUNC_LOG_ERR_FD}
			msg='\x1b[1m\x1b[31m'
			fatal=${1}
			if declare -F "${2}" &>/dev/null; then
				endfunc=${2}
				shift
			fi
			;;
		*)
			echo "internal function error: _log, unexpected argument '$1'" >&2
			return 1
			;;
	esac
	shift

	if [[ ${_BASHFUNC_LOG_DATE} == "on" ]] && [[ $is_normal == 0 ]]; then
		msg+=$(date "${_BASHFUNC_LOG_DATE_FORMAT}")
	fi

	msg+="$*"
	msg+='\x1b[0m'
	eval ">&${out} ${_BASHFUNC_LOG_ECHO_FUNC} -e \"\${msg}\""

	if [[ ${fatal} == "ee" ]]; then
		if [[ ${_BASHFUNC_LAST_EXIT} == 0 ]]; then
			_BASHFUNC_LAST_EXIT=1
		fi
		${endfunc}
		exit "${_BASHFUNC_LAST_EXIT}"
	fi
}


printHelp() {
	echo "
Usage: distro2gentoo [<options>]

options:

	--disable-binhost       Disable the binhost when installing Gentoo
	-h, --help              Show this help
"
	exit "${1:-1}"
}

_gpg() {
	if [[ ! -d "${TMP_DIR}/gnupg_home" ]]; then
		_do mkdir -p "${TMP_DIR}/gnupg_home"
	fi
	export GNUPGHOME="${TMP_DIR}/gnupg_home"
	_do gpg --homedir "${TMP_DIR}/gnupg_home" "$@"
}

gpgDecryptAndOutput() {
	# $1: input file
	# $2: output file
	_log i "Decrypting file '$1' to '$2' ..."
	_gpg -o "$2" --decrypt "$1"
}

gpgVerifyDetachedFile() {
	# $1: input file
	# $2: input signature file
	_log i "Verifying file '$1' with signature file '$2' ..."
	_gpg --verify "$2" "$1"
}

firstTip() {
	echo
	_log n "    1. This script won't format disks,"
	_log n "    2. will remove all mounted data excepts /home, /root,"
	_log n "                                            kernels & modules"
	echo
	_log n "           *** BACKUP YOUR DATA!!! ***"
	echo
	_log n "  To avoid rebooting without privileges, make sure at least one interactive shell with root privileges is active."
	echo
	WAIT=5
	echo -en "Starting in: \e[33m\e[1m"
	while [[ ${WAIT} -gt 0 ]]; do
		echo -en "${WAIT} "
		WAIT=$((WAIT -  1))
		sleep 1
	done
	echo -e "\e[0m"
}


parseParams() {
	set +e
	unset GETOPT_COMPATIBLE
	getopt -T
	if [[ ${?} != 4 ]]; then
		_log ee "The Linux version of command 'getopt' is necessory to parse parameters."
	fi
	local _args
	if ! _args=$(getopt -o 'h' -l 'disable-binhost,help' -n 'distro2gentoo' -- "$@"); then
		printHelp 1
	fi
	set -e

	# parse arguments
	eval "set -- ${_args}"
	while true; do
		case "${1}" in
			--disable-binhost)
				BINHOST_ENABLED=0
				shift
				;;
			-h|--help)
				printHelp 0
				;;
			--)
				shift
				break
				;;
			*)
				_log ee printHelp "unknow error"
				;;
		esac
	done
}


_D2G_DOWNLOAD_CMD=("curl" "--retry" "3" "--connect-timeout" "60" "-Lfo")
_D2G_DOWNLOAD_CMD_RESUME=("curl" "-C" "-" "--retry" "3" "--connect-timeout" "60" "-Lfo")
_D2G_DOWNLOAD_CMD_QUIET=("curl" "--retry" "1" "--connect-timeout" "60" "-sfL")
if command -v curl >/dev/null; then
	:
elif command -v wget >/dev/null; then
	_D2G_DOWNLOAD_CMD=("wget" "-t" "3" "-T" "60" "-O")
	_D2G_DOWNLOAD_CMD_RESUME=("wget" "-c" "-t" "3" "-T" "60" "-O")
	_D2G_DOWNLOAD_CMD_QUIET=("wget" "-t" "1" "-T" "60" "-qO" "-")
else
	NECESSARY_CMDS+=("curl")
fi

downloadCat() {
	if [[ $1 == '-H' ]]; then
		local header="$2"
		shift 2
	fi
	_do "${_D2G_DOWNLOAD_CMD_QUIET[@]}" ${header:+--header} "${header}" "$1"
}

download() {
	# $1: remote url
	# $2: output file

	local isForce=0 _done=0
	if [[ ${FUNCNAME[1]} == "downloadForce" ]]; then
		isForce=1
	fi

	if [[ $isForce == 0 ]] && [[ -f "$2" ]]; then
		_log i "Resuming '$2' (url: '$1') ..."
		if _do "${_D2G_DOWNLOAD_CMD_RESUME[@]}" "$2" "$1"; then
			_done=1
		fi
	fi

	if [[ $_done == 0 ]]; then
		_log i "Downloading '$1' ..."
		_do "${_D2G_DOWNLOAD_CMD[@]}" "$2" "$1"
	fi
}

downloadForce() {
	download "$@"
}


NECESSARY_CMDS+=("awk" "bc" "findmnt" "git" "gpg" "ip" "openssl" "sort" "tr" "wc" "xmllint" "xz")

declare -A -g _D2G_PKG_awk
_D2G_PKG_awk[apt]="gawk"
_D2G_PKG_awk[dnf]="gawk"
_D2G_PKG_awk[opkg]="gawk"
_D2G_PKG_awk[pacman]="gawk"
_D2G_PKG_awk[urpmi]="gawk"
_D2G_PKG_awk[yum]="gawk"
_D2G_PKG_awk[zypper]="gawk"
_D2G_PKG_awk[xbps-install]="gawk"

declare -A -g _D2G_PKG_bc
_D2G_PKG_bc[apt]="bc"
_D2G_PKG_bc[dnf]="bc"
_D2G_PKG_bc[opkg]="bc"
_D2G_PKG_bc[pacman]="bc"
_D2G_PKG_bc[urpmi]="bc"
_D2G_PKG_bc[yum]="bc"
_D2G_PKG_bc[zypper]="bc"
_D2G_PKG_bc[xbps-install]="bc"

declare -A -g _D2G_PKG_efibootmgr
_D2G_PKG_efibootmgr[apt]="efibootmgr"
_D2G_PKG_efibootmgr[dnf]="efibootmgr"
_D2G_PKG_efibootmgr[opkg]="efibootmgr"
_D2G_PKG_efibootmgr[pacman]="efibootmgr"
_D2G_PKG_efibootmgr[urpmi]="efibootmgr"
_D2G_PKG_efibootmgr[yum]="efibootmgr"
_D2G_PKG_efibootmgr[zypper]="efibootmgr"
_D2G_PKG_efibootmgr[xbps-install]="efibootmgr"

declare -A -g _D2G_PKG_findmnt
_D2G_PKG_findmnt[apt]="util-linux"
_D2G_PKG_findmnt[dnf]="util-linux"
_D2G_PKG_findmnt[opkg]="util-linux"
_D2G_PKG_findmnt[pacman]="util-linux"
_D2G_PKG_findmnt[urpmi]="util-linux"
_D2G_PKG_findmnt[yum]="util-linux"
_D2G_PKG_findmnt[zypper]="util-linux"
_D2G_PKG_findmnt[xbps-install]="util-linux"

declare -A -g _D2G_PKG_git
_D2G_PKG_git[apt]="git"
_D2G_PKG_git[dnf]="git"
_D2G_PKG_git[opkg]="git"
_D2G_PKG_git[pacman]="git"
_D2G_PKG_git[urpmi]="git"
_D2G_PKG_git[yum]="git"
_D2G_PKG_git[zypper]="git"
_D2G_PKG_git[xbps-install]="git"

declare -A -g _D2G_PKG_gpg
_D2G_PKG_gpg[apt]="gnupg"
_D2G_PKG_gpg[dnf]="gnupg2"
_D2G_PKG_gpg[opkg]="gnupg"
_D2G_PKG_gpg[pacman]="gnupg"
_D2G_PKG_gpg[urpmi]="gnupg2"
_D2G_PKG_gpg[yum]="gnupg2"
_D2G_PKG_gpg[zypper]="gpg2"
_D2G_PKG_gpg[xbps-install]="gnupg"

declare -A -g _D2G_PKG_ip
_D2G_PKG_ip[apt]="iproute2"
_D2G_PKG_ip[dnf]="iproute"
_D2G_PKG_ip[opkg]="ip"
_D2G_PKG_ip[pacman]="iproute2"
_D2G_PKG_ip[urpmi]="iproute2"
_D2G_PKG_ip[yum]="iproute"
_D2G_PKG_ip[zypper]="iproute2"
_D2G_PKG_ip[xbps-install]="iproute2"

declare -A -g _D2G_PKG_openssl
_D2G_PKG_openssl[apt]="openssl"
_D2G_PKG_openssl[dnf]="openssl"
_D2G_PKG_openssl[opkg]="openssl"
_D2G_PKG_openssl[pacman]="openssl"
_D2G_PKG_openssl[urpmi]="openssl"
_D2G_PKG_openssl[yum]="openssl"
_D2G_PKG_openssl[zypper]="openssl"
_D2G_PKG_openssl[xbps-install]="openssl"

declare -A -g _D2G_PKG_sort
_D2G_PKG_sort[apt]="coreutils"
_D2G_PKG_sort[dnf]="coreutils"
_D2G_PKG_sort[opkg]="coreutils"
_D2G_PKG_sort[pacman]="coreutils"
_D2G_PKG_sort[urpmi]="coreutils"
_D2G_PKG_sort[yum]="coreutils"
_D2G_PKG_sort[zypper]="coreutils"
_D2G_PKG_sort[xbps-install]="coreutils"

declare -A -g _D2G_PKG_tr
_D2G_PKG_tr[apt]="coreutils"
_D2G_PKG_tr[dnf]="coreutils"
_D2G_PKG_tr[opkg]="coreutils"
_D2G_PKG_tr[pacman]="coreutils"
_D2G_PKG_tr[urpmi]="coreutils"
_D2G_PKG_tr[yum]="coreutils"
_D2G_PKG_tr[zypper]="coreutils"
_D2G_PKG_tr[xbps-install]="coreutils"

declare -A -g _D2G_PKG_wc
_D2G_PKG_wc[apt]="coreutils"
_D2G_PKG_wc[dnf]="coreutils"
_D2G_PKG_wc[opkg]="coreutils"
_D2G_PKG_wc[pacman]="coreutils"
_D2G_PKG_wc[urpmi]="coreutils"
_D2G_PKG_wc[yum]="coreutils"
_D2G_PKG_wc[zypper]="coreutils"
_D2G_PKG_wc[xbps-install]="coreutils"

declare -A -g _D2G_PKG_xmllint
_D2G_PKG_xmllint[apt]="libxml2-utils"
_D2G_PKG_xmllint[dnf]="libxml2"
_D2G_PKG_xmllint[pacman]="libxml2"
_D2G_PKG_xmllint[zypper]="libxml2-tools"
_D2G_PKG_xmllint[urpmi]="lib64xml2"
_D2G_PKG_xmllint[opkg]="libxml2"
_D2G_PKG_xmllint[xbps-install]="libxml2"

declare -A -g _D2G_PKG_curl
_D2G_PKG_curl[apt]="curl"
_D2G_PKG_curl[dnf]="curl"
_D2G_PKG_curl[pacman]="curl"
_D2G_PKG_curl[zypper]="curl"
_D2G_PKG_curl[urpmi]="curl"
_D2G_PKG_curl[opkg]="curl"
_D2G_PKG_curl[xbps-install]="curl"

declare -A -g _D2G_PKG_xz
_D2G_PKG_xz[apt]="xz-utils"
_D2G_PKG_xz[dnf]="xz"
_D2G_PKG_xz[pacman]="xz"
_D2G_PKG_xz[zypper]="xz"
_D2G_PKG_xz[urpmi]="xz"
_D2G_PKG_xz[opkg]="xz"
_D2G_PKG_xz[xbps-install]="xz"

declare -A -g _D2G_PKG_cacerts
_D2G_PKG_cacerts[apt]="ca-certificates"
_D2G_PKG_cacerts[dnf]="ca-certificates"
_D2G_PKG_cacerts[pacman]="ca-certificates"
_D2G_PKG_cacerts[zypper]="ca-certificates"
_D2G_PKG_cacerts[urpmi]="rootcerts"
_D2G_PKG_cacerts[opkg]="ca-certificates"
_D2G_PKG_cacerts[xbps-install]="ca-certificates"

_D2G_PKG_DB_Updated=0

_install_pkg() {
	local -i ret=0
	local cmd_key="$1"
	if command -v apt >/dev/null; then
		if (( _D2G_PKG_DB_Updated == 0 )); then
			apt-get update
			_D2G_PKG_DB_Updated=1
		fi
		eval "apt -y install \${_D2G_PKG_${cmd_key}[apt]}" || ret=$?
	elif command -v dnf >/dev/null; then
		eval "dnf -y install \${_D2G_PKG_${cmd_key}[dnf]}" || ret=$?
	elif command -v yum >/dev/null; then
		eval "yum -y install \${_D2G_PKG_${cmd_key}[yum]}" || ret=$?
	elif command -v pacman >/dev/null; then
		if (( _D2G_PKG_DB_Updated == 0 )); then
			pacman -Syy
			_D2G_PKG_DB_Updated=1
		fi
		eval "pacman --noconfirm -S \${_D2G_PKG_${cmd_key}[pacman]}" || ret=$?
	elif command -v zypper >/dev/null; then # SUSE
		eval "zypper install -y \${_D2G_PKG_${cmd_key}[zypper]}" || ret=$?
	elif command -v urpmi >/dev/null; then # Mageia
		eval "urpmi --force \${_D2G_PKG_${cmd_key}[urpmi]}" || ret=$?
	elif command -v opkg >/dev/null; then # OpenWRT
		eval "opkg install \${_D2G_PKG_${cmd_key}[opkg]}" || ret=$?
	elif command -v xbps-install >/dev/null; then # Void Linux
		eval "xbps-install -y \${_D2G_PKG_${cmd_key}[xbps-install]}" || ret=$?
	else
		ret=1
	fi
	return $ret
}

_installDeps() {
	_log i "Updating ca-certificates ..."
	_install_pkg cacerts || true

	_log i "Make sure commands '${NECESSARY_CMDS[*]}' are available."
	for cmd_key in "${NECESSARY_CMDS[@]}"; do
		if ! command -v "${cmd_key}" >/dev/null; then
			if ! _install_pkg "${cmd_key}"; then
				_fatal "Command '${cmd_key}' was not found and the installation failed!"
			fi
		fi
	done
}

_installGPGKeys() {
	# https://www.gentoo.org/downloads/signatures/
	download "https://qa-reports.gentoo.org/output/service-keys.gpg" "${TMP_DIR}/service-keys.gpg"
	_gpg --import "${TMP_DIR}/service-keys.gpg"
}

prerequisitesCheck() {
	local res=000

	# check root
	[[ ${EUID} == 0 ]] || res=1${res:1}

	# check cpu arch (only tested for amd64/arm64 now)
	[[ ${CPUARCH} =~ ^amd64|arm64$ ]] || res=${res:0:1}1${res:2}

	# check newroot dir
	[[ -L ${NEWROOT} || -e ${NEWROOT} ]] && res=${res:0:2}1 || true

	case ${res} in
		1*)
			_log e "Please run this shell as the root user!"
			;;&
		?1?)
			_log e "This script only tested for amd64/arm64 arch now!"
			;;&
		*1)
			_log e "New root path '${NEWROOT}' exists"
			_log e "**umount** it's subdirs and remove it first."
			_log e "  # umount -R ${NEWROOT}/*"
			_log e "  # rm -r ${NEWROOT}"
			;;
	esac
	if [[ ${res} != 000 ]]; then
		_log ee "Abort it!"
	fi

	# check bios/efi
	if [[ -e /sys/firmware/efi ]]; then
		EFI_ENABLED=1
		NECESSARY_CMDS+=( "efibootmgr" )
	fi

	# check iSCSI
	# TODO

	# check filesystem
	# TODO
}

prerequisitesSolve() {
	# installing necessary pkgs
	_installDeps

	# prepare GnuPG Keys
	_installGPGKeys
}


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


getStage3() {
	_log i "Getting stage3 tarball ..."

	local stage3_list_url="${MIRROR%/}/releases/${CPUARCH}/autobuilds/latest-stage3.txt"
	local local_stage3_list="${TMP_DIR}/latest-stage3.txt"
	local relative_path stage3_size selected_stage3 selected_stage3_tmp
	local -a stage3s_names stage3s_paths stage3s_sizes

	_log i "Getting stage3 tarball list ..."

	download "$stage3_list_url" "${local_stage3_list}.with-gpg-signature"
	gpgDecryptAndOutput "${local_stage3_list}.with-gpg-signature" "$local_stage3_list"

	while read -r relative_path stage3_size _; do
		if [[ $relative_path =~ ^[[:space:]]*#|^[[:space:]]*$ ]]; then
			continue
		fi
		stage3s_names+=( "${relative_path##*/}" )
		stage3s_paths+=( "$relative_path" )
		stage3s_sizes+=( "$stage3_size" )
	done <"$local_stage3_list"

	_log n "stage3 list:"
	for (( i=0; i < ${#stage3s_names[@]}; ++i )); do
		local _stage=${stage3s_names[i]}
		if [[ ! ${_stage} =~ ^stage3 ]]; then
			# don't unset these until the problem of index 'i' solved
			#unset 'stage3s_names[i]' 'stage3s_paths[i]' 'stage3s_sizes[i]'
			continue
		fi

		# default to openrc
		if [[ ${_stage} =~ ^stage3-amd64-openrc-2|stage3-arm64-openrc-2 ]]; then
			selected_stage3=${i}
			_log n " -*- [${i}] ${_stage}"
		else
			_log n "     [${i}] ${_stage}"
		fi
	done

	if (( ${#stage3s_names[@]} < 1 )); then
		_log ee "No stage3 list, please check the mirror URL or your network."
	fi

	while :; do
		read -r -p "Choose prefered stage3 tarball (enter the num, empty for the default): " selected_stage3_tmp
		if [[ -z ${selected_stage3_tmp} ]]; then
			if [[ $selected_stage3 == "" || -z $selected_stage3 ]]; then
				_log e "No default stage3 selected, please select one!"
			else
				_log i "Use the default stage3."
				break
			fi
		fi
		if [[ ${selected_stage3_tmp} =~ ^[[:digit:]]+$ ]] && [[ -n ${stage3s_names[${selected_stage3_tmp}]} ]]; then
			selected_stage3=${selected_stage3_tmp}
			break;
		else
			_log e "Out of range, please select a valid one!"
		fi
	done

	_log i "selected stage3: ${stage3s_names[${selected_stage3}]}"

	# prepare signature
	local stage3_asc="/${stage3s_names[${selected_stage3}]}.asc"
	downloadForce "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}.asc" "$stage3_asc"

	# prepare stage3 tarball
	STAGE3_TARBALL="/${stage3s_names[${selected_stage3}]}"
	local stage3_tarball_exists
	if [[ -f $STAGE3_TARBALL ]]; then
		if gpgVerifyDetachedFile "$STAGE3_TARBALL" "$stage3_asc"; then
			stage3_tarball_exists=1
		fi
	fi
	if [[ $stage3_tarball_exists != 1 ]]; then
		download "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}" "$STAGE3_TARBALL"

		# verify stage3 tarball and download again if doesn't match
		local tries=1
		while ! gpgVerifyDetachedFile "$STAGE3_TARBALL" "$stage3_asc"; do
			downloadForce "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}" "$STAGE3_TARBALL"
			tries=$((tries + 1))
			if (( tries > 3 )); then
				_log ee "The downloaded stage3 tarball '$STAGE3_TARBALL' doesn't match its asc file, abort!"
			fi
		done
	fi
	_log i "Stage3 tarball has been stored as '$STAGE3_TARBALL'."
}

unpackStage3ToNEWROOT() {
	pushd "$NEWROOT" || _log ee "Pushd '$NEWROOT' failed!"

	_log w "Untaring stage3 tarball ..."
	_log w ">>> tar xpf \"$STAGE3_TARBALL\" --xattrs-include='*.*' --numeric-owner"
	tar xpf "$STAGE3_TARBALL" --xattrs-include='*.*' --numeric-owner

	popd || _log ee "Popd from '$NEWROOT' failed!"
}


declare -a _D2G_FS_SOURCES _D2G_FS_MOUNTPOINTS _D2G_FS_TYPES _D2G_FS_OPTS

_D2G_LVM_ENABLED=0
declare -a _D2G_LVM_LVS _D2G_LVM_LVS_MOUNTPOINTS

_D2G_LUKS_ENABLED=0
declare -a _D2G_LUKS_PARTS _D2G_LUKS_PARTS_MOUNTPOINTS _D2G_LUKS_PARTS_PARENTS

_D2G_BTRFS_ENABLED=0
_D2G_BTRFS_SUBVOL_ROOTFS=""
declare -a _D2G_BTRFS_MOUNTPOINTS _D2G_BTRFS_SUBVOLS _D2G_BTRFS_OPTS


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


declare -a _D2G_DRACUT_MODULES _D2G_ONETIME_PKGS _D2G_EXTRA_DEPS

_D2G_BINPKGS_PROFILE_VER="23.0"

_D2G_BINPKGS_CATEGORIES_AMD64_DEFAULT=1
_D2G_BINPKGS_CATEGORIES_AMD64=(
	"x32"
	"x86-64"
	"x86-64-v3"
	"x86-64_hardened"
	"x86-64_llvm"
	"x86-64_musl"
	"x86-64_musl_hardened"
	"x86-64_musl_llvm"
)

_D2G_BINPKGS_CATEGORIES_ARM64_DEFAULT=1
_D2G_BINPKGS_CATEGORIES_ARM64=(
	"aarch64_be"
	"arm64"
	"arm64_llvm"
	"arm64_musl"
	"arm64_musl_hardened"
	"arm64_musl_llvm"
)

_the_best_matched_binpkgs_category() {
	local default_index matched_index='' i stage3_category="${STAGE3_TARBALL#*stage3-}" x86_64_v3_supported=0
	local -a categories
	stage3_category="${stage3_category//-/_}"
	case "$CPUARCH" in
		amd64)
			stage3_category="${stage3_category/#amd64/x86-64}"
			categories=("${_D2G_BINPKGS_CATEGORIES_AMD64[@]}")
			default_index="$_D2G_BINPKGS_CATEGORIES_AMD64_DEFAULT"
			if ld.so --help | grep 'x86-64-v3' | grep 'supported' >/dev/null; then
				x86_64_v3_supported=1
			fi
			;;
		arm64)
			categories=("${_D2G_BINPKGS_CATEGORIES_ARM64[@]}")
			default_index="$_D2G_BINPKGS_CATEGORIES_ARM64_DEFAULT"
			;;
	esac
	for ((i=0; i<${#categories[@]}; i++)); do
		if [[ $stage3_category == ${categories[i]}* ]]; then
			matched_index="$i"
		fi
	done
	if [[ $matched_index == '' ]]; then
		matched_index="$default_index"
	fi

	# THIS IS A SPECIFIC CONDITION, PLEASE UPDATE IT CAREFULLY
	if [[ $x86_64_v3_supported == 1 && $CPUARCH == "amd64" && $matched_index == 1 ]]; then
		matched_index=2
	fi

	echo -n "${categories[$matched_index]}"
}

preparePkgsConfiguration() {
	if [[ ! ${STAGE3_TARBALL} =~ systemd ]]; then
		_D2G_EXTRA_DEPS+=("net-misc/netifrc")
	fi

	if [[ ${_D2G_LUKS_ENABLED} == 1 ]]; then
		if [[ $STAGE3_TARBALL =~ systemd ]]; then
			echo 'sys-apps/systemd cryptsetup' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
			_D2G_ONETIME_PKGS+=("sys-apps/systemd")
		fi
		_D2G_DRACUT_MODULES+=("crypt")
		echo 'sys-fs/cryptsetup -static-libs' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
		_D2G_EXTRA_DEPS+=("sys-fs/cryptsetup")
	fi
	if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
		cp -aL /etc/lvm "${NEWROOT}/etc/"
		_D2G_DRACUT_MODULES+=("lvm")
		_D2G_EXTRA_DEPS+=("sys-fs/lvm2")
	fi
	if [[ ${_D2G_BTRFS_ENABLED} == 1 ]]; then
		_D2G_DRACUT_MODULES+=("btrfs")
		_D2G_EXTRA_DEPS+=("sys-fs/btrfs-progs")
	fi
	if [[ ${BINHOST_ENABLED} == 1 ]]; then
		local _binhost_sync_uri
		_binhost_sync_uri="${MIRROR%/}/releases/${CPUARCH}/binpackages/${_D2G_BINPKGS_PROFILE_VER}/$(_the_best_matched_binpkgs_category)/"
		echo "[binhost]
priority = 9999
sync-uri = ${_binhost_sync_uri}
" >"${NEWROOT}/etc/portage/binrepos.conf/gentoobinhost.conf"
		_log w "The binhost sync-uri is set to '${_binhost_sync_uri}'"
		_D2G_BINHOST_ARGS=("--binpkg-changed-deps=y" "--getbinpkg=y" "--usepkg-exclude" "acct-*/* sys-kernel/* virtual/* */*-bin")
		_chroot_exec getuto
		# "--binpkg-respect-use=y" will override "--autounmask-use=y"
		# refs: https://bitbili.net/gentoo-linux-installation-and-usage-tutorial.html#emerge+默认选项
	fi
}

installPortageDB() {
	pushd "${NEWROOT}/var/db/repos" || _log ee "Pushd to '${NEWROOT}/var/db/repos' failed!"
	_do git clone --depth 1 "$_D2G_GIT_MIRROR" gentoo
	local commit result ret=0
	commit=$(_do git -C gentoo rev-list HEAD)
	result=$(_do git -C gentoo verify-commit --raw "$commit" 2>&1) || ret=$?
	if [[ $ret != 0 ]]; then
		_log e "Git repo verification failed!"
		_do git -C gentoo --no-pager log -1 --pretty=fuller "$commit"
		echo "${result}"
		if grep "\\[GNUPG:\\] EXPKEYSIG" <<< "$result"; then
			_log w "... but expired keys are alright..."
			ret=0
		else
			_do rm -rf gentoo
			_log e "Try emerge-webrsync instead."
			_chroot_exec emerge-webrsync
		fi
	fi
	popd || _log ee "Popd from '${NEWROOT}/var/db/repos' failed!"

	if (( ret == 0 )); then
		_chroot_exec chown -R portage:portage /var/db/repos/gentoo
		mkdir -p "${NEWROOT}/etc/portage/repos.conf"
		echo "[gentoo]
location   = /var/db/repos/gentoo
auto-sync  = yes
sync-type  = git
sync-depth = 1
sync-uri   = $_D2G_GIT_MIRROR
sync-git-verify-commit-signature = yes
" >"${NEWROOT}/etc/portage/repos.conf/gentoo.conf"
		_chroot_exec chown -R root:root "/etc/portage/repos.conf"
		_D2G_EXTRA_DEPS+=( "dev-vcs/git" )
	fi
}

installNecessaryPkgs() {
	local _nproc emerge_opts=("--autounmask=y" "--autounmask-license=y" "--autounmask-use=y" "--autounmask-write=y" "--autounmask-continue=y" "-vj")
	_nproc=$(nproc)

	if (( ${#_D2G_ONETIME_PKGS[@]} > 0 )); then
		_chroot_exec env DONT_MOUNT_BOOT=1 emerge -l "$_nproc" -1 "${emerge_opts[@]}" "${_D2G_BINHOST_ARGS[@]}" "${_D2G_ONETIME_PKGS[@]}"
	fi

	# install necessary pkgs
	mkdir -p "${NEWROOT}/etc/portage/package.license"
	echo 'sys-kernel/linux-firmware linux-fw-redistributable no-source-code' \
		>"${NEWROOT}/etc/portage/package.license/linux-firmware"
	echo 'sys-boot/grub mount' >>"${NEWROOT}/etc/portage/package.use/bootloader"
	_chroot_exec env DONT_MOUNT_BOOT=1 emerge -l "$_nproc" -n "${emerge_opts[@]}" "${_D2G_BINHOST_ARGS[@]}" \
		linux-firmware gentoo-kernel-bin sys-boot/grub sys-boot/os-prober net-misc/openssh "${_D2G_EXTRA_DEPS[@]}"

	# regenerate initramfs
	if (( ${#_D2G_DRACUT_MODULES[@]} > 0 )); then
		mkdir -p "${NEWROOT}/etc/dracut.conf.d"
		echo "add_dracutmodules+=\"${_D2G_DRACUT_MODULES[*]} \"" >>"${NEWROOT}/etc/dracut.conf.d/distro2gentoo.conf"
		_chroot_exec env DONT_MOUNT_BOOT=1 emerge --config sys-kernel/gentoo-kernel-bin
	fi
}


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


parseParams "$@"

prerequisitesCheck
firstTip

mkdir -p "${NEWROOT}"
prerequisitesSolve

setupMirror

getStage3
unpackStage3ToNEWROOT

prepareChroot

setupGRUBCmdline

preparePkgsConfiguration
installPortageDB
installNecessaryPkgs

_config_gentoo() {
	local fileForPermitRootLogin fileForAuthorizedKeysFile fileForPasswordAuthentication
	local patForPermitRootLogin='^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]][[:alpha:]-]+$'
	local patForAuthorizedKeysFile='^[[:space:]]*#?[[:space:]]*AuthorizedKeysFile[[:space:]][[:alnum:]\./_-]+$'
	local patForPasswordAuthentication='^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]][[:alpha:]-]+$'

	__file_for() {
		local _line
		if _line=$(grep -r -E "$1" "${NEWROOT}/etc/ssh/sshd_config.d/"); then
			echo "$_line" | cut -d':' -f1 | tail -1
		elif grep -E "$1" "$NEWROOT/etc/ssh/sshd_config" &>/dev/null; then
			echo "$NEWROOT/etc/ssh/sshd_config"
		else
			echo -n ""
		fi
	}

	local var
	for var in PermitRootLogin AuthorizedKeysFile PasswordAuthentication; do
		local fileFor="fileFor${var}" patFor="patFor${var}"
		eval "${fileFor}='$(__file_for "${!patFor}")'"
		local replaced_str="${var} yes"
		if [[ $var == "AuthorizedKeysFile" ]]; then
			replaced_str="${var} .ssh/authorized_keys"
		fi
		if [[ ${!fileFor} != "" ]]; then
			sed -Ei "/${!patFor}/s@${!patFor}@${replaced_str}@" "${!fileFor}"
		else
			echo $'\n'"$replaced_str" >>"${NEWROOT}/etc/ssh/sshd_config"
		fi
	done

	configNetwork

	if [[ $STAGE3_TARBALL =~ systemd ]]; then
		_chroot_exec systemctl enable sshd.service

		if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
			_chroot_exec systemctl enable lvm2-monitor.service
		fi
	else
		_chroot_exec rc-update add sshd default

		if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
			_chroot_exec rc-update add lvm boot
		fi
	fi

	
	# remove the extra "command" opts from root user's authorized_keys
	# some distributions set "exit" in the "command" opts
	sed -Ei 's#(^|,)command=.*[[:space:]](sk-ecdsa-sha2-nistp256@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|ssh-ed25519|ssh-dss|ssh-rsa)# \2#' /root/.ssh/authorized_keys
	sed -Ei 's#^ ##' /root/.ssh/authorized_keys

	_chroot_exec touch /etc/machine-id
}
_config_gentoo


_LD_SO=$(ls -d "$NEWROOT"/lib64/ld-linux-*.so*)
if [[ ! -x ${_LD_SO} ]] || [[ $(${_LD_SO} --version | head -1 | cut -d' ' -f1) != "ld.so" ]]; then
	_log ee "cannot find ld.so from ${NEWROOT}/lib64/ld-linux-*.so*"
fi

WAIT=5
echo
echo
_log w "Following actions will affect the real system."
echo -en "Starting in: \e[33m\e[1m"
while [[ ${WAIT} -gt 0 ]]; do
	echo -en "${WAIT} "
	WAIT=$((${WAIT} -  1))
	sleep 1
done
echo -e "\e[0m"

_log w "Installing Grub ..."
installGRUB
sync

if [[ ${_D2G_BTRFS_ENABLED} == 1 ]]; then
	prepareBtrfsStuffs
fi

_log w "Deleting old system files ..."
set -x
${_LD_SO} --library-path "${NEWROOT}/lib64" "${NEWROOT}/usr/bin/find" / \( ! -path '/' \
	-and ! -regex '/boot.*' \
	-and ! -regex '/dev.*' \
	-and ! -regex '/home.*' \
	-and ! -regex '/proc.*' \
	-and ! -regex '/root.*' \
	-and ! -regex '/run.*' \
	-and ! -regex '/selinux.*' \
	-and ! -regex '/snap.*' \
	-and ! -regex '/sys.*' \
	-and ! -regex '/tmp.*' \
	$_D2G_EXCLUDED_READONLY_SUBVOL_PATH_OPTS \
	-and ! -regex "${EFIMNT:-/4f49e86d-275b-4766-94a9-8ea680d5e2de}.*" \
	-and ! -regex "${NEWROOT}.*" \) \
	-delete || true
set +x

${_LD_SO} --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/ls" -l / || true

_magic_cp() {
	echo ">>> Merging /${1} ..."
	set -- "$_LD_SO" --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/cp" -a "${NEWROOT}/${1}" /
	echo ">>>" "${@}"
	"${@}" || true
}
_magic_cp bin
_magic_cp sbin
_magic_cp etc
_magic_cp lib
_magic_cp lib64
_magic_cp usr
_magic_cp var

. /etc/profile
sync

_D2G_ALL_UMOUNTED=1
_umount_fs() {
	local tries=3
	__umount() {
		if findmnt "${NEWROOT}${1}" >/dev/null; then
			_log i "umounting ${NEWROOT}${1} ..."
			umount -Rf "${NEWROOT}${1}"
		else
			_log i "${NEWROOT}/${1} is already umounted."
		fi
	}
	while ! __umount "$1"; do
		if (( tries < 1 )); then
			_log e "umount '${NEWROOT}${1}' failed!"
			_D2G_ALL_UMOUNTED=0
			break
		fi
		tries=$((tries - 1))

		_log w "terminating processes that are opening files in '${NEWROOT}${1}' ..."
		local _user _pid _access _cmd
		while read -r _user _pid _access _cmd; do
			if [[ $_access =~ ^[F|f] ]]; then
				if [[ $_pid =~ ^[[:digit:]]+$ ]] && (( _pid > 50 )); then
					_log w "terminating $_pid ..."
					kill -SIGTERM "$_pid"
				fi
			fi
		done <<<"$(fuser -vm "${NEWROOT}${1}" 2>&1)"

		_log w "umounting ${NEWROOT}${1} again after 3 seconds ..."
		sleep 3
	done
}
_umount_fs /proc
_umount_fs /dev
_umount_fs /sys
_umount_fs /run
_umount_fs /boot
if [[ -n $EFIMNT ]]; then
	_umount_fs "$EFIMNT"
fi
if [[ $_D2G_ALL_UMOUNTED == 1 ]]; then
	_log i "removing ${NEWROOT} ..."
	rm -rf "$NEWROOT" || true
fi

ConfigureGRUB || true

_log i "Syncing ..."
sync
_log w "Finished!"
echo
echo
(
	. /etc/default/grub
	_log n "        GRUB_CMDLINE_LINUX: '${GRUB_CMDLINE_LINUX}'"
	_log n "GRUB_CMDLINE_LINUX_DEFAULT: '${GRUB_CMDLINE_LINUX_DEFAULT}'"
)
_log w "Unparsed         GRUB_CMDLINE_LINUX: '${D2G_UNUNIFIED_GRUB_CMDLINE_LINUX/#[[:space:]]/}'"
_log w "Unparsed GRUB_CMDLINE_LINUX_DEFAULT: '${D2G_UNUNIFIED_GRUB_CMDLINE_LINUX_DEFAULT/#[[:space:]]/}'"
_log w "The initramfs is generated by dracut by default, please check these opts."
echo
_log n "  1. Normal users (if exist) have been dropped (but /home directories is preserved)."
echo
_log n "  2. Old kernels and modules are preserved but are not used by default."
echo
_log n "  3. 'root' user password is preserved or set to 'distro2gentoo' if it's not set."
echo
_log n "  4. the /root directory is also preserved (please check the /root/.ssh/authorized_keys file)."
echo
_log n "  5. SSH server is enabled and will be listening on port 22,"
_log n "     it can be connected by root user with password authentication."
echo
_log n "  run:"
_log n "    # . /etc/profile"
_log n "  to enter the new environment."
echo
_log n "  reboot:"
_log n "    # reboot -f"
_log n "    or"
_log n "    # echo b >/proc/sysrq-trigger"
_log n "  and Enjoy Gentoo!"
echo
if [[ $_D2G_ALL_UMOUNTED == 0 ]]; then
	_log w "You should delete the '$NEWROOT' after reboot manually due to some mountpoints cannot be umounted!"
	echo
fi
if [[ $GRUB_CONFIGURED == 0 ]]; then
	_log e "!!!!!!!!!!!!!!!"
	_log e "The GRUB bootloader configuration failed!"
	_log e "You should install a bootloader manually!"
	_log e "!!!!!!!!!!!!!!!"
	echo
fi

WAIT=30
_log n "wait to guarantee data synced for some file systems/special environment ..."
_log n "  (CTRL-C is safe in most cases)"
while [[ $WAIT -ge 0 ]]; do
	echo -en "\e[G\e[K  $WAIT "
	WAIT=$((WAIT -  1))
	sleep 1
done
echo

