<#
.SYNOPSIS
  Non-admin, idempotent MSYS2 (UCRT64) toolchain for building Inkscape.

.DESCRIPTION
  Two modes:
    idw      (default) Upstream Inkscape CI's own frozen MSYS2 snapshot ("inkscape-ci-windows", the IDW_VERSION
             pinned in the tag's .gitlab-ci.yml). Exactly the package set the tag is known to build with,
             so a rolling MSYS2 update cannot break a release-tag build. ~570 MB download.
    rolling  Fresh MSYS2 base + `pacman -Syuu` + upstream buildtools/msys2installdeps.sh (needs the source
             tree already cloned, see build-inkscape.ps1 -SkipBuild). Use for newer Inkscape tags.
    gimp     Separate tree <Root>\msys64-gimp: fresh MSYS2 base + `pacman -Syuu`, CLANG64 environment, exactly
             like upstream GIMP CI (it has no frozen snapshot; it updates MSYS2 on every run). Without
             -GimpSrc only the base + git is installed (enough to clone); with -GimpSrc the package list from
             the tag's build/windows/all-deps-uni.txt is installed (re-run when that list changes).
             The installed package versions are written to <Root>\msys64-gimp\olga-packages.txt.

  Everything lands under -Root. Safe to re-run: finished steps are skipped (marker files), downloads resume.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\setup-msys2.ps1 -Root C:\olga-build
#>
param(
    [string]$Root = 'C:\olga-build',
    [ValidateSet('idw', 'rolling', 'gimp')] [string]$Mode = 'idw',
    [int]$IdwVersion = 168,
    [string]$InkscapeSrc = '',     # rolling mode: path of the inkscape checkout (for msys2installdeps.sh)
    [string]$GimpSrc = '',         # gimp mode: path of the gimp checkout (for build/windows/all-deps-uni.txt)
    [string]$MsysBase = '20260927', # rolling/gimp: dated MSYS2 base archive (distrib/x86_64); pacman updates it
    [string]$Mirror = ''            # gimp mode: MSYS2 mirror tried first (base URL from the official mirror list,
                                    # e.g. https://<host>/msys2); empty = MSYS2's own mirror order
)
. "$PSScriptRoot\common.ps1"

# gimp mode: put -Mirror first in every pacman mirror list and download through curl with the same rate cap
# as Get-File (pacman's own downloader cannot be capped). Idempotent; re-applied on every run because a
# pacman-mirrors update may rewrite the lists.
#   pacman has no inline comments, so each injected line is preceded by a marker comment line.
function Remove-OlgaLines([string[]]$lines, [string]$marker) {
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($skip) { $skip = $false; continue }
        if ($l -eq $marker) { $skip = $true; continue }
        $out.Add($l)
    }
    return , $out.ToArray()
}
function Set-PacmanDownloads([string]$msys) {
    $nl = "`n"
    $utf8 = New-Object Text.UTF8Encoding($false)
    $mMark = '# olga-mirror: the next line was added by setup-msys2.ps1 -Mirror'
    foreach ($f in @(Get-ChildItem (Join-Path $msys 'etc\pacman.d') -Filter 'mirrorlist*' | Where-Object { $_.Name -notmatch '\.pac(new|save)$' })) {
        $lines = Remove-OlgaLines ([IO.File]::ReadAllLines($f.FullName)) $mMark
        if ($Mirror) {
            $first = $lines | Where-Object { $_ -match '^\s*Server\s*=\s*https?://' } | Select-Object -First 1
            if ($first) {
                $mine = $first -replace '^\s*Server\s*=\s*https?://[^/]+(/msys2)?/', "Server = $($Mirror.TrimEnd('/'))/"
                $lines = @($mMark, $mine) + $lines
            }
        }
        [IO.File]::WriteAllText($f.FullName, ($lines -join $nl) + $nl, $utf8)
    }
    $conf = Join-Path $msys 'etc\pacman.conf'
    $xMark = '# olga-xfer: the next line was added by setup-msys2.ps1 (download rate cap, OLGA_DOWNLOAD_RATE)'
    $rate = Get-DownloadRate
    $lines = Remove-OlgaLines ([IO.File]::ReadAllLines($conf)) $xMark
    if ($rate -and (Test-Path (Join-Path $msys 'usr\bin\curl.exe'))) {
        $out = @()
        foreach ($l in $lines) {
            $out += $l
            if ($l -match '^\[options\]') {
                $out += $xMark
                $out += "XferCommand = /usr/bin/curl -L -C - -f --retry 5 --retry-delay 5 --limit-rate $rate -o %o %u"
            }
        }
        $lines = $out
    }
    [IO.File]::WriteAllText($conf, ($lines -join $nl) + $nl, $utf8)
}

Ensure-Dir $Root
$dl = Join-Path $Root 'downloads'
$tools = Join-Path $Root 'tools'
Ensure-Dir $dl; Ensure-Dir $tools

# 7zr.exe: the standalone 7-Zip console extractor (.7z only), no install needed
$sevenZ = Join-Path $tools '7zr.exe'
Get-File 'https://www.7-zip.org/a/7zr.exe' $sevenZ

if ($Mode -eq 'gimp') {
    $msys = Join-Path $Root 'msys64-gimp'
    $marker = Join-Path $msys '.olga-base'
    if (-not (Test-Path $marker)) {
        Write-Step 'MSYS2 base for GIMP (CLANG64, rolling like upstream GIMP CI)'
        $sfx = Join-Path $dl "msys2-base-x86_64-$MsysBase.sfx.exe"
        $distrib = 'https://repo.msys2.org'
        if ($Mirror) { $distrib = $Mirror.TrimEnd('/') }
        Get-File "$distrib/distrib/x86_64/msys2-base-x86_64-$MsysBase.sfx.exe" $sfx
        # the archive always unpacks to <dir>\msys64; unpack beside the target and rename
        $tmp = Join-Path $Root '_msys-extract'
        foreach ($d in @($tmp, $msys)) { Remove-Tree $d }
        Ensure-Dir $tmp
        & $sfx -y "-o$tmp\" | Select-Object -Last 3
        if (-not (Test-Path (Join-Path $tmp 'msys64\usr\bin\bash.exe'))) { throw 'MSYS2 base extraction failed' }
        Move-Item (Join-Path $tmp 'msys64') $msys
        Remove-Item -Recurse -Force $tmp
        Set-PacmanDownloads $msys
        Invoke-Msys $msys 'true' $null 'CLANG64'                                  # first-run init (keyring etc.)
        Invoke-Msys $msys 'pacman -Syuu --noconfirm || true' $null 'CLANG64'      # core update, may end the shell
        Invoke-Msys $msys 'pacman -Syuu --noconfirm' $null 'CLANG64'
        Invoke-Msys $msys 'pacman -S --needed --noconfirm git' $null 'CLANG64'
        Set-Content -Path $marker -Value (Get-Date -Format o)
    } else {
        Write-Step 'MSYS2 base for GIMP already installed'
    }
    Set-PacmanDownloads $msys
    # a pacman killed mid-run (e.g. the job was stopped) leaves its lock behind
    $lck = Join-Path $msys 'var\lib\pacman\db.lck'
    if (Test-Path $lck) {
        $running = @(Get-Process pacman -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($msys, [StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -eq 0) { Write-Output '  removing a stale pacman lock'; Remove-Item -Force $lck }
    }
    if ($GimpSrc) {
        $list = Join-Path $GimpSrc 'build\windows\all-deps-uni.txt'
        if (-not (Test-Path $list)) { throw "need the GIMP source first ($list)" }
        # Same parsing as upstream build/windows/1_build-deps-msys2.ps1: MINGW_ lines, minus comments and the
        # |vcpkg: alternative, prefix -> clang x86_64. Plus what this pipeline itself needs.
        $pkgs = @(Get-Content $list | Where-Object { $_ -match 'MINGW_' -and -not $_.Trim().StartsWith('#') } |
            ForEach-Object { (($_.Split('#')[0].Trim() -split '\|vcpkg:')[0]) -replace '\$\{MINGW_PACKAGE_PREFIX\}', 'mingw-w64-clang-x86_64' })
        $pkgs += @('mingw-w64-clang-x86_64-ccache', 'mingw-w64-clang-x86_64-python-pillow', 'patch')
        $want = ($pkgs | Sort-Object -Unique) -join ' '
        $depsMarker = Join-Path $msys '.olga-gimp-deps'
        $have = ''
        if (Test-Path $depsMarker) { $have = (Get-Content $depsMarker -Raw).Trim() }
        if ($have -ne $want) {
            Write-Step "GIMP deps: $($pkgs.Count) packages from all-deps-uni.txt"
            # Pre-fetch the package files with parallel connections (much faster than pacman's capped
            # one-at-a-time XferCommand on a lossy line), the whole still capped at the download rate;
            # resumable; only complete files are moved into pacman's cache, which then installs offline.
            $rate = Get-DownloadRate
            $per = ''
            if ($rate) { $per = "--limit-rate $([long]((([double]($rate -replace '[^0-9.]', '')) * @{ K = 1KB; M = 1MB; G = 1GB }[($rate -replace '[0-9.]', '').ToUpper()]) / 10))" }
            $prefetch = @"
mkdir -p /var/cache/pacman/olga-dl && cd /var/cache/pacman/olga-dl
pacman -Sp --needed --noconfirm $want | grep -E '^https?://' > urls.txt || true
echo "prefetch: `$(wc -l < urls.txt) package files"
for try in 1 2 3 4 5 6 7 8; do
  : > todo.txt
  while read -r u; do f=`$(basename "`$u"); [ -f "/var/cache/pacman/pkg/`$f" ] || echo "`$u" >> todo.txt; done < urls.txt
  [ -s todo.txt ] || break
  echo "prefetch attempt `$try: `$(wc -l < todo.txt) to go"
  xargs -n 1 -P 10 sh -c 'f=`$(basename "`$0"); curl -sS -L -f --retry 5 --retry-delay 5 --speed-limit 1024 --speed-time 120 $per -C - -o "`$f.part" "`$0" && mv -f "`$f.part" "/var/cache/pacman/pkg/`$f"' < todo.txt || true
done
"@
            Invoke-Msys $msys $prefetch $null 'CLANG64'
            Invoke-Msys $msys "pacman -S --needed --noconfirm $want" $null 'CLANG64'
            Set-Content -Path $depsMarker -Value $want
        } else {
            Write-Step 'GIMP deps already installed'
        }
        Invoke-Msys $msys "pacman -Q > /olga-packages.txt" $null 'CLANG64'
    }
    Set-Content -Path (Join-Path $Root 'msys-root-gimp.txt') -Value $msys
    Write-Step "MSYS2 (GIMP) ready: $msys"
    Invoke-Msys $msys 'echo "MSYSTEM=$MSYSTEM"; (cc --version || clang --version) 2>/dev/null | head -1; command -v meson ninja git || true' $null 'CLANG64'
    return
}

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
        $sfx = Join-Path $dl "msys2-base-x86_64-$MsysBase.sfx.exe"
        Get-File "https://repo.msys2.org/distrib/x86_64/msys2-base-x86_64-$MsysBase.sfx.exe" $sfx
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
