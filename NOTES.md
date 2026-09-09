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

The whole chain, end to end, with nothing left on trust:

- Godot 4.7.2 runs headless on Windows and exits non-zero on a failed script.
- 28 pure tests, ~4,400 assertions, about a second, no display.
- A whole-run golden over two policies (passive and dodging), **verified by deliberately
  breaking it**: changing one tuning constant made it fail and name the exact field.
- A smoke test that boots the real scene headlessly and compares drawn instances against
  the model.
- A signed 26.98 MB debug APK, exported from the command line.
- A size guard that fails in both directions.
- **CI green on a real runner** — tests, toolchain discovery, stamp, export, size guard,
  and an APK attached to a GitHub Release.
- **Installed and running on the S26 Ultra.** Vulkan 1.4.295, Forward Mobile, Adreno 840.
  `dumpsys gfxinfo` over the first 44 frames: **50th/90th/95th percentile all 5 ms**, one
  janky frame, GPU 1 ms at the median. On a placeholder scene, so it measures the engine
  and the pipeline rather than a game — but it is the number to compare future ones to.
- The stamp on the phone read back the exact commit that had just been pushed, which is
  the whole point of it.

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

## What the first real game built from this taught it

Wrecking Crew was the first game copied out of here, on 2026-09-08. It changed genre three
times in a day - a lane runner, then a crane-aiming runner, then a demolition game in a
parking basement - and **the test suite came across every time**, which is the entire return
on the pure-simulation rule and is worth more than any individual test in it.

Everything below was folded back in afterwards, and each one is here because it cost
something the first time:

- **`Sim.next_level()` and the interlude in `main.gd`.** The template emitted
  `level_finished` and connected nothing to it, so the first game built from it shipped a
  hard freeze at the end of level one. `run_smoke.gd` now drives through that boundary.
- **The anchored HUD pattern**, and a thumb pad already wired up in the file so the pattern
  is present rather than described. Controls laid out against a literal 1920 landed hundreds
  of pixels off on a 19.5:9 phone.
- **`TestHarness.FLOAT_EPS`.** A golden over floats cannot use exact equality.
- **`test/policies.gd` and `test/run_probe.gd`.** Scripted players as a first-class file, and
  a balance probe that prints and cannot fail. The rule that came with them: every policy must
  fail for a DIFFERENT reason, and if the one that reads the level loses to the one that
  ignores it, fix the bot before touching a constant.
- **`scripts/shot.gd`**, which is the only tool here that can tell you the picture is wrong -
  and it has to render at the phone's aspect ratio, not the project's base one.

Two things it also proved that are not code:

- **The asset rules changed.** "Nothing modelled is worth importing" was written when every
  kilobyte was a download over mobile data. A native APK has no such constraint: an HDRI and
  a concrete PBR set cost 1.6 MB and took the APK from 27.1 to 29.7. See `ASSETS.md`.
- **Physics may be cosmetic and nothing else.** Mobile guidance is 10-20 active rigid bodies,
  so structure, collapse and any pendulum stay as arithmetic in `src/sim/`. That is also what
  keeps the whole-run golden possible.

## Known gaps / next

1. **Target API level is whatever the prebuilt export template targets.** Play requires
   API 36 for new apps and updates from 31 August 2026. Verify with
   `aapt dump badging build/*.apk | grep targetSdk` before any store submission, and turn
   on `gradle_build/use_gradle_build` if it needs overriding.
2. **The game is a placeholder.** A track, one obstacle kind, one pickup kind. It exists
   so the golden has something to be golden about. Do not grow it — copy the repo and
   grow the copy.
3. **No release keystore.** The debug key is fine for sideloading and for internal
   testing; a Play production release needs a real upload key, and Play App Signing
   should be enabled so losing it is recoverable.
4. **CI generates a throwaway debug key every run** unless `ANDROID_DEBUG_KEYSTORE_B64` is
   set as a repository secret, so every build is signed differently and Android refuses to
   update an installed app in place. **Set it on every new repo**; it is two minutes and the
   alternative is uninstalling the game between builds. Verified working on Wrecking Crew.
5. **No audio, and it is the biggest gap.** Kenney's URLs are not guessable and freesound
   needs an API key - both re-checked 2026-09-08 - so neither CC0 library can be fetched
   unattended. The route that works is generating WAVs offline with a short Python script
   and committing them to `assets/`. See `assets/README.md`.

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
