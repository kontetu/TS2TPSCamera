<#
  Installs UE4SS (copied from the user's Subnautica 2 install) and the listed
  mods into Tormented Souls 2. Never touches game content, paks or saves.
  Existing files that would be replaced are copied to backups\ first.
  Run with the game closed.   .\Install-TS2TPS.ps1 [-Mods TS2Probe,TS2TPSCamera] [-SkipUE4SS]
#>
[CmdletBinding()]
param(
    [string]$GameDir = 'E:\program files\steamapps\common\Tormented Souls 2',
    [string]$UE4SSSource = 'E:\program files\steamapps\common\Subnautica2\Subnautica2\Binaries\Win64',
    [string[]]$Mods = @('TS2Probe'),
    [switch]$SkipUE4SS
)
$ErrorActionPreference = 'Stop'
$work = $PSScriptRoot
$win64 = Join-Path $GameDir 'TormentedSouls2\Binaries\Win64'
$exe = Join-Path $win64 'TormentedSouls2-Win64-Shipping.exe'
$ue4ss = Join-Path $win64 'ue4ss'
$modsDir = Join-Path $ue4ss 'Mods'
# SHA-256 of the UE4SS v3.0.1 Beta files in the Subnautica 2 install (Git SHA cdbc0b66).
$expected = @{
    'dwmapi.dll'        = 'F8BEC398FCBB2E3E8D1EF2875CAFCC15D09F82073402FC9879A9CBF78B8D9514'
    'ue4ss\UE4SS.dll'   = 'C273E7228687B647226FD63D7CA65888D313ECE6BE18996EC1320D00A5EFE1F8'
}
$gameExeHashKnown = 'FB761DABD9E61A446CB2DDEAF44BA0432A8EE1A5A1F0A818EB204F3F6F2EE488'

if (-not (Test-Path -LiteralPath $exe)) { throw "Game executable not found: $exe" }
if (Get-Process -Name 'TormentedSouls2-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close Tormented Souls 2 first.' }
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
if ($exeHash -ne $gameExeHashKnown) { Write-Warning "Game exe hash differs from the one the mod was developed against: $exeHash" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backup = Join-Path $work "backups\TS2TPS-$stamp"
$backedUp = New-Object System.Collections.Generic.List[string]
function Backup-Item([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $relative = $path.Substring($win64.Length).TrimStart('\')
    $target = Join-Path $backup $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $path -Destination $target -Recurse -Force
    $backedUp.Add($relative)
}
function Copy-Verified([string]$from, [string]$to) {
    New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
    Backup-Item $to
    Copy-Item -LiteralPath $from -Destination $to -Force
    if ((Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash) {
        throw "Copy verification failed: $to"
    }
}

if (-not $SkipUE4SS) {
    foreach ($relative in $expected.Keys) {
        $source = Join-Path $UE4SSSource $relative
        if (-not (Test-Path -LiteralPath $source)) { throw "UE4SS source missing: $source" }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $expected[$relative]) { throw "UE4SS source hash mismatch: $source" }
    }
    Copy-Verified (Join-Path $UE4SSSource 'dwmapi.dll') (Join-Path $win64 'dwmapi.dll')
    Copy-Verified (Join-Path $UE4SSSource 'ue4ss\UE4SS.dll') (Join-Path $ue4ss 'UE4SS.dll')
    Copy-Verified (Join-Path $UE4SSSource 'ue4ss\LICENSE') (Join-Path $ue4ss 'LICENSE')
    # The settings file is only seeded once, so later edits are never overwritten.
    $ini = Join-Path $ue4ss 'UE4SS-settings.ini'
    if (-not (Test-Path -LiteralPath $ini)) { Copy-Verified (Join-Path $UE4SSSource 'ue4ss\UE4SS-settings.ini') $ini }
    Copy-Verified (Join-Path $UE4SSSource 'ue4ss\Mods\shared\UEHelpers\UEHelpers.lua') (Join-Path $modsDir 'shared\UEHelpers\UEHelpers.lua')
}

foreach ($mod in $Mods) {
    $from = Join-Path $work $mod
    if (-not (Test-Path -LiteralPath $from)) { throw "Mod folder not found in workspace: $from" }
    Get-ChildItem -LiteralPath $from -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($from.Length).TrimStart('\')
        # Files the mod writes at runtime in the game folder (saved settings, snapshots) are not overwritten.
        if ($relative -like 'snapshot-*' -or $relative -eq 'settings_values.lua') { return }
        Copy-Verified $_.FullName (Join-Path (Join-Path $modsDir $mod) $relative)
    }
}

$record = [ordered]@{
    installedAt = (Get-Date).ToString('o'); gameExeSha256 = $exeHash; ue4ssInstalled = (-not $SkipUE4SS)
    mods = $Mods; backupFolder = $(if ($backedUp.Count) { $backup } else { $null }); replacedFiles = $backedUp
}
New-Item -ItemType Directory -Path (Join-Path $work 'research') -Force | Out-Null
$recordPath = Join-Path $work "research\install-record-$stamp.json"
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding utf8
Write-Host "Installed. Record: $recordPath"
Write-Host "UE4SS log after the game starts: $(Join-Path $ue4ss 'UE4SS.log')"
