#!/usr/bin/env bash
# aimg2pkg — turn an AppImage into a pacman -bin package.
#
# One tool, five subcommands, each doing exactly one job:
#
#   aimg2pkg setup   <path-to.AppImage>        move it in, extract it, report deps
#   aimg2pkg deps    <name>                     re-run the dependency check only
#   aimg2pkg convert <name> [pkgver] [pkgrel]  build the payload tarball + PKGBUILD
#   aimg2pkg build   <name>                     makepkg -f
#   aimg2pkg install <name>                     pacman -U the built package
#
# <name> is derived automatically from the AppImage's filename during
# setup (e.g. "RawTherapee_5_12_release.AppImage" -> "rawtherapee"). Every
# command after setup takes that same short name — nothing else to track.
#
# This script is self-locating: it finds the repo root relative to its own
# path (one directory up from wherever aimg2pkg.sh itself lives), so it
# works identically whether you call it from the repo root, from inside
# .AppImage/<name>/, or via an absolute path from anywhere else.
#
# Layout this tool creates, relative to the repo root:
#
#   .AppImage/<name>/
#     src/<original>.AppImage   the file you gave it, moved here
#     extracted/                squashfs-root, kept for deps/convert reuse
#     Makefile                  generated — cd here, run bare `make convert` etc
#     out/
#       PKGBUILD
#       <name>-bin-<ver>-<rel>-x86_64.tar.zst       payload (local source, no upload needed)
#       <name>-bin-<ver>-<rel>-x86_64.pkg.tar.zst   after `build`
#
# .AppImage/ should be in .gitignore — it's scratch space. Only the final
# .pkg.tar.zst (which you copy into x86_64/ yourself) is ever published.

set -euo pipefail

SELF="$(basename "$0")"
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF_ABS")/.." >/dev/null 2>&1 && pwd)"
STATE_DIR="$ROOT/.AppImage"

# System-facing share/ subdirs — these go to the real /usr/share for desktop
# integration. Everything else in usr/share is private runtime data (glib
# schemas, lens databases, themes...) and goes under the app's own prefix.
SYSTEM_SHARE_DIRS=(applications icons man metainfo mime pixmaps)

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# name derivation: "RawTherapee_5_12_release.AppImage" -> "rawtherapee"
# ---------------------------------------------------------------------------
normalize_name() {
	local base="${1%.*}"
	local -a toks
	IFS='-_' read -ra toks <<< "$base"
	local noise='^([0-9]+([.][0-9]+)*|v[0-9].*|release|stable|beta|alpha|rc[0-9]*|linux|x86|x86_64|amd64|appimage|bin|portable|final|build[0-9]*)$'
	local end=${#toks[@]}
	while [ "$end" -gt 1 ]; do
		local tok_lower
		tok_lower=$(tr '[:upper:]' '[:lower:]' <<< "${toks[$((end-1))]}")
		[[ "$tok_lower" =~ $noise ]] || break
		end=$((end-1))
	done
	local out=""
	for ((i=0; i<end; i++)); do
		out+="${toks[$i]}"
		[ "$i" -lt "$((end-1))" ] && out+="-"
	done
	tr '[:upper:]' '[:lower:]' <<< "$out"
}

# ---------------------------------------------------------------------------
# resolve <name> -> its app dir, failing clearly if setup was never run
# ---------------------------------------------------------------------------
app_dir() {
	local name="$1"
	local dir="$STATE_DIR/$name"
	[ -d "$dir" ] || die "no .AppImage/$name/ — run: $SELF setup <path-to.AppImage>"
	echo "$dir"
}

require_tools() {
	local missing=()
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing+=("$t")
	done
	[ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# ---------------------------------------------------------------------------
# setup: move the AppImage in, extract it, report deps, write the per-app Makefile
# ---------------------------------------------------------------------------
cmd_setup() {
	local src="${1:-}"
	[ -n "$src" ] || die "usage: $SELF setup <path-to.AppImage>"
	[ -f "$src" ] || die "not found: $src"
	require_tools file tar realpath

	src="$(realpath "$src")"
	local fname name dir
	fname="$(basename "$src")"
	name="$(normalize_name "$fname")"
	[ -n "$name" ] || die "could not derive a name from '$fname' — rename the file and retry"
	dir="$STATE_DIR/$name"

	note "app name: $name"
	mkdir -p "$dir/src"

	if [ -f "$dir/src/$fname" ]; then
		note "already present at .AppImage/$name/src/$fname — leaving it"
	else
		note "moving $fname into .AppImage/$name/src/"
		cp "$src" "$dir/src/$fname"
	fi
	chmod +x "$dir/src/$fname"

	note "extracting"
	rm -rf "$dir/extracted"
	( cd "$dir/src" && "./$fname" --appimage-extract >/dev/null && mv squashfs-root "$dir/extracted" )
	[ -d "$dir/extracted/usr" ] || die "no usr/ found after extraction — unexpected AppImage layout"

	write_app_makefile "$name" "$dir"
	note "setup complete: .AppImage/$name/"
	echo "    cd .AppImage/$name && make convert   # no arguments needed from here on"
	cmd_deps "$name"
}

# ---------------------------------------------------------------------------
# generate a thin per-app Makefile: cd .AppImage/<name> && make deps/convert/
# build/install just works, zero arguments. Calls this same script directly
# by its absolute path — one hop, no bouncing through a root Makefile.
# ---------------------------------------------------------------------------
write_app_makefile() {
	local name="$1" dir="$2"
	cat > "$dir/Makefile" <<MAKEFILE_EOF
# Auto-generated by aimg2pkg setup — re-running setup overwrites this file,
# so don't hand-edit it. Every target here needs zero arguments; the name
# is already baked in. Override PKGVER/PKGREL only if convert guessed wrong:
#   make convert PKGVER=1.2.3
NAME := ${name}
SCRIPT := ${SELF_ABS}
PKGVER ?=
PKGREL ?= 1
MAKEFLAGS += --no-print-directory

.PHONY: help deps convert build install

help:
	@echo "make deps / convert / build / install"
	@echo "      (zero arguments needed there — setup already filled it in)"
	@echo
	@echo "make list   — show every app tracked under .AppImage/"

deps:
	@\$(SCRIPT) deps \$(NAME)

convert: deps
	@\$(SCRIPT) convert \$(NAME) "\$(PKGVER)" "\$(PKGREL)"

build: convert
	@\$(SCRIPT) build \$(NAME)

install: build
	@\$(SCRIPT) install \$(NAME)

copy:
	 @cp out/*.pkg.tar.zst ../../x86_64/

MAKEFILE_EOF
}

# ---------------------------------------------------------------------------
# deps: ldd every detected binary, auto-copy any bundled lib that's missing
# from the payload's search path, and report anything genuinely absent
# ---------------------------------------------------------------------------
cmd_deps() {
	local name="${1:-}"
	[ -n "$name" ] || die "usage: $SELF deps <name>"
	require_tools ldd find
	local dir; dir="$(app_dir "$name")"
	local root="$dir/extracted"
	[ -d "$root" ] || die "not extracted yet — run: $SELF setup <path>"

	mapfile -t bins < <(
		find "$root/usr/bin" -maxdepth 1 -type f -executable -exec sh -c \
			'file -b "$1" | grep -q "^ELF" && echo "$1"' _ {} \;
	)
	[ "${#bins[@]}" -gt 0 ] || die "no ELF executables found in usr/bin"

	local libdir="$root/usr/lib"
	local missing_report="$dir/MISSING-DEPS.txt"
	: > "$missing_report"

	note "checking ${#bins[@]} executable(s) against bundled + system libraries"
	local any_missing=0
	for b in "${bins[@]}"; do
		local unresolved
		unresolved=$(LD_LIBRARY_PATH="$libdir" ldd "$b" 2>/dev/null | awk '/not found/{print $1}') || true
		[ -z "$unresolved" ] && continue

		while IFS= read -r lib; do
			[ -z "$lib" ] && continue
			# maybe it exists somewhere else inside the AppImage but just
			# wasn't in usr/lib directly (some bundlers nest things) — find
			# and copy it in rather than reporting a false failure.
			local found
			found=$(find "$root" -iname "$lib" 2>/dev/null | head -n1) || true
			if [ -n "$found" ]; then
				mkdir -p "$libdir"
				cp -n "$found" "$libdir/" 2>/dev/null || true
				note "  recovered $lib from within the AppImage (was nested, now in usr/lib)"
			else
				echo "$lib" >> "$missing_report"
				any_missing=1
			fi
		done <<< "$unresolved"
	done

	if [ "$any_missing" -eq 1 ]; then
		sort -u -o "$missing_report" "$missing_report"
		echo
		echo "!! Missing at runtime (not bundled, not on this system):"
		sed 's/^/     /' "$missing_report"
		echo
		if command -v pkgfile >/dev/null 2>&1; then
			echo "   Looking up owning packages via pkgfile:"
			while IFS= read -r lib; do
				pkgfile -b "$lib" 2>/dev/null | sed "s/^/     $lib -> /" || echo "     $lib -> (no match, search https://archlinux.org/packages/ manually)"
			done < "$missing_report"
		else
			echo "   Install 'pkgfile' (then 'pkgfile -u') so this can suggest the"
			echo "   owning pacman package automatically. For now, search each name"
			echo "   at https://archlinux.org/packages/ or https://aur.archlinux.org"
			echo "   and add the right package to depends=() in the PKGBUILD."
		fi
		echo
		echo "   Full list saved to: $missing_report"
	else
		rm -f "$missing_report"
		note "all runtime dependencies resolved (bundled or already on this system)"
	fi
}

# ---------------------------------------------------------------------------
# convert: assemble the payload (private prefix + wrapper scripts +
# split share dirs), tar it, write the PKGBUILD
# ---------------------------------------------------------------------------
cmd_convert() {
	local name="${1:-}" pkgver="${2:-}" pkgrel="${3:-1}"
	[ -n "$name" ] || die "usage: $SELF convert <name> [pkgver] [pkgrel]"
	require_tools tar zstd sha256sum find file

	local dir; dir="$(app_dir "$name")"
	local root="$dir/extracted"
	[ -d "$root" ] || die "not extracted yet — run: $SELF setup <path>"

	if [ -z "$pkgver" ]; then
		local aimg; aimg=$(find "$dir/src" -maxdepth 1 -iname "*.AppImage" | head -n1)
		pkgver=$(basename "$aimg" | grep -oE '[0-9]+([._][0-9]+){1,3}' | head -n1 | tr '_' '.') || true
		[ -n "$pkgver" ] || die "couldn't guess pkgver — pass one: $SELF convert $name <pkgver>"
		note "guessed pkgver: $pkgver (pass one explicitly if wrong)"
	fi

	local pkgname="${name}-bin"
	local prefix="/opt/${pkgname}"
	local out="$dir/out"
	local tarball="${pkgname}-${pkgver}-${pkgrel}-x86_64.tar.zst"
	local payload; payload="$(mktemp -d)"

	mkdir -p "$out" "$payload/opt/${pkgname}" "$payload/usr/bin"

	note "copying bin/ and lib/ into private prefix"
	[ -d "$root/usr/bin" ] && cp -a "$root/usr/bin" "$payload/opt/${pkgname}/bin"
	[ -d "$root/usr/lib" ] && cp -a "$root/usr/lib" "$payload/opt/${pkgname}/lib"

	note "sorting usr/share into system vs. private locations"
	if [ -d "$root/usr/share" ]; then
		for d in "$root"/usr/share/*/; do
			local dname; dname="$(basename "$d")"
			local is_system=0
			for s in "${SYSTEM_SHARE_DIRS[@]}"; do
				[ "$dname" = "$s" ] && is_system=1 && break
			done
			if [ "$is_system" = 1 ]; then
				mkdir -p "$payload/usr/share"
				cp -a "$d" "$payload/usr/share/$dname"
			else
				mkdir -p "$payload/opt/${pkgname}/share"
				cp -a "$d" "$payload/opt/${pkgname}/share/$dname"
			fi
		done
		# hicolor-icon-theme (a base system package) already owns this file
		rm -f "$payload/usr/share/icons/hicolor/index.theme"
	fi

	note "detecting executables to wrap"
	mapfile -t bins < <(
		find "$root/usr/bin" -maxdepth 1 -type f -executable -exec sh -c \
			'file -b "$1" | grep -q "^ELF" && basename "$1"' _ {} \;
	)
	[ "${#bins[@]}" -gt 0 ] || die "no ELF executables found in usr/bin"
	note "  found: ${bins[*]}"

	# universal-ish toolkit detection: only add env vars for machinery that's
	# actually present, instead of assuming GTK (or anything else) up front.
	local pixbuf_cache gtk_dir gi_dir schema_rel qt_plugin_rel
	pixbuf_cache=$(find "$root/usr/lib" -iname "loaders.cache" 2>/dev/null | head -n1) || true
	gtk_dir=$(find "$root/usr/lib" -maxdepth 1 -type d -name "gtk-*" 2>/dev/null | head -n1) || true
	gi_dir=$(find "$root/usr/lib" -maxdepth 1 -type d -name "girepository-1.0" 2>/dev/null) || true
	[ -d "$root/usr/share/glib-2.0/schemas" ] && schema_rel="share/glib-2.0/schemas" || schema_rel=""
	qt_plugin_rel=""
	for cand in "$root"/usr/lib/qt*/plugins "$root"/usr/plugins "$root"/usr/lib/*/qt*/plugins; do
		[ -d "$cand" ] || continue
		qt_plugin_rel="lib/${cand#"$root/usr/lib/"}"
		break
	done

	note "writing wrapper scripts"
	for bin in "${bins[@]}"; do
		local wrapper="$payload/usr/bin/$bin"
		{
			echo '#!/bin/sh'
			echo "# wrapper for the AppImage-derived '$bin' binary — runs it against"
			echo "# its own private lib/share prefix instead of the system's."
			echo "PREFIX=$prefix"
			echo
			echo 'export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"'
			if [ -n "$pixbuf_cache" ] || [ -n "$gtk_dir" ] || [ -n "$schema_rel" ]; then
				echo 'export GTK_DATA_PREFIX="$PREFIX"'
				echo 'export GTK_EXE_PREFIX="$PREFIX"'
				echo 'export GDK_BACKEND="${GDK_BACKEND:-x11}"'
				echo 'export XDG_DATA_DIRS="$PREFIX/share:/usr/share:${XDG_DATA_DIRS:-/usr/local/share}"'
				[ -n "$schema_rel" ] && echo "export GSETTINGS_SCHEMA_DIR=\"\$PREFIX/$schema_rel\""
				[ -n "$gi_dir" ] && echo 'export GI_TYPELIB_PATH="$PREFIX/lib/girepository-1.0"'
				if [ -n "$gtk_dir" ]; then
					local gtk_rel="lib/$(basename "$gtk_dir")"
					echo "export GTK_PATH=\"\$PREFIX/$gtk_rel\""
					local immodules; immodules=$(find "$gtk_dir" -iname "immodules.cache" 2>/dev/null | head -n1) || true
					if [ -n "$immodules" ]; then
						local irel=${immodules#"$root/usr/lib/"}
						echo "export GTK_IM_MODULE_FILE=\"\$PREFIX/lib/$irel\""
					fi
				fi
				if [ -n "$pixbuf_cache" ]; then
					local prel=${pixbuf_cache#"$root/usr/lib/"}
					echo "export GDK_PIXBUF_MODULE_FILE=\"\$PREFIX/lib/$prel\""
				fi
			fi
			if [ -n "$qt_plugin_rel" ]; then
				echo "export QT_PLUGIN_PATH=\"\$PREFIX/$qt_plugin_rel\""
				echo "export QT_QPA_PLATFORM_PLUGIN_PATH=\"\$PREFIX/$qt_plugin_rel/platforms\""
			fi
			echo
			echo "exec \"\$PREFIX/bin/$bin\" \"\$@\""
		} > "$wrapper"
		chmod +x "$wrapper"
	done

	note "building payload tarball: $tarball"
	( cd "$payload" && tar -cf - opt usr | zstd -19 -T0 -o "$out/$tarball" )
	local sha256; sha256=$(sha256sum "$out/$tarball" | awk '{print $1}')
	note "  sha256: $sha256"

	note "writing PKGBUILD"
	local depends="'glibc'"
	[ -n "$pixbuf_cache" ] && depends="$depends 'gtk3' 'hicolor-icon-theme'"
	[ -n "$qt_plugin_rel" ] && depends="$depends 'qt5-base'"

	cat > "$out/PKGBUILD" <<PKGBUILD_EOF
# Maintainer: you
pkgname=${pkgname}
pkgver=${pkgver}
pkgrel=${pkgrel}
pkgdesc="${name} (repackaged from the official AppImage, bundled libs)"
arch=('x86_64')
url="https://example.com/"  # fill in
license=('unknown')          # fill in the real license
depends=(${depends})
provides=('${name}')
conflicts=('${name}' '${name}-git' '${name}-bin')
options=('!strip' '!debug')
# Local source — the tarball sits right here, no upload/network needed to
# build. This is intentional: end users installing via pacman -S never
# run makepkg at all, they just get the prebuilt .pkg.tar.zst from your repo.
source=("${tarball}")
sha256sums=('${sha256}')

package() {
	cp -a opt "\$pkgdir/"
	cp -a usr "\$pkgdir/"
}
PKGBUILD_EOF

	note "done: $out"
	ls -la "$out"
	rm -rf "$payload"
	if [ -f "$dir/MISSING-DEPS.txt" ]; then
		echo
		echo "!! reminder: $dir/MISSING-DEPS.txt lists unresolved runtime deps —"
		echo "   review before shipping this package."
	fi
}

# ---------------------------------------------------------------------------
# build: makepkg -f in the app's out/ dir
# ---------------------------------------------------------------------------
cmd_build() {
	local name="${1:-}"
	[ -n "$name" ] || die "usage: $SELF build <name>"
	require_tools makepkg
	local dir; dir="$(app_dir "$name")"
	local out="$dir/out"
	[ -f "$out/PKGBUILD" ] || die "no PKGBUILD — run: $SELF convert $name first"
	( cd "$out" && rm -rf pkg src *.pkg.tar.zst && makepkg -f )
}

# ---------------------------------------------------------------------------
# install: pacman -U the built package
# ---------------------------------------------------------------------------
cmd_install() {
	local name="${1:-}"
	[ -n "$name" ] || die "usage: $SELF install <name>"
	require_tools pacman sudo
	local dir; dir="$(app_dir "$name")"
	local out="$dir/out"
	shopt -s nullglob
	local pkgs=("$out"/*.pkg.tar.zst)
	shopt -u nullglob
	[ "${#pkgs[@]}" -gt 0 ] || die "no built package — run: $SELF build $name first"
	sudo pacman -U "${pkgs[@]}"
}

# ---------------------------------------------------------------------------
# list: show every app currently tracked under .AppImage/
# ---------------------------------------------------------------------------
cmd_list() {
	shopt -s nullglob
	local dirs=("$STATE_DIR"/*/)
	shopt -u nullglob
	if [ "${#dirs[@]}" -eq 0 ]; then
		echo "(none yet — run: $SELF setup <path-to.AppImage>)"
		return
	fi
	for d in "${dirs[@]}"; do
		local n; n="$(basename "$d")"
		local stage="setup"
		[ -f "$d/out/PKGBUILD" ] && stage="converted"
		shopt -s nullglob
		local pkgs=("$d/out/"*.pkg.tar.zst)
		shopt -u nullglob
		[ "${#pkgs[@]}" -gt 0 ] && stage="built"
		printf "  %-20s %s\n" "$n" "$stage"
	done
}

# ---------------------------------------------------------------------------
main() {
	local cmd="${1:-}"; shift || true
	case "$cmd" in
		setup)   cmd_setup "$@" ;;
		deps)    cmd_deps "$@" ;;
		convert) cmd_convert "$@" ;;
		build)   cmd_build "$@" ;;
		install) cmd_install "$@" ;;
		list)    cmd_list "$@" ;;
		*)
			cat >&2 <<USAGE
usage: $SELF <subcommand> ...

  setup   <path-to.AppImage>          move it in, extract it, report deps
  deps    <name>                       re-run the dependency check only
  convert <name> [pkgver] [pkgrel]    build payload tarball + PKGBUILD
  build   <name>                       makepkg -f
  install <name>                       pacman -U the built package
  list                                  show every app tracked so far

<name> is derived automatically from the AppImage's filename during setup
(e.g. "RawTherapee_5_12_release.AppImage" -> "rawtherapee"). Every command
after setup takes that same short name — nothing else to track. Or just
cd into .AppImage/<name>/ and run bare 'make convert' / 'make build' /
'make install' — the per-app Makefile setup writes there needs no
arguments at all.
USAGE
			exit 1
			;;
	esac
}

main "$@"
