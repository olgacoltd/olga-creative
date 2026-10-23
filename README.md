# olga-creative

Rebranded builds of open-source design apps for Windows.

| Product (placeholder) | Based on | Status |
|---|---|---|
| **OlgaDraw** (vector) | Inkscape 1.4.4 (GPL-2.0-or-later / GPL-3.0) | Windows build pipeline + branding |
| **OlgaPhoto** (raster) | GIMP 3.x (GPL-3.0) | not started |

Everything brand-specific comes from one file, [`brand.json`](brand.json). Upstream licence and copyright
files are kept, every build carries a "Based on Inkscape (GPL)" credit (About screen, splash, `--version`,
`NOTICE.txt`, exe resources). No third-party trademarks (names, logos, icons) are added; the one upstream
keymap file named after a third-party product is renamed (see below). No API keys live here.

## Layout

```
brand.json                        product names, ids, colours, fonts, version suffix
branding/inkscape/patches/        source patches (git format-patch, applied with git apply), brand-neutral:
                                  they read OLGA_BRAND_* CMake variables filled from brand.json
branding/inkscape/apply-branding.py  data-level branding: keymap, zh_TW/en strings, icons, splash/about, installer art
windows/setup-msys2.ps1           non-admin MSYS2 UCRT64 toolchain (default: upstream CI's frozen snapshot)
windows/build-inkscape.ps1        clone -> brand -> cmake/ninja -> install -> zip (+ NSIS installer) -> smoke test
windows/smoke-test-inkscape.ps1   headless: --version, profile dir, Chinese SVG -> PDF + PNG
windows/run-detached.ps1          start a build detached from ssh, with keep-awake and a log file
windows/keepawake-run.ps1         (internal) keep-awake wrapper used by run-detached.ps1
windows/cleanup.ps1               remove everything the pipeline created on a build machine
tools/check-pdf-text.py           verify the smoke-test PDF has live text (pypdfium2)
dist/                             (gitignored) built packages copied back from the build machine
```

## Build machines

Any Windows 10/11 x64 box, admin **not** required. Everything goes under one root directory (`-Root`,
default `C:\olga-build`) plus two small per-user folders the smoke test creates
(`%APPDATA%\<id>`, `%LOCALAPPDATA%\<id>`). Needs ~25 GB free and internet access to gitlab.com and 7-zip.org.

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

## Known issues / not done

- `inkview.exe` (the slideshow viewer) keeps its upstream name.
- GTK icon *names* (`org.inkscape.Inkscape`) are kept; only the pixels are replaced.
- Strings without "Inkscape" in them that describe Inkscape-specific things are untouched; English UI text
  outside the translation catalog (a few hard-coded strings) may still say Inkscape.
- The MSYS2 toolchain is upstream CI's frozen snapshot `ink168` (pinned by the 1.4.4 tag). For newer tags
  use `-MsysMode rolling` (fresh MSYS2 + upstream `buildtools/msys2installdeps.sh`).
