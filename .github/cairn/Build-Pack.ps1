# Copyright (C) 2026 the Cairn contributors. SPDX-License-Identifier: GPL-3.0-only (as the project it is part of)
<#
.SYNOPSIS
    Builds the Cairn mod pack for Grand Theft Auto: San Andreas (CoopAndreas): release\Cairn-Pack-gta-sa-<version>.zip and
    release\pack-index.json (what the Cairn launcher reads to see a newer pack exists).

.DESCRIPTION
    An *external* pack that goes into the game's own folder (docs in the launcher repository: docs/PACKS.md, installDir "."), laid out as the
    README's build section lays it out by hand:

      eax.dll                 the proxy (the game loads it in place of its own eax.dll, which the player renames to eax_orig.dll first)
      CoopAndreasSA.dll       the client
      LaunchCoopAndreas.exe   the launcher the pack names as its "launch": it starts the game with the arguments the mod needs
      CoopAndreas\            the compiled script (main.scm, script.img) and the server (server.exe)
      pack.json, manifest.txt

    The pack's version is the VERSION file (strict X.Y.Z, this project's own); the mod's version (client\version.rc) is the pack's "upstream".
    The mod's own beta serial key (asked by its launcher) is left exactly as the project made it.
    A file of the game's with the same name and other bytes is never overwritten by the launcher.
#>
[CmdletBinding()]
param(
    [string] $BuildDir = 'build'    # where xmake put what it built
)

$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw "VERSION must be strict X.Y.Z, got '$version'" }
$rc = Get-Content (Join-Path $root 'client\version.rc') -Raw
$modVersion = [regex]::Match($rc, 'FILEVERSION\s+(\d+),(\d+),(\d+),\d+')
if (-not $modVersion.Success) { throw 'could not read the mod version from client\version.rc' }
$upstream = "$($modVersion.Groups[1].Value).$($modVersion.Groups[2].Value).$($modVersion.Groups[3].Value)"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$release = Join-Path $root 'release'
$stage = Join-Path $release 'pack-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$mod = Join-Path $stage 'mod'
New-Item -ItemType Directory -Force -Path (Join-Path $mod 'CoopAndreas') | Out-Null

function Find-Built([string] $name, [switch] $Optional) {
    $f = @(Get-ChildItem (Join-Path $root $BuildDir) -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'release' -and $_.FullName -notmatch '\.(obj|pdb)' })
    if ($f.Count -eq 0) { if ($Optional) { return $null }; throw "the build did not make $name under $BuildDir" }
    return $f[0].FullName
}
Copy-Item (Find-Built 'proxy.dll') (Join-Path $mod 'eax.dll')
Copy-Item (Find-Built 'CoopAndreasSA.dll') (Join-Path $mod 'CoopAndreasSA.dll')
Copy-Item (Find-Built 'LaunchCoopAndreas.exe') (Join-Path $mod 'LaunchCoopAndreas.exe')
if (Find-Built 'LaunchCoopAndreas.exe.manifest' -Optional) { Copy-Item (Find-Built 'LaunchCoopAndreas.exe.manifest') (Join-Path $mod 'LaunchCoopAndreas.exe.manifest') }
Copy-Item (Find-Built 'server.exe') (Join-Path $mod 'CoopAndreas\server.exe')
foreach ($n in 'main.scm', 'script.img') {
    $src = Join-Path $root "scm\$n"
    if (-not (Test-Path $src)) { throw "the repository has no scm\$n" }
    Copy-Item $src (Join-Path $mod "CoopAndreas\$n")
}
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $mod 'CoopAndreas\LICENSE')

function Get-Sha256([string] $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# a launcher before 0.3.24 would start the game without the mod: it is refused there
$launcherMin = '0.3.24'
$packJson = [ordered]@{
    schema      = 2
    id          = 'gta-sa'
    game        = 'gta-sa'
    version     = $version
    upstream    = $upstream
    kind        = 'external'
    installDir  = '.'
    launch      = 'LaunchCoopAndreas.exe'
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $stage 'pack.json'), (($packJson | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $mod -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($mod.Length + 1)
    $lines.Add(('MOD|{0}|{1}|{2}' -f $rel, $f.Length, (Get-Sha256 $f.FullName)))
}
[IO.File]::WriteAllText((Join-Path $stage 'manifest.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$zipName = "Cairn-Pack-gta-sa-$version.zip"
$zipPath = Join-Path $release $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$fs = [IO.File]::Open($zipPath, 'Create')
try {
    $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.Length + 1) -replace '\\', '/'
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $z.Dispose() }
} finally { $fs.Dispose() }

$index = [ordered]@{
    schema      = 2
    id          = 'gta-sa'
    game        = 'gta-sa'
    version     = $version
    upstream    = $upstream
    kind        = 'external'
    file        = $zipName
    sha256      = Get-Sha256 $zipPath
    size        = (Get-Item $zipPath).Length
    launcherMin = $launcherMin
}
[IO.File]::WriteAllText((Join-Path $release 'pack-index.json'), (($index | ConvertTo-Json) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "pack: $zipPath ($([math]::Round((Get-Item $zipPath).Length / 1MB, 1)) MB), version $version, CoopAndreas $upstream, $($lines.Count) files"
