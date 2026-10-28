#!/usr/bin/env bash
# Build a Debian/systemd golden on BTRFS (subvolumes @/@home, ESP in vfat)
# by rsync-pivoting the running ext4 Debian helper golden onto a fresh disk.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.sh
. "$HERE/config.sh"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=../lib/cloudinit.sh
. "$HERE/lib/cloudinit.sh"
# shellcheck source=../lib/vm.sh
. "$HERE/lib/vm.sh"

GOLDEN="$GOLDEN_DIR/$GOLDEN_DEBIAN_BTRFS"
if [[ -f $GOLDEN ]]; then
	say "$GOLDEN already exists, skipping"
	exit 0
fi
[[ -f $GOLDEN_DIR/$GOLDEN_DEBIAN ]] || die "$GOLDEN_DEBIAN missing, run golden/fetch.sh first"

WORK="$ASSETS_DIR/debian-btrfs-build"
mkdir -p "$WORK"
HELPER="$WORK/helper.qcow2"
TARGET="$WORK/target.qcow2"
SEED="$WORK/seed.iso"
rm -f "$HELPER" "$TARGET" "$WORK/qemu.pid" "$WORK/qemu.log" "$WORK/serial.log" "$WORK/build.log"
SSH_PORT=$((BASE_SSH_PORT + 92))
MON_PORT=$((BASE_MON_PORT + 92))

vm_make_overlay "$HELPER" "$GOLDEN_DIR/$GOLDEN_DEBIAN"
[[ -f $TARGET ]] || "$QEMU_IMG" create -q -f qcow2 "$TARGET" "$VM_DISK_SIZE"
ensure_ssh_key
gen_seed "$SEED" debbtrfsbuild

cleanup() { vm_stop "$WORK" "$MON_PORT" 2>/dev/null || true; }
trap cleanup EXIT

say "starting Debian helper VM"
cp "$FW_VARS_TEMPLATE" "$WORK/efivars.fd"
nohup "$QEMU_BIN" \
	-name d2g-debbtrfsbuild \
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

say "helper VM up, uploading build script"
vm_wait_ssh "$SSH_PORT" 300
vm_scp_up "$SSH_PORT" "$HERE/golden/debian-btrfs-guest.sh" "/root/debian-btrfs-guest.sh"
# Run detached so a cloud-init triggered network/sshd restart cannot kill
# the build when the SSH session drops; poll the guest-side log to completion.
vm_ssh "$SSH_PORT" -- 'rm -f /root/btrfs-build.log /root/btrfs-build.rc; setsid bash -c "bash /root/debian-btrfs-guest.sh >/root/btrfs-build.log 2>&1; echo \$? >/root/btrfs-build.rc" </dev/null >/dev/null 2>&1 &'
build_rc=""
for t in $(seq 1 300); do
	sleep 10
	build_rc=$(vm_ssh "$SSH_PORT" -- 'cat /root/btrfs-build.rc 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
	[ -n "$build_rc" ] && break
done
vm_ssh "$SSH_PORT" -- 'cat /root/btrfs-build.log' >"$WORK/build.log" 2>/dev/null
tail -20 "$WORK/build.log"
if [[ -z $build_rc || $build_rc != 0 ]]; then
	die "Debian btrfs build failed; see $WORK/build.log and $WORK/serial.log"
fi
grep -q DEBIAN-BTRFS-DISK-READY "$WORK/build.log" || die "build did not report completion"

say "powering helper off and promoting target disk"
vm_ssh "$SSH_PORT" -- 'systemctl poweroff' 2>/dev/null || true
sleep 8
cleanup
trap - EXIT

mv "$TARGET" "$GOLDEN"
say "golden ready: $GOLDEN"

# --- sanity boot of the btrfs golden ---
say "sanity booting the Debian btrfs golden"
SB="$WORK/sanity"; mkdir -p "$SB"
vm_make_overlay "$SB/ov.qcow2" "$GOLDEN"
gen_seed "$SB/seed.iso" debbtrfs-sanity
vm_start "$SB" "$SB/ov.qcow2" "$SB/seed.iso" debbtrfs-sanity "$((SSH_PORT+30))" "$((MON_PORT+30))"
trap 'vm_stop "'$SB'" "'$((MON_PORT+30))'" 2>/dev/null || true' EXIT
if ! vm_wait_ssh "$((SSH_PORT+30))" 300; then
	say "FATAL: Debian btrfs golden SSH never came up; see $SB/serial.log"
	exit 1
fi
vm_ssh "$((SSH_PORT+30))" -- 'uname -m; . /etc/os-release; echo "$PRETTY_NAME"; findmnt -no FSTYPE /; systemctl is-active systemd-networkd 2>/dev/null || systemctl is-active NetworkManager 2>/dev/null'
say "Debian btrfs golden verified: $GOLDEN"
