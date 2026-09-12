# Template scripts this game has deliberately changed

One filename per line. `scripts\doctor.ps1` skips these in its template-drift check, so the
WARN it prints only ever names a difference nobody has read yet. Add a name here only after
reading the diff against `C:\dev\godot-template\scripts` and deciding this game is right to
differ. A template fix that should be forward-ported is not divergence: port it, then it
matches again.

export_release.bat   the output filename carries this game's slug (rewritten by new-game.ps1)
check_size.gd        per-game size budget
rects.gd             names this game's own nodes
shot.gd              photographs this game's own rooms
