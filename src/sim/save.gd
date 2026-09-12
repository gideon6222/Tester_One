class_name SimSave
extends RefCounted

## The save, as pure arithmetic over a Dictionary.
##
## INDEX.md standing rule 2: the simulation wall excludes the renderer, not the
## disk. `src/sim` MAY touch `user://`. What it may not do is make the disk the
## only way to test a save - so serialisation is a pure pair, `Sim` to
## `Dictionary` and back, asserted by `test/test_save.gd` with no file open
## anywhere in it. `write_file` and `read_file` at the bottom are a dozen lines
## of wrapper over that pair, and nothing in the game calls them yet: the rule's
## gate is the pair, and a template that wires a real save into a placeholder
## game is a template every game then has to unpick.
##
## **`apply` restores every field or it returns false.** That is the whole
## difference between this file and a save that "works": a partial restore
## succeeds silently, and the player finds out three sessions later that their
## run resumes one obstacle to the left. A missing key, a key of the wrong type,
## a version this build does not know and a key this build does not recognise
## are all refusals, and a refusal leaves the `Sim` exactly as it was - the
## validation runs to completion BEFORE the first assignment, so a save that is
## rejected half way through cannot leave a half-loaded game standing.
##
## Stillwater's `src/sim/save.gd` is the shape this follows, and it deliberately
## differs in that one respect: it is lenient, because it loads a four-hour
## logbook written by a build that no longer exists, and there "carry on" beats
## "lose everything". This one holds a single run, is the template every new game
## starts from, and has a round-trip test whose job is to fail - leniency here
## would make that test unable to tell a dropped field from a defaulted one.
## A caller that gets `false` starts a fresh run; it must not crash.
##
## **The RNG.** `Sim` in this template owns no `SimRng` - every decision here is
## keyed on (chunk, level) through `SimUtil.hash2`, so there is no stream
## position to lose. A game built from this template usually does own one, and
## `SimRng` has its own `to_dict`/`apply` pair for exactly that reason. **Add it
## here the moment you add the rng to `Sim`**: a save that keeps the seed but
## loses the position resumes a different game from the one that was saved,
## which is a bug this studio has already shipped once in stillwater. The field
## list below is checked against `Sim`'s own properties by the test, so the
## reminder is a red suite rather than this paragraph.

## Bumped when the shape below changes. `apply` refuses anything else rather
## than guessing: a save written by a build with a different field list cannot
## be restored in full, and in full is the only way this pair restores anything.
const VERSION := 1

## Every field a `Sim` owns, by its own name, grouped by how it is checked.
##
## Named here rather than reflected off the object, for stillwater's reason:
## reflection would silently start saving the next `var` somebody adds -
## including a transient one - and silently stop when it is renamed. The names
## ARE the property names, so `test_save.gd` can compare this list against
## `Sim.get_property_list()` and go red when the two drift apart.
const INT_FIELDS := ["level", "lives", "score", "_chunk_spawned"]
const FLOAT_FIELDS := ["distance", "x", "target_x", "time", "hit_timer"]
const BOOL_FIELDS := ["over", "won"]
const ENTITY_FIELDS := ["obstacles", "pickups"]

## Where a game built from this template would keep its run. Used by the file
## wrapper at the bottom, which nothing calls yet.
const PATH := "user://save.json"

## The shape of one live entity. Checked against a real spawned one by the test,
## so a game that gives obstacles a fourth field cannot forget this file.
const ENTITY_KEYS := ["x", "z", "taken"]


static func to_dict(sim: Sim) -> Dictionary:
	var out := {"version": VERSION}
	for k in INT_FIELDS:
		out[k] = int(sim.get(k))
	for k in FLOAT_FIELDS:
		out[k] = float(sim.get(k))
	for k in BOOL_FIELDS:
		out[k] = bool(sim.get(k))
	out["obstacles"] = _entities_out(sim.obstacles)
	out["pickups"] = _entities_out(sim.pickups)
	return out


## Load into a sim. True only if every field was restored.
##
## The sim is not touched until the data has been checked all the way through,
## so `false` means "nothing happened" and never "some of it happened".
static func apply(sim: Sim, data: Dictionary) -> bool:
	if not _valid(data):
		return false
	for k in INT_FIELDS:
		sim.set(k, int(data[k]))
	for k in FLOAT_FIELDS:
		sim.set(k, float(data[k]))
	for k in BOOL_FIELDS:
		sim.set(k, bool(data[k]))
	sim.obstacles = _entities_in(data["obstacles"])
	sim.pickups = _entities_in(data["pickups"])
	return true


## A fresh sim carrying the saved run, or null if the data is not one.
static func from_dict(data: Dictionary) -> Sim:
	var sim := Sim.new()
	if not apply(sim, data):
		return null
	return sim


# --- checking -------------------------------------------------------------

## Every key present, every value the right kind, and NOTHING ELSE in the
## dictionary.
##
## The last one matters as much as the first: a save holding a key this build
## does not know was written by a build that owned more state than this one can
## restore, and loading the part we recognise is the partial restore this file
## exists to refuse.
static func _valid(data: Dictionary) -> bool:
	if not _is_int(data.get("version")) or int(data["version"]) != VERSION:
		return false
	if data.size() != 1 + INT_FIELDS.size() + FLOAT_FIELDS.size() + BOOL_FIELDS.size() + ENTITY_FIELDS.size():
		return false
	for k in INT_FIELDS:
		if not _is_int(data.get(k)):
			return false
	for k in FLOAT_FIELDS:
		if not _is_num(data.get(k)):
			return false
	for k in BOOL_FIELDS:
		if typeof(data.get(k)) != TYPE_BOOL:
			return false
	for k in ENTITY_FIELDS:
		if not _valid_entities(data.get(k)):
			return false
	return true


static func _valid_entities(v: Variant) -> bool:
	if typeof(v) != TYPE_ARRAY:
		return false
	var rows: Array = v
	for e in rows:
		if typeof(e) != TYPE_DICTIONARY:
			return false
		var row: Dictionary = e
		if row.size() != ENTITY_KEYS.size():
			return false
		if not _is_num(row.get("x")) or not _is_num(row.get("z")):
			return false
		if typeof(row.get("taken")) != TYPE_BOOL:
			return false
	return true


## A whole number, however it is spelled.
##
## Written through JSON an int comes back as a float - `17` leaves as `17` and
## returns as `17.0` - so refusing TYPE_FLOAT here would make every save this
## file writes unreadable by the wrapper at the bottom of this same file. A
## float with a fraction in it is still refused: that is a corrupted field, not
## a spelling.
static func _is_int(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and f == floorf(f)


static func _is_num(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	return typeof(v) == TYPE_FLOAT and is_finite(float(v))


# --- entities -------------------------------------------------------------

## Fresh dictionaries, field by field.
##
## Not `duplicate()`: the sim goes on writing to these rows - `taken` flips the
## moment the player reaches one - and a shallow copy would hand the save the
## same inner dictionaries, so the saved state would change under the writer
## between `to_dict` and the file being written. `test_save.gd` plants an
## obstacle, saves, runs the player into it and asserts the saved copy did not
## flip.
static func _entities_out(rows: Array[Dictionary]) -> Array:
	var out := []
	for r in rows:
		out.append({"x": float(r["x"]), "z": float(r["z"]), "taken": bool(r["taken"])})
	return out


## Typed on the way back in, because `Sim.obstacles` is `Array[Dictionary]` and
## an untyped array assigned to it is a runtime error, not a conversion.
static func _entities_in(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var rows: Array = v
	for e in rows:
		var row: Dictionary = e
		out.append({"x": float(row["x"]), "z": float(row["z"]), "taken": bool(row["taken"])})
	return out


# --- the disk, which is the thin part ------------------------------------

## The whole file layer, and it is deliberately this short. Everything that can
## be wrong about a save is decided by the pair above, which is why the suite
## can assert all of it without a filesystem. Nothing in `src/game/` calls
## either of these yet - wire them up in the game that needs them, and delete
## them in the same commit if it never does.
static func write_file(sim: Sim, path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(sim)))
	f.close()
	return true


## True only if a save was there AND it loaded in full. A false here means
## "start a new run", never "carry on with half a run".
static func read_file(sim: Sim, path: String = PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	return apply(sim, parsed)
