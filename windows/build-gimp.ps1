<#
.SYNOPSIS
  Build the rebranded GIMP for Windows (MSYS2 CLANG64 + meson/ninja, upstream GIMP CI's own route) and package it.

.DESCRIPTION
  Resumable: every step checks what is already there, so re-running after a dropped connection, sleep or a
  failed step continues instead of starting over:
    1. MSYS2 toolchain      setup-msys2.ps1 -Mode gimp (base, then the tag's build/windows/all-deps-uni.txt)
    2. sources              official release tarballs (SHA-256 pinned): GIMP (includes gimp-data), babl, GEGL,
                            exiv2 (+ the patch upstream CI applies)
    3. babl, GEGL, exiv2    built and installed into <Root>\build\gimp\_install, like upstream 1_build-deps-msys2.ps1
    4. branding             branding\gimp\patches + apply-branding.py; re-applied only when a patch, the script,
                            the defaults, brand.json or the version changed (stamp file)
    5. configure            meson, only when build.ninja is missing or the branding changed
    6. compile              ninja (incremental; the build dir is kept)
    7. install + bundle     ninja install runs upstream's bundling script -> <Root>\build\gimp\<id>, then the
                            Resynthesizer plug-ins are built against it and added (with a zh_TW catalog for
                            their own gettext domain, resynthesizer-i18n.py), and the bundle-level artwork
                            (splash, About logo) is branded
    8. package              portable zip (+ Inno Setup installer, Inno unpacked per-user under <Root>\tools)
    9. smoke test           smoke-test-gimp.ps1 (console app only, no GUI)

  Run it detached on a remote box:  windows\run-detached.ps1 -Name gimp -Script build-gimp.ps1 -Root <root>

.PARAMETER Clean      Delete the GIMP build directory first (full recompile). Sources, deps and MSYS2 are kept.
.PARAMETER CleanDeps  Also rebuild babl, GEGL and exiv2.
.PARAMETER FetchOnly  Only download and verify the source tarballs (useful to pre-fetch on a slow line).
#>
param(
    [string]$Root = 'C:\olga-build',
    [string]$GimpVersion = '3.2.6',
    [string]$GimpSha256 = '40b15e90ad0c0c631b76da3c467ea9847fa5c24f37413ac5b492804860a28cd8',
    # babl / GEGL: the newest release tags when GIMP_3_2_6 was tagged (upstream CI builds the latest tag)
    [string]$BablVersion = '0.1.128',
    [string]$BablSha256 = 'e676507b421d414d49db8627415dc1eadbd787536baa7d6fe94a1f1971cbe73e',
    [string]$GeglVersion = '0.4.72',
    [string]$GeglSha256 = 'ccbb8cdd1db56ecd4ece5dbabae0118ab2c46b5b3439c94f3cec467798ce956d',
    # exiv2: the version upstream build/windows/1_build-deps-msys2.ps1 pins for this tag. Its source comes from
    # MSYS2's source package (it carries exiv2's own release tarball) because mirrors serve it with a size, so
    # it downloads in parallel ranges; GitHub's tag archive does not.
    [string]$Exiv2Version = '0.28.8',
    [string]$Exiv2MsysRel = '1',
    [string]$Exiv2Sha256 = '1599a4d6d4a4fd28038b845d1a677f028646d120130d72151ed23931cc707a36',
    # Resynthesizer (content-aware heal / fill plug-ins, GPL-3.0), the GIMP 3 line of github.com/bootchk/resynthesizer
    [string]$ResynthVersion = '3.0.1',
    [string]$ResynthSha256 = 'bc88ca6c36e15d518039a670b68ab1b7035ae2721ba2b51ca6174fe6527b9069',
    [string]$Mirror = '',            # MSYS2 mirror tried first (see setup-msys2.ps1)
    [int]$Jobs = 0,
    [switch]$Clean,
    [switch]$CleanDeps,
    [switch]$FetchOnly,
    [switch]$NoInstaller,
    [switch]$NoSmokeTest,
    [switch]$NoResynthesizer
)
. "$PSScriptRoot\common.ps1"
$t0 = Get-Date
$M = 'CLANG64'

# ---------------------------------------------------------------- brand
$brand = Get-Brand
$g = $brand.gimp
if ($g.id -notmatch '^[a-z][a-z0-9-]{1,30}$') { throw "brand.json gimp.id must be lower-case ascii: $($g.id)" }
if ($g.nameAscii -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$') { throw "brand.json gimp.nameAscii must be ascii without spaces: $($g.nameAscii)" }
if ($g.appId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') { throw "brand.json gimp.appId invalid: $($g.appId)" }
foreach ($v in @($g.name, $brand.vendor, $brand.url, $g.versionSuffix)) {
    if ($v -match "[`"'\\;`$``]") { throw "brand.json values may not contain quotes, backslash, semicolon, dollar or backtick: $v" }
}
Write-Step "brand: $($g.name) ($($g.id), $($g.appId)) from GIMP $GimpVersion"

$dl = Join-Path $Root 'downloads'
$srcParent = Join-Path $Root 'src'
$bRoot = Join-Path $Root 'build\gimp'
$prefix = Join-Path $bRoot '_install'          # babl, GEGL, exiv2 and GIMP are installed here (GIMP_PREFIX)
Ensure-Dir $dl; Ensure-Dir $srcParent; Ensure-Dir $bRoot

# ---------------------------------------------------------------- sources (tarballs)
$gimpMinor = ($GimpVersion -split '\.')[0..1] -join '.'
$msysRepo = 'https://repo.msys2.org'
if ($Mirror) { $msysRepo = $Mirror.TrimEnd('/') }
$tarballs = @(
    @{ name = 'gimp';  file = "gimp-$GimpVersion.tar.xz";  sha = $GimpSha256; url = "https://download.gimp.org/gimp/v$gimpMinor/gimp-$GimpVersion.tar.xz" },
    @{ name = 'babl';  file = "babl-$BablVersion.tar.xz";  sha = $BablSha256; url = "https://download.gimp.org/babl/$((($BablVersion -split '\.')[0..1]) -join '.')/babl-$BablVersion.tar.xz" },
    @{ name = 'gegl';  file = "gegl-$GeglVersion.tar.xz";  sha = $GeglSha256; url = "https://download.gimp.org/gegl/$((($GeglVersion -split '\.')[0..1]) -join '.')/gegl-$GeglVersion.tar.xz" },
    @{ name = 'exiv2'; file = "mingw-w64-exiv2-$Exiv2Version-$Exiv2MsysRel.src.tar.zst"; sha = $Exiv2Sha256; url = "$msysRepo/mingw/sources/mingw-w64-exiv2-$Exiv2Version-$Exiv2MsysRel.src.tar.zst" },
    @{ name = 'resynthesizer'; file = "resynthesizer-$ResynthVersion.tar.gz"; sha = $ResynthSha256; url = "https://github.com/bootchk/resynthesizer/archive/refs/tags/v$ResynthVersion.tar.gz" }
)
Write-Step 'sources: release tarballs'
foreach ($t in $tarballs) {
    $f = Join-Path $dl $t.file
    $okMark = "$f.sha256-ok"
    if ((Test-Path $okMark) -and (Test-Path $f)) { Write-Output "  have $($t.file) (verified)"; continue }
    Get-File $t.url $f
    if ($t.sha) { Assert-Sha256 $f $t.sha } else { Write-Output ("  sha256 (not pinned): {0} {1}" -f (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower(), $t.file) }
    Set-Content -Path $okMark -Value (Get-Date -Format o)
}
if ($FetchOnly) { Write-Step 'fetch only: done'; return }

# ---------------------------------------------------------------- 1. toolchain
$tcArgs = @{ Root = $Root; Mode = 'gimp' }
if ($Mirror) { $tcArgs.Mirror = $Mirror }
& "$PSScriptRoot\setup-msys2.ps1" @tcArgs

# GIMP source tree: extracted once from the tarball. A baseline git repository OUTSIDE the tree
# (<Root>\src\gimp-<ver>.git) lets the branding step return to pristine sources without touching
# unchanged files (so ninja only recompiles what a brand change touched). It must stay outside: GIMP's
# meson treats a tree with a .git folder as a developer checkout (git-version.h, submodule checks).
$src = Join-Path $srcParent "gimp-$GimpVersion"
$gitDir = Join-Path $srcParent "gimp-$GimpVersion.git"
$msys = Get-MsysRoot $Root 'gimp'
$s = ConvertTo-MsysPath $src
$gd = ConvertTo-MsysPath $gitDir
$gitEnv = "export GIT_DIR='$gd' GIT_WORK_TREE='$s'; git config --global --add safe.directory '*' 2>/dev/null || true; "
if (-not (Test-Path (Join-Path $gitDir '.olga-baseline'))) {
    Write-Step "source: extracting gimp-$GimpVersion.tar.xz"
    foreach ($d in @($src, $gitDir)) { Remove-Tree $d }
    Invoke-Msys $msys "cd '$(ConvertTo-MsysPath $srcParent)' && tar -xf '$(ConvertTo-MsysPath (Join-Path $dl "gimp-$GimpVersion.tar.xz"))'" $null $M
    if (-not (Test-Path (Join-Path $src 'gimp-data\meson.build'))) { throw "unexpected tarball layout (no gimp-data in $src)" }
    Invoke-Msys $msys ($gitEnv + "cd '$s' && git init -q && git -c core.autocrlf=false add -A -f && git -c user.name=olga -c user.email=olga@localhost commit -q -m pristine") $null $M
    Set-Content -Path (Join-Path $gitDir '.olga-baseline') -Value (Get-Date -Format o)
} else {
    Write-Step 'source: present'
}

# the tag's dependency list (same package set as upstream CI)
$tcArgs.GimpSrc = $src
& "$PSScriptRoot\setup-msys2.ps1" @tcArgs

# ---------------------------------------------------------------- shell environment for every build step
$p = ConvertTo-MsysPath $prefix
$ccacheDir = ConvertTo-MsysPath (Join-Path $Root 'ccache')
$envSh = @"
export PATH="$p/bin:`$PATH"
export PKG_CONFIG_PATH="$p/lib/pkgconfig:$p/share/pkgconfig"
export XDG_DATA_DIRS="$p/share:/clang64/share"
export GI_TYPELIB_PATH="$p/lib/girepository-1.0:/clang64/lib/girepository-1.0"
export CCACHE_DIR='$ccacheDir'
# upstream's Python build scripts open text files without an encoding: on a Chinese/Japanese Windows the
# locale code page (e.g. cp950) cannot read the UTF-8 meson log
export PYTHONUTF8=1
export MSYS_ROOT='$(([IO.Path]::GetFullPath($msys)).Replace('\', '/'))'
command -v cc >/dev/null || export CC=clang CXX=clang++
"@
if ($Jobs -le 0) { $Jobs = Get-DefaultJobs }    # CPU threads minus 2, at Idle priority
$winPrefix = $prefix.Replace('\', '/')

# ---------------------------------------------------------------- 2. babl, GEGL, exiv2
if ($CleanDeps -and (Test-Path $prefix)) { Write-Step "clean deps: removing $prefix"; Remove-Tree $prefix }
function Build-Dep([string]$name, [string]$file, [string]$dir, [string]$configure, [string]$patch = '') {
    $mark = Join-Path $prefix ".olga-dep-$name-$file"
    if (Test-Path $mark) { Write-Step "dep $name : installed"; return }
    Write-Step "dep $name : $file"
    $dsrc = Join-Path $srcParent $dir
    $dbuild = Join-Path $bRoot "dep-$name"
    foreach ($d in @($dsrc, $dbuild)) { Remove-Tree $d }
    $sp = ConvertTo-MsysPath $srcParent
    if ($file -like '*.src.tar.zst') {
        # MSYS2 source package: <pkg>/<upstream tarball> (+ PKGBUILD); unpack the upstream tarball
        Invoke-Msys $msys "cd '$sp' && rm -rf _srcpkg && mkdir _srcpkg && tar -xf '$(ConvertTo-MsysPath (Join-Path $dl $file))' -C _srcpkg && tar -xf `$(ls _srcpkg/*/*.tar.gz | head -1) && rm -rf _srcpkg" $null $M
    } else {
        # MSYS2 tar emulates symlinks by copying the target, which fails when a link comes before its target in
        # the archive (GEGL's bin/lua); a second pass finds the targets in place
        $tf = ConvertTo-MsysPath (Join-Path $dl $file)
        Invoke-Msys $msys "cd '$sp' && { tar -xf '$tf' 2>/dev/null || tar -xf '$tf'; }" $null $M
    }
    if (-not (Test-Path $dsrc)) { throw "unexpected archive layout: $dsrc missing after unpacking $file" }
    if ($patch) { Invoke-Msys $msys "cd '$(ConvertTo-MsysPath $dsrc)' && patch -p1 --forward < '$(ConvertTo-MsysPath $patch)'" $null $M }
    $cfg = $configure.Replace('@SRC@', (ConvertTo-MsysPath $dsrc)).Replace('@BUILD@', (ConvertTo-MsysPath $dbuild))
    Invoke-Msys $msys ($envSh + "`n" + $cfg + "`nninja -C '$(ConvertTo-MsysPath $dbuild)' -j $Jobs install") $null $M
    Ensure-Dir $prefix
    Set-Content -Path $mark -Value (Get-Date -Format o)
}
$mesonCommon = "-Dprefix='$winPrefix' -Dbuildtype=debugoptimized -Dpkgconfig.relocatable=true"
Build-Dep 'babl' "babl-$BablVersion.tar.xz" "babl-$BablVersion" "meson setup '@BUILD@' '@SRC@' $mesonCommon"
Build-Dep 'gegl' "gegl-$GeglVersion.tar.xz" "gegl-$GeglVersion" "meson setup '@BUILD@' '@SRC@' $mesonCommon -Ddocs=false"
Build-Dep 'exiv2' "mingw-w64-exiv2-$Exiv2Version-$Exiv2MsysRel.src.tar.zst" "exiv2-$Exiv2Version" ("cmake -G Ninja -S '@SRC@' -B '@BUILD@' -DCMAKE_INSTALL_PREFIX='$winPrefix' -DCMAKE_BUILD_TYPE=RelWithDebInfo " +
    "-DCMAKE_DLL_NAME_WITH_SOVERSION=ON -DEXIV2_BUILD_EXIV2_COMMAND=OFF -DEXIV2_ENABLE_VIDEO=OFF -DEXIV2_BUILD_SAMPLES=OFF -DEXIV2_BUILD_UNIT_TESTS=OFF " +
    # exiv2 0.28.8 uses std::mktime without <ctime>; newer libc++ no longer pulls it in transitively
    "'-DCMAKE_CXX_FLAGS=-include ctime'") `
    (Join-Path $RepoRoot 'branding\gimp\deps\exiv2-pr3361-locale-workaround.patch')

# ---------------------------------------------------------------- 3. branding
$bdir = Join-Path $RepoRoot 'branding\gimp'
$patches = @(Get-ChildItem (Join-Path $bdir 'patches') -Filter '*.patch' | Sort-Object Name)
$hashInputs = @($patches | ForEach-Object { $_.FullName }) + @((Join-Path $bdir 'apply-branding.py'), (Join-Path $bdir 'zh_TW-terms.csv'), (Join-Path $RepoRoot 'brand.json')) +
    @(Get-ChildItem -Recurse -File (Join-Path $bdir 'defaults') | Sort-Object FullName | ForEach-Object { $_.FullName })
$sha = [Security.Cryptography.SHA256]::Create()
$acc = New-Object System.Text.StringBuilder
[void]$acc.Append($GimpVersion)
foreach ($f in $hashInputs) {
    [void]$acc.Append($f.Substring($RepoRoot.Length)).Append([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f))))
}
$stamp = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($acc.ToString()))).Replace('-', '')
$stampFile = Join-Path $srcParent "gimp-$GimpVersion.brand-stamp"
$oldStamp = ''
if (Test-Path $stampFile) { $oldStamp = (Get-Content $stampFile -TotalCount 1).Trim() }
$brandChanged = ($stamp -ne $oldStamp)
if ($brandChanged) {
    Write-Step "branding: applying $($patches.Count) patches + apply-branding.py"
    Remove-Item -Force $stampFile -ErrorAction SilentlyContinue
    # back to the pristine release (only files that differ are rewritten, so ninja recompiles just those)
    Invoke-Msys $msys ($gitEnv + "cd '$s' && git reset -q --hard && git clean -q -fdx") $null $M
    foreach ($pf in $patches) {
        Write-Output "  patch $($pf.Name)"
        Invoke-Msys $msys ($gitEnv + "cd '$s' && git apply --whitespace=nowarn '$(ConvertTo-MsysPath $pf.FullName)'") $null $M
    }
    $py = "'$(ConvertTo-MsysPath (Join-Path $bdir 'apply-branding.py'))' source '$s' '$(ConvertTo-MsysPath (Join-Path $RepoRoot 'brand.json'))'"
    Invoke-Msys $msys "/clang64/bin/python -I $py" $null $M
    Set-Content -Path $stampFile -Value $stamp
} else {
    Write-Step 'branding: up to date'
}

# ---------------------------------------------------------------- 4. configure
$build = Join-Path $bRoot 'build'
if ($Clean -and (Test-Path $build)) { Write-Step "clean: removing $build"; Remove-Tree $build }
Ensure-Dir $build
$b = ConvertTo-MsysPath $build
$opts = @(
    "-Dprefix='$winPrefix'", '-Dpkgconfig.relocatable=true',
    '-Dwindows-installer=true', '-Denable-default-bin=enabled', '-Dcheck-update=no', '-Dgi-docgen=disabled',
    "-Dbuild-id='$($g.appId)'", "-Dbug-report-url='$($brand.url)'", "-Dgimpdir='$($g.nameAscii)'",
    "-Dolga-brand-name='$($g.name)'", "-Dolga-brand-name-ascii='$($g.nameAscii)'", "-Dolga-brand-id='$($g.id)'",
    "-Dolga-brand-vendor='$($brand.vendor)'", "-Dolga-brand-url='$($brand.url)'",
    "-Dolga-brand-version-suffix='$($g.versionSuffix)'", "-Dolga-app-id='$($g.appId)'"
) -join ' '
if (-not (Test-Path (Join-Path $build 'build.ninja'))) {
    Write-Step 'configure (meson setup)'
    Invoke-Msys $msys ($envSh + "`nmeson setup '$b' '$s' $opts") $null $M
} elseif ($brandChanged) {
    Write-Step 'configure (meson reconfigure: branding changed)'
    Invoke-Msys $msys ($envSh + "`nmeson setup --reconfigure '$b' '$s' $opts") $null $M
} else {
    Write-Step 'configure: up to date'
}

# ---------------------------------------------------------------- 5. compile
Write-Step "build: ninja -j $Jobs"
$tb = Get-Date
# The pdbgen step rewrites libgimp/*_pdb.h in the source tree; on Windows a compile that includes one of them
# at that moment fails with "Permission denied". Build that stamp first, then everything else.
$pdbFirst = "t=`$(ninja -C '$b' -t targets all | grep -o '^[^:]*stamp-pdbgen[^:]*' | head -1); if [ -n `"`$t`" ]; then ninja -C '$b' -j $Jobs `"`$t`"; fi"
Invoke-Msys $msys ($envSh + "`n" + $pdbFirst + "`nninja -C '$b' -j $Jobs") $null $M
Write-Step ("build: done in {0:N1} min" -f ((Get-Date) - $tb).TotalMinutes)

# ---------------------------------------------------------------- 6. install + bundle
# upstream's bundling script (run by `ninja install` because of -Dwindows-installer=true) writes the
# self-contained app folder to <source>\gimp-clang64; it is moved next to the build as <Root>\build\gimp\<id>
$bundleSrc = Join-Path $src 'gimp-clang64'
$bundle = Join-Path $bRoot $g.id
foreach ($d in @($bundleSrc, $bundle)) { Remove-Tree $d }
Write-Step 'install + bundle (ninja install)'
# GIMP's own folders in the prefix are re-installed from scratch: `ninja install` never deletes, so a data
# file the branding removed (or a plug-in left out) would otherwise still reach the bundle from an older run
foreach ($d in @('share\gimp', 'lib\gimp', 'etc\gimp')) { Remove-Tree (Join-Path $prefix $d) }
Invoke-Msys $msys ($envSh + "`nninja -C '$b' install > '$b/ninja-install.log' 2>&1 || { tail -40 '$b/ninja-install.log'; exit 1; }") $null $M
if (-not (Test-Path (Join-Path $bundleSrc "bin\$($g.id).exe"))) { throw "bundle incomplete: $bundleSrc\bin\$($g.id).exe missing" }
Move-Item $bundleSrc $bundle

# ---------------------------------------------------------------- 6b. Resynthesizer plug-ins
# Built against the libgimp just installed into the prefix (like any third-party plug-in) and installed there;
# its plug-in folders are then copied into the bundle (the installer packs lib\gimp\3.0\plug-ins\* as is).
if (-not $NoResynthesizer) {
    Write-Step "Resynthesizer $ResynthVersion (Filters > Enhance > Heal Selection and related)"
    $rsrc = Join-Path $srcParent "resynthesizer-$ResynthVersion"
    $rbuild = Join-Path $bRoot 'dep-resynthesizer'
    if (-not (Test-Path (Join-Path $rsrc '.olga-extracted'))) {
        foreach ($d in @($rsrc, $rbuild)) { Remove-Tree $d }
        $tf = ConvertTo-MsysPath (Join-Path $dl "resynthesizer-$ResynthVersion.tar.gz")
        Invoke-Msys $msys "cd '$(ConvertTo-MsysPath $srcParent)' && { tar -xf '$tf' 2>/dev/null || tar -xf '$tf'; }" $null $M
        if (-not (Test-Path (Join-Path $rsrc 'meson.build'))) { throw "unexpected archive layout: $rsrc\meson.build missing" }
        Set-Content -Path (Join-Path $rsrc '.olga-extracted') -Value (Get-Date -Format o)
    }
    $rb = ConvertTo-MsysPath $rbuild
    $rcfg = ''
    if (-not (Test-Path (Join-Path $rbuild 'build.ninja'))) {
        $rcfg = "meson setup '$rb' '$(ConvertTo-MsysPath $rsrc)' -Dprefix='$winPrefix' -Dbuildtype=release`n"
    }
    Invoke-Msys $msys ($envSh + "`n" + $rcfg + "ninja -C '$rb' -j $Jobs install") $null $M
    $plugSrc = Join-Path $prefix 'lib\gimp\3.0\plug-ins'
    $plugDst = Join-Path $bundle 'lib\gimp\3.0\plug-ins'
    $names = @(Get-ChildItem (Join-Path $rsrc 'outerPlugins') -Filter '*.scm' | ForEach-Object { $_.BaseName }) + @('resynthesizer')
    $present = @($names | Where-Object { Test-Path (Join-Path (Join-Path $plugSrc $_) "$_.*") })
    if ($present -notcontains 'resynthesizer' -or $present -notcontains 'plug-in-heal-selection') {
        throw "Resynthesizer: plug-ins missing after install (got: $($present -join ', '))"
    }
    # Traditional Chinese: the plug-ins' own gettext domain, catalog from branding\gimp\resynthesizer-zh_TW.po
    # installed into each plug-in folder (checked against the texts the installed plug-ins really use)
    $rsheet = Join-Path $bRoot 'resynthesizer-zh_TW-review.md'
    Remove-Item -Force $rsheet -ErrorAction SilentlyContinue
    $py = "'$(ConvertTo-MsysPath (Join-Path $bdir 'resynthesizer-i18n.py'))' '$(ConvertTo-MsysPath $rsrc)' '$(ConvertTo-MsysPath $plugSrc)' '$(ConvertTo-MsysPath $rsheet)' $($present -join ' ')"
    Invoke-Msys $msys ($envSh + "`n/clang64/bin/python -I $py") $null $M
    foreach ($n in $present) { Copy-Item -Recurse -Force (Join-Path $plugSrc $n) $plugDst }
    Write-Output "  plug-ins: $($present -join ', ')"
    foreach ($f in 'COPYING', 'AUTHORS') { Copy-Item (Join-Path $rsrc $f) (Join-Path $plugDst "resynthesizer\$f") }
    $notice = Join-Path $bundle 'NOTICE.txt'
    $nl = "`n"
    if ([IO.File]::ReadAllText($notice).Contains("`r`n")) { $nl = "`r`n" }
    [IO.File]::AppendAllText($notice, ($nl +
        "The content-aware healing filters (Filters > Enhance > Heal Selection, Heal Transparency, Uncrop and" + $nl +
        "related) are Resynthesizer $ResynthVersion by Lloyd Konneker and contributors" + $nl +
        "(https://github.com/bootchk/resynthesizer), GNU General Public License, version 3; see" + $nl +
        "lib\gimp\3.0\plug-ins\resynthesizer\COPYING." + $nl), (New-Object Text.UTF8Encoding($false)))
}
$py = "'$(ConvertTo-MsysPath (Join-Path $bdir 'apply-branding.py'))' bundle '$(ConvertTo-MsysPath $bundle)' '$(ConvertTo-MsysPath (Join-Path $RepoRoot 'brand.json'))' '$b'"
Invoke-Msys $msys "/clang64/bin/python -I $py" $null $M
foreach ($f in 'COPYING', 'LICENSE', 'NOTICE.txt', 'GUIDE-zh_TW.html', "$($g.id).cmd") {
    if (-not (Test-Path (Join-Path $bundle $f))) { throw "missing from the bundle: $f" }
}

# ---------------------------------------------------------------- 7. package
$dist = Join-Path $Root 'dist'
Ensure-Dir $dist
$verTag = "$GimpVersion$($g.versionSuffix)"
$zip = Join-Path $dist ("{0}-{1}-win64-portable.zip" -f $g.id, $verTag)
Write-Step "package: $zip (without .pdb debug symbols)"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$za = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $baseLen = (Split-Path -Parent $bundle).Length + 1
    foreach ($f in (Get-ChildItem -Recurse -File -Force $bundle)) {
        if ($f.Extension -eq '.pdb' -or $f.Name -eq '.gitignore') { continue }
        $entry = $f.FullName.Substring($baseLen).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $f.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $za.Dispose() }
Write-Output ("  {0:N0} MB" -f ((Get-Item $zip).Length / 1MB))
# the customer guide (also inside the packages), next to the packages
Copy-Item -Force (Join-Path $bundle 'GUIDE-zh_TW.html') (Join-Path $dist ("{0}-{1}-guide-zh_TW.html" -f $g.id, $verTag))
# the zh_TW wording review sheet written by apply-branding.py (for staff, next to the packages)
$sheet = Join-Path $src 'po\olga-zh_TW-terms-review.md'
$sheetOut = Join-Path $dist ("{0}-{1}-zh_TW-terms-review.md" -f $g.id, $verTag)
if (Test-Path $sheet) {
    Copy-Item -Force $sheet $sheetOut
    # plus the Resynthesizer section written by resynthesizer-i18n.py
    $rsheet = Join-Path $bRoot 'resynthesizer-zh_TW-review.md'
    if (-not $NoResynthesizer -and (Test-Path $rsheet)) {
        [IO.File]::AppendAllText($sheetOut, "`n" + [IO.File]::ReadAllText($rsheet, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($false)))
    }
    # plus the other text domains (approved terms applied there, translations added) from apply-branding.py bundle
    $csheet = Join-Path $build 'olga-zh_TW-catalogs-review.md'
    if (-not (Test-Path $csheet)) { throw "missing: $csheet (apply-branding.py bundle)" }
    [IO.File]::AppendAllText($sheetOut, [IO.File]::ReadAllText($csheet, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($false)))
}

if (-not $NoInstaller) {
    try {
        & "$PSScriptRoot\package-gimp-installer.ps1" -Root $Root -Bundle $bundle -BuildDir $build -Source $src
    } catch {
        Write-Output "  installer failed (portable zip is still fine): $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 8. smoke test
if (-not $NoSmokeTest) {
    & "$PSScriptRoot\smoke-test-gimp.ps1" -Root $Root -GimpVersion $GimpVersion -NoResynthesizer:$NoResynthesizer
}

$mine = @('msys64-gimp', 'src', 'build', 'ccache', 'downloads', 'tools', 'dist', 'smoke-gimp') | ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }
$used = (Get-ChildItem -Recurse -Force $mine -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
Write-Step ("ALL DONE in {0:N1} min; this pipeline uses {1:N1} GB under {2} (MSYS2, sources, builds, downloads, packages)" -f ((Get-Date) - $t0).TotalMinutes, ($used / 1GB), $Root)
