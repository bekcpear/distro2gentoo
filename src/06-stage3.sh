#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

getStage3() {
	_log i "Getting stage3 tarball ..."

	local stage3_list_url="${MIRROR%/}/releases/${CPUARCH}/autobuilds/latest-stage3.txt"
	local local_stage3_list="${TMP_DIR}/latest-stage3.txt"
	local relative_path stage3_size selected_stage3 selected_stage3_tmp
	local -a stage3s_names stage3s_paths stage3s_sizes

	_log i "Getting stage3 tarball list ..."

	download "$stage3_list_url" "${local_stage3_list}.with-gpg-signature"
	gpgDecryptAndOutput "${local_stage3_list}.with-gpg-signature" "$local_stage3_list"

	while read -r relative_path stage3_size _; do
		if [[ $relative_path =~ ^[[:space:]]*#|^[[:space:]]*$ ]]; then
			continue
		fi
		stage3s_names+=( "${relative_path##*/}" )
		stage3s_paths+=( "$relative_path" )
		stage3s_sizes+=( "$stage3_size" )
	done <"$local_stage3_list"

	_log n "stage3 list:"
	for (( i=0; i < ${#stage3s_names[@]}; ++i )); do
		local _stage=${stage3s_names[i]}
		if [[ ! ${_stage} =~ ^stage3 ]]; then
			# don't unset these until the problem of index 'i' solved
			#unset 'stage3s_names[i]' 'stage3s_paths[i]' 'stage3s_sizes[i]'
			continue
		fi

		# default to openrc
		if [[ ${_stage} =~ ^stage3-amd64-openrc-2|stage3-arm64-openrc-2 ]]; then
			selected_stage3=${i}
			_log n " -*- [${i}] ${_stage}"
		else
			_log n "     [${i}] ${_stage}"
		fi
	done

	if (( ${#stage3s_names[@]} < 1 )); then
		_log ee "No stage3 list, please check the mirror URL or your network."
	fi

	while :; do
		read -r -p "Choose prefered stage3 tarball (enter the num, empty for the default): " selected_stage3_tmp
		if [[ -z ${selected_stage3_tmp} ]]; then
			if [[ $selected_stage3 == "" || -z $selected_stage3 ]]; then
				_log e "No default stage3 selected, please select one!"
			else
				_log i "Use the default stage3."
				break
			fi
		fi
		if [[ ${selected_stage3_tmp} =~ ^[[:digit:]]+$ ]] && [[ -n ${stage3s_names[${selected_stage3_tmp}]} ]]; then
			selected_stage3=${selected_stage3_tmp}
			break;
		else
			_log e "Out of range, please select a valid one!"
		fi
	done

	_log i "selected stage3: ${stage3s_names[${selected_stage3}]}"

	# prepare signature
	local stage3_asc="/${stage3s_names[${selected_stage3}]}.asc"
	downloadForce "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}.asc" "$stage3_asc"

	# prepare stage3 tarball
	STAGE3_TARBALL="/${stage3s_names[${selected_stage3}]}"
	local stage3_tarball_exists
	if [[ -f $STAGE3_TARBALL ]]; then
		if gpgVerifyDetachedFile "$STAGE3_TARBALL" "$stage3_asc"; then
			stage3_tarball_exists=1
		fi
	fi
	if [[ $stage3_tarball_exists != 1 ]]; then
		download "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}" "$STAGE3_TARBALL"

		# verify stage3 tarball and download again if doesn't match
		local tries=1
		while ! gpgVerifyDetachedFile "$STAGE3_TARBALL" "$stage3_asc"; do
			downloadForce "${stage3_list_url%/*}/${stage3s_paths[${selected_stage3}]}" "$STAGE3_TARBALL"
			tries=$((tries + 1))
			if (( tries > 3 )); then
				_log ee "The downloaded stage3 tarball '$STAGE3_TARBALL' doesn't match its asc file, abort!"
			fi
		done
	fi
	_log i "Stage3 tarball has been stored as '$STAGE3_TARBALL'."
}

unpackStage3ToNEWROOT() {
	pushd "$NEWROOT" || _log ee "Pushd '$NEWROOT' failed!"

	_log w "Untaring stage3 tarball ..."
	_log w ">>> tar xpf \"$STAGE3_TARBALL\" --xattrs-include='*.*' --numeric-owner"
	tar xpf "$STAGE3_TARBALL" --xattrs-include='*.*' --numeric-owner

	popd || _log ee "Popd from '$NEWROOT' failed!"
}

