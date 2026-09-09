# Godot phone-game template

The proving stack for Gideon's native Android games: a Godot 4 project with headless
tests, a whole-run golden, a size guard, CI, and an APK that installs on the phone.

**This is not a game.** It is the thing a game is copied from. It contains just enough
playable content — a track, something to dodge, something to collect — for the tests to
have something real to assert about.

**Read `C:\dev\gamedev-notes` first** — `SKILL.md` (process), `CRAFT.md` (design lessons,
all of which apply here; they are about games, not about JavaScript), `PIPELINE.md` (the
web stack and the shared principles), `ASSETS.md`, `PLAYTESTS.md`.

---

## Toolchain, and where it lives

Nothing is installed system-wide and nothing needed admin rights. Portable, under
`C:\dev\toolchain\`:

| Piece | Version | Path |
|---|---|---|
| Godot | 4.7.2 stable | `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\Godot_v4.7.2-stable_win64_console.exe` |
| JDK | Temurin 17.0.20.1 | `C:\dev\toolchain\jdk\jdk-17.0.20.1+1` |
| Android SDK | platform 36, build-tools 36.0.0, platform-tools 37.0.1 | `C:\dev\toolchain\android-sdk` |
| Debug keystore | | `C:\dev\toolchain\debug.keystore` (alias `androiddebugkey`, pass `android`) |
| Export templates | 4.7.2.stable | `%APPDATA%\Godot\export_templates\4.7.2.stable` |

Godot finds the SDK, the JDK and the keystore through **editor settings**, not through
environment variables — `%APPDATA%\Godot\editor_settings-4.7.tres`, keys under
`export/android/`. Setting `ANDROID_HOME` alone does nothing; that costs half an hour if
you do not know it.

## Commands

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"

& $godot --headless --path . --import                                   # after adding files
& $godot --headless --path . --script res://test/run_tests.gd           # pure tests, ~1s
& $godot --headless --path . --script res://test/run_smoke.gd           # boots the real scene
& $godot --headless --path . --export-debug "Android" build/godot-template.apk
& $godot --headless --path . --script res://scripts/check_size.gd       # size guard
& $godot --path .                                                        # open the editor
```

Every one exits non-zero on failure, which is what makes them a CI gate rather than
something to read.

## Files

| File | What it is |
|---|---|
| `src/sim/sim.gd` | **The whole game, with no renderer in it.** |
| `src/sim/tuning.gd` | Every number that shapes how it feels, plus the derived arithmetic |
| `src/sim/util.gd` | `smooth`, `hash2`, `fmt` — pure, and the hash is load-bearing |
| `src/sim/rng.gd` | A seeded stream for values that decide *when* something happens |
| `src/game/main.gd` | The shell: reads `Sim`, draws it, feeds it input. Decides nothing |
| `src/game/main.tscn` | Four lines. One node with the script; the world is built in code |
| `src/build_stamp.gd` | Overwritten at build time. Committed fallback says `dev` |
| `src/changelog.gd` | `VERSION` and the player-facing history |
| `test/policies.gd` | Scripted players. **The definition of "playing well"** |
| `test/run_tests.gd` | Pure tests. No node, no viewport, no GPU |
| `test/run_smoke.gd` | Boots the real scene and plays it |
| `test/run_probe.gd` | Balance readings over several levels. Prints; never fails |
| `test/harness.gd` | The assertions. Deliberately small — see NOTES.md |
| `scripts/shot.gd` | Screenshot of the real game, at the PHONE's aspect ratio |
| `scripts/check_size.gd` | APK size guard, fails in both directions |
| `scripts/stamp.ps1` | Writes the build stamp from git |

## Copying this to start a game

```powershell
Copy-Item -Recurse C:\dev\godot-template C:\dev\<game>
Remove-Item -Recurse -Force C:\dev\<game>\.git, C:\dev\<game>\.godot, C:\dev\<game>\android, C:\dev\<game>\build
```

Then `git init`, and rename in five places: `project.godot` (`config/name`,
`config/description`), `export_presets.cfg` (`package/unique_name`, `package/name`, and BOTH
`export_path` lines), `README.md`, `CLAUDE.md`, and `scripts/check_size.gd` (the APK path).
Reset `src/changelog.gd` to 0.1.0 with a fresh entry. Ask Gideon to create an empty public
repo and push into it; he does that part.

**Do not grow this repo into a game.** Copy it and grow the copy, or the next game starts
from something already shaped by the last one.

**Set `ANDROID_DEBUG_KEYSTORE_B64` as a repository secret** from
`C:\dev\toolchain\debug.keystore`, base64-encoded, before the second build matters. CI
generates a throwaway key otherwise, so every build is signed differently and Android refuses
to update the app in place.

## Invariants

- **`src/sim/` may not reference a Node, a Viewport, an input event or a real frame.**
  That one rule is what makes a whole-run golden test possible and what lets the whole
  renderer be replaced without touching game logic. If something in there needs to know
  about the world, it takes it as an argument.
- **Nothing that affects game state may use `randf()`.** Place-keyed decisions go through
  `SimUtil.hash2` seeded on (chunk, level); stream-like values go through `SimRng`.
  Cosmetic jitter may use `randf()`. The trap is that "cosmetic" is not obvious — **a
  value that decides *when* something happens is simulation**, even if it looks like
  decoration. On the sibling web game, loot scatter velocity looked decorative and was
  deciding when score landed, which made the golden flake one run in ten.
- **The hash uses unsigned shifts on a masked 32-bit value.** A signed shift clears the
  top bit and the function silently returns only `[0, 0.5)` — which disabled three
  shipped mechanics on another game for its entire life, with no error. `test_util.gd`
  asserts the range and the distribution.
- **`_ready` does not run at `add_child()`.** It is deferred to the first processed
  frame, so a headless harness that adds the scene and immediately steps it finds every
  field null. `main.gd` guards this with `_ensure_booted()`; keep that guard.
- **Use `Transform3D.looking_at`, not `Node3D.look_at`.** The node method requires the
  node to be inside the tree and errors when it is not — which is exactly the headless
  case. The transform method is pure maths and works anywhere.
- **`visible_instance_count` is the flush.** Every MultiMesh is a reset → push → flush
  pipeline and forgetting the flush fails completely silently: the simulation carries on
  perfectly and nothing is drawn. `run_smoke.gd` compares the count against the model.
- **Freeze before advancing** in any harness, or results move with the speed of the
  machine.
- **A finished level must start the next one.** `level_finished` has to be connected to
  something that clears `over`. A game built from an earlier version of this template did not
  connect it, `advance()` returned early forever, and it froze with a live HUD - which is a
  crash as far as the player is concerned. `run_smoke.gd` drives through the boundary.
- **Nothing in the HUD may be positioned against a literal screen size.** The project
  stretches with `aspect = "expand"`, so the canvas is about 1080x2340 on the phone and not
  1080x1920. Anchor to a full-rect `Control`, and let every interactive control own its input
  through `_gui_input`. See the long note in `main.gd` - this has shipped wrong once.
- **A golden over floats needs `TestHarness.FLOAT_EPS`**, not exact equality. `snappedf` does
  not round-trip through a source literal, and the goldens are recorded on Windows and checked
  on a Linux runner.
- **A headless run allocates no MultiMesh buffer**, so instance colours read back as black
  there and prove nothing. Check colour in a real renderer or not at all.
- **`global_transform` outside the tree does not error - it returns IDENTITY.** In any
  harness use `transform`. `Node3D.look_at` at least has the decency to fail.
- **A value read out of a Dictionary is a Variant**, and `:=` cannot infer from one. Annotate
  the local: `var pos: Vector3 = c.pos`. Entities held as dictionaries - which is what keeps
  the scene tree out of the test runner - make this constant.

## Signing, and the two builds

There are two export presets and they are not interchangeable.

| | `Android` | `Android Release` |
|---|---|---|
| Output | `.apk` | `.aab` (what Play accepts) |
| Build | prebuilt template, seconds, no Gradle | Gradle build, minutes, ~300 MB of downloads on a cold run |
| Signed with | debug key | **upload key**, from `C:\dev\keys\upload.keystore` |
| Trigger | every push | a `v*` tag |

- **AAB export is only valid with `gradle_build/use_gradle_build=true`.** The exporter
  refuses otherwise, and the Gradle build is also the only way to set `target_sdk`, which
  Play requires to be 36 and which rises every year.
- **`--install-android-build-template` only works alongside an export command.** On its own
  it opens the editor and never returns — it burns CPU and produces nothing, which looks
  like a hang.
- **The release keystore comes from environment variables**, not editor settings:
  `GODOT_ANDROID_KEYSTORE_RELEASE_PATH` / `_USER` / `_PASSWORD`. Godot falls back to editor
  settings for the *debug* key only, so a release export without them fails with
  "Could not find release keystore" — which reads like a missing file rather than a missing
  setting. The env vars are the right shape for CI anyway: the password never touches a
  committed file.
- **Set `GRADLE_OPTS=-Dorg.gradle.daemon=false` for any release export.** Without it Godot
  writes a perfectly good bundle and then **never exits** — Gradle forks a daemon that
  outlives the build and Godot waits on it. Measured: 0% CPU for eight minutes with the AAB
  already on disk. With the daemon off it exits 0. In CI that difference is a job that
  burns until the timeout with nothing actually wrong.
- **Verify the artifact, not the exit code.** This export has returned -1 while producing a
  valid bundle, and returned 0 while producing nothing. Check the file exists, is a
  plausible size, and passes `jarsigner -verify`.
- **Do not invoke it through PowerShell's `Start-Process -ArgumentList`.** It joins
  arguments without quoting, so the preset name `Android Release` arrives as two arguments
  and Godot exports the *`Android`* preset to a file called `Release` — which fails with
  `Invalid filename! Android APK requires the *.apk extension`, a message about nothing to
  do with the mistake. `scripts/export_release.bat` exists to pass the quotes through.
- **Keys live in `C:\dev\keys`**, outside every repository, and `android/` is gitignored
  because it is the export template unpacked, not source.
- See `PLAY.md` in `gamedev-notes` for the store side, and `PRIVACY.md` here for the policy
  every Play listing requires even when nothing is collected.

## Things the exporter will not tell you clearly

- `rendering/textures/vram_compression/import_etc2_astc=true` is **required** for an
  Android export. Without it the export fails with a message about Project Settings.
- A `config/icon` is required, or the export errors even though it still writes a file.
- `gradle_build/use_gradle_build=false` uses the prebuilt template and needs no Gradle
  at all. Turn it on only when a plugin or a custom target SDK demands it — and check
  the target API level against Play's requirement when you do.

## Record as you go

Write lessons into `gamedev-notes` **in the same commit as the change that taught them**,
never at the end of a session. Several games run at once; a lesson recorded after this one
finishes is one the next game never got.
