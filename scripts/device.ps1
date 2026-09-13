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
  scripts\device.ps1 perf -Soak 10      # THE THROTTLING ANSWER: read, play 10 min, read again,
                                        # judge both against POLISH, and write them to NOTES.md
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
  [int] $Seconds = 0,
  ## Minutes of play between an opening reading and a second one. The whole point is that
  ## ONE lease covers both: the throttling question is "is the p95 after ten minutes worse
  ## than the p95 at the start", and two separate device.ps1 calls cannot answer it because
  ## the phone can change hands in between.
  [int] $Soak = 0
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

## ONE READING: reset SurfaceFlinger's stats, wait, and read back the percentiles for THIS
## game's layer.
##
## **SurfaceFlinger, not gfxinfo.** `dumpsys gfxinfo` instruments HWUI - the Android View
## hierarchy - and a Godot game draws to its own SurfaceView instead. Measured on wildform:
## gfxinfo reported `Total frames rendered: 0` and percentiles of 4950 ms, which is its
## no-data sentinel, after a run that had just drawn two thousand frames. Every percentile
## this studio ever printed for a Godot game came from that, and meant nothing.
##
## Returns a hashtable rather than printing, because the soak needs to compare two of these
## and a function that only prints can only be read by a human. `Found` is false when the
## game's layer was not in the dump at all - the game was not in the foreground, or the
## screen was off - and a false there must never be reported as a zero.
function Measure-Surface([int] $ForSeconds) {
  Adb shell dumpsys SurfaceFlinger --timestats -disable -clear | Out-Null
  Adb shell dumpsys SurfaceFlinger --timestats -enable | Out-Null
  Write-Host "   measuring for $ForSeconds s..."
  Start-Sleep -Seconds $ForSeconds
  $ts = (Native { & $adb shell dumpsys SurfaceFlinger --timestats -dump }) -join "`n"
  Adb shell dumpsys SurfaceFlinger --timestats -disable | Out-Null

  $out = @{ Found = $false; Frames = 0 }
  # The game's own layer, and only it: SurfaceFlinger reports every layer on the device and
  # the wallpaper is not what we are measuring.
  $block = ($ts -split '(?m)^layerName = ') | Where-Object { $_ -match [regex]::Escape($pkg) } | Select-Object -First 1
  if (-not $block) { return $out }

  foreach ($k in 'totalFrames', 'droppedFrames', 'jankyFrames', 'averageFPS') {
    if ($block -match "(?m)^\s*$k\s*=\s*(\S+)") { $out[$k] = $Matches[1] }
  }
  # Percentiles, derived from the present-to-present histogram. A frame time is the gap
  # between one frame reaching the panel and the next, which is the number a player feels -
  # not how long the CPU spent on it.
  if ($block -match '(?s)present2present histogram is as below:\s*(.+?)
\w') {
    $pairs = [regex]::Matches($Matches[1], '(\d+)ms=(\d+)')
    $total = 0; foreach ($m in $pairs) { $total += [int]$m.Groups[2].Value }
    if ($total -gt 0) {
      $out.Found = $true
      $out.Frames = $total
      foreach ($q in 50, 90, 95, 99) {
        $want = [math]::Ceiling($total * $q / 100.0); $run = 0
        foreach ($m in $pairs) {
          $run += [int]$m.Groups[2].Value
          if ($run -ge $want) { $out["p$q"] = [int]$m.Groups[1].Value; break }
        }
      }
    }
  }
  return $out
}

function Show-Surface($r) {
  if (-not $r.Found) {
    Write-Host "   no SurfaceFlinger layer for $pkg - is the game in the foreground?" -ForegroundColor Yellow
    return
  }
  foreach ($k in 'totalFrames', 'droppedFrames', 'jankyFrames', 'averageFPS') {
    if ($r.ContainsKey($k)) { Write-Host ("   {0,-14} {1}" -f $k, $r[$k]) }
  }
  $line = @(); foreach ($q in 50, 90, 95, 99) { $line += "p$q $($r["p$q"])ms" }
  Write-Host "   frame time     $($line -join '   ')  over $($r.Frames) frames"
  Write-Host "   (a 120 Hz panel is 8 ms a frame; 60 Hz is 16)"
}

## Android's thermal status as a NUMBER, because the whole question is whether it got worse.
## 0 NONE, 1 LIGHT, 2 MODERATE, 3 SEVERE, 4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN. Returns -1 when
## the dump could not be read or did not name a status, which is not the same as 0 and must
## never be printed as one.
function Get-ThermalStatus {
  $t = try { (Native { & $adb shell dumpsys thermalservice 2>$null }) -join "`n" } catch { "" }
  if ($t -match '(?im)Thermal\s+Status\s*[:=]?\s*(\d+)') { return [int]$Matches[1] }
  return -1
}

function Format-Thermal([int] $Status) {
  if ($Status -lt 0) { return 'unreadable' }
  $names = @('NONE', 'LIGHT', 'MODERATE', 'SEVERE', 'CRITICAL', 'EMERGENCY', 'SHUTDOWN')
  if ($Status -lt $names.Count) { return "$Status ($($names[$Status]))" }
  return "$Status"
}

## THE SHARED RECORD. A reading that lives only in one session's scrollback is a reading the
## next session has to take again, on the same one phone, and that is the whole reason this
## soak exists.
##
## Append only, and with the same writer as Write-PhoneDebt above - AppendAllText and UTF8
## with no BOM, never Get-Content/Set-Content, which rewrites the whole file and mangles
## non-ASCII bytes. Appending rather than inserting under the heading is deliberate: NOTES.md
## is open in other sessions, and adding a line at the end can never lose someone else's
## paragraph. The cost is that `## Phone readings` has to stay the LAST heading in the file,
## which is where setup\game-stubs\godot-NOTES.md puts it.
function Write-PhoneReading([string] $Line) {
  $notes = Join-Path $root 'NOTES.md'
  if (-not (Test-Path -LiteralPath $notes)) {
    Write-Host "   (no NOTES.md here, so this reading is recorded nowhere and the next session will take it again)" -ForegroundColor Yellow
    return
  }
  $text = [System.IO.File]::ReadAllText($notes)
  $add = ""
  if ($text -notmatch '(?m)^## Phone readings\s*$') { $add += "`n## Phone readings`n`n" }
  $lead = if ($text.EndsWith("`n") -or $add -ne "") { '' } else { "`n" }
  [System.IO.File]::AppendAllText($notes, "$lead$add$Line`n", (New-Object System.Text.UTF8Encoding($false)))
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
  # A soak books the phone for the whole run up front. The two readings are 20 s each and the
  # sleep between them is the soak, so the claim has to outlast all three or the lease expires
  # mid-measurement and another session takes the handset out from under the second reading -
  # which does not fail, it just quietly measures a different game.
  $minutes = if ($act -eq 'log' -and -not $Dump) { 60 } elseif ($act -eq 'perf' -and $Soak -gt 0) { $Soak + 5 } else { 20 }
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
    # `--timestats` measures the layer the game actually presents to, so these are the frames
    # that reached the panel. See Measure-Surface for why it is never gfxinfo.
    $window = if ($Seconds -gt 0) { $Seconds } else { 20 }

    # --- the opening reading ------------------------------------------------
    if ($Soak -gt 0) { Write-Host "opening reading" }
    $first = Measure-Surface $window
    Show-Surface $first
    $firstTherm = Get-ThermalStatus
    Write-Host "   thermal        $(Format-Thermal $firstTherm)"
    Write-Host "   (0 is no throttling; 1+ means the phone is backing off)"

    if ($Soak -le 0) {
      if ($first.Found) {
        Write-PhoneReading ("$(Get-Date -Format 'yyyy-MM-dd HH:mm')  spot     p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm)")
      }
      Write-Host ""
      Write-Host "   For the throttling answer POLISH asks for, run: scripts\device.ps1 perf -Soak 10"
      break
    }

    # --- the soak -----------------------------------------------------------
    # THE THROTTLING QUESTION, asked once so no future session has to ask it again. Keep
    # playing: the phone only heats up if the GPU is doing something, and a soak spent on a
    # paused game measures a phone at rest and calls it a pass.
    Write-Host ""
    Write-Host "soaking for $Soak min - KEEP PLAYING, screen on, game in the foreground"
    $end = (Get-Date).AddMinutes($Soak)
    while ((Get-Date) -lt $end) {
      $left = [int][math]::Ceiling(($end - (Get-Date)).TotalMinutes)
      Write-Host "   $left min left..."
      Start-Sleep -Seconds ([math]::Min(60, [math]::Max(1, ($end - (Get-Date)).TotalSeconds)))
      # Renew inside the loop as well as up front. A soak longer than the lease that only
      # claimed once would expire halfway and the second reading would be of whatever the
      # next session put on the screen.
      Invoke-Phone 'claim' ($Soak + 5) | Out-Null
    }

    Write-Host ""
    Write-Host "second reading, after $Soak min of play"
    $second = Measure-Surface $window
    Show-Surface $second
    $secondTherm = Get-ThermalStatus
    Write-Host "   thermal        $(Format-Thermal $secondTherm)"

    # --- the record ---------------------------------------------------------
    $stampNow = Get-Date -Format 'yyyy-MM-dd HH:mm'
    if ($first.Found) {
      Write-PhoneReading ("$stampNow  opening  p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm)")
    }
    if ($second.Found) {
      Write-PhoneReading ("$stampNow  +$Soak min  p50 $($second.p50) p90 $($second.p90) p95 $($second.p95) p99 $($second.p99) ms over $($second.Frames) frames, thermal $(Format-Thermal $secondTherm)")
    }

    # --- the verdict --------------------------------------------------------
    # **No layer, no verdict.** A missing SurfaceFlinger layer means nothing was measured,
    # and the one thing this must never do is print a reassuring zero for a reading that
    # never happened - which is exactly the gfxinfo failure that made every frame number in
    # this studio worthless until it was caught.
    Write-Host ""
    if (-not $first.Found -or -not $second.Found) {
      $which = if (-not $first.Found -and -not $second.Found) { 'Neither reading' } elseif (-not $first.Found) { 'The opening reading' } else { 'The second reading' }
      Write-Host "   NO VERDICT. $which found no SurfaceFlinger layer for $pkg, so nothing was measured." -ForegroundColor Yellow
      Write-Host "   Put the game in the foreground with the screen on and run it again. An unmeasured soak is not a pass."
      Write-Host ""
      Write-PhoneReading "$stampNow  NO VERDICT: $which found no SurfaceFlinger layer, so the throttling question is still open."
      break
    }

    # POLISH.md's three numbers, and all three have to hold.
    $budget = 16.7
    $drift = if ($first.p95 -gt 0) { ($second.p95 - $first.p95) / [double]$first.p95 * 100.0 } else { 0.0 }
    $faults = @()
    if ($first.p95 -gt $budget) { $faults += "the opening p95 is $($first.p95) ms, over the $budget ms 60 fps budget" }
    if ($second.p95 -gt $budget) { $faults += "the p95 after $Soak min is $($second.p95) ms, over the $budget ms 60 fps budget" }
    if ($drift -gt 20.0) { $faults += ("the p95 rose {0:n0}% over the soak ({1} -> {2} ms), past the 20% POLISH allows" -f $drift, $first.p95, $second.p95) }
    # A thermal status that could not be read is not a pass. LIGHT is the worst POLISH allows.
    if ($secondTherm -lt 0) { $faults += "the thermal status could not be read, so it is unknown rather than fine" }
    elseif ($secondTherm -gt 1) { $faults += "thermal reached $(Format-Thermal $secondTherm) after $Soak min, worse than the LIGHT that POLISH allows" }

    $verdict = if ($faults.Count -eq 0) {
      "PASS: p95 {0} -> {1} ms ({2:n0}% over {3} min, both under {4} ms), thermal {5}" -f $first.p95, $second.p95, $drift, $Soak, $budget, (Format-Thermal $secondTherm)
    } else {
      "FAIL: $($faults -join '; ')"
    }
    $color = if ($faults.Count -eq 0) { 'Green' } else { 'Red' }
    Write-Host "   THROTTLING VERDICT (POLISH.md, Performance and stability)" -ForegroundColor $color
    Write-Host "   $verdict" -ForegroundColor $color
    Write-Host ""
    Write-PhoneReading "$stampNow  verdict  $verdict"
    Write-Host "   Both readings and the verdict are in NOTES.md under '## Phone readings'."
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
