#!/usr/bin/env bash
#
# update.sh — for each AUR package in PACKAGES, check the latest version
# against what's currently in the repo. If newer, build it (makepkg handles
# downloading prebuilt binaries for -bin packages automatically). If not,
# just report "already up to date".
#
# Requires: git, base-devel, pacman-contrib (for vercmp), repo-add
#   sudo pacman -S --needed base-devel git pacman-contrib
#
set -euo pipefail

# ---- packages to track --------------------------------------------------
PACKAGES=(
  "localsend-bin"
  # add more AUR pkgbase names here
)

# ---- config ---------------------------------------------------------------
REPO_NAME="ri"
REPO_DIR="$HOME/pkg/ri/x86_64"       # matches ri/x86_64 in the git repo
WORK_DIR="$HOME/.cache/ri-update"

mkdir -p "$REPO_DIR" "$WORK_DIR"

# ---- helpers ---------------------------------------------------------------

# Get the version (pkgver-pkgrel, with epoch if set) of an already-built
# package sitting in the repo dir, by name. Empty string if none found.
current_repo_version() {
  local pkgname="$1"
  local f
  f=$(ls "$REPO_DIR"/"${pkgname}"-*.pkg.tar.zst 2>/dev/null | sort -V | tail -n1 || true)
  [ -z "$f" ] && return 0
  # pacman -Qp prints "name version"
  pacman -Qp "$f" 2>/dev/null | awk '{print $2}'
}

# ---- per-package check/build ------------------------------------------------
sync_pkg() {
  local pkg="$1"
  local clone_dir="$WORK_DIR/$pkg"

  echo "==> [$pkg] checking AUR for latest version"

  if [ -d "$clone_dir/.git" ]; then
    git -C "$clone_dir" fetch origin --quiet
    git -C "$clone_dir" reset --hard --quiet origin/HEAD 2>/dev/null \
      || git -C "$clone_dir" reset --hard --quiet origin/master
  else
    git clone --quiet "https://aur.archlinux.org/${pkg}.git" "$clone_dir"
  fi

  # Read version info out of the PKGBUILD without executing arbitrary
  # functions from it (just the variable assignments).
  local pkgname pkgver pkgrel epoch aur_version
  pkgname=$(awk -F= '/^pkgname=/{gsub(/["'"'"']/,"",$2); print $2; exit}' "$clone_dir/PKGBUILD")
  pkgver=$(awk -F= '/^pkgver=/{gsub(/["'"'"']/,"",$2); print $2; exit}' "$clone_dir/PKGBUILD")
  pkgrel=$(awk -F= '/^pkgrel=/{gsub(/["'"'"']/,"",$2); print $2; exit}' "$clone_dir/PKGBUILD")
  epoch=$(awk -F= '/^epoch=/{gsub(/["'"'"']/,"",$2); print $2; exit}' "$clone_dir/PKGBUILD")

  if [ -n "${epoch:-}" ]; then
    aur_version="${epoch}:${pkgver}-${pkgrel}"
  else
    aur_version="${pkgver}-${pkgrel}"
  fi

  local have_version
  have_version=$(current_repo_version "$pkgname")

  if [ -n "$have_version" ] && [ "$(vercmp "$aur_version" "$have_version")" -le 0 ]; then
    echo "    already up to date ($have_version)"
    return 0
  fi

  if [ -n "$have_version" ]; then
    echo "    update available: $have_version -> $aur_version"
  else
    echo "    not yet in repo, building version $aur_version"
  fi

  (
    cd "$clone_dir"
    makepkg -sf --noconfirm --needed
  )

  # Drop any older builds of this package from the repo dir, copy in the new one
  rm -f "$REPO_DIR"/"${pkgname}"-*.pkg.tar.zst
  local built
  for built in "$clone_dir"/*.pkg.tar.zst; do
    [ -e "$built" ] || continue
    cp -f "$built" "$REPO_DIR/"
  done

  echo "    built $aur_version"
}

# ---- main -------------------------------------------------------------
any_pkg_changed=0
for pkg in "${PACKAGES[@]}"; do
  before=$(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
  sync_pkg "$pkg"
  after=$(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | md5sum || true)
  [ "$before" != "$after" ] && any_pkg_changed=1
done

if [ "$any_pkg_changed" -eq 0 ]; then
  echo "==> Nothing changed, repo database left as-is"
  exit 0
fi

echo "==> Refreshing repo database"
cd "$REPO_DIR"
repo-add "${REPO_NAME}.db.tar.zst" *.pkg.tar.zst

echo "==> Pushing to GitHub"
cd "$HOME/pkg/ri"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Update repo $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git push
else
  echo "    nothing to commit"
fi
