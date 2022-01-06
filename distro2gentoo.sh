#!/usr/bin/env bash
#
# @cwittlut
#

set -e
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
      _log e "New root path '${NEWROOT}' exists, umount it's subdirs and remove it first!"
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
  _COMMANDS+=" wget"
fi

_cat() {
  eval "${_DOWNLOAD_CMD_QUIET} '${1}'"
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

_COMMANDS="awk bc findmnt gpg ip openssl wc xmllint tr sort"

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

_install_deps() {
  #TODO

  function __install_pkg() {
    local -i _ret=0
    local __command=${1}
    if command -v apt >/dev/null; then
      eval "apt -y install \${PKG_${__command}[apt]}" || _ret=1
    elif command -v dnf >/dev/null; then
      eval "dnf -y install \${PKG_${__command}[dnf]}" || _ret=1
    elif command -v yum >/dev/null; then
      eval "yum -y install \${PKG_${__command}[dnf]}" || _ret=1
    elif command -v pacman >/dev/null; then
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
  local _country_code=$(_cat 'https://ip2c.org/self' | cut -d';' -f2)
  local _mirrors
  if [[ $(xmllint --version 2>&1 | head -1 | cut -d' ' -f5) -ge 20909 ]]; then
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
  gpg --quiet --keyserver hkps://keys.gentoo.org --recv-key 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910
  # prepare signed DIGESTS
  DIGESTS="/${_stages[${_selected}]}.DIGESTS.asc"
  if [[ ! -e ${DIGESTS} ]]; then
    eval "_download '${_list%/*}/${_stages_path[${_selected}]}.DIGESTS.asc' '${DIGESTS}'"
  fi
  _log i "Checking ${DIGESTS} ..."
  gpg --verify ${DIGESTS} || _fatal "Verify signature failed!"
  # get sha512sum of the stage3 tarball
  local _sha512sum
  while read -r __sha512sum _; do
    if [[ ${__sha512sum} != "#" ]]; then
      _sha512sum=${__sha512sum}
      break
    fi
  done <<<"$(grep -A1 'SHA512' ${DIGESTS})"
  # prepare stage3 tarball
  STAGE3="/${_stages[${_selected}]}"
  if [[ ! -e ${STAGE3} ]]; then
    eval "_download '${_list%/*}/${_stages_path[${_selected}]}' '${STAGE3}'"
  fi
  local _real_sha512sum
  _real_sha512sum=$(sha512sum ${STAGE3} | cut -d' ' -f1)
  if [[ ${_sha512sum} != ${_real_sha512sum} ]]; then
    _log e "Unmatched sha512sum of ${STAGE3}"
    _log e "  recorded: ${_sha512sum}"
    _log e "      real: ${_real_sha512sum}"
    _fatal "Abort!"
  fi
  _log i "Matched sha512sum of ${STAGE3}"
  _log i "Stage3 tarball has been stored as '${STAGE3}'."
}

_unpack_stage3() {
  pushd ${NEWROOT}
  _log w ">>> tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner"
  tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner
  popd
}

declare -a _FS_PATHS _FS_UUIDS _FS_MPS _FS_TYPES _FS_OPTS
_LVM_ENABLED=0
_LUKS_ENABLED=0
_BTRFS_ENABLED=0
__analyze_fstab() {
  while read -r _fs _mp _type _opts _; do
    if [[ ! ${_fs} =~ ^# ]]; then
      if [[ ${_fs} =~ ^UUID ]]; then
        _FS_UUIDS+=("${_fs}")
        _FS_PATHS+=("UNSET")
      else
        _FS_UUIDS+=("UNSET")
        _FS_PATHS+=("${_fs}")
      fi
      _FS_MPS+=("${_mp}")
      _FS_TYPES+=("${_type}")
      _FS_OPTS+=("${_opts}")
    fi
  done <"${NEWROOT}/etc/fstab"
  while read -r _name _type _mp; do
    case ${_type} in
      crypt)
        _LUKS_ENABLED=1
        _LUKS_ROOTS+=("${_name}")
        ;;
      lvm)
        _LVM_ENABLED=1
        _LVM_LVS+=("${_name}")
        ;;
      part)
        :
        ;;
      *)
        :
        ;;
    esac
  done <<<"$(lsblk -lpnoNAME,TYPE,MOUNTPOINT)"
  local -i i
  for (( i = 0; i < ${#_FS_TYPES[@]}; ++i )); do
    if [[ ${_FS_TYPES[i]} == btrfs ]]; then
      if [[ ${_FS_MPS[i]} =~ ^(/$|/usr|/lib|/var) ]]; then
        _BTRFS_ENABLED=1
      fi
    fi
  done
}

# $1: result variable name
# $2...: cmdline opts
#TODO more options
___unify_cmdline_opts() {
  local _name=${1} _opts _opt _opt_r _tmpv _tmpv_luks_name _tmpv_luks_names
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
        while read -r _lv _vg _; do
          if [[ ${_lv} != "LV" ]]; then
            break;
          elif [[ ${_opt_r} =~ rd\.lvm ]]; then
            _log e "Unexpected error: 'rd.lvm*' and 'dolvm' exist at the same time."
            break
          else
            continue
          fi
          _opt_r+=" rd.lvm.lv=${_vg}/${_lv}"
        done <<<"$(lvdisplay -Co lv_name,vg_name)"
        ;;
      rd.lvm.vg=*)
          _opt_r+=" ${_opt}"
        ;;
      rd.lvm.lv=*)
          _opt_r+=" ${_opt}"
        ;;
      crypt_root=*)
        if [[ ${_opt_r} =~ rd\.luks ]]; then
          _log e "Unexpected error: 'rd.luks*' and 'crypt_root' exist at the same time."
          continue
        fi
        _opt_r+=" rd.luks.uuid=${_opt/#crypt_root=UUID=/}"
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
        if [[ ${_tmpv} =~ ^[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{12}$ ]]; then
          _opt_r+=" rd.luks.uuid=${_tmpv}"
        else
          _log e "Unrecognized cmdline option: ${_opt}"
        fi
        ;;
      luks.name=*|rd.luks.name=*)
        _tmpv=${_opt/#*luks.uuid=/}
        _tmpv=${_tmpv/#luks-/}
        _tmpv_luks_name=${_tmpv/#*=/}
        _tmpv=${_tmpv/%=*/}
        if [[ ${_tmpv} =~ ^[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{12}$ ]]; then
          _opt_r+=" rd.luks.uuid=${_tmpv}"
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
        if [[ ${_tmpv} =~ ^[[:alnum:]]{8}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{4}-[[:alnum:]]{12}= ]]; then
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
  eval "${_name}='${_opt_r/#[[:space:]]/}'"
}

_GRUB_CMDLINE_LINUX=''
_GRUB_CMDLINE_LINUX_DEFAULT=''
__set_grub_cmdline() {
  local _cmdline _cmdline_default _cmdline_array _cmdline_default_array
  cp -aL /etc/default/grub "${NEWROOT}/etc/default/._old_grub"
  _cmdline="$(. /etc/default/grub; echo ${GRUB_CMDLINE_LINUX})"
  _cmdline="${_cmdline//quiet/}"
  _cmdline="${_cmdline//splash/}"
  _cmdline_array=( ${_cmdline//rhgb/} )
  ___unify_cmdline_opts _GRUB_CMDLINE_LINUX ${_cmdline_array[@]}

  _cmdline_default="$(. /etc/default/grub; echo ${GRUB_CMDLINE_LINUX_DEFAULT})"
  _cmdline_default="${_cmdline_default//quiet/}"
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
  mount --bind /boot "${NEWROOT}/boot"
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

_prepare_env() {
  CPUARCH=$(uname -m)
  CPUARCH=${CPUARCH/x86_64/amd64}
  CPUARCH=${CPUARCH/aarch64/arm64}
  NEWROOT="/root.d2g.${CPUARCH}"
  _pre_check
  mkdir -p "${NEWROOT}"
  _install_deps
  _get_mirror
  _get_stage3
  _unpack_stage3
  _ready_chroot
}
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
      if [[ ${EFIMNT} == "" ]]; then
        EFIMNT=$(findmnt --fstab -nlt vfat -oTARGET -S${EFIDEV})
      fi
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
}
_prepare_pkgs_configuration

[[ -z ${ONETIME_PKGS} ]] || \
  _chroot_exec emerge -1vj ${ONETIME_PKGS}

# install necessary pkgs
mkdir -p ${NEWROOT}/etc/portage/package.license
echo 'sys-kernel/linux-firmware linux-fw-redistributable no-source-code' \
  >${NEWROOT}/etc/portage/package.license/linux-firmware
_chroot_exec emerge -vnj linux-firmware gentoo-kernel-bin sys-boot/grub net-misc/openssh ${EXTRA_DEPS}

# regenerate initramfs
if [[ -n ${_DRACUT_MODULES} ]]; then
  echo "add_dracutmodules+=\"${_DRACUT_MODULES} \"" >>"${NEWROOT}/etc/dracut.conf.d/distro2gentoo.conf"
  _chroot_exec emerge --config sys-kernel/gentoo-kernel-bin
fi

_prepare_bootloader

_config_gentoo() {
  sed -Ei -e '/PermitRootLogin/s/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' \
          -e '/AuthorizedKeysFile/s/^[#[:space:]]*AuthorizedKeysFile.*/AuthorizedKeysFile .ssh\/authorized_keys/' \
          -e '/PasswordAuthentication/s/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' ${NEWROOT}/etc/ssh/sshd_config
  local _netgateway _netdev _netproto
  read -r _ _ _ _netgateway _ _netdev _ _netproto _ <<<$(ip -d -o r show type unicast scope global | head -1)
  if [[ ${_netproto} != dhcp ]]; then
    local -a _netip _netip6
    while read -r _ _ __ipver __ip _; do
      if [[ ${__ipver} == inet ]]; then
        _netip+=( ${__ip} )
      else
        _netip6+=( ${__ip} )
      fi
    done <<<"$(ip -d -o a show dev ${_netdev} scope global)"
  fi
  if [[ ${STAGE3} =~ systemd ]]; then
    if [[ ${_netproto} != dhcp ]]; then
      echo "[Match]
Name=${_netdev}

[Network]
DHCP=no
IPv6AcceptRA=false" >${NEWROOT}/etc/systemd/network/50-static.network
      for __netip in ${_netip[@]} ${_netip6[@]}; do
        echo "Address=${__netip}" >>${NEWROOT}/etc/systemd/network/50-static.network
      done
      echo "Gateway=${_netgateway}" >>${NEWROOT}/etc/systemd/network/50-static.network
    else
      echo "[Match]
Name=${_netdev}

[Network]
DHCP=yes" >${NEWROOT}/etc/systemd/network/50-dhcp.network
    fi
    _chroot_exec systemctl enable sshd.service
    _chroot_exec systemctl enable systemd-networkd.service

    if [[ ${_LVM_ENABLED} == 1 ]]; then
      _chroot_exec systemctl enable lvm2-monitor.service
    fi
  else
    if [[ ${_netproto} != dhcp ]]; then
      echo "config_${_netdev}=\"${_netip[@]} ${_netip6}\"" > ${NEWROOT}/etc/conf.d/net
      echo "routes_${_netdev}=\"default via ${_netgateway}\"" >> ${NEWROOT}/etc/conf.d/net
    else
      echo "config_${_netdev}=\"dhcp\"" > ${NEWROOT}/etc/conf.d/net
    fi
    _chroot_exec rc-update add sshd default
    ln -s net.lo ${NEWROOT}/etc/init.d/net.${_netdev}
    _chroot_exec rc-update add net.${_netdev} default

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

sync
_log w "Deleting old system files ..."
set -x
"${NEWROOT}/lib64"/ld-*.so --library-path "${NEWROOT}/lib64" "${NEWROOT}/usr/bin/find" / \( ! -path '/' \
  -and ! -regex '/boot.*' \
  -and ! -regex '/dev.*' \
  -and ! -regex '/home.*' \
  -and ! -regex '/proc.*' \
  -and ! -regex '/root.*' \
  -and ! -regex '/run.*' \
  -and ! -regex '/sys.*' \
  -and ! -regex '/selinux.*' \
  -and ! -regex '/tmp.*' \
  -and ! -regex "${EFIMNT:-/4f49e86d-275b-4766-94a9-8ea680d5e2de}.*" \
  -and ! -regex "${NEWROOT}.*" \) \
  -delete || true
set +x

_magic_cp() {
  echo ">>> Merging /${1} ..."
  local _subdir
  if [[ ${1} =~ / ]]; then
    _subdir=${1%/*}
  fi
  "${NEWROOT}/lib64"/ld-*.so --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/cp" -a "${NEWROOT}/${1}" /${_subdir} || true
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
