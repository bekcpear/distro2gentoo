#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

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

