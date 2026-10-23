<#
.SYNOPSIS
  Non-admin, idempotent MSYS2 (UCRT64) toolchain for building Inkscape.

.DESCRIPTION
  Two modes:
    idw      (default) Upstream Inkscape CI's own frozen MSYS2 snapshot ("inkscape-ci-windows", the IDW_VERSION
             pinned in the tag's .gitlab-ci.yml). Exactly the package set the tag is known to build with,
             so a rolling MSYS2 update cannot break a release-tag build. ~570 MB download.
    rolling  Fresh MSYS2 base + `pacman -Syuu` + upstream buildtools/msys2installdeps.sh (needs the source
             tree already cloned, see build-inkscape.ps1 -SkipBuild). Use for newer tags / GIMP.

  Everything lands under -Root. Safe to re-run: finished steps are skipped (marker files), downloads resume.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\setup-msys2.ps1 -Root C:\olga-build
#>
param(
    [string]$Root = 'C:\olga-build',
    [ValidateSet('idw', 'rolling')] [string]$Mode = 'idw',
    [int]$IdwVersion = 168,
    [string]$InkscapeSrc = ''      # rolling mode: path of the inkscape checkout (for msys2installdeps.sh)
)
. "$PSScriptRoot\common.ps1"

Ensure-Dir $Root
$dl = Join-Path $Root 'downloads'
$tools = Join-Path $Root 'tools'
Ensure-Dir $dl; Ensure-Dir $tools

# 7zr.exe: the standalone 7-Zip console extractor (.7z only), no install needed
$sevenZ = Join-Path $tools '7zr.exe'
Get-File 'https://www.7-zip.org/a/7zr.exe' $sevenZ

if ($Mode -eq 'idw') {
    $name = "ink$IdwVersion"
    $msys = Join-Path $Root $name
    $marker = Join-Path $msys '.olga-extracted'
    if (-not (Test-Path $marker)) {
        Write-Step "MSYS2 snapshot $name (upstream inkscape-ci-windows r$IdwVersion)"
        $archive = Join-Path $dl "$name.7z"
        Get-File "https://gitlab.com/api/v4/projects/46863172/packages/generic/windows/r$IdwVersion/$name.7z" $archive
        if (Test-Path $msys) { Remove-Item -Recurse -Force $msys }   # half-extracted leftovers
        Write-Step "extracting $archive"
        & $sevenZ x -y "-o$Root" $archive | Select-Object -Last 3
        if ($LASTEXITCODE -ne 0) { throw "7zr failed ($LASTEXITCODE)" }
        if (-not (Test-Path (Join-Path $msys 'usr\bin\bash.exe'))) { throw "unexpected archive layout: no $name\usr\bin\bash.exe" }
        Set-Content -Path $marker -Value (Get-Date -Format o)
    } else {
        Write-Step "MSYS2 snapshot $name already extracted"
    }
} else {
    $msys = Join-Path $Root 'msys64'
    $marker = Join-Path $msys '.olga-base'
    if (-not (Test-Path $marker)) {
        Write-Step 'MSYS2 base (rolling)'
        $sfx = Join-Path $dl 'msys2-base-x86_64-latest.sfx.exe'
        Get-File 'https://repo.msys2.org/distrib/msys2-base-x86_64-latest.sfx.exe' $sfx
        if (Test-Path $msys) { Remove-Item -Recurse -Force $msys }
        & $sfx -y "-o$Root\" | Select-Object -Last 3
        if (-not (Test-Path (Join-Path $msys 'usr\bin\bash.exe'))) { throw 'MSYS2 base extraction failed' }
        Invoke-Msys $msys 'true'                                   # first-run init (keyring etc.)
        Invoke-Msys $msys 'pacman -Syuu --noconfirm || true'       # core update, may end the shell
        Invoke-Msys $msys 'pacman -Syuu --noconfirm'
        Set-Content -Path $marker -Value (Get-Date -Format o)
    }
    $depsMarker = Join-Path $msys '.olga-inkscape-deps'
    if (-not (Test-Path $depsMarker)) {
        if (-not $InkscapeSrc) { $InkscapeSrc = Join-Path $Root 'src\inkscape' }
        $script = Join-Path $InkscapeSrc 'buildtools\msys2installdeps.sh'
        if (-not (Test-Path $script)) { throw "need the Inkscape source first ($script)" }
        Write-Step 'Inkscape deps via upstream msys2installdeps.sh (GraphicsMagick source build stripped)'
        # Upstream ends with a from-source GraphicsMagick build (only for raster extension tests);
        # drop that block, use packaged tools instead.
        $m = ConvertTo-MsysPath $script
        Invoke-Msys $msys "sed '/^(/,/^)/d' '$m' > /tmp/olga-installdeps.sh && bash /tmp/olga-installdeps.sh"
        Invoke-Msys $msys 'pacman -S --needed --noconfirm p7zip mingw-w64-ucrt-x86_64-nsis'
        Set-Content -Path $depsMarker -Value (Get-Date -Format o)
    }
}

Set-Content -Path (Join-Path $Root 'msys-root.txt') -Value $msys
Write-Step "MSYS2 ready: $msys"
Invoke-Msys $msys 'echo "MSYSTEM=$MSYSTEM"; gcc --version | head -1; cmake --version | head -1; ninja --version'
