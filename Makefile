# Root Makefile — the only thing you do from here is `setup`.
#
#   make setup APPIMAGE=path/to/Foo.AppImage
#
# That's it. It prints an app name (e.g. "foo"), creates .AppImage/foo/,
# extracts the AppImage, checks its runtime deps, and writes a Makefile
# inside .AppImage/foo/ that needs zero arguments. From there:
#
#   cd .AppImage/foo
#   make deps       # re-check runtime deps
#   make convert    # build payload tarball + PKGBUILD
#   make build      # makepkg -f
#   make install    # pacman -U the result
#
# `make list` here shows every app you've set up so far, and what stage
# each one is at.

SHELL := /bin/bash
MAKEFLAGS += --no-print-directory

.PHONY: setup list help

help:
	@echo "make setup APPIMAGE=path/to/Foo.AppImage"
	@echo
	@echo "then: cd .AppImage/<name> && make deps / convert / build / install"
	@echo "      (zero arguments needed there — setup already filled it in)"
	@echo
	@echo "make list   — show every app tracked under .AppImage/"

setup:
	@test -n "$(APPIMAGE)" || (echo "APPIMAGE=<path-to.AppImage> is required" && exit 1)
	@./ayir/ayir.sh setup "$(APPIMAGE)"

list:
	@./ayir/ayir.sh list
