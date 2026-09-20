#!/usr/bin/env bash
set -euo pipefail

PKGS=(
    rawtherapee-git
    gameoftrees
    forkgram-bin
    latex-pdfpages
    cloudflare-warp-bin
    gimp-devel
    proton-authenticator-bin
    freetube
    localsend-bin
    sxwm
    libjpeg9
    libinput-gestures
    rofi-greenclip
    gtk-engine-murrine
    wlctl-bin
    xdman-beta-bin
    ghgrab-bin
    ibus-avro-git
    jdownloader2
    gtk2
    cropgui
)

REPONAME=ri
REPODIR="$(pwd)/x86_64"
CACHEDIR="$HOME/.cache/ri-update"
EDITOR=nvim

mode=full
TARGETS=()
no_install=0
yes=0
for arg in "${@:-}"; do
	[ -z "$arg" ] && continue
	case "$arg" in
		--sync-only) mode=sync ;;
		--push-only) mode=push ;;
		--no-install) no_install=1 ;;
		--yes|-y) yes=1 ;;
		--*) echo "usage: $0 [--sync-only|--push-only] [--no-install] [--yes] [pkg ...]"; exit 1 ;;
		*) TARGETS+=("$arg") ;;
	esac
done
# CI runs are non-interactive by definition: auto-confirm the push
[ -n "${CI:-}" ] && yes=1

full_run=1
if [ ${#TARGETS[@]} -eq 0 ]; then
	TARGETS=("${PKGS[@]}")
else
	full_run=0
	for t in "${TARGETS[@]}"; do
		found=0
		for pkg in "${PKGS[@]}"; do
			[ "$pkg" = "$t" ] && { found=1; break; }
		done
		[ "$found" -eq 1 ] || { echo "unknown package: $t (not in PKGS)"; exit 1; }
	done
fi

mkdir -p "$REPODIR" "$CACHEDIR"

installed_ver() {
	local pkg=$1 f name
	for f in "$REPODIR"/*.pkg.tar.zst; do
		[ -e "$f" ] || continue
		name=$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}')
		[ "$name" = "$pkg" ] || continue
		pacman -Qp "$f" | awk '{print $2}'
		return 0
	done
}

aur_ver() {
	local srcinfo=$1 name ver rel epoch
	name=$(awk -F' = ' '/^\tpkgname|^pkgname/{print $2; exit}' "$srcinfo")
	ver=$(awk -F' = ' '/^\tpkgver/{print $2; exit}' "$srcinfo")
	rel=$(awk -F' = ' '/^\tpkgrel/{print $2; exit}' "$srcinfo")
	epoch=$(awk -F' = ' '/^\tepoch/{print $2; exit}' "$srcinfo")
	echo "$name" "${epoch:+$epoch:}$ver-$rel"
}

BUILT=()

build_pkg() {
	local pkg=$1 dir="$CACHEDIR/$1"

	echo "==> [$pkg] fetching"
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch -q origin
		git -C "$dir" reset -q --hard origin/HEAD 2>/dev/null ||
			git -C "$dir" reset -q --hard origin/master
	else
		git clone -q "https://aur.archlinux.org/$pkg.git" "$dir"
	fi

	local name ver have
	read -r name ver <<<"$(aur_ver "$dir/.SRCINFO")"
	have=$(installed_ver "$name")

	if [ -n "$have" ] && [ "$(vercmp "$ver" "$have")" -le 0 ]; then
		echo "    up to date ($have)"
		return 0
	fi

	echo "    ${have:+$have -> }${have:-not in repo, }building $ver"
	(cd "$dir" && makepkg -sf --noconfirm --needed)

	rm -f "$REPODIR/$name"-*.pkg.tar.zst
	cp -f "$dir"/*.pkg.tar.zst "$REPODIR/" 2>/dev/null || true
	BUILT+=("$name")
	echo "    built $ver"
}

# install every package that was freshly built this run
install_built() {
	[ "$no_install" -eq 1 ] && return 0
	[ ${#BUILT[@]} -eq 0 ] && return 0
	local files=() name f
	for name in "${BUILT[@]}"; do
		for f in "$REPODIR/$name"-*.pkg.tar.zst; do
			[ -e "$f" ] && files+=("$f")
		done
	done
	[ ${#files[@]} -eq 0 ] && return 0
	echo "==> installing: ${BUILT[*]}"
	sudo pacman -U --noconfirm "${files[@]}"
}

# remove any packages present in the repo db that are no longer listed in PKGS
remove_stale() {
	local f name keep stale=()
	for f in "$REPODIR"/*.pkg.tar.zst; do
		[ -e "$f" ] || continue
		name=$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}')
		[ -n "$name" ] || continue
		keep=0
		for pkg in "${PKGS[@]}"; do
			[ "$pkg" = "$name" ] && { keep=1; break; }
		done
		[ "$keep" -eq 0 ] && stale+=("$name")
	done
	if [ ${#stale[@]} -gt 0 ]; then
		for name in "${stale[@]}"; do
			echo "==> [$name] no longer in PKGS, removing"
			rm -f "$REPODIR/$name"-*.pkg.tar.zst
		done
		(cd "$REPODIR" && repo-remove "$REPONAME.db.tar.zst" "${stale[@]}")
	fi
}

sync_all() {
	local before after changed=0

	# stale removal only makes sense on a full run, otherwise targeting a
	# single package would wipe out everything else in the repo
	if [ "$full_run" -eq 1 ]; then
		before=$(ls "$REPODIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
		remove_stale
		after=$(ls "$REPODIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
		[ "$before" != "$after" ] && changed=1
	fi

	for pkg in "${TARGETS[@]}"; do
		before=$(ls "$REPODIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
		build_pkg "$pkg"
		after=$(ls "$REPODIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
		[ "$before" != "$after" ] && changed=1
	done

	if [ "$changed" -eq 1 ]; then
		echo "==> refreshing db"
		(cd "$REPODIR" && repo-add "$REPONAME.db.tar.zst" *.pkg.tar.zst)
	else
		echo "==> no package changes"
	fi

	install_built
}

push_changes() {
	echo "==> reviewing changes"
	git add -A

	if git diff --cached --quiet; then
		echo "    nothing to commit"
		return 0
	fi

	if [ "$yes" -eq 1 ]; then
		git commit -m "update repo $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		git push
		return 0
	fi

	while true; do
		git status --short
		echo
		read -rp "push? [Y=commit+push / e=edit / d=diff / n=abort] " opt
		case "$opt" in
			Y|y|"")
				git commit -m "update repo $(date -u +%Y-%m-%dT%H:%M:%SZ)"
				git push
				return 0
				;;
			e|E)
                git status --short | $EDITOR
				git add -A
				;;
			d|D)
				git diff --cached
				;;
			n|N)
				echo "    aborted, changes staged only"
				return 0
				;;
			*)
				echo "    unrecognized option"
				;;
		esac
	done
}

rm -rf ./x86_64/*-debug-*
[ "$mode" != push ] && sync_all
[ "$mode" = sync ] && exit 0
push_changes
