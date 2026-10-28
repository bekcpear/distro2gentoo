#!/usr/bin/env bash
# Runs INSIDE the stock Arch Linux x86_64 cloud-image helper VM.
# /dev/vda is the helper's own disk (read-only qcow2 backing + overlay),
# /dev/vdb is a fresh target disk that becomes an Arch/systemd system on
# btrfs (subvolumes @ and @home), by rsync-pivoting the running helper
# rootfs onto it. This is the x86_64 counterpart of the aarch64 ALARM
# tarball goldens: unlike ALARM there is an official upstream Arch cloud
# image on x86_64, so no bootstrap tarball is needed.
set -euxo pipefail

DISK=/dev/vdb

[[ $(uname -m) == x86_64 ]] || { echo "arch-btrfs-guest.sh is x86_64-only" >&2; exit 1; }

# cloud-init/reflector may hold pacman right after first boot
while pgrep -x pacman >/dev/null 2>&1 || pgrep -x reflector >/dev/null 2>&1; do
	echo "waiting for pacman/reflector ..."; sleep 5
done
n=0
until pacman -Sy --noconfirm --disable-download-timeout; do
	n=$((n+1))
	if [ "$n" -ge 12 ]; then echo "pacman -Sy failed after retries" >&2; exit 1; fi
	echo "pacman -Sy retry $n ..."; sleep 10
done
pacman -S --noconfirm --needed --disable-download-timeout \
	btrfs-progs rsync parted dosfstools grub efibootmgr

# fresh partition table: ESP (512MiB) + btrfs root (rest)
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart rootfs btrfs 513MiB 100%
udevadm settle 2>/dev/null || sleep 2
mkfs.vfat -F32 "${DISK}1"
mkfs.btrfs -f -L archroot "${DISK}2"

mount "${DISK}2" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@ "${DISK}2" /mnt
mkdir -p /mnt/home /mnt/boot/efi
mount -o subvol=@home "${DISK}2" /mnt/home
mount "${DISK}1" /mnt/boot/efi

# Copy the running Arch system onto the btrfs target.
# The stock cloud image mounts its ESP at /boot (systemd-boot layout),
# so -x skips it; kernel/initramfs/ucode are copied over separately
# below (without the old systemd-boot EFI binaries) onto the btrfs /boot.
mkdir -p /mnt/{dev,proc,sys,run}
rsync -aHAXx --numeric-ids \
	--exclude='/mnt/***' --exclude='/proc/***' --exclude='/sys/***' \
	--exclude='/dev/***' --exclude='/run/***' --exclude='/tmp/***' \
	--exclude='/boot/***' \
	/ /mnt/
rsync -aHAX --numeric-ids \
	--exclude='/EFI' --exclude='/efi' --exclude='/grub' \
	/boot/ /mnt/boot/

ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
ESP_UUID=$(blkid -s UUID -o value "${DISK}1")
cat > /mnt/etc/fstab <<EOF
UUID=${ROOT_UUID}  /          btrfs  rw,relatime,subvol=@      0 0
UUID=${ROOT_UUID}  /home      btrfs  rw,relatime,subvol=@home  0 0
UUID=${ESP_UUID}   /boot/efi  vfat   umask=0077                0 2
EOF

for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars

cat > /mnt/root/btrfs-finalize.sh <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail

# Rebuild initramfs from the chroot: the autodetect hook now sees a btrfs
# root and pulls the btrfs module in.
mkinitcpio -P

# Arch's /etc/default/grub is a single file (no grub.d drop-ins)
if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
	echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200"' >> /etc/default/grub
else
	sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200"|' /etc/default/grub
fi

# removable path (EFI/BOOT/BOOTX64.EFI) is the bootable fallback and must
# succeed; NVRAM registration is best-effort
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --removable
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch || true
grub-mkconfig -o /boot/grub/grub.cfg

# serial console for QEMU
ln -sf /usr/lib/systemd/system/serial-getty@.service \
	/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
sync
EOF
chmod +x /mnt/root/btrfs-finalize.sh
chroot /mnt /bin/bash /root/btrfs-finalize.sh

sync
umount -R /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
sync
echo ARCH-BTRFS-DISK-READY
