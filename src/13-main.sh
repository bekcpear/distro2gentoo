#
#  Author: Ryan Tsien @cwittlut <i@bitbili.net>
# License: GPL-2
#

main() {
	parseParams "$@"

	prerequisitesCheck
	firstTip

	mkdir -p "${NEWROOT}"
	prerequisitesSolve

	setupMirror

	getStage3
	unpackStage3ToNEWROOT

	prepareChroot

	setupGRUBCmdline

	preparePkgsConfiguration
	installPortageDB
	installNecessaryPkgs

	configureGentoo

	switchToGentoo
}

main "$@"

## Gentoo's /etc/profile (and the scripts it sources) may use a bare `return`,
## which would leave a caller function early, so this must stay at top level.
## It also puts the new system's binaries on PATH for configureGRUB below.
. /etc/profile
sync

finalize
