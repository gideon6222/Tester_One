class_name MechTiming
extends RefCounted

## Timing: judging a tap against a moment, and the instruments that ask for one.
##
## One family, one shape. A moving thing crosses a target, the player commits
## with a single tap or release, and the game grades the OFFSET into a short
## ladder. Rhythm lanes, stop-the-needle skill checks and hold-and-release power
## meters are all that same shape wearing different clothes, which is why they
## are one module.
##
## Research: `research/timing.md`. Every constant below is sourced there, and the
## two that are NOT observed in a shipped game are marked as such in their own
## comments rather than in a footnote nobody reads.
##
## **The number that decides this module's whole design is not a window. It is
## Android's latency.** The platform's own documentation says most Android apps
## run more than 100 ms of audio output latency and more than 200 ms round trip
## unless they take the low-latency path, and touch-to-photon adds around 100 ms
## on top. That is 200 to 300 ms of lag between a cue and a registered tap, which
## is LARGER THAN EVERY PERFECT WINDOW in the references and comparable to most
## "good" windows. So:
##
##   a phone game that grades tightly without calibrating is not hard, it is broken
##
## which is why calibration is a first-class part of this module and not an
## options-screen afterthought, and why the uncalibrated defaults sit at the
## forgiving end of the field rather than the competitive end.

# --- the judgement ladder ---------------------------------------------------

const MISS := 0
const GOOD := 1
const PERFECT := 2

## Half-width of the perfect window, in seconds.
##
## The field runs 15 to 50 ms at the competitive end (osu! at high OD, DDR
## Marvelous) and 45 to 160 ms at the casual end (Friday Night Funkin' 45, Guitar
## Hero 5 around 80). A phone has a touchscreen, no peripheral to practice on and
## the latency above, so this sits at the forgiving end deliberately: 70 ms is
## the middle of the brief's recommended 60 to 80 ms uncalibrated default.
##
## **Anything tighter than about 60 ms is a hard-mode toggle, not a default.**
const PERFECT_DEFAULT := 0.070

## Half-width of the good window. Brief's range is 150 to 180 ms; 165 is the
## middle. Outside this is a miss.
const GOOD_DEFAULT := 0.165

## How far EARLY the windows are centred, in seconds.
##
## Negative mean asynchrony: the sensorimotor synchronization literature (Repp's
## review of the tapping literature) finds people tap 20 to 100 ms BEFORE an
## auditory beat, averaging about 30 ms early in healthy adults. It is a robust
## decades-old finding rather than one study. A window centred on zero therefore
## sits late of where taps actually land, and the complaint it produces is
## players saying the game reads them as early.
##
## **Flagged honestly: this is the research literature's number applied as a
## design decision, not a value observed in a shipped phone game.** The brief
## looked for a commercial title documenting that it ships this offset by default
## and did not find one. It is a default, not a fact, and `bias` is settable.
const NMA_BIAS := 0.025

## Taps needed before a calibration is worth trusting.
##
## The technique is documented across rhythm-game devlogs: play a count-in, have
## the player tap along, take the MEAN SIGNED error. No source gave a required
## sample count, so this is chosen rather than sourced: 8 is enough for one bad
## tap to be outvoted and short enough that nobody quits the screen. Said plainly
## so a later session does not cite it as though it came from the field.
const CALIBRATION_MIN_TAPS := 8

## A tap further from the beat than this is not a mistimed tap, it is a mistake -
## a fumble, a double-tap, a player looking away. Folding it into the mean drags
## the whole calibration, and calibration is the one number every later judgement
## is measured against, so it is dropped instead.
const CALIBRATION_OUTLIER := 0.300

## What a well-calibrated player's spread looks like once corrected, per the
## Rhythm Quest devlog: roughly -40 to +40 ms. Used only by `calibration_quality`
## to tell a player the calibration took, never to reject one.
const CALIBRATION_SPREAD_OK := 0.040

# --- state ------------------------------------------------------------------

## Half-widths, in seconds. `good` must be strictly wider than `perfect` or the
## ladder has a rung with no height.
var perfect_window: float = PERFECT_DEFAULT
var good_window: float = GOOD_DEFAULT

## Where the windows are centred, in seconds, negative meaning early.
var bias: float = -NMA_BIAS

## The learned latency, in seconds, added to every raw offset before judging.
## This is the one value that MUST survive a restart, which is what `to_dict`
## exists for: making the player calibrate twice is worse than not asking.
var offset: float = 0.0

var _samples: PackedFloat32Array = PackedFloat32Array()
var _dropped: int = 0

# --- judging ----------------------------------------------------------------


## Grade a raw signed offset, in seconds. Negative is early, positive is late.
##
## The caller passes the difference between when the tap arrived and when the
## target moment was. This applies the stored calibration and the bias, then
## reads the ladder. Returns `MISS`, `GOOD` or `PERFECT`.
func judge(raw_offset: float) -> int:
	var e: float = absf(corrected(raw_offset))
	if e <= perfect_window:
		return PERFECT
	if e <= good_window:
		return GOOD
	return MISS


## The offset actually being judged, after calibration and bias. Exposed because
## a game that shows the player "12 ms early" must show the SAME number the grade
## came from, or the readout and the grade are two sources of truth for one fact
## and they will disagree at the boundary (studio rule 10).
func corrected(raw_offset: float) -> float:
	return raw_offset + offset - bias


## How far into the perfect window a hit landed, 0 at the edge and 1 dead centre.
## For scoring that rewards accuracy inside a grade rather than only the grade.
func accuracy(raw_offset: float) -> float:
	if good_window <= 0.0:
		return 0.0
	var e: float = absf(corrected(raw_offset))
	return clampf(1.0 - e / good_window, 0.0, 1.0)


## Set the ladder. Refuses a good window that is not strictly wider than the
## perfect one: an equal or inverted pair makes GOOD unreachable, which is a
## silent scoring bug rather than a visible crash.
func set_windows(perfect: float, good: float) -> bool:
	if perfect <= 0.0 or good <= perfect:
		return false
	perfect_window = perfect
	good_window = good
	return true


## The competitive end of the field, for a hard-mode toggle: osu! at OD10 is a
## 20 ms perfect and a 60 ms great. **Only ever reachable after a calibration** -
## these windows are smaller than uncalibrated Android latency, so shipping them
## as a default would be the exact failure this module exists to prevent.
func set_strict() -> bool:
	return set_windows(0.020, 0.060)

# --- calibration ------------------------------------------------------------


## Record one tap from the calibration routine. `raw_offset` is signed seconds
## against the metronome. Returns false when the sample was dropped as an
## outlier, so a calibration screen can say "that one did not count" rather than
## silently swallowing it.
func add_sample(raw_offset: float) -> bool:
	if not is_finite(raw_offset) or absf(raw_offset) > CALIBRATION_OUTLIER:
		_dropped += 1
		return false
	_samples.append(raw_offset)
	return true


func sample_count() -> int:
	return _samples.size()


func dropped_count() -> int:
	return _dropped


func ready_to_calibrate() -> bool:
	return _samples.size() >= CALIBRATION_MIN_TAPS


## Commit the samples to `offset`. Returns false and changes NOTHING when there
## are too few taps.
##
## **The offset is the NEGATED mean, and the sign is the whole point.** If the
## player's taps land 80 ms late on average, every later raw offset carries that
## same 80 ms, so the correction has to subtract it. Getting this backwards
## doubles the latency instead of removing it and is invisible in any test that
## only checks the magnitude, which is why the suite asserts the sign directly.
func calibrate() -> bool:
	if not ready_to_calibrate():
		return false
	var total: float = 0.0
	for s in _samples:
		total += s
	offset = -total / float(_samples.size())
	return true


## Standard deviation of the samples, in seconds. Compare against
## `CALIBRATION_SPREAD_OK` to tell the player whether the calibration took or
## whether they were tapping at random.
func calibration_spread() -> float:
	var n: int = _samples.size()
	if n < 2:
		return 0.0
	var mean: float = 0.0
	for s in _samples:
		mean += s
	mean /= float(n)
	var sq: float = 0.0
	for s in _samples:
		sq += (s - mean) * (s - mean)
	return sqrt(sq / float(n))


## True when the samples are tight enough to believe. A calibration from taps
## scattered over 200 ms is a number, but it is not a measurement.
func calibration_is_trustworthy() -> bool:
	return ready_to_calibrate() and calibration_spread() <= CALIBRATION_SPREAD_OK


func clear_samples() -> void:
	_samples = PackedFloat32Array()
	_dropped = 0

# --- state pair -------------------------------------------------------------


## Only the learned values persist. The samples are scratch for one calibration
## screen and deliberately do not survive, so a half-finished calibration cannot
## combine with a later one into a mean of two different sittings.
func to_dict() -> Dictionary:
	return {
		"offset": offset,
		"bias": bias,
		"perfect": perfect_window,
		"good": good_window,
	}


func apply(d: Dictionary) -> void:
	offset = float(d.get("offset", 0.0))
	bias = float(d.get("bias", -NMA_BIAS))
	var p: float = float(d.get("perfect", PERFECT_DEFAULT))
	var g: float = float(d.get("good", GOOD_DEFAULT))
	# Through the setter, so a hand-edited or corrupted save cannot install an
	# impossible ladder. A refused pair leaves the defaults standing.
	if not set_windows(p, g):
		perfect_window = PERFECT_DEFAULT
		good_window = GOOD_DEFAULT
