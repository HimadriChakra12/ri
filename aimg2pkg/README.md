# aimg2pkg

Turns an AppImage into a pacman `-bin` package. Lives inside a pacman repo
(like `ri`) alongside its `x86_64/` and `update.sh`.

## Layout

```
ri/
├── Makefile              only real job: setup
├── update.sh             your existing AUR flow, untouched
├── x86_64/               your actual repo db
├── aimg2pkg/
│   ├── aimg2pkg.sh        the tool — self-locating, works from anywhere
│   └── README.md          this file
└── .AppImage/             gitignored, created at runtime
    └── <name>/
        ├── src/<original>.AppImage
        ├── extracted/     squashfs-root, kept for reuse
        ├── Makefile        generated — zero-argument commands live here
        └── out/
            ├── PKGBUILD
            ├── <name>-bin-<ver>-<rel>-x86_64.tar.zst
            └── <name>-bin-<ver>-<rel>-x86_64.pkg.tar.zst   (after build)
```

Add to `.gitignore`:
```
.AppImage/
```

## The only two commands you actually type

**1. From the repo root — the one time you need a path:**
```bash
make setup APPIMAGE=~/Downloads/mpv.AppImage
```
Prints the derived name (e.g. `mpv`), moves the file into
`.AppImage/mpv/src/`, extracts it, checks its runtime deps, and writes a
Makefile into `.AppImage/mpv/`.

**2. From inside `.AppImage/<name>/` — no arguments, ever:**
```bash
cd .AppImage/mpv
make deps       # optional — setup already ran this once
make convert    # payload tarball + PKGBUILD
make build      # makepkg -f
make install    # pacman -U the result
```

That's the entire interface. One path at setup time, then zero arguments
for everything else — the name is baked into that directory's Makefile,
which calls `aimg2pkg.sh` directly (one hop, no bouncing through the root
Makefile).

`make list` from the repo root shows every app you've touched and what
stage it's at (`setup` / `converted` / `built`).

If `convert` guesses the wrong version:
```bash
make convert PKGVER=1.2.3
```

## Why no GitHub release step

End users installing via `pacman -S` never run `makepkg` — they just fetch
the prebuilt `.pkg.tar.zst` you copy into `x86_64/`. So the payload tarball
just sits locally next to its `PKGBUILD` forever; `makepkg` never touches
the network.

## What `setup` actually does

1. Derives a short name from the filename — strips version numbers,
   `_release`/`-stable`/`-x86_64`/etc, lowercases the rest.
2. Moves the file into `.AppImage/<name>/src/`.
3. Extracts it (`--appimage-extract`, no FUSE needed).
4. Writes the per-app Makefile.
5. Runs the dependency check immediately so problems show up right away.

If the auto-derived name is wrong, rename the file before running `setup`.

## What `deps` actually does

For every ELF binary in `usr/bin/`:
1. Runs real `ldd` resolution against the bundled `usr/lib/`.
2. Anything "not found" gets searched for across the whole extracted tree
   first (some bundlers nest libraries outside `usr/lib/`) and copied in
   if found, instead of being falsely reported missing.
3. Whatever's still unresolved is a genuine system dependency — written to
   `MISSING-DEPS.txt`, and looked up via `pkgfile` if installed
   (`pacman -S pkgfile && pkgfile -u`) so it can tell you the owning
   pacman package directly.

## What `convert` actually does

1. Copies `usr/bin` + `usr/lib` into `/opt/<name>-bin/` — private, never
   shadows system libraries.
2. Splits `usr/share/`: desktop-integration dirs (`applications`, `icons`,
   `man`, `metainfo`, `mime`, `pixmaps`) → real `/usr/share/`; everything
   else (glib schemas, lens databases, themes...) → private prefix.
3. Detects which toolkit machinery is actually present (gdk-pixbuf,
   GTK modules/immodules, girepository, glib schemas, Qt plugins) and only
   wires up env vars for what's there.
4. Writes one wrapper script per binary, reproducing whatever the
   AppImage's own `AppRun` would have set, repointed at the private prefix.
5. Packs it into a tarball, writes a `PKGBUILD` with the checksum filled in.

## Always review before shipping

- `url=` — placeholder, fill in the real project URL
- `license=('unknown')` — fill in the actual license
- `depends=()` — `glibc` always, plus `gtk3`/`hicolor-icon-theme` or
  `qt5-base` if detected. Add anything `MISSING-DEPS.txt` flagged.

## Known limits

- Only wraps ELF binaries directly in `usr/bin/` — deeply nested launchers
  or non-ELF entry points need manual wrapper edits.
- Toolkit detection covers GTK2/3 and Qt5 marker paths only.
- Assumes a type-2 (squashfs) AppImage — effectively all of them today.
