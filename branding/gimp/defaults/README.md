# Photoshop-style defaults for the GIMP-based app

These files become the app's **default** settings. They are installed into the system configuration folder
of the app (`etc/gimp/3.0/` inside the install tree) by `apply-branding.py`; nothing is written into a
user's profile by the build.

| File here | Installed as | How GIMP uses it |
|---|---|---|
| `shortcutsrc` | `etc/gimp/3.0/shortcutsrc` | read while the user has no personal `shortcutsrc` (patch 0004); resetting shortcuts in Preferences returns to these |
| `sessionrc` | `etc/gimp/3.0/sessionrc` (replaces upstream's) | upstream fallback while the user has no personal `sessionrc` |
| `toolrc` | `etc/gimp/3.0/toolrc` (replaces upstream's) | upstream fallback while the user has no personal `toolrc` |
| `gimprc` | appended to `etc/gimp/3.0/gimprc` | system-wide preferences; a user's own `gimprc` still wins |
| `templaterc-extra` | put in front of GIMP's templates in `etc/gimp/3.0/templaterc` | File > New sizes (shop, social, Taiwanese print); upstream fallback while the user has no personal `templaterc` |
| `profile/*` | `etc/gimp/3.0/defaults/` | copied into a brand-new profile on first start (patch 0004): tool options, context |

## Source and licence

Derived from **PhotoGIMP** by Diolinux, <https://github.com/Diolinux/PhotoGIMP>, commit
`eca3a8f57b9944c063d043ce7c07524107b5292d` (2026-09-27), licensed under the GNU General Public License v3.
Only the settings files are used; PhotoGIMP's splash screen, icons, artwork and name are **not** used.
The app's `NOTICE.txt` credits PhotoGIMP.

Changes from PhotoGIMP:

- `toolrc`, `profile/tool-options/*`: unchanged (header comment added; `gimp-vector-tool` dropped, the tool
  is called `gimp-path-tool` in GIMP 3.2).
- `shortcutsrc`: PhotoGIMP's active shortcuts, except Ctrl+E is Merge Down (as in Photoshop) instead of
  Merge Visible Layers; plus an `OLGA ADDITIONS` block with more Photoshop-standard keys (Ctrl+L/M/U/B,
  Ctrl+Shift+U, Ctrl+I invert / Ctrl+Shift+I invert selection, Ctrl+Shift+Z redo, F7 layers,
  Ctrl+[ ] layer order, Alt+[ ] layer selection, Ctrl+1 / Ctrl+plus / Ctrl+minus zoom, Ctrl+R rulers,
  Ctrl+; guides, Ctrl+' grid, Ctrl+Shift+Alt+W / S export). The block's comment lists which GIMP defaults
  they displace.
- `sessionrc`: same dock layout, but the dock name `gimp-vectors-list` is `gimp-path-list` in GIMP 3.2, the
  machine-specific window and dialog positions were removed, the window starts maximized, and Undo History
  was added next to Layers / Channels / Paths.
- `gimprc`: only the layer/thumbnail preview sizes and import-add-alpha were kept (PhotoGIMP's file also
  carries monitor resolution, a monitor colour profile, full-screen mode and a Linux-only raw-plug-in path);
  `toolbox-wilber no`, `show-welcome-dialog no`, single-window mode, the dark theme and the
  Photoshop-like window title are ours.
- `templaterc-extra`: ours (not from PhotoGIMP).
- `profile/contextrc`: the device-specific `tool-preset` line was removed.
- Not used: `theme.css` (GIMP 3's default is already the dark theme with symbolic icons), `filters/`,
  `plug-in-settings/` (machine-specific last-used values), splash, icons, `.desktop` file.
