#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

NECESSARY_CMDS+=("awk" "bc" "findmnt" "git" "gpg" "ip" "openssl" "sort" "tr" "wc" "xmllint" "xz")

# supported package managers, in detection order
_D2G_PMS=(apt dnf yum pacman zypper urpmi opkg xbps-install)

# Exceptions to the default rule "package name == command key",
# keyed by '<command>:<package-manager>'.
declare -A -g _D2G_PKG=(
	# awk is provided by gawk everywhere
	[awk:apt]=gawk [awk:dnf]=gawk [awk:yum]=gawk [awk:pacman]=gawk
	[awk:zypper]=gawk [awk:urpmi]=gawk [awk:opkg]=gawk [awk:xbps-install]=gawk

	# findmnt belongs to util-linux
	[findmnt:apt]=util-linux [findmnt:dnf]=util-linux [findmnt:yum]=util-linux
	[findmnt:pacman]=util-linux [findmnt:zypper]=util-linux [findmnt:urpmi]=util-linux
	[findmnt:opkg]=util-linux [findmnt:xbps-install]=util-linux

	# sort/tr/wc belong to coreutils
	[sort:apt]=coreutils [sort:dnf]=coreutils [sort:yum]=coreutils [sort:pacman]=coreutils
	[sort:zypper]=coreutils [sort:urpmi]=coreutils [sort:opkg]=coreutils
	[sort:xbps-install]=coreutils
	[tr:apt]=coreutils [tr:dnf]=coreutils [tr:yum]=coreutils [tr:pacman]=coreutils
	[tr:zypper]=coreutils [tr:urpmi]=coreutils [tr:opkg]=coreutils [tr:xbps-install]=coreutils
	[wc:apt]=coreutils [wc:dnf]=coreutils [wc:yum]=coreutils [wc:pacman]=coreutils
	[wc:zypper]=coreutils [wc:urpmi]=coreutils [wc:opkg]=coreutils [wc:xbps-install]=coreutils

	# gpg
	[gpg:apt]=gnupg [gpg:dnf]=gnupg2 [gpg:yum]=gnupg2 [gpg:pacman]=gnupg
	[gpg:zypper]=gpg2 [gpg:urpmi]=gnupg2 [gpg:opkg]=gnupg [gpg:xbps-install]=gnupg

	# ip
	[ip:apt]=iproute2 [ip:dnf]=iproute [ip:yum]=iproute [ip:pacman]=iproute2
	[ip:zypper]=iproute2 [ip:urpmi]=iproute2 [ip:xbps-install]=iproute2

	# xmllint
	[xmllint:apt]=libxml2-utils [xmllint:dnf]=libxml2 [xmllint:yum]=libxml2
	[xmllint:pacman]=libxml2
	[xmllint:zypper]=libxml2-tools [xmllint:urpmi]=lib64xml2
	[xmllint:opkg]=libxml2 [xmllint:xbps-install]=libxml2

	# xz (curl defaults to the command key on every package manager)
	[xz:apt]=xz-utils

	# CA certificates (not a command key, installed explicitly by _installDeps)
	[cacerts:apt]=ca-certificates [cacerts:dnf]=ca-certificates
	[cacerts:yum]=ca-certificates [cacerts:pacman]=ca-certificates
	[cacerts:zypper]=ca-certificates
	[cacerts:urpmi]=rootcerts [cacerts:opkg]=ca-certificates
	[cacerts:xbps-install]=ca-certificates
)

_install_pkg() {
	local cmd_key=$1 pkg pm
	for pm in "${_D2G_PMS[@]}"; do
		command -v "$pm" >/dev/null || continue
		pkg="${_D2G_PKG[${cmd_key}:${pm}]:-$cmd_key}"
		case "$pm" in
			apt)
				if (( _D2G_PKG_DB_Updated == 0 )); then
					apt-get update
					_D2G_PKG_DB_Updated=1
				fi
				apt -y install "$pkg"
				;;
			dnf)
				dnf -y install "$pkg"
				;;
			yum)
				yum -y install "$pkg"
				;;
			pacman)
				if (( _D2G_PKG_DB_Updated == 0 )); then
					pacman -Syy
					_D2G_PKG_DB_Updated=1
				fi
				pacman --noconfirm -S "$pkg"
				;;
			zypper) # SUSE
				zypper install -y "$pkg"
				;;
			urpmi) # Mageia
				urpmi --force "$pkg"
				;;
			opkg) # OpenWRT
				opkg install "$pkg"
				;;
			xbps-install) # Void Linux
				xbps-install -y "$pkg"
				;;
		esac
		return $?
	done
	return 1
}

_installDeps() {
	_log i "Updating ca-certificates ..."
	_install_pkg cacerts || true

	_log i "Make sure commands '${NECESSARY_CMDS[*]}' are available."
	for cmd_key in "${NECESSARY_CMDS[@]}"; do
		if ! command -v "${cmd_key}" >/dev/null; then
			if ! _install_pkg "${cmd_key}"; then
				_log ee "Command '${cmd_key}' was not found and the installation failed!"
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
