<#
.SYNOPSIS
  Film a deterministic run of the game and tile it into a contact sheet Claude can read.

.DESCRIPTION
  Uses Godot's Movie Maker mode: --write-movie renders one PNG per frame at a fixed timestep
  with the dummy audio driver, so a replay file produces the same frames every run. The
  autoload scripts/replay_player.gd feeds the recorded touches on the recorded physics frames.
  ffmpeg then tiles every Nth frame, frame number burned in, into build/movie/<name>/sheet.png.

  NOT headless. A real window opens (small); that is the point.

.EXAMPLE
  scripts\movie.ps1 -Replay test\replays\level1.json -Seconds 20
  scripts\movie.ps1 -Seconds 10 -Name idle            # no input: the attract/idle state
  scripts\movie.ps1 -Replay test\replays\shop.json -Seconds 8 -Every 10 -Cols 4
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
  [string[]] $UserArgs = @()   # extra bare words after --, e.g. 'touch', 'level=3'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $root
try {
  $godot = $env:GODOT
  if (-not $godot) { $godot = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe" | Select-Object -First 1).FullName }
  if (-not $godot) { throw "Godot not found; set `$env:GODOT" }
  if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "ffmpeg not on PATH; run C:\dev\gamedev-notes\setup\install.ps1" }

  if (-not $Name) { $Name = if ($Replay) { [IO.Path]::GetFileNameWithoutExtension($Replay) } else { 'run' } }
  $out = Join-Path $root "build\movie\$Name"
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  New-Item -ItemType Directory -Path $out | Out-Null
  $frames = [int]($Seconds * $Fps)

  $gargs = @('--path', '.', '--write-movie', "build/movie/$Name/frame.png", '--fixed-fps', "$Fps", '--quit-after', "$frames",
            '--resolution', $Resolution, '--disable-vsync', '--')
  if ($Replay) {
    if (-not (Test-Path $Replay)) { throw "replay not found: $Replay" }
    $gargs += "replay=" + ($Replay -replace '\\', '/')
  }
  $gargs += $UserArgs
  Write-Host "==> filming $frames frames at $Fps fps -> $out"
  & $godot @gargs *> "$out\godot.log"
  $exit = $LASTEXITCODE
  $pngs = Get-ChildItem $out -Filter 'frame*.png'
  if ($pngs.Count -lt 2) {
    Get-Content "$out\godot.log" | Select-Object -First 40
    throw "no frames were written (exit $exit). Read the top of godot.log: a parse error hangs, a missing scene prints nothing."
  }

  # Contact sheet with the frame index burned in (frame n * Every).
  $sampled = [math]::Ceiling($pngs.Count / $Every)
  $rows = [math]::Max(1, [math]::Ceiling($sampled / $Cols))
  $font = 'C\:/Windows/Fonts/consola.ttf'
  $vf = "select='not(mod(n\,$Every))',drawtext=fontfile='$font':text='%{n}':x=6:y=6:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.5,scale=230:-1,tile=${Cols}x${rows}"
  $inpat = (Join-Path $out 'frame%08d.png')
  & ffmpeg -loglevel error -y -framerate $Fps -i $inpat -vf $vf -fps_mode passthrough -frames:v 1 (Join-Path $out 'sheet.png')
  if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed building the sheet" }
  & ffmpeg -loglevel error -y -framerate $Fps -i $inpat -c:v libx264 -pix_fmt yuv420p -crf 22 (Join-Path $out 'run.mp4') 2>$null

  $errors = Select-String -Path "$out\godot.log" -Pattern 'ERROR|SCRIPT ERROR|WARNING' | Select-Object -First 20
  Write-Host "==> $($pngs.Count) frames, sheet: $out\sheet.png  (tile n = frame n*$Every, $Every frames = $([math]::Round($Every/$Fps,2)) s)"
  if ($errors) { Write-Host "==> engine messages during the run:" -ForegroundColor Yellow; $errors | ForEach-Object { Write-Host "   $($_.Line)" } }
  else { Write-Host "==> no engine errors in the log" }
} finally { Pop-Location }
