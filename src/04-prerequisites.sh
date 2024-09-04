#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

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

