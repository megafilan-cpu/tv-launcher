# Disable the packages in a debloat list on the TV, one pm command per adb call. Never uninstalls.
# Each disabled package is appended to debloat\applied.log. Undo with scripts\restore.ps1.
#
# Usage: scripts\disable.ps1 debloat\debloat.txt [-Batch 3] [-TvHost 192.168.8.202] [-WhatIf]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$List,
    [int]$Batch = 0,
    [string]$TvHost = $(if ($env:TV_HOST) { $env:TV_HOST } else { '192.168.8.202' }),
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$adb = if ($env:ADB) { $env:ADB } else { 'D:\Server\Tools\platform-tools\adb.exe' }
$dev = if ($TvHost -like '*:*') { $TvHost } else { "${TvHost}:5555" }
$repo = Split-Path -Parent $PSScriptRoot
$log = Join-Path $repo 'debloat\applied.log'

# Read package names, keeping track of the "# Batch N:" headers.
$pkgs = @()
$current = 0
foreach ($line in Get-Content $List) {
    if ($line -match '^#\s*Batch\s+(\d+)') { $current = [int]$Matches[1]; continue }
    $name = ($line -replace '#.*$', '').Trim()
    if (-not $name) { continue }
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') { throw "not a package name: $name" }
    if ($Batch -eq 0 -or $Batch -eq $current) { $pkgs += $name }
}

# Core Android packages: with one of these disabled the TV may never boot again (cleanyourtv v2.7.0,
# issue #884). The whole list is checked, not only the chosen batch, and there is no override.
# Same patterns as tools\disable.ps1, disable.sh and recovery.py.
$coreRe = '^(android|com\.android\.systemui|com\.android\.shell|com\.android\.phone|com\.android\.settings|com\.android\.tv\.settings|com\.(google\.)?android\.(permissioncontroller|packageinstaller|ext\.services|ext\.shared|modulemetadata)|com\.google\.android\.overlay\.modules.*|com\.android\.providers\..*)$'
$coreOk = '^com\.android\.providers\.(calendar|contacts|userdictionary|blockednumber)$'
$all = @(Get-Content $List | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
$core = @($all | Where-Object { $_ -cmatch $coreRe -and $_ -cnotmatch $coreOk })
if ($core.Count -gt 0) {
    throw "refusing ${List}: it disables core Android packages, and without them the TV may not boot again: $($core -join ', '). Take these lines out of the list and run it again. Nothing was changed on the TV."
}

& $adb connect $dev | Out-Null
$enabled = (& $adb -s $dev shell pm list packages -e) -replace '^package:', '' | ForEach-Object { $_.Trim() }

foreach ($p in $pkgs) {
    if ($enabled -notcontains $p) { Write-Output "skip  $p (not installed or already disabled)"; continue }
    if ($WhatIf) { Write-Output "would disable  $p"; continue }
    $res = (& $adb -s $dev shell pm disable-user --user 0 $p) -join ' '
    Write-Output "$p -> $res"
    Add-Content -Path $log -Value ("{0}`t{1}`t{2}" -f (Get-Date -Format 's'), $p, $res.Trim())
}
