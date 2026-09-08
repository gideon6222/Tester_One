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


static func line() -> String:
	return "v%s  ·  %s  ·  %s" % [Changelog.VERSION, SHA, BUILT]
