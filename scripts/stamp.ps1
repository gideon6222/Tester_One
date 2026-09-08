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
        #
        # build_stamp.gd itself is excluded: this script rewrites it on every
        # build, so counting it would make every stamp say dirty forever - and
        # a marker that is always on carries no information.
        $dirty = (& git status --porcelain 2>$null |
            Where-Object { $_ -notmatch 'src/build_stamp\.gd' } |
            Out-String).Trim()
        if ($dirty) { $sha = "$sha+" }
    }
}

$built = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")

# Read and write through .NET with an explicit UTF-8-without-BOM encoding.
#
# `Get-Content -Raw` + `Set-Content -Encoding utf8` looks equivalent and is not:
# PowerShell 5.1 reads a file with no BOM as ANSI, so every non-ASCII byte is
# reinterpreted, and then written back as UTF-8. A middle dot in this very file
# became mojibake that way, and the same mistake broke a regex in another repo
# on the same day. Round-tripping a source file through a shell is worth doing
# carefully or not at all.
$path = Join-Path $PSScriptRoot "..\src\build_stamp.gd"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($path, $utf8)
$text = $text -replace 'const SHA := "[^"]*"', ('const SHA := "' + $sha + '"')
$text = $text -replace 'const BUILT := "[^"]*"', ('const BUILT := "' + $built + '"')
[System.IO.File]::WriteAllText($path, $text, $utf8)

Write-Output "stamped $sha  $built"
