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
		elif s == "touch":
			Input.emulate_touch_from_mouse = true
	set_physics_process(_replaying)
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
