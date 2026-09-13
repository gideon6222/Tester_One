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
                                        # AND to the shared log every game reads (below)
  scripts\device.ps1 tap 540 1800 | swipe 300 1500 800 1500 200 | back | home | resume
  scripts\device.ps1 pull-replay        # user://replay.json from the phone -> test\replays\phone-<time>.json
  scripts\device.ps1 uninstall
  scripts\device.ps1 release            # give the phone back at the end of the pass
  scripts\device.ps1 perf -Phone floor  # any action, on the floor phone (the S22+) instead of his

  Every `perf` reading also goes into the log every game shares, C:\dev\.phone-log.tsv,
  because THERMAL CARRIES BETWEEN GAMES: the handset does not cool down when the lease
  changes hands, and a reading taken soon after another game's soak is a warm start rather
  than a baseline. Read it BEFORE claiming, with the read-only, lease-free action:

  powershell -File C:\dev\gamedev-notes\scripts\phone.ps1 history
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
  [int] $Soak = 0,
  ## WHICH PHONE (DEVICE.md). `main` is his Galaxy S26 Ultra, `floor` is the Galaxy S22+ the
  ## low tier is aimed at. Each role has its own lease and its own serial, read from
  ## C:\dev\.studio\phones.json through phone.ps1, and adb is pointed at that serial through
  ## ANDROID_SERIAL so two handsets on one cable never get each other's install. A role with
  ## no serial recorded means whatever single device is attached, as it always did.
  [string] $Phone = 'main'
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
  $d = @((Native { & $adb devices }) -split "`n" | Where-Object { $_ -match '	device$' })
  if (-not $d) { throw "no phone connected over adb. Plug it in, unlock it, and accept the USB debugging prompt." }
  if ($env:ANDROID_SERIAL) {
    if (-not ($d | Where-Object { $_ -match ('^' + [regex]::Escape($env:ANDROID_SERIAL) + '\s') })) {
      throw "the $Phone phone ($env:ANDROID_SERIAL) is not attached; adb sees: $(($d | ForEach-Object { ($_ -split '\s')[0] }) -join ', ')"
    }
  } elseif ($d.Count -gt 1) {
    throw "$($d.Count) phones are attached and the $Phone role has no serial in C:\dev\.studio\phones.json, so adb cannot tell which one you mean. Record the serial there (phone.ps1 devices prints it)."
  }
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
if (Test-Path -LiteralPath $phoneScript) {
  $roleSerial = (Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript serial -Phone $Phone 2>$null }) -join ''
  if ($roleSerial.Trim()) { $env:ANDROID_SERIAL = $roleSerial.Trim() }
}
function Invoke-Phone([string] $PhoneAction, [int] $Minutes = 20) {
  if (-not (Test-Path -LiteralPath $phoneScript)) {
    Write-Host "   (no $phoneScript, so the phone is used unleased - another session could be on it)" -ForegroundColor Yellow
    return 0
  }
  # A child process's Write-Host arrives here as pipeline strings, so the output is captured
  # and re-printed rather than passed through, which is also how the holder's name is read.
  $out = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript $PhoneAction -Owner $slug -Minutes $Minutes -Phone $Phone 2>&1 }
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
  if ($Phone -ne 'main') { $Line = "[$Phone phone] $Line" }
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

## The same reading again, into the log every game shares (C:\dev\.phone-log.tsv).
##
## NOTES.md above is this game's record and answers "how does MY game run". This answers a
## question no single game's notes can: THERMAL CARRIES BETWEEN GAMES. The handset does not
## cool down because the lease changed hands, so a reading taken minutes after another game's
## ten-minute soak is a warm start rather than a baseline, and it looks exactly like a
## regression in a game that has none. `scripts\phone.ps1 history` reads this back, which is
## what a session does BEFORE claiming.
##
## Swallow-everything, for the reason phone.ps1's own guard gives: a notebook that cannot be
## written must never change what happens to the phone. And under the existing rule at the
## top of this file, a MISSING KNOWLEDGE BASE NEVER STOPS A PHONE PASS - it is simply quiet.
function Write-SharedPhoneLog([string] $Detail) {
  try {
    $logScript = 'C:\dev\gamedev-notes\scripts\phone-log.ps1'
    if (Test-Path -LiteralPath $logScript) {
      if ($Phone -ne 'main') { $Detail = "[$Phone phone] $Detail" }
      & $logScript append -Owner $slug -Event 'perf' -Detail $Detail *> $null
    }
  } catch {
    # Deliberately empty. See the header above.
  }
}

## One reading, as one line for the shared log: the numbers a later session needs to judge
## whether the handset it is about to measure was hot.
function Format-SharedReading($Reading, [int] $Therm, [string] $Phase) {
  # averageFPS is absent whenever SurfaceFlinger did not report it, and a hashtable returns
  # nothing rather than failing for a key it does not have, so it is spelled out as unknown
  # instead of leaving a blank that reads like a zero.
  $fps = if ($Reading.ContainsKey('averageFPS')) { $Reading['averageFPS'] } else { '?' }
  "$Phase p50 $($Reading.p50) p95 $($Reading.p95) ms over $($Reading.Frames) frames, $fps fps avg, thermal $(Format-Thermal $Therm)"
}

## THE VISUALS READING: the game's own GPU milliseconds per frame, which is the number that
## transfers to a slower phone (DEVICE.md in the knowledge base, INDEX.md rule 18). The game
## prints `VISUALS tier=<t> gpu=<ms> cpu=<ms> fps=<n>` every ten seconds on a phone
## (src\game\visuals.gd, Main._report_visuals_line); the newest line in logcat is the reading.
## $null when the game has printed none, which is reported as unmeasured and never as zero.
function Read-VisualsLine {
  $lines = try { Native { & $adb logcat -d -s godot 2>$null } } catch { @() }
  $m = $null
  foreach ($l in @($lines)) {
    if ($l -match 'VISUALS tier=(\w+) gpu=([\d.]+) cpu=([\d.]+) fps=(\d+)') {
      $m = @{ Tier = $Matches[1]; Gpu = [double]$Matches[2]; Cpu = [double]$Matches[3]; Fps = [double]$Matches[4] }
    }
  }
  return $m
}

## The budgets come from the game's own src\game\visuals.gd rather than a copy here, so the
## suite that guards them and the reading that is judged by them read one table. Missing
## constants make the judgement say so rather than fall back to a number nobody wrote.
function Read-VisualsBudgets {
  $gd = Join-Path $root 'src\game\visuals.gd'
  if (-not (Test-Path -LiteralPath $gd)) { return $null }
  $t = [System.IO.File]::ReadAllText($gd)
  $out = @{}
  if ($t -match 'FLOOR_RATIO\s*:=\s*([\d.]+)') { $out.Ratio = [double]$Matches[1] }
  if ($t -match 'SOAK_FREE_DUTY\s*:=\s*([\d.]+)') { $out.Duty = [double]$Matches[1] }
  if ($t -match 'FRAME_MS_60\s*:=\s*([\d.]+)') { $out.Frame = [double]$Matches[1] }
  if ($t -match 'BUDGET_MS\s*:=\s*\{([^}]*)\}') {
    foreach ($pair in [regex]::Matches($Matches[1], '"(\w+)"\s*:\s*([\d.]+)')) { $out[$pair.Groups[1].Value] = [double]$pair.Groups[2].Value }
  }
  if (-not $out.ContainsKey('Ratio') -or -not $out.ContainsKey('low')) { return $null }
  return $out
}

## Prints and returns the visuals judgement as one line for NOTES.md and the shared log.
function Show-Visuals {
  $v = Read-VisualsLine
  if ($null -eq $v) {
    Write-Host "   visuals        no VISUALS line in logcat, so the GPU cost is unmeasured (a game built before src\game\visuals.gd prints none)" -ForegroundColor Yellow
    return "visuals unmeasured"
  }
  $b = Read-VisualsBudgets
  $duty = $v.Gpu * $v.Fps / 1000.0
  $line = "visuals {0}  gpu {1:n2} ms  cpu {2:n2} ms  at {3:n0} fps  duty {4:n0}%" -f $v.Tier, $v.Gpu, $v.Cpu, $v.Fps, ($duty * 100)
  Write-Host "   $line"
  if ($null -eq $b) {
    Write-Host "   (no budgets readable from src\game\visuals.gd, so the reading is not judged)" -ForegroundColor Yellow
    return $line
  }
  $parts = @()
  if ($Phone -eq 'floor') {
    # ON the floor phone there is nothing to predict: the question is whether this tier fits
    # a 60 fps frame with 20% headroom, and low is the tier that must.
    $limit = $b.Frame * 0.8
    $parts += if ($v.Gpu -le $limit) { ("{0:n2} ms fits a 60 fps frame on the floor phone with headroom (limit {1:n1} ms)" -f $v.Gpu, $limit) } elseif ($v.Tier -eq 'low') { ("{0:n2} ms on low MISSES the floor phone's frame (limit {1:n1} ms); low goes no lower, so the floor is unmet for this game (INDEX.md rule 18)" -f $v.Gpu, $limit) } else { ("{0:n2} ms is over the floor phone's frame on {1}, which is expected; low is the tier that must fit" -f $v.Gpu, $v.Tier) }
    $parts += if ($duty -le $b.Duty + 0.0001) { "no soak owed at this duty" } else { "duty over $($b.Duty * 100)%, so perf -Soak 10 is owed once for this build" }
    $judge = $parts -join '; '
    $color = if ($judge -match 'MISSES') { 'Yellow' } else { 'Green' }
    Write-Host "   $judge" -ForegroundColor $color
    return "$line; $judge"
  }
  if ($b.ContainsKey($v.Tier)) {
    $budget = $b[$v.Tier]
    $parts += if ($v.Gpu -le $budget) { "within the $($v.Tier) budget of $budget ms" } else { "OVER the $($v.Tier) budget of $budget ms" }
  }
  if ($v.Tier -eq 'low') {
    $floor = $v.Gpu * $b.Ratio
    $parts += if ($floor -le $b.Frame) { ("predicts {0:n1} ms on the floor phone, inside a 60 fps frame" -f $floor) } else { ("predicts {0:n1} ms on the floor phone, which MISSES 60 fps; low goes no lower, so the floor is unmet for this game (INDEX.md rule 18)" -f $floor) }
  }
  $parts += if ($duty -le $b.Duty + 0.0001) { "no soak owed at this duty" } else { "duty over $($b.Duty * 100)%, so perf -Soak 10 is owed once for this build" }
  $judge = $parts -join '; '
  $color = if ($judge -match 'OVER|MISSES') { 'Yellow' } else { 'Green' }
  Write-Host "   $judge" -ForegroundColor $color
  return "$line; $judge"
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
    # The game's own GPU cost, judged against its tier's budget. This is the reading that
    # says whether a ten-minute soak is owed at all, and what the floor phone would see.
    $visuals = Show-Visuals

    if ($Soak -le 0) {
      if ($first.Found) {
        Write-PhoneReading ("$(Get-Date -Format 'yyyy-MM-dd HH:mm')  spot     p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm); $visuals")
        Write-SharedPhoneLog ((Format-SharedReading $first $firstTherm 'spot') + "; $visuals")
      }
      Write-Host ""
      if ($visuals -match 'soak 10 is owed') {
        Write-Host "   For the throttling answer, run: scripts\device.ps1 perf -Soak 10"
      } else {
        Write-Host "   No soak is owed at this duty cycle (DEVICE.md). Run perf -Soak 10 only if the reading above says so."
      }
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
      Write-PhoneReading ("$stampNow  opening  p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm); $visuals")
    }
    if ($second.Found) {
      Write-PhoneReading ("$stampNow  +$Soak min  p50 $($second.p50) p90 $($second.p90) p95 $($second.p95) p99 $($second.p99) ms over $($second.Frames) frames, thermal $(Format-Thermal $secondTherm)")
    }
    # Into the shared log, both ends of the soak. The SECOND reading is the one that tells the
    # next session what state it is inheriting: a handset left at MODERATE after ten minutes
    # of play is not a baseline for anybody for a while.
    if ($first.Found) { Write-SharedPhoneLog (Format-SharedReading $first $firstTherm 'opening') }
    if ($second.Found) { Write-SharedPhoneLog (Format-SharedReading $second $secondTherm "after $Soak min of play") }

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
  # An arbitrary adb shell command UNDER THE LEASE, for a question none of the actions above
  # asks. Still never a bare adb call: the claim, the renewal and the log all happen first.
  'shell' { Native { & $adb shell @Rest } }
  # The handset's own facts, for DEVICE.md in the knowledge base: size, density, the display
  # modes and refresh rates, and the insets (cutout, status bar, gesture bar) in pixels. One
  # call, read-only, so a new phone gets a profile in a minute rather than a session.
  'profile' {
    Write-Host "model:   $((Native { & $adb shell getprop ro.product.model }) -join '') ($((Native { & $adb shell getprop ro.product.device }) -join ''))"
    Write-Host "android: $((Native { & $adb shell getprop ro.build.version.release }) -join '') (SDK $((Native { & $adb shell getprop ro.build.version.sdk }) -join '')), security patch $((Native { & $adb shell getprop ro.build.version.security_patch }) -join '')"
    Write-Host "soc:     $((Native { & $adb shell getprop ro.soc.model }) -join '') / $((Native { & $adb shell getprop ro.hardware }) -join '')"
    Write-Host "gpu:     $((Native { & $adb shell getprop ro.hardware.egl }) -join '')  vulkan feature level $((Native { & $adb shell getprop ro.hardware.vulkan }) -join '')"
    Adb shell wm size; Adb shell wm density
    Write-Host "display modes:"
    (Native { & $adb shell dumpsys display }) | Where-Object { $_ -match 'DisplayMode\{|mActiveModeId|mDefaultModeId|refreshRate=|mRefreshRate' } | Select-Object -First 12 | ForEach-Object { Write-Host "   $($_.Trim())" }
    Write-Host "insets and cutout (window pixels):"
    (Native { & $adb shell dumpsys window displays }) | Where-Object { $_ -match 'DisplayCutout|cutout|statusBars|navigationBars|mandatorySystemGestures|systemGestures|displayCutout|tappableElement' } | Select-Object -First 40 | Where-Object { $_ -notmatch "overrideConfig=|HideDisplayCutout|initCutout|cutoutPathParserInfo={CutoutPathParserInfo{displayWidth=1080 displayHeight=2340 physicalDisplayWidth=1440" } | ForEach-Object { Write-Host "   $($_.Trim())" }
    Write-Host "thermal now: $(Format-Thermal (Get-ThermalStatus))"
    Write-Host "(record these in C:\dev\gamedev-notes\DEVICE.md when the phone is new or its settings changed)"
  }
  # Switch the visuals tier on the phone and relaunch, for a reading per tier. Writes the
  # same user://visuals.json the settings screen writes, through run-as, which a debug build
  # allows. A release build refuses run-as, and the tier is then changed on the screen.
  'tier' {
    $tier = if ($Rest.Count -gt 0) { "$($Rest[0])".ToLower() } else { '' }
    if ($tier -notin @('low', 'medium', 'high')) { throw "tier low|medium|high" }
    # Piped through stdin rather than quoted on the command line: every layer between here
    # and the phone's sh (PowerShell, adb, the remote shell) strips a level of quoting, and
    # the first version of this landed `{tier:high}` on the phone, which the game refused.
    # So the file is written here, pushed to the phone's scratch dir, and copied in under the
    # app's own uid, with no quoting anywhere on the way.
    $json = '{"tier":"' + $tier + '"}'
    $local = Join-Path $outDir 'visuals.json'
    [System.IO.File]::WriteAllText($local, $json, (New-Object System.Text.UTF8Encoding($false)))
    Adb push $local /data/local/tmp/visuals.json | Out-Null
    # `files/` is created by the app on its first run, so on a fresh install it is not there yet.
    Native { & $adb shell run-as $pkg mkdir -p files }
    Native { & $adb shell run-as $pkg cp /data/local/tmp/visuals.json files/visuals.json }
    if ($LASTEXITCODE -ne 0) { throw "run-as $pkg refused, which means this is not a debug build; pick the tier on the settings screen instead" }
    $back = (Native { & $adb shell run-as $pkg cat files/visuals.json }) -join ''
    if ($back.Trim() -ne $json) { throw "the tier file on the phone reads '$back', not '$json'; the quoting was eaten somewhere on the way" }
    Adb shell am start '-W' '-S' '-n' $component | Out-Null
    Write-Host "visuals tier $tier written and $pkg relaunched; give it ten seconds, then perf reads the VISUALS line"
  }
  default { throw "unknown action $Action. See the header of this script." }
}
