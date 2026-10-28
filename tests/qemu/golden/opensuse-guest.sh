#!/usr/bin/env bash
# Runs INSIDE the Debian helper VM. /dev/vda is the read-only helper golden,
# /dev/vdb is the openSUSE Tumbleweed JeOS disk (btrfs with snapper
# subvolumes; the booted default is @/.snapshots/1/snapshot and /root is
# its own subvolume @/root). Inject our root test key + password into the
# correct subvolumes and disable SELinux (it rejects offline-written,
# unlabelled authorized_keys).
set -euxo pipefail

# cloud-init/unattended-upgrade may hold dpkg/apt locks right after boot;
# wait for running package managers without extra packages
while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1 || pgrep -x apt.systemd.daily >/dev/null 2>&1; do
	echo "waiting for apt/dpkg lock ..."; sleep 5
done
apt-get update -qq
apt-get install -y -qq btrfs-progs

M=/mnt/tw
ROOTVOL=/mnt/rootvol
mkdir -p "$M" "$ROOTVOL"

# The btrfs partition index differs between the appliances
# (vdb3 on the aarch64 ARM-JeOS image); locate it by filesystem type.
ROOTDISK=/dev/vdb
ROOTPART=
for p in "$ROOTDISK"*; do
	[[ -b $p ]] || continue
	[[ $(blkid -s TYPE -o value "$p" 2>/dev/null) == btrfs ]] || continue
	ROOTPART=$p
	break
done
[[ -n $ROOTPART ]] || { echo "no btrfs partition found on $ROOTDISK" >&2; exit 1; }
echo "btrfs partition: $ROOTPART"

# Tumbleweed boots the default subvolume (@/.snapshots/1/snapshot)
mount -o subvolid=5 "$ROOTPART" "$M"
DEFID=$(btrfs subvolume get-default "$M" | awk '{print $2}')
umount "$M"
mount -o subvolid="$DEFID" "$ROOTPART" "$M"

# /root is normally a separate subvolume ("ID 261 ... path @/root").
# If an image does not create it, the booted default subvolume owns /root.
ROOTID=$(btrfs subvolume list "$M" | awk '/ path @\/root$/{print $2; exit}')
echo "default subvol=$DEFID root subvol=${ROOTID:-<none, using default>}"
ROOTHOME="$M"
if [[ -n $ROOTID ]]; then
	mkdir -p "$ROOTVOL"
	mount -o subvolid="$ROOTID" "$ROOTPART" "$ROOTVOL"
	ROOTHOME="$ROOTVOL"
fi

mkdir -p "$ROOTHOME/.ssh"
cat /root/pubkey > "$ROOTHOME/.ssh/authorized_keys"
chmod 700 "$ROOTHOME/.ssh"
chmod 600 "$ROOTHOME/.ssh/authorized_keys"

# known root password; awk avoids interpreting '$' in the hash
HASH=$(openssl passwd -6 d2gtest)
awk -v h="$HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
	"$M/etc/shadow" > "$M/etc/shadow.new"
mv "$M/etc/shadow.new" "$M/etc/shadow"
chmod 640 "$M/etc/shadow"

mkdir -p "$M/etc/ssh/sshd_config.d"
echo 'PermitRootLogin yes' > "$M/etc/ssh/sshd_config.d/99-d2g.conf"

# SELinux: disable policy load entirely via the live grub.cfg on the btrfs
# boot subvolume and the kernel default, plus config for completeness.
rm -f "$M/etc/selinux/.autorelabel"
GRUBCFG="$M/boot/grub2/grub.cfg"
if [[ -f $GRUBCFG ]]; then
	sed -i -E 's#selinux=1#selinux=0#g' "$GRUBCFG"
fi
[[ -f $M/etc/default/grub ]] && sed -i -E 's#selinux=1#selinux=0#g' "$M/etc/default/grub"
if [[ -f $M/etc/selinux/config ]]; then
	sed -i -E 's#^SELINUX=(enforcing|permissive)#SELINUX=disabled#' "$M/etc/selinux/config"
fi

sync
umount "$ROOTVOL"
umount "$M"
echo OPENSUSE-TW-DISK-READY
