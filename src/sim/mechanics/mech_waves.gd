class_name MechWaves
extends RefCounted

## The difficulty ladder: how many enemies, how tough, and when.
##
## Two shapes of game need this and they are not the same shape, so both are
## here and they are kept apart:
##
## - **A horde survivor runs on a clock.** Pressure is a continuous function of
##   elapsed time, spawning is a rate, and the run ends when the clock does.
##   That is the stateful half of this class.
## - **A tower defense runs on waves.** Pressure is a step function of wave
##   index, spawning is a discrete batch, and the player gets a breath between
##   them. That is the static half at the bottom.
##
## Every default below is a measured number from a shipped game, named at the
## constant. Where the research could not find one, the doc says so.

signal wave_started(index: int)
signal boss_due(index: int)

# --- the survivor clock ---------------------------------------------------

## Vampire Survivors' measured escalation, per minute of elapsed time.
##
## These are big numbers and they are meant to be. Enemy health DOUBLES every
## minute, which is what produces the genre's signature arc: helpless at two
## minutes, unstoppable at fifteen, overwhelmed again at twenty. A gentler curve
## gives a flat game that never has either feeling in it.
const HP_PER_MINUTE := 1.00        ## +100% of base per minute
const SPAWN_PER_MINUTE := 0.50     ## +50% of base spawn rate per minute
const DAMAGE_PER_MINUTE := 0.25    ## +25% of base per minute

## Vampire Survivors' own limits: it throttles spawning around 300 alive and
## hard-caps near 500.
##
## **A cap is not a nicety on a phone, it is the frame budget.** The throttle
## exists so the game degrades by spawning more slowly rather than by dropping
## to 15 fps, which is the difference between "this is getting intense" and
## "this is broken".
const ALIVE_THROTTLE := 300
const ALIVE_HARD_CAP := 500

## Seconds between waves and between bosses. A minute and five minutes are what
## the genre settled on: long enough that the change is felt as an event, short
## enough that a fifteen minute run has a shape.
const WAVE_SECONDS := 60.0
const BOSS_SECONDS := 300.0

var elapsed: float = 0.0
var wave: int = 0
var alive: int = 0

## Enemies per second at minute zero.
var base_spawn_rate: float = 1.5

var _spawn_credit: float = 0.0
var _next_boss: float = BOSS_SECONDS


## One step. Returns how many enemies to spawn THIS frame.
##
## A fractional rate accumulated into whole spawns, rather than a per-frame
## probability roll. Two reasons: the rate is exact rather than approximate, and
## it does not change with the frame rate, so a 120 Hz phone and a 60 Hz preview
## produce the same fight.
func advance(dt: float) -> int:
	var step := clampf(dt, 0.0, Mech.MAX_DT)
	if step <= 0.0:
		return 0
	var before := elapsed
	elapsed += step

	var index := int(elapsed / WAVE_SECONDS)
	if index > wave:
		wave = index
		wave_started.emit(wave)

	if before < _next_boss and elapsed >= _next_boss:
		boss_due.emit(int(_next_boss / BOSS_SECONDS))
		_next_boss += BOSS_SECONDS

	_spawn_credit += spawn_rate() * step
	var count := int(floor(_spawn_credit))
	_spawn_credit -= float(count)
	return _allowed(count)


## Enemies per second right now.
func spawn_rate() -> float:
	return base_spawn_rate * (1.0 + SPAWN_PER_MINUTE * minutes())


## What to multiply an enemy's base health by if it spawns right now.
func hp_multiplier() -> float:
	return 1.0 + HP_PER_MINUTE * minutes()


func damage_multiplier() -> float:
	return 1.0 + DAMAGE_PER_MINUTE * minutes()


func minutes() -> float:
	return elapsed / 60.0


## Report a spawn and a death, so the cap can be enforced.
func note_spawned(count: int = 1) -> void:
	alive = maxi(alive + count, 0)


func note_died(count: int = 1) -> void:
	alive = maxi(alive - count, 0)


## Whether spawning is being held back by the crowd on screen. Worth showing to
## yourself in a debug readout: a game sitting permanently at the throttle is
## one whose difficulty has stopped scaling, whatever the curves say.
func is_throttled() -> bool:
	return alive >= ALIVE_THROTTLE


func reset() -> void:
	elapsed = 0.0
	wave = 0
	alive = 0
	_spawn_credit = 0.0
	_next_boss = BOSS_SECONDS


func state() -> Dictionary:
	return {
		"elapsed": snappedf(elapsed, 0.01),
		"wave": wave,
		"alive": alive,
		"spawn_rate": snappedf(spawn_rate(), 0.001),
		"hp_mult": snappedf(hp_multiplier(), 0.001),
		"throttled": is_throttled(),
	}


func to_dict() -> Dictionary:
	return {"elapsed": elapsed, "wave": wave, "alive": alive, "next_boss": _next_boss}


func apply(data: Dictionary) -> bool:
	for key in ["elapsed", "wave", "alive", "next_boss"]:
		if not data.has(key):
			return false
	var e := float(data["elapsed"])
	if not is_finite(e) or e < 0.0:
		return false
	elapsed = e
	wave = maxi(int(data["wave"]), 0)
	alive = maxi(int(data["alive"]), 0)
	_next_boss = float(data["next_boss"])
	_spawn_credit = 0.0
	return true


## Above the throttle, spawning is slowed rather than stopped; above the hard
## cap it stops outright. Degrading in two stages is what keeps the throttle
## from being felt as the game suddenly going quiet.
func _allowed(count: int) -> int:
	if alive >= ALIVE_HARD_CAP:
		return 0
	var room := ALIVE_HARD_CAP - alive
	if alive >= ALIVE_THROTTLE:
		count = int(ceil(float(count) * 0.25))
	return clampi(count, 0, room)


# --- the tower defense ladder ---------------------------------------------

## Enemy health at a given wave.
##
##   hp = base * growth^(wave - 1)
##
## The sourced band is 8 to 12 percent per wave, so `growth` between 1.08 and
## 1.12. It compounds: at 10 percent, wave 20 is a little over six times wave 1,
## and wave 40 is forty-five times.
##
## **The sources disagree about method, not just numbers**, and it is worth
## knowing which argument you are taking. One approach scales health on a fixed
## curve like this; another derives what a wave must survive from the route
## length and the towers that can reach it, and sets health from that. The
## second is more work and does not go wrong when a map is unusual. This is the
## first, because it is what most games do and it is a starting point rather
## than a finished balance.
const TD_GROWTH_GENTLE := 1.08
const TD_GROWTH_STANDARD := 1.10
const TD_GROWTH_STEEP := 1.12

static func wave_hp(base_hp: float, wave_index: int, growth: float = TD_GROWTH_STANDARD) -> float:
	return base_hp * pow(growth, float(maxi(wave_index, 1) - 1))


## How many enemies in a wave. Grows more slowly than health on purpose: enemy
## COUNT costs frame time and health does not, so a curve that scales both
## equally hits the phone's budget long before it hits the difficulty you wanted.
static func wave_count(base_count: int, wave_index: int, growth: float = 1.05) -> int:
	return maxi(1, int(round(float(base_count) * pow(growth, float(maxi(wave_index, 1) - 1)))))


## The damage per second a player must have to clear a wave before it crosses
## the map.
##
##   required = total wave health / seconds the wave is in range
##
## The calculation that tells you whether a map is beatable at all, rather than
## finding out from a playtest. Compare it against the DPS the affordable
## towers can actually field at that wave: if required exceeds available, no
## amount of skill clears it.
static func required_dps(total_wave_hp: float, seconds_in_range: float) -> float:
	if seconds_in_range <= 0.0:
		return INF
	return total_wave_hp / seconds_in_range


## Gold for clearing a wave.
##
## Tied to the wave's health rather than set by hand, so the economy tracks the
## difficulty automatically and a designer cannot accidentally starve wave 30
## while over-feeding wave 12. `rate` is gold per point of health: tune the one
## number and the whole ladder moves together.
static func wave_reward(total_wave_hp: float, rate: float = 0.05) -> int:
	return maxi(1, int(round(total_wave_hp * maxf(rate, 0.0))))
