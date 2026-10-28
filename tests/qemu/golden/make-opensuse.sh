#!/usr/bin/env bash
# Prepare the openSUSE Tumbleweed aarch64 JeOS golden (btrfs flat root).
# The raw JeOS qcow2 has no cloud-init and no pre-shared SSH key, so a
# throwaway Debian helper VM mounts the target disk's btrfs root offline
# and injects our root test key + password, then sanity-boots it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.sh
. "$HERE/config.sh"
. "$HERE/lib/common.sh"
. "$HERE/lib/cloudinit.sh"
. "$HERE/lib/vm.sh"

GOLDEN="$GOLDEN_DIR/$GOLDEN_OPENSUSE"
if [[ -f $GOLDEN ]]; then
	say "$GOLDEN already exists, skipping"
	exit 0
fi
RAW="$DL_DIR/tw-jeos.qcow2"
[[ -f $RAW ]] || die "$RAW missing, run golden/fetch-opensuse.sh first"

WORK="$ASSETS_DIR/opensuse-build"
mkdir -p "$WORK"
HELPER="$WORK/helper.qcow2"
TARGET="$WORK/target.qcow2"
SEED="$WORK/seed.iso"
rm -f "$HELPER" "$TARGET" "$WORK/qemu.pid" "$WORK/qemu.log" "$WORK/serial.log" "$WORK/build.log"
SSH_PORT=$((BASE_SSH_PORT + 94))
MON_PORT=$((BASE_MON_PORT + 94))

vm_make_overlay "$HELPER" "$GOLDEN_DIR/$GOLDEN_DEBIAN"
cp "$RAW" "$TARGET"
"$QEMU_IMG" resize "$TARGET" "$VM_DISK_SIZE"
ensure_ssh_key
gen_seed "$SEED" opensusebuild

cleanup() { vm_stop "$WORK" "$MON_PORT" 2>/dev/null || true; }
trap cleanup EXIT

say "starting Debian helper VM"
cp "$FW_VARS_TEMPLATE" "$WORK/efivars.fd"
nohup "$QEMU_BIN" \
	-name d2g-osbuild \
	"${QEMU_MACHINE_ARGS[@]}" \
	-smp "$VM_SMP" -m "$VM_MEM_MB" \
	-drive if=pflash,format=raw,readonly=on,file="$FW" \
	-drive if=pflash,format=raw,file="$WORK/efivars.fd" \
	-drive file="$HELPER",if=none,id=d0,format=qcow2 -device virtio-blk-pci,drive=d0 \
	-drive file="$TARGET",if=none,id=d1,format=qcow2 -device virtio-blk-pci,drive=d1 \
	-drive file="$SEED",if=none,id=d2,format=raw,readonly=on -device virtio-blk-pci,drive=d2 \
	-netdev user,id=n0,hostfwd="tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=n0 \
	-monitor "tcp:127.0.0.1:${MON_PORT},server,nowait" \
	-serial "file:${WORK}/serial.log" \
	-display none -pidfile "$WORK/qemu.pid" \
	>"$WORK/qemu.log" 2>&1 &
sleep 2

vm_wait_ssh "$SSH_PORT" 300 || die "helper VM SSH never came up; see $WORK/serial.log"
say "helper up, injecting root key into openSUSE btrfs root"
vm_scp_up "$SSH_PORT" "$SSH_KEY.pub" "/root/pubkey"
vm_scp_up "$SSH_PORT" "$HERE/golden/opensuse-guest.sh" "/root/opensuse-guest.sh"
if ! vm_ssh "$SSH_PORT" -- 'timeout 600 bash /root/opensuse-guest.sh' 2>&1 | tee "$WORK/build.log"; then
	die "openSUSE preparation failed; see $WORK/build.log and $WORK/serial.log"
fi
grep -q OPENSUSE-TW-DISK-READY "$WORK/build.log" || die "build did not report completion"

say "powering helper off and promoting target disk"
vm_ssh "$SSH_PORT" -- 'systemctl poweroff' 2>/dev/null || true
sleep 8
cleanup
trap - EXIT

mv "$TARGET" "$GOLDEN"
say "golden ready: $GOLDEN"

# --- sanity boot of the openSUSE golden ---
say "sanity booting the openSUSE golden (no cloud-init, no seed)"
SB="$WORK/sanity"; rm -rf "$SB"; mkdir -p "$SB"
vm_make_overlay "$SB/ov.qcow2" "$GOLDEN"
cp "$FW_VARS_TEMPLATE" "$SB/efivars.fd"
nohup "$QEMU_BIN" -name d2g-osssanity "${QEMU_MACHINE_ARGS[@]}" -smp 4 -m 4096 \
	-drive if=pflash,format=raw,readonly=on,file="$FW" \
	-drive if=pflash,format=raw,file="$SB/efivars.fd" \
	-drive file="$SB/ov.qcow2",if=none,id=d0,format=qcow2 -device virtio-blk-pci,drive=d0 \
	-netdev user,id=n0,hostfwd="tcp:127.0.0.1:$((SSH_PORT+30))-:22" -device virtio-net-pci,netdev=n0 \
	-serial "file:$SB/serial.log" -display none -pidfile "$SB/qemu.pid" >"$SB/qemu.log" 2>&1 &
trap 'kill $(cat $SB/qemu.pid) 2>/dev/null' EXIT
if ! vm_wait_ssh "$((SSH_PORT+30))" 300; then
	say "FATAL: openSUSE golden SSH never came up; see $SB/serial.log"
	exit 1
fi
vm_ssh "$((SSH_PORT+30))" -- 'uname -m; . /etc/os-release; echo "$PRETTY_NAME"; findmnt -no FSTYPE /'
say "openSUSE golden verified: $GOLDEN"
