<#
.SYNOPSIS
  Build the rebranded Inkscape for Windows (MSYS2 UCRT64, CMake + Ninja) and package it.

.DESCRIPTION
  Resumable: every step checks what is already there, so re-running after a dropped connection, sleep or
  a failed step continues instead of starting over:
    1. MSYS2 toolchain           setup-msys2.ps1 (skipped when present)
    2. source checkout           <Root>\src\inkscape, tag + submodules (skipped when complete)
    3. branding                  patches + apply-branding.py; re-applied only when a patch, the script,
                                 brand.json or the tag changed (stamp file)
    4. configure                 only when build.ninja is missing or the branding changed
    5. compile + install/strip   ninja (incremental; the build dir is kept)
    6. package                   portable zip (+ NSIS installer if makensis is available)
    7. smoke test                smoke-test-inkscape.ps1 (CLI only, no GUI)

  Run it detached on a remote box:  windows\run-detached.ps1 -Name inkscape -Script build-inkscape.ps1 -Root <root>

.PARAMETER Clean  Delete the build directory first (full recompile). The checkout and MSYS2 are kept.
#>
param(
    [string]$Root = 'C:\olga-build',
    [string]$Tag = 'INKSCAPE_1_4_4',
    [string]$Repo = 'https://gitlab.com/inkscape/inkscape.git',
    [ValidateSet('idw', 'rolling')] [string]$MsysMode = 'idw',
    [int]$Jobs = 0,
    [switch]$Clean,
    [switch]$NoInstaller,
    [switch]$NoSmokeTest
)
. "$PSScriptRoot\common.ps1"
$t0 = Get-Date

# ---------------------------------------------------------------- brand
$brand = Get-Brand
$ink = $brand.inkscape
if ($ink.id -notmatch '^[a-z][a-z0-9-]{1,30}$') { throw "brand.json inkscape.id must be lower-case ascii: $($ink.id)" }
if ($ink.nameAscii -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,40}$') { throw "brand.json inkscape.nameAscii must be ascii: $($ink.nameAscii)" }
if ($ink.appId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') { throw "brand.json inkscape.appId invalid: $($ink.appId)" }
foreach ($v in @($ink.name, $brand.vendor, $ink.summary, $brand.url)) {
    if ($v -match '["\\;]') { throw "brand.json values may not contain quote, backslash or semicolon: $v" }
}
Write-Step "brand: $($ink.name) ($($ink.id), $($ink.appId)) from tag $Tag"

# ---------------------------------------------------------------- 1. toolchain
& "$PSScriptRoot\setup-msys2.ps1" -Root $Root -Mode $MsysMode
$msys = Get-MsysRoot $Root

# ---------------------------------------------------------------- 2. source
$srcParent = Join-Path $Root 'src'
$src = Join-Path $srcParent 'inkscape'
$cloneMarker = Join-Path $srcParent "inkscape.$Tag.cloned"
Ensure-Dir $srcParent
if (-not (Test-Path $cloneMarker)) {
    Write-Step "source: $Repo @ $Tag"
    $s = ConvertTo-MsysPath $src
    if (-not (Test-Path (Join-Path $src '.git'))) {
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        Invoke-Msys $msys "git clone --depth 1 --branch '$Tag' '$Repo' '$s'"
    } else {
        Write-Output '  checkout exists, completing it'
    }
    # --depth 1 submodules; resumable (re-running fetches only what is missing)
    Invoke-Msys $msys "cd '$s' && git -c protocol.version=2 submodule update --init --recursive --depth 1 --jobs 4"
    Set-Content -Path $cloneMarker -Value (Get-Date -Format o)
} else {
    Write-Step 'source: present'
}

# ---------------------------------------------------------------- 3. branding
$bdir = Join-Path $RepoRoot 'branding\inkscape'
$patches = @(Get-ChildItem (Join-Path $bdir 'patches') -Filter '*.patch' | Sort-Object Name)
$hashInputs = @($patches | ForEach-Object { $_.FullName }) + @((Join-Path $bdir 'apply-branding.py'), (Join-Path $RepoRoot 'brand.json'))
$sha = [Security.Cryptography.SHA256]::Create()
$acc = New-Object System.Text.StringBuilder
[void]$acc.Append($Tag)
foreach ($f in $hashInputs) {
    [void]$acc.Append([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f))))
}
$stamp = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($acc.ToString()))).Replace('-', '')
$stampFile = Join-Path $srcParent 'inkscape.brand-stamp'
$oldStamp = ''
if (Test-Path $stampFile) { $oldStamp = (Get-Content $stampFile -TotalCount 1).Trim() }
$brandChanged = ($stamp -ne $oldStamp)
if ($brandChanged) {
    Write-Step "branding: applying $($patches.Count) patches + apply-branding.py"
    $s = ConvertTo-MsysPath $src
    Remove-Item -Force $stampFile -ErrorAction SilentlyContinue
    # back to the pristine tag (only files that differ are rewritten, so ninja recompiles just those)
    Invoke-Msys $msys "cd '$s' && git reset -q --hard && git clean -q -fd && git submodule foreach -q --recursive 'git reset -q --hard && git clean -q -fd'"
    foreach ($pf in $patches) {
        Write-Output "  patch $($pf.Name)"
        Invoke-Msys $msys "cd '$s' && git apply --whitespace=nowarn '$(ConvertTo-MsysPath $pf.FullName)'"
    }
    $py = "'$(ConvertTo-MsysPath (Join-Path $bdir 'apply-branding.py'))' '$s' '$(ConvertTo-MsysPath (Join-Path $RepoRoot 'brand.json'))'"
    Invoke-Msys $msys "/ucrt64/bin/python -I $py"
    Set-Content -Path $stampFile -Value $stamp
} else {
    Write-Step 'branding: up to date'
}

# ---------------------------------------------------------------- 4. configure
$build = Join-Path $Root "build\inkscape"
$prefix = Join-Path $build $ink.id           # install tree; becomes the top folder of the zip
if ($Clean -and (Test-Path $build)) {
    Write-Step "clean: removing $build"
    Remove-Item -Recurse -Force $build
}
Ensure-Dir $build
# Brand values go through a UTF-8 cache script (-C) so non-ASCII names survive PowerShell -> bash -> cmake
$cacheFile = Join-Path (Split-Path -Parent $build) 'inkscape-brand.cmake'
$cache = @"
set(OLGA_BRAND_NAME "$($ink.name)" CACHE STRING "" FORCE)
set(OLGA_BRAND_NAME_ASCII "$($ink.nameAscii)" CACHE STRING "" FORCE)
set(OLGA_BRAND_ID "$($ink.id)" CACHE STRING "" FORCE)
set(OLGA_APP_ID "$($ink.appId)" CACHE STRING "" FORCE)
set(OLGA_BRAND_VENDOR "$($brand.vendor)" CACHE STRING "" FORCE)
set(OLGA_BRAND_URL "$($brand.url)" CACHE STRING "" FORCE)
set(OLGA_BRAND_VERSION_SUFFIX "$($ink.versionSuffix)" CACHE STRING "" FORCE)
set(OLGA_BRAND_SUMMARY "$($ink.summary)" CACHE STRING "" FORCE)
"@
[IO.File]::WriteAllText($cacheFile, $cache.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))

$ninjaFile = Join-Path $build 'build.ninja'
if ($brandChanged -or -not (Test-Path $ninjaFile)) {
    Write-Step 'configure (cmake)'
    $s = ConvertTo-MsysPath $src; $b = ConvertTo-MsysPath $build
    $launcher = 'if command -v ccache >/dev/null; then L="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"; fi'
    $ccacheDir = ConvertTo-MsysPath (Join-Path $Root 'ccache')
    Invoke-Msys $msys "export CCACHE_DIR='$ccacheDir'; $launcher; cmake -S '$s' -B '$b' -G Ninja -C '$(ConvertTo-MsysPath $cacheFile)' -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX='$(ConvertTo-MsysPath $prefix)' `$L"
} else {
    Write-Step 'configure: up to date'
}

# ---------------------------------------------------------------- 5. build + install
if ($Jobs -le 0) { $Jobs = Get-DefaultJobs }    # CPU threads minus 2, at Idle priority
Write-Step "build: ninja -j $Jobs install/strip"
$tb = Get-Date
$b = ConvertTo-MsysPath $build
# fresh install tree every time, so files dropped by a branding change do not linger in the package
if (Test-Path $prefix) { Remove-Item -Recurse -Force $prefix }
$ccacheDir = ConvertTo-MsysPath (Join-Path $Root 'ccache')
Invoke-Msys $msys "export CCACHE_DIR='$ccacheDir'; ninja -C '$b' -j $Jobs install/strip"
Write-Step ("build: done in {0:N1} min" -f ((Get-Date) - $tb).TotalMinutes)

# ---------------------------------------------------------------- 6. package
$exe = Join-Path $prefix "bin\$($ink.id).exe"
if (-not (Test-Path $exe)) { throw "install tree incomplete: $exe missing" }
# licence + credit are installed by patch 0006 (COPYING, LICENSES\, NOTICE.txt); make sure they are there
foreach ($f in 'COPYING', 'NOTICE.txt', 'LICENSES') {
    if (-not (Test-Path (Join-Path $prefix $f))) { throw "licence file missing from the install tree: $f" }
}
$inkVer = (Select-String -Path (Join-Path $src 'CMakeLists.txt') -Pattern 'set\(INKSCAPE_VERSION_(MAJOR|MINOR|PATCH)\s+(\d+)' |
    ForEach-Object { $_.Matches[0].Groups[2].Value }) -join '.'

$dist = Join-Path $Root 'dist'
Ensure-Dir $dist
$ErrorActionPreference = 'Continue'   # PS 5.1: native stderr redirect + Stop = exception
$ver = (& (Join-Path $prefix "bin\$($ink.id).com") --version 2>$null | Select-Object -First 1)
$ErrorActionPreference = 'Stop'
Write-Output "  version: $ver"
$verTag = "$inkVer$($ink.versionSuffix)"
$zip = Join-Path $dist ("{0}-{1}-win64-portable.zip" -f $ink.id, $verTag)
Write-Step "package: $zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($prefix, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Write-Output ("  {0:N0} MB" -f ((Get-Item $zip).Length / 1MB))

if (-not $NoInstaller) {
    $hasNsis = $true
    try { Invoke-Msys $msys 'command -v makensis >/dev/null' } catch { $hasNsis = $false }
    if ($hasNsis) {
        Write-Step 'package: NSIS installer (ninja dist-win-exe)'
        try {
            Invoke-Msys $msys "export CCACHE_DIR='$ccacheDir'; ninja -C '$b' dist-win-exe"
            Get-ChildItem $build -Filter "$($ink.id)-*.exe" | ForEach-Object { Copy-Item -Force $_.FullName $dist; Write-Output "  $($_.Name)" }
        } catch {
            Write-Output "  installer failed (portable zip is still fine): $($_.Exception.Message)"
        }
    } else {
        Write-Output '  installer skipped: makensis not in this MSYS2 (pacman -S mingw-w64-ucrt-x86_64-nsis)'
    }
}

# ---------------------------------------------------------------- 7. smoke test
if (-not $NoSmokeTest) {
    & "$PSScriptRoot\smoke-test-inkscape.ps1" -Root $Root
}

$used = (Get-ChildItem -Recurse -Force $Root -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
Write-Step ("ALL DONE in {0:N1} min; {1} uses {2:N1} GB" -f ((Get-Date) - $t0).TotalMinutes, $Root, ($used / 1GB))
