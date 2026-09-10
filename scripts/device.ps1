<#
.SYNOPSIS
  The phone, over adb. Install, launch, read the log, screenshot, record, measure, poke.

.EXAMPLE
  scripts\device.ps1 install            # adb install -r -g build\<slug>.apk
  scripts\device.ps1 launch             # force-stop and start, waits for the window
  scripts\device.ps1 log                # live: every print() and error (tag "godot"). Ctrl+C to stop
  scripts\device.ps1 log -Dump          # dump what is there and return
  scripts\device.ps1 shot               # build\phone\<time>.png
  scripts\device.ps1 record 30          # 30 s of video -> build\phone\<time>.mp4 and a contact sheet
  scripts\device.ps1 perf               # frame-time percentiles now, and thermal status
  scripts\device.ps1 perf -Seconds 10   # reset, play for 10 s, then report
  scripts\device.ps1 tap 540 1800 | swipe 300 1500 800 1500 200 | back | home | resume
  scripts\device.ps1 pull-replay        # user://replay.json from the phone -> test\replays\phone-<time>.json
  scripts\device.ps1 uninstall
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)] [string] $Action,
  [Parameter(Position = 1, ValueFromRemainingArguments)] [string[]] $Rest,
  [switch] $Dump,
  [int] $Seconds = 0
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$adb = Join-Path 'C:\dev\toolchain\android-sdk\platform-tools' 'adb.exe'
if (-not (Test-Path $adb)) { $adb = 'adb' }

$presets = Get-Content (Join-Path $root 'export_presets.cfg') -Raw
$pkg = [regex]::Match($presets, 'package/unique_name="([^"]+)"').Groups[1].Value
$apk = [regex]::Match($presets, 'export_path="([^"]+\.apk)"').Groups[1].Value
if (-not $pkg) { throw "no package/unique_name in export_presets.cfg" }
$component = "$pkg/com.godot.game.GodotAppLauncher"
$outDir = Join-Path $root 'build\phone'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Adb { param([Parameter(ValueFromRemainingArguments)] $a) & $adb @a; if ($LASTEXITCODE -ne 0) { throw "adb $($a -join ' ') failed" } }
function Require-Device {
  $d = (& $adb devices) -split "`n" | Where-Object { $_ -match '\tdevice$' }
  if (-not $d) { throw "no phone connected over adb. Plug it in, unlock it, and accept the USB debugging prompt." }
}
## Same resolver as movie.ps1: winget puts ffmpeg on the USER PATH, which a shell only
## reads at start, so a long-running session has an installed ffmpeg it cannot see. A
## missing sheet is a silent loss here - the video still lands - so it is worth looking.
function Resolve-Ffmpeg {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $glob = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*-full_build\bin\ffmpeg.exe"
  $found = Get-ChildItem $glob -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.FullName }
  foreach ($p in ([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';')) {
    if ($p -and (Test-Path (Join-Path $p 'ffmpeg.exe'))) { return (Join-Path $p 'ffmpeg.exe') }
  }
  return ""
}

function Sheet($video, $sheet) {
  $ffmpeg = Resolve-Ffmpeg
  if ($ffmpeg) {
    & $ffmpeg -loglevel error -y -i $video -vf "fps=2,drawtext=fontfile='C\:/Windows/Fonts/consola.ttf':text='%{pts\:hms}':x=6:y=6:fontsize=26:fontcolor=white:box=1:boxcolor=black@0.5,scale=230:-1,tile=6x5" -frames:v 1 $sheet
    if (Test-Path $sheet) { Write-Host "   sheet: $sheet (one tile per half second)" }
  } else {
    Write-Host "   (no ffmpeg, so no contact sheet: winget install --id Gyan.FFmpeg --scope user)"
  }
}

Require-Device
switch ($Action.ToLower()) {
  'install' {
    $path = Join-Path $root $apk
    if (-not (Test-Path $path)) { throw "no APK at $path; export first" }
    Adb install -r -g $path
    Write-Host "installed $pkg"
  }
  'uninstall' { Adb uninstall $pkg }
  'launch' {
    Adb shell am start -W -S -n $component | Out-Null
    Write-Host "launched $component"
  }
  'log' {
    if ($Dump) { & $adb logcat -d -s godot } else { Write-Host "Ctrl+C to stop"; & $adb logcat -s godot }
  }
  'shot' {
    $f = Join-Path $outDir "$stamp.png"
    # exec-out to a FILE; piping the bytes through PowerShell corrupts them.
    & cmd /c "`"$adb`" exec-out screencap -p > `"$f`""
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $f) -or (Get-Item $f).Length -lt 1000) { throw "screencap failed" }
    Write-Host "shot: $f"
  }
  'record' {
    $secs = if ($Rest -and $Rest[0]) { [int]$Rest[0] } else { 20 }
    if ($secs -gt 180) { $secs = 180 }
    Adb shell screenrecord --time-limit $secs --bit-rate 8000000 /sdcard/rec.mp4
    $f = Join-Path $outDir "$stamp.mp4"
    Adb pull /sdcard/rec.mp4 $f | Out-Null
    Adb shell rm /sdcard/rec.mp4
    Write-Host "video: $f"
    Sheet $f (Join-Path $outDir "$stamp-sheet.png")
  }
  'perf' {
    if ($Seconds -gt 0) {
      Adb shell dumpsys gfxinfo $pkg reset | Out-Null
      Write-Host "play for $Seconds s..."
      Start-Sleep -Seconds $Seconds
    }
    $g = & $adb shell dumpsys gfxinfo $pkg
    $g | Select-String -Pattern 'Total frames|Janky|percentile|Number Missed Vsync|Number Slow' | ForEach-Object { Write-Host "   $($_.Line.Trim())" }
    Write-Host "   (gfxinfo instruments HWUI; if the frame count is tiny, read Engine.get_frames_per_second() from the game's own log instead)"
    $t = try { & $adb shell dumpsys thermalservice 2>$null } catch { @() }
    $t | Select-String -Pattern 'Thermal Status|mStatus|CPU|GPU|SKIN' | Select-Object -First 8 | ForEach-Object { Write-Host "   $($_.Line.Trim())" }
    $fps = & $adb logcat -d -s godot | Select-String -Pattern 'fps' | Select-Object -Last 3
    if ($fps) { $fps | ForEach-Object { Write-Host "   $($_.Line)" } }
  }
  'tap' { Adb shell input tap $Rest[0] $Rest[1] }
  'swipe' { Adb shell input swipe @Rest }
  'back' { Adb shell input keyevent KEYCODE_BACK }
  'home' { Adb shell input keyevent KEYCODE_HOME }
  'resume' { Adb shell am start -n $component | Out-Null }
  'pull-replay' {
    $dest = Join-Path $root "test\replays\phone-$stamp.json"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    # user:// on Android is the app's external files dir; run-as works for a debug build.
    $json = try { (& $adb shell run-as $pkg cat files/replay.json 2>$null) -join "`n" } catch { "" }
    if ($json -and $json.Trim().StartsWith('[')) {
      [System.IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
      & $adb pull "/sdcard/Android/data/$pkg/files/replay.json" $dest
    }
    if (Test-Path $dest) { Write-Host "replay: $dest" } else { throw "no replay.json on the phone; launch with a `record` user arg first" }
  }
  'size' { Adb shell wm size; Adb shell wm density }
  default { throw "unknown action $Action. See the header of this script." }
}
