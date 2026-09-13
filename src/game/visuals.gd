class_name Visuals
extends RefCounted

## THE THREE VISUALS TIERS, and the budget that makes "runs on an older phone"
## a number rather than a hope.
##
## Every game ships a low, a medium and a high visuals option (INDEX.md rule
## 17). The tiers are a table here so the pure suite can assert that they exist,
## that each one costs no more than the next, and that the player's choice
## survives a restart. `apply()` is the one renderer-side call, and it is kept
## apart from the table so the table stays testable with no window.
##
## **What the budget is.** The number that transfers from Gideon's phone to a
## slower one is the GPU time the game spends per frame ON HIS PHONE, read from
## `RenderingServer.viewport_get_measured_render_time_gpu` and printed on the
## `VISUALS` line below (`scripts\device.ps1 perf` reads it out of logcat). A
## Galaxy S26 Ultra's Adreno 840 is about `FLOOR_RATIO` times the GPU of a 2021
## flagship (a Galaxy S21's Adreno 660), so the low tier's cost on his phone
## times that ratio is what the floor phone would spend. The budgets are in
## `C:\dev\gamedev-notes\DEVICE.md` with their derivation and sources, and the
## constants below are that file's numbers, dated. Change them there first.
##
## **Low never caps the game.** When a game's low tier cannot get under
## `BUDGET_MS.low`, the game ships anyway with low as low as visuals alone can
## take it, and DEVICE.md records that the floor is unmet for that game. The
## budget is a WARN in the gate and a line in the report, never a refusal.

## DEVICE.md, 2026-09-13. The floor is a 2021 flagship, Galaxy S21 class,
## Snapdragon 888 / Adreno 660. Ratio from 3DMark Wild Life Extreme (6,490
## against 1,508, 4.3x) and GFXBench Aztec Ruins High offscreen (about 154 fps
## against 35, 4.4x). The smaller of the two, so the prediction is the harsher.
const FLOOR_RATIO := 4.3

## The frame the floor phone has to fit at 60 fps.
const FRAME_MS_60 := 16.7

## GPU milliseconds per frame, measured on the S26 Ultra at that tier, that a
## game may spend. low: 3.0 ms here is 12.9 ms on the floor phone, 23% inside a
## 60 fps frame. medium: half a 60 fps frame on this phone. high: half a 120 Hz
## frame on this phone; a game whose high tier cannot get under it caps high at
## 60 fps instead and inherits medium's budget.
const BUDGET_MS := {"low": 3.0, "medium": 8.3, "high": 4.2}

## GPU duty cycle (gpu ms x fps / 1000) under which no thermal soak is owed: a
## chip that idles half of every frame does not throttle. A rule, not a
## measurement, and the first soak that contradicts it replaces it (INDEX.md
## rule 7). Above it, `scripts\device.ps1 perf -Soak 10` is owed once for that
## game's build.
const SOAK_FREE_DUTY := 0.5

## The tiers, lowest first. Every key is a cost that must not go DOWN from one
## row to the next; `test/test_visuals.gd` asserts the ordering, so a tier that
## drifts out of order goes red instead of shipping as "medium is slower than
## low". `fps` 0 means uncapped, which on a 120 Hz panel is 120 with vsync.
const ORDER: Array[String] = ["low", "medium", "high"]
const TIERS := {
	"low": {"fps": 60, "scale": 0.7, "msaa": 0, "shadows": false, "effects": false, "shadow_atlas": 1024},
	"medium": {"fps": 60, "scale": 0.85, "msaa": 1, "shadows": true, "effects": true, "shadow_atlas": 2048},
	"high": {"fps": 0, "scale": 1.0, "msaa": 1, "shadows": true, "effects": true, "shadow_atlas": 4096},
}

## Where the player's choice lives on the phone. The pair below it is what the
## suite tests; this path is only the thin wrapper's business.
const PATH := "user://visuals.json"
const DEFAULT := "high"

## How often the `VISUALS` line is printed while the game runs on a phone or
## under `beat`. Ten seconds is enough for `perf`'s twenty-second window to
## catch at least one.
const REPORT_SECONDS := 10.0


static func is_tier(name: String) -> bool:
	return TIERS.has(name)


## The settings for a tier, or an empty Dictionary for a name that is not one.
## Empty rather than a default, so a caller that passes a typo finds out.
static func settings(tier: String) -> Dictionary:
	if not TIERS.has(tier):
		return {}
	return TIERS[tier]


## The player's choice as a Dictionary and back. `from_dict` refuses anything
## that is not one of the three names by returning "", never by substituting a
## default, so a corrupt file is visible to the caller rather than silently
## high.
static func to_dict(tier: String) -> Dictionary:
	return {"tier": tier}


static func from_dict(d: Dictionary) -> String:
	var t: Variant = d.get("tier", "")
	if t is String and TIERS.has(t):
		return t
	return ""


## A reading judged against the tier's budget. Pure: the ms and fps come from
## whoever measured them, and the answer is a Dictionary so a report can print
## every part of it. `fps` is the rate the game actually ran at (the panel's,
## or the cap), because the duty cycle is what decides whether a soak is owed.
static func judge(tier: String, gpu_ms: float, fps: float) -> Dictionary:
	if not TIERS.has(tier):
		return {}
	var budget: float = BUDGET_MS[tier]
	var duty := gpu_ms * fps / 1000.0
	return {
		"tier": tier,
		"gpu_ms": gpu_ms,
		"budget_ms": budget,
		"within": gpu_ms <= budget,
		"floor_ms": gpu_ms * FLOOR_RATIO if tier == "low" else 0.0,
		"floor_ok": (gpu_ms * FLOOR_RATIO) <= FRAME_MS_60 if tier == "low" else true,
		"duty": duty,
		"soak_owed": duty > SOAK_FREE_DUTY + 0.0001,
	}


## The one line a phone log carries for this. Parsed by `device.ps1 perf` with
## a regex on the `k=v` pairs, so the keys are part of the contract.
static func report_line(tier: String, gpu_ms: float, cpu_ms: float, fps: float) -> String:
	return "VISUALS tier=%s gpu=%.2f cpu=%.2f fps=%.0f" % [tier, gpu_ms, cpu_ms, fps]


# --- the renderer side ------------------------------------------------------

## Pushes a tier into the engine. Everything below is a setter the smoke suite
## reads back, so a key added to the table without a line here shows up as a
## smoke failure rather than as a tier that quietly does nothing.
static func apply(tier: String, viewport: Viewport, sun: DirectionalLight3D = null, env: Environment = null) -> bool:
	var s := settings(tier)
	if s.is_empty():
		return false
	Engine.max_fps = int(s.fps)
	if viewport != null:
		viewport.scaling_3d_scale = float(s.scale)
		viewport.msaa_3d = int(s.msaa) as Viewport.MSAA
		viewport.positional_shadow_atlas_size = int(s.shadow_atlas)
		RenderingServer.directional_shadow_atlas_set_size(int(s.shadow_atlas), true)
	if sun != null:
		sun.shadow_enabled = bool(s.shadows)
	if env != null:
		env.glow_enabled = bool(s.effects)
		env.ssao_enabled = false
	return true


## The thin wrappers over the pair. `load_choice` returns the default for a
## missing or unreadable file, because a first launch is not an error; the pair
## above is where refusal lives and where it is tested.
static func load_choice() -> String:
	if not FileAccess.file_exists(PATH):
		return DEFAULT
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return DEFAULT
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var t := from_dict(parsed)
		if t != "":
			return t
	return DEFAULT


static func save_choice(tier: String) -> bool:
	if not TIERS.has(tier):
		return false
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(tier)))
	f.close()
	return true


## The measured GPU and CPU milliseconds of the last frame, once
## `viewport_set_measure_render_time` is on. Zero on a headless run and on a
## desktop where the driver does not answer, which is why the smoke suite
## asserts the line's SHAPE and never its numbers.
static func measure(viewport: Viewport) -> Dictionary:
	if viewport == null:
		return {"gpu": 0.0, "cpu": 0.0}
	var rid := viewport.get_viewport_rid()
	return {
		"gpu": RenderingServer.viewport_get_measured_render_time_gpu(rid),
		"cpu": RenderingServer.viewport_get_measured_render_time_cpu(rid),
	}
