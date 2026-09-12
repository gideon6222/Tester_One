extends RefCounted

## THE HANDEDNESS GATE. Drag right, go right - asserted, not assumed.
##
## This studio has shipped inverted controls in five games: Captain Run,
## Coreward (twice), Wrecking Crew, Stillwater and Wildform. The rule is written
## down three times - `CRAFT.md:183-185`, `CRAFT.md:257-258` and `POLISH.md:29` -
## and it has never once prevented it. The wildform post-mortem says why: "the
## rule was written as advice about a convention rather than as a test that
## fails". It is a test now.
##
## **Why nothing else catches it.** Wildform had a whole-run golden over five
## scripted policies, 86 tests, 4,800 assertions, a smoke test that boots the
## real scene, and filmed contact sheets of the first minute. None of them could
## see it, because every scripted policy drives the game by calling `steer_to()`
## directly. `steer_to` takes a world X and moves the avatar to that world X
## correctly, on an inverted game as on a correct one. The bug lives entirely in
## the two steps either side: the drag handler turning a thumb into a delta, and
## the camera turning a world X into a screen X. And a contact sheet of an
## avatar sliding left while nobody is watching a thumb looks exactly like an
## avatar sliding left on purpose - **the one thing no bot in this studio does
## is hold a thumb.**
##
## So this file asserts three things, and the third is the one that matters:
##
##   1. A real `InputEventScreenDrag` through the real handler moves the
##      simulation's target the way the thumb went.
##   2. The camera's own right-hand basis vector points at world +X. That is the
##      NDC test written as arithmetic - no GPU, no tree, no frame, the camera's
##      basis is the entire claim. It read -1.00 on this template before the fix
##      that landed with this file.
##   3. The avatar ends up on the right-hand side OF THE SCREEN. Not in world
##      coordinates: **a world-coordinate assertion passes on inverted
##      controls**, which is the whole point.
##
## **What this file does NOT assert, and why.** It never adds the scene to a
## tree, so it never calls `get_viewport()`. Whether `add_child()` during
## `SceneTree._initialize()` puts a node in the tree before the first processed
## frame is a question two files in this knowledge base currently answer
## differently, and a gate that depends on an unsettled fact is a gate that goes
## red on a fresh scaffold for a reason that has nothing to do with the game.
## Everything below is arithmetic on objects that exist without a tree.
##
## Consequently the drag goes through `Main.drag_by(event, span)` - the method
## `_unhandled_input` itself calls, given the width the viewport would have
## supplied - and the thumb pad goes through `_read_pad(local)`, one step short
## of `_on_pad_input`, because `Control.accept_event()` off the tree is the same
## unsettled question. The pad half is therefore the weaker half; the drag half
## is the one the five games needed.


## A phone's width in project pixels. The project's base viewport is 1080 wide
## and `stretch/aspect = "expand"` keeps the width, so this is the number the
## real handler gets on the device - which matters because the assertions below
## are about a SIGN, and a wrong magnitude would still pass while hiding the
## fact that nobody had checked the units.
const SPAN := 1080.0

## A firm sideways flick. Deliberately well clear of anything that could read as
## a tremor, so a failure means the direction is wrong rather than the distance.
const FLICK := 220.0


## A booted game, held in a TYPED local.
##
## The type is the point. An untyped `var main = scene.instantiate()` gives the
## compiler nothing to check, so a renamed member below would be a non-fatal
## runtime error that stops the check where it stands and deletes every
## assertion after it - green, with a smaller number nobody reads. `Main` has a
## `class_name` for this reason.
func _game() -> Main:
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	# `freeze()` boots the world explicitly. `_ready` has not fired - nothing is
	# in a tree - so without this `sim` is still null and every read below is a
	# non-fatal error that silently deletes the rest of the check.
	main.freeze()
	return main


func _drag(dx: float) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.relative = Vector2(dx, 0.0)
	e.position = Vector2(SPAN * 0.5, 900.0)
	return e


## Where the avatar is ON SCREEN, as a signed number: positive is right of the
## centre line, negative is left of it.
##
## `transform.affine_inverse() * p` puts the avatar in the camera's own space,
## where +X is screen right by definition. That is the whole of the projection
## that matters for handedness, it needs no viewport and no frame, and it is the
## quantity that a world-coordinate assertion cannot see.
func _screen_x(main: Main) -> float:
	var cam: Camera3D = main._cam
	var avatar: MeshInstance3D = main._player
	return (cam.transform.affine_inverse() * avatar.position).x


func test_the_scene_is_the_game_this_file_thinks_it_is(t: TestHarness) -> void:
	# Every other check here holds a `Main`. If main.tscn stops being one the
	# cast yields null and those checks bail on their first line, which the
	# harness reports as "asserted nothing" - true, but not useful. This names it.
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	t.ok(main != null, "res://src/game/main.tscn is no longer a Main - this whole gate is inert")
	if main != null:
		main.free()


func test_a_drag_to_the_right_puts_the_avatar_on_the_right_of_the_screen(t: TestHarness) -> void:
	var main := _game()
	var before: float = main.sim.target_x
	main.drag_by(_drag(FLICK), SPAN)
	t.gt(main.sim.target_x, before,
		"a drag to the RIGHT did not move the steering target to the right (%.3f -> %.3f)"
			% [before, main.sim.target_x])
	# Let the smoothing actually carry the avatar there; the target moving is
	# only half the claim.
	main.advance(1.0)
	t.gt(_screen_x(main), 0.0,
		"a drag to the RIGHT left the avatar at screen x %.2f, which is the LEFT of the screen - the controls are inverted. A world-coordinate assertion passes in this state, which is why this one is in screen space."
			% _screen_x(main))
	main.free()


func test_a_drag_to_the_left_mirrors_it(t: TestHarness) -> void:
	# The pair that proves the control exists differs in exactly one thing: the
	# sign of the flick. A single-direction test passes on a control that is
	# stuck to one side.
	var main := _game()
	var before: float = main.sim.target_x
	main.drag_by(_drag(-FLICK), SPAN)
	t.lt(main.sim.target_x, before,
		"a drag to the LEFT did not move the steering target to the left (%.3f -> %.3f)"
			% [before, main.sim.target_x])
	main.advance(1.0)
	t.lt(_screen_x(main), 0.0,
		"a drag to the LEFT left the avatar at screen x %.2f - the controls are INVERTED"
			% _screen_x(main))
	main.free()


## THE NDC TEST, as arithmetic.
##
## A Godot camera looks down its own -Z, so a chase camera following a track laid
## toward world +Z has `basis.x` pointing at world -X and screen right IS world
## -X. This template read -1.00 here until `Main.TRACK_Z` was introduced. One
## assertion, no GPU, no frame.
func test_screen_right_is_world_plus_x(t: TestHarness) -> void:
	var main := _game()
	var right: Vector3 = main._cam.transform.basis.x
	# Normalised first, because a basis carries the node's scale and a dot
	# product against an unnormalised axis reads low for a perfectly correct
	# camera - which is how the same assertion was once "fixed" by loosening it.
	t.approx(right.length(), 1.0, 0.001,
		"the camera basis is scaled (%.3f), so the assertion below is measuring scale as well as direction"
			% right.length())
	t.gt(right.normalized().x, 0.5,
		"the camera's right-hand vector points at world %s, so screen right is world -X and every drag is backwards"
			% str(right.normalized()))
	main.free()


## The pad is absolute: the thumb's position IS the value. Right of the pad's
## centre must therefore put the avatar right of the screen's centre.
func test_the_thumb_pad_pushes_the_avatar_the_way_the_thumb_went(t: TestHarness) -> void:
	var main := _game()
	var r := Main.PAD * 0.5

	main._read_pad(Vector2(r + r * 0.8, r))
	main.advance(1.0)
	t.gt(_screen_x(main), 0.0, "a thumb on the RIGHT of the pad moved the avatar to screen left")

	main.freeze()
	main._read_pad(Vector2(r - r * 0.8, r))
	main.advance(1.0)
	t.lt(_screen_x(main), 0.0, "a thumb on the LEFT of the pad moved the avatar to screen right")
	main.free()


## The positive control. A construct that cannot fail is untested, not safe -
## and the way these assertions go vacuous is for the drag to move nothing at
## all, in which case "did not move left" and "did not move right" are both
## true of a game that ignores the screen entirely.
func test_a_drag_of_nothing_moves_nothing(t: TestHarness) -> void:
	var main := _game()
	var before: float = main.sim.target_x
	main.drag_by(_drag(0.0), SPAN)
	t.approx(main.sim.target_x, before, 0.0001,
		"a zero-length drag moved the steering target, so the assertions above may be reading drift rather than input")
	# And the event type matters: the handler must ignore what is not a drag.
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	main.drag_by(touch, SPAN)
	t.approx(main.sim.target_x, before, 0.0001,
		"a press with no motion steered the avatar - the first touch of every run will yank it sideways")
	main.free()
