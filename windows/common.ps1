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

function Ensure-Dir([string]$p) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
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
    $part = "$dest.part"
    Write-Output "  downloading $url"
    # curl.exe ships with Windows 10+; -C - resumes a partial download after a dropped connection
    & curl.exe -sS -L --fail --retry 5 --retry-delay 10 -C - -o $part $url
    if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE): $url" }
    if ($expectedSize -gt 0 -and (Get-Item $part).Length -ne $expectedSize) {
        throw "size mismatch for $url"
    }
    Move-Item -Force $part $dest
}

# Path of the MSYS2 tree chosen by setup-msys2.ps1 (recorded in <root>\msys-root.txt)
function Get-MsysRoot([string]$Root) {
    $f = Join-Path $Root 'msys-root.txt'
    if (-not (Test-Path $f)) { throw "MSYS2 not set up yet: run windows\setup-msys2.ps1 -Root $Root" }
    return (Get-Content $f -TotalCount 1).Trim()
}

# Run a bash command inside the UCRT64 environment. $cwd is a Windows path.
function Invoke-Msys([string]$MsysRoot, [string]$cmd, [string]$cwd = $null) {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    $env:MSYS2_PATH_TYPE = 'minimal'    # do not inherit Git-for-Windows / other tools from PATH
    $bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
    # PowerShell 5.1 does not escape embedded double quotes when it passes arguments to native programs,
    # so the command never goes on the command line: it is written to a script under the MSYS2 /tmp.
    $tmpDir = Join-Path $MsysRoot 'tmp'
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }
    $name = 'olga-' + [Guid]::NewGuid().ToString('N') + '.sh'
    $file = Join-Path $tmpDir $name
    [IO.File]::WriteAllText($file, "set -e`n" + $cmd.Replace("`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    $old = Get-Location
    try {
        if ($cwd) { Set-Location $cwd }
        & $bash -l "/tmp/$name"
        $rc = $LASTEXITCODE
    } finally {
        Set-Location $old
        Remove-Item -Force $file -ErrorAction SilentlyContinue
    }
    if ($rc -ne 0) { throw "msys command failed (rc=$rc): $cmd" }
}

function ConvertTo-MsysPath([string]$p) {
    $full = [IO.Path]::GetFullPath($p)
    $drive = $full.Substring(0, 1).ToLower()
    return '/' + $drive + $full.Substring(2).Replace('\', '/')
}
