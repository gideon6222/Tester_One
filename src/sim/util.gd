class_name SimUtil
extends RefCounted

## Pure helpers. No nodes, no rendering, no scene tree - so the test runner can
## call any of this headlessly without standing a game up.
##
## Everything here is statically typed on purpose. Typed GDScript compiles to
## faster bytecode than untyped, and more usefully it makes a wrong argument a
## load error rather than a nan three frames later.

const MASK_32 := 0xFFFFFFFF


## Frame-rate independent smoothing: the fraction to move toward a target this
## frame, given a rate and a real delta.
##
## `pos += (target - pos) * 0.1` looks fine at 60fps and is a different spring
## at 120, which is what the phone actually runs at.
static func smooth(rate: float, dt: float) -> float:
	return 1.0 - exp(-rate * dt)


## 32-bit multiply. GDScript ints are 64-bit, so a plain `*` does not wrap the
## way the mixing steps below assume; masking after each one does.
static func imul(a: int, b: int) -> int:
	return (a * b) & MASK_32


## Deterministic 2D hash, uniform over [0, 1).
##
## Every place-keyed decision goes through this rather than randf(), which is
## what makes a whole run reproducible from (chunk, level) alone and is what
## the golden test depends on.
##
## The shifts operate on a value already masked to 32 unsigned bits, so `>>` is
## a logical shift here. That detail is the whole function: in the sibling web
## game the same hash used signed shifts, so `h ^ (h >> 16)` always cleared the
## top bit and it could never return above 0.5 - which silently disabled three
## mechanics whose spawn rolls compared against thresholds above a half, with
## no error and nothing visibly missing. `test/test_util.gd` asserts the range
## and the distribution for exactly that reason.
static func hash2(a: int, b: int) -> float:
	var h: int = (imul(a, 374761393) + imul(b, 668265263)) & MASK_32
	h = imul(h ^ (h >> 13), 1274126177)
	h = (h ^ (h >> 16)) & MASK_32
	return float(h) / 4294967296.0


## Compact numbers for a HUD. Thousands keep one decimal until five figures, so
## the width of the readout stays roughly still while the number climbs.
static func fmt(n: float) -> String:
	var v := int(floor(n))
	if v < 1000:
		return str(v)
	if v < 1000000:
		return ("%.1fK" % (v / 1000.0)) if v < 10000 else ("%dK" % (v / 1000))
	if v < 1000000000:
		return ("%.1fM" % (v / 1000000.0)) if v < 10000000 else ("%dM" % (v / 1000000))
	return "%.1fB" % (v / 1000000000.0)
