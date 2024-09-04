
distro2gentoo.sh: src/00-pre.sh src/_do.sh src/_log.sh src/01-helper.sh src/02-parameters.sh src/03-downloads.sh src/04-prerequisites.sh src/05-mirror.sh src/06-stage3.sh src/07-storageHelper.sh src/08-chroot.sh src/09-pkg.sh src/10-network.sh src/11-bootloader.sh src/12-suf.sh
	@head -6 src/00-pre.sh | grep -h -E '^#' >$@
	@grep -h -vE '^#' $^ >>$@
	@chmod +x $@

.PHONY: clean

clean:
	@rm -f distro2gentoo.sh
