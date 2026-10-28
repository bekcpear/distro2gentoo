#!/usr/bin/env bash
export D2G_NONINTERACTIVE=1
export D2G_COUNTDOWN=0
export D2G_MIRROR='https://mirrors.bfsu.edu.cn/gentoo'
export D2G_GIT_MIRROR='https://mirrors.bfsu.edu.cn/git/gentoo-portage.git'
export D2G_STAGE3_REGEX='^stage3-arm64-openrc-'
timeout 7200 bash /root/distro2gentoo.sh
rc=$?
echo D2G_EXIT=$rc
exit $rc
