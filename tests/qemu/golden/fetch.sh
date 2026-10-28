#!/usr/bin/env bash
# Download and prepare the official cloud images.
# Re-running is safe; existing files of sufficient size are skipped.
#
# Architecture is taken from D2G_ARCH (sourced from config.sh):
#   aarch64 -> Debian bookworm / Ubuntu noble / Fedora 44 (arm64 images)
#   x86_64  -> Debian bookworm / Ubuntu noble / Fedora 44 / Arch x86_64 cloud
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.sh
. "$HERE/config.sh"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

# Upstream images are downloaded under their upstream file names into
# DL_DIR, then converted/resized and promoted into GOLDEN_DIR under the
# GOLDEN_* names defined in config.sh.
declare -A URL GOLDEN_NAME
if [[ $D2G_ARCH == aarch64 ]]; then
	URL[debian]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"
	URL[ubuntu]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
	URL[fedora]="https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2"
else
	URL[debian]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
	URL[ubuntu]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
	URL[fedora]="https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
	URL[arch]="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
fi
case $D2G_ARCH in
	aarch64)
		GOLDEN_NAME[debian]=$GOLDEN_DEBIAN
		GOLDEN_NAME[ubuntu]=$GOLDEN_UBUNTU
		GOLDEN_NAME[fedora]=$GOLDEN_FEDORA ;;
	x86_64)
		GOLDEN_NAME[debian]=$GOLDEN_DEBIAN
		GOLDEN_NAME[ubuntu]=$GOLDEN_UBUNTU
		GOLDEN_NAME[fedora]=$GOLDEN_FEDORA
		GOLDEN_NAME[arch]=$GOLDEN_ARCH ;;
esac

# verify checksum for each golden name (algorithm:file pairs in GOLDEN_CHECKSUMS)
declare -A SUM_ALGO SUM_FILE
if [[ $D2G_ARCH == aarch64 ]]; then
	SUM_FILE[debian]=SHA512SUMS SUM_ALGO[debian]=512
	SUM_FILE[fedora]=Fedora-Cloud-44-1.7-aarch64-CHECKSUM SUM_ALGO[fedora]=sha256
else
	SUM_FILE[debian]=SHA512SUMS SUM_ALGO[debian]=512
	SUM_FILE[fedora]=Fedora-Cloud-44-1.7-x86_64-CHECKSUM SUM_ALGO[fedora]=sha256
fi

dl() { # <key>
	local key=$1 src=${URL[$1]:-}
	[[ -n $src ]] || die "no URL configured for '$key' on $D2G_ARCH"
	local file="$DL_DIR/$(basename "$src")"
	if [[ -s $file ]]; then
		say "$key download present: $file"
		return
	fi
	say "downloading $key ($D2G_ARCH)"
	curl -fL --retry 3 --connect-timeout 30 -o "$file.part" "$src"
	mv "$file.part" "$file"
}

# hex digest of <file>; shasum (macOS/Perl) or coreutils' shaNsum (Linux)
sha_digest() { # <bits> <file>
	if command -v shasum >/dev/null; then
		shasum -a "$1" "$2" | awk '{print $1}'
	else
		"sha$1sum" "$2" | awk '{print $1}'
	fi
}

# verify a checksum line file; algorithm detection is intentionally simple
verify_sum() { # <key> <file>
	local key=$1 file=$2
	local algo="" sumfile=""
	algo="${SUM_ALGO[$key]-}"
	sumfile="${SUM_FILE[$key]-}"
	if [[ -z $algo || -z $sumfile ]]; then
		return 0
	fi
	local sumurl="${URL[$key]%/*}/$sumfile"
	local sumdata
	sumdata=$(curl -fsSL -m 60 "$sumurl") || { say "checksum fetch failed, skipping verification ($key)"; return 0; }
	# checksum manifests use the upstream file name, which may differ from
	# the local promoted golden name; match on the URL basename as fallback
	local chkname
	chkname=$(basename "${URL[$key]}")
	if [[ $algo == 512 ]]; then
		local exp got
		exp=$(awk -v f="$chkname" '$2==f{print $1}' <<<"$sumdata")
		[[ -z $exp ]] && exp=$(awk -v f="$(basename "$file")" '$2==f{print $1}' <<<"$sumdata")
		got=$(sha_digest 512 "$file")
	else
		# Fedora CHECKSUM files carry several images; pick the line for
		# our file ("SHA256 (<basename>) = <hash>"), not just any hash.
		exp=$(awk -v f="SHA256 ($chkname)" 'index($0,f){for (i=1;i<=NF;i++) if ($i ~ /^[a-f0-9]{64}$/) {print $i; exit}}' <<<"$sumdata")
		got=$(sha_digest 256 "$file")
	fi
	[[ -n $exp && $got == "$exp" ]] || die "checksum mismatch for $key"
	say "$key checksum OK"
}

for k in debian ubuntu fedora arch; do
	[[ -n ${URL[$k]:-} ]] || continue
	dl "$k"
	src="$DL_DIR/$(basename "${URL[$k]}")"
	verify_sum "$k" "$src"

	# Convert to qcow2 and grow to the test disk size so cloud-init
	# growpart and the conversion have room, then promote under the
	# GOLDEN_* names defined in config.sh.
	dst="$GOLDEN_DIR/${GOLDEN_NAME[$k]}"
	if [[ ! -f $dst ]]; then
		"$QEMU_IMG" convert -q -O qcow2 "$src" "$dst.tmp"
		"$QEMU_IMG" resize -q "$dst.tmp" "$VM_DISK_SIZE"
		mv "$dst.tmp" "$dst"
		say "golden $k ($D2G_ARCH): $dst"
	fi
done

say "golden images ($D2G_ARCH):"
ls -lh "$GOLDEN_DIR"
