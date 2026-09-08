# Notes — Godot phone-game template

Decisions specific to this repo, and what to do next in it. General lessons belong in
`C:\dev\gamedev-notes`, not here.

## Why this exists

Gideon's games were PWAs: Vite, TypeScript, three.js, served from GitHub Pages. That stack
works and two games ship on it. The move to Godot is to get **native Android** — a real
Play Store listing, Play Games Services, in-app purchases if ever wanted, no WebView
ceiling, and no practical limit on asset size, which is what makes pre-made models and
audio viable at all.

The decision was explicitly *not* to preserve the code. What had to survive was the
knowledge: the design lessons, and the method. So this repo is the method rebuilt on a new
engine — pure simulation core, headless golden test, size guard, CI gate, build stamp,
changelog — and the first job was to prove each piece actually works here before any game
is committed to it.

## What is proven, as of 2026-09-08

- Godot 4.7.2 runs headless on Windows and exits non-zero on a failed script.
- 28 pure tests, ~4,400 assertions, about a second, no display.
- A whole-run golden over two policies (passive and dodging), **verified by deliberately
  breaking it**: changing one tuning constant made it fail and name the exact field.
- A smoke test that boots the real scene headlessly and compares drawn instances against
  the model.
- A signed 27 MB debug APK, exported from the command line.
- A size guard that fails in both directions.

Not yet proven: installing on the phone (no device was connected), and the CI workflow
running green on a real runner.

## The test harness is hand-written, deliberately

`test/harness.gd` is about a hundred lines rather than GUT or gdUnit4. Both of those are
good and either would be a reasonable swap. The reason for not using them on day one was
to prove the *pipeline* — headless run, real assertions, non-zero exit, CI gate — with
nothing to download and no chance of an addon lagging an engine release.

**The signal to switch** is the harness growing doubles, mocks, parameterised tests or
scene-testing helpers. At that point it is reimplementing GUT badly and should be replaced
by it.

## Two hours of the build were lifecycle, not logic

Worth knowing before writing any other headless harness in Godot:

- `root.add_child(node)` inside `SceneTree._initialize()` does **not** run `_ready`, and
  does not put the node in the tree until the first processed frame. Symptom: seven
  hundred identical `Nonexistent function 'advance' in base 'Nil'` errors and a run that
  never terminates. Fix: an idempotent `_ensure_booted()` rather than a rule about call
  order, because a rule about call order is something every future test has to remember.
- `Node3D.look_at` errors when the node is not inside the tree — which is that same case.
  `Transform3D.looking_at` is pure maths and works anywhere. The scene now uses it and is
  better for it.

## Known gaps / next

1. **Nothing has been installed on a phone yet.** `adb devices` was empty. Plug the S26
   in with USB debugging on and `adb install -r build/godot-template.apk`.
2. **CI has never run.** The workflow is written against `barichello/godot-ci:4.7.2` but
   has not been executed; expect the editor-settings step to need adjusting for the
   container's SDK and JDK paths.
3. **Target API level is whatever the prebuilt export template targets.** Play requires
   API 36 for new apps and updates from 31 August 2026. Verify with
   `aapt dump badging build/*.apk | grep targetSdk` before any store submission, and turn
   on `gradle_build/use_gradle_build` if it needs overriding.
4. **The game is a placeholder.** A track, one obstacle kind, one pickup kind. It exists
   so the golden has something to be golden about. Do not grow it — copy the repo and
   grow the copy.
5. **No release keystore.** The debug key is fine for sideloading and for internal
   testing; a Play production release needs a real upload key, and Play App Signing
   should be enabled so losing it is recoverable.
6. **No audio.** The web games synthesised everything at runtime. Godot has `AudioStream`
   and a real mixer; decide per game whether to synthesise or ship files, and record the
   answer in `ASSETS.md`.

## Shipping, when there is something to ship

Direct APK is the fast path: CI attaches a signed APK to a GitHub Release, tap the link
on the phone, install. Note that Google's developer verification is rolling out — the
free limited-distribution tier covers up to 20 authorised devices at no cost, which is
the right tier for one phone and a few friends.

Play needs: the $25 account, developer verification, Play App Signing, the app content
declarations, and then — for a personal account created after November 2023 — a closed
test with **12 testers opted in for 14 continuous days** before production access. The
internal testing track takes up to 100 testers with no review wait and is the fastest way
to get a build onto the phone through Play, but it does **not** count toward that 14-day
requirement.
