class_name BuildStamp
extends RefCounted

## Overwritten by CI (and by scripts/stamp.ps1 locally) immediately before an
## export. The values below are the committed fallback, so a fresh clone always
## builds - a generated file that has to exist before the project opens is a
## file that must be committed.
##
## The stamp answers "did my update actually land", which is otherwise
## unanswerable on a phone: an installed app can be a version behind, and the
## game is meant to look identical between builds. The changelog answers "what
## changed" - different question, and both are wanted in the same place.

const SHA := "dev"
const BUILT := "unbuilt"


## Deliberately ASCII-only, as belt and braces.
##
## scripts/stamp.ps1 rewrites this file on every build. It now reads and writes
## through .NET with an explicit encoding, which is the actual fix - but the
## bug it had before (PowerShell 5.1 reads a BOM-less file as ANSI and writes
## it back as UTF-8) turned a middle dot here into mojibake and, the same day,
## a regex in another repo into one that could never match. Neither looked
## wrong in a diff. A file that a script rewrites is worth keeping free of any
## character a re-encoding can change.
static func line() -> String:
	return "v%s | %s | %s" % [Changelog.VERSION, SHA, BUILT]
