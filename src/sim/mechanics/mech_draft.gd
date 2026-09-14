class_name MechDraft
extends RefCounted

## Pick one of three.
##
## The best value-for-effort decision in games: one choice, no menu, high
## stakes, over in two seconds. It is the level-up card in every horde survivor,
## the boon at the end of a room, the upgrade after a wave, and the reason a run
## you have played forty times is a different run.
##
## The rules that make it work are all refusals, and every one of them is a bug
## the first time somebody writes this by hand:
##
## - **Never offer the same thing twice in one draft.** Obvious, and the naive
##   "roll three times" does it constantly.
## - **Never offer something that cannot be taken.** A maxed weapon, a locked
##   option, one whose prerequisite is unmet. An offer the player cannot act on
##   spends one of their three slots on nothing.
## - **Never silently offer fewer than asked without saying so.** Late in a run
##   the pool empties, and a draft screen built to show three cards and handed
##   two either crashes or shows a blank. `offer` returns what it could find and
##   the caller is expected to look.
##
## Deterministic: every roll comes from a `MechRng` the caller owns, so a run
## replays exactly and a filmed run can be compared against another one.

## One option in the pool.
##
## `weight` is relative, not a probability, so options can be added and removed
## without renormalising anything. `max_level` of 1 is a one-shot unlock; higher
## makes it a stackable upgrade. `requires` is a list of ids that must be at
## least level 1 before this can be offered, which is the whole mechanism behind
## an evolution or a tier-two upgrade.
class Option extends RefCounted:
	var id: String
	var weight: float
	var max_level: int
	var level: int = 0
	var requires: PackedStringArray
	var banished: bool = false

	func _init(option_id: String, option_weight: float = 1.0, maximum: int = 1,
			prerequisites: PackedStringArray = PackedStringArray()) -> void:
		id = option_id
		weight = maxf(option_weight, 0.0)
		max_level = maxi(maximum, 1)
		requires = prerequisites

	func is_maxed() -> bool:
		return level >= max_level

	func to_dict() -> Dictionary:
		return {"id": id, "level": level, "banished": banished}


var options: Array[Option] = []

## Multiplier applied to anything already taken at least once.
##
## Above 1.0 the draft steers toward finishing what you started, which makes
## builds converge and is what an evolution system needs. Below 1.0 it steers
## toward breadth. 1.0 is neutral and is the honest default, because a player
## who cannot tell why an option keeps appearing experiences weighting as the
## game being rigged rather than as the game being helpful.
var owned_bias: float = 1.0

var _by_id: Dictionary = {}


## Add an option. Returns it, so a pool can be built in one expression chain.
func add(option: Option) -> Option:
	options.append(option)
	_by_id[option.id] = option
	return option


## Convenience for the common case.
func add_simple(id: String, weight: float = 1.0, max_level: int = 1) -> Option:
	return add(Option.new(id, weight, max_level))


func get_option(id: String) -> Option:
	return _by_id.get(id, null)


func level_of(id: String) -> int:
	var o: Option = _by_id.get(id, null)
	return 0 if o == null else o.level


## Every option that could legally be offered right now.
func available() -> Array[Option]:
	var out: Array[Option] = []
	for o in options:
		if _is_available(o):
			out.append(o)
	return out


## Offer up to `count` distinct options.
##
## Returns fewer than `count` only when the pool genuinely cannot supply that
## many, and an empty array when nothing at all is available. **Check the size.**
## A draft screen that assumes three and is handed one is the most common way
## this mechanic ships broken, and it only happens deep in a run.
func offer(count: int, rng: MechRng) -> Array[Option]:
	var pool := available()
	var picked: Array[Option] = []
	var wanted := mini(count, pool.size())

	while picked.size() < wanted:
		var weights := PackedFloat32Array()
		for o in pool:
			weights.append(_effective_weight(o))
		var index := rng.weighted(weights)
		if index < 0:
			# Every remaining option has zero weight. Fall back to taking them in
			# order rather than returning short: a zero-weight option is still a
			# legal one, and a blank card is worse than an unlikely card.
			picked.append(pool[0])
			pool.remove_at(0)
			continue
		picked.append(pool[index])
		pool.remove_at(index)

	return picked


## Take an option, raising its level. Returns false if it was not takeable, so a
## double tap on a card cannot level something twice.
func take(id: String) -> bool:
	var o: Option = _by_id.get(id, null)
	if o == null or o.is_maxed() or o.banished:
		return false
	o.level += 1
	return true


## Remove an option from this run without taking it. The "banish" button.
func banish(id: String) -> bool:
	var o: Option = _by_id.get(id, null)
	if o == null or o.banished:
		return false
	o.banished = true
	return true


## Everything back to level zero, nothing banished. A new run.
func reset() -> void:
	for o in options:
		o.level = 0
		o.banished = false


## How much of the pool has been exhausted, 0..1. A useful readout for deciding
## when a run should end: a draft with nothing left to offer is a run that has
## stopped being a game.
func exhaustion() -> float:
	if options.is_empty():
		return 1.0
	var taken := 0
	for o in options:
		if o.is_maxed() or o.banished:
			taken += 1
	return float(taken) / float(options.size())


func state() -> Dictionary:
	return {
		"options": options.size(),
		"available": available().size(),
		"exhaustion": snappedf(exhaustion(), 0.001),
	}


func to_dict() -> Dictionary:
	var rows: Array = []
	for o in options:
		rows.append(o.to_dict())
	return {"options": rows}


## Restores levels and banishments onto a pool that has already been built.
##
## Deliberately does NOT create options from the save. The pool is content and
## belongs to the game's data, not to the save file: a save that can invent
## options will happily restore one that a later version removed, and the game
## then holds an upgrade that nothing implements.
func apply(data: Dictionary) -> bool:
	if not data.has("options") or typeof(data["options"]) != TYPE_ARRAY:
		return false
	for row in data["options"]:
		if typeof(row) != TYPE_DICTIONARY or not row.has("id"):
			return false
	for row in data["options"]:
		var o: Option = _by_id.get(String(row["id"]), null)
		if o == null:
			continue  # an option this build no longer has. Skipped, not fatal.
		o.level = clampi(int(row.get("level", 0)), 0, o.max_level)
		o.banished = bool(row.get("banished", false))
	return true


# --- internals ------------------------------------------------------------

func _is_available(o: Option) -> bool:
	if o.banished or o.is_maxed():
		return false
	for required in o.requires:
		var dependency: Option = _by_id.get(required, null)
		if dependency == null or dependency.level <= 0:
			return false
	return true


func _effective_weight(o: Option) -> float:
	return o.weight * (owned_bias if o.level > 0 else 1.0)
