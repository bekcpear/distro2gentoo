#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

printHelp() {
	echo "
Usage: distro2gentoo [<options>]

options:

	--yyy                   Answer yes to every confirmation, skip all
	                        interactive prompts and use defaults (unattended)
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

# Print a bold-yellow N..1 countdown on a single line.
# $1: message printed before the numbers
# $2: seconds to count
countdown() {
	local seconds=$2
	if [[ ${D2G_COUNTDOWN:-1} == 0 ]]; then
		echo "${1}(skipped)"
		return
	fi
	echo -en "$1\e[33m\e[1m"
	while (( seconds > 0 )); do
		echo -en "${seconds} "
		seconds=$((seconds - 1))
		sleep 1
	done
	echo -e "\e[0m"
}

# Interactive y/N gate. With --yyy (D2G_ASSUME_YES=1) it proceeds
# with the default automatically. Otherwise the user must answer y/Y to
# continue; anything else (including empty input -> default N) aborts.
# $1: prompt line(s) already printed by the caller
confirm_or_abort() {
	if [[ ${D2G_ASSUME_YES:-0} == 1 || ${D2G_NONINTERACTIVE:-0} == 1 ]]; then
		return 0
	fi
	# Only prompt when running interactively (stdin is a real TTY).
	# Under ssh-without-a-tty / pipes / CI there is nobody to answer;
	# treat that as non-interactive and proceed with the defaults.
	if [[ ! -t 0 ]]; then
		return 0
	fi
	local _reply=""
	read -r -p "$(printf 'Proceed? [y/N]: ')" _reply || true
	case $_reply in
		y|Y) return 0 ;;
		*)
			_log ee "Aborted by user."
			return 1
			;;
	esac
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
	confirm_or_abort
	countdown "Starting in: " 5
}

