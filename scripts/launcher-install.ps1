# Build the Cosy Home launcher (launcher\), install it on the TV, and with -TakeHome make it the Home screen.
# Run again after changing launcher\cosy.properties or the source.
#
# Usage: scripts\launcher-install.ps1 [-TakeHome] [-NoBuild] [-NoOpen] [-TvHost 192.168.8.202]
# Undo:  scripts\restore.ps1 -RemoveLauncher   (or see "Undo / restore" in README.md)
param(
    [switch]$TakeHome,
    [switch]$NoBuild,
    [switch]$NoOpen,
    [string]$TvHost = $(if ($env:TV_HOST) { $env:TV_HOST } else { '192.168.8.202' })
)
$ErrorActionPreference = 'Stop'
$adb = if ($env:ADB) { $env:ADB } else { 'D:\Server\Tools\platform-tools\adb.exe' }
$bash = if ($env:GIT_BASH) { $env:GIT_BASH } else { 'D:\Laragon\bin\git\bin\bash.exe' }
$dev = if ($TvHost -like '*:*') { $TvHost } else { "${TvHost}:5555" }
$repo = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $repo 'launcher'
$apk = Join-Path $launcher 'app\build\outputs\apk\release\app-release.apk'
$pkg = 'com.cosyhome.tv'
$stock = 'com.google.android.apps.tv.launcherx'
$setup = 'com.google.android.tungsten.setupwraith'
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = 'D:\Server\Tools\Android\Sdk' }

# Build with the Gradle wrapper through Git Bash (the project ships only the sh wrapper).
if (-not $NoBuild) {
    # Windows PowerShell turns compiler notes on stderr into errors, so judge the build by its exit code only.
    $ErrorActionPreference = 'Continue'
    & $bash -lc "cd '$($launcher -replace '\\','/')' && ./gradlew assembleRelease -q --console=plain" 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}

& $adb connect $dev | Out-Null
& $adb -s $dev install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'install failed' }

# Switch the remote-button service back on: Android drops it from the enabled list on every reinstall, a moment after the install returns.
Start-Sleep -Seconds 4
$svc = "$pkg/$pkg.KeyService"
$current = ((& $adb -s $dev shell settings get secure enabled_accessibility_services) -join '').Trim()
$list = @($current -split ':' | Where-Object { $_ -and $_ -ne 'null' -and $_ -ne $svc }) + $svc
& $adb -s $dev shell settings put secure enabled_accessibility_services ($list -join ':')
& $adb -s $dev shell settings put secure accessibility_enabled 1
Start-Sleep -Seconds 2
$enabled = ((& $adb -s $dev shell "dumpsys accessibility | grep 'Enabled services'") -join '') -match [regex]::Escape($svc)
# Media session access for the now playing card (notification listener; notifications themselves are never read).
& $adb -s $dev shell cmd notification allow_listener "$pkg/$pkg.MediaListener"
if ($enabled) { Write-Output 'Remote-button service is enabled and bound.' } else { Write-Warning 'Remote-button service is not enabled: run this script again or switch it on under Settings > Accessibility.' }

function HomeNow { ((& $adb -s $dev shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME) | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim() }

if (-not $TakeHome) {
    # -NoOpen leaves whatever is on screen alone (someone may be watching).
    if (-not $NoOpen) { & $adb -s $dev shell am start -n "$pkg/.HomeActivity" | Out-Null }
    Write-Output "Installed and opened. Home is still: $(HomeNow)"
    return
}

# The setup wizard claims HOME once the stock launcher is gone. Its Wi-Fi ownership was checked: the TV is on Ethernet.
& $adb -s $dev shell pm disable-user --user 0 $setup

# Start Cosy Home first so the TV is never without a Home, then disable the stock launcher.
& $adb -s $dev shell am start -n "$pkg/.HomeActivity" | Out-Null
& $adb -s $dev shell pm disable-user --user 0 $stock
& $adb -s $dev shell cmd package set-home-activity "$pkg/.HomeActivity"

# Verify with a real Home key press, not only the resolver.
Start-Sleep -Seconds 2
& $adb -s $dev shell input keyevent KEYCODE_HOME
Start-Sleep -Seconds 2
$focused = (& $adb -s $dev shell "dumpsys activity activities | grep mFocusedApp") -join ' '
if ((HomeNow) -like "$pkg/*" -and $focused -match $pkg) {
    Write-Output "Cosy Home is the Home screen. $stock and $setup are disabled."
    Write-Output 'Wait ten seconds before switching the TV off at the wall.'
} else {
    & $adb -s $dev shell pm enable $stock | Out-Null
    throw "Home did not move to Cosy Home ($(HomeNow); $focused). $stock was re-enabled."
}
