class_name SimRng
extends RefCounted

## A deterministic replacement for randf(), for anything that touches game
## state.
##
## `SimUtil.hash2` is for decisions keyed on a place - which chunk, which level
## - and gives the same answer however many times it is asked. This is for the
## other case: a stream of values where nothing meaningful indexes them, like
## the scatter velocity of a burst of pickups.
##
## Those look purely decorative and are not. A pickup's velocity decides when
## it comes within magnet reach, which decides when its score lands. On the web
## game, leaving that on Math.random made the whole-run golden test fail about
## one run in ten - passing alone, failing under load - which is the worst
## possible behaviour for the test every other change is checked against.
##
## The rule that came out of it: **anything that decides *when* something
## happens is simulation, however decorative it looks.** Cosmetic jitter with
## no bearing on outcome can stay on randf().
##
## Reseed per run so a run replays exactly.

var _n: int = 0
var _seed: int = 0


func _init(seed_value: int = 0) -> void:
	_seed = seed_value


func next() -> float:
	var v := SimUtil.hash2(_n, _seed)
	_n += 1
	return v


## Uniform in [lo, hi).
func range_f(lo: float, hi: float) -> float:
	return lo + next() * (hi - lo)


## How many values have been drawn. Two runs that diverge here have diverged
## in the simulation, which is a faster thing to notice than a wrong score.
func draws() -> int:
	return _n


## The stream as a plain dictionary, and back. The other half of INDEX.md rule
## 2's pure pair - see `src/sim/save.gd`, which holds the one for `Sim`.
##
## **The position is saved, not just the seed.** A save that keeps `_seed` and
## drops `_n` restores a stream that replays from the beginning, so the run
## resumes with values it has already used - the same level, played out
## differently, with nothing in the save file that looks wrong. Stillwater
## shipped that, and it reads to a player as "my game changed while it was
## closed". `test/test_save.gd` asserts the restored stream continues rather
## than restarts, with a positive control that fails when only the seed is kept.
func to_dict() -> Dictionary:
	return {"n": _n, "seed": _seed}


## Total or false, like the pair in save.gd, and for the same reason: a stream
## restored to the right seed at the wrong position is worse than no save.
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
## The same check lives in save.gd; five lines of it are cheaper than making
## this file depend on that one.
func _is_whole(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and f == floorf(f)
