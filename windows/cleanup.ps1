<#
.SYNOPSIS
  Remove everything the build pipeline put on a build machine. Nothing else is touched.

  Removes: the build root (MSYS2, sources, build dirs, ccache, downloads, logs, dist), the per-user
  profile/cache folders the smoke test created for the branded apps, the MSYS2 home of this user inside
  the build root (already covered) and any OlgaBuild-* scheduled task run-detached.ps1 may have created.
  Stops build processes started from the build root first.

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
}

# 1. stop processes running from the build root (bash, ninja, gcc, the app smoke test ...)
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($full, [StringComparison]::OrdinalIgnoreCase) })
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

# 4. the build root itself (MSYS2 can leave read-only files; -Force handles them)
if ($PSCmdlet.ShouldProcess($full, 'Remove-Item -Recurse')) {
    Remove-Item -Recurse -Force $full -ErrorAction SilentlyContinue
    if (Test-Path $full) {
        # long paths / stubborn files: fall back to robocopy-mirror of an empty dir
        $empty = Join-Path $env:TEMP ('olga-empty-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty | Out-Null
        robocopy $empty $full /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        Remove-Item -Recurse -Force $full, $empty -ErrorAction SilentlyContinue
    }
    if (Test-Path $full) { Write-Output "WARNING: some files remain in $full" } else { Write-Output "removed $full" }
}
