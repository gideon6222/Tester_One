<#
.SYNOPSIS
  Everything that can run on the desk, in the order that fails fastest. Exit non-zero on the
  first failure. Run before every commit that touches src/ or test/.

  import -> pure tests -> smoke -> (visual guard if present) -> (size guard if an APK exists)
#>
[CmdletBinding()]
param([switch] $Export)   # also export the debug APK and run the size guard
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
    # `$ErrorActionPreference = 'Stop'` turns a native command's STDERR into a
    # terminating error BEFORE the exit-code check below it ever runs, so
    # -AllowFail could never fire and a step that merely chatted to stderr killed
    # the whole gate with a PowerShell stack trace instead of a result line.
    # Relaxing the preference around the call is the fix; the exit code and the
    # error count below are then the only things that decide.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # **Unwrap the ErrorRecords and write UTF-8, or the log is not what Godot
    # printed and the error count below is a lie.**
    #
    # `*> $log` sends a native command's stderr through PowerShell's error
    # channel, which renders each line as
    #   Godot_v4.7.2-stable_win64_console.exe : SCRIPT ERROR: ...
    # plus a `+ CategoryInfo` block, in UTF-16. So an anchored `^SCRIPT ERROR`
    # matched nothing, ever: the gate reported `errors 0` on a smoke run that
    # was throwing inside a check and skipping every assertion after it. It had
    # been blind in every step since the template was written.
    #
    # Calling ToString() on the ErrorRecord gives back the line Godot actually
    # wrote, and -Encoding utf8 makes the log greppable by anything else too.
    try {
      & $godot @a 2>&1 |
        ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Unwrap-ErrorLine $_ } else { $_ } } |
        Out-File -FilePath $log -Encoding utf8
    } finally { $ErrorActionPreference = $prev }
    $code = $LASTEXITCODE
    $errs = Select-String -Path $log -Pattern '^(SCRIPT |USER )?ERROR' | Measure-Object | Select-Object -ExpandProperty Count
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
  # The size guard now REFUSES a stale APK rather than measuring it, so this step
  # goes red when build/ holds an APK older than something you have edited. That
  # is the point - a sibling game's local check printed `size ok` for a whole
  # session about a build nobody had made that day - and the fix is to run this
  # script with -Export rather than to delete the APK.
  if ((Test-Path 'scripts\check_size.gd') -and (Get-ChildItem build -Filter *.apk -ErrorAction SilentlyContinue)) {
    Run 'size' 'build\check-size.log' @('--headless', '--path', '.', '--script', 'res://scripts/check_size.gd')
  }
  # THE FRAMEWORK'S OWN INVARIANTS, checked every time the gate runs.
  #
  # Everything above tests the game. This tests the things that are true of every
  # repo here and that nothing else notices when they rot: the export guards, the
  # .gitignore form that keeps build/.gdignore committable, version/code against
  # the changelog, template script drift, src/sim purity, the inbox backlog.
  #
  # It is here rather than in a skill because a sentence in a skill is what the
  # controls rule was, and that rule sat in three files while the same bug
  # shipped six times. The gate runs before every commit; a rule that runs with
  # it is a rule that fires.
  #
  # -Quiet prints only WARN and FAIL and skips the slow cross-repo passes, so it
  # costs a second or two. A FAIL here is a framework problem, not a game one,
  # and the line says which. If gamedev-notes is not on this machine the step is
  # skipped rather than failing - a missing knowledge base is not a broken game.
  $doctor = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'gamedev-notes\scripts\doctor.ps1'
  if (Test-Path $doctor) {
    $slug = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf
    $t = [Diagnostics.Stopwatch]::StartNew()
    & powershell -NoProfile -ExecutionPolicy Bypass -File $doctor -Repo $slug -Quiet
    $dcode = $LASTEXITCODE
    Write-Host ("{0,-14} {1}  {2:N1}s  exit {3}" -f 'framework', ($(if ($dcode -eq 0) { 'ok  ' } else { 'FAIL' })), $t.Elapsed.TotalSeconds, $dcode)
    if ($dcode -ne 0) {
      Write-Host "---- the FAIL lines above are about the framework, not this game's code" -ForegroundColor Yellow
      exit 1
    }
  } else {
    Write-Host ("{0,-14} skipped - no gamedev-notes on this machine" -f 'framework')
  }
  Write-Host "all green" -ForegroundColor Green
} finally { Pop-Location }
