#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

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

