<#
.SYNOPSIS
  The phone, over adb. Install, launch, read the log, screenshot, record, measure, poke.

.DESCRIPTION
  There is one phone and several sessions. Every action here claims it first through
  C:\dev\gamedev-notes\scripts\phone.ps1, and every action renews that claim as it runs, so
  two games cannot install over each other or read each other's logcat. When another game
  holds it this script writes a `PHONE TEST OWED` line into NOTES.md and **exits 75** without
  touching adb: that is not a failure to retry, it is an answer. Finish the desk pass and
  come back to the phone. End a phone pass with `release`; a forgotten lease expires in 20
  minutes on its own. Never call adb directly - a raw adb call is the one path the lease
  cannot see.

.EXAMPLE
  scripts\device.ps1 install            # adb install -r -g build\<slug>.apk (and claims the phone)
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
  scripts\device.ps1 release            # give the phone back at the end of the pass
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position = 0)] [string] $Action,
  [Parameter(Position = 1, ValueFromRemainingArguments)] [string[]] $Rest,
  [switch] $Dump,
  [int] $Seconds = 0
)
$ErrorActionPreference = 'Stop'

## Native commands write progress and warnings to STDERR, and `$ErrorActionPreference =
## 'Stop'` turns any of that into a terminating error BEFORE the exit-code check below it
## runs. adb is a heavy offender: "daemon not running; starting now", "Performing Streamed
## Install" and screenrecord's own progress all go to stderr on a completely successful run.
## Redirection does not save it - the text moves and the ErrorRecord still throws.
function Native([scriptblock]$Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}
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

function Adb { param([Parameter(ValueFromRemainingArguments)] $a) Native { & $adb @a }; if ($LASTEXITCODE -ne 0) { throw "adb $($a -join ' ') failed" } }
function Require-Device {
  $d = (Native { & $adb devices }) -split "`n" | Where-Object { $_ -match '	device$' }
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

## The phone is one device shared by every running session, so it is claimed before use and
## given back after. The lease lives in the knowledge base, not here, because the games share
## the phone, not the code. A missing knowledge base must never stop a game testing on the
## phone, so that case warns once and runs unleased.
$slug = Split-Path $root -Leaf
$phoneScript = 'C:\dev\gamedev-notes\scripts\phone.ps1'
$script:PhoneHolder = 'another game'
function Invoke-Phone([string] $PhoneAction, [int] $Minutes = 20) {
  if (-not (Test-Path -LiteralPath $phoneScript)) {
    Write-Host "   (no $phoneScript, so the phone is used unleased - another session could be on it)" -ForegroundColor Yellow
    return 0
  }
  # A child process's Write-Host arrives here as pipeline strings, so the output is captured
  # and re-printed rather than passed through, which is also how the holder's name is read.
  $out = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript $PhoneAction -Owner $slug -Minutes $Minutes 2>&1 }
  $code = $LASTEXITCODE
  foreach ($l in @($out)) { Write-Host "   $l" }
  $m = [regex]::Match(($out -join "`n"), 'held by ([^\s,]+)')
  if ($m.Success) { $script:PhoneHolder = $m.Groups[1].Value }
  return $code
}

## A refused phone pass that leaves no trace is a phone pass that silently never happens.
## The line is plain text at the start of a line so scripts\doctor.ps1 (Test-PhoneDebt) can
## see it in any game, and only one is written: a pass retried five times is one debt, not
## five. AppendAllText, never Get-Content/Set-Content, which rewrites the whole file and
## mangles non-ASCII bytes.
function Write-PhoneDebt([string] $What) {
  $notes = Join-Path $root 'NOTES.md'
  if (-not (Test-Path -LiteralPath $notes)) {
    Write-Host "   (no NOTES.md here, so the owed phone test is not recorded anywhere)" -ForegroundColor Yellow
    return
  }
  $text = [System.IO.File]::ReadAllText($notes)
  if ($text -match '(?m)^PHONE TEST OWED') {
    Write-Host '   NOTES.md already records a phone test owed, so no second line was added.'
    return
  }
  $line = "PHONE TEST OWED $(Get-Date -Format 'yyyy-MM-dd HH:mm'): device.ps1 $What refused, phone held by $($script:PhoneHolder). Rerun the phone pass and change this prefix to PHONE TEST DONE."
  $lead = if ($text.EndsWith("`n")) { '' } else { "`n" }
  [System.IO.File]::AppendAllText($notes, "$lead$line`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "   wrote to NOTES.md: $line"
}

function Sheet($video, $sheet) {
  $ffmpeg = Resolve-Ffmpeg
  if ($ffmpeg) {
    Native { & $ffmpeg -loglevel error -y -i $video -vf "fps=2,drawtext=fontfile='C\:/Windows/Fonts/consola.ttf':text='%{pts\:hms}':x=6:y=6:fontsize=26:fontcolor=white:box=1:boxcolor=black@0.5,scale=230:-1,tile=6x5" -frames:v 1 $sheet }
    if (Test-Path $sheet) { Write-Host "   sheet: $sheet (one tile per half second)" }
  } else {
    Write-Host "   (no ffmpeg, so no contact sheet: winget install --id Gyan.FFmpeg --scope user)"
  }
}

$act = $Action.ToLower()

# The device check comes FIRST and the claim second, on purpose. "No phone connected" and
# "another game has the phone" are different reports and want different answers, and claiming
# before the check would leave a lease on a machine with nothing plugged in.
# `release` is the exception and skips the check: the phone being unplugged is the commonest
# reason a pass ends, and a lease you cannot give back because the cable came out is a lease
# the next game waits twenty minutes for.
if ($act -ne 'release') {
  Require-Device
  # A live logcat blocks until Ctrl+C, so it books the phone for an hour. Everything else is
  # seconds long and renews the default 20 minutes as it goes.
  $minutes = if ($act -eq 'log' -and -not $Dump) { 60 } else { 20 }
  if ((Invoke-Phone 'claim' $minutes) -eq 75) {
    Write-PhoneDebt $act
    exit 75
  }
}

switch ($act) {
  'release' { Invoke-Phone 'release' | Out-Null }
  'install' {
    $path = Join-Path $root $apk
    if (-not (Test-Path $path)) { throw "no APK at $path; export first" }
    Adb install -r -g $path
    Write-Host "installed $pkg"
  }
  'uninstall' { Adb uninstall $pkg }
  'launch' {
    # **Quoted, because PowerShell binds parameters before it hands anything to
    # adb.** `-W` prefix-matches the common parameters -WarningAction and
    # -WarningVariable, so an unquoted `-W` here is an AmbiguousParameter error
    # against device.ps1 itself and adb is never reached. `launch` had never
    # once worked. Quoting makes each flag a value rather than a parameter name;
    # any adb flag starting with w, v, d or c needs the same treatment.
    Adb shell am start '-W' '-S' '-n' $component | Out-Null
    Write-Host "launched $component"
  }
  'log' {
    if ($Dump) { & $adb logcat -d -s godot } else { Write-Host "Ctrl+C to stop"; & $adb logcat -s godot }
  }
  'shot' {
    $f = Join-Path $outDir "$stamp.png"
    # exec-out to a FILE; piping the bytes through PowerShell corrupts them.
    Native { & cmd /c "`"$adb`" exec-out screencap -p > `"$f`"" }
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
    # **SurfaceFlinger, not gfxinfo.** `dumpsys gfxinfo` instruments HWUI - the
    # Android View hierarchy - and a Godot game draws to its own SurfaceView
    # instead. Measured on wildform: gfxinfo reported `Total frames rendered: 0`
    # and percentiles of 4950 ms, which is its no-data sentinel, after a run that
    # had just drawn two thousand frames. Every percentile this studio has ever
    # printed for a Godot game came from that, and meant nothing.
    #
    # `--timestats` measures the layer the game actually presents to, so the
    # numbers below are the frames that reached the panel.
    Adb shell dumpsys SurfaceFlinger --timestats -disable -clear | Out-Null
    Adb shell dumpsys SurfaceFlinger --timestats -enable | Out-Null
    if ($Seconds -gt 0) {
      Write-Host "play for $Seconds s..."
      Start-Sleep -Seconds $Seconds
    } else {
      Write-Host "measuring for 20 s (pass -Seconds N for longer)..."
      Start-Sleep -Seconds 20
    }
    $ts = (Native { & $adb shell dumpsys SurfaceFlinger --timestats -dump }) -join "`n"
    Adb shell dumpsys SurfaceFlinger --timestats -disable | Out-Null

    # The game's own layer, and only it: SurfaceFlinger reports every layer on
    # the device and the wallpaper is not what we are measuring.
    $block = ($ts -split '(?m)^layerName = ') | Where-Object { $_ -match [regex]::Escape($pkg) } | Select-Object -First 1
    if (-not $block) {
      Write-Host "   no SurfaceFlinger layer for $pkg - is the game in the foreground?" -ForegroundColor Yellow
    } else {
      foreach ($k in 'totalFrames', 'droppedFrames', 'jankyFrames', 'averageFPS') {
        if ($block -match "(?m)^\s*$k\s*=\s*(\S+)") { Write-Host ("   {0,-14} {1}" -f $k, $Matches[1]) }
      }
      # Percentiles, derived from the present-to-present histogram. A frame time
      # is the gap between one frame reaching the panel and the next, which is
      # the number a player feels - not how long the CPU spent on it.
      if ($block -match '(?s)present2present histogram is as below:\s*(.+?)
\w') {
        $pairs = [regex]::Matches($Matches[1], '(\d+)ms=(\d+)')
        $total = 0; foreach ($m in $pairs) { $total += [int]$m.Groups[2].Value }
        if ($total -gt 0) {
          $line = @()
          foreach ($q in 50, 90, 95, 99) {
            $want = [math]::Ceiling($total * $q / 100.0); $run = 0; $ms = '?'
            foreach ($m in $pairs) {
              $run += [int]$m.Groups[2].Value
              if ($run -ge $want) { $ms = $m.Groups[1].Value; break }
            }
            $line += "p$q ${ms}ms"
          }
          Write-Host "   frame time     $($line -join '   ')  over $total frames"
          Write-Host "   (a 120 Hz panel is 8 ms a frame; 60 Hz is 16)"
        }
      }
    }

    $t = try { & $adb shell dumpsys thermalservice 2>$null } catch { @() }
    $t | Select-String -Pattern 'Thermal Status|mName=AP|mName=SKIN|mName=BAT' | Select-Object -First 6 | ForEach-Object { Write-Host "   $($_.Line.Trim())" }
    Write-Host "   (Thermal Status 0 is no throttling; 1+ means the phone is backing off)"
  }
  'tap' { Adb shell input tap $Rest[0] $Rest[1] }
  'swipe' { Adb shell input swipe @Rest }
  # `back N` sends N presses in ONE input call, a few ms apart, which is the only
  # way to exercise a game's double-press debounce: separate device.ps1 calls
  # land about two seconds apart (measured on snowball: 2.3 s), so two of them
  # test the one-layer-per-press rule and never the debounce.
  'back' { $n = if ($Rest.Count -gt 0) { [Math]::Max(1, [int]$Rest[0]) } else { 1 }; Adb shell input keyevent (@('KEYCODE_BACK') * $n) }
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
      Native { & $adb pull "/sdcard/Android/data/$pkg/files/replay.json" $dest }
    }
    if (Test-Path $dest) { Write-Host "replay: $dest" } else { throw "no replay.json on the phone; launch with a `record` user arg first" }
  }
  'size' { Adb shell wm size; Adb shell wm density }
  default { throw "unknown action $Action. See the header of this script." }
}
