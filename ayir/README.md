# Ayir Functionality

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
