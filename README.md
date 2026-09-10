# Godot phone-game template

The stack a phone game starts from: Godot 4.7, a pure simulation core, headless tests, a
whole-run golden, an APK size guard, CI, a build stamp, a changelog, a replay-driven film
tool and an adb tool for the phone.

It contains a placeholder game (a track, something to dodge, something to collect) so the
tests have something real to assert about. **Copy the repo to start a game; do not grow this
one.** `C:\dev\gamedev-notes\scripts\new-game.ps1 -Slug <slug> -Name "<Name>"` does the copy,
the rename, the GitHub repo, the secrets and the first build.

```powershell
scripts\check.ps1                                  # tests, smoke, guards
scripts\check.ps1 -Export                          # plus build\godot-template.apk
scripts\movie.ps1 -Seconds 10 -Name idle           # film it
scripts\device.ps1 install                         # onto the phone
```

`CLAUDE.md` says what is here. `C:\dev\gamedev-notes\GODOT.md` has the toolchain and the
traps. `NOTES.md` has what is proven and what to do next.
