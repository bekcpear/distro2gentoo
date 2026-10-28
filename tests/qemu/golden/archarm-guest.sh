#!/usr/bin/env bash
# Runs INSIDE the Debian helper VM. Builds a bootable Arch Linux ARM disk.
# Usage: archarm-guest.sh <target-disk-dev> <pubkey-file>
set -euxo pipefail

DISK=$1
PUBKEY=$2
TARBALL_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
TARBALL=/root/ArchLinuxARM-aarch64-latest.tar.gz

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq parted dosfstools e2fsprogs curl

if [[ ! -s $TARBALL ]]; then
	curl -fL --retry 3 -o "$TARBALL" "$TARBALL_URL"
fi

# fresh partition table: ESP (512MiB) + root (rest)
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart rootfs ext4 513MiB 100%
udevadm settle 2>/dev/null || sleep 2
mkfs.vfat -F32 "${DISK}1"
mkfs.ext4 -F -L archroot "${DISK}2"

mount "${DISK}2" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}1" /mnt/boot/efi

tar xpf "$TARBALL" -C /mnt

ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
ESP_UUID=$(blkid -s UUID -o value "${DISK}1")
cat > /mnt/etc/fstab <<EOF
UUID=${ROOT_UUID}  /          ext4  defaults,rw          0 1
UUID=${ESP_UUID}   /boot/efi  vfat  umask=0077          0 2
EOF

# ALARM ships /etc/resolv.conf as an absolute symlink into /run/systemd/resolve;
# remove it before copying or cp considers both paths the same file.
rm -f /mnt/etc/resolv.conf
cp /etc/resolv.conf /mnt/etc/resolv.conf
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
# a plain /sys bind does not propagate the efivarfs submount; without it
# grub-install/efibootmgr inside the chroot report "EFI variables unsupported"
mkdir -p /mnt/sys/firmware/efi/efivars
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars
mkdir -p /mnt/root
cp "$PUBKEY" /mnt/root/authorized_keys

cat > /mnt/root/inner.sh <<'INNER'
#!/usr/bin/env bash
set -euxo pipefail

pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --disable-download-timeout
pacman -S --noconfirm grub efibootmgr openssh linux-aarch64 linux-firmware

# networking: systemd-networkd + resolved on any virtio/onboard NIC
cat >/etc/systemd/network/20-wired.network <<'NET'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
NET
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-networkd systemd-resolved sshd

# serial console for QEMU
ln -sf /usr/lib/systemd/system/serial-getty@.service \
	/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

# locale
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# root login
echo 'root:d2gtest' | chpasswd
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /root/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# kernel console on serial
if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
	echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200"' >> /etc/default/grub
else
	sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200"|' /etc/default/grub
fi

# ALARM's grub resolves root by /dev name (different in the build VM vs
# the test VM) and cannot pair /boot/Image with initramfs-linux.img;
# install an explicit UUID-based entry and make it the default
cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
cat <<'GRUBENTRY'
menuentry "Arch ARM" {
	search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
	linux /boot/Image root=UUID=${ROOT_UUID} rw console=ttyAMA0,115200
	initrd /boot/initramfs-linux.img
}
GRUBENTRY
EOF
chmod +x /etc/grub.d/40_custom
sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT="Arch ARM"|' /etc/default/grub

# removable path (EFI/BOOT/BOOTAA64.EFI) is the bootable fallback and
# must succeed; NVRAM registration is best-effort
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=GRUB || true
grub-mkconfig -o /boot/grub/grub.cfg
INNER
chmod +x /mnt/root/inner.sh
# ROOT_UUID is the ext4 fs created on the target disk by the outer script
chroot /mnt /usr/bin/env ROOT_UUID="$ROOT_UUID" /bin/bash /root/inner.sh

sync
umount -R /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
sync
echo ARCHARM-DISK-READY
