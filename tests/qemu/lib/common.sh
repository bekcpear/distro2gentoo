# Small logging helpers for the harness itself (host side).

ts() { date '+%H:%M:%S'; }

say() { echo "[$(ts)] $*"; }
die() { say "FATAL: $*" >&2; exit 1; }
section() { echo; echo "==== $* ===="; }
