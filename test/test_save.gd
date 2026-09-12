extends RefCounted

## The save pair, round-tripped with no file anywhere in it.
##
## INDEX.md standing rule 2 settles that `src/sim` may touch `user://`, and that
## what it may NOT do is make the disk the only way to test a save: serialisation
## is a pure `state -> Dictionary -> state` pair, and the file call is a thin
## wrapper over it. This suite is the half of that rule the template could not
## enforce until `src/sim/save.gd` existed - `Sim.state()` is a lossy HUD
## snapshot with no inverse, and a round trip asserted against it would have
## failed for reasons that have nothing to do with saving.
##
## **Not one `FileAccess` below, and that is the point.** Everything that can be
## wrong about a save - a dropped field, a stale stream position, a half-applied
## load - is decided by arithmetic over a Dictionary, so it is all assertable in
## a headless millisecond. `SimSave.write_file` is twelve lines over this pair
## and is never called from a test or from the game.
##
## Four different things are asserted, because they fail in four different ways:
##
## 1. A played run survives the trip and then **advances identically**, which is
##    what catches a field that restores to something plausible but wrong.
## 2. A synthetic state in which **no field holds its default** proves the trip
##    is total - against a fresh `Sim`, a pair that silently dropped `score`
##    would round-trip 0 to 0 and look perfect.
## 3. Every missing or malformed key is **refused**, and a refusal leaves the sim
##    untouched. A partial restore that returns true is the failure mode the
##    whole rule exists to prevent.
## 4. The field list in `save.gd` is compared against `Sim`'s own properties, so
##    the next `var` added to the simulation cannot quietly stop being saved.

const STEP := 1.0 / 60.0


# --- the round trip -------------------------------------------------------

func test_a_played_run_survives_the_trip_and_carries_on_the_same(t: TestHarness) -> void:
	var played := Sim.new()
	_drive(played, 600)
	# A deterministic tail, so `x` and `target_x` are provably away from their
	# defaults whatever the policy was doing when the loop ended. Half a second
	# of smoothing toward 1.3 lands above 1.25 from anywhere in the lane.
	played.steer_to(1.3)
	for i in 30:
		played.advance(STEP)

	t.ok(not played.over, "the run ended during setup - the rest of this test would be asserting a dead sim")
	t.gt(played.distance, 50.0, "ten seconds covered no ground")
	t.gt(played.time, 5.0, "time did not accumulate")
	t.gt(float(played.obstacles.size()), 0.0, "no obstacle is live - the entity half of the trip is untested")
	t.gt(float(played.pickups.size()), 0.0, "no pickup is live - the entity half of the trip is untested")
	t.gt(float(played._chunk_spawned), 5.0, "the spawn cursor never moved")
	t.approx(played.target_x, 1.3, 0.0001, "the tail did not steer")
	t.gt(played.x, 0.1, "the tail did not move the player off centre")

	var data := SimSave.to_dict(played)
	var restored := Sim.new()
	t.ok(SimSave.apply(restored, data), "apply refused a dictionary to_dict had just produced")
	_same_sim(t, restored, played, "restored")

	# The half a lost RNG position or a stale spawn cursor would survive: two
	# sims that LOOK equal must also BEHAVE equal. Both are driven by the same
	# policy through the same seam a thumb uses, so any difference in what they
	# hold shows up as a difference in where they end.
	var at_save := played.distance
	_drive(played, 600)
	_drive(restored, 600)
	_same_sim(t, restored, played, "after 600 more steps")
	t.gt(restored.distance, at_save, "neither sim advanced after the restore")


## A fresh `Sim` shares a default with almost every field, so a trip tested only
## against one cannot tell a restored field from a dropped one. Nothing in this
## state is what a fresh sim holds.
func test_every_field_survives_a_state_that_shares_no_default(t: TestHarness) -> void:
	var made := _synthetic()
	var fresh := Sim.new()
	for name in _all_fields():
		t.ok(str(made.get(name)) != str(fresh.get(name)),
			"the synthetic state's `%s` is already what a fresh Sim holds - a pair that dropped it would still pass" % name)

	var restored := Sim.new()
	t.ok(SimSave.apply(restored, SimSave.to_dict(made)), "apply refused a dictionary to_dict had just produced")
	_same_sim(t, restored, made, "synthetic")


# --- refusals -------------------------------------------------------------

## Every key, one at a time. A save missing one field is not a save with a
## sensible default in it; it is a save this build cannot restore, and the only
## honest answer is false.
func test_a_missing_key_is_refused_rather_than_defaulted(t: TestHarness) -> void:
	var full := SimSave.to_dict(_synthetic())
	var victim := Sim.new()
	for key in full.keys():
		var data: Dictionary = full.duplicate(true)
		data.erase(key)
		t.ok(not SimSave.apply(victim, data),
			"a save with no `%s` was accepted - that is a partial restore reported as a success" % key)
	_same_sim(t, victim, Sim.new(), "a refused save must leave the sim untouched")


func test_a_malformed_value_is_refused(t: TestHarness) -> void:
	var base := SimSave.to_dict(_synthetic())
	var victim := Sim.new()
	t.ok(not SimSave.apply(victim, _with(base, "level", "4")), "a string where an int belongs")
	t.ok(not SimSave.apply(victim, _with(base, "level", 1.5)), "a level with a fraction in it")
	t.ok(not SimSave.apply(victim, _with(base, "distance", "far")), "a string where a float belongs")
	t.ok(not SimSave.apply(victim, _with(base, "over", 1)), "an int where a bool belongs")
	t.ok(not SimSave.apply(victim, _with(base, "version", SimSave.VERSION + 1)),
		"a save from a version this build has never seen")
	t.ok(not SimSave.apply(victim, _with(base, "bonus", 1)),
		"a key this build does not know - the build that wrote it owned state this one cannot restore")
	t.ok(not SimSave.apply(victim, _with(base, "obstacles", 3)), "entities that are not a list")
	t.ok(not SimSave.apply(victim, _with(base, "obstacles", [7])), "an entity that is not a dictionary")
	t.ok(not SimSave.apply(victim, _with(base, "pickups", [{"x": 0.0, "z": 1.0}])), "an entity with no taken flag")
	t.ok(not SimSave.apply(victim, _with(base, "pickups", [{"x": "a", "z": 1.0, "taken": false}])),
		"an entity whose x is a string")
	t.ok(not SimSave.apply(victim, _with(base, "pickups", [{"x": 0.0, "z": 1.0, "taken": false, "kind": "coin"}])),
		"an entity carrying a field the save cannot write back")
	_same_sim(t, victim, Sim.new(), "a refused save must leave the sim untouched")

	# The positive control. Without it every assertion above would also pass for
	# an `apply` that returns false for everything.
	t.ok(SimSave.apply(Sim.new(), base), "the unaltered base was refused - the refusals above prove nothing")


# --- the field lists, checked against the things they claim to cover ------

## The gate that survives the next person. A `var` added to `Sim` and not to
## `save.gd` is a field that silently stops being saved, and no round trip can
## notice a field it was never told about.
##
## Reflection is used HERE and deliberately not in `save.gd`: a save built by
## reflection would start writing the next transient somebody adds. A test built
## by reflection just notices that the two lists disagree.
func test_the_save_covers_every_field_the_sim_owns(t: TestHarness) -> void:
	var owned: Array[String] = []
	for p in Sim.new().get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			owned.append(str(p["name"]))
	owned.sort()

	var saved: Array[String] = []
	for k in SimSave.to_dict(Sim.new()).keys():
		if str(k) != "version":
			saved.append(str(k))
	saved.sort()

	t.gt(float(owned.size()), 8.0,
		"reflection found only %d script variables on Sim - this gate is reading the wrong list and guarding nothing" % owned.size())
	t.eq(", ".join(owned), ", ".join(saved),
		"src/sim/sim.gd and src/sim/save.gd disagree about what a Sim owns. Every field on the left must be in one of the lists in save.gd, or it is not in the save")


## The same gate one level down. A game that gives obstacles a `kind` gets a red
## suite rather than a save that quietly drops it.
func test_the_save_covers_every_field_an_entity_owns(t: TestHarness) -> void:
	var s := Sim.new()
	s.advance(2.0)
	t.gt(float(s.obstacles.size()), 0.0, "no obstacle spawned in two seconds - there is nothing to check the shape of")
	t.gt(float(s.pickups.size()), 0.0, "no pickup spawned in two seconds - there is nothing to check the shape of")

	var want: Array[String] = []
	for k in SimSave.ENTITY_KEYS:
		want.append(str(k))
	want.sort()
	t.eq(_keys(s.obstacles[0]), ", ".join(want), "an obstacle carries fields SimSave.ENTITY_KEYS does not name")
	t.eq(_keys(s.pickups[0]), ", ".join(want), "a pickup carries fields SimSave.ENTITY_KEYS does not name")


## The saved dictionary must be a copy, not a window onto the live rows.
##
## The sim goes on writing to its entity dictionaries - `taken` flips the moment
## the player reaches one - so a shallow copy would change the save between
## `to_dict` and the file being written, and the bug would only ever show up as
## "the state I loaded is not the state I saved".
func test_the_dictionary_does_not_alias_the_live_entities(t: TestHarness) -> void:
	var s := Sim.new()
	# Planted at four metres: closer than the first chunk that spawns anything
	# (chunk 2, at sixteen), so it is certainly the first thing hit and no
	# immunity window can be running when the player arrives.
	var planted: Array[Dictionary] = [{"x": 0.0, "z": 4.0, "taken": false}]
	s.obstacles = planted

	var data := SimSave.to_dict(s)
	for i in 60:
		s.advance(STEP)

	t.ok(bool(planted[0]["taken"]), "the planted obstacle was never hit - this test proves nothing")
	t.lt(float(s.lives), float(Tuning.START_LIVES), "the hit cost no life - this test proves nothing")
	var saved: Array = data["obstacles"]
	t.eq(saved.size(), 1, "the saved list changed size while the sim ran")
	t.eq(bool(saved[0]["taken"]), false,
		"the saved entity flipped when the sim hit it - to_dict handed out the live dictionary instead of a copy")


# --- the stream -----------------------------------------------------------

## `Sim` in this template owns no stream, because every decision here is keyed on
## (chunk, level). `SimRng` still carries the pair, and it is asserted here
## rather than in test_util because the thing being asserted is the SAVE: a run
## that resumes with its stream rewound to zero replays values it has already
## used, which is a different level from the one that was saved and looks like
## nothing at all in the file.
func test_the_rng_pair_restores_the_position_and_not_just_the_seed(t: TestHarness) -> void:
	var live := SimRng.new(21)
	for i in 37:
		live.next()

	var restored := SimRng.new(4)
	t.ok(restored.apply(live.to_dict()), "apply refused a dictionary to_dict had just produced")
	t.eq(restored.draws(), live.draws(), "the restored stream is at a different position")
	var same := true
	for i in 20:
		if live.next() != restored.next():
			same = false
	t.ok(same, "the restored stream diverged from the one it was saved from")

	# The positive control for the assertion above: if position 0 of this seed
	# gave the same values as position 57, keeping the position would be
	# indistinguishable from dropping it.
	var pos := restored.draws()
	t.ok(SimRng.new(21).next() != restored.next(),
		"position 0 and position %d of seed 21 give the same value - this test cannot tell a kept position from a lost one" % pos)

	var refused := SimRng.new(9)
	t.ok(not refused.apply({"seed": 21}), "a save with no position was accepted - the run would resume rewound")
	t.ok(not refused.apply({"n": "three", "seed": 21}), "a position that is not a number was accepted")
	t.ok(not refused.apply({"n": -1, "seed": 21}), "a negative position was accepted")
	t.eq(refused.draws(), 0, "a refused save moved the stream anyway")


# --- helpers --------------------------------------------------------------

## Every field the save claims to carry, in one list, taken from `save.gd` so
## this file cannot go stale on its own.
func _all_fields() -> Array:
	return SimSave.INT_FIELDS + SimSave.FLOAT_FIELDS + SimSave.BOOL_FIELDS + SimSave.ENTITY_FIELDS


## Equal in EVERY field, not in the nine that `Sim.state()` shows a HUD.
## Entities are compared as one formatted string per list, so a mismatch prints
## both lists side by side instead of failing once per obstacle.
func _same_sim(t: TestHarness, actual: Sim, expected: Sim, label: String) -> void:
	t.eq(actual.level, expected.level, "%s: level" % label)
	t.eq(actual.lives, expected.lives, "%s: lives" % label)
	t.eq(actual.score, expected.score, "%s: score" % label)
	t.eq(actual.distance, expected.distance, "%s: distance" % label)
	t.eq(actual.x, expected.x, "%s: x" % label)
	t.eq(actual.target_x, expected.target_x, "%s: target_x" % label)
	t.eq(actual.over, expected.over, "%s: over" % label)
	t.eq(actual.won, expected.won, "%s: won" % label)
	t.eq(actual.time, expected.time, "%s: time" % label)
	t.eq(actual.hit_timer, expected.hit_timer, "%s: hit_timer" % label)
	t.eq(actual._chunk_spawned, expected._chunk_spawned, "%s: _chunk_spawned (the spawn cursor - a run that loses it respawns a chunk it has already passed)" % label)
	t.eq(_entities(actual.obstacles), _entities(expected.obstacles), "%s: obstacles" % label)
	t.eq(_entities(actual.pickups), _entities(expected.pickups), "%s: pickups" % label)


func _entities(rows: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for r in rows:
		parts.append("{x=%.9f z=%.9f taken=%s}" % [float(r["x"]), float(r["z"]), str(bool(r["taken"]))])
	return "[%s]" % ", ".join(parts)


func _keys(row: Dictionary) -> String:
	var out: Array[String] = []
	for k in row.keys():
		out.append(str(k))
	out.sort()
	return ", ".join(out)


func _with(base: Dictionary, key: String, value: Variant) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	out[key] = value
	return out


## A state in which no field holds a fresh sim's value.
func _synthetic() -> Sim:
	var s := Sim.new()
	s.level = 4
	s.lives = 2
	s.score = 137
	s.distance = 123.5
	s.x = -1.25
	s.target_x = 2.0
	s.over = true
	s.won = true
	s.time = 9.75
	s.hit_timer = 0.35
	s._chunk_spawned = 17
	var obs: Array[Dictionary] = [
		{"x": -2.0, "z": 40.0, "taken": true},
		{"x": 1.5, "z": 48.0, "taken": false},
	]
	var pks: Array[Dictionary] = [{"x": 0.25, "z": 44.0, "taken": false}]
	s.obstacles = obs
	s.pickups = pks
	return s


## Driven through `Policies`, which is the same seam the golden and a thumb use.
## A helper that computed its own steering would be a second, worse player.
func _drive(s: Sim, frames: int) -> void:
	var mem := {}
	for i in frames:
		if s.over:
			return
		Policies.steer(Policies.DODGER, s, mem)
		s.advance(STEP)
