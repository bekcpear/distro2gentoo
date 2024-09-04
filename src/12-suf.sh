#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

parseParams "$@"

prerequisitesCheck
firstTip

mkdir -p "${NEWROOT}"
prerequisitesSolve

setupMirror

getStage3
unpackStage3ToNEWROOT

prepareChroot

setupGRUBCmdline

preparePkgsConfiguration
installPortageDB
installNecessaryPkgs

_config_gentoo() {
	local fileForPermitRootLogin fileForAuthorizedKeysFile fileForPasswordAuthentication
	local patForPermitRootLogin='^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]][[:alpha:]-]+$'
	local patForAuthorizedKeysFile='^[[:space:]]*#?[[:space:]]*AuthorizedKeysFile[[:space:]][[:alpha:]-]+$'
	local patForPasswordAuthentication='^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]][[:alpha:]-]+$'

	__file_for() {
		local _line
		if _line=$(grep -r -E "$1" "${NEWROOT}/etc/ssh/sshd_config.d/"); then
			echo "$_line" | cut -d':' -f1 | tail -1
		elif grep -E "$1" "$NEWROOT/etc/ssh/sshd_config" &>/dev/null; then
			echo "$NEWROOT/etc/ssh/sshd_config"
		else
			echo -n ""
		fi
	}

	local var
	for var in PermitRootLogin AuthorizedKeysFile PasswordAuthentication; do
		local fileFor="fileFor${var}" patFor="patFor${var}"
		eval "${fileFor}='$(__file_for "${!patFor}")'"
		if [[ ${!fileFor} != "" ]]; then
			local replaced_str="${var} yes"
			if [[ $var == "AuthorizedKeysFile" ]]; then
				replaced_str="${var} .ssh/authorized_keys"
			fi
			sed -Ei "/${!patFor}/s@${!patFor}@${replaced_str}@" "${!fileFor}"
		else
			echo $'\n'"$replaced_str" >>"${NEWROOT}/etc/ssh/sshd_config"
		fi
	done

	configNetwork

	if [[ $STAGE3_TARBALL =~ systemd ]]; then
		_chroot_exec systemctl enable sshd.service

		if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
			_chroot_exec systemctl enable lvm2-monitor.service
		fi
	else
		_chroot_exec rc-update add sshd default

		if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
			_chroot_exec rc-update add lvm boot
		fi
	fi

	
	# remove the extra "command" opts from root user's authorized_keys
	# some distributions set "exit" in the "command" opts
	sed -Ei 's#(^|,)command=.*[[:space:]](sk-ecdsa-sha2-nistp256@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|ssh-ed25519|ssh-dss|ssh-rsa)# \2#' /root/.ssh/authorized_keys
	sed -Ei 's#^ ##' /root/.ssh/authorized_keys

	_chroot_exec touch /etc/machine-id
}
_config_gentoo


########################################
########################################
########################################
_LD_SO=$(ls -d "$NEWROOT"/lib64/ld-linux-*.so*)
if [[ ! -x ${_LD_SO} ]] || [[ $(${_LD_SO} --version | head -1 | cut -d' ' -f1) != "ld.so" ]]; then
	_log ee "cannot find ld.so from ${NEWROOT}/lib64/ld-linux-*.so*"
fi

WAIT=5
echo
echo
_log w "Following actions will affect the real system."
echo -en "Starting in: \e[33m\e[1m"
while [[ ${WAIT} -gt 0 ]]; do
	echo -en "${WAIT} "
	WAIT=$((${WAIT} -  1))
	sleep 1
done
echo -e "\e[0m"

_log w "Installing Grub ..."
installGRUB
sync

if [[ ${_D2G_BTRFS_ENABLED} == 1 ]]; then
	prepareBtrfsStuffs
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
	-and ! -regex '/selinux.*' \
	-and ! -regex '/snap.*' \
	-and ! -regex '/sys.*' \
	-and ! -regex '/tmp.*' \
	$_D2G_EXCLUDED_READONLY_SUBVOL_PATH_OPTS \
	-and ! -regex "${EFIMNT:-/4f49e86d-275b-4766-94a9-8ea680d5e2de}.*" \
	-and ! -regex "${NEWROOT}.*" \) \
	-delete || true
set +x

${_LD_SO} --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/ls" -l / || true

_magic_cp() {
	echo ">>> Merging /${1} ..."
	set -- "$_LD_SO" --library-path "${NEWROOT}/lib64" "${NEWROOT}/bin/cp" -a "${NEWROOT}/${1}" /
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
sync

_D2G_ALL_UMOUNTED=1
_umount_fs() {
	local tries=3
	__umount() {
		if findmnt "${NEWROOT}${1}" >/dev/null; then
			_log i "umounting ${NEWROOT}${1} ..."
			umount -Rf "${NEWROOT}${1}"
		else
			_log i "${NEWROOT}/${1} is already umounted."
		fi
	}
	while ! __umount "$1"; do
		if (( tries < 1 )); then
			_log e "umount '${NEWROOT}${1}' failed!"
			_D2G_ALL_UMOUNTED=0
			break
		fi
		tries=$((tries - 1))

		_log w "terminating processes that are opening files in '${NEWROOT}${1}' ..."
		local _user _pid _access _cmd
		while read -r _user _pid _access _cmd; do
			if [[ $_access =~ ^[F|f] ]]; then
				if [[ $_pid =~ ^[[:digit:]]+$ ]] && (( _pid > 50 )); then
					_log w "terminating $_pid ..."
					kill -SIGTERM "$_pid"
				fi
			fi
		done <<<"$(fuser -vm "${NEWROOT}${1}" 2>&1)"

		_log w "umounting ${NEWROOT}${1} again after 3 seconds ..."
		sleep 3
	done
}
_umount_fs /proc
_umount_fs /dev
_umount_fs /sys
_umount_fs /run
_umount_fs /boot
if [[ -n $EFIMNT ]]; then
	_umount_fs "$EFIMNT"
fi
if [[ $_D2G_ALL_UMOUNTED == 1 ]]; then
	_log i "removing ${NEWROOT} ..."
	rm -rf "$NEWROOT" || true
fi

ConfigureGRUB || true

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
_log w "Unparsed         GRUB_CMDLINE_LINUX: '${D2G_UNUNIFIED_GRUB_CMDLINE_LINUX/#[[:space:]]/}'"
_log w "Unparsed GRUB_CMDLINE_LINUX_DEFAULT: '${D2G_UNUNIFIED_GRUB_CMDLINE_LINUX_DEFAULT/#[[:space:]]/}'"
_log w "The initramfs is generated by dracut by default, please check these opts."
echo
_log n "  1. Normal users (if exist) have been dropped (but /home directories is preserved)."
echo
_log n "  2. Old kernels and modules are preserved but are not used by default."
echo
_log n "  3. 'root' user password is preserved or set to 'distro2gentoo' if it's not set."
echo
_log n "  4. the /root directory is also preserved (please check the /root/.ssh/authorized_keys file)."
echo
_log n "  5. SSH server is enabled and will be listening on port 22,"
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
if [[ $_D2G_ALL_UMOUNTED == 0 ]]; then
	_log w "You should delete the '$NEWROOT' after reboot manually due to some mountpoints cannot be umounted!"
	echo
fi
if [[ $GRUB_CONFIGURED == 0 ]]; then
	_log e "!!!!!!!!!!!!!!!"
	_log e "The GRUB bootloader configuration failed!"
	_log e "You should install a bootloader manually!"
	_log e "!!!!!!!!!!!!!!!"
	echo
fi

WAIT=30
_log n "wait to guarantee data synced for some file systems/special environment ..."
_log n "  (CTRL-C is safe in most cases)"
while [[ $WAIT -ge 0 ]]; do
	echo -en "\e[G\e[K  $WAIT "
	WAIT=$((WAIT -  1))
	sleep 1
done
echo

