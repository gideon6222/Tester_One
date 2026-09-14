<#
.SYNOPSIS
  Film a deterministic run of the game and tile it into a contact sheet Claude can read.

.DESCRIPTION
  Uses Godot's Movie Maker mode: --write-movie renders at a fixed timestep with the dummy
  audio driver, so a replay file produces the same frames every run. The autoload
  scripts/replay_player.gd feeds the recorded touches on the recorded physics frames.
  ffmpeg then tiles every Nth frame, frame number burned in, into
  build/movie/<name>/sheet.png, and writes build/movie/<name>/run.mp4 from the same decode.

  Godot writes ONE MJPEG file, build/movie/<name>/run.avi, not a PNG per frame. The PNG
  sequence cost 1080 full-size encodes on the way out and two full decodes on the way back
  in, and nothing ever read a single one of those files: the artefacts are the sheet and the
  mp4, both of which are already lossy and both of which are scaled down. Measured on this
  template, 18 seconds of film went from 188 s / 83 MB to the numbers the cost line prints.

  -Png restores the old PNG sequence and frame.wav. Use it when something needs a specific
  frame at full quality with no JPEG in the way - reading a thin line of text, judging a
  gradient or a one-pixel seam, or feeding a pixel check - and when you want the audio track
  as a file. It is slower and far bigger; the sheet is not worth it.

  NOT headless. A real window opens (small); that is the point.

  -State <name> STARTS THE FILM IN THE SITUATION instead of driving to it. The names come
  from the game's own Main.dev_states(); a name ending in .json is an exact saved run. This
  is the difference between filming a moment and filming everything in front of it, and on
  this template on 2026-09-13 it was measured:

    five seconds of level 2 by playing to it   -Seconds 34    2040 frames   216.0 s  100.7 MB
    five seconds of level 2 by seeking to it   -State level2 -Seconds 5
                                                               300 frames    37.3 s   14.9 MB

  Six times faster and seven times smaller for the same five seconds of picture, and the gap
  grows with how deep into a run the moment is. The unit rate is the thing to budget with,
  and it is the same either way: 6.3 s of wall clock and 3.0 MB per second of film. What
  -State buys is not a cheaper second, it is not filming the 29 seconds in front of it.

  Two frames at the head of a sought film are the UNSOUGHT game: the first rendered frames
  are drawn before the physics loop has run, and the seek happens on physics frame 1. The
  log line `ReplayPlayer: sought state '<name>' on physics frame <n>` says where it landed.

  IS THE RUN GETTING THE DATA IT WAS ASKED FOR? Every film passes `beat` to the game, which
  prints `DEVBEAT f=<frame> k=v ...` from Main.dev_heartbeat() every 30 physics frames. Two
  things read those lines:

    -StallSeconds  kills a run whose heartbeat has stopped CHANGING (default 45 s). The
                   reading is what is watched, not the line: a game that goes on printing
                   the same numbers is as stuck as one that has stopped printing. Godot does
                   not block-buffer stdout under redirection - measured here 2026-09-13,
                   beats arrive at about 100 a second in a continuous trickle, never in one
                   lump at the end - so a stall is visible while it is happening. A game
                   with no dev_heartbeat() says so on its own first line, and the detector
                   then disarms itself and leaves the wall clock as the only ceiling.
    -MaxMinutes    the wall clock ceiling (default 15), which holds either way.

  After the run the first and the last DEVBEAT are compared, and a film whose numbers never
  changed is an error naming the two frames rather than a contact sheet of a frozen picture.
  That is the second net under the first: a film SHORTER than -StallSeconds ends before the
  watchdog would have fired, and this catches it anyway. Both were verified by hand on
  2026-09-13 - an infinite loop in _ready is killed in 30 s instead of running for six
  minutes, a game whose _process returns early throws with the two frame numbers, and a
  game with no dev_heartbeat() disarms the stall detector rather than being killed by it.

.EXAMPLE
  scripts\movie.ps1 -Replay test\replays\level1.json -Seconds 20
  scripts\movie.ps1 -State level2 -Seconds 6 -UserArgs policy=dodger   # start on level 2
  scripts\movie.ps1 -State user://save.json -Seconds 8                 # an exact saved run
  scripts\movie.ps1 -Seconds 10 -Name idle            # no input: the attract/idle state
  scripts\movie.ps1 -Replay test\replays\shop.json -Seconds 8 -Every 10 -Cols 4
  scripts\movie.ps1 -Seconds 5 -Name seam -Png        # lossless frames + frame.wav
#>
[CmdletBinding()]
param(
  [string] $Replay,
  [string] $State,          # a name from the game's Main.dev_states(), or a path to a .json save
  [double] $Seconds = 15,
  [int] $Fps = 60,
  [int] $Every = 20,        # tile every Nth frame
  [int] $Cols = 6,
  [string] $Name,
  # **540x960, not the phone's 460x996.** Movie Maker writes the PROJECT viewport
  # buffer (1080x1920) whatever the window is, and the stretch transform is
  # computed for the WINDOW - so a window at the phone's aspect puts every
  # edge-anchored Control outside the captured frame. Measured on candle-gift and
  # on gravewell: films of both came back with no HUD at the top or bottom, so
  # every HUD judgement this studio made from a contact sheet was made from a
  # picture with the HUD cut off. store.ps1 already screenshots at 540x960 for
  # exactly this reason and says so in its header; this default had the same
  # fault with a different number. The guard below refuses a mismatch outright.
  [string] $Resolution = '540x960',
  [switch] $Png,            # lossless PNG per frame + frame.wav, the old slow path
  [int] $StallSeconds = 45,      # kill after this long with no new heartbeat; 0 disables
  [double] $MaxMinutes = 15,     # kill after this much wall clock; 0 disables
  [string[]] $UserArgs = @()   # extra bare words after --, e.g. 'touch', 'level=3'
)
$ErrorActionPreference = 'Stop'

## Native commands write progress and warnings to STDERR, and
## `$ErrorActionPreference = 'Stop'` turns any of that into a terminating error.
## Godot's Movie Maker run ends with a shutdown warning, so the script died after
## rendering all 3,840 frames and before tiling a single one of them: the
## expensive half succeeded and the useful half never ran.
##
## Third script in this repo with the same fault. Every native call goes through
## this now, and the exit code below is the only thing that decides.
function Native([scriptblock]$Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}

## ffmpeg, found even when this shell's PATH predates the install.
##
## winget puts ffmpeg on the USER PATH, which a shell only picks up when it starts.
## A long-running session - which is what a Claude session is - therefore has a
## perfectly installed ffmpeg it cannot see, and the old message here sent the reader
## to install.ps1, which reinstalls nothing and rewrites ~/.claude/CLAUDE.md on the
## way past. So look where winget actually puts it before believing PATH.
function Resolve-Ffmpeg {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $glob = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*-full_build\bin\ffmpeg.exe"
  $found = Get-ChildItem $glob -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.FullName }
  foreach ($p in ([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';')) {
    if ($p -and (Test-Path (Join-Path $p 'ffmpeg.exe'))) { return (Join-Path $p 'ffmpeg.exe') }
  }
  throw "ffmpeg not found. Install it with: winget install --id Gyan.FFmpeg --scope user"
}

## ffprobe ships in the same bin directory as the ffmpeg we just resolved, so take it from
## there rather than from PATH - same reason as above, and it keeps the two binaries the
## same build.
function Resolve-Ffprobe($ffmpegPath) {
  $beside = Join-Path (Split-Path $ffmpegPath -Parent) 'ffprobe.exe'
  if (Test-Path $beside) { return $beside }
  $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "ffprobe not found beside $ffmpegPath. Install ffmpeg with: winget install --id Gyan.FFmpeg --scope user"
}

## How many frames are actually in the AVI.
##
## Godot's AVI writer patches the frame count into the header when it closes the file, so a
## run that died mid-way leaves it absent or zero - exactly the case the guard below exists
## to catch - and the fall-through then DECODES the stream and counts what survived. Both
## are needed: reading the header is 0.3 s on a 1080-frame film and decoding it is 10.8 s
## (M), so paying the decode on every good run would give back a tenth of what this change
## just saved, and trusting only the header would call a half-written file complete.
function Get-AviFrameCount($ffprobePath, $file) {
  if (-not (Test-Path $file)) { return 0 }
  ## Native runs the block in a child scope, so read its OUTPUT rather than assigning
  ## through it - a variable set inside never comes back out.
  $raw = Native { & $ffprobePath -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 $file 2>$null }
  $n = $raw | Where-Object { "$_" -match '^\d+$' } | Select-Object -First 1
  if ($n -and [int]$n -gt 0) { return [int]$n }
  $raw = Native { & $ffprobePath -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $file 2>$null }
  $n = $raw | Where-Object { "$_" -match '^\d+$' } | Select-Object -First 1
  if ($n) { return [int]$n }
  return 0
}

## The last `DEVBEAT f=<frame> <pairs>` line in the log, as a two-part reading, or $null.
##
## The tail rather than the whole file, because this is called every two seconds for the
## length of a film and the log grows all the way through. Sixty lines is two minutes of
## heartbeats at the default interval, so a run that is producing them cannot hide behind
## its own chatter.
function Get-LastBeat($file) {
  if (-not (Test-Path $file)) { return $null }
  $lines = $null
  try { $lines = @(Get-Content $file -Tail 60 -ErrorAction SilentlyContinue) } catch { return $null }
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $m = [regex]::Match([string]$lines[$i], '^DEVBEAT f=(\d+)\s+(.*)$')
    if ($m.Success) { return @{ Frame = [int]$m.Groups[1].Value; Reading = $m.Groups[2].Value.Trim() } }
  }
  return $null
}

## Every `DEVBEAT` reading in the finished log, in order. Read once, at the end.
function Get-AllBeats($file) {
  if (-not (Test-Path $file)) { return @() }
  return @(Select-String -Path $file -Pattern '^DEVBEAT f=(\d+)\s+(.*)$' | ForEach-Object {
    @{ Frame = [int]$_.Matches[0].Groups[1].Value; Reading = $_.Matches[0].Groups[2].Value.Trim() }
  })
}

## Append lines to a file that another process may not have let go of yet.
##
## `Start-Process -RedirectStandardOutput` opens the file on PowerShell's side and hands the
## handle to the child, and after a KILL the handle outlives `WaitForExit` by a moment. The
## first version of this appended straight away, and on a killed run it threw
## "the process cannot access the file" - which aborted the script BEFORE the short-run
## guard, so the one run that most needed its reason printed was the one that printed none.
## A watchdog whose own cleanup can throw is not a watchdog.
function Append-Lines($file, [string[]] $lines) {
  for ($i = 0; $i -lt 25; $i++) {
    try {
      Add-Content -Path $file -Value $lines -ErrorAction Stop
      return $true
    } catch {
      Start-Sleep -Milliseconds 200
    }
  }
  return $false
}

## One command line, quoted. `Start-Process -ArgumentList` takes an array and joins it
## WITHOUT quoting on Windows PowerShell, so a repo or a -Name with a space in it would
## silently become two arguments and Godot would film something else.
function Join-Args($items) {
  return (($items | ForEach-Object {
    $a = [string]$_
    if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
  }) -join ' ')
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $root
try {
  $godot = $env:GODOT
  if (-not $godot) { $godot = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe" | Select-Object -First 1).FullName }
  if (-not $godot) { throw "Godot not found; set `$env:GODOT" }
  $ffmpeg = Resolve-Ffmpeg
  $ffprobe = Resolve-Ffprobe $ffmpeg

  ## A replay is a recorded sequence of touches on NUMBERED PHYSICS FRAMES, recorded from the
  ## beginning of a run. Seeking first moves the game out from under every one of them, and
  ## what comes back is a plausible film of a thumb pressing nothing. Refused with the way
  ## round that does work rather than silently ignoring one of the two.
  if ($State -and $Replay) {
    throw "-State and -Replay together. A replay is touches pinned to numbered physics frames of a run that started at the beginning, so seeking first plays them against a different game. Film the state with a bot instead: -State $State -UserArgs policy=<name>."
  }

  if (-not $Name) {
    $Name = if ($Replay) { [IO.Path]::GetFileNameWithoutExtension($Replay) }
            elseif ($State) { 'state_' + ($State -replace '[^\w\-]+', '_').Trim('_') }
            else { 'run' }
  }
  $out = Join-Path $root "build\movie\$Name"
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Path $out | Out-Null
  $frames = [int]($Seconds * $Fps)

  # ---------------------------------------------------------------------------
  # **The window's aspect must match the buffer's, or the film loses its edges.**
  #
  # This is the frame check, done at the cause rather than on the pixels: a film
  # is only worth judging a HUD from when the two aspects agree, and comparing
  # them is exact, instant and game-agnostic. Inspecting a rendered frame for a
  # missing control needs to know which control, which is the game's business.
  # ---------------------------------------------------------------------------
  $vw = 1080.0; $vh = 1920.0
  $pg = Join-Path $root 'project.godot'
  if (Test-Path $pg) {
    $pgText = Get-Content $pg -Raw -Encoding UTF8
    if ($pgText -match 'window/size/viewport_width\s*=\s*(\d+)')  { $vw = [double]$Matches[1] }
    if ($pgText -match 'window/size/viewport_height\s*=\s*(\d+)') { $vh = [double]$Matches[1] }
  }
  if ($Resolution -match '^(\d+)x(\d+)$') {
    $rw = [double]$Matches[1]; $rh = [double]$Matches[2]
    $want = $vw / $vh
    $have = $rw / $rh
    if ([Math]::Abs($want - $have) -gt 0.01) {
      $goodH = [int][Math]::Round($rw * $vh / $vw)
      throw ("-Resolution $Resolution is $([Math]::Round($have,3)) to 1 and the project's buffer is " +
             "$([int]$vw)x$([int]$vh), $([Math]::Round($want,3)) to 1. Movie Maker captures the BUFFER, " +
             "and the stretch transform is computed for the WINDOW, so every edge-anchored control " +
             "would land outside the frame and the film would show no HUD. Use ${rw}x${goodH}.")
    }
  }

  # One MJPEG file by default; a PNG per frame plus frame.wav under -Png.
  $movieOut = if ($Png) { "build/movie/$Name/frame.png" } else { "build/movie/$Name/run.avi" }
  $avi = Join-Path $out 'run.avi'

  $gargs = @('--path', '.', '--write-movie', $movieOut, '--fixed-fps', "$Fps", '--quit-after', "$frames",
            '--resolution', $Resolution, '--disable-vsync', '--')
  if ($Replay) {
    if (-not (Test-Path $Replay)) { throw "replay not found: $Replay" }
    $gargs += "replay=" + ($Replay -replace '\\', '/')
  }
  if ($State) { $gargs += "state=" + ($State -replace '\\', '/') }
  $gargs += $UserArgs
  # The heartbeat, unless the caller already asked for one in its own words. It costs the
  # game nothing it has not already written and it is the only thing that can tell a long
  # film of the game being played from a long film of the game stuck.
  if (-not ($UserArgs | Where-Object { $_ -eq 'beat' -or "$_".StartsWith('beat=') })) { $gargs += 'beat' }

  $log = Join-Path $out 'godot.log'
  $errFile = Join-Path $out 'godot.err'
  Write-Host "==> filming $frames frames at $Fps fps -> $out$(if ($State) { " (state '$State')" })$(if ($Png) { ' (PNG sequence)' })"

  ## **Run it as a process rather than through a pipeline, and watch it while it runs.**
  ##
  ## The old form was `& $godot @gargs 2>&1 | ... | Out-File`, which cannot be interrupted:
  ## a run that hung produced nothing until somebody noticed, and a run that filmed the
  ## wrong thing cost the whole budget before saying so. It also wrapped every stderr line
  ## in an ErrorRecord, which is why this file used to carry an unwrapper - two digested
  ## lessons and a `check.ps1` fix ago. Redirecting the two streams to two files at the OS
  ## level makes both problems go away at once: the bytes in the log are the bytes Godot
  ## wrote, and the poll below can read them while they are being written.
  ##
  ## **The single-file contract still holds.** `skills/playtest/SKILL.md` tells a session to
  ## read `godot.log` after a filmed run, so stderr is appended into it under a labeled
  ## block the moment the process ends, and `godot.err` is removed.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process -FilePath $godot -ArgumentList (Join-Args $gargs) -PassThru -NoNewWindow `
            -RedirectStandardOutput $log -RedirectStandardError $errFile

  ## THE WATCHDOG.
  ##
  ## The stall clock is armed from launch, so a game that hangs before it draws anything is
  ## caught too - and it DISARMS itself the moment the game says it has no `dev_heartbeat()`
  ## to report, because a run that cannot produce heartbeats must not be killed for not
  ## producing them. What is left in that case is the wall clock, and the line printed after
  ## the run says so in as many words.
  $lastReading = ''
  $lastAt = 0.0
  $noHeartbeat = $false
  $sawBeat = $false
  $killedBecause = ''
  while (-not $proc.HasExited) {
    Start-Sleep -Seconds 2
    $nowS = $sw.Elapsed.TotalSeconds
    $beat = Get-LastBeat $log
    if ($null -ne $beat) {
      $sawBeat = $true
      if ($beat.Reading -ne $lastReading) { $lastReading = $beat.Reading; $lastAt = $nowS }
    } elseif (-not $sawBeat -and -not $noHeartbeat) {
      # Said once by the game, early, and only worth looking for until it is settled.
      if (Select-String -Path $log -Pattern 'DEVBEAT none' -SimpleMatch -Quiet -ErrorAction SilentlyContinue) { $noHeartbeat = $true }
    }
    if ($MaxMinutes -gt 0 -and $nowS -gt $MaxMinutes * 60) {
      $killedBecause = "the wall clock passed -MaxMinutes $MaxMinutes"
      break
    }
    if ($StallSeconds -gt 0 -and -not $noHeartbeat -and ($nowS - $lastAt) -gt $StallSeconds) {
      $killedBecause = if ($sawBeat) {
        "no NEW heartbeat for $StallSeconds s (last reading: $lastReading). The run is alive and the game is not."
      } else {
        "not one heartbeat in $StallSeconds s. Godot did not get as far as the first physics frames, so read the TOP of godot.log."
      }
      break
    }
  }
  if ($killedBecause) {
    Write-Host "==> killing the run: $killedBecause" -ForegroundColor Yellow
    try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
  }
  $proc.WaitForExit()
  $renderS = $sw.Elapsed.TotalSeconds
  # A killed process does not always hand its code back through this object, and a blank
  # `exit ` in the message below reads like the script forgot to look rather than like the
  # watchdog pulling the plug. Say which it was.
  $exit = $null
  try { $exit = $proc.ExitCode } catch { }
  if ($null -eq $exit) { $exit = if ($killedBecause) { 'killed' } else { 'unknown' } }
  $proc.Dispose()

  # Fold stderr back in, so godot.log is still the one file to read. The banner deliberately
  # carries none of the words the sweep at the bottom greps for, and the sweep skips `----`
  # lines as well: the first version of this line announced itself as holding SCRIPT ERRORs
  # and was then reported, every single run, as an engine message. A label that trips the
  # detector it labels is a false positive with a name.
  if (Test-Path $errFile) {
    $errText = ''
    try { $errText = (Get-Content $errFile -Raw -ErrorAction Stop) } catch { }
    $folded = Append-Lines $log @(
      '',
      '---- stderr from the run, verbatim (script faults, push_err lines and shutdown notices) ----',
      $(if ([string]::IsNullOrWhiteSpace($errText)) { '(nothing)' } else { $errText.TrimEnd() })
    )
    if ($folded) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
    else { Write-Host "==> could not fold stderr into godot.log; it is beside it, in godot.err" -ForegroundColor Yellow }
  }

  ## Count what was actually filmed, and refuse a short run.
  ##
  ## The old guard asked only whether two PNGs existed, so a run that died a second in still
  ## produced a sheet - a plausible sheet of the wrong thing, which is the failure filming
  ## exists to catch. Anything under ninety per cent of the frames asked for is a run that
  ## stopped, not a run that is short, and the top of godot.log is where it says why.
  if ($Png) {
    $count = (Get-ChildItem $out -Filter 'frame*.png' -ErrorAction SilentlyContinue).Count
    $inArgs = @('-framerate', "$Fps", '-i', (Join-Path $out 'frame%08d.png'))
  } else {
    $count = Get-AviFrameCount $ffprobe $avi
    $inArgs = @('-i', $avi)
  }
  if ($count -lt [int]($frames * 0.9)) {
    Get-Content $log -ErrorAction SilentlyContinue | Select-Object -First 40
    $why = if ($killedBecause) { "KILLED: $killedBecause" }
           else { "Read the top of godot.log: a parse error hangs, a missing scene prints nothing, a missing replay throws, and a state the game refuses quits 1 on purpose." }
    throw "filmed $count of $frames frames (exit $exit). $why"
  }

  # Contact sheet with the frame index burned in (frame n * Every), and the mp4, from ONE
  # decode. select comes before drawtext, so the number drawn is the tile index, which is
  # what the line printed at the end promises.
  $sampled = [math]::Ceiling($count / $Every)
  $rows = [math]::Max(1, [math]::Ceiling($sampled / $Cols))
  $font = 'C\:/Windows/Fonts/consola.ttf'
  $vf = "select='not(mod(n\,$Every))',drawtext=fontfile='$font':text='%{n}':x=6:y=6:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.5,scale=230:-1,tile=${Cols}x${rows}"
  $sheet = Join-Path $out 'sheet.png'
  $mp4 = Join-Path $out 'run.mp4'
  $fc = "[0:v]split=2[sh][vd];[sh]$vf[sheet];[vd]format=yuv420p[vid]"

  $sheetS = 0.0; $videoS = 0.0; $onePass = $true
  $encS = (Measure-Command {
    Native {
      & $ffmpeg -loglevel error -y @inArgs -filter_complex $fc `
        -map '[sheet]' -fps_mode passthrough -frames:v 1 $sheet `
        -map '[vid]' -c:v libx264 -crf 22 $mp4 2>&1 | Out-Null
    }
    $script:fcExit = $LASTEXITCODE
  }).TotalSeconds
  if ($script:fcExit -ne 0 -or -not (Test-Path $sheet)) {
    # Fall back to two passes over the same input if the split graph fights us.
    $onePass = $false
    Write-Host "==> single-pass graph failed (exit $($script:fcExit)); falling back to two passes"
    $sheetS = (Measure-Command {
      Native { & $ffmpeg -loglevel error -y @inArgs -vf $vf -fps_mode passthrough -frames:v 1 $sheet }
      $script:sExit = $LASTEXITCODE
    }).TotalSeconds
    if ($script:sExit -ne 0) { throw "ffmpeg failed building the sheet" }
    $videoS = (Measure-Command {
      Native { & $ffmpeg -loglevel error -y @inArgs -c:v libx264 -pix_fmt yuv420p -crf 22 $mp4 2>&1 | Out-Null }
    }).TotalSeconds
  }

  $mb = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
  $errors = Select-String -Path $log -Pattern 'ERROR|SCRIPT ERROR|WARNING' |
            Where-Object { $_.Line -notmatch '^\s*----' } | Select-Object -First 20
  Write-Host "==> $count frames, sheet: $sheet  (tile n = frame n*$Every, $Every frames = $([math]::Round($Every/$Fps,2)) s)"
  ## Print what it cost, every time, so the budget in TESTING.md is a number somebody read
  ## rather than a number somebody remembered.
  $split = if ($onePass) { "render $([math]::Round($renderS,1))s, sheet+video $([math]::Round($encS,1))s" }
           else { "render $([math]::Round($renderS,1))s, sheet $([math]::Round($sheetS,1))s, video $([math]::Round($videoS,1))s" }
  Write-Host "==> cost: $count frames, $([math]::Round($renderS + $encS + $sheetS + $videoS,1))s total ($split), $mb MB on disk$(if ($Png) { ' (-Png)' })"
  if ($errors) { Write-Host "==> engine messages during the run:" -ForegroundColor Yellow; $errors | ForEach-Object { Write-Host "   $($_.Line)" } }
  else { Write-Host "==> no engine errors in the log" }

  ## DID ANYTHING HAPPEN? Asked last, after the sheet and the mp4 exist, so a film of a
  ## frozen game is still on disk to look at when this throws. A contact sheet of twenty
  ## identical tiles is the one artefact that reads as evidence and is not.
  $beats = Get-AllBeats $log
  if ($beats.Count -eq 0) {
    Write-Host "==> checked for liveness only: no DEVBEAT lines. This game implements no dev_heartbeat(), so nothing here can tell a film of it being played from a film of it stuck. See src/game/main.gd." -ForegroundColor Yellow
  } elseif ($beats.Count -eq 1) {
    Write-Host "==> one heartbeat only (frame $($beats[0].Frame)), so there is nothing to compare it against. Film for longer or lower beat=<frames>." -ForegroundColor Yellow
  } else {
    $a = $beats[0]; $z = $beats[-1]
    if ($a.Reading -eq $z.Reading) {
      throw "NOTHING MOVED between physics frame $($a.Frame) and physics frame $($z.Frame): both read '$($a.Reading)'. $count frames were filmed of a game that was not running. Look at $sheet, then at the top of godot.log."
    }
    Write-Host "==> alive: frame $($a.Frame) $($a.Reading)  ->  frame $($z.Frame) $($z.Reading)"
  }
} finally { Pop-Location }
