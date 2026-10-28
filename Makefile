# '_' sorts after digits, so the library files must be listed explicitly:
# a plain sort of the wildcard would place them after 13-main.sh, whose top
# level already invokes main "$@" before they would be defined.
LIB := src/_log.sh src/_do.sh
SRC := src/00-pre.sh $(LIB) \
       $(filter-out src/00-pre.sh $(LIB),$(sort $(wildcard src/*.sh)))

# Assemble the distributable single-file script:
#   - the shebang of 00-pre.sh is kept as the first line
#   - lines starting with '##' are comments that ship in the product
#     (one leading '#' is removed when assembling)
#   - every other full-line comment is source-only and gets stripped
# Build via a temp file so an awk failure cannot leave a truncated target with
# a fresh mtime (which would make every later `make` a silent no-op).
distro2gentoo.sh: $(SRC) Makefile
	@tmp="$@.tmp"; \
	awk 'FNR==1 && NR==1 && $$0 ~ /^#!/ {print; next} /^##/ {sub(/^#/, ""); print; next} /^#/ {next} {print}' $(SRC) > $$tmp \
	  && chmod +x $$tmp \
	  && mv -f $$tmp $@ \
	  || { rm -f $$tmp; exit 1; }

.PHONY: clean rebuild

clean:
	@rm -f distro2gentoo.sh

# Force a rebuild after git operations that refresh the tracked target's mtime
# (pull/checkout/switch/restore/reset/stash).
rebuild:
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory distro2gentoo.sh
