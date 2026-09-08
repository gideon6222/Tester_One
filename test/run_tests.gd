extends SceneTree

## Entry point for the pure tests.
##
##   godot --headless --script res://test/run_tests.gd
##
## Nothing loaded here touches a Node, a viewport or an input event, so this
## runs in a container with no GPU and no display in about a second. The scene
## is exercised separately by run_smoke.gd, which is slower and catches a
## different class of bug.


func _initialize() -> void:
	var suites := [
		load("res://test/test_util.gd").new(),
		load("res://test/test_tuning.gd").new(),
		load("res://test/test_sim.gd").new(),
		load("res://test/test_golden.gd").new(),
	]
	var code := TestHarness.run_all(suites)
	quit(code)
