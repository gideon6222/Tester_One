class_name Mech
extends RefCounted

## The only file every other module in this library depends on.
##
## Copy `gd/` into a game and this comes with it; nothing here reaches for a
## Node, a viewport, an input event or a real frame, so every module built on it
## can be run by a headless test in milliseconds. That constraint is not
## tidiness - it is what lets `docs/` quote numbers that a suite actually
## asserts, instead of numbers someone remembered from a blog post.
##
## Four things live here, and they are the four that every mechanic needed:
##
## 1. **Frame-rate independent smoothing.** The single most common bug in a
##    phone game's feel. `Mech.damp` is the fix and `smooth` is its kernel.
## 2. **A deterministic hash and stream.** Anything that decides *when*
##    something happens must be reproducible or a whole-run golden test flakes.
## 3. **Easing curves**, by name, so a doc can say "ease_out_back at 0.25s" and
##    mean something exact.
## 4. **Weighted choice**, because a third of the modules draft, drop or spawn
##    from a weight table and every one of them was about to write it again.
##
## Everything is statically typed. Typed GDScript compiles to faster bytecode,
## and more usefully it turns a wrong argument into a load error rather than a
## NaN three frames later.

const MASK_32 := 0xFFFFFFFF

## Below this, a delta is treated as a stall rather than a frame.
##
## A phone that has just come back from the lock screen, or a debugger that has
## just been stepped, hands the game a delta of several seconds. Every smoothing
## call below saturates harmlessly, but anything integrating velocity teleports.
## Modules clamp `dt` to this before integrating; the number is one 20 Hz frame,
## which is slower than the worst frame a game in this studio has ever measured
## and still short enough that a real hitch is simulated rather than skipped.
const MAX_DT := 0.05


# --- smoothing and springs ------------------------------------------------

## The fraction to move toward a target this frame, given a rate and a delta.
##
## `pos += (target - pos) * 0.1` is the line this replaces. It looks correct at
## 60 fps and is a visibly different spring at 120, which is what a modern phone
## actually runs at - the S26 Ultra's panel is 120 Hz, so a game tuned on a
## 60 Hz desktop preview arrives on the phone with every ease twice as fast.
##
## `rate` is in units of "e-folds per second": the value covers 63% of the
## remaining distance in `1.0 / rate` seconds. Useful anchors, measured rather
## than guessed (`test_mech.gd` asserts all three):
##
## | rate | 63% of the way | 95% of the way |
## |------|----------------|----------------|
## | 3.0  | 0.33 s         | 1.00 s         |
## | 8.0  | 0.13 s         | 0.37 s         |
## | 20.0 | 0.05 s         | 0.15 s         |
static func smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)


## Move `current` toward `target` at `rate`, frame-rate independently.
##
## The workhorse. Reach for this before any `lerp` with a magic constant.
static func damp(current: float, target: float, rate: float, dt: float) -> float:
	return current + (target - current) * smooth(rate, dt)


## As `damp`, for a 2D value. Componentwise, so it is not direction-preserving
## on a diagonal - which is the behavior you want for a camera and not the
## behavior you want for a velocity. Use `damp_toward` for the latter.
static func damp_v2(current: Vector2, target: Vector2, rate: float, dt: float) -> Vector2:
	var f := smooth(rate, dt)
	return current + (target - current) * f


static func damp_v3(current: Vector3, target: Vector3, rate: float, dt: float) -> Vector3:
	var f := smooth(rate, dt)
	return current + (target - current) * f


## Move toward a target by at most `max_delta`, never overshooting.
##
## The linear counterpart to `damp`. A damp never quite arrives, which is right
## for a camera and wrong for a value that must land exactly - a reload timer, a
## meter draining to zero, a cursor snapping to a slot.
static func approach(current: float, target: float, max_delta: float) -> float:
	if absf(target - current) <= max_delta:
		return target
	return current + signf(target - current) * max_delta


## One step of a damped spring, returned as `[position, velocity]`.
##
## Use this and not `damp` whenever the motion should *overshoot* - a menu card
## landing, a weapon kicking back, a health bar punching past its value and
## settling. A damp is a spring with the life taken out of it.
##
## Integrated semi-implicitly (velocity first, then position) because plain
## Euler gains energy on every step and a stiff spring built on it explodes
## after a few seconds. `test_mech.gd` runs a stiff case for 30 simulated
## seconds and asserts it settles rather than diverges - with a positive control
## that fails if the integration order is swapped back.
##
## `damping` is the ratio, not a coefficient: 1.0 is critical (fastest approach
## with no overshoot), below 1.0 bounces, above 1.0 is sluggish. For a UI
## element that should feel alive, 0.5 to 0.7 is the range worth trying first.
static func spring(value: float, velocity: float, target: float,
		stiffness: float, damping: float, dt: float) -> Array:
	var step := minf(dt, MAX_DT)
	var omega := sqrt(maxf(stiffness, 0.0))
	var force := -stiffness * (value - target) - 2.0 * damping * omega * velocity
	var new_velocity := velocity + force * step
	var new_value := value + new_velocity * step
	return [new_value, new_velocity]


## Spring stiffness that reaches its target in roughly `seconds`, critically.
##
## Lets a tuning file say "0.25 seconds" - a thing a person can picture and a
## designer can ask for - instead of "stiffness 158", which is the same number
## with the meaning removed.
static func spring_stiffness_for(seconds: float) -> float:
	var s := maxf(seconds, 0.001)
	# A critically damped spring settles in about 4 time constants; omega = 4/t.
	var omega := 4.0 / s
	return omega * omega


# --- deterministic randomness ---------------------------------------------

## 32-bit multiply. GDScript ints are 64-bit, so a plain `*` does not wrap the
## way the mixing steps below assume; masking after each one does.
static func imul(a: int, b: int) -> int:
	return (a * b) & MASK_32


## Deterministic 2D hash, uniform over [0, 1).
##
## For decisions keyed on a *place* - which chunk, which level, which slot -
## which give the same answer however many times they are asked, and in any
## order. That is what makes a whole run reproducible and a golden test possible.
## For a stream of values where nothing meaningful indexes them, use `MechRng`.
##
## The shifts operate on a value already masked to 32 unsigned bits, so `>>` is
## a logical shift. That detail is the entire function. In a sibling web game
## the same hash used signed shifts, so `h ^ (h >> 16)` always cleared the top
## bit and it could never return above 0.5 - which silently disabled three
## mechanics whose spawn rolls compared against thresholds above a half, with no
## error and nothing visibly missing. It failed as *absence*, the one failure a
## playtest cannot see. `test_mech.gd` asserts the range and the distribution.
static func hash2(a: int, b: int) -> float:
	var h: int = (imul(a, 374761393) + imul(b, 668265263)) & MASK_32
	h = imul(h ^ (h >> 13), 1274126177)
	h = (h ^ (h >> 16)) & MASK_32
	return float(h) / 4294967296.0


## Three-key variant, for a decision keyed on (x, y, salt) or (chunk, lane, run).
static func hash3(a: int, b: int, c: int) -> float:
	return hash2(int(hash2(a, b) * 4294967296.0) & MASK_32, c)


## Pick an index from a weight table, given a roll in [0, 1).
##
## Returns -1 for an empty table or one whose weights sum to zero, rather than
## silently returning 0 - a drop table that has been misconfigured to nothing
## should be visible, and index 0 is a plausible-looking lie.
##
## Negative weights are clamped to zero rather than rejected, because the common
## way one appears is a weight computed from a stat that went negative, and
## crashing a loot roll is worse than dropping that entry.
static func weighted_pick(weights: PackedFloat32Array, roll: float) -> int:
	var total := 0.0
	for w in weights:
		total += maxf(w, 0.0)
	if total <= 0.0:
		return -1
	var target := clampf(roll, 0.0, 0.999999) * total
	var running := 0.0
	for i in weights.size():
		running += maxf(weights[i], 0.0)
		if target < running:
			return i
	return weights.size() - 1


# --- ranges and curves ----------------------------------------------------

static func clamp01(v: float) -> float:
	return clampf(v, 0.0, 1.0)


## Where `v` sits between `a` and `b`, as 0..1. The inverse of `lerp`.
## A zero-width range returns 0.0 rather than dividing by it.
static func inv_lerp(a: float, b: float, v: float) -> float:
	if is_equal_approx(a, b):
		return 0.0
	return (v - a) / (b - a)


## Move a value from one range to another, clamped to the destination.
static func remap01(v: float, in_min: float, in_max: float) -> float:
	return clamp01(inv_lerp(in_min, in_max, v))


## Decelerating curve. The default for anything arriving somewhere.
static func ease_out_quad(t: float) -> float:
	var x := clamp01(t)
	return 1.0 - (1.0 - x) * (1.0 - x)


static func ease_out_cubic(t: float) -> float:
	var x := clamp01(t)
	return 1.0 - pow(1.0 - x, 3.0)


static func ease_in_out_cubic(t: float) -> float:
	var x := clamp01(t)
	if x < 0.5:
		return 4.0 * x * x * x
	return 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0


## Overshoots past 1.0 and comes back. The "it landed" curve: a card dealing, a
## button confirming, a pickup popping into the HUD. Returns above 1.0 in the
## middle of its range by design, so whatever consumes it must tolerate that.
static func ease_out_back(t: float) -> float:
	var x := clamp01(t)
	const C1 := 1.70158
	const C3 := C1 + 1.0
	return 1.0 + C3 * pow(x - 1.0, 3.0) + C1 * pow(x - 1.0, 2.0)


## Overshoots repeatedly, decaying. Use sparingly and never on anything the
## player is trying to read: it is legible as celebration and illegible as data.
static func ease_out_elastic(t: float) -> float:
	var x := clamp01(t)
	if is_zero_approx(x) or is_equal_approx(x, 1.0):
		return x
	const C4 := TAU / 3.0
	return pow(2.0, -10.0 * x) * sin((x * 10.0 - 0.75) * C4) + 1.0


## Exponential decay to zero over a half-life, frame-rate independently.
##
## The right shape for anything that should fade rather than stop: screen shake,
## a speed boost wearing off, a combo meter cooling. `half_life` is in seconds
## and is directly what it says - after that long, half is left.
static func decay(value: float, half_life: float, dt: float) -> float:
	if half_life <= 0.0:
		return 0.0
	return value * pow(0.5, dt / half_life)


# --- readouts -------------------------------------------------------------

## Compact numbers for a HUD. Thousands keep one decimal until five figures, so
## the width of the readout stays roughly still while the number climbs - a
## number that changes width every frame reads as flicker, not as a score.
static func fmt(n: float) -> String:
	var v := int(floor(n))
	if v < 1000:
		return str(v)
	if v < 1000000:
		return ("%.1fK" % (v / 1000.0)) if v < 10000 else ("%dK" % (v / 1000))
	if v < 1000000000:
		return ("%.1fM" % (v / 1000000.0)) if v < 10000000 else ("%dM" % (v / 1000000))
	return "%.1fB" % (v / 1000000000.0)


## Seconds as `M:SS`, or `H:MM:SS` past an hour. Negative clamps to zero rather
## than printing `-0:-3`, which is what every naive version of this prints the
## first time a timer is allowed to go past its end.
static func fmt_time(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	var h := s / 3600
	var m := (s % 3600) / 60
	var sec := s % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, sec]
	return "%d:%02d" % [m, sec]
