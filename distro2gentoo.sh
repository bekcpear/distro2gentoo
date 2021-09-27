#!/usr/bin/env bash
#
# @cwittlut
#

set -e

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
    eval ">${ofd} echo -e '${color}${prefix}${msg//\'/\'\\\'\'}${reset}'"
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
  # check cpu arch (only tested for arm64/amd64 now)
  [[ ${CPUARCH} =~ ^amd64$ ]] || _ret=${_ret:0:1}1${_ret:2}
  # check newroot dir
  [[ -L ${NEWROOT} || -e ${NEWROOT} ]] && _ret=${_ret:0:2}1 || true
  case ${_ret} in
    1*)
      _log e "Please run this shell as the root user!"
      ;;&
    ?1?)
      _log e "This script only tested for amd64 arch now!"
      ;;&
    *1)
      _log e "New root path '${NEWROOT}' exists, remove it first!"
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

_COMMANDS="bc findmnt gpg ip openssl wc xmllint"
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

declare -A -g PKG_xmllint PKG_gpg
PKG_xmllint[apt]="libxml2-utils"
PKG_xmllint[dnf]="libxml2"
PKG_xmllint[pacman]="libxml2"
PKG_gpg[apt]="gnupg"
PKG_gpg[dnf]="gnupg2"
PKG_gpg[pacman]="gnupg"
PKG_bc[apt]="bc"
PKG_bc[dnf]="bc"
PKG_bc[pacman]="bc"
_install_deps() {
  #TODO
  _log w "Make sure commands '${_COMMANDS[@]}' are available!"
  local __commands="bc gpg xmllint"
  for __command in ${__commands}; do
    if ! command -v ${__command} >/dev/null; then
      if command -v apt >/dev/null; then
        eval "apt -y install \${PKG_${__command}[apt]}"
      elif command -v dnf >/dev/null; then
        eval "dnf -y install \${PKG_${__command}[dnf]}"
      elif command -v yum >/dev/null; then
        eval "yum -y install \${PKG_${__command}[dnf]}"
      elif command -v pacman >/dev/null; then
        eval "pacman --noconfirm -S \${PKG_${__command}[pacman]}"
      fi
    fi
  done
}

_get_mirror() {
  _log i "Setting mirror ..."
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
  _mirrors=( ${_mirrors} )
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
    [[ ${_path} != "#" ]] || continue
    _stages+=( "${_path##*/}" )
    _stages_path+=( "${_path}" )
  done <<<$(_cat "${_list}")
  _log n "stage3 list:"
  for (( i = 0; i < ${#_stages[@]}; ++i )); do
    local _stage=${_stages[i]}
    if [[ ! ${_stage} =~ ^stage3 ]]; then
      unset _stages[i]
      continue
    fi
    if [[ ${_stage} =~ ^stage3-amd64-openrc- ]]; then
      _selected=${i}
      _log n " -*-[${i}] ${_stage}"
    else
      _log n "    [${i}] ${_stage}"
    fi
  done
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
  done <<<$(grep -A1 'SHA512' ${DIGESTS})
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
  _log i "Stage3 tarball has been stored as '${STAGE3}'."
}

_unpack_stage3() {
  pushd ${NEWROOT}
  _log w ">>> tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner"
  tar xpf ${STAGE3} --xattrs-include='*.*' --numeric-owner
  popd
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
  cp -aL /etc/hostname "${NEWROOT}/etc/" || true
  cp -aL /lib/modules "${NEWROOT}/lib/" || true
  local rootshadow=$(grep -E '^root:' /etc/shadow)
  if [[ ${rootshadow} =~ ^root:\*: ]]; then
    _log i "setting root password to 'distro2gentoo' ..."
    local _newpass=$(openssl passwd -6 distro2gentoo)
    local _newday=$(echo `date +%s`/24/60/60 | bc)
  else
    _log i "backuping root password ..."
    local _newpass=$(echo ${rootshadow} | cut -d':' -f2)
    local _newday=$(echo ${rootshadow} | cut -d':' -f3)
  fi
  eval "sed -Ei '/root:\*:.*/s@root:\*:[[:digit:]]+:@root:${_newpass}:${_newday}:@' '${NEWROOT}/etc/shadow'"
  echo "GRUB_PLATFORMS=\"efi-64 pc\"" >> "${NEWROOT}/etc/portage/make.conf"
  echo "GENTOO_MIRRORS=\"${MIRROR}\"" >> "${NEWROOT}/etc/portage/make.conf"
  # kmod USE+zstd when it's Arch Linux
  if grep -E '^ID=arch$' /etc/os-release &>/dev/null; then
    local _use_path="${NEWROOT}/etc/portage/package.use"
    if [[ -f "${_use_path}" ]]; then
      echo "sys-apps/kmod zstd" >>"${_use_path}"
    else
      mkdir -p "${_use_path}"
      echo "sys-apps/kmod zstd" >>"${_use_path}/kmod"
    fi
    ONETIME_PKGS="sys-apps/kmod"
  fi
}

_prepare_env() {
  CPUARCH=$(uname -m)
  CPUARCH=${CPUARCH/x86_64/amd64}
  NEWROOT="/root.d2g.${CPUARCH}"
  _pre_check
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
  local _grub_configed=0
  # find the boot device
  mount /boot || true
  local _bootdev
  if _bootdev=$(findmnt -no SOURCE /boot); then
    _log i ">>> mount --bind /boot ${NEWROOT}/boot"
    mount --bind /boot "${NEWROOT}/boot"
  else
    _bootdev=$(findmnt -no SOURCE /)
  fi
  _bootdev=$(lsblk -npsro TYPE,NAME "${_bootdev}" | awk '($1 == "disk") { print $2}')
  if [[ ! ${_bootdev} =~ ^/dev/mapper ]]; then
    _chroot_exec grub-install --target=i386-pc ${_bootdev} && \
    _grub_configed=1 || true
  fi
  # prepare efi
  if [[ -n ${EFI_ENABLED} ]]; then
    # fuzzy matching a possibile efi partition
    local _efidevs="$(grep '[[:space:]]vfat[[:space:]]' /etc/fstab | grep -Ev '^#')"
    if [[ $(<<<"${_efidevs}" wc -l) -gt 1 ]]; then
      while read -r _ _efidev_m _; do
        if [[ ${_efidev_m} =~ [eE][fF][iI] ]]; then
          EFIMNT=${_efidev_m}
          break
        elif [[ ${_efidev_m} =~ [bB][oO][oO][tT] ]]; then
          EFIMNT=${_efidev_m}
        fi
      done <<<"${_efidevs}"
    else
      read -r _ EFIMNT _ <<<"${_efidevs}"
    fi
    if [[ -n ${EFIMNT} ]] ;then
      mkdir -p "${NEWROOT}${EFIMNT}"
      _log i ">>> mount --bind ${EFIMNT} ${NEWROOT}${EFIMNT}"
      mount --bind ${EFIMNT} "${NEWROOT}${EFIMNT}"
      _chroot_exec grub-install --target=x86_64-efi --efi-directory=${EFIMNT} --bootloader-id=Gentoo
      _chroot_exec grub-install --target=x86_64-efi --efi-directory=${EFIMNT} --removable
      _grub_configed=1
    else
      _log e "Cannot find efi path!"
    fi
  fi
  if [[ ${_grub_configed} == 0 ]]; then
    _fatal "Grub install failed! (LVM not supported yet)"
  fi
}

if [[ ! ${STAGE3} =~ systemd ]]; then
  OPENRC_NETDEP="net-misc/netifrc"
fi
_chroot_exec emerge-webrsync
[[ -z ${ONETIME_PKGS} ]] || \
  _chroot_exec emerge -1vj ${ONETIME_PKGS}
_chroot_exec emerge -vnj sys-boot/grub net-misc/openssh ${OPENRC_NETDEP}
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
    done <<<$(ip -d -o a show dev ${_netdev} scope global)
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
  fi
  if [[ $(cat /root/.ssh/authorized_keys 2>/dev/null) =~ no-port-forwarding ]]; then
    echo > /root/.ssh/authorized_keys
  fi
}
_config_gentoo

_log w "Deleting old system files ..."
find / \( ! -path '/boot/*' \
  -and ! -path '/dev/*' \
  -and ! -path '/home/*' \
  -and ! -path '/proc/*' \
  -and ! -path '/root/*' \
  -and ! -path '/run/*' \
  -and ! -path '/sys/*' \
  -and ! -path '/selinux/*' \
  -and ! -path "${NEWROOT}/*" \) -delete 2>/dev/null || true

_magic_cp() {
  echo ">>> Merging ${1} ..."
  local _subdir
  if [[ ${1} =~ / ]]; then
    _subdir=${1%/*}
  fi
  "${NEWROOT}/lib64"/ld-*.so --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/cp" -a "${NEWROOT}/${1}" /${_subdir} || true
}
_magic_cp bin
if ! "${NEWROOT}/lib64"/ld-*.so --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/findmnt" /boot &>/dev/null; then
  "${NEWROOT}/lib64"/ld-*.so --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/rm" -rf /boot/grub
  _magic_cp boot/grub
fi
_magic_cp sbin
_magic_cp etc
_magic_cp lib
_magic_cp lib64
_magic_cp mnt
_magic_cp opt
_magic_cp tmp
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

_log i ">>> grub-mkconfig -o /boot/grub/grub.cfg"
grub-mkconfig -o /boot/grub/grub.cfg
_log i "Syncing ..."
sync
_log w "Finished!"
echo
_log n "  Normal users (if any) have been dropped (home directories is preserved)."
_log n "  root password is preserved or 'distro2gentoo' if it's not set."
_log n "  ssh server enabled and listened at port 22, can be connected by root user with password authentication."
_log n "  run:"
_log n "    # . /etc/profile"
_log n "  to enter the new environment."
_log n "  reboot:"
_log n "    # echo b >/proc/sysrq-trigger"
_log n "  and Enjoy Gentoo!"
echo

