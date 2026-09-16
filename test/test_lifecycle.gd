extends RefCounted

## THE OTHER WAY A PHONE GAME IS LEFT, ANSWERED ON THE DESK.
##
## `test_back_button.gd` covers the press the player makes on purpose. This
## covers the commoner departure: home, the task switcher, a call arriving.
## Android sends no back request for any of them, gives no promise that the
## process survives, and a run that was not written to disk on the way out is
## simply gone - which the player experiences as the game losing their progress
## for no reason they can see.
##
## It is here rather than on the phone because the whole of it is arithmetic on
## `Main._notification`, and `DEVICE.md` records what Android actually delivers.
## The handset is for the four questions only it can answer, and "does pausing
## save" is not one of them.
##
## **The check that matters is the third one.** One home press on his Galaxy S26
## Ultra fires `NOTIFICATION_APPLICATION_PAUSED` **and**
## `NOTIFICATION_APPLICATION_FOCUS_OUT` (`DEVICE.md`, measured on snowball), so a
## handler wired to both without a latch writes the player's run twice for one
## departure. Two saves is not a crash, which is why it needs a test: it is
## invisible from outside and it doubles the disk work on the one path the player
## is already waiting on.
##
## Verified by reintroduction 2026-09-16: remove the `if _backgrounded: return`
## guard from `Main._leave()` and `test_one_departure_writes_one_save` goes red
## with two saves for one press, while every other check here stays green.
##
## Like `test_back_button.gd`, nothing here enters a tree. It instantiates the
## scene and fires the real notifications at the real handler.


const SAVE := SimSave.PATH


func _game() -> Main:
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	# `_ready` has not fired off the tree, so without the explicit boot `sim` is
	# null and every read below is a non-fatal error that deletes the rest of the
	# check. Same reason as test_back_button.gd and test_controls.gd.
	main.freeze()
	return main


func test_pausing_saves_the_run(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var distance: float = main.sim.distance
	var before: int = main.saves_written

	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	t.eq(main.saves_written, before + 1,
		"NOTIFICATION_APPLICATION_PAUSED did not save the run, so a player who presses home loses everything since the last save")

	# The counter is the game's own word for it. This is the player's: a real
	# file, read back through the real loader, carrying the run that was live.
	var restored := Sim.new()
	t.ok(SimSave.read_file(restored, SAVE),
		"no save could be read from %s after the game was paused" % SAVE)
	t.approx(restored.distance, distance, 0.001,
		"the save written when the game was paused does not hold the run that was on screen")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


func test_losing_focus_saves_the_run(t: TestHarness) -> void:
	# Both halves, separately. Android sends FOCUS_OUT on its own in cases PAUSED
	# does not cover (the notification shade, a permission dialog), so a handler
	# wired to only one of the two is a handler that misses real departures.
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var before: int = main.saves_written

	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	t.eq(main.saves_written, before + 1,
		"NOTIFICATION_APPLICATION_FOCUS_OUT did not save the run")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## THE REFUSAL, AND THE REASON THIS FILE EXISTS.
##
## `DEVICE.md`: one home press on his phone delivers BOTH notifications. The two
## checks above each pass on a handler that saves on every notification it is
## given, and that handler writes the run twice for every single departure.
func test_one_departure_writes_one_save(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var before: int = main.saves_written

	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	t.eq(main.saves_written, before + 1,
		"the two notifications Android sends for ONE home press wrote %d saves instead of one - the departure handler has no latch"
			% (main.saves_written - before))

	# And the order the phone happens to deliver them in is not part of the
	# contract, so the other way round must also be one save.
	var other := _game()
	other.advance(2.0)
	var before_other: int = other.saves_written
	other.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	other.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	t.eq(other.saves_written, before_other + 1,
		"one departure delivered focus-out first wrote %d saves instead of one"
			% (other.saves_written - before_other))

	main.free()
	other.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## THE POSITIVE CONTROL FOR THE LATCH. Without this, a `_leave()` that saves once
## and never again passes every check above while quietly losing the player's run
## every time after the first - which is strictly worse than the double save the
## latch was added to stop.
func test_coming_back_and_leaving_again_saves_again(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var before: int = main.saves_written

	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	t.eq(main.saves_written, before + 1, "the first departure did not write exactly one save")

	main.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	main.advance(2.0)
	main.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	t.eq(main.saves_written, before + 2,
		"the game was resumed and then left again and no second save was written, so the latch saves once per RUN instead of once per departure")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)


## The departure handler must not be a handler that fires on anything, which is
## the failure `test_back_button.gd` guards on its own side.
func test_an_unrelated_notification_does_not_save(t: TestHarness) -> void:
	var had_save := FileAccess.file_exists(SAVE)
	var main := _game()
	main.advance(2.0)
	var before: int = main.saves_written

	main.notification(Node.NOTIFICATION_WM_MOUSE_ENTER)
	t.eq(main.saves_written, before,
		"an unrelated notification wrote a save, so the checks above may be reading a handler that fires on everything")

	main.free()
	if not had_save:
		DirAccess.remove_absolute(SAVE)
