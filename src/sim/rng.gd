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
