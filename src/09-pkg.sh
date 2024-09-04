#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

declare -a _D2G_DRACUT_MODULES _D2G_ONETIME_PKGS _D2G_EXTRA_DEPS

_D2G_BINPKGS_PROFILE_VER="23.0"

_D2G_BINPKGS_CATEGORIES_AMD64_DEFAULT=1
_D2G_BINPKGS_CATEGORIES_AMD64=(
	"x32"
	"x86-64"
	"x86-64-v3"
	"x86-64_hardened"
	"x86-64_llvm"
	"x86-64_musl"
	"x86-64_musl_hardened"
	"x86-64_musl_llvm"
)

_D2G_BINPKGS_CATEGORIES_ARM64_DEFAULT=1
_D2G_BINPKGS_CATEGORIES_ARM64=(
	"aarch64_be"
	"arm64"
	"arm64_llvm"
	"arm64_musl"
	"arm64_musl_hardened"
	"arm64_musl_llvm"
)

_the_best_matched_binpkgs_category() {
	local default_index matched_index='' i stage3_category="${STAGE3_TARBALL#*stage3-}" x86_64_v3_supported=0
	local -a categories
	stage3_category="${stage3_category//-/_}"
	case "$CPUARCH" in
		amd64)
			stage3_category="${stage3_category/#amd64/x86-64}"
			categories=("${_D2G_BINPKGS_CATEGORIES_AMD64[@]}")
			default_index="$_D2G_BINPKGS_CATEGORIES_AMD64_DEFAULT"
			if ld.so --help | grep 'x86-64-v3' | grep 'supported' >/dev/null; then
				x86_64_v3_supported=1
			fi
			;;
		arm64)
			categories=("${_D2G_BINPKGS_CATEGORIES_ARM64[@]}")
			default_index="$_D2G_BINPKGS_CATEGORIES_ARM64_DEFAULT"
			;;
	esac
	for ((i=0; i<${#categories[@]}; i++)); do
		if [[ $stage3_category == ${categories[i]}* ]]; then
			matched_index="$i"
		fi
	done
	if [[ $matched_index == '' ]]; then
		matched_index="$default_index"
	fi

	# THIS IS A SPECIFIC CONDITION, PLEASE UPDATE IT CAREFULLY
	if [[ $x86_64_v3_supported == 1 && $CPUARCH == "amd64" && $matched_index == 1 ]]; then
		matched_index=2
	fi

	echo -n "${categories[$matched_index]}"
}

preparePkgsConfiguration() {
	if [[ ! ${STAGE3_TARBALL} =~ systemd ]]; then
		_D2G_EXTRA_DEPS+=("net-misc/netifrc")
	fi

	if [[ ${_D2G_LUKS_ENABLED} == 1 ]]; then
		if [[ $STAGE3_TARBALL =~ systemd ]]; then
			echo 'sys-apps/systemd cryptsetup' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
			_D2G_ONETIME_PKGS+=("sys-apps/systemd")
		fi
		_D2G_DRACUT_MODULES+=("crypt")
		echo 'sys-fs/cryptsetup -static-libs' >>"${NEWROOT}/etc/portage/package.use/cryptsetup"
		_D2G_EXTRA_DEPS+=("sys-fs/cryptsetup")
	fi
	if [[ ${_D2G_LVM_ENABLED} == 1 ]]; then
		cp -aL /etc/lvm "${NEWROOT}/etc/"
		_D2G_DRACUT_MODULES+=("lvm")
		_D2G_EXTRA_DEPS+=("sys-fs/lvm2")
	fi
	if [[ ${_D2G_BTRFS_ENABLED} == 1 ]]; then
		_D2G_DRACUT_MODULES+=("btrfs")
		_D2G_EXTRA_DEPS+=("sys-fs/btrfs-progs")
	fi
	if [[ ${BINHOST_ENABLED} == 1 ]]; then
		local _binhost_sync_uri
		_binhost_sync_uri="${MIRROR%/}/releases/${CPUARCH}/binpackages/${_D2G_BINPKGS_PROFILE_VER}/$(_the_best_matched_binpkgs_category)/"
		echo "[binhost]
priority = 9999
sync-uri = ${_binhost_sync_uri}
" >"${NEWROOT}/etc/portage/binrepos.conf/gentoobinhost.conf"
		_log w "The binhost sync-uri is set to '${_binhost_sync_uri}'"
		_D2G_BINHOST_ARGS=("--binpkg-changed-deps=y" "--getbinpkg=y" "--usepkg-exclude" "acct-*/* sys-kernel/* virtual/* */*-bin")
		_chroot_exec getuto
		# "--binpkg-respect-use=y" will override "--autounmask-use=y"
		# refs: https://bitbili.net/gentoo-linux-installation-and-usage-tutorial.html#emerge+默认选项
	fi
}

installPortageDB() {
	pushd "${NEWROOT}/var/db/repos" || _log ee "Pushd to '${NEWROOT}/var/db/repos' failed!"
	_do git clone --depth 1 "$_D2G_GIT_MIRROR" gentoo
	local commit result ret=0
	commit=$(_do git -C gentoo rev-list HEAD)
	result=$(_do git -C gentoo verify-commit --raw "$commit" 2>&1) || ret=$?
	if [[ $ret != 0 ]]; then
		_log e "Git repo verification failed!"
		_do git -C gentoo --no-pager log -1 --pretty=fuller "$commit"
		echo "${result}"
		if grep "\\[GNUPG:\\] EXPKEYSIG" <<< "$result"; then
			_log w "... but expired keys are alright..."
			ret=0
		else
			_do rm -rf gentoo
			_log e "Try emerge-webrsync instead."
			_chroot_exec emerge-webrsync
		fi
	fi
	popd || _log ee "Popd from '${NEWROOT}/var/db/repos' failed!"

	if (( ret == 0 )); then
		_chroot_exec chown -R portage:portage /var/db/repos/gentoo
		mkdir -p "${NEWROOT}/etc/portage/repos.conf"
		echo "[gentoo]
location   = /var/db/repos/gentoo
auto-sync  = yes
sync-type  = git
sync-depth = 1
sync-uri   = $_D2G_GIT_MIRROR
sync-git-verify-commit-signature = yes
" >"${NEWROOT}/etc/portage/repos.conf/gentoo.conf"
		_chroot_exec chown -R root:root "/etc/portage/repos.conf"
		_D2G_EXTRA_DEPS+=( "dev-vcs/git" )
	fi
}

installNecessaryPkgs() {
	local _nproc emerge_opts=("--autounmask=y" "--autounmask-license=y" "--autounmask-use=y" "--autounmask-write=y" "--autounmask-continue=y" "-vj")
	_nproc=$(nproc)

	if (( ${#_D2G_ONETIME_PKGS[@]} > 0 )); then
		_chroot_exec 'DONT_MOUNT_BOOT=1' emerge -l "$_nproc" -1 "${emerge_opts[@]}" "${_D2G_BINHOST_ARGS[@]}" "${_D2G_ONETIME_PKGS[@]}"
	fi

	# install necessary pkgs
	mkdir -p "${NEWROOT}/etc/portage/package.license"
	echo 'sys-kernel/linux-firmware linux-fw-redistributable no-source-code' \
		>"${NEWROOT}/etc/portage/package.license/linux-firmware"
	echo 'sys-boot/grub mount' >>"${NEWROOT}/etc/portage/package.use/bootloader"
	_chroot_exec 'DONT_MOUNT_BOOT=1' emerge -l "$_nproc" -n "${emerge_opts[@]}" "${_D2G_BINHOST_ARGS[@]}" \
		linux-firmware gentoo-kernel-bin sys-boot/grub sys-boot/os-prober net-misc/openssh "${_D2G_EXTRA_DEPS[@]}"

	# regenerate initramfs
	if (( ${#_D2G_DRACUT_MODULES[@]} > 0 )); then
		mkdir -p "${NEWROOT}/etc/dracut.conf.d"
		echo "add_dracutmodules+=\"${_D2G_DRACUT_MODULES[*]} \"" >>"${NEWROOT}/etc/dracut.conf.d/distro2gentoo.conf"
		_chroot_exec 'DONT_MOUNT_BOOT=1' emerge --config sys-kernel/gentoo-kernel-bin
	fi
}

