extends SceneTree

## Entry point for the pure tests.
##
##   godot --headless --script res://test/run_tests.gd
##
## Almost nothing loaded here touches a Node, a viewport or an input event, so
## this runs in a container with no GPU and no display in about a second. The
## scene is exercised separately by run_smoke.gd, which is slower and catches a
## different class of bug.
##
## The one deliberate exception is `test_controls.gd`, whose subject IS the
## wiring between a thumb and the simulation. It instantiates the scene and
## drives a real input event through the real handler, but it never adds
## anything to a tree and never opens a viewport, so it still runs here in
## milliseconds. See its header for why that boundary is exactly where it is.
##
## **The suite list is a glob, not a hand-written array**, and that is the only
## interesting thing about this file. TESTING.md: any list of things to run that
## is maintained by hand fails silently in the safe-looking direction. A sibling
## game added nine `test_*.gd` files, did not add them to the array, and its
## runner reported "65 passing" for a suite that had never been run - a number
## that looks like evidence and is not. The directory is the list.
##
## Two failures are deliberate rather than tolerated:
##
## - **An empty glob FAILS.** Zero suites and a green exit are indistinguishable
##   from outside, and "the runner is broken" is a different answer from "the
##   game is fine". A tool that cannot report failure reports absence instead.
## - **A suite count below the floor fails.** See MIN_ASSERTIONS below.


## The floor under the whole suite's assertion count.
##
## Not a target - a canary. A runtime error inside a check (a renamed property
## read off an untyped local, say) is non-fatal in GDScript: the check function
## stops at that line, every assertion below it never runs, and the harness
## carries on and prints "all passing" with a smaller number nobody reads. On a
## sibling game that silently deleted fifteen assertions, one of which existed
## because its absence had already shipped a build with no visible HUD.
##
## The count cannot say WHICH assertions vanished, only that some did, and that
## is enough, because the cause is always the same shape.
##
## Counted by hand rather than measured, because the number has to be in the
## file before the first run: the four original suites assert 4,410 times (the
## arithmetic is dominated by three loops - 43x8 hash pairs, 4,000 stream draws,
## 10 deciles) and test_version, test_sim_boundary and test_controls bring it to
## 4,444. The floor sits below that on purpose, so an off-by-a-few in a
## conditional branch cannot turn a freshly scaffolded game red on its first run,
## and still far enough above zero to catch any bail worth catching. **Raise it
## when you add suites** - the runner prints the live count and nags when the gap
## grows wide enough to be worth closing.
const MIN_ASSERTIONS := 4400

## How far above the floor the count may drift before the runner asks for the
## floor to be re-recorded. Without this the floor rots: a suite that has
## doubled in size is no longer guarded by a number set when it was half that.
const FLOOR_SLACK := 400


func _initialize() -> void:
	var names: Array[String] = []
	var dir := DirAccess.open("res://test")
	if dir == null:
		print("  FAIL  cannot open res://test - the runner is broken, not the game")
		quit(1)
		return
	for f in dir.get_files():
		# `.gd` in the editor and in a source checkout, `.gd.remap` in an
		# exported build, where the script itself has been compiled away.
		var file := f.trim_suffix(".remap")
		if not file.begins_with("test_") or not file.ends_with(".gd"):
			continue
		if not names.has(file):
			names.append(file)
	names.sort()

	if names.is_empty():
		print("")
		print("  FAIL  the glob matched no suites in res://test")
		print("        Zero tests is not zero failures. Either the files moved or the")
		print("        naming convention did; a green exit here would be a lie.")
		quit(1)
		return

	var suites := []
	for file in names:
		suites.append(load("res://test/" + file).new())

	print("  suites: %s" % ", ".join(names))
	var t := TestHarness.new()
	var code := TestHarness.run_all(suites, t)

	if code == 0 and t.checks < MIN_ASSERTIONS:
		print("")
		print("  FAIL  %d assertions ran, but at least %d are expected." % [t.checks, MIN_ASSERTIONS])
		print("        Nothing is red, which is the point: a check errored part-way and")
		print("        every assertion below it never ran. Look for a renamed property")
		print("        read off an untyped local. Fix that, do not lower the floor.")
		code = 1
	elif code == 0 and t.checks > MIN_ASSERTIONS + FLOOR_SLACK:
		print("  note: %d assertions against a floor of %d - raise MIN_ASSERTIONS in run_tests.gd"
			% [t.checks, MIN_ASSERTIONS])

	quit(code)
