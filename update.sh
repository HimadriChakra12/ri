#!/usr/bin/env bash
# update.sh — build AUR packages if newer than what's in the local repo.
# Requires: git, base-devel, pacman-contrib
set -euo pipefail

PACKAGES=(
    "localsend-bin"
    "wlctl-bin"
)
REPO_NAME="ri"
REPO_DIR="$(pwd)/x86_64"
WORK_DIR="$HOME/.cache/ri-update"
mkdir -p "$REPO_DIR" "$WORK_DIR"

repo_version() {
  local f
  f=$(ls "$REPO_DIR/$1"-*.pkg.tar.zst 2>/dev/null | sort -V | tail -n1) || return 0
  [ -n "$f" ] && pacman -Qp "$f" | awk '{print $2}'
}

sync_pkg() {
  local pkg=$1 dir="$WORK_DIR/$1"
  echo "==> [$pkg] checking AUR"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q origin
    git -C "$dir" reset -q --hard origin/HEAD 2>/dev/null || git -C "$dir" reset -q --hard origin/master
  else
    git clone -q "https://aur.archlinux.org/$pkg.git" "$dir"
  fi

  local pb="$dir/PKGBUILD" name ver rel epoch aur have
  name=$(awk -F= '/^pkgname=/{gsub(/["'"'"']/,"",$2);print $2;exit}' "$pb")
  ver=$(awk -F=  '/^pkgver=/{gsub(/["'"'"']/,"",$2);print $2;exit}' "$pb")
  rel=$(awk -F=  '/^pkgrel=/{gsub(/["'"'"']/,"",$2);print $2;exit}' "$pb")
  epoch=$(awk -F= '/^epoch=/{gsub(/["'"'"']/,"",$2);print $2;exit}' "$pb")
  aur="${epoch:+$epoch:}$ver-$rel"
  have=$(repo_version "$name")

  if [ -n "$have" ] && [ "$(vercmp "$aur" "$have")" -le 0 ]; then
    echo "    up to date ($have)"; return 0
  fi
  echo "    ${have:+$have -> }${have:-not in repo, }building $aur"

  (cd "$dir" && makepkg -sf --noconfirm --needed)
  rm -f "$REPO_DIR/$name"-*.pkg.tar.zst
  cp -f "$dir"/*.pkg.tar.zst "$REPO_DIR/" 2>/dev/null || true
  echo "    built $aur"
}

changed=0
for pkg in "${PACKAGES[@]}"; do
  before=$(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
  sync_pkg "$pkg"
  after=$(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
  [ "$before" != "$after" ] && changed=1
done

[ "$changed" -eq 0 ] && { echo "==> Nothing changed"; exit 0; }

echo "==> Refreshing repo database"
(cd "$REPO_DIR" && repo-add "$REPO_NAME.db.tar.zst" *.pkg.tar.zst)

echo "==> Pushing to GitHub"
cd "$HOME/pkg/ri"
git add -A
git diff --cached --quiet && echo "    nothing to commit" || { git commit -m "Update repo $(date -u +%Y-%m-%dT%H:%M:%SZ)"; git push; }
