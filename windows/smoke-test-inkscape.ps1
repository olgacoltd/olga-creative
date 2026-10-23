<#
.SYNOPSIS
  Headless smoke test of the built Inkscape-based app (no GUI is opened).
  Results land in <Root>\smoke\ : version.txt, dirs.txt, cjk.svg, cjk.pdf, cjk.png, result.json
  (check the PDF for live text on another machine, e.g. tools\check-pdf-text.py with pypdfium2).
#>
param([string]$Root = 'C:\olga-build')
. "$PSScriptRoot\common.ps1"
# PS 5.1: with Stop, redirecting a native program's stderr (2>&1 / 2>$null) throws NativeCommandError
$ErrorActionPreference = 'Continue'
$ink = (Get-Brand).inkscape
$prefix = Join-Path $Root "build\inkscape\$($ink.id)"
$com = Join-Path $prefix "bin\$($ink.id).com"
if (-not (Test-Path $com)) { throw "not built: $com" }
$out = Join-Path $Root 'smoke'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
Ensure-Dir $out
Write-Step "smoke test: $com"

# Run the app with stdout/stderr going to files (PowerShell 5.1 would wrap stderr lines into error records)
function Invoke-App([string]$tag, [string[]]$argv) {
    $o = Join-Path $out "$tag.out.txt"; $e = Join-Path $out "$tag.err.txt"
    $quoted = $argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $p = Start-Process -FilePath $com -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $o -RedirectStandardError $e
    $script:lastRc = $p.ExitCode
    return ([IO.File]::ReadAllText($o)).Trim()
}

$version = (Invoke-App 'version' @('--version')) -split "`n" | Where-Object { $_ -like "$($ink.name) *" } | Select-Object -First 1
if (-not $version) { $version = (Get-Content (Join-Path $out 'version.out.txt') -Raw) }
Set-Content -Path (Join-Path $out 'version.txt') -Value $version -Encoding UTF8
Write-Output "  --version: $version"
$userDir = Invoke-App 'userdir' @('--user-data-directory')
$sysDir = Invoke-App 'sysdir' @('--system-data-directory')
Set-Content -Path (Join-Path $out 'dirs.txt') -Value "user=$userDir`nsystem=$sysDir" -Encoding UTF8
Write-Output "  profile: $userDir"

# Traditional Chinese test text as XML character references, so this file stays ASCII (PowerShell 5.1)
# U+5411 U+91CF U+8A2D U+8A08 U+6E2C U+8A66 = "vector design test"
$svg = @'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="160" viewBox="0 0 400 160">
  <rect width="400" height="160" fill="#ffffff"/>
  <rect x="10" y="10" width="380" height="140" rx="12" fill="#1e3a5f"/>
  <text x="200" y="75" font-family="Microsoft JhengHei" font-size="40" fill="#ffffff" text-anchor="middle">&#x5411;&#x91CF;&#x8A2D;&#x8A08;&#x6E2C;&#x8A66;</text>
  <text x="200" y="120" font-family="Segoe UI" font-size="22" fill="#f0b44c" text-anchor="middle">OlgaDraw smoke test 123</text>
</svg>
'@
$svgPath = Join-Path $out 'cjk.svg'
[IO.File]::WriteAllText($svgPath, $svg, (New-Object Text.UTF8Encoding($false)))

$pdf = Join-Path $out 'cjk.pdf'
$png = Join-Path $out 'cjk.png'
[void](Invoke-App 'export-pdf' @($svgPath, '--export-type=pdf', "--export-filename=$pdf"))
$pdfRc = $lastRc
[void](Invoke-App 'export-png' @($svgPath, '--export-type=png', '--export-dpi=96', "--export-filename=$png"))
$pngRc = $lastRc

function SizeOf($f) { if (Test-Path $f) { return (Get-Item $f).Length } else { return 0 } }
$res = [ordered]@{
    version     = $version
    profileDir  = $userDir
    pdfRc       = $pdfRc
    pdfBytes    = (SizeOf $pdf)
    pngRc       = $pngRc
    pngBytes    = (SizeOf $png)
    exeName     = (Split-Path -Leaf $com)
    brandInVersion = ($version -like "$($ink.name) *")
}
($res | ConvertTo-Json) | Set-Content -Path (Join-Path $out 'result.json') -Encoding UTF8
$res.GetEnumerator() | ForEach-Object { Write-Output ("  {0} = {1}" -f $_.Key, $_.Value) }
if ($res.pdfBytes -le 0 -or $res.pngBytes -le 0 -or -not $res.brandInVersion) { throw 'smoke test FAILED' }
Write-Step 'smoke test passed (PDF live-text check: run tools\check-pdf-text.py on the copied cjk.pdf)'
