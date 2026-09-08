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

	_finish()


func _live(items: Array[Dictionary]) -> int:
	var n := 0
	for i in items:
		if not i.taken:
			n += 1
	return n


func _finish() -> void:
	print("")
	if _t.failures.is_empty():
		print("  smoke: %d assertions, all passing" % _t.checks)
		quit(0)
		return
	for f in _t.failures:
		print("  FAIL  %s" % f)
	print("")
	print("  smoke: %d assertions, %d FAILED" % [_t.checks, _t.failures.size()])
	quit(1)
