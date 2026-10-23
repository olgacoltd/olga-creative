<#
.SYNOPSIS
  Headless smoke test of the built GIMP-based app (console executable only, no GUI is opened).
  Results land in <Root>\smoke-gimp\ : version*.txt, in.png, out.png, out.jpg, result.json, *.out/err.txt

  Checks: --version shows the brand and version suffix (English and zh_TW), exe version resource, a Python
  batch job (open PNG -> desaturate + scale -> export PNG and JPG), Resynthesizer's Heal Selection on a test
  image, a new profile gets the brand's default settings, the default profile folder is the brand's own, the
  zh_TW / en catalogs carry the brand name, every new wording of branding\gimp\zh_TW-terms.csv is in the
  compiled zh_TW catalog and the branded zh_TW.po passes msgfmt --check, the default shortcuts (Export As on
  Ctrl+Shift+S, Group Layers on Ctrl+G) and the Group/Ungroup actions are in the app, the mascot artwork is gone.
#>
param([string]$Root = 'C:\olga-build', [string]$GimpVersion = '3.2.6', [switch]$NoResynthesizer)
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
$seeded = @('contextrc', 'tool-options\gimp-paintbrush-tool') | Where-Object { Test-Path (Join-Path $prof $_) }

# 4. default profile folder = %APPDATA%\<nameAscii>\<major.minor> (not GIMP's)
$appProf = Join-Path $env:APPDATA $g.nameAscii
[void](Invoke-App 'profile' @('-i', '-n', '-d', '-f', '--batch-interpreter=plug-in-script-fu-eval', '-b', '(gimp-quit 0)'))
$ownProfile = Test-Path $appProf
$gimpProfileTouched = Test-Path (Join-Path $env:APPDATA 'GIMP\3.2')

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
    newProfileSeeded   = ($seeded.Count -eq 2)
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
    defaultGimprc      = ((Test-Path $sysGimprc) -and ((Get-Content $sysGimprc -Raw) -match '(?m)^\(theme-color-scheme dark\)') -and
                          ((Get-Content $sysGimprc -Raw) -match '(?m)^\(single-window-mode yes\)'))
}
if ($res.outPngBytes -gt 0) {
    $im = [System.Drawing.Image]::FromFile($outPng); $res.outPngSize = "$($im.Width)x$($im.Height)"; $im.Dispose()
}
[IO.File]::WriteAllText((Join-Path $out 'result.json'), ($res | ConvertTo-Json), $utf8)
$res.GetEnumerator() | ForEach-Object { Write-Output ("  {0} = {1}" -f $_.Key, $_.Value) }
$fail = @()
foreach ($k in 'brandInVersion', 'versionSuffix', 'brandInVersionZh', 'batchPrinted', 'newProfileSeeded', 'ownProfileDir', 'defaultShortcuts', 'defaultTemplates', 'defaultGimprc', 'groupActions', 'mascotGone', 'shortcutsPhotoshop') { if (-not $res[$k]) { $fail += $k } }
if ($res.outPngBytes -le 0 -or $res.outJpgBytes -le 0) { $fail += 'export' }
if ($res.outPngSize -ne '200x150') { $fail += 'scale' }
if ($res.zhTwMoBrandCount -le 0) { $fail += 'zh_TW catalog' }
if ($res.termsMissingInMo -gt 0) { $fail += "zh_TW terms missing from the catalog: $($termsMissing -join '; ')" }
if ($res.msgfmtCheckRc -ne 0) { $fail += 'msgfmt --check' }
if (-not $NoResynthesizer -and ($res.resynthStatus -ne 'SUCCESS' -or -not $res.healed)) { $fail += 'Resynthesizer heal selection' }
if ($fail.Count) { throw "smoke test FAILED: $($fail -join ', ')" }
Write-Step 'smoke test passed'
