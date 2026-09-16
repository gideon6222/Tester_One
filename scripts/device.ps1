<#
.SYNOPSIS
  The phone, over adb. Install, launch, read the log, screenshot, record, measure, poke.

.DESCRIPTION
  There is one phone and several sessions. Every action here claims it first through
  C:\dev\gamedev-notes\scripts\phone.ps1, and every action renews that claim as it runs, so
  two games cannot install over each other or read each other's logcat. When another game
  holds it this script writes a `PHONE TEST OWED` line into NOTES.md, puts this game on the
  shared queue with what it came for, and **exits 75** without
  touching adb: that is not a failure to retry, it is an answer. Finish the desk pass and
  come back to the phone. End a phone pass with `release`; a forgotten lease expires in 20
  minutes on its own. Never call adb directly - a raw adb call is the one path the lease
  cannot see.

.EXAMPLE
  scripts\device.ps1 pass               # THE PHONE PASS. One claim, one release, one record.
                                        # install, launch, a 20 s reading on the default tier,
                                        # the log scanned for ERROR, a screenshot. It writes
                                        # build\last-phone-pass.json and a stamped line per
                                        # reading into NOTES.md under '## Phone readings'.
  scripts\device.ps1 pass -Visuals      # also switch to low, relaunch and take a second reading
  scripts\device.ps1 pass -Visuals -Phone floor   # where the low reading belongs (DEVICE.md)
  scripts\device.ps1 pass -Soak 10      # and the soak, but ONLY if the reading says one is owed
  scripts\device.ps1 pass -Show         # what the last pass found, without touching the phone

  WHAT THE PASS ASKS, AND WHAT IT DELIBERATELY DOES NOT, IS ONE TABLE AND IT IS NOT HERE:
  C:\dev\gamedev-notes\DEVICE.md, "The phone pass, and the only four questions the phone is
  for". Four questions only a handset can answer (GPU ms at the default tier, GPU ms on low on
  the floor phone, thermal over ten minutes when the duty says a soak is owed, and real touch
  with hit boxes, audio ducking and haptics), and a second table naming the desk test that
  answers everything else. Quote that table, never restate it (INDEX.md rule 10). The actions
  below are the parts the pass is assembled from and are still there for a question the pass
  does not ask.

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

  powershell -File C:\dev\gamedev-notes\scripts\phone.ps1 history   # what it has been asked
  powershell -File C:\dev\gamedev-notes\scripts\phone.ps1 wants     # whose turn it is
  powershell -File C:\dev\gamedev-notes\scripts\phone.ps1 thermal   # how warm it already is

  And when this script exits 75 because another game holds the handset, IT WRITES THIS GAME
  ONTO THAT QUEUE ITSELF, with what it came for, beside the NOTES.md debt line. There is
  nothing here for a session to remember: the board fills from the refusal that was already
  happening. Measured over 2026-09-13 to 2026-09-15, when joining the queue was an
  instruction in this header instead: 26 refusals in the shared log and not one want row.
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
  [string] $Phone = 'main',
  ## `pass` only. Also switch the game to the low tier, relaunch, and take a second reading.
  ## The low reading belongs on the floor phone (`-Phone floor`), where perf judges it against
  ## a 60 fps frame directly instead of predicting it by ratio (DEVICE.md).
  [switch] $Visuals,
  ## `pass` only. Print build\last-phone-pass.json and stop. Takes no lease, touches no handset.
  [switch] $Show
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

## WHICH BUILD A READING IS ABOUT, resolved once and written onto every line.
##
## `## Phone readings` in NOTES.md is append-only and grows for the life of the game, and until
## 2026-09-16 a line there carried a timestamp and nothing else - so a reader six weeks later
## could see that a reading was taken and not which build it was taken of. A reading that cannot
## be tied to a build cannot say whether the number moved, which is the only question anybody
## asks of a second reading. The version is the presets' own, the head is git's, and both are
## asked rather than trusted: a repo with no commits yet leaves the head empty rather than
## aborting, the fallback shape scripts\stamp.ps1 and scripts\deliver.ps1 both use.
$version = [regex]::Match($presets, 'version/name="([^"]+)"').Groups[1].Value
$head = ''
try { $head = (Native { & git -C $root rev-parse --short=7 HEAD 2>$null } | Out-String).Trim() } catch { }
$buildStamp = ''
try {
  $stampPath = Join-Path $root 'src\build_stamp.gd'
  if (Test-Path -LiteralPath $stampPath) {
    $buildStamp = [regex]::Match([System.IO.File]::ReadAllText($stampPath), 'SHA\s*:=\s*"([^"]*)"').Groups[1].Value
  }
} catch { }
$buildTag = (@(
    $(if ($version) { "v$version" } else { '' })
    $(if ($head) { $head } else { '' })
  ) | Where-Object { $_ }) -join ' '

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

## THE QUEUE ROW, WRITTEN BY THE CODE THAT WAS ALREADY RUNNING.
##
## `phone.ps1 wants` is the board a session reads before claiming, and `phone.ps1 want` is how
## a game gets onto it. Both shipped on 2026-09-15 and both work. What did not work was the
## part that asked a session to REMEMBER to join: the instruction sat in this script's own
## header and in INDEX.md, in front of the session at the exact moment it applied, and the
## compliance rate over 2026-09-13 to 2026-09-15 was 0 of 26 - twenty-six refusals in
## C:\dev\.phone-log.tsv and not a single want row. That is not carelessness, it is what a
## rule costs when the code that was already running could have done the thing itself.
##
## So the refusal writes the row. Everything a queue row needs is already here: the game is
## this repo, $Phone is the handset, $act is what the pass came for, and $script:PhoneHolder
## is who turned it away. ONE ROW PER REFUSAL - this runs from the single claim below and
## never from the soak's renewals, which is what keeps a retried pass one row and not five.
##
## A WANT IS A NOTE AND NOTHING ELSE. It never feeds phone.ps1's fair share, which only a
## `refused` line may trigger; writing wants automatically makes that separation matter far
## more than it did while the board was empty, so phone-tests.ps1 asserts it as a pair rather
## than trusting it.
##
## THE SAME SWALLOW-EVERYTHING GUARD AS Write-SharedPhoneLog, and for the harder reason: this
## runs on the path whose whole product is an exit code. A queue that cannot be written to must
## never turn "another game has the phone" into anything else, so every failure here is quiet
## and $LASTEXITCODE is saved and restored around it. The exit 75 below is not this function's
## to change.
function Write-PhoneWant([string] $What) {
  $keep = $LASTEXITCODE
  try {
    if (Test-Path -LiteralPath $phoneScript) {
      $note = "$What, refused while $($script:PhoneHolder) held it"
      $null = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript want -Owner $slug -Phone $Phone -Note $note 2>&1 }
      Write-Host "   put $slug on the queue for the $Phone phone: $note"
    }
  } catch {
    # Deliberately empty. See the header above.
  }
  $global:LASTEXITCODE = $keep
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
  # WHICH BUILD, on the line itself. See $buildTag above: a reading with no build behind it
  # cannot answer the only question a second reading is ever taken to answer.
  if ($buildTag) { $Line = "$Line  [$buildTag]" }
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
      # -Phone is the log's fifth column (2026-09-15). Thermal carries between games but not
      # between handsets, so a reading that does not say which phone it was taken on tells the
      # next session nothing: a soak on the floor S22+ says nothing about how warm his S26
      # Ultra is. The old habit of prefixing the detail text is gone with the column, which
      # `phone.ps1 history` reads back by name.
      & $logScript append -Owner $slug -Event 'perf' -Detail $Detail -Phone $Phone *> $null
    }
  } catch {
    # Deliberately empty. See the header above.
  }
}

## WHAT THE SHARED LOG ALREADY SAYS ABOUT THIS HANDSET, as a note to hang on this session's
## own reading. Empty string when the phone is cold, unknown, or the question cannot be asked.
##
## Thermal carries between games and nothing in THIS repo can see it: the handset does not cool
## down because the lease changed hands, so an opening reading taken minutes after another
## game's ten-minute soak is a warm start, and it looks exactly like a regression in a game that
## has none. `phone.ps1 thermal` reads the newest perf line in C:\dev\.phone-log.tsv and answers
## in one word. It is read-only and lease-free, so this costs nothing and changes nothing.
##
## THE SAME SWALLOW-EVERYTHING GUARD AS Write-SharedPhoneLog, and for the same reason: this is
## a label on a reading, never permission to take one. A missing knowledge base, a phone.ps1
## without the action, a child that throws - all answer '' and the reading proceeds exactly as
## it did before. $LASTEXITCODE is saved and restored because the caller's next check is about
## adb, never about this.
function Get-WarmStartNote {
  $keep = $LASTEXITCODE
  $note = ''
  try {
    if (Test-Path -LiteralPath $phoneScript) {
      $out = (Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript thermal -Phone $Phone 2>&1 }) -join "`n"
      $m = [regex]::Match($out, 'phone thermal: warm - (.+)')
      if ($m.Success) { $note = "WARM START: $($m.Groups[1].Value.Trim())" }
    }
  } catch {
    # Deliberately empty. See the header above.
  }
  $global:LASTEXITCODE = $keep
  return $note
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

## ONE PERF READING, and the soak when one is genuinely asked for.
##
## THIS IS A FUNCTION SO THAT `perf` AND `pass` RUN THE SAME CODE. The judgement, the NOTES.md
## line, the shared-log line and the soak verdict are the product of this script, and a second
## copy of them written for the pass is a second set of numbers that quietly disagree with the
## first. The `perf` action below is now a one-line caller and nothing about it changed.
##
## It returns a hashtable as well as printing, for the reason Measure-Surface's own header
## gives: `pass` writes these numbers into build\last-phone-pass.json, and a function that only
## prints can only be read by a human. `Found` false means NOTHING WAS MEASURED and must never
## be reported as a zero.
function Invoke-Perf([int] $Window, [int] $SoakMinutes, [string] $Label = '') {
  $out = @{
    Label     = $Label
    Found     = $false
    Visuals   = ''
    SoakOwed  = $false
    SoakTaken = ($SoakMinutes -gt 0)
    Verdict   = ''
  }

  # WHAT THIS HANDSET WAS LEFT AT BY WHOEVER HAD IT LAST, asked ONCE and asked HERE: the
  # lease is already claimed by this point, and the question has to be put before this
  # session writes its own reading into the shared log, or the answer would be about the
  # reading being taken right now. It refuses nothing; the answer is only a label.
  $warmStart = Get-WarmStartNote
  if ($warmStart) {
    Write-Host "   $warmStart" -ForegroundColor Yellow
    Write-Host "   The opening numbers below are a warm start, not a baseline."
  }

  # --- the opening reading ------------------------------------------------
  if ($SoakMinutes -gt 0) { Write-Host "opening reading" }
  $first = Measure-Surface $Window
  Show-Surface $first
  $firstTherm = Get-ThermalStatus
  Write-Host "   thermal        $(Format-Thermal $firstTherm)"
  Write-Host "   (0 is no throttling; 1+ means the phone is backing off)"
  # The game's own GPU cost, judged against its tier's budget. This is the reading that
  # says whether a ten-minute soak is owed at all, and what the floor phone would see.
  $visuals = Show-Visuals
  $out.Visuals = $visuals
  # The tier the game was actually running, read back off its own VISUALS line rather than
  # assumed. `pass -Visuals` uses it to put the tier back the way it found it, so a pass never
  # leaves his phone on low.
  $out.Tier = [regex]::Match($visuals, '^visuals (\w+)').Groups[1].Value
  $out.SoakOwed = [bool]($visuals -match 'soak 10 is owed')
  $out.Found = [bool]$first.Found
  $out.Thermal = Format-Thermal $firstTherm
  foreach ($q in 'p50', 'p90', 'p95', 'p99') { if ($first.ContainsKey($q)) { $out[$q] = $first[$q] } }
  $out.Frames = $first.Frames

  # The note rides on the RECORD and not only on the screen. A warm start that lives in one
  # session's scrollback is a warm start the session reading NOTES.md next month cannot see,
  # and it will read the number as this game's own regression.
  $warmSuffix = if ($warmStart) { "; $warmStart" } else { '' }
  $out.WarmStart = [bool]$warmStart

  if ($SoakMinutes -le 0) {
    if ($first.Found) {
      Write-PhoneReading ("$(Get-Date -Format 'yyyy-MM-dd HH:mm')  spot     p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm); $visuals$warmSuffix")
      Write-SharedPhoneLog ((Format-SharedReading $first $firstTherm 'spot') + "; $visuals$warmSuffix")
    }
    Write-Host ""
    if ($out.SoakOwed) {
      Write-Host "   For the throttling answer, run: scripts\device.ps1 pass -Soak 10"
    } else {
      Write-Host "   No soak is owed at this duty cycle (DEVICE.md). Run pass -Soak 10 only if the reading above says so."
    }
    return $out
  }

  # --- the soak -----------------------------------------------------------
  # THE THROTTLING QUESTION, asked once so no future session has to ask it again. Keep
  # playing: the phone only heats up if the GPU is doing something, and a soak spent on a
  # paused game measures a phone at rest and calls it a pass.
  Write-Host ""
  Write-Host "soaking for $SoakMinutes min - KEEP PLAYING, screen on, game in the foreground"
  $end = (Get-Date).AddMinutes($SoakMinutes)
  while ((Get-Date) -lt $end) {
    $left = [int][math]::Ceiling(($end - (Get-Date)).TotalMinutes)
    Write-Host "   $left min left..."
    Start-Sleep -Seconds ([math]::Min(60, [math]::Max(1, ($end - (Get-Date)).TotalSeconds)))
    # Renew inside the loop as well as up front. A soak longer than the lease that only
    # claimed once would expire halfway and the second reading would be of whatever the
    # next session put on the screen.
    Invoke-Phone 'claim' ($SoakMinutes + 5) | Out-Null
  }

  Write-Host ""
  Write-Host "second reading, after $SoakMinutes min of play"
  $second = Measure-Surface $Window
  Show-Surface $second
  $secondTherm = Get-ThermalStatus
  Write-Host "   thermal        $(Format-Thermal $secondTherm)"

  # --- the record ---------------------------------------------------------
  $stampNow = Get-Date -Format 'yyyy-MM-dd HH:mm'
  if ($first.Found) {
    Write-PhoneReading ("$stampNow  opening  p50 $($first.p50) p90 $($first.p90) p95 $($first.p95) p99 $($first.p99) ms over $($first.Frames) frames, thermal $(Format-Thermal $firstTherm); $visuals$warmSuffix")
  }
  if ($second.Found) {
    Write-PhoneReading ("$stampNow  +$SoakMinutes min  p50 $($second.p50) p90 $($second.p90) p95 $($second.p95) p99 $($second.p99) ms over $($second.Frames) frames, thermal $(Format-Thermal $secondTherm)")
  }
  # Into the shared log, both ends of the soak. The SECOND reading is the one that tells the
  # next session what state it is inheriting: a handset left at MODERATE after ten minutes
  # of play is not a baseline for anybody for a while.
  # The warm-start note goes on the OPENING reading only. By the second reading the handset
  # is hot because this game just played on it for $SoakMinutes minutes, which is the
  # measurement, not a contaminant.
  if ($first.Found) { Write-SharedPhoneLog ((Format-SharedReading $first $firstTherm 'opening') + $warmSuffix) }
  if ($second.Found) { Write-SharedPhoneLog (Format-SharedReading $second $secondTherm "after $SoakMinutes min of play") }

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
    $out.Verdict = "NO VERDICT: $which found no SurfaceFlinger layer"
    $out.Found = $false
    return $out
  }

  # POLISH.md's three numbers, and all three have to hold.
  $budget = 16.7
  $drift = if ($first.p95 -gt 0) { ($second.p95 - $first.p95) / [double]$first.p95 * 100.0 } else { 0.0 }
  $faults = @()
  if ($first.p95 -gt $budget) { $faults += "the opening p95 is $($first.p95) ms, over the $budget ms 60 fps budget" }
  if ($second.p95 -gt $budget) { $faults += "the p95 after $SoakMinutes min is $($second.p95) ms, over the $budget ms 60 fps budget" }
  if ($drift -gt 20.0) { $faults += ("the p95 rose {0:n0}% over the soak ({1} -> {2} ms), past the 20% POLISH allows" -f $drift, $first.p95, $second.p95) }
  # A thermal status that could not be read is not a pass. LIGHT is the worst POLISH allows.
  if ($secondTherm -lt 0) { $faults += "the thermal status could not be read, so it is unknown rather than fine" }
  elseif ($secondTherm -gt 1) { $faults += "thermal reached $(Format-Thermal $secondTherm) after $SoakMinutes min, worse than the LIGHT that POLISH allows" }

  $verdict = if ($faults.Count -eq 0) {
    "PASS: p95 {0} -> {1} ms ({2:n0}% over {3} min, both under {4} ms), thermal {5}" -f $first.p95, $second.p95, $drift, $SoakMinutes, $budget, (Format-Thermal $secondTherm)
  } else {
    "FAIL: $($faults -join '; ')"
  }
  $colour = if ($faults.Count -eq 0) { 'Green' } else { 'Red' }
  Write-Host "   THROTTLING VERDICT (POLISH.md, Performance and stability)" -ForegroundColor $colour
  Write-Host "   $verdict" -ForegroundColor $colour
  Write-Host ""
  Write-PhoneReading "$stampNow  verdict  $verdict"
  Write-Host "   Both readings and the verdict are in NOTES.md under '## Phone readings'."
  $out.Verdict = $verdict
  $out.SecondThermal = Format-Thermal $secondTherm
  $out.SecondP95 = $second.p95
  return $out
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

## THE STEPS OF A PASS, each one also still an action of its own.
##
## They are functions for the reason Invoke-Perf is: `pass` runs exactly what `install`,
## `launch`, `tier`, `log -Dump` and `shot` run, rather than a second copy of each that drifts
## from it. Every one of these branches below is now a one-line caller.

function Install-Build {
  $path = Join-Path $root $apk
  if (-not (Test-Path $path)) { throw "no APK at $path; export first" }
  Adb install -r -g $path
  Write-Host "installed $pkg"
}

function Start-Game {
  # **Quoted, because PowerShell binds parameters before it hands anything to
  # adb.** `-W` prefix-matches the common parameters -WarningAction and
  # -WarningVariable, so an unquoted `-W` here is an AmbiguousParameter error
  # against device.ps1 itself and adb is never reached. `launch` had never
  # once worked. Quoting makes each flag a value rather than a parameter name;
  # any adb flag starting with w, v, d or c needs the same treatment.
  Adb shell am start '-W' '-S' '-n' $component | Out-Null
  Write-Host "launched $component"
}

function Get-Screenshot([string] $Name) {
  $f = Join-Path $outDir "$Name.png"
  # exec-out to a FILE; piping the bytes through PowerShell corrupts them.
  Native { & cmd /c "`"$adb`" exec-out screencap -p > `"$f`"" }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $f) -or (Get-Item $f).Length -lt 1000) { throw "screencap failed" }
  Write-Host "shot: $f"
  return $f
}

## Switch the visuals tier on the phone and relaunch, for a reading per tier. Writes the same
## user://visuals.json the settings screen writes, through run-as, which a debug build allows.
##
## It RETURNS the reason it could not rather than throwing, because the two reasons are
## refusals and `pass` answers a refusal with exit 0: a release build has no run-as and the
## tier is then picked on the settings screen. The `tier` action throws on the same string, so
## nothing about that action changed.
function Set-VisualsTier([string] $Tier) {
  # Piped through a pushed file rather than quoted on the command line: every layer between
  # here and the phone's sh (PowerShell, adb, the remote shell) strips a level of quoting, and
  # the first version of this landed `{tier:high}` on the phone, which the game refused.
  $json = '{"tier":"' + $Tier + '"}'
  $local = Join-Path $outDir 'visuals.json'
  [System.IO.File]::WriteAllText($local, $json, (New-Object System.Text.UTF8Encoding($false)))
  Adb push $local /data/local/tmp/visuals.json | Out-Null
  # `files/` is created by the app on its first run, so on a fresh install it is not there yet.
  Native { & $adb shell run-as $pkg mkdir -p files }
  Native { & $adb shell run-as $pkg cp /data/local/tmp/visuals.json files/visuals.json }
  if ($LASTEXITCODE -ne 0) { return "run-as $pkg refused, which means this is not a debug build; pick the tier on the settings screen instead" }
  $back = (Native { & $adb shell run-as $pkg cat files/visuals.json }) -join ''
  if ($back.Trim() -ne $json) { return "the tier file on the phone reads '$back', not '$json'; the quoting was eaten somewhere on the way" }
  Adb shell am start '-W' '-S' '-n' $component | Out-Null
  Write-Host "visuals tier $Tier written and $pkg relaunched; give it ten seconds, then perf reads the VISUALS line"
  return ''
}

## Every ERROR line the run left in logcat. POLISH.md asks for none across a full play session,
## and the pass reads it under the lease it already holds rather than booking a second one.
##
## `-cmatch`, case-sensitive on purpose: Godot's own is `ERROR:` and `E/`, and a game that
## prints the word "error" in a piece of player-facing text is not a fault.
function Get-LogErrors {
  $lines = try { Native { & $adb logcat -d -s godot 2>$null } } catch { @() }
  return @(@($lines) | Where-Object { "$_" -cmatch 'ERROR' })
}

## THE PASS'S OWN RECORD, on scripts\deliver.ps1's build\last-delivery.json pattern: a whole
## temp file and one Move-Item -Force, so a reader can never see half of it. build\ is
## gitignored, so this is never committed - the readings that ARE committed are the NOTES.md
## lines under '## Phone readings'.
function Write-PassRecord($Record) {
  $path = Join-Path $root 'build\last-phone-pass.json'
  $tmp = "$path.tmp"
  [System.IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $path -Force
  Write-Host "   record: $path  (scripts\device.ps1 pass -Show prints it)"
}

## HOW LONG A PASS LETS A RELAUNCHED GAME SETTLE before it measures it.
##
## The template's low tier read 30 fps for its first twenty seconds after a relaunch and then
## held 60 on a second reading forty seconds in (DEVICE.md, measured 2026-09-13), so a pass
## that measures immediately measures the relaunch and reports a game that has got slower.
## A named constant rather than a literal because C:\dev\gamedev-notes\scripts\phone-tests.ps1
## rewrites it to 0 in the copy it drives, the same discipline it uses for the lease path.
$SettleSeconds = 40

$act = $Action.ToLower()

## `pass -Show` reads one local file. No device check, no lease, no adb, the same class as
## phone.ps1's own read-only actions, so it is answered before any of them run.
if ($act -eq 'pass' -and $Show) {
  $record = Join-Path $root 'build\last-phone-pass.json'
  if (Test-Path -LiteralPath $record) { Write-Output ([System.IO.File]::ReadAllText($record)) }
  else { Write-Output "device: no phone pass has been taken in $root yet" }
  exit 0
}

# The device check comes FIRST and the claim second, on purpose. "No phone connected" and
# "another game has the phone" are different reports and want different answers, and claiming
# before the check would leave a lease on a machine with nothing plugged in.
# `release` is the exception and skips the check: the phone being unplugged is the commonest
# reason a pass ends, and a lease you cannot give back because the cable came out is a lease
# the next game waits twenty minutes for.
if ($act -ne 'release') {
  # **A REFUSAL IS AN ANSWER, AND FOR `pass` IT IS AN exit 0**, the shape scripts\deliver.ps1
  # uses and for the same reason: a pass is meant to be run at every beat that owes one, and a
  # beat that exits 1 because the cable is out reads exactly like a broken build. The BUSY
  # PHONE keeps its 75 - that is the one refusal a caller has to tell apart, because it means
  # finish the desk pass and come back rather than that there is nothing to come back to.
  if ($act -eq 'pass') {
    try { Require-Device } catch {
      Write-Host "no pass taken: $($_.Exception.Message)" -ForegroundColor Yellow
      Write-Host "   Nothing about this build was judged on a handset, so the phone pass is still owed (DEVICE.md)."
      exit 0
    }
  } else {
    Require-Device
  }
  # A live logcat blocks until Ctrl+C, so it books the phone for an hour. Everything else is
  # seconds long and renews the default 20 minutes as it goes.
  # A soak books the phone for the whole run up front. The two readings are 20 s each and the
  # sleep between them is the soak, so the claim has to outlast all three or the lease expires
  # mid-measurement and another session takes the handset out from under the second reading -
  # which does not fail, it just quietly measures a different game.
  # A pass books the handset for the whole of itself in one claim, for the same reason the soak
  # does: its steps are an install, a settle, two readings and a screenshot, and a lease that
  # expires between them hands the phone to another game mid-pass.
  $minutes = if ($act -eq 'log' -and -not $Dump) { 60 } elseif ($act -eq 'perf' -and $Soak -gt 0) { $Soak + 5 } elseif ($act -eq 'pass') { if ($Soak -gt 0) { $Soak + 10 } else { 20 } } else { 20 }
  if ((Invoke-Phone 'claim' $minutes) -eq 75) {
    Write-PhoneDebt $act
    # The queue joins itself. See Write-PhoneWant: neither call above may change the 75.
    Write-PhoneWant $act
    exit 75
  }
}

switch ($act) {
  'release' { Invoke-Phone 'release' | Out-Null }
  'install' { Install-Build }
  'uninstall' { Adb uninstall $pkg }
  'launch' { Start-Game }
  'log' {
    if ($Dump) { & $adb logcat -d -s godot } else { Write-Host "Ctrl+C to stop"; & $adb logcat -s godot }
  }
  'shot' { Get-Screenshot $stamp | Out-Null }
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
    #
    # The reading itself lives in Invoke-Perf above, because `pass` below takes the same one
    # and two copies of a judgement are two judgements that drift. Nothing about this action
    # changed when it moved.
    $window = if ($Seconds -gt 0) { $Seconds } else { 20 }
    Invoke-Perf $window $Soak 'perf' | Out-Null
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
  # Switch the visuals tier on the phone and relaunch, for a reading per tier. A release build
  # refuses run-as, and the tier is then changed on the settings screen.
  'tier' {
    $tier = if ($Rest.Count -gt 0) { "$($Rest[0])".ToLower() } else { '' }
    if ($tier -notin @('low', 'medium', 'high')) { throw "tier low|medium|high" }
    $why = Set-VisualsTier $tier
    if ($why) { throw $why }
  }

  # ==========================================================================================
  # THE PHONE PASS. One claim, one release, one record, and the same four questions every time.
  #
  # WHAT IT ASKS IS NOT DECIDED HERE. C:\dev\gamedev-notes\DEVICE.md holds one table of the only
  # four questions a handset can answer and a second naming the desk test that answers
  # everything else, and this action is that table carried out. Quote it, never restate it
  # (INDEX.md rule 10).
  #
  # WHY IT IS ONE ACTION AND NOT SIX. Measured in C:\dev\.phone-log.tsv on 2026-09-16: 46 perf
  # readings over three days, all of them from four repos, while candle-gift was the named
  # holder in sixteen refusals of other games and wrote no reading at all. Six sessions each
  # assembling their own sequence of install, launch, perf, tier, log and shot produced six
  # passes that could not be compared and a handful of games with no evidence on the record.
  # A game now either ran this or did not.
  #
  # EVERY REFUSAL IS AN exit 0 EXCEPT A BUSY PHONE, which keeps its 75 up at the claim above.
  # ==========================================================================================
  'pass' {
    $apkPath = Join-Path $root $apk
    if (-not (Test-Path -LiteralPath $apkPath)) {
      Write-Host "no APK at $apkPath, so there is nothing to put on the handset." -ForegroundColor Yellow
      Write-Host "   Run scripts\check.ps1 -Export first, then this. The phone pass is still owed."
      Invoke-Phone 'release' | Out-Null
      exit 0
    }

    $readings = @()
    $errorLines = @()
    $shotPath = ''
    $soakOwed = $false
    $soakTaken = $false
    $notes = @()

    try {
      Install-Build
      Start-Game

      # **A RELAUNCHED GAME READS SLOW FOR ITS FIRST TWENTY SECONDS** - the template's low tier
      # read 30 fps and then held 60 on a second reading forty seconds in (DEVICE.md, measured
      # 2026-09-13). A pass that measures immediately measures the relaunch, which looks
      # exactly like a game that has got slower.
      Write-Host "   settling for $SettleSeconds s before the reading (DEVICE.md: a relaunch reads low for about twenty)"
      Start-Sleep -Seconds $SettleSeconds

      $window = if ($Seconds -gt 0) { $Seconds } else { 20 }
      Write-Host ''
      Write-Host "reading 1: the tier the game defaults to" -ForegroundColor Cyan
      $first = Invoke-Perf $window 0 'the tier the game defaults to'
      $readings += $first
      if ($first.SoakOwed) { $soakOwed = $true }

      # --- the low tier, where the floor phone judges it against the frame ------------------
      if ($Visuals) {
        Write-Host ''
        Write-Host "reading 2: low" -ForegroundColor Cyan
        if ($Phone -ne 'floor') {
          Write-Host "   (this is the $Phone phone, so low is judged by prediction. The low reading belongs on the floor phone: pass -Visuals -Phone floor)" -ForegroundColor Yellow
        }
        $wasTier = "$($first.Tier)"
        $why = Set-VisualsTier 'low'
        if ($why) {
          Write-Host "   no low reading: $why" -ForegroundColor Yellow
          $notes += "no low reading: $why"
        } else {
          Start-Sleep -Seconds $SettleSeconds
          $low = Invoke-Perf $window 0 'low'
          $readings += $low
          if ($low.SoakOwed) { $soakOwed = $true }
          # **PUT THE TIER BACK.** user://visuals.json survives the pass, so a pass that walks
          # away leaves his phone running the game on low and the next thing he picks up is a
          # build that looks worse than the one he was sent.
          if ($wasTier -and $wasTier -ne 'low') {
            $back = Set-VisualsTier $wasTier
            if ($back) { $notes += "the tier could not be put back to $wasTier`: $back" }
          } elseif (-not $wasTier) {
            $notes += 'the tier before this pass could not be read, so the phone has been left on low'
          }
        }
      }

      # --- the soak, and only when it is genuinely owed --------------------------------------
      #
      # Ten minutes of the one handset is the most expensive thing in this script, so -Soak is
      # permission and never an instruction: the reading's own duty judgement decides.
      if ($Soak -gt 0 -and $soakOwed) {
        Write-Host ''
        Write-Host "the reading owes a soak, and -Soak $Soak was passed" -ForegroundColor Cyan
        # **NOT `$soak`.** PowerShell variable names are case-insensitive, so a `$soak` at
        # script scope IS this script's own `[int] $Soak` parameter, and assigning a hashtable
        # to it fails the param block's type constraint with an ArgumentTransformationMetadata
        # error raised against device.ps1 itself - after the whole pass has run and with no
        # line number anywhere near the assignment. Measured here 2026-09-16.
        $soakReading = Invoke-Perf $window $Soak "soak $Soak min"
        $readings += $soakReading
        $soakTaken = $true
      } elseif ($Soak -gt 0) {
        Write-Host ''
        Write-Host "   no soak taken: this build is at or under the soak-free duty (DEVICE.md), so ten minutes of the handset would answer a question already answered."
        $notes += 'a soak was offered and not taken: the duty does not owe one'
      } elseif ($soakOwed) {
        Write-Host ''
        Write-Host "   A SOAK IS OWED for this build. Rerun with: scripts\device.ps1 pass -Soak 10" -ForegroundColor Yellow
        $notes += 'a soak is owed for this build and was not taken'
      }

      # --- the log, under the lease already held ---------------------------------------------
      $errorLines = @(Get-LogErrors)
      Write-Host ''
      if ($errorLines.Count -eq 0) {
        Write-Host "   log            no ERROR lines from this run" -ForegroundColor Green
      } else {
        Write-Host "   log            $($errorLines.Count) ERROR line(s) (POLISH.md asks for none)" -ForegroundColor Yellow
        foreach ($l in @($errorLines | Select-Object -First 3)) { Write-Host "                  $l" -ForegroundColor Yellow }
        if ($errorLines.Count -gt 3) { Write-Host "                  (+$($errorLines.Count - 3) more, scripts\device.ps1 log -Dump for all of them)" }
      }

      # --- one frame of what he would be looking at -------------------------------------------
      #
      # A failed screencap is a REFUSAL and not a failure of the pass: the readings above are
      # the product, they are already in NOTES.md, and throwing here would throw away the
      # record of a pass that has just spent the handset for a minute. Say so and carry on.
      try {
        $shotPath = Get-Screenshot "$stamp-pass"
      } catch {
        Write-Host "   no screenshot: $($_.Exception.Message)" -ForegroundColor Yellow
        $notes += "no screenshot: $($_.Exception.Message)"
      }
    } finally {
      Invoke-Phone 'release' | Out-Null
    }

    # --- the record ---------------------------------------------------------------------------
    $summary = "$($readings.Count) reading(s), $($errorLines.Count) ERROR line(s), soak $(if ($soakTaken) { 'taken' } elseif ($soakOwed) { 'OWED' } else { 'not owed' })"
    Write-PhoneReading ("$(Get-Date -Format 'yyyy-MM-dd HH:mm')  pass     $summary$(if ($notes.Count) { '; ' + ($notes -join '; ') } else { '' })")

    Write-PassRecord ([ordered]@{
        slug       = $slug
        utc        = [datetimeoffset]::UtcNow.ToString('o')
        phone      = $Phone
        head       = $head
        stamp      = $buildStamp
        version    = $version
        tier       = "$($readings[0].Tier)"
        readings   = @($readings | ForEach-Object {
            [ordered]@{
              label    = "$($_.Label)"
              tier     = "$($_.Tier)"
              found    = [bool]$_.Found
              p50      = $_.p50
              p90      = $_.p90
              p95      = $_.p95
              p99      = $_.p99
              frames   = $_.Frames
              thermal  = "$($_.Thermal)"
              visuals  = "$($_.Visuals)"
              verdict  = "$($_.Verdict)"
              soakOwed = [bool]$_.SoakOwed
              warmStart = [bool]$_.WarmStart
            }
          })
        errors     = $errorLines.Count
        errorLines = @($errorLines | Select-Object -First 3 | ForEach-Object { "$_" })
        soakOwed   = [bool]$soakOwed
        soakTaken  = [bool]$soakTaken
        shot       = "$shotPath"
        notes      = @($notes)
      })

    Write-Host ''
    Write-Host "phone pass: $summary" -ForegroundColor Green
    Write-Host "   The readings are in NOTES.md under '## Phone readings', stamped with the build they belong to."
  }
  default { throw "unknown action $Action. See the header of this script." }
}
