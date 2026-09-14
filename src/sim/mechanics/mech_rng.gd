class_name MechRng
extends RefCounted

## A deterministic replacement for `randf()`, for anything that touches game
## state.
##
## `Mech.hash2` is for decisions keyed on a place - which chunk, which slot -
## and gives the same answer however many times it is asked. This is for the
## other case: a stream of values where nothing meaningful indexes them. A
## card shuffle, the scatter velocity of a burst of coins, which of three
## upgrades is offered.
##
## Those look decorative and are not. A coin's scatter velocity decides when it
## comes within magnet range, which decides when its score lands. Leaving that
## on `Math.random` made a sibling web game's whole-run golden test fail about
## one run in ten - passing alone, failing under load, which is the worst
## possible behavior for the test every other change is checked against.
##
## **The rule that came out of it: anything that decides *when* something
## happens is simulation, however decorative it looks.** Cosmetic jitter with no
## bearing on outcome can stay on `randf()`.

var _n: int = 0
var _seed: int = 0


func _init(seed_value: int = 0) -> void:
	_seed = seed_value


## The next value in [0, 1).
func next() -> float:
	var v := Mech.hash2(_n, _seed)
	_n += 1
	return v


## Uniform in [lo, hi).
func range_f(lo: float, hi: float) -> float:
	return lo + next() * (hi - lo)


## Uniform integer in [lo, hi] - inclusive at both ends, which is what a die
## roll and a "pick a lane" both want, and is the spelling that stops the
## off-by-one that the exclusive version causes every time.
func range_i(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + int(next() * float(hi - lo + 1))


## True with probability `p`.
func chance(p: float) -> bool:
	return next() < p


## An index into a weight table. See `Mech.weighted_pick` for the -1 case.
func weighted(weights: PackedFloat32Array) -> int:
	return Mech.weighted_pick(weights, next())


## Fisher-Yates, in place, drawing from this stream.
##
## Godot's own `Array.shuffle()` uses the global RNG and is therefore invisible
## to a seed - a shuffled deck is the single most common way a "deterministic"
## run stops being one.
func shuffle(items: Array) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := range_i(0, i)
		var tmp: Variant = items[i]
		items[i] = items[j]
		items[j] = tmp


## Pick `count` distinct indices from `0..size-1`, without replacement.
##
## The draft primitive: three upgrades from a pool of forty, no duplicates.
## Returns fewer than `count` only when the pool is smaller than that.
func sample(size: int, count: int) -> PackedInt32Array:
	var pool: Array[int] = []
	for i in size:
		pool.append(i)
	shuffle(pool)
	var out := PackedInt32Array()
	for i in mini(count, size):
		out.append(pool[i])
	return out


## How many values have been drawn. Two runs that diverge here have diverged in
## the simulation, which is a much faster thing to notice than a wrong score
## three minutes later.
func draws() -> int:
	return _n


## The stream as a plain dictionary, and back.
##
## **The position is saved, not just the seed.** A save that keeps the seed and
## drops the position restores a stream that replays from the beginning, so the
## run resumes with values it has already used - the same level, played out
## differently, with nothing in the save file that looks wrong. A sibling game
## shipped exactly that, and it reads to a player as "my game changed while it
## was closed".
func to_dict() -> Dictionary:
	return {"n": _n, "seed": _seed}


## Total or false: a stream restored to the right seed at the wrong position is
## worse than no save at all, so a partial restore is refused outright.
func apply(data: Dictionary) -> bool:
	if data.size() != 2:
		return false
	if not _is_whole(data.get("n")) or not _is_whole(data.get("seed")):
		return false
	var n := int(data["n"])
	if n < 0:
		return false
	_n = n
	_seed = int(data["seed"])
	return true


## A whole number however it is spelled - JSON hands every int back as a float.
func _is_whole(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and f == floorf(f)
