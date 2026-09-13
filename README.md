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
scripts\movie.ps1 -Seconds 60 -Name bot -UserArgs policy=dodger   # film a BOT playing it
scripts\movie.ps1 -State level2 -Seconds 5 -UserArgs policy=dodger  # film IN a situation
scripts\device.ps1 install                         # onto the phone
scripts\deliver.ps1                                # gate, export, stamp and onto the phone
scripts\status.ps1 -Doing "..." -Next "..."        # this session's status line for the dashboard
```

**Film from the situation, not from the beginning.** `Main.dev_states()` publishes the
situations this game can be put into and `Main.dev_seek()` puts it in one; `-State <name>`
on the film tool and a bare word on `shot.gd` both ask for one by name, and a name ending in
`.json` is an exact saved run. Measured here on 2026-09-13, five seconds of level 2 cost
216.0 s and 100.7 MB by playing to it and 37.3 s and 14.9 MB by seeking to it. A game
built from this template adds arms to `dev_seek`, not `shot_*.gd` files.

**A long film says early whether it is getting anything.** Every run passes `beat` to the
game, which prints `DEVBEAT` lines from `Main.dev_heartbeat()`. `-StallSeconds` (45) kills a
run whose numbers have stopped changing and `-MaxMinutes` (15) is the wall clock, so a stuck
run costs half a minute rather than the whole budget; and a film whose first and last
readings are identical is an error rather than a plausible contact sheet.

`CLAUDE.md` says what is here. `C:\dev\gamedev-notes\GODOT.md` has the toolchain and the
traps. `NOTES.md` has what is proven and what to do next.
