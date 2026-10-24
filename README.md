# olga-creative

Rebranded builds of open-source design apps for Windows.

| Product (placeholder) | Based on | Status |
|---|---|---|
| **OlgaDraw** (vector) | Inkscape 1.4.4 (GPL-2.0-or-later / GPL-3.0) | Windows build pipeline + branding |
| **OlgaPhoto** (raster) | GIMP 3.2.6 (GPL-3.0-or-later) | Windows build pipeline + branding + Photoshop-style defaults |

Everything brand-specific comes from one file, [`brand.json`](brand.json). Upstream licence and copyright
files are kept, every build carries a "Based on Inkscape (GPL)" / "Based on GIMP (GPL)" credit (About screen,
splash, `--version`, `NOTICE.txt`, exe resources). No third-party trademarks (names, logos, icons) are added;
the one upstream keymap file named after a third-party product is renamed (see below). No API keys live here.

## Layout

```
brand.json                        product names, ids, colours, fonts, version suffix
branding/inkscape/patches/        source patches (git format-patch, applied with git apply), brand-neutral:
                                  they read OLGA_BRAND_* CMake variables filled from brand.json
branding/inkscape/apply-branding.py  data-level branding: keymap, zh_TW/en strings, icons, splash/about, installer art
branding/gimp/patches/            GIMP source patches (brand-neutral: meson options -Dolga-brand-* filled from brand.json)
branding/gimp/apply-branding.py   GIMP data-level branding: defaults, zh_TW/en strings, logos/icons, splash, installer art
branding/gimp/defaults/           Photoshop-style default shortcuts/layout/toolbox/tool options/templates (mostly PhotoGIMP, GPL-3.0)
branding/gimp/zh_TW-terms.csv     zh_TW wording table (GIMP's term -> the term Photoshop users know), applied at build time
branding/gimp/zh_TW-term-words.csv  word rules that carry those approved terms into the other text domains
branding/gimp/zh_TW-translations.csv  zh_TW texts upstream lacks (JPEG export dialog, Wavelet Decompose, GEGL Filter Browser)
branding/gimp/guide-zh_TW.html    customer guide (Traditional Chinese), installed as GUIDE-zh_TW.html
branding/gimp/resynthesizer-zh_TW.po  zh_TW catalog for the bundled Resynthesizer plug-ins (their gettext domain)
branding/gimp/resynthesizer-i18n.py   checks that catalog against the installed plug-ins, compiles and installs it
branding/gimp/deps/               the exiv2 patch upstream GIMP CI applies
windows/setup-msys2.ps1           non-admin MSYS2 toolchains: UCRT64 for Inkscape (upstream CI's frozen snapshot),
                                  CLANG64 for GIMP (rolling, like upstream GIMP CI)
windows/build-inkscape.ps1        clone -> brand -> cmake/ninja -> install -> zip (+ NSIS installer) -> smoke test
windows/smoke-test-inkscape.ps1   headless: --version, profile dir, Chinese SVG -> PDF + PNG
windows/build-gimp.ps1            tarballs -> babl/GEGL/exiv2 -> brand -> meson/ninja -> bundle (+ Resynthesizer) -> zip (+ Inno) -> smoke test
windows/package-gimp-installer.ps1  Inno Setup installer (Inno unpacked per-user under the build root)
windows/smoke-test-gimp.ps1       headless: --version (en/zh_TW), Python batch PNG -> PNG/JPG, Heal Selection, profile seeding,
                                  catalogs + zh_TW terms + msgfmt --check, default shortcuts, mascot artwork gone,
                                  Resynthesizer labels in zh_TW and English, no parse error in any settings file
                                  (console run + a desktop-less GUI batch run), every product gimprc value really
                                  used, default comment, product keys / wheel / tool / style defaults, the other
                                  text domains, the customer guide
windows/run-detached.ps1          start a build detached from ssh, with keep-awake and a log file
windows/keepawake-run.ps1         (internal) keep-awake wrapper used by run-detached.ps1
windows/cleanup.ps1               remove everything the pipeline created on a build machine
tools/check-pdf-text.py           verify the smoke-test PDF has live text (pypdfium2)
dist/                             (gitignored) built packages copied back from the build machine
```

## Build machines

Any Windows 10/11 x64 box, admin **not** required. Everything goes under one root directory (`-Root`,
default `C:\olga-build`) plus small per-user folders the smoke tests create (`%APPDATA%\<id>`,
`%LOCALAPPDATA%\<id>`; for the GIMP-based app `%APPDATA%\<nameAscii>`). Needs ~25 GB free per app and internet
access to gitlab.com, 7-zip.org, an MSYS2 mirror, download.gimp.org and github.com.

Downloads are capped at 2 MB/s in total so a build never saturates the line (`OLGA_DOWNLOAD_RATE`, e.g. `500K`,
`0` = no cap). Large files are fetched in parallel byte ranges and MSYS2 packages with parallel connections
(within the same cap), every piece resumable: this keeps a build moving on a lossy line. Not capped: pacman's
own database sync and MSYS2 base-system update (a few hundred MB; a capped curl downloader for pacman made the
database signature checks fail).

Clone or copy this repo to `<root>\olga-creative` (when copying over an older copy, remove the old
`branding`, `windows` and `tools` folders first so a renamed or deleted patch does not linger), then:

```powershell
# on the build box (or through ssh), detached so a dropped ssh session does not kill it:
powershell -ExecutionPolicy Bypass -File <root>\olga-creative\windows\run-detached.ps1 -Name inkscape -Script build-inkscape.ps1 -Root <root>
# follow the log:
powershell -Command "Get-Content (Get-Content <root>\logs\inkscape-latest.txt) -Tail 30"
```

`run-detached.ps1` starts the job through WMI (survives the ssh session; needs WMI access, i.e. admin over
ssh). If that is refused (non-admin account) it falls back to a one-shot scheduled task `OlgaBuild-<name>`
for the current user, and as a last resort to `Start-Process`. While the job runs it holds
`SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`, so idle sleep does not interrupt it; power
settings are not changed. Only one copy per name runs at a time (`<root>\logs\<name>.pid`).

### The build must never disturb the person using the machine

A build box may be someone's everyday computer. Therefore:

- Every step runs at **Idle CPU priority**: `run-detached.ps1` starts the job at Idle on every launch path,
  and `common.ps1` drops any script that loads it to Idle, so bash, ninja, gcc, curl and 7zr inherit it.
- Default parallelism is **CPU threads minus 2** (`ninja -j6` on an 8-thread CPU); `-ScriptArgs '-Jobs 4'`
  to go lower.
- No system changes: no Defender exclusion, no power-plan change, no services. Windows Defender will still
  scan the build output (it costs CPU we cannot lower); if the user notices, stop the job (`Stop-Process` the
  pid in `<root>\logs\<name>.pid` and its children, or `cleanup.ps1 -WhatIf` to see them) and resume later -
  the build continues where it stopped.

Extra build options go through `-ScriptArgs`, e.g. `-ScriptArgs '-Clean'` (full recompile) or
`-ScriptArgs '-NoInstaller'`.

### Resuming (machine asleep, network changed, ssh dropped)

Just run the same command again. Each step skips what is already done:

| Step | Skipped when | Where |
|---|---|---|
| MSYS2 | `<root>\ink168\.olga-extracted` exists (downloads resume with `curl -C -`) | `<root>\ink168` |
| Source | `<root>\src\inkscape.<TAG>.cloned` exists; a half clone is completed, not redone | `<root>\src\inkscape` |
| Branding | stamp = hash(tag, patches, apply-branding.py, brand.json) unchanged | `<root>\src\inkscape.brand-stamp` |
| Configure | `build.ninja` exists and branding unchanged | `<root>\build\inkscape` |
| Compile | ninja is incremental; the build dir is never deleted unless `-Clean` | same |
| Package + smoke test | always re-run (a few minutes) | `<root>\dist`, `<root>\smoke` |

ccache (`<root>\ccache`) makes recompiles after a brand change cheap.

### Outputs

- `<root>\dist\<id>-<version>-win64-portable.zip` - unzip anywhere, run `<id>\bin\<id>.exe`.
- `<root>\dist\<id>-<version>...-x64.exe` - NSIS installer (start menu / Add-Remove Programs use the brand name;
  installs to `Program Files\<nameAscii>`; registers `.svg`/`.svgz` with `<nameAscii>.SVG` ProgIds).
- `<root>\smoke\` - `version.txt`, `dirs.txt`, `cjk.pdf`, `cjk.png`, `result.json`.
- Logs: `<root>\logs\<name>-<timestamp>.log`.

To check the smoke-test PDF for live text: `python -I tools\check-pdf-text.py <root>\smoke\cjk.pdf`.

## Renaming the brand

Edit `brand.json` -> `inkscape.name` (display, any Unicode), `nameAscii` (installer / exe resources),
`id` (lower-case: exe name and profile folder), `appId`, `monogram`, colours, taglines, `keymapName`.
Re-run the build: the branding stamp changes, the tree is reset to the pristine tag, patches + data
branding are re-applied, cmake re-configures and ninja recompiles only what changed (minutes with ccache).

## What the branding changes (Inkscape)

Source patches (`branding/inkscape/patches`):

1. `0001` brand configuration: `CMakeScripts/OlgaBrand.cmake` + generated `olga-brand.h` (`OLGA_BRAND_*`).
2. `0002` product name in `--version`, About and splash title (`OlgaDraw 1.4.4-olga1 (based on Inkscape 1.4.4 (...))`),
   window title (`file.svg - OlgaDraw`), application id (`tw.olga.OlgaDraw`, so it never merges with a running
   real Inkscape), own profile folder (`%APPDATA%\olgadraw`, so an existing Inkscape profile does not override
   our defaults and the two apps do not share settings), `INKSCAPE_COMMAND` points extensions at our exe.
3. `0003` executable `olgadraw.exe` / `olgadraw.com`, Windows version resource (product, company, credit), manifest.
4. `0004` default preferences: keymap `brand-default.xml`, welcome dialog off, splash on.
5. `0005` installer: package/vendor/start-menu names, install dir, App Paths, file-association ProgIds, own
   MSI upgrade GUID, dist file names.
6. `0006` installs `COPYING`, `LICENSES\` and a branded `NOTICE.txt` ("based on Inkscape", where the source is)
   into every package (zip and installer).
7. `0007` replaces upstream's `Run Inkscape !.bat` launchers (they start `inkscape.exe`) with `<nameAscii>.bat`.

Data branding (`apply-branding.py`):

- `share/keys/brand-default.xml` = upstream's Illustrator-CS2-style preset with a brand name; the upstream file
  named after the third-party product is removed (`dropThirdPartyBrandedFiles`).
- `po/zh_TW.po`: translations mentioning Inkscape now say the brand; a generated `po/en.po` does the same for
  English systems. Kept as "Inkscape": credits, licence, links, upstream version history, the "Inkscape SVG" format.
- App icon (exe `.ico`, in-app hicolor icons), splash/welcome banners, About screen (with the upstream credit),
  NSIS/WiX installer bitmaps - generated from the brand colours and fonts (Windows fonts; CJK names use JhengHei).

The UI language follows Windows (zh_TW on Traditional Chinese Windows) - upstream behaviour, nothing changed.

## The GIMP-based app (OlgaPhoto)

```powershell
powershell -ExecutionPolicy Bypass -File <root>\olga-creative\windows\run-detached.ps1 -Name gimp -Script build-gimp.ps1 -Root <root>
# optional: -ScriptArgs '-Jobs 8 -Mirror https://<msys2 mirror>/msys2'   (-FetchOnly pre-fetches the tarballs)
```

Same route as upstream GIMP CI for Windows (`build/windows/` in the GIMP tree): MSYS2 **CLANG64**, packages from
the tag's `build/windows/all-deps-uni.txt`, babl/GEGL/exiv2 built first, meson with `-Dwindows-installer=true`
so `ninja install` runs upstream's bundling script, then Inno Setup. Upstream CI has no frozen MSYS2 snapshot
(it updates MSYS2 on every run), so neither does this; the installed package versions are recorded in
`<root>\msys64-gimp\olga-packages.txt`. Sources are the official release tarballs (SHA-256 pinned in
`build-gimp.ps1`; the GIMP tarball already contains `gimp-data`).

| Step | Skipped when | Where |
|---|---|---|
| MSYS2 | `<root>\msys64-gimp\.olga-base` exists; deps when the package list is unchanged | `<root>\msys64-gimp` |
| Tarballs | `<file>.sha256-ok` exists (downloads resume) | `<root>\downloads` |
| babl, GEGL, exiv2 | `<root>\build\gimp\_install\.olga-dep-*` exists (`-CleanDeps` rebuilds) | `<root>\build\gimp\dep-*` |
| Branding | stamp = hash(version, patches, apply-branding.py, zh_TW-terms.csv, defaults, brand.json) unchanged; the tree is reset via a baseline git repo kept *outside* it (`<root>\src\gimp-<ver>.git`) | `<root>\src\gimp-<ver>` |
| Configure / compile | as for Inkscape (`-Clean` = full recompile) | `<root>\build\gimp\build` |
| Resynthesizer | extracted once; meson/ninja incremental, `-NoResynthesizer` leaves it out | `<root>\build\gimp\dep-resynthesizer` |
| Bundle, package, smoke test | always re-run | `<root>\build\gimp\<id>`, `<root>\dist`, `<root>\smoke-gimp` |

Outputs: `<root>\dist\<id>-<version>-win64-portable.zip` (unzip anywhere, run `<id>\<id>.cmd` or
`<id>\bin\<id>.exe`; debug symbols left out) and `<root>\dist\<id>-<version>-setup.exe` (Inno Setup, per-user
install by default, admin install offered), plus `<root>\dist\<id>-<version>-zh_TW-terms-review.md`, the
before/after sheet of the zh_TW wording (and the Resynthesizer terms) for staff review, and
`<root>\dist\<id>-<version>-guide-zh_TW.html`, the customer guide that also ships in the packages.

Source patches (`branding/gimp/patches`, all brand-neutral; the values come from meson `-Dolga-brand-*`):

1. `0001` brand options -> `OLGA_BRAND_*` in `config.h` and the resource templates.
2. `0002` product name instead of GIMP's in window titles, About (name, version, "Based on GIMP ..." credit, link)
   and `--version` (`OlgaPhoto version 3.2.6-olga3 (based on GIMP 3.2.6)`); application id `tw.olga.OlgaPhoto`;
   brand-specific single-instance window class and process mutex, so a real GIMP running next to it never
   receives this app's files (and the installer does not wait for a running GIMP).
3. `0003` exe version resources (product, vendor, version, credit), branded copies `<id>.exe` /
   `<id>-console.exe` of the main executables (upstream's `gimp-3.2.exe` etc. stay: plug-ins, the installer's
   upgrade logic and GIMP's own tooling refer to them), a `<id>.cmd` launcher, the fontconfig cache under the
   brand's folder, and `COPYING`, `LICENSE`, `NOTICE.txt` in every package.
4. `0004` Photoshop-style defaults: `etc/gimp/3.0/shortcutsrc` is used while the user has no shortcuts of their
   own (and again after "reset shortcuts"); a brand-new profile is seeded from `etc/gimp/3.0/defaults/`.
5. `0005` installer: names, AppId/mutex, install folder, uninstall/registry keys, ProgIds, App Paths, links,
   licence files; per-user profile removal on uninstall points at the brand's folder.
6. `0006` Layer > Group Layers / Ungroup Layers: puts the selected layers (multi-selection, stacking order kept)
   into a new group at the place of the topmost one, or moves a group's layers out and removes the group; one
   undo step each. Bound to Ctrl+G / Ctrl+Shift+G by the default shortcuts (Ctrl+G was the Gradients dialog).
7. `0007` the empty canvas (and the optional toolbox artwork) draws a plain brand-neutral mark instead of
   GIMP's mascot.
8. `0008` the welcome dialog follows `show-welcome-dialog` (product default: off) also on the first start of a new
   profile or version (upstream shows it then regardless).
9. `0009` Windows: the image window and docks detach their input method (IME) while the focus is not on a text
   entry, a text view or the text tool's on-canvas editing, so single-key shortcuts work with e.g. Bopomofo in
   Chinese mode; the user's input mode is kept, dialogs are unchanged.
10. `0010` Alt-click sets the clone / heal source and Alt picks colors while painting (Ctrl keeps working; the
    eraser keeps Alt for anti-erase).
11. `0011` installer: the customer guide `GUIDE-zh_TW.html` at the install root, with a Start menu entry.

Build options (not patches): own profile folder `%APPDATA%\<nameAscii>\3.2` (`-Dgimpdir`, upstream option, so an
installed GIMP's settings never override ours and the two never share settings), `-Dcheck-update=no` (no "new
GIMP version available" prompts), `-Dbug-report-url`, `-Dbuild-id`.

Data branding (`branding/gimp/apply-branding.py`): the defaults in `branding/gimp/defaults` (see its README:
single-window Photoshop-style layout, toolbox grouping and shortcuts mostly from PhotoGIMP, GPL-3.0, credited in
`NOTICE.txt`, plus more Photoshop-standard shortcuts, dark theme, a Photoshop-like title bar and File > New
templates for shop / social / print sizes), zh_TW catalogs of every GIMP text domain and a generated
`po/en.po` (kept as "GIMP": credits, licence, links, GIMP help/manual, version history, file/resource format
names), logo SVGs and the committed `.ico` files (the build renders the About logo, app/file icons and installer
icons from them), every other mascot picture (Default/Legacy icon themes incl. the error icon, the splash easter
egg; the mascot brush is not shipped), and on the finished bundle the splash screen and the installer
splash/banner bitmaps. The zh_TW wording table `branding/gimp/zh_TW-terms.csv` (context, English text, GIMP's
current wording, new wording, why) is applied to `po/zh_TW.po` after the brand rename: a row whose current
wording no longer matches upstream, a missing or extra menu mnemonic, or changed format specifiers stop the
build, and the catalog must pass `msgfmt --check`. Edit the table and rebuild to change the wording.
On the finished bundle the same terms reach the other text domains (libgimp's shared buttons such as Help /
Export, the plug-ins' dialogs, Script-Fu, Python, GEGL's filter names): the decompiled catalogs get the table rows
(GIMP's domains), the word rules of `zh_TW-term-words.csv` (each must belong to an approved term and use its new
word) and the missing translations of `zh_TW-translations.csv`, and are compiled again; a rule that no longer
changes anything or a translation upstream now has stops the build. GLib's own catalogs (file errors) are added
to the bundle. The staff review sheet lists every change.

Bundled plug-in: **Resynthesizer** (GPL-3.0, <https://github.com/bootchk/resynthesizer>, the GIMP 3 line,
tag pinned with SHA-256 in `build-gimp.ps1`): Filters > Enhance > Heal Selection (content-aware fill),
Heal Transparency, Uncrop, Map > Style, Render > Texture and related. It is built against the app's libgimp after
the bundle is made and copied into `lib\gimp\3.0\plug-ins`; its `COPYING` sits next to it and
`NOTICE.txt` credits it.

Its texts are translated the plug-ins' own way: each outer plug-in (a Script-Fu script run by the stand-alone
interpreter) declares the gettext domain `resynthesizer3` and marks its texts `_"..."`, the C engine returns the
same domain from `set_i18n()`, and GIMP binds that domain to `<plug-in folder>\locale`. Upstream ships no zh_TW
catalog, so `branding/gimp/resynthesizer-zh_TW.po` adds one: `resynthesizer-i18n.py` reads the texts the
installed plug-ins really use (the way Script-Fu reads them), stops the build when a text has no translation,
an entry is stale, a menu mnemonic or format specifier is lost or `msgfmt --check` fails, and installs the
compiled catalog as `locale\zh_TW\LC_MESSAGES\resynthesizer3.mo` in every Resynthesizer plug-in folder. Menu
labels, tooltips, dialog labels and option choices are then Chinese when the interface language is Traditional
Chinese and stay English otherwise. Its terms are listed in the staff review sheet. Edit the `.po` and rebuild
to change them.

## Known issues / not done

- GIMP-based app: the "GIMP Online" / help menus still point at gimp.org (that is GIMP's documentation); English
  installer texts outside the translation catalogs may still say GIMP; icon *names* (`gimp-wilber`) are kept,
  only the pictures are replaced; the GEGL goat brush (`Fun` tag) is kept.
- `inkview.exe` (the slideshow viewer) keeps its upstream name.
- GTK icon *names* (`org.inkscape.Inkscape`) are kept; only the pixels are replaced.
- Strings without "Inkscape" in them that describe Inkscape-specific things are untouched; English UI text
  outside the translation catalog (a few hard-coded strings) may still say Inkscape.
- The MSYS2 toolchain is upstream CI's frozen snapshot `ink168` (pinned by the 1.4.4 tag). For newer tags
  use `-MsysMode rolling` (fresh MSYS2 + upstream `buildtools/msys2installdeps.sh`).
