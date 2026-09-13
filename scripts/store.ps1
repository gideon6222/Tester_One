<#
.SYNOPSIS
  Render every image a Play listing needs into store\listing\<locale>\images, at sizes
  Play accepts, from the real game.

.DESCRIPTION
  Reads store\store.json for which game states to photograph and how to cut the feature
  graphic, then writes:

    images\icon.png                      512x512 from icon.svg (or assets\icon\store.png if present)
    images\featureGraphic.png            1024x500, no alpha
    images\phoneScreenshots\N-<state>.png  one per state, at the project's full 1080x1920

  and measures every file against Play's limits (PLAY.md, The listing), refusing one Play
  would reject. Commit the result: the dashboard's Sync listing sends this folder to Play.

  Two traps this script exists to avoid, both measured on a sibling game:

  1. `shot.gd --resolution 1080x2160` does NOT give a 1080x2160 image. The window cannot be
     taller than the desktop, so Godot clamps it and the shot came back 1080x1061. The frame
     at the project's real size comes out of Movie Maker's offscreen buffer instead
     (`--write-movie`), which ignores the window entirely.

  2. The window's ASPECT still has to match that buffer's. With a 1080x1061 window and a
     1080x1920 buffer, the stretch transform is computed for the window and every Control
     anchored to an edge lands outside the captured frame. At 540x960, the same 16:9 the
     buffer is, the whole HUD renders. store.json's "window" is that size.

  1080x1920 is 16:9, inside Play's 2:1 cap. The phone's own 1080x2340 is 2.167:1 and is
  rejected, so a native grab is never a store screenshot.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\store.ps1
  powershell -ExecutionPolicy Bypass -File scripts\store.ps1 -Locale en-US -States title,play
#>
[CmdletBinding()]
param(
  [string] $Locale = 'en-US',
  [string[]] $States = @(),
  [switch] $SkipIcon
)
$ErrorActionPreference = 'Stop'

## `$ErrorActionPreference = 'Stop'` turns a native command's STDERR into a terminating
## error, and Godot writes its leak warnings there on every exit. The same wrapper
## movie.ps1 and check.ps1 carry, for the same reason.
function Native([scriptblock]$Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}

$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
  $godot = $env:GODOT
  if (-not $godot) {
    $godot = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
  }
  if (-not $godot) { throw "Godot not found; set `$env:GODOT" }
  $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
  if (-not $ffmpeg) { throw "ffmpeg not found on PATH" }
  $ffprobe = Join-Path (Split-Path $ffmpeg -Parent) 'ffprobe.exe'

  $cfgPath = Join-Path $root 'store\store.json'
  if (-not (Test-Path $cfgPath)) { throw "store\store.json is missing (store\README.md)" }
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $States -or $States.Count -eq 0) { $States = @($cfg.screenshots.states) }
  if ($States.Count -lt 2) { throw "Play wants at least two screenshots; store.json names $($States.Count) state(s)" }
  if ($States.Count -gt 8) { throw "Play allows at most eight screenshots; store.json names $($States.Count)" }
  $window = if ($cfg.screenshots.window) { [string]$cfg.screenshots.window } else { '540x960' }

  $out = Join-Path $root "store\listing\$Locale\images"
  $shots = Join-Path $out 'phoneScreenshots'
  New-Item -ItemType Directory -Force -Path $shots | Out-Null
  Get-ChildItem $shots -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
  $tmp = Join-Path $root 'build\store-frames'
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  New-Item -ItemType Directory -Path $tmp | Out-Null

  $n = 0
  $byState = @{}
  foreach ($state in $States) {
    $n++
    $stem = Join-Path $tmp "$state.png"
    # Movie Maker writes the project-size frame the window cannot show. See the header.
    Native { & $godot --path . --resolution $window --write-movie $stem --fixed-fps 60 `
      --script res://scripts/shot.gd -- $state store 2>&1 | Out-Null }
    $frame = Get-ChildItem $tmp -Filter "$state*.png" | Sort-Object Name | Select-Object -Last 1
    if (-not $frame) { throw "no frame rendered for state '$state' (scripts\shot.gd lists the states it knows)" }
    $shot = Join-Path $shots ("{0}-{1}.png" -f $n, $state)
    # Strip the alpha channel: Play takes 24-bit PNG or JPEG for screenshots.
    Native { & $ffmpeg -y -v error -i $frame.FullName -pix_fmt rgb24 $shot }
    $byState[$state] = $shot
    Get-ChildItem $tmp -Filter "$state*.png" | Remove-Item -Force
    Write-Host ("screenshot {0}  {1}" -f $n, (Split-Path $shot -Leaf))
  }

  # The feature graphic: a band cut from one screenshot, scaled to 1024x500, with the
  # wordmark drawn on the empty side. store.json says which state, where to cut, and which
  # font; a game with a real wordmark PNG can overlay that instead by editing this block.
  $feat = $cfg.feature
  $source = $byState[[string]$feat.source]
  if (-not $source) { $source = $byState[$States[0]] }
  $feature = Join-Path $out 'featureGraphic.png'
  $crop = if ($feat.crop) { [string]$feat.crop } else { '1010:493:0:600' }
  $vf = "crop=$crop,scale=1024:500"
  if ($feat.text) {
    # drawtext needs a font FILE on Windows: with none, ffmpeg asks fontconfig, which has no
    # config here, and writes nothing. store.json names one; otherwise the first .ttf under
    # assets\fonts, and failing that the system's Arial.
    $fontPath = if ($feat.font) { Join-Path $root ([string]$feat.font) } else { $null }
    if (-not $fontPath -or -not (Test-Path $fontPath)) {
      $fontPath = (Get-ChildItem (Join-Path $root 'assets') -Recurse -Filter '*.ttf' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $fontPath) { $fontPath = 'C:\Windows\Fonts\arial.ttf' }
    $font = $fontPath -replace '\\', '/' -replace ':', '\:'
    $size = if ($feat.fontsize) { [int]$feat.fontsize } else { 92 }
    $x = if ($feat.x) { [int]$feat.x } else { 56 }
    $text = ([string]$feat.text) -replace "'", ''
    $fontArg = if ($font) { "fontfile='$font':" } else { '' }
    $vf += ",drawtext=${fontArg}text='$text':fontcolor=white:fontsize=${size}:borderw=6:bordercolor=0x000000aa:x=${x}:y=h-text_h-46"
  }
  Native { & $ffmpeg -y -v error -i $source -vf $vf -pix_fmt rgb24 $feature }
  if (-not (Test-Path $feature)) { throw "ffmpeg did not write featureGraphic.png (filter: $vf)" }
  Write-Host "feature graphic  featureGraphic.png"

  if (-not $SkipIcon) {
    $icon = Join-Path $out 'icon.png'
    $ready = Join-Path $root 'assets\icon\store.png'
    if (Test-Path $ready) {
      Copy-Item $ready $icon -Force
      Write-Host "icon             icon.png (from assets\icon\store.png)"
    } else {
      $rel = "store/listing/$Locale/images/icon.png"
      Native { & $godot --headless --path . --script res://scripts/store_icon.gd -- $rel 2>&1 | Out-Null }
      if (-not (Test-Path $icon)) { throw "store_icon.gd did not write $rel" }
      Write-Host "icon             icon.png (from icon.svg)"
    }
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

  # Everything Play measures, so a bad size is caught here and not on upload.
  $bad = 0
  foreach ($f in @(Get-ChildItem $out -Filter '*.png') + @(Get-ChildItem $shots -Filter '*.png')) {
    $probe = Native { & $ffprobe -v error -select_streams v -show_entries stream=width,height,pix_fmt -of csv=p=0 $f.FullName }
    # As NUMBERS. Split gives strings, and "1080" -ge "320" is false.
    $parts = ([string]$probe).Trim().Split(',')
    $w = [int]$parts[0]; $h = [int]$parts[1]; $pix = $parts[2]
    $ratio = [math]::Round(([double][math]::Max($w, $h)) / ([double][math]::Min($w, $h)), 3)
    $ok = ($w -ge 320 -and $h -ge 320 -and $w -le 3840 -and $h -le 3840 -and $ratio -le 2.0)
    if ($f.Name -eq 'featureGraphic.png') { $ok = ($w -eq 1024 -and $h -eq 500 -and $pix -notmatch 'a') }
    if ($f.Name -eq 'icon.png') { $ok = ($w -eq 512 -and $h -eq 512) }
    Write-Host ("  {0,-28} {1}x{2} {3,-8} {4}" -f $f.Name, $w, $h, $pix, $(if ($ok) { 'ok' } else { 'REJECTED BY PLAY' }))
    if (-not $ok) { $bad++ }
  }
  if ($bad) { throw "$bad image(s) are not a size Play accepts" }
  Write-Host "`nstore images in store\listing\$Locale\images - commit them"
}
finally {
  Pop-Location
}
