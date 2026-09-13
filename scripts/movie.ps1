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

.EXAMPLE
  scripts\movie.ps1 -Replay test\replays\level1.json -Seconds 20
  scripts\movie.ps1 -Seconds 10 -Name idle            # no input: the attract/idle state
  scripts\movie.ps1 -Replay test\replays\shop.json -Seconds 8 -Every 10 -Cols 4
  scripts\movie.ps1 -Seconds 5 -Name seam -Png        # lossless frames + frame.wav
#>
[CmdletBinding()]
param(
  [string] $Replay,
  [double] $Seconds = 15,
  [int] $Fps = 60,
  [int] $Every = 20,        # tile every Nth frame
  [int] $Cols = 6,
  [string] $Name,
  [string] $Resolution = '460x996',
  [switch] $Png,            # lossless PNG per frame + frame.wav, the old slow path
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
function Unwrap-ErrorLine($rec) {
  # A BLANK stderr line - printerr("") between the paragraphs of an error block -
  # arrives as an ErrorRecord whose ToString() returns the bare type name, so the
  # log reads `System.Management.Automation.RemoteException` where the program
  # wrote nothing at all. Exception.Message is the line Godot actually emitted,
  # empty string included. Same family as the ErrorRecord wrapping itself: a log
  # that does not say what the program printed.
  $m = $null
  if ($null -ne $rec.Exception) { $m = $rec.Exception.Message }
  if ($null -eq $m) { $m = $rec.ToString() }
  if ($m -eq 'System.Management.Automation.RemoteException') { return '' }
  return $m
}

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

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $root
try {
  $godot = $env:GODOT
  if (-not $godot) { $godot = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe" | Select-Object -First 1).FullName }
  if (-not $godot) { throw "Godot not found; set `$env:GODOT" }
  $ffmpeg = Resolve-Ffmpeg
  $ffprobe = Resolve-Ffprobe $ffmpeg

  if (-not $Name) { $Name = if ($Replay) { [IO.Path]::GetFileNameWithoutExtension($Replay) } else { 'run' } }
  $out = Join-Path $root "build\movie\$Name"
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Path $out | Out-Null
  $frames = [int]($Seconds * $Fps)

  # One MJPEG file by default; a PNG per frame plus frame.wav under -Png.
  $movieOut = if ($Png) { "build/movie/$Name/frame.png" } else { "build/movie/$Name/run.avi" }
  $avi = Join-Path $out 'run.avi'

  $gargs = @('--path', '.', '--write-movie', $movieOut, '--fixed-fps', "$Fps", '--quit-after', "$frames",
            '--resolution', $Resolution, '--disable-vsync', '--')
  if ($Replay) {
    if (-not (Test-Path $Replay)) { throw "replay not found: $Replay" }
    $gargs += "replay=" + ($Replay -replace '\\', '/')
  }
  $gargs += $UserArgs
  Write-Host "==> filming $frames frames at $Fps fps -> $out$(if ($Png) { ' (PNG sequence)' })"
  ## **Unwrap the ErrorRecords and write UTF-8, or godot.log is not what Godot
  ## printed** - and this is the file `skills/playtest/SKILL.md` tells the session
  ## to read after a filmed run.
  ##
  ## `*> $log` sends a native command's stderr through PowerShell's error channel,
  ## which renders each line as
  ##   Godot_v4.7.2-stable_win64_console.exe : SCRIPT ERROR: ...
  ## plus a `+ CategoryInfo` block, in UTF-16. So the error sweep at the bottom of
  ## this script matched a different string than the one Godot wrote, and a
  ## session reading the log for the three bugs sitting in the console found a
  ## wall of PowerShell stack traces instead. `check.ps1` was fixed on 2026-09-10
  ## and two digested lessons both ended "the same fix is still owed to
  ## movie.ps1" - a note of that shape is a bug report filed against yourself.
  ##
  ## Calling ToString() on the ErrorRecord gives back the line Godot actually
  ## wrote, and -Encoding utf8 makes the log greppable by anything else too.
  $renderS = (Measure-Command {
    Native {
      & $godot @gargs 2>&1 |
        ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Unwrap-ErrorLine $_ } else { $_ } } |
        Out-File -FilePath "$out\godot.log" -Encoding utf8
    }
    $script:exit = $LASTEXITCODE
  }).TotalSeconds
  $exit = $script:exit

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
    Get-Content "$out\godot.log" -ErrorAction SilentlyContinue | Select-Object -First 40
    throw "filmed $count of $frames frames (exit $exit). Read the top of godot.log: a parse error hangs, a missing scene prints nothing, a missing replay throws."
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
  $errors = Select-String -Path "$out\godot.log" -Pattern 'ERROR|SCRIPT ERROR|WARNING' | Select-Object -First 20
  Write-Host "==> $count frames, sheet: $sheet  (tile n = frame n*$Every, $Every frames = $([math]::Round($Every/$Fps,2)) s)"
  ## Print what it cost, every time, so the budget in TESTING.md is a number somebody read
  ## rather than a number somebody remembered.
  $split = if ($onePass) { "render $([math]::Round($renderS,1))s, sheet+video $([math]::Round($encS,1))s" }
           else { "render $([math]::Round($renderS,1))s, sheet $([math]::Round($sheetS,1))s, video $([math]::Round($videoS,1))s" }
  Write-Host "==> cost: $count frames, $([math]::Round($renderS + $encS + $sheetS + $videoS,1))s total ($split), $mb MB on disk$(if ($Png) { ' (-Png)' })"
  if ($errors) { Write-Host "==> engine messages during the run:" -ForegroundColor Yellow; $errors | ForEach-Object { Write-Host "   $($_.Line)" } }
  else { Write-Host "==> no engine errors in the log" }
} finally { Pop-Location }
