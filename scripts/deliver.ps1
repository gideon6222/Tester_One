<#
.SYNOPSIS
  One call from a finished piece of work to a playable build on the phone: gate, stamp,
  export, install. Nothing here is new - it is stamp.ps1, check.ps1 -Export, phone.ps1 and
  device.ps1 in the one order that is safe - and the value is that a session can call it at
  every beat without thinking about the cost.

.DESCRIPTION
  MEASURED COST: 18.6 s end to end on the template, of which 10.6 s is the export itself
  (this PC, 2026-09-13). That is the whole reason this script exists. Getting a build onto
  the handset had never been timed, so it was treated as a ship-sized act and rationed to a
  full playtest or a /ship - which is how Gideon ended up with a phone holding a build from
  two days ago and no way to judge the work in front of him.

  Called at three beats (INDEX.md rule 3): a milestone box ticked, a change to what the
  player sees, hears or feels, and every stop-and-report, beside status.ps1 -State waiting.
  Not for a refactor, a test-only change or prose.

  EVERY REFUSAL HERE IS A DELIBERATE exit 0, AND ONLY ONE THING FAILS.

    nothing moved       exit 0, no export. This is what makes calling it at every beat free.
    a red gate          exit 1. THE ONLY FAILING EXIT. It costs about 8 s more than a bare
                        export and it is what guarantees he never receives a red build.
    nothing plugged in  exit 0, prints the APK path. The build is ready for the next cable.
    the phone is busy   exit 0. Another game has the handset; the next beat delivers.

  A caller may therefore run this and ignore the result, and the only thing it can ever stop
  is a commit that was going to hand him a broken build anyway.

  IT TOUCHES NO GITHUB AND SPENDS NO CI MINUTES. Pushing is still on purpose (INDEX.md rule
  3); this is the local cable, and the two are independent.

.EXAMPLE
  scripts\deliver.ps1          # gate, stamp, export, and onto the phone if it is there
  scripts\deliver.ps1 -Show    # what was last delivered, and whether it reached the handset
#>
[CmdletBinding()]
param([switch] $Show)

$ErrorActionPreference = 'Stop'

## Native commands write progress and warnings to STDERR, and $ErrorActionPreference = 'Stop'
## turns any of that into a terminating error BEFORE an exit code can be read. adb and git
## are both offenders on a completely successful run. Same helper, same reason, as
## scripts\device.ps1.
function Native([scriptblock] $Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
$root = [System.IO.Path]::GetFullPath((Join-Path $here '..'))
$slug = Split-Path $root -Leaf
$buildDir = Join-Path $root 'build'
$record = Join-Path $buildDir 'last-delivery.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if ($Show) {
  if (Test-Path -LiteralPath $record) { Write-Output ([System.IO.File]::ReadAllText($record)) }
  else { Write-Output "deliver: nothing delivered from $root yet" }
  exit 0
}

$presets = Join-Path $root 'export_presets.cfg'
if (-not (Test-Path -LiteralPath $presets)) { throw "no export_presets.cfg in $root" }
$apkRel = [regex]::Match(([System.IO.File]::ReadAllText($presets)), 'export_path="([^"]+\.apk)"').Groups[1].Value
if (-not $apkRel) { throw "no .apk export_path in $presets" }
$apk = Join-Path $root $apkRel

## Atomic, the pattern scripts\status.ps1 uses: a whole temp file then one Move-Item -Force,
## so a reader can never see half of it. build\ is gitignored, so this is never committed.
function Write-Record([string] $Head, [string] $Stamp, [bool] $Installed, [string] $Reason) {
  $bytes = 0
  $apkUtc = ''
  if (Test-Path -LiteralPath $apk) {
    $item = Get-Item -LiteralPath $apk
    $bytes = $item.Length
    # The APK's OWN modified time, not the time this record was written. The retry path below
    # uses it to prove the file on disk is still the one this gate produced, and comparing
    # against the record's `utc` could never do that: the export always finishes BEFORE the
    # record is written, so an "APK no older than the record" test is false every single time
    # and the cheap path would have silently re-exported for ever.
    $apkUtc = $item.LastWriteTimeUtc.ToString('o')
  }
  $r = [ordered]@{
    slug      = $slug
    utc       = [datetimeoffset]::UtcNow.ToString('o')
    head      = $Head
    stamp     = $Stamp
    apkBytes  = $bytes
    apkUtc    = $apkUtc
    installed = $Installed
    reason    = $Reason
  }
  $tmp = $record + '.tmp'
  [System.IO.File]::WriteAllText($tmp, ($r | ConvertTo-Json -Depth 3), $utf8)
  Move-Item -LiteralPath $tmp -Destination $record -Force
}

# git is asked, never trusted: a repo with no commits yet leaves these empty rather than
# aborting, the fallback shape scripts\stamp.ps1 and scripts\status.ps1 both use.
$head = ''
try { $head = (Native { & git -C $root rev-parse --short=7 HEAD 2>$null } | Out-String).Trim() } catch { }
# src/build_stamp.gd is excluded for the reason stamp.ps1 excludes it: this script rewrites
# it on every run, so counting it would make every tree look dirty for ever.
$dirty = ''
try {
  $dirty = (Native { & git -C $root status --porcelain 2>$null } |
    Where-Object { $_ -notmatch 'src/build_stamp\.gd' } | Out-String).Trim()
} catch { }

# ---------------------------------------------------------------------------
# Nothing moved. The cheap path, and the one that earns the right to be called often.
#
# The skip needs `installed` to be true, not just a matching head: a delivery that stopped
# at a busy phone or a missing cable has NOT reached him, and skipping on the head alone
# would make "the next beat delivers" a lie for the rest of that commit's life. When the
# head matches and the build was never installed, the export is still skipped - a green APK
# built from this exact commit on a clean tree is already on disk - and only the phone half
# is retried. So a cable plugged in later costs seconds, not a rebuild.
# ---------------------------------------------------------------------------
$retryPhoneOnly = $false
if ($head -and -not $dirty -and (Test-Path -LiteralPath $record)) {
  $last = $null
  try { $last = [System.IO.File]::ReadAllText($record) | ConvertFrom-Json } catch { $last = $null }
  if ($last -and $last.head -eq $head) {
    if ($last.installed) {
      Write-Host "already delivered $head (stamp $($last.stamp)) - nothing to do"
      exit 0
    }
    # The APK must still be there and be untouched since the gate produced it, or "already
    # built" is a guess about a file something else may have replaced.
    if ($last.apkUtc -and (Test-Path -LiteralPath $apk) -and
        (Get-Item -LiteralPath $apk).LastWriteTimeUtc.ToString('o') -eq $last.apkUtc) {
      $retryPhoneOnly = $true
      Write-Host "$head was built and gated but never installed ($($last.reason)) - retrying the phone only"
    }
  }
}

$stampSha = ''
if ($retryPhoneOnly) {
  $stampSha = "$($last.stamp)"
} else {
  # -----------------------------------------------------------------------
  # Stamp, gate, export - and put the stamp back.
  #
  # The stamp is what lets him read off the title screen which commit is on his phone, and
  # stamp.ps1's `+` marker correctly says the build came from an uncommitted tree. But the
  # committed fallback is "dev"/"unbuilt" on purpose, so the file is restored afterwards and
  # this script leaves no diff behind. Restored by writing the text back through
  # System.IO.File with a UTF8Encoding($false), the way stamp.ps1 itself reads and writes it:
  # never `git checkout -- <file>`, which would also discard a real edit somebody is holding,
  # and never Get-Content/Set-Content, which reads a BOM-less file as ANSI and mangles every
  # non-ASCII byte.
  #
  # **THE MODIFIED TIME IS PUT BACK TOO, AND THAT IS NOT A DETAIL.** scripts\check_size.gd
  # refuses to measure an APK older than any source file, so restoring only the text left
  # build_stamp.gd four seconds newer than the APK the export had just written - and the very
  # next bare `scripts\check.ps1`, which every commit runs, went red on the size guard about a
  # build that was perfectly fine. Measured on the template, 2026-09-13, first run of this
  # script. Putting the stamp back means putting it back in both senses, so a delivery leaves
  # no trace at all: not in `git status`, and not in the next gate either.
  # -----------------------------------------------------------------------
  $stampPath = Join-Path $root 'src\build_stamp.gd'
  if (-not (Test-Path -LiteralPath $stampPath)) { throw "no src\build_stamp.gd in $root" }
  $original = [System.IO.File]::ReadAllText($stampPath, $utf8)
  $originalTime = (Get-Item -LiteralPath $stampPath).LastWriteTimeUtc
  $gateCode = 0
  $gateOut = @()
  # **Run from the repo root, because scripts\stamp.ps1 reads git from the CURRENT DIRECTORY.**
  # It calls `git rev-parse --short=7 HEAD` with no -C, so a child process inherits whatever
  # directory the caller happened to be in. Measured 2026-09-13: called from a session sitting
  # in C:\dev\gamedev-notes, it stamped THAT repo's head (a57961b) onto the template's build
  # while the template was on bb31379 - a title screen naming a commit the game does not
  # contain, which is worse than no stamp at all, because he reads it to know what he is
  # holding. check.ps1 is safe on its own (it does its own Push-Location) and this covers it too.
  Push-Location $root
  try {
    $stampOut = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'stamp.ps1') 2>&1 }
    foreach ($l in @($stampOut)) { Write-Host "   $l" }
    $stampSha = [regex]::Match((@($stampOut) -join "`n"), 'stamped (\S+)').Groups[1].Value

    Write-Host "gate and export (about 19 s)..."
    $gateOut = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'check.ps1') -Export 2>&1 }
    $gateCode = $LASTEXITCODE
    foreach ($l in @($gateOut)) { Write-Host "   $l" }
  } finally {
    Pop-Location
    [System.IO.File]::WriteAllText($stampPath, $original, $utf8)
    (Get-Item -LiteralPath $stampPath).LastWriteTimeUtc = $originalTime
  }

  # A red gate is the only failing exit, and it deliberately writes NO record: the record
  # means "a green build for this head exists on disk", and a head that has never produced
  # one must not be skipped by the cheap path above.
  if ($gateCode -ne 0) {
    Write-Host "deliver: the gate is red, so nothing was installed. The build above is not his to play." -ForegroundColor Red
    exit 1
  }
}

# ---------------------------------------------------------------------------
# Is a handset attached at all? The read-only, lease-free action (phone.ps1 devices): it asks
# the local adb server which handsets are plugged in, reads nothing on the phone and changes
# nothing on it. Asking this before claiming keeps "nothing plugged in" and "another game has
# it" as the two different answers they are.
# ---------------------------------------------------------------------------
$phoneScript = 'C:\dev\gamedev-notes\scripts\phone.ps1'
# A delivery goes to HIS phone, the main role, never the floor phone. When its serial is
# recorded, adb is pointed at it so a second handset on the cable cannot take the build.
if (Test-Path -LiteralPath $phoneScript) {
  $mainSerial = (Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript serial -Phone main 2>$null }) -join ''
  if ($mainSerial.Trim()) { $env:ANDROID_SERIAL = $mainSerial.Trim() }
}
if (-not (Test-Path -LiteralPath $phoneScript)) {
  Write-Host "no $phoneScript on this machine, so the phone is left alone. APK: $apk"
  Write-Record $head $stampSha $false 'no knowledge base, so no phone lease'
  exit 0
}
$devices = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript devices 2>&1 }
foreach ($l in @($devices)) { Write-Host "   $l" }
$devicesText = @($devices) -join "`n"
if ($devicesText -notmatch 'phone connected') {
  # 'not connected' and 'presence unknown' are kept apart in the record on purpose. The second
  # means adb never answered, so the build may well be deliverable and the next beat should
  # find out; reading it as an absent handset is how a delivery stops happening silently.
  $why = if ($devicesText -match 'presence unknown') { 'adb did not answer, so presence is unknown' } else { 'no phone attached' }
  Write-Host "$why, so the build waits on disk for the next cable. APK: $apk"
  Write-Record $head $stampSha $false $why
  exit 0
}

# **"A phone is connected" is not "THIS phone is connected."**
#
# `devices` correctly names EVERY attached role, so with only the floor phone on the cable
# that string still matches - and the install below is addressed to main's serial, which is
# not there. device.ps1 then throws and the run ends `not delivered: install failed (exit 1)`,
# which is the code this script reserves for a RED GATE. A beat whose whole contract is "free
# to call, exits 0 when the phone is unplugged" reported what looks exactly like a broken
# build. Measured on gravewell 2026-09-14 with the S22+ alone on the cable.
#
# A different role attached is the NO-PHONE answer: name the APK and let the next beat deliver.
if ($mainSerial -and $mainSerial.Trim() -and $devicesText -notmatch [regex]::Escape($mainSerial.Trim())) {
  $why = 'the main phone is not on the cable, though another role is'
  Write-Host "$why, so the build waits on disk. APK: $apk"
  Write-Record $head $stampSha $false $why
  exit 0
}

# ---------------------------------------------------------------------------
# Claim it HERE, rather than letting scripts\device.ps1 refuse.
#
# This is the whole reason the claim is not left to device.ps1: its refusal path writes a
# `PHONE TEST OWED` line into NOTES.md, which scripts\doctor.ps1 (Test-PhoneDebt) then warns
# on until somebody clears it. A DELIVERY IS NOT A PHONE TEST. Missing one because another
# game had the handset for three minutes owes nobody anything - the next beat delivers - and
# a debt line for it would train every session to ignore the real ones.
#
# Three minutes, because an install is seconds. device.ps1 install below claims again under
# the same owner, which renews rather than blocks, so the effective hold is its own 20
# minutes and the release in the finally is what actually gives the phone back.
# ---------------------------------------------------------------------------
$claim = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $phoneScript claim -Owner $slug -Minutes 3 2>&1 }
$claimCode = $LASTEXITCODE
foreach ($l in @($claim)) { Write-Host "   $l" }
if ($claimCode -eq 75) {
  $who = [regex]::Match((@($claim) -join "`n"), 'held by ([^\s,]+)').Groups[1].Value
  if (-not $who) { $who = 'another game' }
  Write-Host "phone busy: $who has it, delivering at the next beat"
  Write-Record $head $stampSha $false "phone busy, held by $who"
  exit 0
}

$installed = $false
$reason = ''
try {
  $out = Native { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'device.ps1') install 2>&1 }
  $code = $LASTEXITCODE
  $text = @($out) -join "`n"
  foreach ($l in @($out)) { Write-Host "   $l" }
  if ($code -eq 0 -and $text -match 'installed ') {
    $installed = $true
  } else {
    $reason = "install failed (exit $code)"
    # The one install failure with a one-line fix. It means the APK on the phone was signed
    # with a different key than this one, and it SHOULD NOT HAPPEN here: new-game.ps1 sets
    # ANDROID_DEBUG_KEYSTORE_B64 from the same C:\dev\toolchain\debug.keystore this local
    # export signs with, so CI's build and this one carry one signature. If it does happen,
    # something replaced one of those two.
    if ($text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match') {
      $reason = 'signature mismatch with the build already on the phone'
      Write-Host "   fix: scripts\device.ps1 uninstall, then run deliver.ps1 again." -ForegroundColor Yellow
      Write-Host "   This should not happen: CI signs with the same C:\dev\toolchain\debug.keystore this export does," -ForegroundColor Yellow
      Write-Host "   so if it does, check ANDROID_DEBUG_KEYSTORE_B64 against that file." -ForegroundColor Yellow
    }
  }
} finally {
  Native { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'device.ps1') release 2>&1 } | ForEach-Object { Write-Host "   $_" }
}

Write-Record $head $stampSha $installed $reason
if ($installed) {
  Write-Host "delivered $stampSha to the phone - he can pick it up and play it" -ForegroundColor Green
} else {
  Write-Host "not delivered: $reason. The green APK is at $apk" -ForegroundColor Yellow
}
exit 0
