extends RefCounted

## THE FILMED-RUN GATE. A bot that holds a thumb, asserted rather than assumed.
##
## `test_controls.gd` proves a drag moves the avatar the right way at ONE instant.
## This proves the seam a whole filmed run drives through is still wired up, which
## is a different failure: `scripts/replay_player.gd policy=<name>` can go inert -
## a renamed method, a restore quietly dropped, a policy that never asks for
## anything - and the only symptom is a film of a game nobody appears to be
## playing. That is indistinguishable from a film of a game that ignores input,
## and it is the shape of fault this studio keeps paying for: **the check passes
## because nothing happened.**
##
## Everything here is arithmetic on a scene that is never added to a tree, so it
## runs in the pure suite alongside `test_controls.gd`.

## The phone's width in project pixels, the number the real handler gets on the
## device. The assertions below are about direction and about a round trip, so a
## wrong magnitude would still pass while hiding that nobody had checked the units.
const SPAN := 1080.0

## How long to look for a frame the policy actually wants to steer on. Ten seconds
## at 60 Hz is far longer than the placeholder world takes to put something ahead
## of the player.
const SEARCH_FRAMES := 600


func _game() -> Main:
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	# `freeze()` boots the world explicitly. `_ready` has not fired, so without it
	# `sim` is null and every read below is a non-fatal error that silently deletes
	# the rest of the check.
	main.freeze()
	return main


func _drag(dx: float) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.relative = Vector2(dx, 0.0)
	e.position = Vector2(SPAN * 0.5, 900.0)
	return e


## Step the game until the policy actually wants to move, and report how far it
## got. Returns 0.0 if it never wanted anything.
##
## This exists because of the precondition rule: a test that drives a policy which
## happens to want nothing asserts nothing and reports the same green as one that
## works. The caller asserts on the result rather than assuming it, so "the world
## never put anything in front of the bot" fails as itself instead of being
## reported as whatever was being measured.
func _steer_the_policy_wants(main: Main, policy: String, mem: Dictionary) -> float:
	for i in SEARCH_FRAMES:
		var asked: Vector2 = main.bot_drag_pixels(policy, mem, SPAN)
		if absf(asked.x) > 1.0:
			return asked.x
		main.advance(1.0 / 60.0)
	return 0.0


func test_the_game_exposes_the_bot_seam(t: TestHarness) -> void:
	# Named on its own, because every other check in this file reads as "the bot
	# wanted nothing" when the method is simply not there any more.
	var main := _game()
	t.ok(main.has_method("bot_drag_pixels"),
		"Main no longer implements bot_drag_pixels(policy, mem, span), so `policy=` films a game nobody is playing and this whole gate is inert")
	t.ok(main.has_method("bot_can_drive"),
		"Main no longer implements bot_can_drive(), so a bot will steer during the interlude and after the run is over")
	main.free()


func test_a_policy_that_wants_nothing_asks_for_no_drag(t: TestHarness) -> void:
	# The positive control. The way every assertion here goes vacuous is for
	# bot_drag_pixels to return zero always, in which case "it did not steer the
	# wrong way" is true of a seam that does nothing at all.
	var main := _game()
	var mem := {}
	var asked: Vector2 = main.bot_drag_pixels(Policies.PASSIVE, mem, SPAN)
	t.approx(asked.x, 0.0, 0.0001,
		"the PASSIVE policy asked for a drag of %.3f px - it touches nothing, so the seam is inventing input" % asked.x)
	main.free()


func test_asking_the_policy_does_not_move_the_simulation(t: TestHarness) -> void:
	# The restore is the whole point of the seam. Without it the bot sets the
	# steering target directly AND pushes a drag, so the run is driven by the
	# shortcut while appearing to be driven by a thumb - a filmed run that proves
	# nothing while looking like the one artefact that would have.
	var main := _game()
	var mem := {}
	var wanted := _steer_the_policy_wants(main, Policies.GREEDY, mem)
	t.ok(absf(wanted) > 1.0,
		"the GREEDY policy never wanted to steer in %d frames, so the checks that follow assert nothing about the seam" % SEARCH_FRAMES)
	if absf(wanted) <= 1.0:
		main.free()
		return
	var before: float = main.sim.target_x
	var again: Vector2 = main.bot_drag_pixels(Policies.GREEDY, mem, SPAN)
	t.approx(main.sim.target_x, before, 0.0001,
		"bot_drag_pixels left the steering target at %.4f instead of %.4f - it asked the policy and kept the answer, so the bot is taking the shortcut and filming it too"
			% [main.sim.target_x, before])
	t.ok(absf(again.x) > 1.0,
		"the second ask returned %.3f px after the first returned %.3f - asking twice with the world unchanged must give the same answer" % [again.x, wanted])
	main.free()


func test_the_drag_the_bot_asks_for_lands_where_the_policy_wanted(t: TestHarness) -> void:
	# The round trip, through the real handler, asserted as a PROPERTY rather than
	# by restating the formula: after the asked-for drag is applied, the policy has
	# nothing left to ask for. A test that recomputed `world_dx * span / (...)` here
	# would pass with the conversion wrong in both places, which is the trap of a
	# test that re-derives the rule it is testing.
	#
	# It also catches an inverted control without naming one: if the sign were
	# wrong, applying the drag would carry the avatar the other way and the second
	# ask would be LARGER, not smaller.
	var main := _game()
	var mem := {}
	var wanted := _steer_the_policy_wants(main, Policies.GREEDY, mem)
	t.ok(absf(wanted) > 1.0,
		"the GREEDY policy never wanted to steer in %d frames, so the round trip below asserts nothing" % SEARCH_FRAMES)
	if absf(wanted) <= 1.0:
		main.free()
		return

	# Exactly what the bot asked for, through the method `_unhandled_input` calls.
	main.drag_by(_drag(wanted), SPAN)
	var left_to_ask: Vector2 = main.bot_drag_pixels(Policies.GREEDY, mem, SPAN)
	t.lt(absf(left_to_ask.x), absf(wanted) * 0.1,
		"the bot asked for %.2f px, that drag went through the real handler, and it still wants %.2f px - the conversion in bot_drag_pixels and the one in drag_by disagree, or the control is inverted"
			% [wanted, left_to_ask.x])
	main.free()


func test_the_bot_is_refused_once_the_run_is_over(t: TestHarness) -> void:
	# A bot that keeps steering after the end films a corpse being nudged, and
	# nothing about that fails on its own.
	var main := _game()
	t.ok(main.bot_can_drive(), "a freshly booted run refuses to let a bot drive, so no filmed policy run can ever start")
	main.sim.over = true
	t.ok(not main.bot_can_drive(), "the bot is still allowed to drive after the run is over")
	main.free()
