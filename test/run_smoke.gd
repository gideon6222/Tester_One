extends SceneTree

## Smoke test: boots the real scene and plays it.
##
##   godot --headless --script res://test/run_smoke.gd
##
## The pure tests in run_tests.gd cannot see a wiring bug - a scene that fails
## to build, a node that is never added, a render path that stopped being
## flushed, a HUD reading a field that no longer exists. Those only show up
## when something actually instantiates the game.
##
## The load-bearing assertion is the last one: **the number of instances drawn
## must match the number of entities that exist.** A subsystem that renders
## nothing and a subsystem that does not exist look identical from outside.
## That exact bug has already cost a full tuning pass on another game here -
## the enemies were invisible while still charging and still killing, and it
## was read as a balance problem for days.

## The floor under this suite's assertion count. See the same constant in
## run_tests.gd for the full reasoning; the short version is that a runtime
## error inside a check is non-fatal in GDScript, so the check stops there,
## every assertion below it never runs, and this file prints "all passing" with
## a smaller number nobody reads.
##
## **The smoke suite is where that actually happened.** A sibling game renamed a
## HUD gauge, the suite read the old name off an untyped `main`, and the count
## went from 402 to 387 with nothing red - fifteen assertions gone, including
## "the gauge is on screen", which exists because its absence had already
## shipped.
##
## This suite asserts 19 times today. The floor sits one below that so a
## conditional branch cannot redden a freshly scaffolded game, and it is still
## tight enough that any bail worth catching drops under it. Raise it as the
## suite grows - the count is printed on every run.
const MIN_ASSERTIONS := 18

var _t := TestHarness.new()


func _initialize() -> void:
	var scene: PackedScene = load("res://src/game/main.tscn")
	_t.begin("smoke > the scene loads")
	_t.ok(scene != null, "main.tscn failed to load")
	if scene == null:
		_finish()
		return

	var main = scene.instantiate()
	root.add_child(main)

	# Freeze first, then step. Two reasons, and the second is not obvious:
	# real frames run between a scene loading and a harness taking over, so
	# without this every number would move with the speed of the machine - and
	# `_ready` has not fired yet either, because add_child() during
	# SceneTree._initialize() defers it to the first processed frame. freeze()
	# boots the scene explicitly, which is why the assertions come after it.
	main.freeze()

	_t.begin("smoke > the scene builds its world")
	_t.ok(main.sim != null, "Sim was never created")
	_t.ok(main.get_node_or_null("Road") != null, "the road is missing from the scene")

	main.advance(12.0)

	var s: Dictionary = main.sim.state()

	_t.begin("smoke > twelve seconds of play happened")
	_t.gt(s["distance"], 60.0, "the player barely moved in twelve seconds")
	_t.gt(float(s["obstacles"]), 0.0, "nothing was spawned on the track")

	_t.begin("smoke > everything that exists is actually drawn")
	var drawn_obstacles: int = main._obstacles.multimesh.visible_instance_count
	var drawn_pickups: int = main._pickups.multimesh.visible_instance_count
	var live_obstacles := _live(main.sim.obstacles)
	var live_pickups := _live(main.sim.pickups)

	_t.gt(float(drawn_obstacles), 0.0,
		"obstacles exist in the model but none are drawn - visible_instance_count is not being set")
	_t.eq(drawn_obstacles, live_obstacles,
		"drawn obstacles do not match the model")
	_t.eq(drawn_pickups, live_pickups,
		"drawn pickups do not match the model")

	_t.begin("smoke > the HUD reflects the run")
	_t.ok(main._hud.text.contains("SCORE"), "the HUD is not being written")
	_t.ok(main._hud.text.contains(str(main.sim.lives)), "the HUD lives count disagrees with the run")

	_check_the_controls_are_anchored(main)
	_check_the_level_can_be_left(main)

	_finish()


## The controls must be ANCHORED to the viewport, never placed at a literal
## coordinate.
##
## A structural assertion rather than a behavioural one, because the bug it
## guards against is invisible at the size the tests run. The project stretches
## with `aspect = "expand"`, which keeps the base WIDTH and extends the HEIGHT -
## so on a 19.5:9 phone the canvas is about 1080x2340 while the base is
## 1080x1920. Controls laid out against the literal 1920 drew hundreds of pixels
## above where they belonged, and the report was "the icons are about half an
## inch too high".
##
## **A headless run uses the base size, where the wrong layout and the right one
## are identical** - so no screenshot or coordinate check taken here could ever
## have caught it. What CAN be checked is the property that makes it impossible.
func _check_the_controls_are_anchored(main) -> void:
	_t.begin("smoke > the controls are anchored, not placed")
	var pad: Control = main._pad
	_t.eq(pad.anchor_bottom, 1.0,
		"the pad is not anchored to the bottom of the viewport - it will drift on a tall screen")
	_t.eq(pad.anchor_top, 1.0,
		"the pad is anchored to the TOP, so its distance from the bottom follows the aspect ratio")
	_t.lt(pad.offset_bottom, 0.0,
		"the pad is offset downward from its anchor and will sit off the bottom of the screen")
	_t.ok(pad.gui_input.get_connections().size() > 0,
		"the pad does not handle its own input, so its hit box is a second source of truth")
	_t.eq(pad.mouse_filter, Control.MOUSE_FILTER_STOP,
		"the pad does not consume its own touches, so one gesture drives two things")


## A finished level must start the next one.
##
## The assertion an earlier version of this template did not have, and the one
## that would have caught the first bug a game built from it shipped: `over`
## went true at the end of a level, `advance()` returned early from then on, and
## the game froze with a live HUD.
##
## Every other test in the suite plays a level and reads the state at the END,
## which is the exact instant that freeze begins. **A suite that always stops
## where the content stops cannot see past the end of the content**, so this one
## deliberately drives THROUGH the boundary - and through the real scene, since
## the missing code was in the renderer's handler and not in Sim.
func _check_the_level_can_be_left(main) -> void:
	_t.begin("smoke > a finished level starts the next one")
	main.freeze()
	var guard := 0
	while not main.sim.over and guard < 12000:
		main.advance(1.0 / 60.0, 1.0 / 60.0)
		guard += 1
	_t.eq(main.sim.over, true, "the level never ended one way or the other")

	var level: int = main.sim.level
	var won: bool = main.sim.won

	main.advance(main.INTERLUDE_SECONDS + 0.5, 1.0 / 60.0)
	_t.eq(main.sim.over, false,
		"the game is still frozen after the interlude - this is the bug that shipped")
	if won:
		_t.eq(main.sim.level, level + 1, "finishing a level did not start the next one")
	else:
		_t.eq(main.sim.level, 1, "running out did not send the run back to the first level")

	# And it has to actually play on the other side.
	var before: float = main.sim.distance
	main.advance(1.0, 1.0 / 60.0)
	_t.gt(main.sim.distance, before, "the next level does not advance when the frame loop runs")


func _live(items: Array[Dictionary]) -> int:
	var n := 0
	for i in items:
		if not i.taken:
			n += 1
	return n


func _finish() -> void:
	print("")
	if _t.failures.is_empty() and _t.checks < MIN_ASSERTIONS:
		print("  smoke: %d assertions, but at least %d are expected." % [_t.checks, MIN_ASSERTIONS])
		print("         Nothing is red, which is the point: a check errored part-way and")
		print("         every assertion below it never ran. Fix that, do not lower the floor.")
		quit(1)
		return
	if _t.failures.is_empty():
		print("  smoke: %d assertions, all passing" % _t.checks)
		quit(0)
		return
	for f in _t.failures:
		print("  FAIL  %s" % f)
	print("")
	print("  smoke: %d assertions, %d FAILED" % [_t.checks, _t.failures.size()])
	quit(1)
