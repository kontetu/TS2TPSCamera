<#
  Builds the distribution zip: release\TS2TPSCamera-v<version>.zip
  Contents: ue4ss\Mods\TS2TPSCamera\ (the mod only) + README.md, README-ja.md, LICENSE.txt, CHANGELOG.md.
  It never includes research\, backups\, tools\, TS2Probe, install records or the user's settings_values.lua,
  and it refuses to build while a document still has a placeholder or the version numbers disagree.
  Run:  .\Build-Release.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$modDir = Join-Path $root 'TS2TPSCamera'
$distDir = Join-Path $root 'dist'

# --- version: main.lua is the source of truth; the docs must agree
$mainText = Get-Content -LiteralPath (Join-Path $modDir 'Scripts\main.lua') -Raw -Encoding UTF8
if ($mainText -notmatch 'local VERSION = "([0-9]+\.[0-9]+\.[0-9]+[^"]*)"') { throw 'VERSION not found in main.lua' }
$version = $Matches[1]
foreach ($doc in 'README.md', 'README-ja.md') {
    $text = Get-Content -LiteralPath (Join-Path $distDir $doc) -Raw -Encoding UTF8
    if ($text -notmatch [regex]::Escape("v$version")) { throw "dist\$doc does not mention v$version" }
}
$changelog = Get-Content -LiteralPath (Join-Path $distDir 'CHANGELOG.md') -Raw -Encoding UTF8
if ($changelog -notmatch "## $([regex]::Escape($version)) ") { throw "dist\CHANGELOG.md has no section for $version" }
$license = Get-Content -LiteralPath (Join-Path $distDir 'LICENSE.txt') -Raw -Encoding UTF8
if ($license -match '<YOUR NAME') { throw 'dist\LICENSE.txt still has the <YOUR NAME OR HANDLE> placeholder - put your name or handle in the copyright line.' }

# --- the repository's top-level README.md / README-ja.md / LICENSE start with the shipped dist\ text (no drift)
foreach ($pair in @(@('README.md', 'README.md'), @('README-ja.md', 'README-ja.md'), @('LICENSE', 'LICENSE.txt'))) {
    $top = Join-Path $root $pair[0]
    if (Test-Path -LiteralPath $top) {
        $topText = (Get-Content -LiteralPath $top -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $distText = ((Get-Content -LiteralPath (Join-Path $distDir $pair[1]) -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd()
        if (-not $topText.StartsWith($distText)) { throw "$($pair[0]) in the repository root no longer starts with dist\$($pair[1]) - copy it over again." }
    }
}

# --- files
$entries = New-Object System.Collections.Generic.List[object]   # @{ Source; Name }
Get-ChildItem -LiteralPath $modDir -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($modDir.Length).TrimStart('\')
    if ($relative -eq 'settings_values.lua' -or $relative -like 'snapshot-*') { return }
    $entries.Add(@{ Source = $_.FullName; Name = 'ue4ss/Mods/TS2TPSCamera/' + ($relative -replace '\\', '/') })
}
foreach ($doc in 'README.md', 'README-ja.md', 'LICENSE.txt', 'CHANGELOG.md') {
    $entries.Add(@{ Source = (Join-Path $distDir $doc); Name = $doc })
}

# --- nothing personal or machine-specific may ship
$problems = @()
foreach ($entry in $entries) {
    $text = Get-Content -LiteralPath $entry.Source -Raw -Encoding UTF8
    if ($text -match ('(?i)' + [regex]::Escape($env:USERNAME) + '|C:\\Users|[A-Z]:\\program files|Documents\\claude')) { $problems += "personal path/name in $($entry.Name)" }
}
if ($problems) { throw ("Refusing to build:`n  " + ($problems -join "`n  ")) }

# --- zip (forward-slash entry names, UTF-8 file contents untouched)
$releaseDir = Join-Path $root 'release'
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$zipPath = Join-Path $releaseDir "TS2TPSCamera-v$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entry in $entries) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $entry.Source, $entry.Name, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $zip.Dispose() }

# --- report
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try { $check.Entries | ForEach-Object { '{0,8}  {1}' -f $_.Length, $_.FullName } } finally { $check.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Host ''
Write-Host "Built $zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)) KB)"
Write-Host "SHA-256 $hash"
