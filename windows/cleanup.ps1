<#
.SYNOPSIS
  Remove everything the build pipeline put on a build machine. Nothing else is touched.

  Removes: the pipeline's folders in the build root (MSYS2 trees, sources, build dirs, ccache, downloads,
  logs, dist, smoke tests, the repo copy), the per-user profile/cache folders the smoke tests created for
  the branded apps and any OlgaBuild-* scheduled task run-detached.ps1 may have created. Stops build
  processes started from those folders first. Anything else in the build root (e.g. another project's
  folder) is left alone, and the root itself is removed only when it ends up empty.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\olga-build\olga-creative\windows\cleanup.ps1 -Root C:\olga-build -WhatIf
  powershell -ExecutionPolicy Bypass -File C:\olga-build\olga-creative\windows\cleanup.ps1 -Root C:\olga-build
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$Root = 'C:\olga-build')
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $Root)) { Write-Output "nothing to do: $Root does not exist"; exit 0 }
$full = (Resolve-Path $Root).Path.TrimEnd('\')
if ($full.Length -lt 6 -or $full -match '^[A-Za-z]:$' -or $full -match '\\(Windows|Users|Program Files)') {
    throw "refusing to delete suspicious root: $full"
}

# brand ids, so the per-user profile folders of the branded apps can be removed too
$ids = @()
$brandFile = Join-Path $full 'olga-creative\brand.json'
if (Test-Path $brandFile) {
    $b = [IO.File]::ReadAllText($brandFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($k in 'inkscape', 'gimp') { if ($b.$k -and $b.$k.id) { $ids += $b.$k.id } }
    # the GIMP-based app keeps its profile in %APPDATA%\<nameAscii> (meson -Dgimpdir), same for its cache
    if ($b.gimp -and $b.gimp.nameAscii) { $ids += $b.gimp.nameAscii }
}

# Only what this pipeline creates is touched: other folders in the same root (another project's work) and
# their processes are left alone, and the root itself is removed only when nothing else is left in it.
$ours = @('olga-creative', 'ink168', 'msys64', 'msys64-gimp', '_msys-extract', 'src', 'build', 'ccache', 'downloads',
    'tools', 'logs', 'dist', 'smoke', 'smoke-gimp', 'msys-root.txt', 'msys-root-gimp.txt') |
    ForEach-Object { Join-Path $full $_ }

# 1. stop processes running from our folders (bash, ninja, gcc, the app smoke test ...)
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $pp = $_.Path
        $pp -and @($ours | Where-Object { $pp.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 })
foreach ($p in $procs) {
    if ($PSCmdlet.ShouldProcess("$($p.Name) (pid $($p.Id))", 'Stop-Process')) { Stop-Process -Id $p.Id -Force }
}
# the keep-awake wrapper is a powershell.exe whose pid is recorded in logs\*.pid
Get-ChildItem (Join-Path $full 'logs') -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object {
    $wpid = (Get-Content $_.FullName -TotalCount 1).Trim()
    if ($wpid -and (Get-Process -Id $wpid -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess("keep-awake wrapper pid $wpid", 'Stop-Process')) { Stop-Process -Id $wpid -Force }
    }
}

# 2. scheduled tasks created by run-detached.ps1 (only the ones with our prefix)
Get-ScheduledTask -TaskName 'OlgaBuild-*' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($PSCmdlet.ShouldProcess($_.TaskName, 'Unregister-ScheduledTask')) { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false }
}

# 3. per-user profile + cache folders of the branded apps (created by the smoke test)
foreach ($id in $ids) {
    foreach ($d in @((Join-Path $env:APPDATA $id), (Join-Path $env:LOCALAPPDATA $id))) {
        if (Test-Path $d) { if ($PSCmdlet.ShouldProcess($d, 'Remove-Item')) { Remove-Item -Recurse -Force $d } }
    }
}

# 4. our folders in the build root (MSYS2 can leave read-only files; -Force handles them), then the root
#    itself if nothing else is in it
foreach ($d in @($ours | Where-Object { Test-Path $_ })) {
    if ($PSCmdlet.ShouldProcess($d, 'Remove-Item -Recurse')) {
        Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
        if ((Test-Path $d) -and (Test-Path $d -PathType Container)) {
            # long paths / stubborn files: fall back to robocopy-mirror of an empty dir
            $empty = Join-Path $env:TEMP ('olga-empty-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            robocopy $empty $d /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
            Remove-Item -Recurse -Force $d, $empty -ErrorAction SilentlyContinue
        }
        if (Test-Path $d) { Write-Output "WARNING: some files remain in $d" } else { Write-Output "removed $d" }
    }
}
$left = @(Get-ChildItem -Force $full -ErrorAction SilentlyContinue)
if ($left.Count -eq 0) {
    if ($PSCmdlet.ShouldProcess($full, 'Remove-Item')) { Remove-Item -Force $full; Write-Output "removed $full" }
} else {
    Write-Output ("kept $full (other content: {0})" -f (($left | ForEach-Object { $_.Name }) -join ', '))
}
