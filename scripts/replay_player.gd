extends Node
## Records and replays touch input on the physics frame it happened, so a filmed run
## (scripts/movie.ps1, --fixed-fps) is deterministic and a bug is a replay file rather
## than a paragraph.
##
## Autoloaded as ReplayPlayer. Does nothing unless a user arg asks for it:
##
##   godot --path . -- record=test/replays/level1.json      # write what the player does
##   godot --path . -- replay=test/replays/level1.json      # play it back
##   godot --path . -- touch                                 # emulate touch from the mouse (desk)
##   godot --path . -- policy=dodger                         # a bot that holds a thumb
##
## On the phone `record=` writes to user://replay.json; pull it with scripts/device.ps1 pull-replay.
##
## File format: JSON array of {"f": physics_frame, "t": "touch"|"drag", "i": index,
## "x": px, "y": px, "p": pressed}. Positions are in viewport coordinates, which is what
## push_input(ev, true) expects. Recorded at one stretch configuration, replayed at the same.
##
## Two things that fail silently, both verified: push_input needs in_local_coords = true or
## the click lands nowhere, and Controls have no rect until a frame has run, so the first
## event is never sent before frame 3.

var _events: Array = []
var _idx := 0
var _record_path := ""
var _recorded: Array = []
var _replaying := false

## **The bot that holds a thumb.**
##
## Every scripted policy in this studio drives a game by calling `steer_to()`,
## which is the value the control would set. A suite made entirely of policies
## therefore tests the simulation and nothing between the finger and it, which is
## how five games shipped with inverted controls past thousands of passing
## assertions and a hundred filmed frames. `test/test_controls.gd` closes that at
## one instant. This closes it over a whole run.
##
## `policy=<name>` asks the game where the policy wants to be, and then DRAGS
## there through the real touch handler. Every frame of the resulting film went
## through the input event, the viewport and the camera basis, so a film of a bot
## playing well is evidence about the CONTROL and not only about the sim. The
## first run of it on a sibling game found the evolution transform covering the
## whole screen for 5.08 seconds, three times - a fifth of the run unreadable -
## while all 4,800 of that game's assertions passed, because every one of them
## drove the sim and none drove the picture.
##
## Recorded touch replays do not replace this. They are fixed sequences that stop
## being valid the moment the layout moves; a policy adapts, so one line of
## `-UserArgs policy=dodger` films any build for as long as you like.
##
## The game supplies `bot_drag_pixels(policy, mem, span)` and optionally
## `bot_can_drive()`. See `src/game/main.gd`, which has the contract and the
## reason the arithmetic lives there rather than here.
##
## **The second thumb.** A game that is played by pressing and holding rather
## than by dragging - a cast button, a reel you hold, a keep-or-release pair -
## also supplies `bot_touch_pixels(policy, mem, size) -> Vector2`: where the
## thumb is DOWN this frame in viewport pixels, or `Vector2.INF` for up. This
## file turns the edges into real `InputEventScreenTouch` presses and releases,
## so a bot's press lands on the button through the viewport like a finger's. A
## game whose bot never presses anything leaves the method out.
##
## `policy=` and `record=` together write the bot's run out as an ordinary replay
## file, because the events it pushes are real events and the recorder below sees
## them like any others.
var _policy := ""
var _policy_mem := {}
var _bot: Node = null
var _bot_missing_reported := false
var _bot_down := false
var _bot_down_at := Vector2.ZERO

## The drag thumb is finger 0 and the pressing thumb is finger 1, as on a phone.
## They must differ: the GUI routes a drag to whichever control its finger went
## DOWN on, so a drag on the same index as a held button would be delivered to
## the button rather than to the water under the resting thumb.
const TOUCH_FINGER := 1

## How far a thumb moves in one physics frame at a brisk drag: 1080 px across in
## about a third of a second is 54 px a frame at 60 Hz. Unclamped the bot
## teleports, and a film of an avatar that teleports says nothing about whether
## the control is reachable - which is the only question this mode exists to ask.
const MAX_DRAG_PIXELS := 54.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("replay="):
			_load(s.trim_prefix("replay="))
		elif s.begins_with("record="):
			_record_path = s.trim_prefix("record=")
			if not _record_path.begins_with("res://") and not _record_path.begins_with("user://"):
				_record_path = "res://" + _record_path
		elif s == "record":
			_record_path = "user://replay.json"
		elif s.begins_with("policy="):
			_policy = s.trim_prefix("policy=")
		elif s == "touch":
			Input.emulate_touch_from_mouse = true
	set_physics_process(_replaying or _policy != "")
	if _record_path != "":
		get_tree().root.tree_exiting.connect(_flush)


func _load(path: String) -> void:
	if not path.begins_with("res://") and not path.begins_with("user://"):
		path = "res://" + path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ReplayPlayer: cannot open %s" % path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_error("ReplayPlayer: %s is not a JSON array" % path)
		return
	_events = parsed
	_replaying = _events.size() > 0
	print("ReplayPlayer: %d events from %s" % [_events.size(), path])


func _physics_process(_delta: float) -> void:
	var frame := Engine.get_physics_frames()
	if frame < 3:
		return
	if _policy != "":
		_drive_with_a_thumb()
		return
	while _idx < _events.size() and int(_events[_idx].get("f", 0)) <= frame:
		var e: Dictionary = _events[_idx]
		_idx += 1
		var ev: InputEvent
		if String(e.get("t", "touch")) == "drag":
			var d := InputEventScreenDrag.new()
			d.index = int(e.get("i", 0))
			d.position = Vector2(float(e.get("x", 0)), float(e.get("y", 0)))
			d.relative = Vector2(float(e.get("rx", 0)), float(e.get("ry", 0)))
			ev = d
		else:
			var t := InputEventScreenTouch.new()
			t.index = int(e.get("i", 0))
			t.position = Vector2(float(e.get("x", 0)), float(e.get("y", 0)))
			t.pressed = bool(e.get("p", true))
			ev = t
		get_viewport().push_input(ev, true)
	# After the last event the run keeps going until --quit-after: the tail is worth filming.


## Ask the game, then drag there for real.
func _drive_with_a_thumb() -> void:
	if _bot == null:
		_bot = _find_bot(get_tree().root)
	if _bot == null:
		# Refuse loudly, once. A harness that cannot reach its subject must say so:
		# silence here is a filmed run of a game nobody is playing, which looks
		# exactly like a filmed run of a game that ignores input.
		if not _bot_missing_reported:
			_bot_missing_reported = true
			push_error("ReplayPlayer: policy=%s was asked for, but nothing in the scene implements bot_drag_pixels(policy, mem, span). See src/game/main.gd for the contract." % _policy)
		return

	# `has_method` rather than a typed call, because the driver is generic and the
	# gate is optional. A game that never refuses input can leave it out.
	if _bot.has_method("bot_can_drive"):
		var allowed: bool = _bot.bot_can_drive()
		if not allowed:
			# A bot that may not drive takes its thumb OFF. Left down through a
			# cinematic, the next press it wants is a press it already holds: no
			# event is generated, and the run stalls under a thumb that never
			# lifts, which films as a game that ignores its own button.
			_lift_thumb()
			return

	var rect := get_viewport().get_visible_rect()
	var span := rect.size.x
	if span <= 0.0:
		return

	# Annotated, not inferred. A call on an untyped Node returns Variant, and `:=`
	# cannot infer from one - it fails the whole FILE rather than the line, and the
	# symptom is a run that never terminates (GODOT.md).
	var drag: Vector2 = _bot.bot_drag_pixels(_policy, _policy_mem, span)
	if drag.length() >= 0.001:
		drag.x = clampf(drag.x, -MAX_DRAG_PIXELS, MAX_DRAG_PIXELS)
		drag.y = clampf(drag.y, -MAX_DRAG_PIXELS, MAX_DRAG_PIXELS)
		var d := InputEventScreenDrag.new()
		d.index = 0
		# Mid-screen and low, where a thumb actually rests. The position matters to any
		# control that cares WHERE it was touched, so it is a plausible one rather than
		# the origin.
		d.position = Vector2(span * 0.5, rect.size.y * 0.8)
		d.relative = drag
		get_viewport().push_input(d, true)

	# The second thumb. Only the EDGES become events: a point where there was
	# none is a press, none where there was a point is a release, and a point
	# that moved to a different control is a release now and a press next frame,
	# because a thumb does not slide from one button onto another.
	if not _bot.has_method("bot_touch_pixels"):
		return
	var at: Vector2 = _bot.bot_touch_pixels(_policy, _policy_mem, rect.size)
	var want_down := at.is_finite()
	if want_down and _bot_down and at.distance_to(_bot_down_at) > 1.0:
		_lift_thumb()
		return
	if want_down == _bot_down:
		return
	if want_down:
		_bot_down = true
		_bot_down_at = at
		_push_touch(true, at)
	else:
		_lift_thumb()


func _lift_thumb() -> void:
	if not _bot_down:
		return
	_bot_down = false
	_push_touch(false, _bot_down_at)


func _push_touch(pressed: bool, at: Vector2) -> void:
	var t := InputEventScreenTouch.new()
	t.index = TOUCH_FINGER
	t.position = at
	t.pressed = pressed
	get_viewport().push_input(t, true)


## The game is whatever implements the contract. Matching on the contract itself
## rather than on a node name or a class keeps this file generic: a game can put
## the seam on its main scene, on a rig node, or anywhere else it likes.
func _find_bot(n: Node) -> Node:
	if n.has_method("bot_drag_pixels"):
		return n
	for c in n.get_children():
		var found := _find_bot(c)
		if found != null:
			return found
	return null


func _input(event: InputEvent) -> void:
	if _record_path == "" or _replaying:
		return
	var f := Engine.get_physics_frames()
	if event is InputEventScreenTouch:
		_recorded.append({"f": f, "t": "touch", "i": event.index, "x": event.position.x, "y": event.position.y, "p": event.pressed})
	elif event is InputEventScreenDrag:
		_recorded.append({"f": f, "t": "drag", "i": event.index, "x": event.position.x, "y": event.position.y, "rx": event.relative.x, "ry": event.relative.y})


func _flush() -> void:
	if _record_path == "" or _recorded.is_empty():
		return
	var f := FileAccess.open(_record_path, FileAccess.WRITE)
	if f == null:
		push_error("ReplayPlayer: cannot write %s" % _record_path)
		return
	f.store_string(JSON.stringify(_recorded))
	print("ReplayPlayer: wrote %d events to %s" % [_recorded.size(), _record_path])
