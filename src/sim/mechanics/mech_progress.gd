class_name MechProgress
extends RefCounted

## Levels, drip-fed unlocks, and a collection that does not decay.
##
## This module exists because of two entries in this studio's `PLAYER.md` under
## the heading "what he has asked for more than once and never been given". Both
## are quoted at the mechanism that implements them, because a rule with its
## evidence attached survives a rewrite and a rule without it does not.
##
## ## 1. Unlocks are found, then upgraded. Not a shop shown up front
##
##   "I want most of the upgrades to be hidden for now and unlock later in the
##    game ... so you only unlock certain upgrades by finding them initially,
##    the game hints at what it does and you now own it, then you can upgrade it
##    at the shop."
##
## So an entry moves through three states and the shop only ever shows the last
## one. A full shop on day one spoils its own contents: the player reads forty
## rows, understands the whole game before playing it, and every later discovery
## is a price change rather than a surprise.
##
## ## 2. The collection is the reason to come back
##
##   "think about a larger point to the game, or secondary objective."
##
## A score decays to nothing the moment a better one replaces it. A collection
## does not. `discover` is one-way, on purpose, and there is no method anywhere
## in this file that takes an entry back out.

signal levelled(level: int)
signal discovered(id: String)
signal unlocked(id: String)

## Hidden entirely. The player does not know it exists.
const STATE_HIDDEN := 0
## Found. It is theirs, the game has hinted what it does, and it shows in the
## collection. It is NOT yet upgradeable.
const STATE_FOUND := 1
## Unlocked for upgrading. This is the only state the shop lists.
const STATE_UNLOCKED := 2


class Entry extends RefCounted:
	var id: String
	var state: int = STATE_HIDDEN
	var level: int = 0
	var max_level: int = 1
	## Shown next to the entry the moment it is found, before it can be bought.
	## The hint IS the mechanic: an entry found with no hint is a locked row,
	## which is the thing this design replaces.
	var hint: String = ""

	func _init(entry_id: String, maximum: int = 1, found_hint: String = "") -> void:
		id = entry_id
		max_level = maxi(maximum, 1)
		hint = found_hint

	func to_dict() -> Dictionary:
		return {"id": id, "state": state, "level": level}


var level: int = 1
var xp: float = 0.0
## Curve parameters, fed to `MechIdle.xp_for_level`.
var xp_base: float = 8.0
var xp_power: float = 2.0

var entries: Array[Entry] = []
var _by_id: Dictionary = {}


func add(entry: Entry) -> Entry:
	entries.append(entry)
	_by_id[entry.id] = entry
	return entry


func add_simple(id: String, max_level: int = 1, hint: String = "") -> Entry:
	return add(Entry.new(id, max_level, hint))


func get_entry(id: String) -> Entry:
	return _by_id.get(id, null)


# --- levels ---------------------------------------------------------------

## Add experience, levelling as many times as it earns.
##
## A loop rather than a single check: a large reward at a low level can cross
## several thresholds at once, and a version that levels once per call silently
## swallows the rest. Returns how many levels were gained, so the presentation
## layer can stack the celebrations rather than playing one and losing three.
func add_xp(amount: float) -> int:
	if amount <= 0.0:
		return 0
	xp += amount
	var gained := 0
	while xp >= xp_to_next():
		xp -= xp_to_next()
		level += 1
		gained += 1
		levelled.emit(level)
	return gained


func xp_to_next() -> float:
	return MechIdle.xp_for_level(level, xp_base, xp_power)


## How far through the current level, 0..1. What a bar draws.
func level_fraction() -> float:
	var needed := xp_to_next()
	return 0.0 if needed <= 0.0 else Mech.clamp01(xp / needed)


# --- the unlock ladder ----------------------------------------------------

## Find something. Hidden becomes found: the player now owns it and can see it
## in the collection, with its hint, but cannot yet upgrade it.
##
## **One way.** There is no `undiscover`, and that is the point of the whole
## module. Returns false if it was already found, so a pickup cannot be
## collected twice.
func discover(id: String) -> bool:
	var e: Entry = _by_id.get(id, null)
	if e == null or e.state != STATE_HIDDEN:
		return false
	e.state = STATE_FOUND
	if e.level < 1:
		e.level = 1  # finding it means owning it, at level one
	discovered.emit(id)
	return true


## Promote a found entry to upgradeable, so the shop will list it.
##
## Separate from `discover` on purpose. The gap between the two is where the
## design lives: the player has the thing, has been told roughly what it does,
## and has a reason to go looking for the shop.
func unlock(id: String) -> bool:
	var e: Entry = _by_id.get(id, null)
	if e == null or e.state != STATE_FOUND:
		return false
	e.state = STATE_UNLOCKED
	unlocked.emit(id)
	return true


## Find and unlock in one step, for a game that does not want the middle state.
func discover_and_unlock(id: String) -> bool:
	return discover(id) and unlock(id)


func state_of(id: String) -> int:
	var e: Entry = _by_id.get(id, null)
	return STATE_HIDDEN if e == null else e.state


func level_of(id: String) -> int:
	var e: Entry = _by_id.get(id, null)
	return 0 if e == null else e.level


func is_found(id: String) -> bool:
	return state_of(id) >= STATE_FOUND


## Raise an entry's level. Refuses anything not yet unlocked, which is what
## stops a shop screen from selling something the player has not found.
func upgrade(id: String) -> bool:
	var e: Entry = _by_id.get(id, null)
	if e == null or e.state != STATE_UNLOCKED or e.level >= e.max_level:
		return false
	e.level += 1
	return true


## What a shop screen should list, and nothing else.
func shop_rows() -> Array[Entry]:
	var out: Array[Entry] = []
	for e in entries:
		if e.state == STATE_UNLOCKED:
			out.append(e)
	return out


## What a collection screen should list: everything found, in the order it was
## defined, so the gaps are visible. **The gaps are the content.** A collection
## that only shows what you have is a list; one that shows the shape of what is
## missing is a reason to go back out.
func collection_rows() -> Array[Entry]:
	var out: Array[Entry] = []
	for e in entries:
		if e.state >= STATE_FOUND:
			out.append(e)
	return out


func found_count() -> int:
	return collection_rows().size()


## How complete the collection is, 0..1.
func collection_fraction() -> float:
	if entries.is_empty():
		return 0.0
	return float(found_count()) / float(entries.size())


func state() -> Dictionary:
	return {
		"level": level,
		"xp": snappedf(xp, 0.01),
		"to_next": snappedf(xp_to_next(), 0.01),
		"found": found_count(),
		"total": entries.size(),
		"collection": snappedf(collection_fraction(), 0.001),
		"shop_rows": shop_rows().size(),
	}


func to_dict() -> Dictionary:
	var rows: Array = []
	for e in entries:
		rows.append(e.to_dict())
	return {"level": level, "xp": xp, "entries": rows}


## As with the draft pool, the entries themselves are content and belong to the
## game's data. A save restores their STATE onto a list the game already built,
## and can never invent one.
func apply(data: Dictionary) -> bool:
	if not data.has("level") or not data.has("xp") or not data.has("entries"):
		return false
	if typeof(data["entries"]) != TYPE_ARRAY:
		return false
	var new_level := int(data["level"])
	var new_xp := float(data["xp"])
	if new_level < 1 or not is_finite(new_xp) or new_xp < 0.0:
		return false
	for row in data["entries"]:
		if typeof(row) != TYPE_DICTIONARY or not row.has("id"):
			return false
	level = new_level
	xp = new_xp
	for row in data["entries"]:
		var e: Entry = _by_id.get(String(row["id"]), null)
		if e == null:
			continue
		e.state = clampi(int(row.get("state", STATE_HIDDEN)), STATE_HIDDEN, STATE_UNLOCKED)
		e.level = clampi(int(row.get("level", 0)), 0, e.max_level)
	return true
