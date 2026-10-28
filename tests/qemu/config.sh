# Shared configuration for the QEMU end-to-end test harness for distro2gentoo.
# Source this file; do not execute it directly.
#
# Architecture selection (override for cross-arch runs):
#   D2G_ARCH=aarch64|x86_64   (default: uname -m mapped to one of these)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# --- architecture ----------------------------------------------------------
case "${D2G_ARCH:-$(uname -m)}" in
	arm64|aarch64) D2G_ARCH=aarch64; STAGE3_ARCH=arm64 ;;
	x86_64|amd64)  D2G_ARCH=x86_64; STAGE3_ARCH=amd64 ;;
	*) echo "unsupported arch: ${D2G_ARCH}" >&2; exit 1 ;;
esac

# --- host OS ----------------------------------------------------------------
case "$(uname -s)" in
	Darwin) HOST_OS=darwin ;;
	Linux)  HOST_OS=linux ;;
	*) echo "unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

# print the first existing path from the candidate list (empty if none)
_first_existing() {
	local p
	for p in "$@"; do
		[[ -f $p ]] && { printf '%s' "$p"; return 0; }
	done
}

# KVM is usable from Linux only, when host and guest arches match and the
# current user can open /dev/kvm (typically: membership of the 'kvm' group).
_kvm_usable() {
	[[ $HOST_OS == linux ]] || return 1
	case "$(uname -m)" in
		arm64|aarch64) [[ $D2G_ARCH == aarch64 ]] || return 1 ;;
		x86_64|amd64)  [[ $D2G_ARCH == x86_64 ]]  || return 1 ;;
		*) return 1 ;;
	esac
	[[ -r /dev/kvm && -w /dev/kvm ]]
}

# --- host tools, firmware, accelerator -------------------------------------
# All values honor environment overrides (QEMU_BIN/QEMU_IMG/FW/FW_VARS_TEMPLATE,
# D2G_MACHINE/D2G_ACCEL/D2G_CPU).
if [[ $HOST_OS == darwin ]]; then
	# Homebrew layout on Apple Silicon
	QEMU_IMG="${QEMU_IMG:-/opt/homebrew/bin/qemu-img}"
	if [[ $D2G_ARCH == aarch64 ]]; then
		QEMU_BIN="${QEMU_BIN:-/opt/homebrew/bin/qemu-system-aarch64}"
		FW="${FW:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
		# a writable copy of the aarch64 code fd works as the per-VM EFI
		# vars template (Homebrew ships no separate aarch64 vars image).
		FW_VARS_TEMPLATE="${FW_VARS_TEMPLATE:-$FW}"
	else
		QEMU_BIN="${QEMU_BIN:-/opt/homebrew/bin/qemu-system-x86_64}"
		FW="${FW:-/opt/homebrew/share/qemu/edk2-x86_64-code.fd}"
		# Homebrew ships a single OVMF code fd (no separate vars image);
		# the VM layer copies it as the writable vars slot, which boots
		# fine and lets efibootmgr register entries.
		FW_VARS_TEMPLATE="${FW_VARS_TEMPLATE:-$FW}"
	fi
else
	# Linux: QEMU and EDK2 come from distribution packages; binaries are
	# resolved from PATH and firmware from the standard EDK2 locations.
	QEMU_IMG="${QEMU_IMG:-qemu-img}"
	QEMU_BIN="${QEMU_BIN:-qemu-system-$D2G_ARCH}"
	if [[ $D2G_ARCH == aarch64 ]]; then
		FW="${FW:-$(_first_existing \
			/usr/share/AAVMF/AAVMF_CODE.fd \
			/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw \
			/usr/share/edk2/aarch64/QEMU_EFI.fd \
			/usr/share/qemu/aavmf-aarch64-code.bin)}"
		FW_VARS_TEMPLATE="${FW_VARS_TEMPLATE:-$(_first_existing \
			/usr/share/AAVMF/AAVMF_VARS.fd \
			/usr/share/edk2/aarch64/vars-template-pflash.raw \
			/usr/share/edk2/aarch64/QEMU_VARS.fd \
			/usr/share/qemu/aavmf-aarch64-suse-vars.bin \
			/usr/share/qemu/aavmf-aarch64-vars.bin)}"
	else
		FW="${FW:-$(_first_existing \
			/usr/share/OVMF/OVMF_CODE.fd \
			/usr/share/edk2/ovmf/OVMF_CODE.fd \
			/usr/share/OVMF/x64/OVMF_CODE.fd \
			/usr/share/qemu/ovmf-x86_64-code.bin)}"
		FW_VARS_TEMPLATE="${FW_VARS_TEMPLATE:-$(_first_existing \
			/usr/share/OVMF/OVMF_VARS.fd \
			/usr/share/edk2/ovmf/OVMF_VARS.fd \
			/usr/share/OVMF/x64/OVMF_VARS.fd \
			/usr/share/qemu/ovmf-x86_64-vars.bin)}"
	fi
fi
# Fall back to a writable copy of the code fd when no dedicated vars image
# exists (same behaviour the Homebrew setup relies on).
: "${FW_VARS_TEMPLATE:=$FW}"

# Machine type follows the guest arch; accel/cpu follow the host.
if [[ $D2G_ARCH == aarch64 ]]; then
	D2G_MACHINE="${D2G_MACHINE:-virt}"
	if [[ $HOST_OS == darwin ]]; then
		D2G_ACCEL="${D2G_ACCEL:-hvf}"
	elif _kvm_usable; then
		D2G_ACCEL="${D2G_ACCEL:-kvm}"
	else
		D2G_ACCEL="${D2G_ACCEL:-tcg,thread=multi}"
	fi
else
	D2G_MACHINE="${D2G_MACHINE:-q35}"
	if _kvm_usable; then
		D2G_ACCEL="${D2G_ACCEL:-kvm}"
	else
		D2G_ACCEL="${D2G_ACCEL:-tcg,thread=multi}"
	fi
fi
# -cpu host is only valid with KVM/HVF; TCG needs a model (e.g. max).
if [[ $D2G_ACCEL == tcg* ]]; then
	D2G_CPU="${D2G_CPU:-max}"
else
	D2G_CPU="${D2G_CPU:-host}"
fi
# consumed by lib/vm.sh and the golden-builder scripts
QEMU_MACHINE_ARGS=( -machine "$D2G_MACHINE" -accel "$D2G_ACCEL" -cpu "$D2G_CPU" )

ASSETS_DIR="${ASSETS_DIR:-$HERE/assets}"
# architecture-specific golden images and per-arch downloaded artifacts
GOLDEN_DIR="$ASSETS_DIR/golden/$D2G_ARCH"
DL_DIR="$ASSETS_DIR/downloads/$D2G_ARCH"
RESULTS_ROOT="${RESULTS_ROOT:-$HERE/results}/$D2G_ARCH"
SSH_KEY="${SSH_KEY:-$ASSETS_DIR/id_ed25519}"
CASES_DIR="$HERE/cases/$D2G_ARCH"

# TCG (cross-arch, or hosts without virtualization) needs more wall clock:
# smaller VMs and longer timeouts. KVM/HVF at native speed is fast.
if [[ $D2G_ACCEL == kvm || $D2G_ACCEL == hvf ]]; then
	VM_SMP="${VM_SMP:-4}"
	VM_MEM_MB="${VM_MEM_MB:-8192}"
	VM_DISK_SIZE="${VM_DISK_SIZE:-30G}"
	BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
	REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-480}"
else
	VM_SMP="${VM_SMP:-4}"
	VM_MEM_MB="${VM_MEM_MB:-4096}"
	VM_DISK_SIZE="${VM_DISK_SIZE:-30G}"
	BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"
	REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-900}"
fi
RUN_TIMEOUT="${RUN_TIMEOUT:-7200}"
# hostfwd TCP base ports; case index is added to get a per-case port
BASE_SSH_PORT="${BASE_SSH_PORT:-2230}"
BASE_MON_PORT="${BASE_MON_PORT:-2330}"
# wall-clock cap for one short ssh probe (conversion channel overrides)
: "${D2G_SSH_TIMEOUT:=30}"

# conversion mirror used inside guests
D2G_MIRROR="${D2G_TEST_MIRROR:-https://mirrors.bfsu.edu.cn/gentoo}"
# Gentoo git mirror for the portage tree
D2G_GIT_MIRROR="${D2G_TEST_GIT_MIRROR:-https://mirrors.bfsu.edu.cn/git/gentoo-portage.git}"

# golden image filenames (located in the per-arch GOLDEN_DIR)
if [[ $D2G_ARCH == aarch64 ]]; then
	GOLDEN_DEBIAN="debian-bookworm-ext4-arm64.qcow2"
	GOLDEN_UBUNTU="ubuntu-noble-ext4-arm64.qcow2"
	GOLDEN_FEDORA="fedora44-btrfs-arm64.qcow2"
	GOLDEN_ARCH="arch-ext4-arm64.qcow2"
	GOLDEN_DEBIAN_BTRFS="debian-bookworm-btrfs-arm64.qcow2"
	GOLDEN_OPENSUSE="opensuse-leap-btrfs-arm64.qcow2"
	GOLDEN_ARCH_BTRFS="arch-btrfs-arm64.qcow2"
else
	GOLDEN_DEBIAN="debian-bookworm-ext4-amd64.qcow2"
	GOLDEN_UBUNTU="ubuntu-noble-ext4-amd64.qcow2"
	GOLDEN_FEDORA="fedora44-btrfs-amd64.qcow2"
	GOLDEN_ARCH="arch-ext4-amd64.qcow2"
	GOLDEN_DEBIAN_BTRFS="debian-bookworm-btrfs-amd64.qcow2"
	GOLDEN_OPENSUSE="opensuse-tumbleweed-btrfs-amd64.qcow2"
	GOLDEN_ARCH_BTRFS="arch-btrfs-amd64.qcow2"
fi

mkdir -p "$GOLDEN_DIR" "$DL_DIR"
