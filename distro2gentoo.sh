#!/usr/bin/env bash
#
# @cwittlut
#

set -e
set -o pipefail
export LC_ALL=C

# @VARIABLE: LOGLEVEL
# #DEFAULT: 2
# @INTERNAL
# @DESCRIPTION:
# Used to control output level of messages. Should only be setted
# by shell itself.
# 0 -> DEBUG; 1 -> INFO; 2 -> NORMAL; 3 -> WARNNING; 4 -> ERROR
LOGLEVEL=1

# @FUNCTION: _log
# @USAGE: <[dinwe]> <message>
# @INTERNAL
# @DESCRIPTION:
# Echo messages with a unified format.
#  'd' means showing in    DEBUG level;
#  'i' means showing in     INFO level;
#  'n' means showing in   NORMAL level;
#  'w' means showing in WARNNING level;
#  'e' means showing in    ERROR level;
# Msg will be printed to the standard output normally
# when this function is called without any option.
_log() {
  local color='\e[0m'
  local reset='\e[0m'
  local ofd='&1'
  local -i lv=2
  if [[ ! ${1} =~ ^[dinwe]+$ ]]; then
    echo "UNRECOGNIZED OPTIONS OF INTERNAL <_log> FUNCTION!" >&2
    exit 1
  fi
  case ${1} in
    *e*)
      lv=4
      color='\e[31m'
      ofd='&2'
      ;;
    *w*)
      lv=3
      color='\e[33m'
      ofd='&2'
      ;;
    *n*)
      lv=2
      color='\e[36m'
      ;;
    *i*)
      lv=1
      ;;
    *d*)
      lv=0
      ;;
  esac
  if [[ ${lv} -ge ${OUTPUT_LEVEL} ]]; then
    shift
    local prefix=""
    local msg="${@}"
    if [[ ${lv} != 2 ]]; then
      prefix="[$(date '+%Y-%m-%d %H:%M:%S')] "
    fi
    eval ">${ofd} echo -e \"${color}${prefix}${msg//\"/\\\"}${reset}\""
  fi
}

# @FUNCTION: _fatal
# @USAGE: <exit-code> <message>
# @INTERNAL
# @DESCRIPTION:
# Print an error message and exit shell.
_fatal() {
  if [[ ${1} =~ ^[[:digit:]]+$ ]]; then
    local exit_code=${1}
    shift
  else
    local exit_code=1
  fi
  _log e "${@}"
  exit ${exit_code}
}


# experimental binhost enabled or not
_BINHOST_ENABLED=0

_show_help() {
  echo "
Usage: distro2gentoo [<options>]

options:

  -b, --use-binhost       Enable the **experimental** binhost when installing Gentoo, refer to:
                          https://dilfridge.blogspot.com/2021/09/experimental-binary-gentoo-package.html

  -h, --help              Show this help
"
}

_parse_params() {
  set +e
  unset GETOPT_COMPATIBLE
  getopt -T
  if [[ ${?} != 4 ]]; then
    fatalerr "The command 'getopt' of Linux version is necessory to parse parameters."
  fi
  local _args
  _args=$(getopt -o 'bh' -l 'use-binhost,help' -n 'distro2gentoo' -- "$@")
  if [[ ${?} != 0 ]]; then
    _show_help
    exit 1
  fi
  set -e

  # parse arguments
  eval "set -- ${_args}"
  while true; do
    case "${1}" in
      -b|--use-binhost)
        if [[ ${CPUARCH} != "amd64" ]]; then
          _log e "The experimental binhost only supports amd64 architecture now, ignore '${1}'!"
        else
          _BINHOST_ENABLED=1
        fi
        shift
        ;;
      -h|--help)
        _show_help
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        fatalerr "unknow error"
        ;;
    esac
  done
}

_pre_check() {
  local _ret=000
  # check root
  [[ ${EUID} == 0 ]] || _ret=1${_ret:1}
  # check cpu arch (only tested for amd64/arm64 now)
  [[ ${CPUARCH} =~ ^amd64|arm64$ ]] || _ret=${_ret:0:1}1${_ret:2}
  # check newroot dir
  [[ -L ${NEWROOT} || -e ${NEWROOT} ]] && _ret=${_ret:0:2}1 || true
  case ${_ret} in
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
  if [[ ${_ret} != 000 ]]; then
    _fatal "Abort it!"
  fi
  # check bios/efi
  if [[ -e /sys/firmware/efi ]]; then
    EFI_ENABLED=1
  fi
}

_DOWNLOAD_CMD="wget"
_DOWNLOAD_CMD_QUIET="wget -qO -"
if command -v wget >/dev/null; then
  :
elif command -v curl >/dev/null; then
  _DOWNLOAD_CMD="curl -fL"
  _DOWNLOAD_CMD_QUIET="curl -sfL"
else
  _COMMANDS="wget"
fi

_cat() {
  if [[ ${1} == '-H' ]]; then
    local header="'${2}'"
    shift 2
  fi
  eval "${_DOWNLOAD_CMD_QUIET} ${header:+--header} ${header} '${1}'"
}

_download() {
  _log i "Downloading '${1}' ..."
  if [[ ${_DOWNLOAD_CMD} == wget ]]; then
    local _arg="-O '${2}'"
  else
    local _arg="-o '${2}'"
  fi
  eval "${_DOWNLOAD_CMD} ${_arg} '${1}'"
}

#test -e /etc/os-release && _os_release='/etc/os-release' || _os_release='/usr/lib/os-release'
#_DISTRO_ID=$(. ${_os_release}; echo -n "${ID}")
#_log i "Current system ID: ${_DISTRO_ID}"
#echo

_COMMANDS+=" awk bc findmnt gpg ip openssl wc xmllint xz tr sort"

declare -A -g PKG_ip
PKG_ip[apt]="iproute2"
PKG_ip[dnf]="iproute"
PKG_ip[pacman]="iproute2"
PKG_ip[zypper]="iproute2"
PKG_ip[urpmi]="iproute2"
PKG_ip[opkg]="ip"
PKG_ip[xbps-install]="iproute2"

declare -A -g PKG_xmllint
PKG_xmllint[apt]="libxml2-utils"
PKG_xmllint[dnf]="libxml2"
PKG_xmllint[pacman]="libxml2"
PKG_xmllint[zypper]="libxml2-tools"
PKG_xmllint[urpmi]="lib64xml2"
PKG_xmllint[opkg]="libxml2"
PKG_xmllint[xbps-install]="libxml2"

declare -A -g PKG_gpg
PKG_gpg[apt]="gnupg"
PKG_gpg[dnf]="gnupg2"
PKG_gpg[pacman]="gnupg"
PKG_gpg[zypper]="gpg2"
PKG_gpg[urpmi]="gnupg2"
PKG_gpg[opkg]="gnupg"
PKG_gpg[xbps-install]="gnupg"

declare -A -g PKG_wget
PKG_wget[apt]="wget"
PKG_wget[dnf]="wget"
PKG_wget[pacman]="wget"
PKG_wget[zypper]="wget"
PKG_wget[urpmi]="wget"
PKG_wget[opkg]="wget"
PKG_wget[xbps-install]="wget"

declare -A -g PKG_xz
PKG_xz[apt]="xz-utils"
PKG_xz[dnf]="xz"
PKG_xz[pacman]="xz"
PKG_xz[zypper]="xz"
PKG_xz[urpmi]="xz"
PKG_xz[opkg]="xz"
PKG_xz[xbps-install]="xz"

declare -A -g PKG_bc
PKG_bc[apt]="bc"
PKG_bc[dnf]="bc"
PKG_bc[pacman]="bc"
PKG_bc[zypper]="bc"
PKG_bc[urpmi]="bc"
PKG_bc[opkg]="bc"
PKG_bc[xbps-install]="bc"

declare -A -g PKG_cacerts
PKG_cacerts[apt]="ca-certificates"
PKG_cacerts[dnf]="ca-certificates"
PKG_cacerts[pacman]="ca-certificates"
PKG_cacerts[zypper]="ca-certificates"
PKG_cacerts[urpmi]="rootcerts"
PKG_cacerts[opkg]="ca-certificates"
PKG_cacerts[xbps-install]="ca-certificates"

__install_pkg() {
  local -i _ret=0
  local __command=${1}
  if command -v apt >/dev/null; then
    apt-get update
    eval "apt -y install \${PKG_${__command}[apt]}" || _ret=1
  elif command -v dnf >/dev/null; then
    eval "dnf -y install \${PKG_${__command}[dnf]}" || _ret=1
  elif command -v yum >/dev/null; then
    eval "yum -y install \${PKG_${__command}[dnf]}" || _ret=1
  elif command -v pacman >/dev/null; then
    pacman -Syy
    eval "pacman --noconfirm -S \${PKG_${__command}[pacman]}" || _ret=1
  elif command -v zypper >/dev/null; then # SUSE
    eval "zypper install -y \${PKG_${__command}[zypper]}" || _ret=1
  elif command -v urpmi >/dev/null; then # Mageia
    eval "urpmi --force \${PKG_${__command}[urpmi]}" || _ret=1
  elif command -v opkg >/dev/null; then # OpenWRT
    eval "opkg install \${PKG_${__command}[opkg]}" || _ret=1
  elif command -v xbps-install >/dev/null; then # Void Linux
    eval "xbps-install -y \${PKG_${__command}[xbps-install]}" || _ret=1
  else
    _ret=1
  fi
  return ${_ret}
}

_install_deps() {
  #TODO

  _log i "Updating ca-certificates ..."
  __install_pkg cacerts || true

  _log i "Make sure commands '${_COMMANDS[@]}' are available."
  for __command in ${_COMMANDS[@]}; do
    if ! command -v ${__command} >/dev/null; then
      if ! __install_pkg ${__command}; then
        _fatal "Command '${__command}' not found or install failed!"
      fi
    fi
  done
}

_get_mirror() {
  _log i "Getting mirror list..."
  set +e
  [[ $(_cat -H 'I-Agree-To-Use-Only-For-The-Distro2Gentoo-Script: True' 'https://ip7.d0a.io/self') =~ \"IsoCode\":\"([[:upper:]]{2})\" ]]
  local _country_code=${BASH_REMATCH[1]}
  local _mirrors
  : ${_country_code:=CN}
  if [[ $(xmllint --version 2>&1 | head -1 | cut -d' ' -f5 | cut -d'-' -f1) -ge 20909 ]]; then
    eval "_mirrors=\$(_cat 'https://api.gentoo.org/mirrors/distfiles.xml' | \
      xmllint --xpath '/mirrors/mirrorgroup[@country=\"${_country_code}\"]/mirror/uri/text()' -)"
  else
    eval "_mirrors=\$(_cat 'https://api.gentoo.org/mirrors/distfiles.xml' | \
      xmllint --xpath '/mirrors/mirrorgroup[@country=\"${_country_code}\"]/mirror/uri' -)"
    _mirrors=${_mirrors//<\/uri>/$'\n'}
    _mirrors=$(echo "${_mirrors}" | cut -d'>' -f2)
  fi
  set -e
  local _uri __selected
  _mirrors=$(sed -E '/^rsync/d' <<<"${_mirrors}")
  _mirrors=( ${_mirrors} )
  _log i "Setting mirror ..."
  _log n "mirror list in ${_country_code}:"
  for (( i = 0; i < ${#_mirrors[@]}; ++i )); do
    _uri=${_mirrors[i]}
    if [[ "${_uri}" =~ ^https ]] && [[ -z ${MIRROR} ]]; then
      MIRROR="${_uri}"
      _log n " -*-[${i}] ${_uri}"
    else
      _log n "    [${i}] ${_uri}"
    fi
  done
  _mirrors+=( "CUSTOM" )
  _log n "    [${i}] <Enter custom URL>"
  while [[ ${#_mirrors[@]} -gt 0 ]]; do
    read -p "Choose prefered mirror (enter the num, empty for default): " __selected
    [[ -n ${__selected} ]] || break
    if [[ ${__selected} =~ ^[[:digit:]]+$ ]] && [[ -n ${_mirrors[${__selected}]} ]]; then
      MIRROR=${_mirrors[${__selected}]}
      break;
    else
      _log w "out of range!"
    fi
  done
  if [[ ${MIRROR} == CUSTOM ]]; then
    _set_custom_mirror() {
      read -p "Enter your custom URL: " MIRROR
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

_get_stage3() {
  _log i "Getting stage3 tarball ..."
  local _list="${MIRROR%/}/releases/${CPUARCH}/autobuilds/latest-stage3.txt"
  local _path _size _selected __selected
  local -a _stages _stages_path
  _log i "Downloading stage3 tarball list ..."
  while read -r _path _; do
    [[ ! ${_path} =~ ^# ]] || continue
    _stages+=( "${_path##*/}" )
    _stages_path+=( "${_path}" )
  done <<<"$(_cat ${_list})"
  _log n "stage3 list:"
  for (( i = 0; i < ${#_stages[@]}; ++i )); do
    local _stage=${_stages[i]}
    if [[ ! ${_stage} =~ ^stage3 ]]; then
      unset _stages[i]
      continue
    fi
    if [[ ${_stage} =~ ^stage3-amd64-openrc-|stage3-arm64-2 ]]; then
      _selected=${i}
      _log n " -*-[${i}] ${_stage}"
    else
      _log n "    [${i}] ${_stage}"
    fi
  done
  if [[ ${#_stages[@]} < 1 ]]; then
    _fatal "No stage3 list, please check the mirror URL or your network."
  fi
  while :; do
    read -p "Choose prefered stage3 (enter the num, empty for default): " __selected
    [[ -n ${__selected} ]] || break
    if [[ ${__selected} =~ ^[[:digit:]]+$ ]] && [[ -n ${_stages[${__selected}]} ]]; then
      _selected=${__selected}
      break;
    else
      _log w "out of range!"
    fi
  done
  _log i "selected stage3: ${_stages[${_selected}]}"
  _log i "Importing release keys ..."
  _GET_RELEASE_KEY="gpg --quiet --keyserver hkps://keys.gentoo.org --recv-key 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
  ${_GET_RELEASE_KEY} || \
    {
      _log i "try again ..."
      pkill dirmngr || true
      ${_GET_RELEASE_KEY}
    }
  # prepare signature
  ASC="/${_stages[${_selected}]}.asc"
  if [[ ! -e ${ASC} ]]; then
    eval "_download '${_list%/*}/${_stages_path[${_selected}]}.asc' '${ASC}'"
  fi
  # prepare stage3 tarball
  STAGE3="/${_stages[${_selected}]}"
  if [[ ! -e ${STAGE3} ]]; then
    eval "_download '${_list%/*}/${_stages_path[${_selected}]}' '${STAGE3}'"
  fi
  _log i "Checking ${ASC} ..."
  gpg --verify ${ASC} || _fatal "Verify signature failed!"
  _log i "Stage3 tarball has been stored as '${STAGE3}'."
}

_unpack_stage3() {
  pushd ${NEWROOT}
  _log w ">>> tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner"
  tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner
  popd
}

declare -a _FS_SOURCES _FS_MPS _FS_TYPES _FS_OPTS
_LVM_ENABLED=0   # _LVM_LVS _LVM_LVS_MP
_LUKS_ENABLED=0  # _LUKS_PARTS _LUKS_PARTS_MP _LUKS_PARTS_PARENT
_BTRFS_ENABLED=0 # _BTRFS_MP _BTRFS_SUBVOL _BTRFS_OPT _BTRFS_SUBVOL_ROOTFS
__analyze_fstab() {
  while read -r _source _mp _type _opts _; do
    _FS_SOURCES+=("${_source}")
    _FS_MPS+=("${_mp}")
    _FS_TYPES+=("${_type}")
    _FS_OPTS+=("${_opts}")
  done <<<"$(findmnt --noheadings -loSOURCE,TARGET,FSTYPE,OPTIONS)"

  local _sys_path_pattern='^(/|\[SWAP\])'
  while read -r _name _type _mp; do
    case ${_type} in
      crypt)
        while read -r __mp; do
          if [[ ${__mp} =~ ${_sys_path_pattern} ]]; then
            _LUKS_ENABLED=1
            _LUKS_PARTS+=("${_name}")
            _LUKS_PARTS_MP+=("${_mp}")
            _LUKS_PARTS_PARENT+=("$(lsblk -tpo NAME | grep -B1 "${_name}" | head -1 | cut -d'-' -f2)")
            break
          fi
        done <<<"$(lsblk -lnoMOUNTPOINT ${_name})"
        ;;
      lvm)
        if [[ ${_mp} =~ ${_sys_path_pattern} ]]; then
          _LVM_ENABLED=1
          _LVM_LVS+=("${_name}")
          _LVM_LVS_MP+=("${_mp}")
        fi
        ;;
      *)
        :
        ;;
    esac
  done <<<"$(lsblk -lpnoNAME,TYPE,MOUNTPOINT)"

  local -i i
  local __subvol
  for (( i = 0; i < ${#_FS_TYPES[@]}; ++i )); do
    if [[ ${_FS_TYPES[i]} == btrfs ]]; then
      if [[ ${_FS_MPS[i]} =~ ^/ ]]; then
        _BTRFS_ENABLED=1
        _BTRFS_MP+=("${_FS_MPS[i]}")
        __subvol="$(<<<${_FS_SOURCES[i]} sed -nE 's/^[^[]+\[([^]]+)\]/\1/p')"
        _BTRFS_SUBVOL+=("${__subvol}")
        _BTRFS_OPT+=("${_FS_OPTS[i]}")
        if [[ ${_FS_MPS[i]} == / ]]; then
          _BTRFS_SUBVOL_ROOTFS="${__subvol}"
        fi
      fi
    fi
  done
}

# $1: result variable name
# $2...: cmdline opts
#TODO more options
___unify_cmdline_opts() {
  local _name=${1} _opts _opt _opt_r _tmpv _tmpv_luks_name _tmpv_luks_names
  local -a _luks_opts _lvm_vg_opts _lvm_lv_opts
  local _uuid_pattern='[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{12}'
  shift
  _opts=$(echo "$*" | tr ' ' '\n' | sort -du | tr '\n' ' ')
  set - ${_opts}
  for _opt ; do
    case "${_opt}" in
      root=*)
        if [[ ${_opt_r} =~ [[:space:]]root= ]]; then
          _log w "Multiple 'root=' options, ignore '${_opt}'"
        else
          _opt_r+=" ${_opt}"
        fi
        ;;
      dolvm)
        :
        ;;
      rd.lvm.vg=*)
        _lvm_vg_opts+=( ${_opt} )
        ;;
      rd.lvm.lv=*)
        _lvm_lv_opts+=( ${_opt} )
        ;;
      crypt_root=*)
        if [[ ${_opt} =~ ^crypt_root=UUID=${_uuid_pattern}$ ]]; then
          _luks_opts+=( "rd.luks.uuid=${_opt/#crypt_root=UUID=/}" )
        else
          _log e "Unrecognized cmdline option: ${_opt}"
        fi
        ;;
      luks=*|rd.luks=*)
        _tmpv=${_opt/#*luks=/}
        if [[ ${_tmpv} =~ [[:digit:]]+ ]]; then
          _opt_r+=" rd.luks=${_tmpv}"
        else
          case ${_tmpv} in
            yes)
              _opt_r+=" rd.luks=1"
              ;;
            no)
              _opt_r+=" rd.luks=0"
              ;;
            *)
              _log e "Unrecognized cmdline option: ${_opt}"
              ;;
          esac
        fi
        ;;
      luks.crypttab=*|rd.luks.crypttab=*)
        _tmpv=${_opt/#*luks.crypttab=/}
        if [[ ${_tmpv} =~ [[:digit:]]+ ]]; then
          _opt_r+=" rd.luks.crypttab=${_tmpv}"
        else
          case ${_tmpv} in
            yes)
              _opt_r+=" rd.luks.crypttab=1"
              ;;
            no)
              _opt_r+=" rd.luks.crypttab=0"
              ;;
            *)
              _log e "Unrecognized cmdline option: ${_opt}"
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
        fi
        ;;
      luks.name=*|rd.luks.name=*)
        _tmpv=${_opt/#*luks.uuid=/}
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
        fi
        ;;
      luks.key=*|rd.luks.key=*)
        _tmpv=${_opt/#*luks.key=/}
        if [[ ${_tmpv} =~ ^${_uuid_pattern}= ]]; then
          local _tmpv_luksdev
          _tmpv_luksdev=":UUID=${_tmpv/%=*/}"
          _tmpv=${_tmpv/#${_tmpv_luksdev/#UUID=}=/}
        fi
        if [[ ${_tmpv} =~ : ]]; then
          local _tmpv_keydev
          _tmpv_keydev=":${_tmpv/#*:/}"
        fi
        _opt_r+=" rd.luks.key=${_tmpv/%:*/}${_tmpv_keydev}${_tmpv_luksdev}"
        ;;
      *)
        eval "_UNUNIFIED${_name}+=' ${_opt}'"
        _opt_r+=" ${_opt}"
        ;;
    esac
  done
  if [[ ${_opt_r} =~ [[:space:]]root=/dev/mapper/ ]]; then
    local _tmpv_root_name
    _tmpv_root_name=$(echo ${_opt_r} | sed -nE 's/.*\sroot=\/dev\/mapper\/([^\/[:space:]]+)\s.*/\1/p')
    for _tmpv in ${_tmpv_luks_names}; do
      if [[ ${_tmpv} == ${_tmpv_root_name} ]]; then
        _opt_r="${_opt_r//root=\/dev\/mapper\/${_tmpv_root_name}/}"
        _opt_r+=" root=UUID=$(lsblk -noUUID /dev/mapper/${_tmpv_root_name} | head -1)"
      fi
    done
  fi

  if [[ ${_name} == "_GRUB_CMDLINE_LINUX" ]]; then
    if [[ ${_LVM_ENABLED} == 1 ]]; then
      local _tmpv_lvm_lv _tmpv_lvm_vg _tmpv_lvm_lv_val
      for (( i = 0; i < ${#_LVM_LVS[@]}; ++i )); do
        local _this_is_set=0 _first_line=0
        while read -r _tmpv_lvm_lv _tmpv_lvm_vg; do
          if [[ ${_tmpv_lvm_lv} == "LV" ]]; then
            _first_line=1
            continue
          elif [[ ${_first_line} == 0 ]]; then
            _log e "Cannot get LV and VG for '${_LVM_LVS[i]}'"
            break
          fi
          _tmpv_lvm_lv_val="rd.lvm.lv=${_tmpv_lvm_vg}/${_tmpv_lvm_lv}"
        done <<<"$(lvdisplay -Co lv_name,vg_name ${_LVM_LVS[i]})"
        for _lvm_lv_opt in ${_lvm_lv_opts[@]}; do
          if [[ "${_lvm_lv_opt}" == "${_tmpv_lvm_lv_val}" ]]; then
            _this_is_set=1
          fi
        done
        if [[ ${_this_is_set} == 0 ]]; then
          _lvm_lv_opts+=( "${_tmpv_lvm_lv_val}" )
        fi
      done
    fi

    if [[ ${_LUKS_ENABLED} == 1 ]]; then
      local _tmpv_luks_uuid _tmpv_luks_uuid_val
      for (( i = 0; i < ${#_LUKS_PARTS_PARENT[@]}; ++i )); do
        local _this_is_set=0
        read -r _tmpv_luks_uuid _ <<<"$(lsblk -tnoUUID,NAME ${_LUKS_PARTS_PARENT[i]} | head -1)"
        _tmpv_luks_uuid_val="rd.luks.uuid=${_tmpv_luks_uuid}"
        for _luks_opt in ${_luks_opts[@]}; do
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

  for _opt in ${_lvm_lv_opts[@]} ${_lvm_vg_opts[@]} ${_luks_opts[@]}; do
    _opt_r+=" ${_opt}"
  done

  eval "${_name}='${_opt_r/#[[:space:]]/}'"

  unset _name _opts _opt _opt_r _tmpv _tmpv_luks_name _tmpv_luks_names _luks_opts _lvm_vg_opts _lvm_lv_opts
}

_GRUB_CMDLINE_LINUX=''
_GRUB_CMDLINE_LINUX_DEFAULT=''
__set_grub_cmdline() {
  local _cmdline _cmdline_default _cmdline_array _cmdline_default_array
  cp -aL /etc/default/grub "${NEWROOT}/etc/default/._old_grub" || true
  _cmdline="$(. /etc/default/grub; echo ${GRUB_CMDLINE_LINUX})"
  _cmdline="${_cmdline//quiet/}"
  _cmdline="${_cmdline//splash=silent/}"
  _cmdline="${_cmdline//splash/}"
  _cmdline_array=( ${_cmdline//rhgb/} )
  ___unify_cmdline_opts _GRUB_CMDLINE_LINUX ${_cmdline_array[@]}

  _cmdline_default="$(. /etc/default/grub; echo ${GRUB_CMDLINE_LINUX_DEFAULT})"
  _cmdline_default="${_cmdline_default//quiet/}"
  _cmdline_default="${_cmdline_default//splash=silent/}"
  _cmdline_default="${_cmdline_default//splash/}"
  _cmdline_default_array=( ${_cmdline_default//rhgb/} )
  ___unify_cmdline_opts _GRUB_CMDLINE_LINUX_DEFAULT ${_cmdline_default_array[@]}
}

_ready_chroot() {
  _log i "mounting necessaries ..."
  mount -t proc /proc "${NEWROOT}/proc"
  mount --rbind /sys "${NEWROOT}/sys"
  mount --make-rslave "${NEWROOT}/sys"
  mount --rbind /dev "${NEWROOT}/dev"
  mount --make-rslave "${NEWROOT}/dev"
  mount -t tmpfs -o nosuid,nodev,mode=0755 run "${NEWROOT}/run"
  _log i "copying necessaries ..."
  cp -aL /etc/fstab "${NEWROOT}/etc/"
  cp -aL /etc/resolv.conf "${NEWROOT}/etc/" || true
  cp -aL /etc/hosts "${NEWROOT}/etc/" || true
  cp -aL /etc/hostname "${NEWROOT}/etc/" || \
    echo "gentoo" > "${NEWROOT}/etc/hostname"
  cp -aL /lib/modules "${NEWROOT}/lib/" || true
  __analyze_fstab
  __set_grub_cmdline
  mount /boot || true
  local rootshadow=$(grep -E '^root:' /etc/shadow)
  local _newpass _newday
  if [[ ${rootshadow} =~ ^root:\*: ]]; then
    _log i "setting root password to 'distro2gentoo' ..."
    _newpass=$(openssl passwd -1 distro2gentoo)
    _newday=$(echo `date +%s`/24/60/60 | bc)
  else
    _log i "backuping root password ..."
    _newpass=$(echo ${rootshadow} | cut -d':' -f2)
    _newday=$(echo ${rootshadow} | cut -d':' -f3)
  fi
  eval "sed -Ei '/root:\*:.*/s@root:\*:[[:digit:]]+:@root:${_newpass}:${_newday}:@' '${NEWROOT}/etc/shadow'"
  if [[ ${CPUARCH} == amd64 ]]; then
    echo "GRUB_PLATFORMS=\"efi-64 pc\"" >> "${NEWROOT}/etc/portage/make.conf"
  else
    echo "GRUB_PLATFORMS=\"efi-64\"" >> "${NEWROOT}/etc/portage/make.conf"
  fi
  echo "GENTOO_MIRRORS=\"${MIRROR}\"" >> "${NEWROOT}/etc/portage/make.conf"
}

_first_tip() {
  echo
  _log n "    1. This script won't format disks,"
  _log n "    2. will remove all mounted data excepts /home, /root,"
  _log n "                                            kernels & modules"
  echo
  _log n "           *** BACKUP YOUR DATA!!! ***"
  echo
  WAIT=5
  echo -en "Starting in: \e[33m\e[1m"
  while [[ ${WAIT} -gt 0 ]]; do
    echo -en "${WAIT} "
    WAIT=$((${WAIT} -  1))
    sleep 1
  done
  echo -e "\e[0m"
}

CPUARCH=$(uname -m)
CPUARCH=${CPUARCH/x86_64/amd64}
CPUARCH=${CPUARCH/aarch64/arm64}
_parse_params "${@}"

_prepare_env() {
  NEWROOT="/root.d2g.${CPUARCH}"
  _pre_check
  _first_tip
  mkdir -p "${NEWROOT}"
  _install_deps
  _get_mirror
  _get_stage3
  _unpack_stage3
  _ready_chroot
}
_prepare_env

_chroot_exec() {
  _log w ">>> chroot '${NEWROOT}' /bin/bash -lc '${@}'"
  eval "chroot '${NEWROOT}' /bin/bash -lc '${@}'"
}

_prepare_bootloader() {
  sed -i "/GRUB_CMDLINE_LINUX=\"\"/aGRUB_CMDLINE_LINUX=\"${_GRUB_CMDLINE_LINUX}\"" \
    ${NEWROOT}/etc/default/grub
  sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/aGRUB_CMDLINE_LINUX_DEFAULT=\"${_GRUB_CMDLINE_LINUX_DEFAULT}\"" \
    ${NEWROOT}/etc/default/grub
  sed -i "/GRUB_DEFAULT=/aGRUB_DEFAULT=\"saved\"" ${NEWROOT}/etc/default/grub
  echo $'\n'"GRUB_DISABLE_OS_PROBER=false" >>${NEWROOT}/etc/default/grub

  cp -a "${NEWROOT}"/boot/* /boot/
  mount --bind /boot "${NEWROOT}/boot"
  local _grub_configed=0
  # find the boot device
  if [[ ${CPUARCH} == amd64 ]]; then
    local _bootdev
    if _bootdev=$(findmnt -no SOURCE /boot); then
      :
    else
      _bootdev=$(findmnt -no SOURCE /)
    fi
    _bootdev=$(lsblk -npsro TYPE,NAME "${_bootdev}" | awk '($1 == "disk") { print $2}')
    if [[ ! ${_bootdev} =~ ^/dev/mapper ]]; then
      _chroot_exec grub-install --target=i386-pc ${_bootdev} && \
        _grub_configed=1 || true
    else
      _log w "Boot device is a mapper, skip i386-pc target grub installation."
    fi
  fi
  # prepare efi
  if [[ -n ${EFI_ENABLED} ]]; then
    local _bootcurrent _partuuid
    while read -r _head _val; do
      if [[ ${_head} == "BootCurrent:" ]]; then
        _bootcurrent="${_val}"
        continue
      fi
      if [[ ${_head} =~ Boot${_bootcurrent} ]]; then
        _partuuid=$(echo "${_val}" | sed -nE '/HD\(/s/.*HD\([^,]+,[^,]+,([^,]+),.*/\1/p')
        break
      fi
    done <<<"$(efibootmgr -v)"
    if [[ ${_partuuid} != "" ]]; then
      read -r EFIDEV EFIMNT <<<"$(lsblk -noPATH,MOUNTPOINT /dev/disk/by-partuuid/${_partuuid})"
    else
      # hazily matching a possibile efi partition
      _log w "matching a possibile efi partition hazily ..."
      local _efidevs="$(findmnt --fstab -nlt vfat -o TARGET,SOURCE)"
      if [[ $(<<<"${_efidevs}" wc -l) -gt 1 ]]; then
        local _efidev_m_f
        while read -r _efidev_m _efidev_d; do
          case ${_efidev_m} in
            *[eE][fF][iI]*)
              EFIMNT=${_efidev_m}
              EFIDEV=${_efidev_d}
              _efidev_m_f=e
              ;;
            *[bB][oO][oO][tT]*)
              if [[ ${_efidev_m_f} != "e" ]]; then
                EFIMNT=${_efidev_m}
                EFIDEV=${_efidev_d}
                _efidev_m_f=b
              fi
              ;;
            *)
              if [[ ${_efidev_m_f} == "" ]]; then
                EFIMNT=${_efidev_m}
                EFIDEV=${_efidev_d}
              fi
              ;;
          esac
        done <<<"${_efidevs}"
      else
        read -r EFIMNT EFIDEV <<<"${_efidevs}"
      fi
    fi
    if [[ -n ${EFIDEV} ]]; then
      if [[ ${EFIMNT} == "" ]]; then
        if ! EFIMNT=$(findmnt --fstab -nlt vfat -oTARGET -S${EFIDEV}); then
          # set a default efi mount point
          EFIMNT="/boot/efi_partition"
        fi
      fi
      mkdir -p "${NEWROOT}${EFIMNT}"
      _log i ">>> mount ${EFIDEV} ${NEWROOT}${EFIMNT}"
      mount ${EFIDEV} "${NEWROOT}${EFIMNT}"
      if [[ ${CPUARCH} == amd64 ]]; then
        local _target="x86_64-efi"
      else
        local _target="arm64-efi"
      fi
      _chroot_exec grub-install --target=${_target} --efi-directory=${EFIMNT} --bootloader-id=Gentoo
      _chroot_exec grub-install --target=${_target} --efi-directory=${EFIMNT} --removable
      _grub_configed=1
    else
      _log e "Cannot find EFI partition!"
    fi
  fi
  if [[ ${_grub_configed} == 0 ]]; then
    _fatal "Grub install failed!"
  fi
}

if [[ ! ${STAGE3} =~ systemd ]]; then
  EXTRA_DEPS+=" net-misc/netifrc"
fi
_chroot_exec emerge-webrsync

_DRACUT_MODULES=
_prepare_pkgs_configuration() {
  if [[ ${_LUKS_ENABLED} == 1 ]]; then
    if [[ ${STAGE3} =~ systemd ]]; then
      echo 'sys-apps/systemd cryptsetup' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
      ONETIME_PKGS+=" sys-apps/systemd"
    fi
    _DRACUT_MODULES+=" crypt"
    echo 'sys-fs/cryptsetup -static-libs' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
    EXTRA_DEPS+=" sys-fs/cryptsetup"
  fi
  if [[ ${_LVM_ENABLED} == 1 ]]; then
    cp -aL /etc/lvm "${NEWROOT}/etc/"
    _DRACUT_MODULES+=" lvm"
    EXTRA_DEPS+=" sys-fs/lvm2"
  fi
  if [[ ${_BTRFS_ENABLED} == 1 ]]; then
    _DRACUT_MODULES+=" btrfs"
    EXTRA_DEPS+=" sys-fs/btrfs-progs"
  fi
  if [[ ${_BINHOST_ENABLED} == 1 ]]; then
    local _binhost_sync_uri="${MIRROR%/}/experimental/${CPUARCH}/binpkg/default/linux/17.1/x86-64/"
    echo "[binhost]
priority = 9999
sync-uri = ${_binhost_sync_uri}
" >"${NEWROOT}/etc/portage/binrepos.conf"
    _log w "The binhost sync-uri is set to '${_binhost_sync_uri}'"
    _BINHOST_ARGS="--binpkg-changed-deps=y --binpkg-respect-use=y --getbinpkg=y"
  fi
}
_prepare_pkgs_configuration
_CPUS=$(grep '^processor' /proc/cpuinfo | wc -l)

_EMERGE_OPTS="--autounmask-write --autounmask-continue -vj"

[[ -z ${ONETIME_PKGS} ]] || \
  _chroot_exec 'DONT_MOUNT_BOOT=1' emerge -l ${_CPUS} -1 ${_EMERGE_OPTS} ${_BINHOST_ARGS} ${ONETIME_PKGS}

# install necessary pkgs
mkdir -p ${NEWROOT}/etc/portage/package.license
echo 'sys-kernel/linux-firmware linux-fw-redistributable no-source-code' \
  >${NEWROOT}/etc/portage/package.license/linux-firmware
echo 'sys-boot/grub mount' >>"${NEWROOT}/etc/portage/package.use/bootloader"
_chroot_exec 'DONT_MOUNT_BOOT=1' emerge -l ${_CPUS} -n ${_EMERGE_OPTS} ${_BINHOST_ARGS} \
  linux-firmware gentoo-kernel-bin sys-boot/grub sys-boot/os-prober net-misc/openssh ${EXTRA_DEPS}

# regenerate initramfs
if [[ -n ${_DRACUT_MODULES} ]]; then
  mkdir -p "${NEWROOT}/etc/dracut.conf.d"
  echo "add_dracutmodules+=\"${_DRACUT_MODULES} \"" >>"${NEWROOT}/etc/dracut.conf.d/distro2gentoo.conf"
  _chroot_exec 'DONT_MOUNT_BOOT=1' emerge --config sys-kernel/gentoo-kernel-bin
fi

# TODO: support bridge
# TODO: IPv6 RA for netifrc (openrc)
# TODO: DHCP/DHCPv6 for netifrc (net-misc/dhcpcd or net-misc/dhcp does not installed by default for now, 20221113)
__config_network() {
  local -A _dev_prefix_priority=([en]=9 [wl]=8 [ww]=7 [eth]=6 [wlan]=5)
  local -a _netdev _netproto _netdst _netgateway _netdev6 _netproto6 _netdst6 _netgateway6
  local _ __dst __via __gateway __dev __proto

  ___with_high_priority() {
    local __first=${_dev_prefix_priority[${1:0:4}]:-${_dev_prefix_priority[${1:0:3}]:-${_dev_prefix_priority[${1:0:2}]:-0}}}
    local __second=${_dev_prefix_priority[${2:0:4}]:-${_dev_prefix_priority[${2:0:3}]:-${_dev_prefix_priority[${2:0:2}]:-0}}}
    (( ${__first} > ${__second} ))
  }
  ___has_priority() {
    [[ -n ${_dev_prefix_priority[${1:0:4}]:-${_dev_prefix_priority[${1:0:3}]:-${_dev_prefix_priority[${1:0:2}]}}} ]]
  }

  # ipv4 default route/device
  ___assign_primary_net() {
    _netdev[0]=${1}
    _netgateway[0]=${2}
    _netproto[0]=${3}
    _netdst[0]="0.0.0.0/0"
  }
  local __iproute_updated=
  while ! [[ $(ip -d -o route show type unicast to default) =~ ^unicast ]]; do
    if [[ -n ${__iproute_updated} ]]; then
      _fatal "iproute2 version is still too old, please solve it manually"
    fi
    _log w "iproute2 version is too old, updating it ..."
    __install_pkg ip
    __iproute_updated=1
  done
  while read -r _ _ _ __gateway _ __dev _ __proto _; do
    if [[ -z ${_netdev[0]} ]] || \
      ___with_high_priority "${__dev}" "${_netdev[0]}"; then
      ___assign_primary_net "${__dev}" "${__gateway}" "${__proto}"
    fi
  done<<<"$(ip -d -o route show type unicast to default)"

  ___assign_extra_net() {
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
    if [[ ${!__netdevprim} != ${__dev} ]] && \
      ___has_priority ${__dev}; then
      eval "_netdev${__t}+=( '${__dev}' )"
      eval "_netproto${__t}+=( '${__proto}' )"
      eval "_netdst${__t}+=( '${__dst}' )"
      eval "_netgateway${__t}+=( '${__gateway}' )"
    fi
  }
  # ipv4 extra route/device
  while read -r _ __dst __via __gateway _ __dev _ __proto _; do
    ___assign_extra_net "${__dst}" "${__via}" "${__gateway}" "${__dev}" "${__proto}" ""
  done<<<"$(ip -d -o route show type unicast)"

  # ipv6 default route/device
  ___assign_primary_net6() {
    _netdev6[0]=${1}
    _netgateway6[0]=${2}
    _netproto6[0]=${3}
    _netdst6[0]="::/0"
  }
  while read -r _ _ _ __gateway _ __dev _ __proto _; do
    if [[ -z ${_netdev6[0]} ]] || \
      ___with_high_priority "${__dev}" "${_netdev6[0]}"; then
      ___assign_primary_net6 "${__dev}" "${__gateway}" "${__proto}"
    fi
  done<<<"$(ip -6 -d -o route show type unicast to default)"

  # ipv6 extra route/device
  while read -r _ __dst __via __gateway _ __dev _ __proto _; do
    ___assign_extra_net "${__dst}" "${__via}" "${__gateway}" "${__dev}" "${__proto}" 6
  done<<<"$(ip -6 -d -o route show type unicast | grep -Ev '^unicast[[:space:]]+fe80::')"

  local -a _dev _proto _proto6 _dst _dst6 _gateway _gateway6

  ___assign_net() {
         _dev+=( "${1}" )
       _proto+=( "${2}" )
      _proto6+=( "${3}" )
         _dst+=( "${4}" )
        _dst6+=( "${5}" )
     _gateway+=( "${6}" )
    _gateway6+=( "${7}" )
  }

  # check primary network devices
  if [[ ${_netdev[0]} == ${_netdev6[0]} ]]; then
    ___assign_net ${_netdev[0]} ${_netproto[0]} ${_netproto6[0]} ${_netdst[0]} ${_netdst6[0]} ${_netgateway[0]} ${_netgateway6[0]}
  else
    if [[ -n ${_netdev[0]} ]]; then
    ___assign_net ${_netdev[0]} ${_netproto[0]} "" ${_netdst[0]} "" ${_netgateway[0]} ""
    fi
    if [[ -n ${_netdev6[0]} ]]; then
    ___assign_net ${_netdev6[0]} "" ${_netproto6[0]} "" ${_netdst6[0]} "" ${_netgateway6[0]}
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
      if [[ ${__dev} == ${_netdev6[$_j]} ]]; then
        # means _netdev6[_j] must not equal to _netdev[0], safely to add
        __added_j+=( $_j )
        ___assign_net ${_netdev[$_i]} ${_netproto[$_i]} ${_netproto6[$_j]} ${_netdst[$_i]} ${_netdst6[$_j]} ${_netgateway[$_i]} ${_netgateway6[$_j]}
        __added=1
        break
      fi
    done
    if [[ ${__added} == 0 ]]; then
      ___assign_net ${_netdev[$_i]} ${_netproto[$_i]} "" ${_netdst[$_i]} "" ${_netgateway[$_i]} ""
    fi
  done
  for (( _j = 1; _j < ${#_netdev6[@]}; _j++ )); do
    __added=0
    for __j in ${__added_j[@]}; do
      if [[ $_j == $__j ]]; then
        __added=1
      fi
    done
    if [[ ${__added} == 0 ]]; then
      # check whether the _netdev6[_j] is equal to _netdev[0]
      if [[ ${_netdev6[$_j]} == ${_netdev[0]} ]]; then
        # _netdev[0] always has the index 0, assign maunally.
        _proto6[0]="${_netproto6[$_j]}"
        _dst6[0]="${_netdst6[$_j]}"
        _gateway6[0]="${_netgateway6[$_j]}"
      else
        ___assign_net ${_netdev6[$_j]} "" ${_netproto6[$_j]} "" ${_netdst6[$_j]} "" ${_netgateway6[$_j]}
      fi
    fi
  done

  ___the_correct_dev_name() {
    # fix to use correct interface name
    # refer to https://www.freedesktop.org/wiki/Software/systemd/PredictableNetworkInterfaceNames/
    local _netdev=$1
    local -a __devs
    if [[ $_netdev =~ ^(eth|wlan) ]] && \
      [[ ! "${_GRUB_CMDLINE_LINUX}${_GRUB_CMDLINE_LINUX_DEFAULT}" =~ net\.ifnames=0 ]]; then
      __devs=($(ip link show ${_netdev} | grep -E '^\s+altname\s' | awk '{print $2}'))
      if [[ ${#__devs[@]} -eq 0 ]]; then
        _log w "cannot found the altname for this legacy network device name: $_netdev"
        _log w "use this legacy name, and set 'net.ifnames=0' to the kernel cmdline ..."
        echo -n "LEGACY"
        # TODO: try to guess the correct modern name
      else
        for __dev in ${__devs[@]}; do
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
    local      __dev=${_dev[$_i]} \
             __proto=${_proto[$_i]} \
            __proto6=${_proto6[$_i]} \
               __dst=${_dst[$_i]} \
              __dst6=${_dst6[$_i]} \
           __gateway=${_gateway[$_i]} \
          __gateway6=${_gateway6[$_i]}

    local -a __ip=() __ip6=()
    local ___ip=
    if [[ ${__proto} != dhcp ]]; then
      while read -r _ ___ip _; do
        if [[ -n ${___ip} ]]; then
          __ip+=( "${___ip}" )
        fi
      done <<<"$(ip -d addr show dev ${__dev} scope global | grep -E '^\s+inet\s')"
    fi
    if [[ ${__proto6} != dhcp ]] && [[ ${__proto6} != ra ]]; then
      while read -r _  ___ip _; do
        if [[ -n ${___ip} ]]; then
          __ip6+=( "${___ip}" )
        fi
      done <<<"$(ip -d addr show dev ${__dev} scope global | grep -E '^\s+inet6\s')"
    fi

    __dev=$(___the_correct_dev_name ${__dev})
    if [[ ${__dev} =~ ^LEGACY ]]; then
      __dev=${__dev#LEGACY}
      _GRUB_CMDLINE_LINUX+=" net.ifnames=0"
    fi

    local __networkd_match="[Match]" \
        __networkd_network="[Network]" \
        __networkd_address= \
          __networkd_route="[Route]" \
       __networkd_address6= \
         __networkd_route6="[Route]" \
           __networkd_dhcp= \
                __networkd= \
          __netifrc_config="config_${__dev}=\"" \
          __netifrc_routes="routes_${__dev}=\"" \
                 __netifrc= \

    __networkd_match+=$'\n'"Name=${__dev}"
    for ___ip in ${__ip[@]}; do
      __networkd_address+=${__networkd_address:+$'\n\n'}"[Address]"$'\n'"Address=${___ip}"
    done
    for ___ip in ${__ip6[@]}; do
      __networkd_address6+=${__networkd_address6:+$'\n\n'}"[Address]"$'\n'"Address=${___ip}"
    done
    __networkd_route+=$'\n'"Destination=${__dst}"
    __networkd_route+=$'\n'"Gateway=${__gateway}"
    __networkd_route6+=$'\n'"Destination=${__dst6}"
    __networkd_route6+=$'\n'"Gateway=${__gateway6}"

    if [[ ${__proto6} != ra ]]; then
      __networkd_network+=$'\n'"IPv6AcceptRA=false"
    fi
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
    __networkd="${__networkd_match}"$'\n'$'\n'"${__networkd_network}"
    if [[ ${__proto} == dhcp ]]; then
      __netifrc_config+=$'\n'"dhcp"
    elif [[ ${__proto} != "" ]]; then
      __netifrc_config+=$'\n'"${__ip[@]}"
      __networkd+=$'\n'$'\n'"${__networkd_address}"
      if [[ ${__proto} =~ boot|static ]]; then
        __netifrc_routes+=$'\n'"${__dst} via ${__gateway}"
        __networkd+=$'\n'$'\n'"${__networkd_route}"
      fi
    fi
    if [[ ${__proto6} == dhcp ]]; then
      __netifrc_config+=$'\n'"dhcpv6"
    elif [[ ${__proto6} != "" ]]; then
      __netifrc_config+=$'\n'"${__ip6[@]}"
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

    if [[ ! ${STAGE3} =~ systemd ]]; then
      ln -s net.lo "${NEWROOT}/etc/init.d/net.${__dev}"
      _chroot_exec rc-update add net.${__dev} default
    fi
  done

  echo $'\n\n'"# fallback nameserver"$'\n'"nameserver 1.1.1.1" >>"${NEWROOT}/etc/resolv.conf"

  if [[ ${STAGE3} =~ systemd ]]; then
    _chroot_exec systemctl enable systemd-networkd.service
  fi
}

_config_gentoo() {
  sed -Ei -e '/PermitRootLogin/s/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' \
          -e '/AuthorizedKeysFile/s/^[#[:space:]]*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' \
          -e '/PasswordAuthentication/s/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' ${NEWROOT}/etc/ssh/sshd_config

  __config_network

  if [[ ${STAGE3} =~ systemd ]]; then
    _chroot_exec systemctl enable sshd.service
    if [[ ${_LVM_ENABLED} == 1 ]]; then
      _chroot_exec systemctl enable lvm2-monitor.service
    fi
  else
    _chroot_exec rc-update add sshd default
    if [[ ${_LVM_ENABLED} == 1 ]]; then
      _chroot_exec rc-update add lvm boot
    fi
  fi
  if [[ $(cat /root/.ssh/authorized_keys 2>/dev/null) =~ no-port-forwarding ]]; then
    echo > /root/.ssh/authorized_keys
  fi
  _chroot_exec touch /etc/machine-id
}
_config_gentoo

########################################
########################################
########################################
_LD_SO=$(ls -d ${NEWROOT}/lib64/ld-linux-*.so*)
if [[ ! -x ${_LD_SO} ]] || [[ $(${_LD_SO} --version | head -1 | cut -d' ' -f1) != "ld.so" ]]; then
  _fatal "cannot find ld.so from ${NEWROOT}/lib64/ld-linux-*.so*"
fi

WAIT=5
echo
echo
_log n "Following actions will affect the real system."
echo -en "Starting in: \e[33m\e[1m"
while [[ ${WAIT} -gt 0 ]]; do
  echo -en "${WAIT} "
  WAIT=$((${WAIT} -  1))
  sleep 1
done
echo -e "\e[0m"

_log w "Installing Grub ..."
_prepare_bootloader
sync

if [[ ${_BTRFS_ENABLED} == 1 ]]; then
  # detect btrfs readonly subvol
  while read -r _ _ _ _ _ _ _ _ __subvol_path; do
    for (( i = 0; i < ${#_BTRFS_SUBVOL[@]}; ++i )); do
      __subvol_path=${__subvol_path#<FS_TREE>}
      __subvol_path_remaining=${__subvol_path#${_BTRFS_SUBVOL[i]}}
      if [[ ${__subvol_path_remaining} != ${__subvol_path} ]]; then
        __subvol_path_readonlys+=("${_BTRFS_MP[i]}${__subvol_path_remaining}")
      fi
    done
  done <<<"$(btrfs subvolume list -ar /)"
  for __subvol_path_readonly in ${__subvol_path_readonlys[@]}; do
    _log w "'${__subvol_path_readonly}' is a readonly subvolume."
    __EXCLUDE_READONLY_SUBVOL_PATH+=" -and ! -regex '${__subvol_path_readonly}.*'"
  done

  # tune btrfs rootfs opts in /etc/fstab
  if [[ -n ${_BTRFS_SUBVOL_ROOTFS} ]]; then
    __btrfs_fstab_rootfs_subvol_sed_pattern="/subvol/!s/^([[:space:]]*[^#][^[:space:]]+[[:space:]]+\/[[:space:]]+btrfs[[:space:]]+[^[:space:]]+)[[:space:]]+([[:digit:]].+)$/\1,subvol=${_BTRFS_SUBVOL_ROOTFS//\//\\\/}  \2/"
    _log i ">>> sed -Ei '${__btrfs_fstab_rootfs_subvol_sed_pattern}' ${NEWROOT}/etc/fstab"
    eval "sed -Ei '${__btrfs_fstab_rootfs_subvol_sed_pattern}' ${NEWROOT}/etc/fstab"

    # keep the contents within the root subvol but with different path
    for (( i = 0; i < ${#_BTRFS_SUBVOL[@]}; ++i )); do
      if [[ ${_BTRFS_SUBVOL_ROOTFS} == ${_BTRFS_SUBVOL[i]} ]]; then
        continue
      fi
      __btrfs_subvol_rootfs_remaining=${_BTRFS_SUBVOL_ROOTFS#${_BTRFS_SUBVOL[i]}}
      if [[ ${__btrfs_subvol_rootfs_remaining} != ${_BTRFS_SUBVOL_ROOTFS} ]]; then
        __EXCLUDE_ROOTFS_SUBVOL_PATH=" -and ! -regex '${_BTRFS_MP[i]}${__btrfs_subvol_rootfs_remaining}.*'"
      fi
    done

  fi
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
  -and ! -regex '/sys.*' \
  -and ! -regex '/selinux.*' \
  -and ! -regex '/tmp.*' \
  ${__EXCLUDE_ROOTFS_SUBVOL_PATH} \
  ${__EXCLUDE_READONLY_SUBVOL_PATH} \
  -and ! -regex "${EFIMNT:-/4f49e86d-275b-4766-94a9-8ea680d5e2de}.*" \
  -and ! -regex "${NEWROOT}.*" \) \
  -delete || true
set +x

${_LD_SO} --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/ls" -l / || true

_magic_cp() {
  echo ">>> Merging /${1} ..."
  set -- ${_LD_SO} --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/cp" -a "${NEWROOT}/${1}" /
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

_umount_fs() {
  _log i "umounting ${NEWROOT}${1} ..."
  umount -Rf ${NEWROOT}${1} || true
}
_umount_fs /proc
_umount_fs /dev
_umount_fs /sys
_umount_fs /run
_umount_fs /boot
if [[ -n ${EFIMNT} ]]; then
  _umount_fs ${EFIMNT}
fi
_log i "removing ${NEWROOT} ..."
rm -rf ${NEWROOT} || true

_config_grub() {
  local _submenu _menuentry
  local -a _menuentries
  _log w ">>> grub-mkconfig -o /boot/grub/grub.cfg"
  grub-mkconfig -o /boot/grub/grub.cfg
  _submenu=$(awk -F\' '/submenu / {print $4}' /boot/grub/grub.cfg)
  _menuentries=( $(awk -F\' '/menuentry / {print $4}' /boot/grub/grub.cfg) )
  for __menuentry in ${_menuentries[@]}; do
    if [[ ${__menuentry} =~ gentoo-dist-adv ]]; then
      _menuentry=${__menuentry}
      break
    fi
  done
  _log w ">>> grub-set-default '${_submenu}>${_menuentry}'"
  eval "grub-set-default '${_submenu}>${_menuentry}'"
}
_config_grub

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
_log w "Unparsed         GRUB_CMDLINE_LINUX: '${_UNUNIFIED_GRUB_CMDLINE_LINUX/#[[:space:]]/}'"
_log w "Unparsed GRUB_CMDLINE_LINUX_DEFAULT: '${_UNUNIFIED_GRUB_CMDLINE_LINUX_DEFAULT/#[[:space:]]/}'"
_log w "The initramfs is generated by dracut by default, please check these opts."
echo
_log n "  1. Normal users (if exist) have been dropped (but /home directories is preserved)."
echo
_log n "  2. Old kernels and modules are preserved but are not used by default."
echo
_log n "  3. 'root' user password is preserved or set to 'distro2gentoo' if it's not set."
echo
_log n "  4. SSH server is enabled and will be listening on port 22,"
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

WAIT=30
_log n "wait to guarantee data synced for some file systems/special environment ..."
_log n "  (CTRL-C is safe in most cases)"
while [[ ${WAIT} -ge 0 ]]; do
  echo -en "\e[G\e[K  ${WAIT} "
  WAIT=$((${WAIT} -  1))
  sleep 1
done
echo
