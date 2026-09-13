class_name Main
extends Node3D

## The shell. Reads `Sim` and draws it; never decides anything.
##
## It carries a `class_name` so a harness can hold it in a TYPED local. That is
## not decoration: a sibling game renamed a HUD gauge, its smoke suite read the
## old name off an untyped `var main = scene.instantiate()`, and the missing
## property was a non-fatal runtime error that stopped that check where it stood
## and deleted fifteen assertions without turning anything red. Typed, the same
## rename is a parse error before the suite runs.
##
## The scene file next to this is four lines on purpose - one node with this
## script. Everything visible is built here in code rather than laid out in the
## editor, for two reasons:
##
## 1. A procedural game's world is built at runtime anyway, so an editor layout
##    would be a second source of truth that has to agree with the first.
## 2. It keeps the whole project reviewable as text. A scene tree assembled by
##    clicking is invisible in a diff and cannot be written by anything that
##    does not have the editor open.
##
## If a game later wants hand-placed content, that content belongs in its own
## scene loaded from here - not merged into this one.

const POOL := 64  ## per entity kind; the horizon holds far fewer than this

## THE DIRECTION OF TRAVEL, named once, because five games have shipped inverted.
##
## Godot's camera looks down its own -Z, so a chase camera following a track laid
## toward world +Z has its right-hand basis vector pointing at world -X: screen
## right IS world -X, and every drag then moves the avatar the wrong way while
## every world-coordinate assertion in the suite goes on passing. Captain Run,
## Coreward (twice), Wrecking Crew, Stillwater and Wildform all shipped that way,
## and so did this template: the placeholder game ran toward +Z, its camera's
## `basis.x` was (-1, 0, 0), and dragging right sent the cube left.
##
## Laying the track toward -Z makes screen right world +X with no sign flip
## anywhere near the input, which is what CRAFT.md prescribes. `Sim` counts
## distance as a positive number going forward and knows nothing about any of
## this; the multiplication below is the ONE place the simulation's forward
## becomes a world axis, so there is one place to be wrong instead of nine.
##
## `test/test_controls.gd` is the gate. Change this sign and it goes red.
const TRACK_Z := -1.0

var sim: Sim

## What the Android back button unwinds. Empty at boot, and that is a rule rather
## than a starting value - see `back_pressed()` below.
var screens := ScreenStack.new()

## How many times the game has written its save, counted so a test can assert
## that a back press saved without reading the disk to find out. Incremented only
## when the write actually succeeded, so a read-only `user://` shows up as a
## failure here rather than as a silent loss of the player's run.
var saves_written := 0

var _cam: Camera3D
var _road: MeshInstance3D
var _player: MeshInstance3D
var _obstacles: MultiMeshInstance3D
var _pickups: MultiMeshInstance3D
var _hud: Label
var _ui: Control
var _pad: Control
var _pad_grab := -1
var _pad_vec := Vector2.ZERO
var _dragging := false

## Big enough for a thumb without looking at it, and clear of the bottom edge so
## the system gesture bar cannot eat the press.
const PAD := 210.0
const PAD_BOTTOM := 200.0

## Long enough to read what happened, short enough that it never feels like a
## menu. The game is playable again on the other side of it without a tap.
const INTERLUDE_SECONDS := 2.2
var _interlude := 0.0
var _interlude_won := false

## Set by the headless harness. When true the frame loop does not step the sim,
## so `advance()` is the only thing moving time and results do not depend on
## how fast the machine boots.
var frozen := false


var _booted := false

## The visuals tier in force (INDEX.md rule 17, `src/game/visuals.gd`). The
## sun and the environment are kept so a tier change can reach the shadows and
## the effects, which are the two costs a scale slider cannot touch.
var visuals_tier := Visuals.DEFAULT
var _sun: DirectionalLight3D
var _env: Environment
var _report_visuals := false
var _visuals_clock := 0.0


func _ready() -> void:
	_ensure_booted()
	# The visuals tier needs a viewport, which is only there once the node is in
	# the tree, so it is applied here rather than in the boot. A `visuals=<tier>`
	# user arg beats the saved choice, for films and shots of one tier.
	var tier := Visuals.load_choice()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("visuals=") and Visuals.is_tier(a.trim_prefix("visuals=")):
			tier = a.trim_prefix("visuals=")
	apply_visuals(tier)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_report_visuals = OS.has_feature("mobile") or OS.get_cmdline_user_args().has("beat")


## The current tier, and the one call that changes it. `Visuals.apply` is the
## renderer side; this keeps the name so the HUD, a settings screen and the
## `VISUALS` line all read one field. Returns false and changes nothing for a
## name that is not a tier.
func apply_visuals(tier: String, viewport: Viewport = null) -> bool:
	# `get_viewport()` is null until the first processed frame, which is where
	# the smoke suite lives, so it hands the tree's root in explicitly.
	var vp := viewport if viewport != null else get_viewport()
	if not Visuals.apply(tier, vp, _sun, _env):
		return false
	visuals_tier = tier
	return true


## Chosen from a settings screen: apply, then remember. The order matters in the
## one case that shows, a full disk, where the player keeps the tier they saw.
func choose_visuals(tier: String) -> bool:
	if not apply_visuals(tier):
		return false
	Visuals.save_choice(tier)
	return true


## The `VISUALS tier=... gpu=... cpu=... fps=...` line, every
## `Visuals.REPORT_SECONDS`, on a phone and under `beat`. `device.ps1 perf`
## reads it from logcat and judges the GPU number against the tier's budget.
func _report_visuals_line(delta: float) -> void:
	if not _report_visuals:
		return
	_visuals_clock += delta
	if _visuals_clock < Visuals.REPORT_SECONDS:
		return
	_visuals_clock = 0.0
	var m := Visuals.measure(get_viewport())
	print(Visuals.report_line(visuals_tier, m.gpu, m.cpu, Engine.get_frames_per_second()))


## Building the world is idempotent and callable before the first frame.
##
## `_ready` does not run at `add_child()` - it is deferred to the first
## processed frame - so a headless harness that adds this node and immediately
## calls `advance()` finds `sim` still null. That cost an hour: the symptom was
## seven hundred identical "Nonexistent function 'advance' in base 'Nil'"
## errors and a run that never terminated, which reads like an engine problem
## and is really a lifecycle one.
##
## The fix is a guard rather than a rule about call order, because a rule about
## call order is something every future test has to remember.
func _ensure_booted() -> void:
	if _booted:
		return
	_booted = true
	sim = Sim.new()
	_build_world()
	sim.level_finished.connect(_on_level_finished)
	_sync()


# --- world ----------------------------------------------------------------

func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.36, 0.62, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.70, 0.80)
	e.ambient_light_energy = 0.75
	e.fog_enabled = true
	e.fog_light_color = Color(0.36, 0.62, 0.82)
	e.fog_density = 0.012
	env.environment = e
	_env = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.6
	_sun = sun
	add_child(sun)

	_cam = Camera3D.new()
	_cam.fov = 62
	_cam.far = 220
	add_child(_cam)

	# Road. One long box that is moved with the player rather than tiled, so
	# the ground is a single draw call for the whole level.
	_road = MeshInstance3D.new()
	var road_mesh := BoxMesh.new()
	road_mesh.size = Vector3(Tuning.LANE_HALF_WIDTH * 2.0 + 2.0, 0.4, 400.0)
	_road.mesh = road_mesh
	_road.material_override = _mat(Color(0.55, 0.52, 0.47))
	_road.position.y = -0.2
	_road.name = "Road"
	add_child(_road)

	_player = MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.9, 0.9, 0.9)
	_player.mesh = pm
	_player.material_override = _mat(Color(0.98, 0.80, 0.25))
	add_child(_player)

	_obstacles = _make_multimesh(Vector3(1.2, 1.2, 1.2), Color(0.72, 0.24, 0.30))
	_pickups = _make_multimesh(Vector3(0.55, 0.55, 0.55), Color(0.35, 0.85, 0.95))

	_build_hud()


## THE LAYOUT RULE, and it is here because getting it wrong has shipped.
##
## `window/stretch/aspect = "expand"` keeps the base WIDTH and extends the
## HEIGHT to the device's aspect. The base here is 1080x1920; the phone is about
## 19.5:9, so the canvas the game renders into is roughly 1080x2340. **Laying
## anything out against the literal number 1920 therefore puts it hundreds of
## pixels above where it belongs**, and the player's report was "the icons are
## about half an inch too high".
##
## It shipped alongside a second bug of the same origin: a hand-rolled hit test
## that scaled touches into a 1080x1920 space of its own, so the drawn control
## and the region that responded were in two different coordinate systems and
## disagreed with each other as well as with the screen.
##
## So, for every game built from this template:
##
##   - One `Control` with `PRESET_FULL_RECT` inside the `CanvasLayer`, and
##     **everything anchors to that**. `PRESET_CENTER_BOTTOM` with a negative
##     `offset_bottom` puts a thumb control a fixed distance from the real
##     bottom edge at any aspect ratio.
##   - **Every interactive control handles its own input** through `_gui_input`
##     and calls `accept_event()`. Position and hit box are then the same object
##     and cannot drift apart. A manual hit test in `_unhandled_input` is a
##     second source of truth for where a button is.
##
## **No headless test can catch this**, which is the part worth remembering: a
## headless run uses the base viewport size, where the wrong layout and the
## right one are identical. Screenshot at the phone's aspect (see
## `scripts/shot.gd`), and have the smoke test assert the PROPERTY - that the
## control resolves from the viewport edge - rather than its position.
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Hud"
	add_child(layer)

	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.name = "Ui"
	layer.add_child(_ui)

	_hud = Label.new()
	_hud.position = Vector2(46, 52)
	_hud.add_theme_font_size_override("font_size", 34)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_hud.add_theme_constant_override("outline_size", 8)
	_ui.add_child(_hud)

	# A thumb control, anchored rather than placed - here so the pattern is
	# already in the file and the smoke test has something real to assert
	# against. Replace what it DOES; keep how it is positioned.
	_pad = Control.new()
	_pad.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_pad.custom_minimum_size = Vector2(PAD, PAD)
	_pad.size = Vector2(PAD, PAD)
	_pad.offset_left = -PAD * 0.5
	_pad.offset_right = PAD * 0.5
	_pad.offset_top = -PAD - PAD_BOTTOM
	_pad.offset_bottom = -PAD_BOTTOM
	_pad.mouse_filter = Control.MOUSE_FILTER_STOP
	_pad.name = "Pad"
	_pad.gui_input.connect(_on_pad_input)
	_pad.draw.connect(_draw_pad)
	_ui.add_child(_pad)


func _draw_pad() -> void:
	var r := PAD * 0.5
	var c := Vector2(r, r)
	var lit: float = 0.6 if _pad_grab >= 0 else 0.3
	_pad.draw_circle(c, r, Color(0.05, 0.05, 0.06, 0.32))
	_pad.draw_arc(c, r - 4.0, 0.0, TAU, 48, Color(1.0, 0.86, 0.42, lit), 4.0)
	_pad.draw_circle(c + _pad_vec * (r * 0.55), r * 0.28, Color(0.95, 0.85, 0.55, 0.85))


func _on_pad_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.pressed:
			_pad_grab = event.index if event is InputEventScreenTouch else 0
			_read_pad(event.position)
		else:
			_pad_grab = -1
			_pad_vec = Vector2.ZERO
		_pad.accept_event()
	elif event is InputEventScreenDrag or event is InputEventMouseMotion:
		if _pad_grab >= 0:
			_read_pad(event.position)
			_pad.accept_event()


## Absolute, not relative: on a pad the thumb's position IS the value, and a
## relative mapping lets the control and the thing it controls drift apart.
##
## The dead zone is not optional. Without one a virtual stick reads every tremor
## of a resting thumb and the machine wanders on its own, which reads to the
## player as the controls being loose rather than as their own imprecision.
func _read_pad(local: Vector2) -> void:
	var r := PAD * 0.5
	_pad_vec = ((local - Vector2(r, r)) / (r * 0.78)).limit_length(1.0)
	if _pad_vec.length() < 0.14:
		_pad_vec = Vector2.ZERO
		return
	sim.steer_to(_pad_vec.x * Tuning.LANE_HALF_WIDTH)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


## One MultiMesh per entity kind, rewritten every frame.
##
## `visible_instance_count` is the whole reason to use this rather than a pool
## of nodes: it is a number the tests can compare against the entity list. A
## render path that silently stops drawing and a subsystem that does not exist
## look identical from outside, and that has already cost a full tuning pass on
## another game here - the enemies were invisible and it read as balance.
func _make_multimesh(box_size: Vector3, c: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := BoxMesh.new()
	mesh.size = box_size
	mm.mesh = mesh
	mm.instance_count = POOL
	mm.visible_instance_count = 0
	mmi.multimesh = mm
	mmi.material_override = _mat(c)
	add_child(mmi)
	return mmi


# --- loop -----------------------------------------------------------------

func _process(delta: float) -> void:
	_report_visuals_line(delta)
	if frozen:
		return
	_tick(delta)


func _tick(dt: float) -> void:
	sim.advance(dt)
	_advance_interlude(dt)
	_sync()


## The only place the world can be started again, and the reason it exists is
## worth reading before deleting it.
##
## A game built from an earlier version of this template connected nothing to
## `level_finished`. `over` went true at the end of the first level,
## `advance()` returned early from then on, and it sat frozen with a live HUD -
## which to the person holding the phone is a crash. It was the first thing they
## hit, and no test caught it because **every test in the suite played a level
## and read the state at the end, which is the exact instant the freeze began.**
## The suite was not weak; it was uniform.
func _on_level_finished(won: bool) -> void:
	_interlude = INTERLUDE_SECONDS
	_interlude_won = won


func _advance_interlude(dt: float) -> void:
	if _interlude <= 0.0:
		return
	_interlude -= dt
	if _interlude > 0.0:
		return
	if _interlude_won:
		sim.next_level()
	else:
		sim.restart(1)


## The headless seam.
##
## `_process` computes a delta and calls `_tick`; this steps `_tick` at a fixed
## delta instead. A whole level compresses into one call, deterministically and
## far faster than real time, with no window open.
##
## Freeze first. Real frames run between the scene loading and a harness taking
## over, and how many depends on how fast the machine starts - which quietly
## makes every recorded number a function of the test runner's speed.
func advance(seconds: float, step: float = 1.0 / 60.0) -> void:
	_ensure_booted()
	var n := maxi(1, int(round(seconds / step)))
	for i in n:
		_tick(step)


func freeze(start_level: int = 1) -> void:
	_ensure_booted()
	frozen = true
	sim.restart(start_level)
	_interlude = 0.0
	_sync()


# --- the dev seam ---------------------------------------------------------

## JUMP STRAIGHT TO THE SITUATION, instead of driving to it.
##
## Everything that looks at this game from outside - `scripts/shot.gd`,
## `scripts/replay_player.gd` and through it `scripts/movie.ps1` - used to reach
## an interesting moment the only way a player can: by playing from frame one
## until it arrived. The opening of level 2 is 28.9 s of play away (26.7 s of
## level 1 plus the 2.2 s interlude) and film costs 6.3 s of wall clock and
## 3.0 MB per second, so measured on this template on 2026-09-13, five seconds
## of level 2 cost 216.0 s and 100.7 MB by playing to it and 37.3 s and 14.9 MB
## by seeking to it.
##
## So the states live HERE, on the game, and the tools ask for one by name. The
## three methods are the whole contract:
##
##   `dev_states()`     name -> one line of what it is. THE table. `shot.gd` and
##                      `replay_player.gd` both print this list when they are
##                      given a name nobody knows, so there is one writer.
##   `dev_seek(name)`   put the game in that state and leave it RUNNING; false
##                      for a name it does not know. A false must leave the
##                      simulation as it was - a half-seeked game is the
##                      plausible-looking wrong thing this seam exists to stop.
##   `dev_heartbeat()`  the few sim numbers that MUST move while a run is alive.
##                      `movie.ps1` prints them every thirty physics frames and
##                      refuses a film whose first and last readings are equal,
##                      so a run that got stuck says so instead of producing
##                      twenty minutes of a frozen picture.
##
## **A name ending in `.json` is a saved run**, loaded through
## `SimSave.read_file`. That pair restores every field or none, so an exact
## situation pulled off the phone is a state like any other and a refusal is a
## `false` rather than a half-loaded game.
##
## **Add an arm here, not a script.** A sibling game grew nine near-identical
## `shot_*.gd` files, 473 lines, differing only in a setup call. Each one of
## those is an arm below and a word on a command line.
##
## Keep each arm to the SETUP, and keep it honest: an arm that cannot reach the
## state it promises returns false rather than photographing something else.
## `test/test_dev_states.gd` plants a state that shares no field with a fresh
## boot before every seek, so an arm that quietly does nothing goes red.

## How long `level2` plays once it is there, so the track ahead is populated and
## the picture is of a level being played rather than of its first frame. Fixed
## rather than taken from the caller: a state is a state, and a seek whose result
## depends on an argument is two states wearing one name.
const DEV_LEVEL2_SECONDS := 6.0

## The guards on the arms that play until something happens. Six thousand steps
## is 100 s at 1/60, which is four times the length of a level here.
const DEV_GUARD_STEPS := 6000
const DEV_FINISH_GUARD_STEPS := 12000


func dev_states() -> Dictionary:
	return {
		"start": "the very first frame, before anything has happened",
		"hit": "the moment after an impact, while the cooldown is running",
		"finish": "the interlude after a level is completed",
		"level2": "a later level, which is faster and denser",
	}


func dev_seek(state: String) -> bool:
	_ensure_booted()
	var step := 1.0 / 60.0
	var mem := {}

	if state.ends_with(".json"):
		# Read into a scratch sim FIRST. `SimSave.apply` already refuses in full
		# rather than in part, but reading straight into the live one would still
		# mean freezing and restarting the game before finding out the file is not
		# there - which is a refusal that reset the run, and `test_dev_states.gd`
		# caught exactly that on the first draft of this arm.
		var probe := Sim.new()
		if not SimSave.read_file(probe, _dev_save_path(state)):
			return false
		freeze()
		if not SimSave.apply(sim, SimSave.to_dict(probe)):
			push_error("dev_seek('%s'): the save loaded into a scratch sim and then would not apply to the live one" % state)
			return false
		_sync()
		frozen = false
		return true

	match state:
		"start":
			freeze()
		"hit":
			# Driven straight down the middle, which is what hits something,
			# and stopped INSIDE the cooldown rather than after it.
			freeze()
			var guard := 0
			while sim.lives == Tuning.START_LIVES and guard < DEV_GUARD_STEPS:
				advance(step, step)
				guard += 1
			if sim.lives == Tuning.START_LIVES:
				push_error("dev_seek('hit'): never took a hit in %.1f seconds of play" % (float(guard) * step))
				return false
			advance(Tuning.HIT_COOLDOWN * 0.4, step)
		"finish":
			freeze()
			var guard2 := 0
			while not sim.over and guard2 < DEV_FINISH_GUARD_STEPS:
				Policies.steer(Policies.DODGER, sim, mem)
				advance(step, step)
				guard2 += 1
			if not sim.over:
				push_error("dev_seek('finish'): the level never ended - nothing to photograph")
				return false
			advance(INTERLUDE_SECONDS * 0.5, step)
		"level2":
			# DODGER, not GREEDY, and this is the difference between a state and a
			# trap. Six seconds of greedy play on a denser level arrives with one
			# life left: the first film taken of this state died twelve frames in,
			# sat through the interlude and spent the rest of its budget on a
			# fresh level 1. A state you cannot play out of is not the state its
			# name promises. `test_dev_states.gd` asserts the lives.
			freeze(2)
			for i in int(round(DEV_LEVEL2_SECONDS / step)):
				Policies.steer(Policies.DODGER, sim, mem)
				advance(step, step)
		_:
			return false

	# **A seek hands back a RUNNING game.** Each arm freezes first, because
	# stepping at a fixed delta is the only way the same seek lands in the same
	# place on any machine - but leaving it frozen is how the first draft of this
	# produced a film of level 2 in which nothing whatsoever moved for twenty
	# seconds, measured. A tool that wants a still sets `frozen` back afterwards,
	# which is what `scripts/shot.gd` does and why that flag is public.
	frozen = false
	return true


## The few numbers that must move while a run is alive.
##
## Deliberately small and all-scalar: this is printed on one line thirty frames
## apart and compared as text, so a nested structure would make "did anything
## happen" unreadable. A game adds the numbers that prove ITS loop is running -
## the ones whose being equal at both ends of a film means the run was stuck.
func dev_heartbeat() -> Dictionary:
	if sim == null:
		return {}
	return {
		"t": snappedf(sim.time, 0.01),
		"dist": snappedf(sim.distance, 0.01),
		"score": sim.score,
		"level": sim.level,
	}


## `res://` unless the caller already said where. Same rule as
## `scripts/replay_player.gd` uses for a replay file, so a state and a replay are
## named the same way on a command line, and a run pulled off the phone
## (`user://save.json`) is reachable without a copy.
func _dev_save_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	return "res://" + path


# --- drawing --------------------------------------------------------------

func _sync() -> void:
	var z := sim.distance * TRACK_Z
	_player.position = Vector3(sim.x, 0.45, z)

	# Transform3D.looking_at rather than Node3D.look_at. The node method
	# requires the node to be inside the tree and errors if it is not - and a
	# headless harness that adds this scene and steps it immediately is exactly
	# that case, because add_child() during SceneTree._initialize() does not
	# put anything in the tree until the first frame. This is pure math and
	# works anywhere.
	# Nine meters BEHIND the player and ten meters AHEAD of them, both expressed
	# along the direction of travel rather than along +Z, so the camera cannot
	# end up on the wrong side of the avatar if the track is ever turned round.
	var eye := Vector3(sim.x * 0.35, 5.4, z - 9.0 * TRACK_Z)
	var focus := Vector3(sim.x * 0.2, 1.0, z + 10.0 * TRACK_Z)
	_cam.transform = Transform3D(Basis.IDENTITY, eye).looking_at(focus, Vector3.UP)

	_road.position = Vector3(0, -0.2, z)

	_write(_obstacles, sim.obstacles, 0.6)
	_write(_pickups, sim.pickups, 0.8)

	# The stamp is on screen rather than behind a menu because this is a
	# template: the first thing to verify on a phone is that the build you are
	# holding is the build you just made. A real game moves it to a pause or
	# settings screen next to the changelog.
	_hud.text = "SCORE %s\nLIVES %d\nLEVEL %d\n%s" % [
		SimUtil.fmt(sim.score), sim.lives, sim.level, BuildStamp.line()
	]


## reset -> push -> flush, in the one place it can be got wrong.
##
## `visible_instance_count` is the flush. Forgetting it leaves the count at
## whatever it was last frame, which draws stale entities or none at all while
## the simulation carries on perfectly - so keep this the only writer, and let
## `test/test_render.gd` compare the count it sets against the model.
func _write(mmi: MultiMeshInstance3D, items: Array[Dictionary], y: float) -> void:
	var n := 0
	for item in items:
		if n >= POOL:
			break
		if item.taken:
			continue
		mmi.multimesh.set_instance_transform(
			n, Transform3D(Basis.IDENTITY, Vector3(item.x, y, item.z * TRACK_Z))
		)
		n += 1
	mmi.multimesh.visible_instance_count = n


# --- the back button ------------------------------------------------------

## THE ANDROID BACK BUTTON, answered here so no session has to answer it on the
## phone again.
##
## `project.godot` sets `application/config/quit_on_go_back=false`. That line
## alone, which is how this template shipped, means the button does **nothing**:
## the engine stops quitting and nobody handles the notification, so a player
## with a menu open presses back and the game ignores them. GODOT.md's rule is
## that the setting and the handler are one change, and this is the handler.
##
## The contract is one press, one layer:
##
##   - a press with something open closes exactly ONE layer and returns "popped"
##   - a press with nothing open returns "quit", and only then does the game go
##   - either way the run is saved FIRST, because a back press is the commonest
##     way a phone game is left and an unsaved run is the loss the player feels
##
## It returns a String rather than quitting inline so the whole rule is testable
## with no tree, no window and no phone: `test/test_back_button.gd` drives it in
## the pure suite in milliseconds. The one thing a desk cannot answer is what
## Android does around the press - the lifecycle, the gesture, the thermal state
## - and that is what the phone pass is for.
func back_pressed() -> String:
	_ensure_booted()
	_save()
	if screens.is_empty():
		return "quit"
	screens.pop()
	return "popped"


## The save, in one place so `back_pressed` and any future pause path cannot
## disagree about what "saved" means.
func _save() -> void:
	if SimSave.write_file(sim):
		saves_written += 1
	else:
		push_error("the run could not be saved to %s - the player will lose it" % SimSave.PATH)


## THE STACK IS EMPTY AT BOOT, and this is a rule about the template rather than
## a detail of this file.
##
## A screen pushed in front of the game at startup turns every other harness in
## this repo into a test of that screen: `test_controls.gd` drags at a menu,
## the smoke test photographs it, and the filmed runs record it. A sibling game
## did exactly that and its whole control suite went on passing while measuring
## nothing. So a game built from here opens ON the game, and anything it wants
## in front of the player is pushed by a player action, never by `_ready`.
## `test/test_back_button.gd` asserts the empty boot for that reason.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if back_pressed() != "quit":
		return
	# `is_inside_tree()` rather than a null check on `get_tree()`, and the
	# difference is not style: `get_tree()` off the tree does not simply return
	# null, it raises "Parameter data.tree is null" - a non-fatal engine error
	# that the harness counts and fails the test for. Measured while verifying
	# this file's own tests by reintroducing the bug they guard.
	if is_inside_tree():
		get_tree().quit()


# --- input ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_dragging = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		_dragging = (event as InputEventMouseButton).pressed
	elif event is InputEventScreenDrag or (event is InputEventMouseMotion and _dragging):
		drag_by(event, float(get_viewport().get_visible_rect().size.x))


## THE ONE WAY A DRAG REACHES THE SIMULATION, and it is a method rather than the
## body of `_unhandled_input` for one reason: so a test can drive it.
##
## `_unhandled_input` needs a viewport to know how wide the screen is, and a
## headless suite has no reliable viewport at the moment it runs. Everything
## else about the gesture - reading the delta off a real event, the sign, the
## scale, the clamp inside `steer_to` - lives here, where a test hands it a real
## `InputEventScreenDrag` and a stated width and asserts where the avatar ends
## up on screen. See `test/test_controls.gd`.
##
## **A test that calls `sim.steer_to()` instead is not a test of the control.**
## `steer_to` takes a world X and moves the avatar to that world X correctly,
## including on a game whose controls are inverted - the bug lives in the two
## steps either side of it, and a suite made entirely of policies has no
## coverage of either. That is how five games in this studio shipped backwards
## with four thousand assertions passing.
##
## Relative, not absolute: the thumb is never where the player is looking, and
## an absolute mapping makes the first touch of every run yank the player
## sideways.
## THE BOT SEAM: what a scripted policy has to go through to count as a test of
## the control.
##
## `scripts/replay_player.gd` drives `policy=<name>` runs by calling this and
## then pushing the returned drag at the viewport as a real
## `InputEventScreenDrag`. The split is deliberate. The driver owns everything
## generic - the frame gate, the clamp on how fast a thumb moves, building and
## pushing the event - and this method owns the two things only the GAME knows:
## which policy set to ask, and the arithmetic its own handler uses.
##
## **Write the conversion from the handler's own constants, inverted.**
## `drag_by` below turns a pixel delta into a world delta with
## `dx / span * Tuning.LANE_HALF_WIDTH * 3.4`, so this turns the world delta the
## policy wants back into pixels with the same three constants. A measured fudge
## factor would drift the moment the control is retuned, and a bot that steers
## almost right is worse than no bot: it films a plausible run of a broken game.
##
## **It must not leave the simulation changed.** `Policies.steer` mutates the
## sim, so the target is read and put straight back. If it were left set, the bot
## would have taken the shortcut AND filmed it, which is precisely the thing this
## whole seam exists to stop - a policy that sets the value the control would set
## is not a test of the control, and that is how five games shipped inverted.
## `test/test_replay_policy.gd` asserts the restore, so a future edit that drops
## it goes red rather than quietly making every filmed run worthless.
##
## Only `target_x` is saved here because `steer_to` is the only thing the
## template's policies touch. A game whose policies also set a hold, a throttle
## or a facing saves and restores those too, and adds them to that test.
func bot_drag_pixels(policy: String, mem: Dictionary, span: float) -> Vector2:
	# Loud, not silent, for the same reason drag_by is: dividing by a width that
	# has not resolved yet yields a plausible drag with no relationship to
	# anything, and a filmed run of it looks like a balance problem.
	if span <= 0.0:
		push_error("bot_drag_pixels was given a screen width of %f - the viewport is not resolved" % span)
		return Vector2.ZERO
	if sim == null:
		push_error("bot_drag_pixels was called before the sim existed - call freeze() or let _ready run first")
		return Vector2.ZERO

	var was_target: float = sim.target_x
	Policies.steer(policy, sim, mem)
	var wants: float = sim.target_x
	sim.target_x = was_target

	var world_dx := wants - was_target
	# A policy that is happy where it is asks for nothing. Returning a tiny drag
	# instead would push a real event every single frame, and a film of a thumb
	# that never lets go is not a film of the game being played.
	if absf(world_dx) < 0.0001:
		return Vector2.ZERO
	return Vector2(world_dx * span / (Tuning.LANE_HALF_WIDTH * 3.4), 0.0)


## True while a bot may drive. The driver asks before every frame it pushes.
##
## Steering during the interlude would send input at a screen the player cannot
## steer on, and steering after the run is over films a corpse being nudged.
## Neither fails anything, which is why they have to be refused here rather than
## noticed later in a contact sheet.
func bot_can_drive() -> bool:
	return sim != null and not sim.over and _interlude <= 0.0

func drag_by(event: InputEvent, span: float) -> void:
	# Loud, not silent. A zero width means the viewport has not resolved yet, and
	# `dx / 0` would steer the avatar to infinity and clamp it to the lane edge -
	# a plausible-looking movement with no relationship to the thumb. `push_error`
	# is what makes check.ps1 fail on it rather than a quiet `return`.
	if span <= 0.0:
		push_error("drag_by was given a screen width of %f - the viewport is not resolved" % span)
		return
	var dx := 0.0
	if event is InputEventScreenDrag:
		dx = (event as InputEventScreenDrag).relative.x
	elif event is InputEventMouseMotion:
		dx = (event as InputEventMouseMotion).relative.x
	else:
		return
	sim.steer_to(sim.target_x + dx / span * Tuning.LANE_HALF_WIDTH * 3.4)
