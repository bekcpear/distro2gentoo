#
# **BEGIN**
# BASHFUNC01: _log (d|i|n|w|e)|(ee [FUNCNAME]) MSG-STRING {MSG-STRING}
#
#  Author: Ryan Tsien <i@bitbili.net>
# License: GPL-2
#
# Log to specified destination, the destination is controled by
#
# variable:
#   _BASHFUNC_LOG_OUT_FD <FD-NUM>
# default:
#   1
#
# variable:
#   _BASHFUNC_LOG_ERR_FD <FD-NUM>
# default:
#   2
#
# if you want to redirect logs into custom files, you can
#   exec {_BASHFUNC_LOG_OUT_FD}>/path/to/file
#   exec {_BASHFUNC_LOG_ERR_FD}>/path/to/file
# before sourcing this file. Or if you have sourced, you can
#   exec {_ANY_VAR_NAME0}>/path/to/file
#   exec {_ANY_VAR_NAME1}>/path/to/file
#   _BASHFUNC_LOG_OUT_FD=${_ANY_VAR_NAME0}
#   _BASHFUNC_LOG_ERR_FD=${_ANY_VAR_NAME1}
#
# with different levels
#
#   e: print to error level
#   w: print to warning and above levels
#   n: print to normal and above levels
#   i: print to info and above levels
#   d: print to debug and above levels
#
#   ee: print to error level and
#       exit with ${_BASHFUNC_LAST_EXIT}
#                 or $?
#                 or 1
#       this mode can specify a function to call before exit
#       just pass the function name after ee
#
# the output level is controled by
#
# variable:
#   _BASHFUNC_LOG_LEVEL error|warning|normal|info|debug
# default:
#   warning
#
#      warning and error logs will print to _BASHFUNC_LOG_ERR_FD
# normal, info and debug logs will print to _BASHFUNC_LOG_OUT_FD
#
# the output string can also be prefixed with a datetime,
# which controled by
#
# variable:
#   _BASHFUNC_LOG_DATE on|off
# default:
#   on
#
# variable:
#   _BASHFUNC_LOG_DATE_FORMAT <DATE-FORMAT-PATTERN>
# default:
#   "+[%Y-%m-%d %H:%M:%S] "
#
# you can also specify a custom echo function name, this custom function
# should implements the same basic functions as bash buildin echo, and
# should also implements the same functions of options -e, this function
# can be specified by
#
# variable:
#   _BASHFUNC_LOG_ECHO_FUNC <FUNCNAME>
# default:
#   echo
#
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
#
# BASHFUNC01: _log (d|i|n|w|e)|(ee [FUNCNAME]) MSG-STRING {MSG-STRING}
# **END**
#

