# QEMU VM lifecycle helpers (KVM/HVF accelerated, TCG fallback; slirp networking).

# vm_make_overlay <output.qcow2> <golden.qcow2>
vm_make_overlay() {
	local out=$1 golden=$2
	[[ -f $golden ]] || die "golden image missing: $golden (run golden/fetch.sh first)"
	"$QEMU_IMG" create -q -f qcow2 -F qcow2 -b "$golden" -o backing_fmt=qcow2 "$out"
}

# vm_start <case_dir> <overlay> <seed.iso> <name> <ssh_port> <mon_port>
vm_start() {
	local dir=$1 overlay=$2 seed=$3 name=$4 ssh_port=$5 mon_port=$6
	[[ -f $FW ]] || die "UEFI firmware not found: $FW"
	# writable per-VM EFI variable store so efibootmgr can register entries
	[[ -f $FW_VARS_TEMPLATE ]] || die "UEFI vars template not found: $FW_VARS_TEMPLATE"
	if [[ $D2G_ARCH == aarch64 ]]; then
		cp "$FW_VARS_TEMPLATE" "${dir}/efivars.fd"
	else
		# x86_64 OVMF: writable vars must match the code fd size. Prefer
		# a dedicated vars template, else copy code fd, else empty 4m.
		if [[ -f $FW_VARS_TEMPLATE ]]; then
			cp "$FW_VARS_TEMPLATE" "${dir}/efivars.fd"
		elif [[ -f $FW ]]; then
			cp "$FW" "${dir}/efivars.fd"
		else
			truncate -s 4m "${dir}/efivars.fd"
		fi
	fi
	# machine/accel/cpu are resolved per host OS in config.sh
	nohup "$QEMU_BIN" \
		-name "d2g-${name}" \
		"${QEMU_MACHINE_ARGS[@]}" \
		-smp "$VM_SMP" -m "$VM_MEM_MB" \
		-drive if=pflash,format=raw,readonly=on,file="$FW" \
		-drive if=pflash,format=raw,file="${dir}/efivars.fd" \
		-drive file="$overlay",if=none,id=disk0,format=qcow2 \
		-device virtio-blk-pci,drive=disk0,addr=0x2 \
		-drive file="$seed",if=none,id=disk1,format=raw,readonly=on \
		-device virtio-blk-pci,drive=disk1,addr=0x4 \
		-netdev user,id=n0,hostfwd="tcp:127.0.0.1:${ssh_port}-:22" \
		-device virtio-net-pci,netdev=n0,addr=0x3 \
		-monitor "tcp:127.0.0.1:${mon_port},server,nowait" \
		-serial "file:${dir}/serial.log" \
		-display none -pidfile "${dir}/qemu.pid" \
		>"${dir}/qemu.log" 2>&1 &
	echo $! > "${dir}/launch.pid"
	sleep 2
	kill -0 "$(cat "${dir}/launch.pid")" 2>/dev/null \
		|| die "qemu exited immediately, see ${dir}/qemu.log"
	say "[$name] QEMU started (ssh 127.0.0.1:${ssh_port}, monitor ${mon_port})"
}

# vm_monitor <mon_port> <monitor command...>
# The QEMU monitor never closes the connection, and Linux
# netcat-openbsd (unlike macOS nc) does not exit after stdin EOF
# without -N/-q, so the call must be bounded or it wedges the harness
# right after "hard resetting VM". The command reaches QEMU within the
# first 0.5s; killing nc afterwards is harmless.
vm_monitor() {
	local port=$1; shift
	( printf '%s\n' "$*"; sleep 0.5 ) | timeout 15 nc 127.0.0.1 "$port" 2>/dev/null
}

vm_reset() { vm_monitor "$1" system_reset >/dev/null; }
vm_stop() {
	local dir=$1
	if [[ -f ${dir}/qemu.pid ]] && kill -0 "$(cat "${dir}/qemu.pid")" 2>/dev/null; then
		vm_monitor "$2" quit >/dev/null
		local i
		for ((i=0; i<20; i++)); do
			kill -0 "$(cat "${dir}/qemu.pid")" 2>/dev/null || return 0
			sleep 0.5
		done
		kill "$(cat "${dir}/qemu.pid")" 2>/dev/null || true
	fi
}

# Total wall-clock cap for any single ssh invocation. Without this an
# established TCP connection to a half-ready sshd can hang on auth for
# the full ServerAlive window (tens of minutes), stalling the harness.
: "${D2G_SSH_TIMEOUT:=30}"

# vm_ssh <port> -- <remote command...>
vm_ssh() {
	local port=$1; shift
	[[ $1 == "--" ]] && shift
	timeout "$D2G_SSH_TIMEOUT" ssh -n -i "$SSH_KEY" -p "$port" -o BatchMode=yes \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR -o ConnectTimeout=8 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		root@127.0.0.1 "$@"
}

# vm_scp_up <port> <local> <remote>
vm_scp_up() {
	local port=$1 l=$2 r=$3
	scp -i "$SSH_KEY" -P "$port" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR "$l" "root@127.0.0.1:${r}"
}

# vm_wait_ssh <port> <timeout>
# <timeout> is a wall-clock window: a single probe can itself take up to
# D2G_SSH_TIMEOUT seconds (slirp accepts the TCP connection even while
# the guest sshd is down, so ssh hangs until killed), and counting only
# the sleep time would let the phase overshoot the window many times
# over. Progress notes every 30s keep boot/reboot phases from looking
# stuck in CI logs.
vm_wait_ssh() {
	local port=$1 timeout=$2 start=$SECONDS waited=0 last_note=0
	while :; do
		if vm_ssh "$port" -- true 2>/dev/null; then
			return 0
		fi
		waited=$((SECONDS - start))
		(( waited < timeout )) || return 1
		if (( waited - last_note >= 30 )); then
			last_note=$waited
			say "  waiting for SSH on port ${port} (${waited}s/${timeout}s)"
		fi
		sleep 5
	done
}
