<#
.SYNOPSIS
  Build the Inno Setup installer for the GIMP-based app from the finished bundle (called by build-gimp.ps1).

.DESCRIPTION
  Same route as upstream build/windows/installer/3_dist-gimp-inno.ps1, without admin and without touching
  the machine: Inno Setup is installed in portable mode under <Root>\tools\innosetup-<ver> (no registry,
  no uninstaller, no shortcuts), the installer languages Inno does not ship are fetched from the same Inno
  release tag, and iscc compiles the branded build\windows\installer\gimp-setup.iss (patch 0005).
  The installer is per-user by default (upstream: PrivilegesRequired=lowest, admin install optional).
  Skipped from upstream: the cosmetic version-in-window-title patch of the language files (fix_msg.py).
#>
param(
    [string]$Root = 'C:\olga-build',
    [Parameter(Mandatory = $true)] [string]$Bundle,
    [Parameter(Mandatory = $true)] [string]$BuildDir,
    [Parameter(Mandatory = $true)] [string]$Source,
    [string]$InnoVersion = '7.1.0',
    [string]$InnoSha256 = ''
)
. "$PSScriptRoot\common.ps1"
$g = (Get-Brand).gimp
$dl = Join-Path $Root 'downloads'
$innoTag = 'is-' + $InnoVersion.Replace('.', '_')

# 1. Inno Setup, portable, under the build root
$inno = Join-Path $Root "tools\innosetup-$InnoVersion"
$iscc = Join-Path $inno 'ISCC.exe'
if (-not (Test-Path $iscc)) {
    Write-Step "Inno Setup $InnoVersion (portable install under $inno)"
    $setup = Join-Path $dl "innosetup-$InnoVersion-x86.exe"
    Get-File "https://github.com/jrsoftware/issrc/releases/download/$innoTag/innosetup-$InnoVersion-x86.exe" $setup
    Assert-Sha256 $setup $InnoSha256
    $p = Start-Process -FilePath $setup -Wait -PassThru -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        '/CURRENTUSER', '/PORTABLE=1', '/NOICONS', "/DIR=`"$inno`"", "/LOG=`"$(Join-Path $Root 'logs\innosetup-install.log')`"")
    if ($p.ExitCode -ne 0 -or -not (Test-Path $iscc)) { throw "Inno Setup install failed (rc $($p.ExitCode)), see logs\innosetup-install.log" }
}

# 2. installer languages that Inno does not ship (upstream fetches them from the issrc repository)
$xml = New-Object XML
$xml.Load((Join-Path $Source 'build\windows\installer\lang\iso_639_custom.xml'))
$codes = @($xml.iso_639_entries.iso_639_entry | ForEach-Object { $_.inno_code } | Where-Object { $_ -like '*Languages*' } | Sort-Object -Unique)
$fetched = 0
foreach ($c in $codes) {
    $rel = $c.Replace('\\', '\')
    $dest = Join-Path $inno $rel
    if (Test-Path $dest) { continue }
    $cache = Join-Path $dl "inno-$InnoVersion-langs\$rel"
    Get-File ("https://raw.githubusercontent.com/jrsoftware/issrc/$innoTag/Files/" + $rel.Replace('\', '/')) $cache | Out-Null
    Ensure-Dir (Split-Path -Parent $dest)
    Copy-Item $cache $dest
    $fetched++
}
Write-Output "  languages: $($codes.Count) ($fetched fetched)"

# 3. config.h without C comments (ISPP reads its #defines), like upstream
$cfg = Join-Path $BuildDir 'config.h'
$clean = Join-Path $BuildDir 'config_clean.h'
$txt = [IO.File]::ReadAllText($cfg)
[IO.File]::WriteAllText($clean, [regex]::Replace($txt, '/\*[\s\S]*?\*/', ''), (New-Object Text.UTF8Encoding($false)))

# 4. compile (output lands in the source root, as upstream)
Write-Step 'package: Inno Setup installer'
$log = Join-Path $Root 'logs\iscc.log'
$ErrorActionPreference = 'Continue'
Push-Location $Source
try {
    & $iscc "-DREVISION=0" "-DBUILD_DIR=$BuildDir" "-DX64_BUNDLE=$Bundle" '-DPYTHON' 'build\windows\installer\gimp-setup.iss' > $log 2>&1
    $rc = $LASTEXITCODE
} finally { Pop-Location; $ErrorActionPreference = 'Stop' }
if ($rc -ne 0) { Get-Content $log -Tail 30; throw "iscc failed (rc $rc), see $log" }
$exe = Get-ChildItem $Source -Filter "$($g.id)-*-setup.exe" | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $exe) { throw 'iscc produced no installer' }
$dist = Join-Path $Root 'dist'
Ensure-Dir $dist
Move-Item -Force $exe.FullName (Join-Path $dist $exe.Name)
Write-Output ("  {0} ({1:N0} MB)" -f $exe.Name, ((Get-Item (Join-Path $dist $exe.Name)).Length / 1MB))
