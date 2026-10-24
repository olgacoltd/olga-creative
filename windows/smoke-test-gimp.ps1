<#
.SYNOPSIS
  Headless smoke test of the built GIMP-based app (console executable only, no GUI is opened).
  Results land in <Root>\smoke-gimp\ : version*.txt, in.png, out.png, out.jpg, result.json, *.out/err.txt

  Checks: --version shows the brand and version suffix (English and zh_TW), exe version resource, a Python
  batch job (open PNG -> desaturate + scale -> export PNG and JPG), Resynthesizer's Heal Selection on a test
  image, a new profile gets the brand's default settings, the default profile folder is the brand's own, the
  zh_TW / en catalogs carry the brand name, every new wording of branding\gimp\zh_TW-terms.csv is in the
  compiled zh_TW catalog and the branded zh_TW.po passes msgfmt --check, the default shortcuts (Export As on
  Ctrl+Shift+S, Group Layers on Ctrl+G) and the Group/Ungroup actions are in the app, the mascot artwork is gone,
  the installed default settings name no other vendor's product, every Resynthesizer plug-in folder has its
  zh_TW catalog, and the Resynthesizer menu labels / tooltip / parameter label GIMP registers are the Chinese
  ones under zh_TW and the English ones under English (fresh profile per language).
  Settings files: no run may report a parse error in any rc file (gimprc, contextrc, templaterc ... from the
  console app; sessionrc, toolrc, shortcutsrc, controllerrc, devicerc ... from a GUI run, see -GuiRcCheck), and
  every value of the product's gimprc block must be the one GIMP actually uses (gimp-gimprc-query), including
  the brand's default image comment (no "Created with GIMP" in an exported JPEG). A new profile starts with the
  shipped context (rectangle select). The other text domains carry the approved terms and the added
  translations (zh_TW-translations.csv), and GLib's catalog is bundled.

.PARAMETER GuiRcCheck  auto (default): run the GUI executable once in batch mode only when this session has no
                       desktop (Windows session 0: ssh, WMI, a scheduled task not tied to a logged-on desktop),
                       so nothing appears on anyone's screen; 'yes' forces it, 'no' skips it. The GUI run is the
                       only way to have GIMP itself parse sessionrc, toolrc, shortcutsrc and controllerrc.
#>
param([string]$Root = 'C:\olga-build', [string]$GimpVersion = '3.2.6', [switch]$NoResynthesizer,
      [ValidateSet('auto', 'yes', 'no')][string]$GuiRcCheck = 'auto')
. "$PSScriptRoot\common.ps1"
# PS 5.1: with Stop, redirecting a native program's stderr throws NativeCommandError
$ErrorActionPreference = 'Continue'
$g = (Get-Brand).gimp
$bundle = Join-Path $Root "build\gimp\$($g.id)"
$exe = Join-Path $bundle "bin\$($g.id)-console.exe"
if (-not (Test-Path $exe)) { throw "not built: $exe" }
$out = Join-Path $Root 'smoke-gimp'
Remove-Tree $out
Ensure-Dir $out
Write-Step "smoke test: $exe"
$utf8 = New-Object Text.UTF8Encoding($false)

function Invoke-App([string]$tag, [string[]]$argv, [string]$stdin = '') {
    $o = Join-Path $out "$tag.out.txt"; $e = Join-Path $out "$tag.err.txt"
    $quoted = $argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $sp = @{ FilePath = $exe; ArgumentList = $quoted; NoNewWindow = $true; Wait = $true; PassThru = $true
             RedirectStandardOutput = $o; RedirectStandardError = $e }
    if ($stdin) { $sp.RedirectStandardInput = $stdin }
    $proc = Start-Process @sp
    $script:lastRc = $proc.ExitCode
    return [IO.File]::ReadAllText($o, [Text.Encoding]::UTF8).Trim()
}

# 1. --version (English, then Traditional Chinese)
$env:LANGUAGE = 'en'; $env:LANG = 'en_US.UTF-8'
$version = (Invoke-App 'version' @('--version')) -split "`n" | Select-Object -First 1
$env:LANGUAGE = 'zh_TW'; $env:LANG = 'zh_TW.UTF-8'
$versionZh = (Invoke-App 'version-zh' @('--version')) -split "`n" | Select-Object -First 1
Remove-Item Env:\LANGUAGE, Env:\LANG -ErrorAction SilentlyContinue
[IO.File]::WriteAllText((Join-Path $out 'version.txt'), "$version`n$versionZh`n", $utf8)
Write-Output "  --version: $version"
Write-Output ("  --version (zh_TW, base64 UTF-8): {0}" -f [Convert]::ToBase64String($utf8.GetBytes($versionZh)))

# 2. exe version resource
$vi = (Get-Item (Join-Path $bundle "bin\$($g.id).exe")).VersionInfo

# 3. batch job in a throw-away profile (GIMP3_DIRECTORY), which also exercises the first-run profile seeding
Add-Type -AssemblyName System.Drawing
$inPng = Join-Path $out 'in.png'
$bmp = New-Object System.Drawing.Bitmap 400, 300
$gr = [System.Drawing.Graphics]::FromImage($bmp)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point 0, 0), (New-Object System.Drawing.Point 400, 300), [System.Drawing.Color]::FromArgb(30, 58, 95), [System.Drawing.Color]::FromArgb(240, 180, 76))
$gr.FillRectangle($brush, 0, 0, 400, 300)
$gr.FillEllipse([System.Drawing.Brushes]::Crimson, 120, 70, 160, 160)
$gr.Dispose(); $bmp.Save($inPng, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
$outPng = Join-Path $out 'out.png'; $outJpg = Join-Path $out 'out.jpg'; $healPng = Join-Path $out 'heal.png'
$py = @"
from gi.repository import Gimp, Gio
img = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(r'$inPng'))
layer = img.get_layers()[0]
layer.desaturate(Gimp.DesaturateMode.LUMINANCE)
img.scale(img.get_width() // 2, img.get_height() // 2)
for path in (r'$outPng', r'$outJpg'):
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path(path), None)
img.delete()
print('olga-smoke-batch-ok')
# Resynthesizer: heal away the red disc (select it with a margin; the surroundings are the gradient)
proc = Gimp.get_pdb().lookup_procedure('plug-in-heal-selection')
if proc is None:
    print('olga-smoke-resynth-missing')
else:
    img = Gimp.file_load(Gimp.RunMode.NONINTERACTIVE, Gio.File.new_for_path(r'$inPng'))
    img.select_ellipse(Gimp.ChannelOps.REPLACE, 110, 60, 180, 180)
    cfg = proc.create_config()
    cfg.set_property('run-mode', Gimp.RunMode.NONINTERACTIVE)
    cfg.set_property('image', img)
    cfg.set_core_object_array('drawables', [img.get_layers()[0]])
    res = proc.run(cfg)
    print('olga-smoke-resynth-status', 'SUCCESS' if res.index(0) == Gimp.PDBStatusType.SUCCESS else str(res.index(0)))
    img.flatten()
    Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path(r'$healPng'), None)
    img.delete()
"@
$pyFile = Join-Path $out 'batch.py'
[IO.File]::WriteAllText($pyFile, $py.Replace("`r`n", "`n"), $utf8)
$prof = Join-Path $out 'profile'
$env:GIMP3_DIRECTORY = $prof
[void](Invoke-App 'batch' @('-i', '-n', '--batch-interpreter=python-fu-eval', '-b', '-', '--quit') $pyFile)
$batchRc = $lastRc
Remove-Item Env:\GIMP3_DIRECTORY -ErrorAction SilentlyContinue

# 3b. Resynthesizer texts per interface language: each run uses a fresh profile, so GIMP queries every plug-in
# in that language and keeps the labels the plug-in registered (menu label, tooltip, parameter labels). Under
# zh_TW they must be the translations of branding\gimp\resynthesizer-zh_TW.po, under English the source texts.
$resynthProcs = [ordered]@{ 'plug-in-heal-selection' = '_Heal Selection...'; 'plug-in-heal-transparency' = 'Heal Transparency...'
                            'plug-in-uncrop' = 'Uncrop...'; 'plug-in-fill-pattern-resynth' = 'Fill with Pattern Seamless...' }
$resynthBlurb = 'Heal the selection from surroundings as if using the heal tool.'
$resynthNick = 'Context sampling width (pixels)'
$labelPy = @"
import base64, json
from gi.repository import Gimp
pdb = Gimp.get_pdb()
out = {}
for name in $('(' + (($resynthProcs.Keys | ForEach-Object { "'$_'" }) -join ', ') + ')'):
    proc = pdb.lookup_procedure(name)
    if proc is None:
        out[name] = None
    else:
        out[name] = {'menu_label': proc.get_menu_label(), 'blurb': proc.get_blurb(),
                     'nicks': [ps.get_nick() for ps in proc.get_arguments()]}
print('olga-smoke-labels', base64.b64encode(json.dumps(out, ensure_ascii=False).encode('utf-8')).decode('ascii'))
"@
$labelFile = Join-Path $out 'labels.py'
[IO.File]::WriteAllText($labelFile, $labelPy.Replace("`r`n", "`n"), $utf8)
$po = @{}
$rpo = Join-Path $RepoRoot 'branding\gimp\resynthesizer-zh_TW.po'
foreach ($m in [regex]::Matches([IO.File]::ReadAllText($rpo, [Text.Encoding]::UTF8).Replace("`r`n", "`n"), '(?m)^msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"$')) {
    $po[[regex]::Replace($m.Groups[1].Value, '\\(.)', '$1')] = [regex]::Replace($m.Groups[2].Value, '\\(.)', '$1')
}
function Get-Labels([string]$tag, [string]$lang) {
    $env:LANGUAGE = $lang; $env:LANG = "$lang.UTF-8"; $env:GIMP3_DIRECTORY = Join-Path $out "profile-$tag"
    [void](Invoke-App "labels-$tag" @('-i', '-n', '--batch-interpreter=python-fu-eval', '-b', '-', '--quit') $labelFile)
    Remove-Item Env:\LANGUAGE, Env:\LANG, Env:\GIMP3_DIRECTORY -ErrorAction SilentlyContinue
    $b64 = [regex]::Match((Get-Content (Join-Path $out "labels-$tag.out.txt") -Raw), 'olga-smoke-labels (\S+)').Groups[1].Value
    if (-not $b64) { return $null }
    $json = $utf8.GetString([Convert]::FromBase64String($b64))
    [IO.File]::WriteAllText((Join-Path $out "labels-$tag.json"), $json, $utf8)
    return ($json | ConvertFrom-Json)
}
function Test-Labels($labels, [bool]$zh) {
    if ($null -eq $labels) { return @('no output') }
    $bad = @()
    foreach ($k in $resynthProcs.Keys) {
        $want = $resynthProcs[$k]
        if ($zh) { $want = $po[$want] }
        $got = $labels.$k
        if ($null -eq $got) { $bad += "$k missing"; continue }
        if ($got.menu_label -ne $want) { $bad += "$k menu label" }
    }
    $hs = $labels.'plug-in-heal-selection'
    if ($null -ne $hs) {
        $wantBlurb = $resynthBlurb; $wantNick = $resynthNick
        if ($zh) { $wantBlurb = $po[$resynthBlurb]; $wantNick = $po[$resynthNick] }
        if ($hs.blurb -ne $wantBlurb) { $bad += 'heal-selection tooltip' }
        if (@($hs.nicks) -notcontains $wantNick) { $bad += 'heal-selection parameter label' }
    }
    return $bad
}
$labelsZhBad = @('skipped'); $labelsEnBad = @('skipped')
if (-not $NoResynthesizer) {
    $labelsZhBad = @(Test-Labels (Get-Labels 'zh' 'zh_TW') $true)
    $labelsEnBad = @(Test-Labels (Get-Labels 'en' 'en') $false)
    $hz = ''
    if (Test-Path (Join-Path $out 'labels-zh.json')) { $hz = [IO.File]::ReadAllText((Join-Path $out 'labels-zh.json'), [Text.Encoding]::UTF8) }
    if ($hz) { Write-Output ("  Resynthesizer labels (zh_TW, base64 UTF-8 JSON): {0}" -f [Convert]::ToBase64String($utf8.GetBytes($hz.Trim()))) }
}

# 4. default profile folder = %APPDATA%\<nameAscii>\<major.minor> (not GIMP's)
$appProf = Join-Path $env:APPDATA $g.nameAscii
[void](Invoke-App 'profile' @('-i', '-n', '-d', '-f', '--batch-interpreter=plug-in-script-fu-eval', '-b', '(gimp-quit 0)'))
$ownProfile = Test-Path $appProf
$gimpProfileTouched = Test-Path (Join-Path $env:APPDATA 'GIMP\3.2')

# 4b. the product's gimprc block is what GIMP really uses: every "(token value)" line of
# branding\gimp\defaults\gimprc is queried back from the app (a line GIMP cannot parse makes it ignore the rest
# of the file), and the default image comment is the brand's (brand.json gimp.defaultComment, empty = none)
$gimprcWant = [ordered]@{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $RepoRoot 'branding\gimp\defaults\gimprc'), [Text.Encoding]::UTF8)) {
    $m = [regex]::Match($line, '^\(([a-z0-9-]+) (.+)\)\s*$')
    if ($m.Success) { $gimprcWant[$m.Groups[1].Value] = $m.Groups[2].Value }
}
$wantComment = ''
# the default font of the shipped context, and the font family GIMP should find for it
$shippedFont = [regex]::Match([IO.File]::ReadAllText((Join-Path $RepoRoot 'branding\gimp\defaults\profile\contextrc')), '(?m)^\(font "([^"]+)"\)').Groups[1].Value
$fontFamily = ($shippedFont -split ' ')[0..1] -join ' '
if ($null -ne $g.defaultComment) { $wantComment = [string]$g.defaultComment }
$rcPy = @"
import base64, json
from gi.repository import Gimp
out = {}
for t in $('(' + (($gimprcWant.Keys | ForEach-Object { "'$_'" }) -join ', ') + ',)'):
    try:
        out[t] = Gimp.gimprc_query(t)
    except Exception as e:
        out[t] = 'ERROR: %s' % e
out['__default_comment__'] = Gimp.get_default_comment()
out['__fonts__'] = [f.get_name() for f in Gimp.fonts_get_list('$fontFamily')]
print('olga-smoke-gimprc', base64.b64encode(json.dumps(out, ensure_ascii=False).encode('utf-8')).decode('ascii'))
"@
$rcFile = Join-Path $out 'gimprc-query.py'
[IO.File]::WriteAllText($rcFile, $rcPy.Replace("`r`n", "`n"), $utf8)
$env:LANGUAGE = 'en'; $env:LANG = 'en_US.UTF-8'; $env:GIMP3_DIRECTORY = Join-Path $out 'profile-rc'
[void](Invoke-App 'gimprc' @('-i', '-n', '--batch-interpreter=python-fu-eval', '-b', '-', '--quit') $rcFile)
Remove-Item Env:\LANGUAGE, Env:\LANG, Env:\GIMP3_DIRECTORY -ErrorAction SilentlyContinue
function Get-RcText([string]$v) {
    $v = $v.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = [regex]::Replace($v.Substring(1, $v.Length - 2), '\\(.)', '$1') }
    return $v
}
$gimprcBad = @('no output')
$commentOk = $false
$fontFound = $false
$b64 = [regex]::Match((Get-Content (Join-Path $out 'gimprc.out.txt') -Raw), 'olga-smoke-gimprc (\S+)').Groups[1].Value
if ($b64) {
    $rcJson = $utf8.GetString([Convert]::FromBase64String($b64))
    [IO.File]::WriteAllText((Join-Path $out 'gimprc-query.json'), $rcJson, $utf8)
    $rcGot = $rcJson | ConvertFrom-Json
    $gimprcBad = @($gimprcWant.Keys | Where-Object { (Get-RcText ([string]$rcGot.$_)) -ne (Get-RcText $gimprcWant[$_]) })
    $commentOk = ([string]$rcGot.'__default_comment__' -eq $wantComment)
    $fontFound = (@($rcGot.'__fonts__') -contains $shippedFont)
}

# 4c. GUI-only settings files (sessionrc, toolrc, shortcutsrc, controllerrc, devicerc, menus) are parsed by the
# GUI executable only: one batch run of it with a fresh profile, when nobody can see it (see -GuiRcCheck)
$sessionId = (Get-Process -Id $PID).SessionId
$guiRun = ($GuiRcCheck -eq 'yes') -or ($GuiRcCheck -eq 'auto' -and $sessionId -eq 0)
$guiResult = "skipped (session $sessionId has a desktop; -GuiRcCheck yes forces it)"
$guiProf = Join-Path $out 'profile-gui'
if ($guiRun) {
    $env:LANGUAGE = 'en'; $env:LANG = 'en_US.UTF-8'; $env:GIMP3_DIRECTORY = $guiProf
    $gp = Start-Process -FilePath (Join-Path $bundle "bin\$($g.id).exe") -PassThru -NoNewWindow `
        -ArgumentList '-n', '--no-splash', '--console-messages', '--batch-interpreter=plug-in-script-fu-eval', '-b', '"(gimp-quit 0)"' `
        -RedirectStandardOutput (Join-Path $out 'gui.out.txt') -RedirectStandardError (Join-Path $out 'gui.err.txt')
    Remove-Item Env:\LANGUAGE, Env:\LANG, Env:\GIMP3_DIRECTORY -ErrorAction SilentlyContinue
    if ($gp.WaitForExit(300000)) {
        $guiResult = 'ok'
    } else {
        $guiResult = 'timeout'
        Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($bundle, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# 4d. a new profile starts with the shipped context and tool options (patch 0004 seeds them): the starting tool
# is the one in branding\gimp\defaults\profile\contextrc, after a run that loaded and saved it again
$shippedTool = [regex]::Match([IO.File]::ReadAllText((Join-Path $RepoRoot 'branding\gimp\defaults\profile\contextrc')), '\(tool "[^"]+"\)').Value
function Test-Seeded([string]$p, [bool]$options) {
    # the console app never rewrites tool options, so there they must be the shipped file byte for byte
    $ctx = Join-Path $p 'contextrc'; $opt = Join-Path $p 'tool-options\gimp-paintbrush-tool'
    if (-not (Test-Path $ctx) -or -not [IO.File]::ReadAllText($ctx).Contains($shippedTool)) { return $false }
    if (-not $options) { return $true }
    $shippedOpt = Join-Path $RepoRoot 'branding\gimp\defaults\profile\tool-options\gimp-paintbrush-tool'
    return ((Test-Path $opt) -and ([IO.File]::ReadAllText($opt) -eq [IO.File]::ReadAllText($shippedOpt)))
}
$seededConsole = Test-Seeded $prof $true
$seededGui = $null
if ($guiResult -eq 'ok') { $seededGui = Test-Seeded $guiProf $false }

# 4e. settings files: no run may report a parse error (English and Traditional Chinese message texts)
$parseErrors = @(Get-ChildItem $out -File | Where-Object { $_.Name -match '\.(out|err)\.txt$' } | ForEach-Object {
    $f = $_
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($t, '(?im)^.*(error while parsing|parse error|error parsing your|unexpected identifier|\u5256\u6790|\u5206\u6790\u300c[^\u300d]+\u300d\u7b2c).*$')) {
        "$($f.Name): $($m.Value.Trim())"
    }
})
[IO.File]::WriteAllText((Join-Path $out 'rc-parse-errors.txt'), ($parseErrors -join "`n"), $utf8)

# 4f. other text domains (libgimp, plug-ins, Script-Fu, Python, GEGL): the added translations are there, no
# text that a word rule covers still has the old word, and GLib's catalog is bundled (MSYS2 Python's gettext)
$catPy = @'
import base64, csv, gettext, json, os, re, sys
loc, here = sys.argv[1], sys.argv[2]
bad = []
cats = {}
def cat(dom):
    if dom not in cats:
        try:
            cats[dom] = gettext.translation(dom, localedir=loc, languages=['zh_TW'])
        except OSError:
            cats[dom] = gettext.NullTranslations()
            cats[dom]._catalog = {}
            bad.append('zh_TW catalog missing: ' + dom)
    return cats[dom]
for r in csv.DictReader(open(os.path.join(here, 'zh_TW-translations.csv'), encoding='utf-8-sig')):
    t = cat(r['domain'])
    got = t.pgettext(r['context'], r['msgid']) if r['context'] else t.gettext(r['msgid'])
    if got != r['zh_TW']:
        bad.append('translation missing: %s %s' % (r['domain'], r['msgid']))
words = list(csv.DictReader(open(os.path.join(here, 'zh_TW-term-words.csv'), encoding='utf-8-sig')))
for dom in ('gimp30', 'gimp30-libgimp', 'gimp30-std-plug-ins', 'gimp30-python', 'gimp30-script-fu', 'gegl-0.4'):
    for key, val in cat(dom)._catalog.items():
        mid = key[0] if isinstance(key, tuple) else key
        mid = mid.split('\x04', 1)[-1].replace('_', '')
        if not mid:
            continue
        for w in words:
            if w['domains'] and dom not in w['domains'].split():
                continue
            if re.search(w['msgid_regex'], mid) and not (w['except_regex'] and re.search(w['except_regex'], mid)):
                old, new = w['old_zh_TW'], w['new_zh_TW']
                if old in (val.replace(new, '') if old in new else val):
                    bad.append('old wording left: %s %r (%s)' % (dom, mid, w['term']))
                    break
glib = cat('glib20')
if len(glib._catalog) < 100:
    bad.append('GLib zh_TW catalog missing or empty')
print('olga-smoke-catalogs', base64.b64encode(json.dumps(bad, ensure_ascii=False).encode('utf-8')).decode('ascii'))
'@
$catFile = Join-Path $out 'catalogs.py'
[IO.File]::WriteAllText($catFile, $catPy.Replace("`r`n", "`n"), $utf8)
$msysPy = Join-Path (Get-MsysRoot $Root 'gimp') 'clang64\bin\python.exe'
$catOut = & $msysPy -I $catFile (Join-Path $bundle 'share\locale') (Join-Path $RepoRoot 'branding\gimp') 2> (Join-Path $out 'catalogs.err.txt')
$catBad = @('no output')
$b64 = [regex]::Match(($catOut -join "`n"), 'olga-smoke-catalogs (\S+)').Groups[1].Value
if ($b64) {
    $catJson = $utf8.GetString([Convert]::FromBase64String($b64))
    [IO.File]::WriteAllText((Join-Path $out 'catalogs.json'), $catJson, $utf8)
    # PS 5.1: ConvertFrom-Json emits a JSON array as one object; enumerate it
    $catBad = @($catJson | ConvertFrom-Json | ForEach-Object { $_ })
}

# 5. catalogs
function Count-Bytes([string]$file, [string]$needle) {
    if (-not (Test-Path $file)) { return -1 }
    $hay = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file))
    $n = [Text.Encoding]::GetEncoding(28591).GetString($utf8.GetBytes($needle))
    return ([regex]::Matches($hay, [regex]::Escape($n))).Count
}
$zhMo = Join-Path $bundle 'share\locale\zh_TW\LC_MESSAGES\gimp30.mo'
$enMo = Join-Path $bundle 'share\locale\en\LC_MESSAGES\gimp30.mo'

# 6. zh_TW wording table: every new text is in the compiled catalog; the branded .po passes msgfmt --check
$terms = @(Import-Csv -Encoding UTF8 (Join-Path $RepoRoot 'branding\gimp\zh_TW-terms.csv'))
$termsMissing = @($terms | Where-Object { (Count-Bytes $zhMo $_.new_zh_TW) -le 0 } | ForEach-Object { $_.msgid })
$zhPo = Join-Path $Root "src\gimp-$GimpVersion\po\zh_TW.po"
$msgfmt = Join-Path (Get-MsysRoot $Root 'gimp') 'clang64\bin\msgfmt.exe'
$checkMo = Join-Path $out 'zh_TW-check.mo'
& $msgfmt --check -o $checkMo $zhPo 2> (Join-Path $out 'msgfmt-check.err.txt')
$msgfmtRc = $LASTEXITCODE
[IO.File]::WriteAllText((Join-Path $out 'terms-missing.txt'), ($termsMissing -join "`n"), $utf8)

# 7. Resynthesizer result: the centre of the healed disc is no longer red
$healCentre = ''
$healed = $false
if (Test-Path $healPng) {
    $im = New-Object System.Drawing.Bitmap $healPng
    $c = $im.GetPixel(200, 150); $im.Dispose()
    $healCentre = "$($c.R),$($c.G),$($c.B)"
    $healed = -not ($c.R -gt 150 -and $c.G -lt 80 -and $c.B -lt 110)
}

# 8. Group/Ungroup actions compiled in; mascot artwork gone
$exeMain = Join-Path $bundle "bin\$($g.id).exe"
$groupActions = ((Count-Bytes $exeMain 'layers-group-selected') -gt 0) -and ((Count-Bytes $exeMain 'layers-ungroup') -gt 0)
$share = Join-Path $bundle 'share\gimp\3.0'
$mascotGone = -not (Test-Path (Join-Path $share 'brushes\Fun\Wilber.gih'))
$sid = Join-Path $share 'images\sidrat.data'
if (Test-Path $sid) { $im = [System.Drawing.Image]::FromFile($sid); if ($im.Height -ne $im.Width) { $mascotGone = $false }; $im.Dispose() }

function SizeOf($f) { if (Test-Path $f) { return (Get-Item $f).Length } else { return 0 } }
$sysShortcuts = Join-Path $bundle 'etc\gimp\3.0\shortcutsrc'
$sysTemplates = Join-Path $bundle 'etc\gimp\3.0\templaterc'
$sysGimprc = Join-Path $bundle 'etc\gimp\3.0\gimprc'
# 9. the files shipped from branding\gimp\defaults (as installed) name no other vendor's product
$sysEtc = Join-Path $bundle 'etc\gimp\3.0'
$shippedDefaults = @('shortcutsrc', 'sessionrc', 'toolrc', 'gimprc', 'templaterc', 'controllerrc', 'gimp.css' | ForEach-Object { Join-Path $sysEtc $_ }) +
    @(Get-ChildItem -Recurse -File (Join-Path $sysEtc 'defaults') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) +
    @(Join-Path $bundle 'GUIDE-zh_TW.html')
$vendorWords = @($shippedDefaults | Where-Object { (Test-Path $_) -and ([IO.File]::ReadAllText($_) -match '(?i)photoshop|adobe') } |
    ForEach-Object { $_.Substring($bundle.Length + 1) })
# 9b. the product's keys, mouse wheel, tool and style defaults are in the installed files (GIMP parsing them is
# checked by the rc parse guard above): each entry = file, pattern
$sysText = @{}
function Get-SysText([string]$rel) {
    if (-not $sysText.ContainsKey($rel)) {
        $f = Join-Path $sysEtc $rel
        $sysText[$rel] = ''
        if (Test-Path $f) { $sysText[$rel] = [IO.File]::ReadAllText($f) }
    }
    return $sysText[$rel]
}
$expectDefaults = [ordered]@{
    'heal on Shift+F5 / Shift+Backspace'   = @('shortcutsrc', '(?m)^\(action "plug-in-heal-selection" "<Shift>F5" "<Shift>BackSpace"\)')
    'stamp visible Ctrl+Alt+Shift+E'       = @('shortcutsrc', '(?m)^\(action "layers-new-from-visible" "<Primary><Shift><Alt>e"\)')
    'new layer Ctrl+Alt+Shift+N'           = @('shortcutsrc', '(?m)^\(action "layers-new-last-values" "<Primary><Shift><Alt>n"\)')
    'preferences Ctrl+K'                   = @('shortcutsrc', '(?m)^\(action "dialogs-preferences" "<Primary>k"\)')
    'shortcuts Ctrl+Alt+Shift+K'           = @('shortcutsrc', '(?m)^\(action "dialogs-keyboard-shortcuts" "<Primary><Shift><Alt>k"\)')
    'print Ctrl+P'                         = @('shortcutsrc', '(?m)^\(action "file-print-gtk" "<Primary>p"\)')
    'warp Ctrl+Shift+X'                    = @('shortcutsrc', '(?m)^\(action "tools-warp" "<Primary><Shift>x"\)')
    'merge visible Ctrl+Shift+E'           = @('shortcutsrc', '(?m)^\(action "image-merge-layers" "<Primary><Shift>e"\)')
    'paste in place Ctrl+Shift+V'          = @('shortcutsrc', '(?m)^\(action "edit-paste-in-place" "<Primary><Shift>v" "<Primary><Alt>v"\)')
    'paste as new image keyless'           = @('shortcutsrc', '(?m)^\(action "edit-paste-as-new-image"\)')
    'brush size [ ] 10 px'                 = @('shortcutsrc', '(?ms)^\(action "tools-size-decrease-skip" "bracketleft"\).*^\(action "tools-size-increase-skip" "bracketright"\)')
    'no digit zoom'                        = @('shortcutsrc', '(?ms)^\(action "view-zoom-1-1" "<Primary>1"\).*^\(action "view-zoom-2-1"\).*^\(action "view-zoom-16-1"\).*^\(action "view-zoom-1-16"\)')
    'Alt+wheel zooms'                      = @('controllerrc', '"scroll-up-alt"\s+"view-zoom-in"[\s\S]*"scroll-down-alt"\s+"view-zoom-out"')
    'Move tool moves the selected layer'   = @('defaults\tool-options\gimp-move-tool', '(?m)^\(move-current yes\)')
    'default font (context)'               = @('defaults\contextrc', '(?m)^\(font "Microsoft JhengHei UI Regular"\)')
    'default font (text tool)'             = @('defaults\tool-options\gimp-text-tool', '(?m)^\(font "Microsoft JhengHei UI Regular"\)')
    'selected-row style'                   = @('gimp.css', 'GimpDock treeview\.view:selected')
}
$defaultsMissing = @($expectDefaults.Keys | Where-Object { -not ((Get-SysText $expectDefaults[$_][0]) -match $expectDefaults[$_][1]) })
# no other binding uses a key that the product moved (a GIMP default left on it would compete)
$shortcutText = Get-SysText 'shortcutsrc'
$keyClashes = @('"<Primary><Shift>e"', '"<Primary><Shift>v"', '"<Shift>F5"', '"<Shift>BackSpace"', '"<Primary>k"', '"<Primary>p"', '"<Primary><Shift>x"', '"bracketleft"', '"bracketright"' | Where-Object {
    ([regex]::Matches($shortcutText, '(?m)^\(action "[^"]+"[^\r\n]*' + [regex]::Escape($_))).Count -ne 1 })
$guideOk = (Test-Path (Join-Path $bundle 'GUIDE-zh_TW.html')) -and ([IO.File]::ReadAllText((Join-Path $bundle 'GUIDE-zh_TW.html')) -match [regex]::Escape($g.name))
# 10. Resynthesizer zh_TW catalog in every Resynthesizer plug-in folder
$plugDir = Join-Path $bundle 'lib\gimp\3.0\plug-ins'
$resynthDirs = @(Get-ChildItem -Directory $plugDir | Where-Object { Test-Path (Join-Path $_.FullName 'locale\fr\LC_MESSAGES\resynthesizer3.mo') })
$resynthZhMo = @($resynthDirs | Where-Object { Test-Path (Join-Path $_.FullName 'locale\zh_TW\LC_MESSAGES\resynthesizer3.mo') })
$res = [ordered]@{
    version            = $version
    brandInVersion     = ($version -like "$($g.name) *" -and $version -like '*based on GIMP*')
    versionSuffix      = ($version -like "* $GimpVersion$($g.versionSuffix) *")
    brandInVersionZh   = ($versionZh -like "$($g.name) *")
    exeProductName     = $vi.ProductName
    exeCompany         = $vi.CompanyName
    exeProductVersion  = $vi.ProductVersion
    batchRc            = $batchRc
    batchPrinted       = ((Get-Content (Join-Path $out 'batch.out.txt') -Raw) -match 'olga-smoke-batch-ok')
    outPngBytes        = (SizeOf $outPng)
    outJpgBytes        = (SizeOf $outJpg)
    newProfileSeeded   = $seededConsole
    newProfileSeededGui = $seededGui
    ownProfileDir      = $ownProfile
    gimpProfileTouched = $gimpProfileTouched
    zhTwMoBrandCount   = (Count-Bytes $zhMo $g.name)
    enMoBrandCount     = (Count-Bytes $enMo $g.name)
    defaultShortcuts   = ((Test-Path $sysShortcuts) -and ((Get-Content $sysShortcuts -Raw) -match 'tools-unified-transform" "<Primary>t"') -and
                          ((Get-Content $sysShortcuts -Raw) -match 'layers-merge-down" "<Primary>e"'))
    defaultTemplates   = ((Test-Path $sysTemplates) -and ((Get-Content $sysTemplates -Raw) -match 'Product templates \(olga-creative\)'))
    resynthStatus      = ([regex]::Match((Get-Content (Join-Path $out 'batch.out.txt') -Raw), 'olga-smoke-resynth-status (\S+)').Groups[1].Value)
    healCentreRgb      = $healCentre
    healed             = $healed
    termsTotal         = $terms.Count
    termsMissingInMo   = $termsMissing.Count
    msgfmtCheckRc      = $msgfmtRc
    groupActions       = $groupActions
    mascotGone         = $mascotGone
    shortcutsPhotoshop = ((Test-Path $sysShortcuts) -and ((Get-Content $sysShortcuts -Raw) -match 'file-export-as" "<Primary><Shift>s"') -and
                          ((Get-Content $sysShortcuts -Raw) -match 'layers-group-selected" "<Primary>g"'))
    defaultGimprc      = ((Test-Path $sysGimprc) -and ((Get-Content $sysGimprc -Raw) -match '(?m)^\(theme-color-scheme dark\)'))
    gimprcNotApplied   = ($gimprcBad -join ', ')
    defaultComment     = $commentOk
    jpgCreatedWith     = (Count-Bytes $outJpg 'Created with')
    productDefaultsMissing = ($defaultsMissing -join ', ')
    keyClashes         = ($keyClashes -join ' ')
    guide              = $guideOk
    defaultFontFound   = $fontFound
    redoShortcut       = ((Test-Path $sysShortcuts) -and ((Get-Content $sysShortcuts -Raw) -match '(?m)^\(action "edit-redo" "<Primary><Shift>z"'))
    guiRun             = $guiResult
    rcParseErrors      = $parseErrors.Count
    catalogProblems    = ($catBad -join '; ')
    defaultsVendorWords = ($vendorWords -join ', ')
    resynthZhCatalogs  = "$($resynthZhMo.Count)/$($resynthDirs.Count)"
    resynthLabelsZh    = ($labelsZhBad -join ', ')
    resynthLabelsEn    = ($labelsEnBad -join ', ')
}
if ($res.outPngBytes -gt 0) {
    $im = [System.Drawing.Image]::FromFile($outPng); $res.outPngSize = "$($im.Width)x$($im.Height)"; $im.Dispose()
}
[IO.File]::WriteAllText((Join-Path $out 'result.json'), ($res | ConvertTo-Json), $utf8)
$res.GetEnumerator() | ForEach-Object { Write-Output ("  {0} = {1}" -f $_.Key, $_.Value) }
$fail = @()
foreach ($k in 'brandInVersion', 'versionSuffix', 'brandInVersionZh', 'batchPrinted', 'newProfileSeeded', 'ownProfileDir', 'defaultShortcuts', 'defaultTemplates', 'defaultGimprc', 'groupActions', 'mascotGone', 'shortcutsPhotoshop', 'defaultComment', 'redoShortcut') { if (-not $res[$k]) { $fail += $k } }
if ($defaultsMissing.Count) { $fail += "product defaults missing: $($defaultsMissing -join ', ')" }
if ($keyClashes.Count) { $fail += "keys bound more than once (or not at all): $($keyClashes -join ' ')" }
# the default font ships with Traditional Chinese Windows; on a build box that has the file it must resolve
if (-not $fontFound -and (Test-Path (Join-Path $env:WINDIR 'Fonts\msjh.ttc'))) { $fail += "default font '$shippedFont' not found by name" }
if (-not $guideOk) { $fail += 'customer guide GUIDE-zh_TW.html missing or not branded' }
if ($parseErrors.Count) { $fail += "settings file parse errors: $($parseErrors -join ' | ')" }
if ($gimprcBad.Count) { $fail += "gimprc values GIMP does not use: $($gimprcBad -join ', ')" }
if ($res.jpgCreatedWith -ne 0) { $fail += 'default comment written into the exported JPEG' }
if ($guiResult -eq 'timeout') { $fail += 'GUI settings check: the GUI run did not quit' }
if ($null -ne $seededGui -and -not $seededGui) { $fail += 'new profile (GUI run) does not start with the shipped context' }
if ($catBad.Count) { $fail += "text domains: $($catBad -join '; ')" }
if ($res.outPngBytes -le 0 -or $res.outJpgBytes -le 0) { $fail += 'export' }
if ($res.outPngSize -ne '200x150') { $fail += 'scale' }
if ($res.zhTwMoBrandCount -le 0) { $fail += 'zh_TW catalog' }
if ($res.termsMissingInMo -gt 0) { $fail += "zh_TW terms missing from the catalog: $($termsMissing -join '; ')" }
if ($res.msgfmtCheckRc -ne 0) { $fail += 'msgfmt --check' }
if (-not $NoResynthesizer -and ($res.resynthStatus -ne 'SUCCESS' -or -not $res.healed)) { $fail += 'Resynthesizer heal selection' }
if ($vendorWords.Count) { $fail += "other vendors' product names in the shipped defaults: $($vendorWords -join ', ')" }
if (-not $NoResynthesizer) {
    if ($resynthDirs.Count -lt 8 -or $resynthZhMo.Count -ne $resynthDirs.Count) { $fail += "Resynthesizer zh_TW catalogs: $($res.resynthZhCatalogs)" }
    if ($labelsZhBad.Count) { $fail += "Resynthesizer labels under zh_TW: $($labelsZhBad -join '; ')" }
    if ($labelsEnBad.Count) { $fail += "Resynthesizer labels under English: $($labelsEnBad -join '; ')" }
}
if ($fail.Count) { throw "smoke test FAILED: $($fail -join ', ')" }
Write-Step 'smoke test passed'
