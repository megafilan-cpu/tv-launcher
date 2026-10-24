# Check that the setup is still in place, typically after a Sony firmware update, which can re-enable
# disabled packages, hand Home back to the stock launcher, drop the remote-button service and add new
# preloads. Read-only on the TV (the same idea as cleanyourtv's tools/check.py, for this setup).
#
# Usage: scripts\check.ps1 [-List debloat\debloat.txt] [-Baseline backup\2026-10-21_1537-after-setup] [-TvHost 192.168.8.202]
# Exit code 0 when everything is in place, 1 when something drifted.
# Fix:   scripts\disable.ps1 debloat\debloat.txt   (re-disables what came back)
#        scripts\launcher-install.ps1 -TakeHome     (Home, stock launcher, remote-button service)
#        scripts\dns.ps1                            (Private DNS)
param(
    [string]$List = '',
    [string]$Baseline = '',
    [string]$TvHost = $(if ($env:TV_HOST) { $env:TV_HOST } else { '192.168.8.202' })
)
$ErrorActionPreference = 'Stop'
$adb = if ($env:ADB) { $env:ADB } else { 'D:\Server\Tools\platform-tools\adb.exe' }
$dev = if ($TvHost -like '*:*') { $TvHost } else { "${TvHost}:5555" }
$repo = Split-Path -Parent $PSScriptRoot
if (-not $List) { $List = Join-Path $repo 'debloat\debloat.txt' }
if (-not $Baseline) { $Baseline = Join-Path $repo 'backup\2026-10-21_1537-after-setup' }
$pkg = 'com.cosyhome.tv'
$stock = 'com.google.android.apps.tv.launcherx'
$drift = 0
function Bad([string]$msg) { Write-Output "DRIFT  $msg"; $script:drift++ }
function Packages([string[]]$lines) { $lines -replace '^package:', '' | ForEach-Object { "$_".Trim() } | Where-Object { $_ } }

& $adb connect $dev | Out-Null
$enabled = @(Packages (& $adb -s $dev shell pm list packages -e))
if ($enabled.Count -eq 0) { throw "could not read the package list from $dev" }
$all = @(Packages (& $adb -s $dev shell pm list packages))

# Firmware version, compared with the baseline.
$build = ((& $adb -s $dev shell getprop ro.build.version.incremental) -join '').Trim()
$baseProps = Join-Path $Baseline 'getprop.txt'
$baseBuild = if (Test-Path $baseProps) { (Select-String -Path $baseProps -Pattern '^\[ro\.build\.version\.incremental\]: \[(.*)\]$' | Select-Object -First 1).Matches.Groups[1].Value } else { '' }
Write-Output ("firmware  $build" + $(if ($baseBuild -and $baseBuild -ne $build) { " (was ${baseBuild}: updated since the baseline)" } else { '' }))

# Listed packages that are enabled again.
$pkgs = Get-Content $List | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' }
foreach ($p in $pkgs) { if ($enabled -contains $p) { Bad "$p is enabled again" } }

# Home, the stock launcher and the remote-button service.
$homeAct = ((& $adb -s $dev shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME) | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
if ("$homeAct".Trim() -notlike "$pkg/*") { Bad "Home is $("$homeAct".Trim()), not Cosy Home" }
if ($enabled -contains $stock) { Bad "$stock (stock launcher) is enabled again" }
$svc = ((& $adb -s $dev shell settings get secure enabled_accessibility_services) -join '').Trim()
if ($svc -notmatch [regex]::Escape("$pkg/$pkg.KeyService")) { Bad 'the remote-button service is off (YouTube button -> SmartTube)' }

# Private DNS.
$mode = ((& $adb -s $dev shell settings get global private_dns_mode) -join '').Trim()
$spec = ((& $adb -s $dev shell settings get global private_dns_specifier) -join '').Trim()
if ($mode -ne 'hostname' -or $spec -notlike '*adguard*') { Bad "Private DNS is $mode $spec, not AdGuard" }

# New packages since the baseline: a firmware update may add preloads worth reviewing (not counted as drift).
$baseAll = Join-Path $Baseline 'packages-all.txt'
if (Test-Path $baseAll) {
    $known = @(Get-Content $baseAll | ForEach-Object { if ($_ -match '=([A-Za-z0-9_.]+)( versionCode:\d+)?$') { $Matches[1] } })
    $new = @($all | Where-Object { $known -notcontains $_ })
    foreach ($p in $new) { Write-Output "new    $p (not in the baseline; review it before adding to the list)" }
}

if ($drift -eq 0) { Write-Output 'OK     everything is in place.'; exit 0 }
Write-Output "$drift item(s) drifted. Fix lines are at the top of scripts\check.ps1."
exit 1
