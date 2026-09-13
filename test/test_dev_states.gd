extends RefCounted

## THE JUMP-TO-A-SITUATION GATE.
##
## `Main.dev_states()`, `Main.dev_seek()` and `Main.dev_heartbeat()` are what let
## `scripts/shot.gd`, `scripts/replay_player.gd` and `scripts/movie.ps1` start a
## run IN the situation being troubleshot instead of driving to it. Measured on
## this template on 2026-09-13: filming five seconds of level 2 by playing to it
## cost 211 s and 99 MB, and `-State level2` cost 33 s and 15 MB.
##
## **The failure this file exists to catch is a seek that does nothing.** A
## `dev_seek` that returns true and leaves the game where it was passes every
## naive check, because a fresh boot already satisfies most of what you would
## assert about it - and what it produces is a plausible film of the wrong
## moment, which is the exact class of bug filming exists to catch. So every
## check below plants a synthetic state before it seeks (the trick
## `test_save.gd` uses on the save pair), and then asserts the field the state's
## own name promises. A no-op seek leaves the planted state standing and goes
## red. Verified by making `dev_seek` return true and do nothing: ten of the
## assertions below fail, across six of the checks.
##
## Read `_plant`'s own note before changing it. Which fields it holds at their
## fresh-boot values is the load-bearing part.
##
## Like `test_controls.gd` this instantiates the real scene and never adds it to
## a tree, so it runs in the pure suite in milliseconds. See that file's header
## for where that boundary is and why.


## A booted game, held in a TYPED local. Untyped, a renamed method below would be
## a non-fatal runtime error that deletes every assertion after it - green, with
## a smaller number nobody reads.
func _game() -> Main:
	var scene: PackedScene = load("res://src/game/main.tscn")
	var main := scene.instantiate() as Main
	main.freeze()
	return main


## The state every check below starts from, planted on a booted game. Built on
## `test_save.gd:_synthetic` and deliberately different from it in four fields,
## which is the interesting part.
##
## The seven fields that CAN differ from a fresh boot do, so a seek that does
## nothing leaves them standing and the generic check below goes red.
##
## `lives`, `hit_timer`, `over` and `won` are held at their fresh-boot values ON
## PURPOSE. They are what `hit` and `finish` promise to change, and the first
## draft of this file planted `lives = 2, hit_timer = 0.35, over = true` - which
## is to say it planted the answers. Both of those checks passed against a
## `dev_seek` that returned true and did nothing at all, measured. A test whose
## fixture already satisfies its assertion is not a weak test, it is no test.
func _plant(main: Main) -> void:
	var s := main.sim
	s.level = 4
	s.score = 137
	s.distance = 123.5
	s.x = -1.25
	s.target_x = 2.0
	s.time = 9.75
	s._chunk_spawned = 17
	s.lives = Tuning.START_LIVES
	s.hit_timer = 0.0
	s.over = false
	s.won = false


## A game sitting in the synthetic state, ready to be seeked out of it.
func _planted() -> Main:
	var main := _game()
	_plant(main)
	return main


func test_the_table_holds_the_states_the_tools_offer(t: TestHarness) -> void:
	var main := _game()
	var states: Dictionary = main.dev_states()
	# Three is the floor, not the target: below that the seam is a special case
	# rather than a table, and the nine-shot_files failure it replaces comes back.
	t.gt(states.size(), 2.0,
		"dev_states() publishes %d state(s). Below three this is a special case, not a table - and a state nobody can name is a script somebody has to find."
			% states.size())
	for k in states:
		t.ok(str(k) != "", "dev_states() holds an empty name - '' means 'no state' to shot.gd and cannot also be a state")
		t.ok(str(states[k]).length() > 8,
			"dev_states()['%s'] has no description worth printing, and that list is what a session reads after typing a name nobody knows" % str(k))
	main.free()


## Every published name seeks, and lands somewhere that is not where it started.
func test_every_published_state_seeks_and_changes_the_game(t: TestHarness) -> void:
	var names: Array = _game_states()
	for k in names:
		var main := _planted()
		var before: Dictionary = main.sim.state()
		t.ok(main.dev_seek(str(k)), "dev_seek('%s') refused a name its own dev_states() publishes" % str(k))
		# A seek that leaves the clock stopped films twenty seconds of a still
		# picture, which is what the first draft of this seam did: every arm
		# freezes to step deterministically and the last one forgot to let go.
		t.ok(not main.frozen,
			"dev_seek('%s') left the game frozen, so a film of this state would not move and a phone build would sit there" % str(k))
		t.ok(not _same(main.sim.state(), before),
			"dev_seek('%s') left the game exactly where it was. The planted state differs from a fresh boot in seven fields, so this is a seek that did nothing, and what it produces is a plausible film of the wrong moment."
				% str(k))
		main.free()


## And each one lands in the state its NAME promises, which is the half that a
## generic "something changed" assertion cannot see.
func test_start_is_a_fresh_boot(t: TestHarness) -> void:
	var main := _planted()
	t.ok(main.dev_seek("start"), "dev_seek('start') refused")
	t.dict_eq(main.sim.state(), Sim.new().state(),
		"dev_seek('start') did not leave the game as a player finds it on the first frame")
	main.free()


func test_hit_stops_inside_the_cooldown(t: TestHarness) -> void:
	var main := _planted()
	t.ok(main.dev_seek("hit"), "dev_seek('hit') refused - the arm plays until it takes one and gives up if it never does")
	t.lt(main.sim.lives, Tuning.START_LIVES,
		"dev_seek('hit') left every life intact, so nothing was hit and the picture is of an ordinary frame")
	t.gt(main.sim.hit_timer, 0.0,
		"dev_seek('hit') landed AFTER the cooldown ran out - the moment worth photographing is inside it")
	main.free()


func test_finish_is_the_end_of_a_level(t: TestHarness) -> void:
	var main := _planted()
	t.ok(main.dev_seek("finish"), "dev_seek('finish') refused - the level never ended")
	t.ok(main.sim.over, "dev_seek('finish') left the level still running")
	t.ok(main.sim.won, "dev_seek('finish') ended the level by dying rather than by completing it, which is a different screen")
	main.free()


func test_level2_is_a_later_level_already_under_way(t: TestHarness) -> void:
	var main := _planted()
	t.ok(main.dev_seek("level2"), "dev_seek('level2') refused")
	t.eq(main.sim.level, 2, "dev_seek('level2') is not on level 2")
	t.gt(main.sim.distance, 0.0,
		"dev_seek('level2') stopped on level 2's first frame, so nothing is on the track and the picture says nothing about a denser level")
	t.ok(not main.sim.over, "dev_seek('level2') arrived at a level that is already over")
	main.free()


## THE POSITIVE CONTROL, and it is the one that keeps the rest honest. A seam
## that says yes to everything cannot fail the checks above either.
func test_a_name_nobody_knows_is_refused_and_changes_nothing(t: TestHarness) -> void:
	var main := _planted()
	var before: Dictionary = main.sim.state()
	t.ok(not main.dev_seek("nosuchstate"),
		"dev_seek accepted a name its dev_states() has never published - a seam that says yes to everything says nothing")
	t.dict_eq(main.sim.state(), before,
		"a refused dev_seek moved the game anyway, which is the half-loaded state the refusal exists to prevent")
	main.free()


## A saved run is a state too, and a save that will not load is a refusal rather
## than half a game. This half needs no file at all.
func test_a_saved_run_that_is_not_there_is_refused_and_changes_nothing(t: TestHarness) -> void:
	var main := _planted()
	var before: Dictionary = main.sim.state()
	t.ok(not main.dev_seek("user://no-such-save-exists.json"),
		"dev_seek accepted a .json path with no file behind it")
	t.dict_eq(main.sim.state(), before,
		"a .json state that could not be read moved the game anyway")
	main.free()


## The other half, which does need one. `user://` rather than the repo, written
## and deleted here: the pair itself is asserted without a filesystem in
## test_save.gd, so all this adds is that `dev_seek` reaches it.
func test_a_saved_run_is_restored_exactly(t: TestHarness) -> void:
	var path := "user://test_dev_states.json"
	var saved := Sim.new()
	saved.level = 3
	saved.score = 4242
	saved.distance = 77.25
	t.ok(SimSave.write_file(saved, path), "could not write %s - the rest of this check would assert nothing" % path)

	var main := _planted()
	t.ok(main.dev_seek(path), "dev_seek refused a save it had just written")
	t.dict_eq(main.sim.state(), saved.state(), "dev_seek('<a save>') did not restore the run that was saved")
	main.free()
	DirAccess.remove_absolute(path)


# --- the heartbeat --------------------------------------------------------

func test_the_heartbeat_reports_numbers_and_they_move(t: TestHarness) -> void:
	var main := _game()
	var first: Dictionary = main.dev_heartbeat()
	t.gt(first.size(), 0.0,
		"dev_heartbeat() is empty, so a filmed run of this game can only be checked for liveness and a stuck run spends the whole budget before anyone notices")
	main.advance(1.0)
	var later: Dictionary = main.dev_heartbeat()
	t.ok(not _same(later, first),
		"dev_heartbeat() read the same numbers after a second of play, so movie.ps1 would call a healthy run frozen (or, worse, a frozen one healthy)")
	for k in first:
		t.ok(later.has(k), "dev_heartbeat() dropped the key `%s` between two reads - movie.ps1 compares these as text" % str(k))
	main.free()


## The line movie.ps1 parses is `key=value` pairs, so a value with a space in it
## would split into two fields and the comparison would read a different number
## from the one the game reported.
func test_the_heartbeat_is_printable_on_one_line(t: TestHarness) -> void:
	var main := _game()
	main.advance(1.0)
	var h: Dictionary = main.dev_heartbeat()
	t.gt(h.size(), 0.0, "dev_heartbeat() is empty, so the loop below would assert nothing")
	for k in h:
		t.ok(not str(k).contains(" ") and not str(k).contains("="),
			"dev_heartbeat() key `%s` cannot be written as key=value on one line" % str(k))
		t.ok(not str(h[k]).contains(" "),
			"dev_heartbeat()['%s'] is `%s`, which has a space in it - movie.ps1 splits that line on spaces" % [str(k), str(h[k])])
	main.free()


# --- helpers --------------------------------------------------------------

func _game_states() -> Array:
	var main := _game()
	var out: Array = main.dev_states().keys()
	main.free()
	return out


## Field by field, because `==` on two Dictionaries is a question about identity
## as often as about contents depending on the engine version, and an assertion
## that a seek CHANGED something must not be able to pass by comparing two
## different objects holding the same numbers.
func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or str(b[k]) != str(a[k]):
			return false
	return true
