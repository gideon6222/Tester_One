class_name MechMeter
extends RefCounted

## A resource that runs out, and kills the run when it does.
##
## Fuel, air, heat, battery, daylight, hull. This is the spine that puts
## something at stake, and it is in this library first because "nothing is at
## stake" is the single most repeated complaint in this studio's playtest logs,
## in the player's own words, across four different games:
##
##   "it feels free."
##   "I can afford upgrades pretty early on for fuel and cooling so neither is
##    a risk."
##   "there isn't really a risk or reward yet."
##   "I dont want towing to be a thing. if you run out of gas, you should game
##    over."
##
## So the module is opinionated in three ways, and each one is a decision rather
## than a default:
##
## 1. **Empty is terminal.** There is no rescue, no tow, no half-failure. A
##    meter that empties sets `empty` and stays there until something explicitly
##    restarts the run. Softening this is the change that made the last four
##    games feel free, and it is not a knob.
## 2. **The greedy option burns faster.** `burn` is a live multiplier, not a
##    constant, so going fast, digging deeper, carrying more or running the
##    light all cost measurably more. A resource that drains at a fixed rate is
##    a countdown timer wearing a costume: the player makes no decision about it
##    and correctly reports that nothing is at stake.
## 3. **The readout is part of the mechanic.** `seconds_left()` and
##    `reach_at()` exist so the HUD can show the player the decision they are
##    actually making, which is never "how full is the tank" but always "can I
##    get back from here". The logs are just as clear that an invisible stake is
##    the same as no stake: "difficult to judge the price", "i dont see any
##    gauges", "it is difficult to understand what is going on".
##
## Pure: no nodes, no frames. `advance(dt)` is called by whatever owns the
## clock, and a test can run a whole tank dry in microseconds.

signal warned            ## crossed into the warning band, once per entry
signal critical          ## crossed into the critical band, once per entry
signal emptied           ## hit zero. The run is over

## Fractions of capacity at which the bands begin. Two levels rather than one,
## because the player asked for exactly two levels of haptic readout: "when the
## fish pulls, you should feel a small vibration, and when the pole is getting
## too bent, you should get a good amount of vibration to match." One buzz is a
## notification. Two buzzes are an instrument.
const WARN_AT := 0.30
const CRITICAL_AT := 0.12

## How much the bands must recover before they can fire again.
##
## Without hysteresis a meter sitting exactly on a threshold re-fires its signal
## every frame that noise pushes it across, which reaches the player as a
## stuttering icon and a phone buzzing forty times a second. The band must be
## genuinely left before it can be genuinely re-entered.
const BAND_HYSTERESIS := 0.04

var capacity: float = 100.0
var value: float = 100.0

## Units drained per second at a burn of 1.0.
var drain_per_second: float = 1.0

## The live multiplier on the drain. This is the dial the game moves: throttle,
## depth, weight, how many lights are on. 0.0 is allowed and means "idling".
var burn: float = 1.0

## Units regained per second, applied before drain. For a meter that recovers
## when you are not spending it (heat cooling, stamina, oxygen at the surface).
## Left at zero for a true one-way resource like fuel.
var regen_per_second: float = 0.0

## Whether regen is allowed to run at the same time as burn. Off by default: a
## resource that refills while you spend it is the softest possible version of
## a stake, and it is how "it feels free" happens without anyone deciding it.
var regen_while_burning: bool = false

var empty: bool = false

## Total units consumed this run. The honest denominator for an end-of-run
## readout, and the number a difficulty pass should be reading.
var spent: float = 0.0

var _band: int = 0  ## 0 none, 1 warned, 2 critical


func _init(start_capacity: float = 100.0, start_drain: float = 1.0) -> void:
	capacity = maxf(start_capacity, 0.0001)
	drain_per_second = maxf(start_drain, 0.0)
	refill()


## Back to full, not empty, nothing spent. Call at the start of a run.
func refill() -> void:
	value = capacity
	spent = 0.0
	empty = false
	_band = 0


## One step. `dt` is seconds; the caller decides whether that came from a real
## frame or a test stepping at a fixed rate, and the result is identical.
##
## `dt` is clamped to `Mech.MAX_DT` so a phone returning from the lock screen
## with a three second delta does not silently drain a full tank between two
## frames and present the player with a game over they never saw coming.
func advance(dt: float) -> void:
	if empty:
		return
	var step := clampf(dt, 0.0, Mech.MAX_DT)
	if step <= 0.0:
		return

	var burning := burn > 0.0
	if regen_per_second > 0.0 and (regen_while_burning or not burning):
		value = minf(capacity, value + regen_per_second * step)

	var used := drain_per_second * maxf(burn, 0.0) * step
	if used > 0.0:
		value -= used
		spent += minf(used, maxf(value + used, 0.0))

	if value <= 0.0:
		value = 0.0
		empty = true
		_band = 2
		emptied.emit()
		return

	_update_bands()


## Add units, never past capacity. Returns how much was actually taken, so a
## pickup can show "wasted" when the player grabs fuel at 98 percent - which is
## information they can act on, and is the difference between a pickup that
## teaches routing and one that is just a number going up.
##
## Refuses to revive an empty meter. Coming back from zero is a rescue, and
## rescues are what this module exists to refuse. Restart the run instead.
func add(amount: float) -> float:
	if empty or amount <= 0.0:
		return 0.0
	var before := value
	value = minf(capacity, value + amount)
	_update_bands()
	return value - before


## Spend a fixed amount immediately - a boost, a jump, a shot. Returns false and
## changes nothing if there is not enough, so the caller can refuse the action
## rather than going negative.
##
## **All or nothing on purpose.** A partial spend produces a boost that fires at
## 40 percent power, which the player reads as the control being broken rather
## than as the tank being low.
func try_spend(amount: float) -> bool:
	if empty or amount <= 0.0 or value < amount:
		return false
	value -= amount
	spent += amount
	if value <= 0.0:
		value = 0.0
		empty = true
		_band = 2
		emptied.emit()
	else:
		_update_bands()
	return true


## How full, 0..1. What a gauge draws.
func fraction() -> float:
	return clampf(value / capacity, 0.0, 1.0)


## Seconds until empty at the CURRENT burn, or -1.0 for "not draining".
##
## The number the player is actually asking for. A bar shows how much is left;
## this shows how long that is, which is the only form the answer is useful in
## when the burn rate is something they control. Show both: the bar for glance,
## this for the decision.
func seconds_left() -> float:
	var rate := drain_per_second * maxf(burn, 0.0) - (regen_per_second if regen_while_burning else 0.0)
	if rate <= 0.0:
		return -1.0
	return value / rate


## How far the player can travel at a given speed before this empties, in
## whatever unit `speed` is per second.
##
## The routing question made answerable: "is that island inside my range".
func reach_at(speed: float) -> float:
	var seconds := seconds_left()
	if seconds < 0.0:
		return INF
	return maxf(speed, 0.0) * seconds


## Whether `cost` units can be spent and still leave `reserve` behind.
##
## The greedy decision, in one call. A player deciding whether to take one more
## dive is asking exactly this, and a game that cannot answer it is a game where
## the greedy option is a guess rather than a gamble. Feed `reserve` the cost of
## getting home.
func affords(cost: float, reserve: float = 0.0) -> bool:
	return not empty and value - cost >= reserve


func in_warning() -> bool:
	return _band >= 1


func in_critical() -> bool:
	return _band >= 2


## Everything a HUD or a harness needs, flat and all-scalar so a golden test can
## assert the whole thing at once and read the diff.
func state() -> Dictionary:
	return {
		"value": snappedf(value, 0.001),
		"capacity": snappedf(capacity, 0.001),
		"fraction": snappedf(fraction(), 0.001),
		"burn": snappedf(burn, 0.001),
		"seconds_left": snappedf(seconds_left(), 0.01),
		"spent": snappedf(spent, 0.001),
		"band": _band,
		"empty": empty,
	}


## The pure save pair. No file here on purpose: serialization is state to
## Dictionary and back, asserted by a round trip that touches no disk, and the
## file call is a thin wrapper the game owns.
func to_dict() -> Dictionary:
	return {
		"value": value,
		"capacity": capacity,
		"drain": drain_per_second,
		"burn": burn,
		"regen": regen_per_second,
		"spent": spent,
		"band": _band,
		"empty": empty,
	}


## Total or false. A meter restored with a capacity but no value, or a value
## above its capacity, is worse than a fresh one: it looks right and is not.
func apply(data: Dictionary) -> bool:
	for key in ["value", "capacity", "drain", "burn", "regen", "spent", "band", "empty"]:
		if not data.has(key):
			return false
	var cap := float(data["capacity"])
	var val := float(data["value"])
	if not is_finite(cap) or not is_finite(val) or cap <= 0.0:
		return false
	if val < 0.0 or val > cap:
		return false
	capacity = cap
	value = val
	drain_per_second = maxf(float(data["drain"]), 0.0)
	burn = maxf(float(data["burn"]), 0.0)
	regen_per_second = maxf(float(data["regen"]), 0.0)
	spent = maxf(float(data["spent"]), 0.0)
	_band = clampi(int(data["band"]), 0, 2)
	empty = bool(data["empty"])
	return true


# --- internals ------------------------------------------------------------

## Bands only ever fire on entry, and only re-arm once the meter has climbed
## clear of the threshold by `BAND_HYSTERESIS`.
func _update_bands() -> void:
	var f := fraction()
	var want := 0
	if f <= CRITICAL_AT:
		want = 2
	elif f <= WARN_AT:
		want = 1

	if want > _band:
		_band = want
		if want == 2:
			critical.emit()
		else:
			warned.emit()
		return

	# Falling back out of a band needs real recovery, not a jitter across the line.
	if want < _band:
		var threshold := CRITICAL_AT if _band == 2 else WARN_AT
		if f > threshold + BAND_HYSTERESIS:
			_band = want
