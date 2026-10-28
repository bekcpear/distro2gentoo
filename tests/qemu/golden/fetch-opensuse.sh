#!/usr/bin/env bash
# Download the openSUSE Tumbleweed JeOS/Minimal-VM qcow2 (btrfs root).
# openSUSE Leap's JeOS images use ext4; Tumbleweed uses the project's
# default btrfs layout (snapper subvolumes), which is what this matrix needs.
#   aarch64 -> ARM-JeOS-efi appliance from the ports tree
#   x86_64  -> Minimal-VM kvm-and-xen appliance (JeOS was renamed for x86_64)
# Re-running is safe; an existing image is kept.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.sh
. "$HERE/config.sh"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

mkdir -p "$DL_DIR"
IMG="$DL_DIR/tw-jeos.qcow2"
if [[ $D2G_ARCH == aarch64 ]]; then
	IMG_URL="${OPENSUSE_IMG_URL:-https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-Tumbleweed-ARM-JeOS-efi.aarch64.qcow2}"
else
	IMG_URL="${OPENSUSE_IMG_URL:-https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-kvm-and-xen.qcow2}"
fi

# migrate the pre-per-arch flat layout used by older revisions
LEGACY="$ASSETS_DIR/downloads/tw-jeos.qcow2"
if [[ ! -s $IMG && -s $LEGACY && $D2G_ARCH == aarch64 ]]; then
	say "moving legacy $LEGACY -> $IMG"
	mv "$LEGACY" "$IMG"
fi

if [[ ! -s $IMG ]]; then
	say "downloading openSUSE Tumbleweed appliance $D2G_ARCH"
	curl -fL -C - --retry 3 -o "$IMG.part" "$IMG_URL"
	mv "$IMG.part" "$IMG"
fi
say "openSUSE image: $IMG"
