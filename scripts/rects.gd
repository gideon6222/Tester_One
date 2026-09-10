extends SceneTree

## Print where the controls REALLY are, in the coordinate space a replay uses.
##
## A headless run cannot answer this: its viewport is 100x100 and every anchored
## control reports nonsense against it. So this opens a real window, lets the
## layout resolve over several frames, and prints the global rects.

var _main
var _frames := 0

func _initialize() -> void:
	_main = load("res://src/game/main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	print("viewport: ", root.get_visible_rect().size)
	var hud = _main._hud
	for pair in [["dpad", hud._pad], ["uplink", hud._uplink_btn], ["lamp", hud._lamp_btn],
			["load", hud._load_btn], ["close", hud._manifest._close]]:
		var c: Control = pair[1]
		var r := c.get_global_rect()
		print("%-8s rect=%s centre=(%d, %d)" % [pair[0], str(r),
			int(r.position.x + r.size.x * 0.5), int(r.position.y + r.size.y * 0.5)])
	quit(0)
	return true
