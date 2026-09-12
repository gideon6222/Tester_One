# Godot phone-game template

The thing a game is copied from: a Godot 4.7 project with a pure simulation core, headless
tests, a whole-run golden, a smoke test that boots the real scene, a size guard, CI that
attaches a signed APK to a Release, a build stamp, a changelog, a replay-driven film tool
and an adb tool for the phone.

@../gamedev-notes/INDEX.md

**This is not a game.** It carries just enough playable content (a track, something to
dodge, something to collect) for the tests to assert about. **Do not grow it into a game.**
`C:\dev\gamedev-notes\scripts\new-game.ps1` copies it; grow the copy.

The engine traps, the invariants every game keeps, the toolchain paths and the export and
signing rules are in `C:\dev\gamedev-notes\GODOT.md`. Read that before changing anything
here. This file only says what is in this repo and how to change it safely.

## Commands

```powershell
scripts\check.ps1                 # import, pure tests, smoke, size guard: the local gate
scripts\check.ps1 -Export         # plus the debug APK
scripts\movie.ps1 -Seconds 10 -Name idle
scripts\device.ps1 install | launch | log | shot | record 30 | perf
& $env:GODOT --path . --resolution 460x996 --script res://scripts/shot.gd -- 14.0
& $env:GODOT --path . --resolution 460x996 --script res://scripts/shot.gd -- 45 hit   # a named STATE
& $env:GODOT --path . --resolution 460x996 --script res://scripts/rects.gd            # control rects for a replay
& $env:GODOT --path .              # the editor
```

## Files

| File | What it is |
|---|---|
| `src/sim/sim.gd` | **The whole game, with no renderer in it** |
| `src/sim/tuning.gd` | Every number that shapes how it feels, plus the derived arithmetic |
| `src/sim/util.gd` | `smooth`, `hash2`, `fmt`. The hash is load-bearing and tested |
| `src/sim/rng.gd` | A seeded stream for values that decide *when* something happens |
| `src/sim/save.gd` | The save as a pure `Sim` <-> `Dictionary` pair. `apply` restores every field or returns false. The `user://` wrapper at the bottom is twelve lines and nothing calls it yet |
| `src/game/main.gd` | The shell: reads `Sim`, draws it, feeds it input. Decides nothing. Anchored HUD and a thumb pad already wired |
| `src/game/main.tscn` | One node with the script; the world is built in code |
| `src/build_stamp.gd` | Overwritten by CI. Committed fallback says `dev` |
| `src/changelog.gd` | `VERSION` and the player-facing history |
| `test/policies.gd` | Scripted players. **The definition of "playing well"** |
| `test/run_tests.gd` | Pure tests, discovered by GLOB. Fails on an empty glob and on an assertion count below `MIN_ASSERTIONS` |
| `test/test_version.gd` | `VERSION` == `version/name` AND `version/code` in every export preset |
| `test/test_sim_boundary.gd` | Standing rule 2 as a gate: reads every file under `src/sim` and fails on a Node, a Viewport, an input event or an unseeded roll |
| `test/test_save.gd` | The other half of rule 2: the save round trip, with no file open anywhere in it. Also checks `save.gd`'s field list against `Sim`'s own properties |
| `test/test_controls.gd` | **The handedness gate.** A real drag event through the real handler, asserting where the avatar lands ON SCREEN |
| `test/run_smoke.gd` | Boots the real scene, plays it, drives through the level boundary |
| `test/run_probe.gd` | Balance readings. Prints; never fails |
| `test/harness.gd` | The assertions, deliberately small, with `FLOAT_EPS` |
| `test/replays/` | Recorded touch scenarios for `movie.ps1` |
| `scripts/replay_player.gd` | Autoload. `-- record=<file>`, `-- replay=<file>`, `-- touch` |
| `scripts/movie.ps1` | Film a deterministic run into a contact sheet |
| `scripts/device.ps1` | The phone over adb |
| `scripts/check.ps1` | The local gate in the order that fails fastest |
| `scripts/shot.gd` | Screenshot at the PHONE's aspect ratio, at a time or in a named state, into `build/shot[_state].png` |
| `scripts/rects.gd` | Every `Control`'s real global rect, in the space a replay is written in |
| `scripts/check_size.gd` | APK size guard, fails in both directions |
| `scripts/stamp.ps1`, `scripts/export_release.bat` | Build stamp; Play AAB with the quotes intact |
| `.github/workflows/build.yml` | Tests, APK on every push, AAB on a `v*` tag |

## Placeholders the scaffold renames

`godot-template` (paths), `godottemplate` (package id), `Godot Template` (display name),
`com.gideon.godottemplate`. `new-game.ps1` replaces all four in every text file and fails if
any survive, so a new file that needs the game's name must use one of these exact strings.

## Changing the template

- A change here reaches only games copied after it. When a fix belongs in existing games
  too, apply it there by hand and `/record-lesson`.
- Every change must leave `scripts\check.ps1` green and CI green, because a fresh copy
  proves itself with these before its first push.
- Keep the placeholder game minimal. The tests need something to assert about; they do
  not need a second game.
- The remote is `github.com/gideon6222/Tester_One` for historical reasons. Nothing depends
  on the name.
