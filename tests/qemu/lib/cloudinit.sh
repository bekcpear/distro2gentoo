# cloud-init NoCloud seed generation. Uses only stock host tools:
# hdiutil on macOS, genisoimage/mkisofs/xorrisofs on Linux.

ensure_ssh_key() {
	if [[ ! -f $SSH_KEY ]]; then
		say "generating test SSH key $SSH_KEY"
		ssh-keygen -t ed25519 -N '' -C d2g-test -f "$SSH_KEY" -q
	fi
}

# gen_seed <output.iso> <hostname>
gen_seed() {
	local out=$1 hostname=$2
	ensure_ssh_key
	local stage pub
	stage="$(mktemp -d "${TMPDIR:-/tmp}/d2g-seed.XXXXXX")"
	mkdir -p "$stage/cidata"
	pub="$(cat "${SSH_KEY}.pub")"

	cat > "$stage/cidata/meta-data" <<EOF
instance-id: d2g-${hostname}
local-hostname: ${hostname}
EOF

	# Keep the images' default user list untouched; we only need root.
	# Cloud images default to PermitRootLogin prohibit-password, so the
	# injected key alone is sufficient; the password is a fallback.
	cat > "$stage/cidata/user-data" <<EOF
#cloud-config
hostname: ${hostname}
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: d2gtest
      type: text
write_files:
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    owner: root:root
    content: |
      ${pub}
runcmd:
  - [ sh, -c, "mkdir -p /root/.ssh && chmod 700 /root/.ssh && chown root:root /root/.ssh && (grep -q '${pub}' /root/.ssh/authorized_keys 2>/dev/null || echo '${pub}' >> /root/.ssh/authorized_keys); chmod 600 /root/.ssh/authorized_keys" ]
EOF

	# the ISO tool refuses to overwrite an existing image
	rm -f "$out"
	# An ISO9660/Joliet image labelled CIDATA is what cloud-init's
	# NoCloud datasource recognises.
	if command -v hdiutil >/dev/null; then
		hdiutil makehybrid -iso -joliet -default-volume-name CIDATA \
			-o "$out" "$stage/cidata" >/dev/null
	elif command -v genisoimage >/dev/null; then
		genisoimage -quiet -J -V CIDATA -o "$out" "$stage/cidata" >/dev/null
	elif command -v mkisofs >/dev/null; then
		mkisofs -quiet -J -V CIDATA -o "$out" "$stage/cidata" >/dev/null
	elif command -v xorrisofs >/dev/null; then
		xorrisofs -quiet -J -V CIDATA -o "$out" "$stage/cidata" >/dev/null
	else
		die "no ISO9660 tool found (hdiutil on macOS; genisoimage/mkisofs/xorriso on Linux)"
	fi
	rm -rf "$stage"
	[[ -s $out ]] || die "failed to create cloud-init seed $out"
}
