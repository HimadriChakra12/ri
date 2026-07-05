# ri

A personal pacman repository, auto-synced from AUR.

## Usage

Add to `/etc/pacman.conf`:

```ini
[ri]
SigLevel = Optional TrustAll
Server = https://himadrichakra12.github.io/ri/$arch
```

Then:

```bash
sudo pacman -Sy
sudo pacman -S localsend
```

## Packages

- localsend-bin
- xdman-beta-bin
- wlctl-bin
- ghgrab-bin
- ibus-avro-git
- Jdownloader2
- rawtherapee-appimage-bin

## ayir

ayir is a `AppImage` to `Pacman tar` converter.

### Layout

```
.AppImage/             gitignored, created at runtime
└── <name>/
    ├── src/<Appimage>
    ├── extracted/     squashfs-root, kept for reuse
    ├── Makefile
    └── out/
        ├── PKGBUILD
        ├── <name>-bin-<ver>-<rel>-x86_64.tar.zst       (Base Tar)
        └── <name>-bin-<ver>-<rel>-x86_64.pkg.tar.zst   (Pac Pkg)
```

``` sh
make setup APPIMAGE="/path/to/appimage"
```

It creates a `.AppImage/` directory and generates a `appdir/` according to the name.

```
cd .AppImage/appdir/
```

There is a `Makefile` that makes the whole thing into `pacman tar`.

```
make deps       # optional — setup already ran this once
make convert    # payload tarball + PKGBUILD
make build      # makepkg -f
make install    # pacman -U the result
make copy       # copies to ri/x86_64
```

`make list` from the repo root shows every app you've touched and what
stage it's at (`setup` / `converted` / `built`).

If `convert` guesses the wrong version:
```bash
make convert PKGVER=1.2.3
```
