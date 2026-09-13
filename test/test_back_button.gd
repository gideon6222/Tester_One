extends RefCounted

## THE BACK BUTTON, ANSWERED ON THE DESK.
##
## Every session in this studio that has picked up the phone has picked it up to
## ask the same two questions, and one of them is "does back unwind properly".
## It does not need the phone. What back does is a stack discipline -
## `ScreenStack` plus `Main.back_pressed()` - and a stack discipline is
## arithmetic. This file settles it in milliseconds so the phone pass is spent on
## the things only a phone can answer: thermal, safe area, real touch, and what
## Android does around the press.
##
## Like `test_controls.gd`, nothing here enters a tree. It instantiates the scene
## and calls the real handler, which is why it belongs in the pure suite.
##
## **It asserts the unwinding, never the setting.** `project.godot` carrying
## `quit_on_go_back=false` is a line of config that cannot fail - it is either
## there or it is a one-word diff - and a test of it would be a construct that
## cannot go red. What CAN fail, and what shipped in this template, is the
## setting being there with no handler behind it: back then does nothing at all.
## Every check below drives `back_pressed()` or the notification that calls it.
##
## The four failure modes it is written against, all of them things a real game
## here has done:
##
##   1. One press clears the whole stack, so back from a sub-menu drops the
##      player to the game and skips the menu they came from.
##   2. Back quits with a screen still open, so a press meant to close the pause
##      menu closes the game.
##   3. Back quits without saving, so the commonest way a phone game is left is
##      also the way a run is lost.
##   4. A screen is open at boot, which silently turns `test_controls.gd` and
##      every filmed run into a test of that screen instead of the game.


## Where the save lands. Read back rather than trusted, because "the game says it
## saved" and "there is a save" are different claims and only the second one is
## the player's.
const SAVE := SimSave.PATH


func _game() -> Main:
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	# Typed local and an explicit boot, for the reasons test_controls.gd's header
	# gives: `_ready` has not fired off the tree, so without this `sim` is null
	# and every read below is a non-fatal error that deletes the rest of the check.
	main.freeze()
	return main


func test_the_stack_is_empty_at_boot(t: TestHarness) -> void:
	# The quiet one, and the one that protects every other harness in the repo.
	# A game that opens with a screen in front of it makes test_controls.gd a
	# test of that screen, and it goes on passing while measuring nothing.
	var main := _game()
	t.eq(main.screens.depth(), 0,
		"the game boots with a screen already open, so test_controls.gd and every filmed run are now measuring that screen instead of the game")
	t.ok(main.screens.is_empty(), "screens.is_empty() disagrees with screens.depth() at boot")
	t.eq(main.screens.top(), "", "an empty stack named a top screen")
	main.free()


func test_one_press_closes_exactly_one_layer(t: TestHarness) -> void:
	var main := _game()
	main.screens.push("pause")
	main.screens.push("settings")

	t.eq(main.back_pressed(), "popped", "a press with two screens open did not report closing one")
	t.eq(main.screens.depth(), 1,
		"a back press from a sub-screen did not leave the screen underneath it open - one press must close exactly one layer, not the whole stack")
	t.eq(main.screens.top(), "pause",
		"the wrong layer is on top after one press, so back skipped a screen the player came through")
	main.free()


func test_two_presses_reach_the_game_without_quitting(t: TestHarness) -> void:
	# The pair matters. A handler that pops one layer and then quits passes the
	# check above and still closes the game on the second press.
	var main := _game()
	main.screens.push("pause")
	main.screens.push("settings")

	t.eq(main.back_pressed(), "popped", "the first of two presses did not close a layer")
	# Held in a local rather than called inside the message: an argument is
	# evaluated whether the assertion passes or fails, so a second call in the
	# failure text would press the button a third time and change the state the
	# next check reads.
	var second := main.back_pressed()
	t.eq(second, "popped",
		"the second press reported '%s' instead of closing the last screen - back quit the game while a screen was still open"
			% second)
	t.eq(main.screens.depth(), 0, "two presses over two screens did not land back on the game")
	main.free()


func test_a_press_with_nothing_open_quits(t: TestHarness) -> void:
	# The positive control for all of the above. Without it a handler that
	# refuses to quit under any circumstance passes every other check here, and
	# the player cannot leave the game with the button Android gives them.
	var main := _game()
	t.eq(main.back_pressed(), "quit",
		"a back press with no screen open did not ask to quit, so the player cannot leave the game")
	t.eq(main.screens.depth(), 0, "quitting pushed or popped something")
	main.free()


func test_the_run_is_saved_on_the_last_press(t: TestHarness) -> void:
	# Back is how a phone game is left. A press that does not save is a run lost,
	# and it is invisible on the desk unless something reads the file back.
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var distance: float = main.sim.distance
	var before: int = main.saves_written

	t.eq(main.back_pressed(), "quit", "the press under test did not reach the quit path")
	t.eq(main.saves_written, before + 1, "the last back press did not save the run")

	# The counter is the game's own word for it. This is the player's: a real
	# file, read back through the real loader, carrying the run that was live.
	var restored := Sim.new()
	t.ok(SimSave.read_file(restored, SAVE),
		"no save could be read from %s after a back press, so the run the player left is gone" % SAVE)
	t.approx(restored.distance, distance, 0.001,
		"the save written by the back press does not hold the run that was on screen")

	main.free()
	# Leave the user directory as it was found. A stray save here is inert today
	# (nothing loads one at boot) but a game built from this template will load
	# one, and a test that plants a run for the next test is a trap.
	if not had_save:
		DirAccess.remove_absolute(SAVE)


func test_a_press_also_saves_while_a_screen_is_open(t: TestHarness) -> void:
	# Not only the last press. A player who backs out of a pause menu and then
	# gets a phone call has still left the game, and the run has to be on disk.
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.screens.push("pause")
	var before: int = main.saves_written

	t.eq(main.back_pressed(), "popped", "the press under test did not reach the popped path")
	t.eq(main.saves_written, before + 1, "a back press that closed a screen did not save the run")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## THE WIRING, which is the half that cannot be proved by calling the method.
##
## Everything above would pass on a game whose `back_pressed()` is perfect and
## never called, which is exactly the state this template was in: the setting
## was in `project.godot` and no handler existed. This fires the notification
## Android actually sends.
##
## A screen is pushed first on purpose, so the handler takes the "popped" branch
## and there is no path from this check to `get_tree().quit()`.
func test_the_notification_android_sends_reaches_the_handler(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.screens.push("pause")

	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	t.eq(main.screens.depth(), 0,
		"NOTIFICATION_WM_GO_BACK_REQUEST did not reach back_pressed(), so the back button does nothing on the phone - which is what quit_on_go_back=false buys you without a handler")

	# And the handler must not answer notifications that are not the back button.
	main.screens.push("pause")
	main.notification(Node.NOTIFICATION_WM_MOUSE_ENTER)
	t.eq(main.screens.depth(), 1,
		"an unrelated notification closed a screen, so the checks above may be reading a handler that fires on anything")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## The quit branch of the notification, off the tree, which is where every test
## in this suite lives.
##
## `get_tree()` on a node that is not in a tree does not return null - it raises
## "Parameter data.tree is null", a non-fatal engine error that the harness
## counts and fails the test for. So the handler asks `is_inside_tree()` first,
## and this is the check that keeps that guard honest: without it the quit path
## is never exercised here at all, because every other check pushes a screen
## precisely so it cannot be.
func test_the_quit_branch_does_not_raise_off_the_tree(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	t.ok(main.screens.is_empty(), "this check only means anything with nothing open")

	# The assertion is the absence of an engine error, which TestHarness turns
	# into a failure of this test on its own. The eq below is here so the check
	# is not counted as having asserted nothing.
	main.notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	t.eq(main.screens.depth(), 0, "a back press with nothing open changed the stack")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## The stack on its own, away from the game, because `Main` only ever exercises
## the shallow end of it and the class is what a real game will lean on.
func test_the_stack_counts_and_unwinds_in_order(t: TestHarness) -> void:
	var s := ScreenStack.new()
	t.ok(s.is_empty(), "a fresh stack is not empty")
	t.eq(s.pop(), "", "popping an empty stack invented a screen name")

	for screen in ["pause", "settings", "audio"]:
		s.push(screen)
	t.eq(s.depth(), 3, "three pushes did not make a depth of three")
	t.eq(s.pop(), "audio", "the stack unwound in the wrong order")
	t.eq(s.pop(), "settings", "the stack unwound in the wrong order")
	t.eq(s.depth(), 1, "two pops off three left the wrong depth")
	s.clear()
	t.ok(s.is_empty(), "clear() left something on the stack")
