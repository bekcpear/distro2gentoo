#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

parseParams() {
	set +e
	unset GETOPT_COMPATIBLE
	getopt -T
	if [[ ${?} != 4 ]]; then
		_log ee "The Linux version of command 'getopt' is necessory to parse parameters."
	fi
	local _args
	if ! _args=$(getopt -o 'h' -l 'yyy,disable-binhost,help' -n 'distro2gentoo' -- "$@"); then
		printHelp 1
	fi
	set -e

	# parse arguments
	eval "set -- ${_args}"
	local _assume_yes=0
	while true; do
		case "${1}" in
			--yyy)
				_assume_yes=1
				shift
				;;
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
	if [ "$_assume_yes" -eq 1 ]; then
		export D2G_ASSUME_YES=1
	fi
}

