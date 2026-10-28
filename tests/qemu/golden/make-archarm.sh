#!/usr/bin/env bash
# Build an Arch Linux ARM golden image from the official ALARM tarball,
# using a throwaway Debian VM to partition / populate / chroot the disk.
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

GOLDEN="$GOLDEN_DIR/$GOLDEN_ARCH"
if [[ -f $GOLDEN ]]; then
	say "$GOLDEN already exists, skipping"
	exit 0
fi
[[ -f $GOLDEN_DIR/$GOLDEN_DEBIAN ]] || die "$GOLDEN_DEBIAN missing, run golden/fetch.sh first"

WORK="$ASSETS_DIR/archbuild"
mkdir -p "$WORK"
HELPER="$WORK/helper.qcow2"
TARGET="$WORK/target.qcow2"
SEED="$WORK/seed.iso"
rm -f "$HELPER" "$TARGET" "$WORK/qemu.pid" "$WORK/qemu.log" "$WORK/serial.log" "$WORK/build.log"
SSH_PORT=$((BASE_SSH_PORT + 90))
MON_PORT=$((BASE_MON_PORT + 90))

vm_make_overlay "$HELPER" "$GOLDEN_DIR/$GOLDEN_DEBIAN"
[[ -f $TARGET ]] || "$QEMU_IMG" create -q -f qcow2 "$TARGET" "$VM_DISK_SIZE"
ensure_ssh_key
gen_seed "$SEED" archbuild

cleanup() { vm_stop "$WORK" "$MON_PORT" 2>/dev/null || true; }
trap cleanup EXIT

say "starting Debian helper VM"
cp "$FW_VARS_TEMPLATE" "$WORK/efivars.fd"
"$QEMU_BIN" \
	-name d2g-archbuild \
	"${QEMU_MACHINE_ARGS[@]}" \
	-smp "$VM_SMP" -m "$VM_MEM_MB" \
	-drive if=pflash,format=raw,readonly=on,file="$FW" \
	-drive if=pflash,format=raw,file="$WORK/efivars.fd" \
	-drive file="$HELPER",if=none,id=d0,format=qcow2 -device virtio-blk-pci,drive=d0 \
	-drive file="$TARGET",if=none,id=d1,format=qcow2 -device virtio-blk-pci,drive=d1 \
	-drive file="$SEED",if=none,id=d2,format=raw,readonly=on -device virtio-blk-pci,drive=d2 \
	-netdev user,id=n0,hostfwd="tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=n0 \
	-monitor "tcp:127.0.0.1:${MON_PORT},server,nowait" \
	-serial "file:${WORK}/serial.log" -display none -pidfile "$WORK/qemu.pid" \
	>"$WORK/qemu.log" 2>&1 &
sleep 2
kill -0 "$(cat "$WORK/qemu.pid" 2>/dev/null)" 2>/dev/null || die "helper qemu failed, see $WORK/qemu.log"

vm_wait_ssh "$SSH_PORT" 300 || die "helper VM SSH never came up"
vm_ssh "$SSH_PORT" -- 'lsblk -dn -o NAME,SIZE | cat'

say "uploading build script"
vm_scp_up "$SSH_PORT" "$HERE/golden/archarm-guest.sh" "/root/archarm-guest.sh"
vm_scp_up "$SSH_PORT" "${SSH_KEY}.pub" "/root/authorized_keys"

# fetch the ALARM tarball on the host (resumable, reused across retries)
TARBALL="$WORK/ArchLinuxARM-aarch64-latest.tar.gz"
if [[ ! -s $TARBALL ]]; then
	say "downloading Arch Linux ARM tarball (~790 MiB)"
	curl -fL -C - --retry 3 -o "$TARBALL.part" \
		"http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
	mv "$TARBALL.part" "$TARBALL"
fi
vm_scp_up "$SSH_PORT" "$TARBALL" "/root/ArchLinuxARM-aarch64-latest.tar.gz"
local_size=$(wc -c < "$TARBALL" | tr -d '[:space:]')
remote_size=$(vm_ssh "$SSH_PORT" -- 'stat -c%s /root/ArchLinuxARM-aarch64-latest.tar.gz')
[[ $local_size == "$remote_size" ]] || die "tarball upload incomplete ($remote_size/$local_size)"

say "building Arch ARM disk (tarball download + pacstrap can take 20-50 min)"
if ! vm_ssh "$SSH_PORT" -- 'timeout 3600 bash /root/archarm-guest.sh /dev/vdb /root/authorized_keys' 2>&1 | tee "$WORK/build.log"; then
	die "Arch ARM build failed; see $WORK/build.log and $WORK/serial.log"
fi
grep -q ARCHARM-DISK-READY "$WORK/build.log" || die "build did not report completion"

say "powering helper off and promoting target disk"
vm_ssh "$SSH_PORT" -- 'systemctl poweroff' 2>/dev/null || true
sleep 8
cleanup
trap - EXIT
mv "$TARGET" "$GOLDEN"
say "golden ready: $GOLDEN"

# --- sanity boot of the new golden ---
say "sanity booting the Arch golden"
SB="$WORK/sanity"; mkdir -p "$SB"
SOV="$SB/ov.qcow2"
vm_make_overlay "$SOV" "$GOLDEN"
gen_seed "$SB/seed.iso" archsanity
vm_start "$SB" "$SOV" "$SB/seed.iso" archsanity "$SSH_PORT" "$MON_PORT"
trap 'vm_stop "$SB" "$MON_PORT" 2>/dev/null || true' EXIT
vm_wait_ssh "$SSH_PORT" 300 || die "Arch golden SSH never came up; see $SB/serial.log"
vm_ssh "$SSH_PORT" -- 'uname -m; pacman -V | head -1; cat /etc/os-release | head -2; systemctl is-active sshd systemd-networkd'
vm_ssh "$SSH_PORT" -- 'systemctl poweroff' 2>/dev/null || true
sleep 8
vm_stop "$SB" "$MON_PORT"
trap - EXIT
say "Arch ARM golden verified: $GOLDEN"
