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

``` sh
make setup APPIMAGE="/path/to/appimage"
```

It creates a `.AppImage/` directory and generates a `appdir/` according to the name.

```
cd .AppImage/appdir/
```

There is a `Makefile` that makes the whole thing into `pacman tar`.

```
make deps       #checks the deps
make convert    #converts to PKGBUILD and tar
make build      #builds as .pkg.tar
make install    #install the .pkg.tar
make copy       #copies to ri/x86_64
```
