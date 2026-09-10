<#
.SYNOPSIS
  Everything that can run on the desk, in the order that fails fastest. Exit non-zero on the
  first failure. Run before every commit that touches src/ or test/.

  import -> pure tests -> smoke -> (visual guard if present) -> (size guard if an APK exists)
#>
[CmdletBinding()]
param([switch] $Export)   # also export the debug APK and run the size guard
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $root
try {
  $godot = $env:GODOT
  if (-not $godot) { $godot = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe" | Select-Object -First 1).FullName }
  if (-not $godot) { throw "Godot not found; set `$env:GODOT" }
  New-Item -ItemType Directory -Force -Path build | Out-Null

  function Run($label, $log, [string[]] $a, [switch] $AllowFail) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    & $godot @a *> $log
    $code = $LASTEXITCODE
    $errs = Select-String -Path $log -Pattern '^(SCRIPT )?ERROR' | Measure-Object | Select-Object -ExpandProperty Count
    $ok = ($code -eq 0 -and $errs -eq 0) -or $AllowFail
    Write-Host ("{0,-14} {1}  {2:N1}s  exit {3}  errors {4}" -f $label, ($(if ($ok) { 'ok  ' } else { 'FAIL' })), $t.Elapsed.TotalSeconds, $code, $errs)
    if (-not $ok) {
      Write-Host "---- first 30 lines of $log (a parse error is at the TOP, not the end)" -ForegroundColor Yellow
      Get-Content $log | Select-Object -First 30
      exit 1
    }
  }

  Run 'import' 'build\check-import.log' @('--headless', '--path', '.', '--import') -AllowFail
  Run 'tests' 'build\check-tests.log' @('--headless', '--path', '.', '--script', 'res://test/run_tests.gd')
  Run 'smoke' 'build\check-smoke.log' @('--headless', '--path', '.', '--script', 'res://test/run_smoke.gd')
  if (Test-Path 'test\run_visual.gd') {
    Run 'visual' 'build\check-visual.log' @('--path', '.', '--resolution', '460x996', '--script', 'res://test/run_visual.gd')
  }
  if ($Export) {
    $apk = [regex]::Match((Get-Content export_presets.cfg -Raw), 'export_path="([^"]+\.apk)"').Groups[1].Value
    Run 'export' 'build\check-export.log' @('--headless', '--path', '.', '--export-debug', 'Android', $apk)
  }
  if ((Test-Path 'scripts\check_size.gd') -and (Get-ChildItem build -Filter *.apk -ErrorAction SilentlyContinue)) {
    Run 'size' 'build\check-size.log' @('--headless', '--path', '.', '--script', 'res://scripts/check_size.gd')
  }
  Write-Host "all green" -ForegroundColor Green
} finally { Pop-Location }
