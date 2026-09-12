extends SceneTree

## Print where the controls REALLY are, in the coordinate space a replay uses.
##
##   godot --path . --resolution 460x996 --script res://scripts/rects.gd
##
## **A headless run cannot answer this.** A headless root reports 100x100 and
## every anchored control resolves against that, so a replay written from a
## headless probe lands every tap in the top-left fifth of the screen, hits
## nothing, and films a game that looks broken rather than a coordinate that is.
## So this opens a real window, lets the layout resolve over several frames, and
## prints the global rects.
##
## **It walks the scene.** The version this replaces named four controls out of
## the game it was copied from - `_hud._pad`, `_uplink_btn`, `_lamp_btn`,
## `_manifest._close` - so it threw on the first frame of every game scaffolded
## from this template, which is to say it has never once run where it shipped.
## A tool that names the thing it inspects has to be edited before it can be
## used; a tool that finds it works on day one. Nothing below knows what game
## this is.
##
## Also printed, because a rect alone is not enough to write a replay against:
## whether the control is visible, and whether it takes touches at all. A tap
## delivered to a control whose `mouse_filter` is IGNORE hits whatever is behind
## it, and a miss is not an error - it is a green run that proves nothing.

var _main: Main
var _frames := 0


func _initialize() -> void:
	var scene: PackedScene = load("res://src/game/main.tscn")
	_main = scene.instantiate() as Main
	root.add_child(_main)


func _process(_delta: float) -> bool:
	# Six frames, unchanged from the version this replaces: control layout is
	# resolved during a frame, and a rect read before one has run is a zero-size
	# rect at the origin for every anchored control in the scene.
	_frames += 1
	if _frames < 6:
		return false

	print("viewport: %s" % str(root.get_visible_rect().size))
	print("%-38s %-30s %-16s %s" % ["node", "rect", "centre", "flags"])
	var found := _print_controls(_main)

	if found == 0:
		printerr("")
		printerr("  no Control was found anywhere under %s." % _main.name)
		printerr("  That is this tool failing, not a game with no interface -")
		printerr("  an empty listing and a broken walk look identical from here.")
		quit(1)
		return true

	print("")
	print("%d controls. Replay coordinates go in THIS space - the project viewport -" % found)
	print("not in the --resolution the window was opened at.")
	quit(0)
	return true


## Depth-first, so the printed order is the order they are drawn in and a
## control sitting on top of another is the one below it in this list.
func _print_controls(node: Node) -> int:
	var found := 0
	if node is Control:
		var c := node as Control
		var r := c.get_global_rect()
		print("%-38s %-30s %-16s %s" % [
			str(_main.get_path_to(c)),
			"(%.0f, %.0f) %.0fx%.0f" % [r.position.x, r.position.y, r.size.x, r.size.y],
			"(%d, %d)" % [int(r.get_center().x), int(r.get_center().y)],
			"%s %s" % ["visible" if c.is_visible_in_tree() else "HIDDEN", _filter(c.mouse_filter)],
		])
		found += 1
	for child in node.get_children():
		found += _print_controls(child)
	return found


## Plain `if`s rather than a `match`, so the compiler can see that every path
## returns a String without having to decide whether a wildcard arm counts.
func _filter(f: int) -> String:
	if f == Control.MOUSE_FILTER_STOP:
		return "takes touches"
	if f == Control.MOUSE_FILTER_PASS:
		return "passes touches on"
	return "IGNORES touches"
