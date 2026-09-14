class_name MechIdle
extends RefCounted

## The arithmetic of an economy: cost curves, bulk buying, prestige and offline
## earnings.
##
## Static and pure. Nothing here holds state, so it can be called from a shop
## screen, a save loader, a balance test or a spreadsheet export without any of
## them knowing about the others. `MechGenerator` is the stateful thing built on
## top of it.
##
## Every formula here is the one shipped games actually use, with the source
## named at the function. Where the research could not find a real number,
## the doc says so rather than presenting a guess as a fact - the sourced
## values are in `research/economy.md`, and the gaps are marked there too.
##
## **The one design opinion in this file** is in `cost_for_next`: growth rate is
## not a decoration, it is the pacing dial. A growth of 1.07 and a growth of
## 1.15 are the difference between a purchase every few seconds forever and a
## wall you hit in twenty minutes, and no amount of production tuning fixes the
## wrong choice.

## Growth rates from shipped games, for reference when picking one.
##
## Cookie Clicker uses 1.15 across the board. AdVenture Capitalist's Lemonade
## Stand uses 1.07 and its later businesses vary. The usable band is roughly
## 1.07 to 1.15: below it the curve barely bites and the player buys in bulk
## forever, above it the wall arrives too fast for the production side to keep
## up and the game reads as broken rather than as hard.
const GROWTH_GENTLE := 1.07
const GROWTH_STANDARD := 1.15

## Below this, a growth rate is treated as linear rather than geometric.
## The closed forms below divide by `(growth - 1)`, so a rate of exactly 1.0
## is not a rounding problem, it is a division by zero.
const LINEAR_EPSILON := 1e-9

## Where float64 stops being able to count.
##
## Past 2^53 an integer cannot be represented exactly, so a cost, a bank balance
## or a lifetime total beyond this silently starts rounding - purchases go
## through that should not, and a total stops increasing at all. An idle game
## that runs long enough WILL reach this. Cross it and you need a mantissa plus
## exponent pair rather than a float, which is a different module and a
## deliberate decision, not something to discover from a bug report.
const SAFE_INTEGER := 9007199254740992.0


# --- cost curves ----------------------------------------------------------

## What the next one costs, given how many are already owned.
##
##   cost = base * growth^owned
##
## The formula behind every incremental game. `owned` is the count BEFORE this
## purchase, so the first ever purchase costs exactly `base`.
##
## Source: Cookie Clicker's published price formula, and the standard treatment
## in Anthony Pecorella's "The Math of Idle Games" (Kongregate).
static func cost_for_next(base: float, growth: float, owned: int) -> float:
	if owned < 0:
		return base
	return base * pow(growth, float(owned))


## What it costs to buy `count` more, starting from `owned`.
##
## The geometric series, closed form:
##
##   cost = base * growth^owned * (growth^count - 1) / (growth - 1)
##
## Worth having as a closed form rather than a loop: a bulk-buy button that
## sums a thousand purchases one at a time is a visible stall on a phone, and
## the loop's rounding drifts from the closed form the shop screen quotes.
static func cost_for_bulk(base: float, growth: float, owned: int, count: int) -> float:
	if count <= 0:
		return 0.0
	if absf(growth - 1.0) < LINEAR_EPSILON:
		return base * float(count)
	var first := cost_for_next(base, growth, owned)
	return first * (pow(growth, float(count)) - 1.0) / (growth - 1.0)


## How many can be afforded with `cash`, starting from `owned`.
##
## The inverse of `cost_for_bulk`, solved for count:
##
##   count = floor( log(1 + cash * (growth - 1) / (base * growth^owned)) / log(growth) )
##
## This is what a "buy max" button needs, and doing it by trial subtraction is
## both slower and subtly different from the price the bulk call quotes.
##
## Returns 0 rather than a negative when nothing is affordable.
static func affordable_count(base: float, growth: float, owned: int, cash: float) -> int:
	if cash <= 0.0:
		return 0
	var first := cost_for_next(base, growth, owned)
	if first <= 0.0:
		return 0
	if absf(growth - 1.0) < LINEAR_EPSILON:
		return int(floor(cash / first))
	var inner := 1.0 + cash * (growth - 1.0) / first
	if inner <= 1.0:
		return 0
	var n := int(floor(log(inner) / log(growth)))
	return maxi(n, 0)


# --- production -----------------------------------------------------------

## Output per second from `owned` producers at `base` each, times any
## multipliers.
##
## Linear in `owned` on purpose. The whole tension of the genre is that
## production is linear or polynomial while cost is geometric, so every
## generator eventually stops being worth buying and the player has to reach
## for something structural instead. That crossover is the game.
static func production(base: float, owned: int, multiplier: float = 1.0) -> float:
	return base * float(maxi(owned, 0)) * multiplier


## Seconds of saving needed to afford the next one at the current income.
##
## The single most useful pacing number there is, and the one to tune against.
## If this climbs past a minute or two for the generator the player is currently
## focused on, the game has stalled, whatever the curves say.
##
## Returns INF when there is no income at all, rather than dividing by it.
static func seconds_to_afford(cost: float, cash: float, income_per_second: float) -> float:
	var missing := cost - cash
	if missing <= 0.0:
		return 0.0
	if income_per_second <= 0.0:
		return INF
	return missing / income_per_second


# --- prestige -------------------------------------------------------------

## Prestige currency earned for a lifetime total.
##
##   earned = floor( (lifetime / scale) ^ exponent )
##
## The generalised form of what shipped games use. The exponent is what decides
## how much more you have to earn to double your reward, which is the only part
## the player feels:
##
## | Game | Formula | Earn this much more to double |
## |---|---|---|
## | Cookie Clicker | cbrt(lifetime / 1e12), so exponent 1/3 | 8x |
## | AdVenture Capitalist | sqrt(lifetime / 44.4e9), exponent 1/2 | 4x |
## | Egg Inc | (run / 1e6)^0.14 | 128x |
##
## A lower exponent is a longer, flatter game. Egg Inc's 0.14 is what a game
## built to run for years looks like; a half is what a game built for a weekend
## looks like.
static func prestige_earned(lifetime_total: float, scale: float, exponent: float = 1.0 / 3.0) -> float:
	if lifetime_total <= 0.0 or scale <= 0.0:
		return 0.0
	var ratio := lifetime_total / scale
	if ratio <= 0.0:
		return 0.0
	return _floor_with_tolerance(pow(ratio, exponent))


## Floor, unless the value is within floating-point noise of a whole number.
##
## **This is not a nicety, it is a whole prestige level.** `pow(1000.0, 1.0/3.0)`
## returns 9.999999999999998, so the obvious `floor(pow(...))` pays out 9 chips
## for a total that should pay 10. The player who worked out the threshold and
## hit it exactly gets nothing, sees no error, and is simply wrong about the
## game's own published formula.
##
## The tolerance is relative, because an absolute epsilon means nothing once the
## reward is in the thousands.
static func _floor_with_tolerance(raw: float) -> float:
	var nearest := roundf(raw)
	if absf(raw - nearest) < 1e-9 * maxf(1.0, absf(raw)):
		return nearest
	return floorf(raw)


## The lifetime total needed to earn a given amount of prestige currency.
##
## The inverse, so a UI can say "1.4 billion more for the next chip" - which is
## the readout that makes a prestige feel like a target rather than a surprise.
static func prestige_threshold(target: float, scale: float, exponent: float = 1.0 / 3.0) -> float:
	if target <= 0.0 or exponent <= 0.0:
		return 0.0
	return scale * pow(target, 1.0 / exponent)


## The multiplier a prestige stack is worth.
##
## Additive per unit, which is what Cookie Clicker does and what reads most
## honestly: each chip is visibly worth the same as the last. A multiplicative
## stack compounds into numbers nobody can reason about within two resets.
static func prestige_multiplier(currency: float, per_unit: float = 0.02) -> float:
	return 1.0 + maxf(currency, 0.0) * per_unit


# --- offline earnings -----------------------------------------------------

## What to pay out for time away.
##
##   payout = income_per_second * min(seconds_away, cap_seconds) * rate
##
## Two dials, and both exist for a reason:
##
## - **`rate`** is the fraction of the online rate paid while away. Shipped
##   games sit between 0.5 and 1.0 (Egg Inc pays 100% up to its cap, Idle Online
##   Universe pays 90%, half is the common generic default). Below about a half
##   the player feels punished for closing the app, which is the opposite of
##   what the mechanic is for.
## - **`cap_seconds`** is the point where it stops accruing. Shipped caps run
##   from 2 hours (Egg Inc) to several days. The cap is what makes coming back
##   after lunch worth something and coming back after a month not worth
##   skipping the whole midgame.
##
## Negative elapsed time returns zero. That is not paranoia: a player who moves
## their device clock backwards, or a device that corrects its clock over the
## network, hands you a negative interval, and the naive version pays out a
## negative fortune or a positive one depending on sign handling.
static func offline_earnings(income_per_second: float, seconds_away: float,
		rate: float = 0.5, cap_seconds: float = 8.0 * 3600.0) -> float:
	if income_per_second <= 0.0 or seconds_away <= 0.0:
		return 0.0
	var counted := minf(seconds_away, maxf(cap_seconds, 0.0))
	return income_per_second * counted * clampf(rate, 0.0, 1.0)


## Whether a stored timestamp can be trusted for an offline payout.
##
## The check that belongs in front of every `offline_earnings` call. A save from
## the future means the clock moved, and paying out on it is how an idle game
## gets trivially cheated by changing the date.
static func elapsed_is_plausible(saved_unix_time: int, now_unix_time: int) -> bool:
	return saved_unix_time > 0 and now_unix_time >= saved_unix_time


# --- experience and levels ------------------------------------------------

## XP needed to go from `level` to the next one.
##
##   needed = base * level^power
##
## Quadratic (power 2.0) is the common shape and is what Vampire Survivors uses
## with a base of 8. Power 1.0 is linear and flattens too early; much past 2.5
## and the last levels of a run become unreachable, which is only correct if
## they are meant to be.
static func xp_for_level(level: int, base: float = 8.0, power: float = 2.0) -> float:
	var l := maxi(level, 1)
	return base * pow(float(l), power)


## Total XP to reach `level` from level 1. Summed rather than closed-form
## because the power is arbitrary, and because a level table is computed once at
## load and then read, not computed per frame.
static func xp_total_to_level(level: int, base: float = 8.0, power: float = 2.0) -> float:
	var total := 0.0
	for l in range(1, maxi(level, 1)):
		total += xp_for_level(l, base, power)
	return total


# --- big numbers ----------------------------------------------------------

## Whether a value has passed the point where a float stops counting exactly.
##
## Call it in a test, not in the game loop. An idle game that ships without ever
## asserting this will eventually have a player whose total simply stops going
## up, and no error anywhere.
static func exceeds_safe_integer(value: float) -> bool:
	return not is_finite(value) or absf(value) >= SAFE_INTEGER


## A short name for a large number: 12.4K, 3.1M, 891B, then scientific.
##
## Named tiers stop at the point where nobody can tell two adjacent names apart.
## Past a quadrillion this returns scientific notation on purpose: "1.2Qa" is
## not more readable than "1.2e15", it just looks more like a word.
static func fmt_big(value: float) -> String:
	if not is_finite(value):
		return "inf"
	var v := absf(value)
	var sign_text := "-" if value < 0.0 else ""
	if v < 1000.0:
		return sign_text + ("%.0f" % v)
	const NAMES := ["K", "M", "B", "T"]
	var tier := 0
	while v >= 1000.0 and tier < NAMES.size():
		v /= 1000.0
		tier += 1
	if tier >= NAMES.size() and v >= 1000.0:
		return sign_text + _scientific(absf(value))
	var name: String = NAMES[tier - 1]
	if v < 10.0:
		return sign_text + ("%.2f%s" % [v, name])
	if v < 100.0:
		return sign_text + ("%.1f%s" % [v, name])
	return sign_text + ("%.0f%s" % [v, name])


## Scientific notation, built by hand.
##
## **GDScript's `%` operator has no `%e`.** It supports f, d, s, x, o, c and the
## literal %%, and anything else raises "unsupported format character" at
## runtime - which in GDScript is a non-fatal error that stops the function
## where it stands and lets everything above it carry on reporting success.
## Worth knowing before reaching for a C-style format string anywhere else.
static func _scientific(v: float) -> String:
	if v <= 0.0:
		return "0"
	var exponent := int(floor(log(v) / log(10.0)))
	var mantissa := v / pow(10.0, float(exponent))
	# Rounding the mantissa can carry it to 10.0, which is not scientific notation.
	if mantissa >= 9.995:
		mantissa /= 10.0
		exponent += 1
	return "%.2fe%d" % [mantissa, exponent]
