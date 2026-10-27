# am9-first-boot.ps1 - the one-time switch of a Ugoos AM9 Pro from Android
# to the Symphony CoreELEC stick, from Windows. Run it with
# am9-first-boot.cmd beside it (double-click), which starts PowerShell
# without changing the system's script policy.
#
# The box's bootloader looks on USB for the stick's aml_autoscript only when
# Android restarts with the reason "update", and Android's menus have no
# entry that does that. adb does: `adb reboot update`. This script is that
# one command, plus everything around it: get adb, connect, get the TV's
# "Allow USB debugging?" accepted, check the box is an AM9 Pro on firmware
# 2.2.0 or later, and make sure the stick is in.
#
# Windows PowerShell 5.1 (every Windows 10/11) and nothing else. adb is
# Google's own platform-tools, downloaded once into %LOCALAPPDATA% and
# checked against a pinned SHA-256; nothing is installed. The adb server
# runs on its own port and is stopped at the end, so an adb the user already
# has is not touched.
#
# Same steps and messages as am9-first-boot.command (macOS); change both.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with it on
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$PtVersion = '37.0.1'
$PtUrl = "https://dl.google.com/android/repository/platform-tools_r$PtVersion-win.zip"
# sha256 of that zip; Google's repository2-3.xml publishes sha1
# e03e78b1d80b396f1c3358e31251cb31740e1110 for the same file.
$PtSha256 = '45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99'
$Cache = Join-Path $env:LOCALAPPDATA "Symphony\am9\platform-tools-r$PtVersion"
$Adb = Join-Path $Cache 'platform-tools\adb.exe'
$MinFw = @(2, 2, 0)

$env:ANDROID_ADB_SERVER_PORT = '5099'

function Step($text) { Write-Host ''; Write-Host "== $text" }

function Finish([int]$code) {
    if (Test-Path $Adb) { Adb @('kill-server') | Out-Null }
    Write-Host ''
    Read-Host 'Press Enter to close this window' | Out-Null
    exit $code
}

function Fail($text) {
    Write-Host ''
    Write-Host "STOPPED: $text" -ForegroundColor Yellow
    Finish 1
}

function Adb([string[]]$a) {
    # adb's output as text; never throws (adb writes progress to stderr)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Adb @a 2>&1) | Out-String) } finally { $ErrorActionPreference = $old }
}

Clear-Host
Write-Host @'
Symphony CoreELEC - first boot of a Ugoos AM9 Pro

Before you start:
  - The AM9 Pro is on, in Android, on the same network as this PC.
  - You know its IP address (Android: Settings -> Network & Internet ->
    your connection).
  - The Symphony system stick is written and in your hand.
  - The Dolby Vision stick (dovi.ko) is ready, if you have one.
'@

# ---------------------------------------------------------------- adb
if (-not (Test-Path $Adb)) {
    Step "Downloading Google's adb (platform-tools $PtVersion, about 8 MB)"
    try {
        New-Item -ItemType Directory -Force -Path $Cache | Out-Null
        $zip = Join-Path $Cache 'pt.zip'
        Invoke-WebRequest -UseBasicParsing -Uri $PtUrl -OutFile $zip
        $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
        if ($got -ne $PtSha256) {
            Remove-Item -Force $zip
            Fail 'the download does not match the expected checksum; not using it.'
        }
        Expand-Archive -Force -Path $zip -DestinationPath $Cache
        Remove-Item -Force $zip
    } catch {
        Fail "could not get adb ($($_.Exception.Message)). Check this PC's internet connection and run this again."
    }
    if (-not (Test-Path $Adb)) { Fail 'adb was not where the download should have put it.' }
}

# ------------------------------------------------------------- address
function Test-Ip([string]$s) {
    if (-not ($s -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')) { return $false }
    foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
    return $true
}

while ($true) {
    Write-Host ''
    $Ip = (Read-Host "The AM9 Pro's IP address (for example 192.168.1.50)") -replace '\s', ''
    if (Test-Ip $Ip) { break }
    Write-Host 'That is not an IP address. It is four numbers separated by dots.'
}
$T = "${Ip}:5555"

Step "Looking for the box at $Ip"
$open = $false
$tcp = New-Object Net.Sockets.TcpClient
try { $open = $tcp.ConnectAsync($Ip, 5555).Wait(3000) -and $tcp.Connected } catch { $open = $false } finally { $tcp.Close() }
if (-not $open) {
    Fail @"
nothing answered at $Ip on port 5555.
  - Check the address in Android's network settings.
  - Check the box and this PC are on the same network.
  - The box must be running Android firmware 2.2.0 or later, which has
    network debugging on.
"@
}

# ------------------------------------------------------------- connect
function Get-State {
    foreach ($line in ((Adb @('devices')) -split "`r?`n")) {
        $f = $line -split '\s+'
        if ($f.Count -ge 2 -and $f[0] -eq $T) { return $f[1] }
    }
    return ''
}

Adb @('start-server') | Out-Null
Adb @('connect', $T) | Out-Null

$told = $false
$deadline = (Get-Date).AddMinutes(3)
while ($true) {
    $s = Get-State
    if ($s -eq 'device') { break }
    if ($s -eq 'unauthorized' -and -not $told) {
        Write-Host ''
        Write-Host 'Look at the TV: it asks "Allow USB debugging?".'
        Write-Host 'Tick "Always allow from this computer", then choose Allow (or OK).'
        Write-Host 'Waiting for that...'
        $told = $true
    }
    if ($s -eq '') { Adb @('connect', $T) | Out-Null }
    if ((Get-Date) -gt $deadline) {
        Fail @"
the box did not accept this PC within 3 minutes.
  If no question appeared on the TV, restart the box and run this again.
"@
    }
    Start-Sleep -Seconds 2
}
Write-Host 'Connected.'

function Get-Prop([string]$name) { return (Adb @('-s', $T, 'shell', 'getprop', $name)).Trim() }

# --------------------------------------------------------------- model
Step 'Checking the box'
$Model = Get-Prop 'ro.product.model'
$norm = ($Model.ToUpper() -replace '[ -]', '_')
Write-Host "Model: $(if ($Model) { $Model } else { 'unknown' })"
if ($norm -ne 'AM9_PRO') {
    Fail 'this is not a Ugoos AM9 Pro. This build is for the AM9 Pro only (not the plain AM9).'
}

# ------------------------------------------------------------ firmware
# TODO: pin the property Ugoos keeps "2.2.0" in, read once from a box with
# `adb shell getprop`. Until then: the first x.y.z found in these.
$fwRaw = ''
foreach ($p in 'ro.build.display.id', 'ro.build.version.incremental', 'ro.product.version', 'ro.build.description') {
    $v = Get-Prop $p
    if ($v) { $fwRaw += " $v" }
}
$fw = $null
if ($fwRaw -match '(^|[^0-9.])v?(\d+)\.(\d+)\.(\d+)([^0-9.]|$)') {
    $fw = @([int]$Matches[2], [int]$Matches[3], [int]$Matches[4])
}

function Test-Older($v) {
    foreach ($i in 0..2) {
        if ($v[$i] -lt $MinFw[$i]) { return $true }
        if ($v[$i] -gt $MinFw[$i]) { return $false }
    }
    return $false
}

if ($fw) {
    $fwText = $fw -join '.'
    Write-Host "Firmware: $fwText"
    if (Test-Older $fw) {
        Fail @"
firmware $fwText is too old: this build needs 2.2.0 or later.
  Update Android first (Settings -> About -> System update -> Local update,
  with the firmware from Ugoos' AM9 Pro page), then run this again.
"@
    }
} else {
    Write-Host 'Firmware: could not read a version number from the box.'
    Write-Host 'Check Settings -> About on the TV: it must say 2.2.0 or later.'
    $ans = Read-Host 'Is it 2.2.0 or later? (y/n)'
    if ($ans -notmatch '^[yY]') { Fail 'update Android to 2.2.0 or later first, then run this again.' }
}

# ---------------------------------------------------------------- go
Step 'Ready'
Write-Host @'
Plug the Symphony system stick into one of the box's USB-A ports (all three are USB 3.0),
and the Dolby Vision stick (if you have one) into any other port.

The box will restart from the stick. You should see the Symphony splash
within a few seconds, then Kodi. This switch is needed only once: from now
on the box starts from the stick whenever it is plugged in.
'@
Write-Host ''
$ans = Read-Host 'Sticks in? Press Enter to restart the box into Symphony (or type q to stop)'
if ($ans -match '^[qQ]') { Fail 'stopped; nothing was changed.' }

Adb @('-s', $T, 'reboot', 'update') | Out-Null
$rc = $LASTEXITCODE
Adb @('disconnect', $T) | Out-Null
if ($rc -ne 0) { Fail "the box did not accept the restart command (adb exit $rc)." }

Write-Host ''
Write-Host 'Done. The box is restarting into Symphony CoreELEC.'
Write-Host 'If it starts Android again instead, check the system stick is in a USB-A port and run this again.'
Finish 0
