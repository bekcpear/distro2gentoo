#!/usr/bin/env bash
# End-to-end conversion test runner.
# Usage: run.sh [-j N] [case-name ...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$HERE/config.sh"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/cloudinit.sh
. "$HERE/lib/cloudinit.sh"
# shellcheck source=lib/vm.sh
. "$HERE/lib/vm.sh"

J=3
while [[ $# -gt 0 ]]; do
	case $1 in
		-j) J=$2; shift 2 ;;
		-h|--help)
			grep -E '^#( |$)' "$0" | grep -v shellcheck | sed 's/^# \{0,1\}//'
			echo "available cases ($D2G_ARCH):"; ls "$CASES_DIR" | sed 's/^/  /;s/\.conf$//'
			exit 0 ;;
		*) break ;;
	esac
done

[[ -f $REPO_ROOT/distro2gentoo.sh ]] || die "distro2gentoo.sh not built yet; run 'make' in the repo root"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RESULTS_ROOT/$RUN_ID"
# fail loudly here; without the run dir every later mkdir (per-case dir,
# lock dir) fails too and reports misleading "stale lock" errors instead
mkdir -p "$RUN_DIR" || die "cannot create run dir '$RUN_DIR'"

# load cases, names determine stable port indices
mapfile -t ALL_CASES < <(ls "$CASES_DIR"/*.conf | sort)
WANTED=("$@")

collect_guest_diagnostics() { # <port> <dir> <tag>
	local port=$1 dir=$2 tag=$3
	{	vm_ssh "$port" -- 'echo "== uname =="; uname -a
			echo "== os-release =="; cat /etc/os-release 2>/dev/null
			echo "== lsblk =="; lsblk -f
			echo "== findmnt / =="; findmnt /
			echo "== fstab =="; cat /etc/fstab
			echo "== routes =="; ip route
			echo "== dmesg tail =="; dmesg 2>/dev/null | tail -30'
	} >"$dir/diag-${tag}.log" 2>&1 || true
}

run_case() { # <index> <conf>
	local idx=$1 conf=$2
	local NAME GOLDEN STAGE3_REGEX
	# shellcheck disable=SC1090
	. "$conf"
	# Target init and root fs are derived from the case name
	# "<host>-<fs>-systemd-to-gentoo-<target>" rather than stored as
	# separate INIT/FS keys in the conf.
	local casedir; casedir=$(basename "$conf" .conf)
	local FS INIT
	FS=${casedir#*-}; FS=${FS%%-systemd-to-gentoo-*}; FS=${FS#*-}
	INIT=${casedir##*-}
	local ssh_port=$((BASE_SSH_PORT + idx)) mon_port=$((BASE_MON_PORT + idx))
	# results directory follows the conf file name; NAME (without the
	# numeric prefix) is used for the VM/domain name
	local dir="$RUN_DIR/$casedir"
	mkdir -p "$dir"
	local overlay="$dir/overlay.qcow2" seed="$dir/seed.iso"
	local status="FAIL" phase="startup"

	mkdir "$dir/lock" 2>/dev/null || die "case $NAME is already running (stale lock at $dir/lock)"

	_fail() { # <phase> <message>
		phase=$1
		say "[$NAME] FAIL: $2"
		echo "$phase FAIL" > "$dir/result"
		return 1
	}

	# Bake the paths into the trap command: on subshell EXIT the function
	# frame and its locals are already gone.
	# shellcheck disable=SC2064
	trap "vm_stop '$dir' '$mon_port' 2>/dev/null || true" EXIT

	say "[$NAME] starting (golden=$GOLDEN init=$INIT fs=$FS)"
	vm_make_overlay "$overlay" "$GOLDEN_DIR/$GOLDEN"
	gen_seed "$seed" "$NAME"
	vm_start "$dir" "$overlay" "$seed" "$NAME" "$ssh_port" "$mon_port"

	if ! vm_wait_ssh "$ssh_port" "$BOOT_TIMEOUT"; then
		_fail boot "guest never came up over SSH; see $dir/serial.log"
		return 1
	fi
	phase="prepare"
	say "[$NAME] guest is up, injecting markers and script"
	vm_ssh "$ssh_port" -- 'echo preserved >/root/d2g-marker-root
		mkdir -p /home && echo preserved >/home/d2g-marker-home
		echo oldetc >/etc/d2g-marker-etc' \
		|| { _fail prepare "could not inject markers"; return 1; }

	vm_scp_up "$ssh_port" "$REPO_ROOT/distro2gentoo.sh" "/root/distro2gentoo.sh" \
		|| { _fail prepare "could not upload distro2gentoo.sh"; return 1; }

	cat >"$dir/d2g-runner.sh" <<EOF
#!/usr/bin/env bash
export D2G_NONINTERACTIVE=1
export D2G_COUNTDOWN=0
export D2G_MIRROR='$D2G_MIRROR'
export D2G_GIT_MIRROR='$D2G_GIT_MIRROR'
export D2G_STAGE3_REGEX='$STAGE3_REGEX'
timeout $RUN_TIMEOUT bash /root/distro2gentoo.sh
rc=\$?
echo D2G_EXIT=\$rc
exit \$rc
EOF
	vm_scp_up "$ssh_port" "$dir/d2g-runner.sh" "/root/d2g-runner.sh" \
		|| { _fail prepare "could not upload d2g-runner.sh"; return 1; }

	phase="convert"
	say "[$NAME] running distro2gentoo (this is the long phase, up to ${RUN_TIMEOUT}s)"
	# conversion legitimately runs for tens of minutes; lift the ssh cap.
	# Run it in the background and emit a status heartbeat every
	# D2G_STATUS_INTERVAL seconds: the guest output only lands in
	# conversion.log, so without this the CI job log stays silent for
	# the whole phase.
	D2G_SSH_TIMEOUT="$RUN_TIMEOUT" vm_ssh "$ssh_port" -- 'bash /root/d2g-runner.sh 2>&1 | tee /root/d2g-run.log' \
		>"$dir/conversion.log" 2>&1 &
	local conv_pid=$! conv_waited=0 conv_beat=0 conv_rc=0
	while kill -0 "$conv_pid" 2>/dev/null; do
		sleep 5
		conv_waited=$((conv_waited + 5))
		if (( conv_waited - conv_beat >= D2G_STATUS_INTERVAL )); then
			conv_beat=$conv_waited
			# sed (not tail): conversion.log grows while we read it, and
			# a racing tail -n1 can emit more than one line
			say "[$NAME] converting: ${conv_waited}s elapsed; last: $(
				sed -n '$p' "$dir/conversion.log" 2>/dev/null | cut -c1-160)"
		fi
	done
	wait "$conv_pid" || conv_rc=$?
	if (( conv_rc != 0 )); then
		_fail convert "conversion transport failed (check $dir/conversion.log)"
		return 1
	fi
	grep -q '^D2G_EXIT=0' "$dir/conversion.log" || {
		_fail convert "conversion reported non-zero exit (check $dir/conversion.log)"
		return 1
	}
	collect_guest_diagnostics "$ssh_port" "$dir" pre-reboot

	phase="reboot"
	say "[$NAME] conversion finished, hard resetting VM and booting Gentoo"
	vm_reset "$mon_port"
	say "[$NAME] reset sent, waiting for Gentoo SSH (up to ${REBOOT_TIMEOUT}s)"
	if ! vm_wait_ssh "$ssh_port" "$REBOOT_TIMEOUT"; then
		_fail reboot "Gentoo did not come up after reboot; see $dir/serial.log"
		return 1
	fi

	phase="verify"
	say "[$NAME] Gentoo is up, running verification checks"
	vm_scp_up "$ssh_port" "$HERE/verify-guest.sh" "/root/verify-guest.sh" \
		|| { _fail verify "could not upload verify-guest.sh"; return 1; }
	# stream the checks to the console as well as verify.log: tee keeps
	# the artifact verbatim, sed -u (unbuffered) prefixes each line with
	# the case name so parallel (-j) output stays attributable. The if
	# still sees the guest exit code because pipefail is set.
	if vm_ssh "$ssh_port" -- "bash /root/verify-guest.sh '$INIT' '$FS' '$D2G_MIRROR'" 2>&1 \
			| tee "$dir/verify.log" | sed -u "s|^|[$NAME] |"; then
		status="PASS"
		say "[$NAME] PASS"
	else
		say "[$NAME] FAIL: verification (see $dir/verify.log)"
	fi
	collect_guest_diagnostics "$ssh_port" "$dir" post-reboot
	echo "$phase $status" > "$dir/result"
	rmdir "$dir/lock" 2>/dev/null || true
	[[ $status == PASS ]]
}

# select requested cases
SELECTED=()
for ((i=0; i<${#ALL_CASES[@]}; i++)); do
	c="${ALL_CASES[$i]}"
	name="$(basename "$c" .conf)"
	if [[ $# -eq 0 ]] || printf '%s\n' "${WANTED[@]}" | grep -Fxq "$name"; then
		SELECTED+=("$i:$c")
	fi
done
[[ ${#SELECTED[@]} -gt 0 ]] || die "no matching cases"

say "running ${#SELECTED[@]} case(s), parallelism $J, run dir $RUN_DIR"
running=0 next=0 failures=0

while (( next < ${#SELECTED[@]} || running > 0 )); do
	while (( next < ${#SELECTED[@]} && running < J )); do
		entry="${SELECTED[$next]}"
		idx=${entry%%:*}; conf=${entry#*:}
		( run_case "$idx" "$conf" ) &
		running=$((running + 1))
		next=$((next + 1))
	done
	(( running > 0 )) || break
	# errexit must not kill the run when a case fails
	if wait -n; then rc=0; else rc=$?; fi
	running=$((running - 1))
	if (( rc != 0 )); then
		failures=$((failures + 1))
	fi
done

section "RESULTS ($RUN_ID)"
{	echo "case,phase,status"
	for entry in "${SELECTED[@]}"; do
		name="$(basename "${entry#*:}" .conf)"
		if [[ -f $RUN_DIR/$name/result ]]; then
			read -r phase status < "$RUN_DIR/$name/result"
		else
			phase=- status=UNKNOWN
		fi
		printf '%s,%s,%s\n' "$name" "$phase" "$status"
	done
} | tee "$RUN_DIR/summary.csv"

say "logs: $RUN_DIR"
exit "$failures"
