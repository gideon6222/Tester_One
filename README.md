# Tester_One — Godot phone-game template

The stack a phone game starts from: Godot 4.7, a pure simulation core, headless tests, a
whole-run golden, an APK size guard, CI, a build stamp and a changelog.

It contains a placeholder game — a track, something to dodge, something to collect — so
the tests have something real to assert about. **Copy the repo to start a game; do not
grow this one.**

The repo is named `Tester_One` because it is the first native Android build here and the
name was chosen before there was a game in it. Nothing in the project depends on the repo
name, so renaming it later is safe.

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"

& $godot --headless --path . --script res://test/run_tests.gd    # pure tests
& $godot --headless --path . --script res://test/run_smoke.gd    # boots the real scene
& $godot --headless --path . --export-debug "Android" build/godot-template.apk
& $godot --path .                                                 # open the editor
```

`CLAUDE.md` has the toolchain paths and the invariants. `NOTES.md` has what is proven,
what is not, and what to do next.
