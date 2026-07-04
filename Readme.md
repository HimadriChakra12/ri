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
