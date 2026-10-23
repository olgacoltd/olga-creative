# Shared helpers for the Windows build scripts. Dot-source it: . "$PSScriptRoot\common.ps1"
# PowerShell 5.1 compatible (no ?? / ?. operators).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is 10x slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRoot = Split-Path -Parent $PSScriptRoot

# The build must never disturb the person using the machine: every script that dot-sources this file
# drops itself (and therefore every child: bash, ninja, gcc, 7zr, curl) to Idle priority.
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::Idle } catch { }

# Default parallelism leaves 2 hardware threads free for the user (override with -Jobs).
function Get-DefaultJobs { return [Math]::Max(1, [Environment]::ProcessorCount - 2) }

function Write-Step([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$ts] === $msg"
}

function Get-Brand {
    $p = Join-Path $RepoRoot 'brand.json'
    # Read as UTF-8 explicitly (PS 5.1 Get-Content defaults to the ANSI code page)
    $txt = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    return ($txt | ConvertFrom-Json)
}

# Remove a directory tree; retries because files of a process that just ended can stay locked for a moment.
function Remove-Tree([string]$p) {
    for ($i = 1; (Test-Path $p); $i++) {
        try { Remove-Item -Recurse -Force $p -ErrorAction Stop } catch {
            if ($i -ge 6) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

function Ensure-Dir([string]$p) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
}

# Download rate cap so a build never saturates the user's internet line: env OLGA_DOWNLOAD_RATE
# (curl syntax, e.g. 2M or 500K; 0 = no cap), default 2M. Used by Get-File and by pacman (setup-msys2.ps1).
function Get-DownloadRate {
    $r = $env:OLGA_DOWNLOAD_RATE
    if (-not $r) { $r = '2M' }
    if ($r -eq '0') { return '' }
    return $r
}

# Big files: download in parallel byte ranges (several connections get much further than one on a lossy
# line), each range resumable, the whole capped at Get-DownloadRate. Sets $script:OlgaSegmented to $false when
# the server does not report a size or does not support ranges (the caller then uses one connection).
function Get-FileSegmented([string]$url, [string]$dest, [int]$segments = 6) {
    $ErrorActionPreference = 'Continue'
    $head = & curl.exe -sSIL --retry 5 --retry-delay 5 $url 2>$null
    $ErrorActionPreference = 'Stop'
    $len = 0L; $ranges = $false
    foreach ($l in $head) {
        if ($l -match '^HTTP/') { $len = 0L; $ranges = $false }      # keep only the final response of redirects
        if ($l -match '^content-length:\s*(\d+)') { $len = [long]$Matches[1] }
        if ($l -match '^accept-ranges:\s*bytes') { $ranges = $true }
    }
    $script:OlgaSegmented = $false
    if ($len -lt 8MB -or -not $ranges) { return }
    $rate = Get-DownloadRate
    $limit = @()
    if ($rate) {
        $num = [double]($rate -replace '[^0-9.]', '')
        $unit = ($rate -replace '[0-9.]', '').ToUpper()
        $bytes = switch ($unit) { 'K' { $num * 1KB } 'M' { $num * 1MB } 'G' { $num * 1GB } default { $num } }
        $limit = @('--limit-rate', [string][long]([Math]::Max(16KB, $bytes / $segments)))
    }
    $size = [long][Math]::Ceiling($len / $segments)
    # a plain single-connection .part from an earlier run is the start of segment 0
    if ((Test-Path "$dest.part") -and -not (Test-Path "$dest.seg0")) { Move-Item "$dest.part" "$dest.seg0" }
    Write-Output ("  downloading {0} ({1:N1} MB in {2} parallel ranges)" -f $url, ($len / 1MB), $segments)
    for ($try = 1; $try -le 20; $try++) {
        $procs = @()
        for ($i = 0; $i -lt $segments; $i++) {
            $a = $i * $size; $b = [Math]::Min($len, $a + $size) - 1
            $seg = "$dest.seg$i"
            $have = 0L; if (Test-Path $seg) { $have = (Get-Item $seg).Length }
            if ($have -gt ($b - $a + 1)) {
                # e.g. a single-connection .part longer than one range: keep the range's share
                $fs = [IO.File]::Open($seg, [IO.FileMode]::Open); try { $fs.SetLength($b - $a + 1) } finally { $fs.Dispose() }
                $have = $b - $a + 1
            }
            if ($have -eq ($b - $a + 1)) { continue }
            $cargs = @('-sS', '-L', '--fail', '--retry', '10', '--retry-delay', '5', '--speed-limit', '1024', '--speed-time', '120') + $limit +
                @('-r', "$($a + $have)-$b", '-o', "`"$seg.tmp`"", "`"$url`"")
            if (Test-Path "$seg.tmp") { Remove-Item -Force "$seg.tmp" }
            $procs += [pscustomobject]@{ seg = $seg; p = (Start-Process -FilePath curl.exe -ArgumentList $cargs -NoNewWindow -PassThru) }
        }
        foreach ($x in $procs) {
            $x.p.WaitForExit()
            if (Test-Path "$($x.seg).tmp") {
                # append what this attempt fetched to the segment (resume = keep every byte already received)
                $o = [IO.File]::Open($x.seg, [IO.FileMode]::Append)
                try { $in = [IO.File]::OpenRead("$($x.seg).tmp"); try { $in.CopyTo($o) } finally { $in.Dispose() } } finally { $o.Dispose() }
                Remove-Item -Force "$($x.seg).tmp"
            }
        }
        $done = $true
        for ($i = 0; $i -lt $segments; $i++) {
            $a = $i * $size; $b = [Math]::Min($len, $a + $size) - 1
            $seg = "$dest.seg$i"
            if (-not (Test-Path $seg) -or (Get-Item $seg).Length -ne ($b - $a + 1)) { $done = $false }
        }
        if ($done) { break }
        Write-Output "  ranges incomplete after attempt $try, resuming"
    }
    if (-not $done) { throw "download failed: $url" }
    $o = [IO.File]::Create("$dest.part")
    try {
        for ($i = 0; $i -lt $segments; $i++) { $in = [IO.File]::OpenRead("$dest.seg$i"); try { $in.CopyTo($o) } finally { $in.Dispose() } }
    } finally { $o.Dispose() }
    if ((Get-Item "$dest.part").Length -ne $len) { throw "size mismatch after joining ranges: $url" }
    for ($i = 0; $i -lt $segments; $i++) { Remove-Item -Force "$dest.seg$i" }
    Move-Item -Force "$dest.part" $dest
    $script:OlgaSegmented = $true
}

# Download with resume-by-restart semantics: write to .part, rename when complete.
function Get-File([string]$url, [string]$dest, [long]$expectedSize = 0) {
    if (Test-Path $dest) {
        if ($expectedSize -le 0 -or (Get-Item $dest).Length -eq $expectedSize) {
            Write-Output "  have $dest"
            return
        }
        Remove-Item -Force $dest
    }
    Ensure-Dir (Split-Path -Parent $dest)
    Get-FileSegmented $url $dest
    if ($script:OlgaSegmented) { return }
    $part = "$dest.part"
    Write-Output "  downloading $url"
    # curl.exe ships with Windows 10+; -C - resumes a partial download after a dropped connection
    $limit = @()
    $rate = Get-DownloadRate
    if ($rate) { $limit = @('--limit-rate', $rate) }
    & curl.exe -sS -L --fail --retry 5 --retry-delay 10 -C - @limit -o $part $url
    if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE): $url" }
    if ($expectedSize -gt 0 -and (Get-Item $part).Length -ne $expectedSize) {
        throw "size mismatch for $url"
    }
    Move-Item -Force $part $dest
}

# Check a downloaded file against a pinned SHA-256; a mismatching (e.g. truncated) file is deleted so the
# next run downloads it again.
function Assert-Sha256([string]$file, [string]$expected) {
    if (-not $expected) { return }
    $h = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
    if ($h -ne $expected.ToLower()) {
        Remove-Item -Force $file
        throw "SHA-256 mismatch for $file (got $h, want $expected); deleted, re-run to download again"
    }
    Write-Output "  sha256 ok: $(Split-Path -Leaf $file)"
}

# Path of the MSYS2 tree chosen by setup-msys2.ps1 (recorded in <root>\msys-root.txt; the GIMP toolchain,
# a separate tree, in <root>\msys-root-gimp.txt)
function Get-MsysRoot([string]$Root, [string]$Name = '') {
    $leaf = 'msys-root.txt'
    if ($Name) { $leaf = "msys-root-$Name.txt" }
    $f = Join-Path $Root $leaf
    if (-not (Test-Path $f)) { throw "MSYS2 not set up yet ($leaf): run windows\setup-msys2.ps1 -Root $Root" }
    return (Get-Content $f -TotalCount 1).Trim()
}

# Run a bash command inside an MSYS2 environment (UCRT64 by default; the GIMP build uses CLANG64 like
# upstream GIMP CI). $cwd is a Windows path.
function Invoke-Msys([string]$MsysRoot, [string]$cmd, [string]$cwd = $null, [string]$Msystem = 'UCRT64') {
    $env:MSYSTEM = $Msystem
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'minimal'    # do not inherit Git-for-Windows / other tools from PATH
    $bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
    # PowerShell 5.1 does not escape embedded double quotes when it passes arguments to native programs,
    # so the command never goes on the command line: it is written to a script under the MSYS2 /tmp.
    $tmpDir = Join-Path $MsysRoot 'tmp'
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }
    $name = 'olga-' + [Guid]::NewGuid().ToString('N') + '.sh'
    $file = Join-Path $tmpDir $name
    # stdin from /dev/null: a detached build (run-detached.ps1) has no valid stdin handle, and native Windows
    # programs that duplicate it (Python's subprocess, e.g. meson running cmake) fail with WinError 6
    [IO.File]::WriteAllText($file, "set -e`nexec </dev/null`n" + $cmd.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    $old = Get-Location
    try {
        if ($cwd) { Set-Location $cwd }
        & $bash -l "/tmp/$name"
        $rc = $LASTEXITCODE
    } finally {
        Set-Location $old
        Remove-Item -Force $file -ErrorAction SilentlyContinue
        $env:MSYSTEM = 'UCRT64'
    }
    if ($rc -ne 0) { throw "msys command failed (rc=$rc): $cmd" }
}

function ConvertTo-MsysPath([string]$p) {
    $full = [IO.Path]::GetFullPath($p)
    $drive = $full.Substring(0, 1).ToLower()
    return '/' + $drive + $full.Substring(2).Replace('\', '/')
}
