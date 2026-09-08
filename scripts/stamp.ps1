# Writes src/build_stamp.gd from the current git state, immediately before an
# export. CI runs the same thing; see .github/workflows/build.yml.
#
# The committed fallback says "dev" / "unbuilt", and the smoke test asserts the
# stamp is NOT that after a build - so a broken stamp pipeline fails the build
# rather than shipping a lie to the phone.

$ErrorActionPreference = "Stop"

$sha = $env:GITHUB_SHA
if ($sha) {
    # CI checks out a detached head; GITHUB_SHA is authoritative there.
    $sha = $sha.Substring(0, 7)
} else {
    # Locally. `git rev-parse HEAD` fails on a repository with no commits yet,
    # and PowerShell turns a native command's stderr into a terminating error
    # under `ErrorActionPreference = Stop` - so a brand new repo would abort
    # the whole build here rather than fall back. Catch it.
    try {
        $sha = (& git rev-parse --short=7 HEAD 2>$null | Out-String).Trim()
    } catch {
        $sha = ""
    }
    if (-not $sha) {
        $sha = "nogit"
    } else {
        # Mark a dirty tree with '+', so a stamp read off a phone is never
        # mistaken for a commit that actually exists.
        $dirty = (& git status --porcelain 2>$null | Out-String).Trim()
        if ($dirty) { $sha = "$sha+" }
    }
}

$built = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")

$path = Join-Path $PSScriptRoot "..\src\build_stamp.gd"
$text = Get-Content $path -Raw
$text = $text -replace 'const SHA := "[^"]*"', ('const SHA := "' + $sha + '"')
$text = $text -replace 'const BUILT := "[^"]*"', ('const BUILT := "' + $built + '"')
Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline

Write-Output "stamped $sha  $built"
