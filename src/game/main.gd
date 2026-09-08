extends Node3D

## The shell. Reads `Sim` and draws it; never decides anything.
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

var sim: Sim

var _cam: Camera3D
var _road: MeshInstance3D
var _player: MeshInstance3D
var _obstacles: MultiMeshInstance3D
var _pickups: MultiMeshInstance3D
var _hud: Label
var _dragging := false

## Set by the headless harness. When true the frame loop does not step the sim,
## so `advance()` is the only thing moving time and results do not depend on
## how fast the machine boots.
var frozen := false


var _booted := false


func _ready() -> void:
	_ensure_booted()


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
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	sun.light_energy = 1.6
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

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(24, 24)
	_hud.add_theme_font_size_override("font_size", 34)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	_hud.add_theme_constant_override("outline_size", 8)
	layer.add_child(_hud)


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
	if frozen:
		return
	_tick(delta)


func _tick(dt: float) -> void:
	sim.advance(dt)
	_sync()


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
	_sync()


# --- drawing --------------------------------------------------------------

func _sync() -> void:
	var z := sim.distance
	_player.position = Vector3(sim.x, 0.45, z)

	# Transform3D.looking_at rather than Node3D.look_at. The node method
	# requires the node to be inside the tree and errors if it is not - and a
	# headless harness that adds this scene and steps it immediately is exactly
	# that case, because add_child() during SceneTree._initialize() does not
	# put anything in the tree until the first frame. This is pure maths and
	# works anywhere.
	var eye := Vector3(sim.x * 0.35, 5.4, z - 9.0)
	var focus := Vector3(sim.x * 0.2, 1.0, z + 10.0)
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
			n, Transform3D(Basis.IDENTITY, Vector3(item.x, y, item.z))
		)
		n += 1
	mmi.multimesh.visible_instance_count = n


# --- input ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_dragging = event.pressed
	elif event is InputEventMouseButton:
		_dragging = event.pressed
	elif event is InputEventScreenDrag or (event is InputEventMouseMotion and _dragging):
		# Relative drag, not absolute position: the thumb is never where the
		# player is looking, and an absolute mapping makes the first touch of
		# every run yank the player sideways.
		var dx: float = event.relative.x
		var span := float(get_viewport().get_visible_rect().size.x)
		sim.steer_to(sim.target_x + dx / span * Tuning.LANE_HALF_WIDTH * 3.4)
