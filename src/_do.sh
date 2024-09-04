#
# **BEGIN**
# BASHFUNC00: _do [-p PREFIX] COMMAND {ARGUMENT}
#
#  Author: Ryan Tsien <i@bitbili.net>
# License: GPL-2
#
# Print command and arguments to default stdout with
# a different FD number, so it won't affect or be affected by FD 1,
# and run it with all passed arguments
#
# option:
#   -p PREFIX
# description:
#   optional, MUST be at the begining of all arguments
#   it will add a prefix to the output
#
# the output is controled by
#
# variable:
#   _BASHFUNC_DO_OFD <FD-NUM>
# default:
#   an auto assigned FD number which point to the file which the current FD 1 pointed to
#
# if you want to redirect into custom files, you can
#   exec {_BASHFUNC_DO_OFD}>/path/to/file
# before sourcing this file. Or if you have sourced, you can
#   eval "exec ${_BASHFUNC_DO_OFD}>/path/to/file"
#
# the output string can also be prefixed with a datetime,
# which controled by
#
# variable:
#   _BASHFUNC_DO_DATE on|off
# default:
#   on
#
# variable:
#   _BASHFUNC_DO_DATE_FORMAT <DATE-FORMAT-PATTERN>
# default:
#   "+[%Y-%m-%d %H:%M:%S] "
#
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
#
# BASHFUNC00: _do [-p PREFIX] COMMAND {ARGUMENT}
# **END**
#
