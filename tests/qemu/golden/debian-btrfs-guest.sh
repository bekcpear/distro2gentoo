#!/usr/bin/env bash
# Runs INSIDE the Debian helper VM. /dev/vda is the read-only helper golden
# (ext4), /dev/vdb is a fresh target disk that becomes a Debian/systemd
# system on btrfs (subvolumes @ and @home), by rsync-pivoting the live
# helper rootfs onto it.
set -euxo pipefail

DISK=/dev/vdb

# grub target/package and serial device depend on the guest architecture
case "$(dpkg --print-architecture)" in
	arm64) GRUB_PKG=grub-efi-arm64-bin; GRUB_TARGET=arm64-efi;  SERIAL_CONSOLE=ttyAMA0 ;;
	amd64) GRUB_PKG=grub-efi-amd64-bin; GRUB_TARGET=x86_64-efi; SERIAL_CONSOLE=ttyS0 ;;
	*) echo "unsupported debian arch: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
# cloud-init/unattended-upgrade may hold dpkg/apt locks right after boot;
# wait for any running apt/dpkg/unattended process without extra deps
while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1 || pgrep -x apt.systemd.daily >/dev/null 2>&1; do
	echo "waiting for apt/dpkg lock ..."; sleep 5
done
# apt can run before cloud-init has fully brought up DHCP; retry. Guard
# against set -e aborting on the first failing attempt.
n=0
while :; do
	if apt-get update; then break; fi
	n=$((n+1))
	if [ $n -ge 12 ]; then echo "apt-get update failed after retries" >&2; exit 1; fi
	echo "apt-get update retry $n ..."; sleep 10
done
DEBIAN_FRONTEND=noninteractive apt-get install -y btrfs-progs rsync "$GRUB_PKG" efibootmgr dosfstools parted

# fresh partition table: ESP (512MiB) + btrfs root (rest)
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart rootfs btrfs 513MiB 100%
udevadm settle 2>/dev/null || sleep 2
mkfs.vfat -F32 "${DISK}1"
mkfs.btrfs -f -L debroot "${DISK}2"

mount "${DISK}2" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o subvol=@ "${DISK}2" /mnt
mkdir -p /mnt/home /mnt/boot/efi
mount -o subvol=@home "${DISK}2" /mnt/home
mount "${DISK}1" /mnt/boot/efi

# copy the running Debian system onto the btrfs target;
# -x stays on one filesystem so the helper's mounted ESP/run/etc are skipped
mkdir -p /mnt/{dev,proc,sys,run}
rsync -aHAXx --numeric-ids \
	--exclude='/mnt/***' --exclude='/proc/***' --exclude='/sys/***' \
	--exclude='/dev/***' --exclude='/run/***' --exclude='/tmp/***' \
	/ /mnt/

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

# unquoted EOF: GRUB_TARGET/SERIAL_CONSOLE are host-side values; the
# inner script itself contains no expansions
cat > /mnt/root/btrfs-finalize.sh <<EOF
#!/usr/bin/env bash
set -euxo pipefail
apt-get install -y -qq btrfs-progs >/dev/null
update-initramfs -u -k all
grub-install --target=${GRUB_TARGET} --efi-directory=/boot/efi --bootloader-id=debian || true
grub-install --target=${GRUB_TARGET} --efi-directory=/boot/efi --removable
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="console=${SERIAL_CONSOLE},115200"|' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
# NOTE: cloud-init may pin the first-boot NIC name in
# /etc/netplan/50-cloud-init.yaml (set-name), which can differ from the
# udev PCI-path name a converted Gentoo kernel uses. We deliberately do
# NOT fight this in the image: distro2gentoo selects the interface by
# udev's ID_NET_NAME_PATH (hardware location, stable across kernels) and
# falls back to MAC binding, so the pinned host name is harmless.
sync
EOF
chmod +x /mnt/root/btrfs-finalize.sh
chroot /mnt /bin/bash /root/btrfs-finalize.sh

sync
umount -R /mnt 2>/dev/null || umount -l /mnt 2>/dev/null || true
sync
echo DEBIAN-BTRFS-DISK-READY
