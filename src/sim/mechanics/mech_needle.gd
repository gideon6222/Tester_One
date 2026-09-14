class_name MechNeedle
extends RefCounted

## The stop-the-needle skill check: a marker sweeps a track, the player taps, and
## where the marker was when they tapped is the whole mechanic.
##
## Research: `research/timing.md`, section 4. `MechTiming` grades a tap against a
## MOMENT; this is the instrument that creates the moment and shows it coming.
## They are separate because a rhythm lane needs the grading with no needle and a
## skill check needs the needle with its own geometry.
##
## **The finding that should change how this is tuned.** Dead by Daylight is the
## best-documented example of exactly this mechanic, and its numbers say the
## thing nobody expects: the Great zone is 10.5 degrees wide and the needle
## sweeps at a median 320 degrees per second, up to 406 with a perk. So the
## player has 26 to 37 ms to hit a zone that LOOKS generous. A fat bar on screen
## is not a forgiving window, and reading forgiveness off the picture rather than
## off the arithmetic is how this mechanic is mistuned. `great_seconds()` below
## exists so the real number is always one call away.

## Where the needle is on its track, 0 to 1, wrapping. A fraction rather than
## degrees or pixels so the same instrument drives a circular gauge, a horizontal
## bar and a vertical meter without three sets of constants.
var phase: float = 0.0

## Sweeps per second. DBD's median 320 deg/s is 0.89 of a full circle per second;
## its fastest observed 406 deg/s is 1.13. This default is the median.
const SWEEP_DEFAULT := 0.89
var sweeps_per_second: float = SWEEP_DEFAULT

## Where the success zone starts, 0 to 1.
var zone_start: float = 0.6

## Widths as fractions of the track.
##
## DBD's structure, and it is deliberate rather than incidental: **the Great zone
## sits at the LEADING EDGE of the Good zone**, with Good extending about 38
## degrees past it on the late side and nothing at all on the early side. Tapping
## early misses entirely. Tapping a little late is still a Good.
##
## That asymmetry is the design. It matches how people actually fail this - they
## commit early out of nerves - and it means the punishing side of the window is
## the one the player can see coming.
const GREAT_FRACTION := 10.5 / 360.0
const GOOD_FRACTION := (10.5 + 38.0) / 360.0
var great_width: float = GREAT_FRACTION
var good_width: float = GOOD_FRACTION

## Whether the needle is running. A skill check that keeps sweeping after it has
## been answered will be answered twice.
var active: bool = false
var answered: bool = false

## Where this sweep started, and how far it has travelled since, in fractions of
## the track.
##
## **Distance travelled is tracked rather than inferred from the phase, and the
## suite is what proved it has to be.** On a circular track "not yet at the zone"
## and "a long way past the zone" are THE SAME REGION: with the needle at 0.0 and
## the zone at 0.6, the gap behind the zone reads as 0.4 whether the needle is
## approaching for the first time or has been round twice. A `missed()` built on
## the phase alone therefore fires the instant the check begins, which is a skill
## check that is lost before the player sees it.
var _start_phase: float = 0.0
var _travelled: float = 0.0


## Start a sweep from a given phase. The needle begins BEFORE the zone by
## default so the player sees it approach; starting inside the zone is a free
## hit and starting just past it is unanswerable.
func begin(from_phase: float = 0.0) -> void:
	phase = fposmod(from_phase, 1.0)
	_start_phase = phase
	_travelled = 0.0
	active = true
	answered = false


## Advance the needle.
##
## **`dt` is clamped by `Mech.MAX_DT` and that is correct here, unlike the
## wall-clock windows in `MechGesture`.** A hitch must not teleport the needle
## through the zone: the player did not get slower, the frame did, and a skill
## check that cannot be passed because the renderer stalled is the game cheating.
##
## **A music-synced game must NOT drive this from `dt` at all.** Accumulated
## frame deltas drift against the audio clock, and the drift is exactly the
## quantity a rhythm game is measuring. Set `phase` from the audio playback
## position instead and never call this. Said here rather than in the recipe
## because this is the function somebody will reach for.
func step(dt: float) -> void:
	if not active:
		return
	var d: float = sweeps_per_second * minf(dt, Mech.MAX_DT)
	phase = fposmod(phase + d, 1.0)
	_travelled += d


## Distance from the needle to the START of the zone, forward along the sweep,
## as a fraction of the track. 0 exactly at the leading edge.
func to_zone() -> float:
	return fposmod(zone_start - phase, 1.0)


## How far the needle is INTO the zone, or -1 when it is not in it. The value a
## readout should show, and the value the grade is taken from, so the two cannot
## disagree (studio rule 10).
func depth_in_zone() -> float:
	var d: float = fposmod(phase - zone_start, 1.0)
	return d if d <= good_width else -1.0


## Grade the tap, using `MechTiming`'s ladder so a game mixing a rhythm lane and
## a skill check reports both on one scale.
##
## Answering twice returns MISS without changing anything: a double tap is not
## two chances.
func commit() -> int:
	if not active or answered:
		return MechTiming.MISS
	answered = true
	active = false
	var d: float = depth_in_zone()
	if d < 0.0:
		return MechTiming.MISS
	if d <= great_width:
		return MechTiming.PERFECT
	return MechTiming.GOOD


## The sweep has gone past the zone without an answer. A skill check that is
## never answered has to resolve or the game waits forever.
##
## Measured against distance TRAVELLED, for the circular-track reason given at
## `_travelled`. Placing the needle by hand (setting `phase` directly, as a test
## or an audio-synced game does) does not advance the travel, so this stays false
## until the needle has actually been driven past the zone.
func missed() -> bool:
	if not active or answered:
		return false
	return _travelled > fposmod(zone_start + good_width - _start_phase, 1.0)


## **How long the Great zone is actually open, in seconds.** The number to look
## at before believing a zone is generous. At the defaults this is 0.033, which
## is tighter than `MechTiming`'s 70 ms perfect window despite looking far more
## forgiving on screen.
func great_seconds() -> float:
	if sweeps_per_second <= 0.0:
		return 0.0
	return great_width / sweeps_per_second


func good_seconds() -> float:
	if sweeps_per_second <= 0.0:
		return 0.0
	return good_width / sweeps_per_second


## Set the zone. Refuses widths that are not ordered or that wrap the whole
## track: a good zone covering everything is a skill check that cannot be
## failed, which is a construct that cannot fail and therefore untested
## (studio rule 11).
func set_zone(start: float, great: float, good: float) -> bool:
	if great <= 0.0 or good <= great or good >= 1.0:
		return false
	zone_start = fposmod(start, 1.0)
	great_width = great
	good_width = good
	return true


## Make it harder by NARROWING THE ZONE rather than speeding the needle.
##
## **Flagged as reasoning, not sourced.** The brief found no A/B result on which
## reads better. The argument for the zone: a narrower zone at constant speed is
## a pure precision test and reads as fair-but-hard, while a faster needle also
## punishes misjudging the distance still to travel, which is much harder to
## eyeball and reads as unfair sooner. Speed is the knob to turn last and
## sparingly, so it is not what this function touches.
func set_difficulty(t: float) -> void:
	var k: float = clampf(t, 0.0, 1.0)
	great_width = lerpf(GREAT_FRACTION, GREAT_FRACTION * 0.4, k)
	good_width = lerpf(GOOD_FRACTION, GOOD_FRACTION * 0.55, k)


func state() -> Dictionary:
	return {
		"phase": phase,
		"active": active,
		"answered": answered,
		"depth": depth_in_zone(),
		"great_seconds": great_seconds(),
	}


func to_dict() -> Dictionary:
	return {
		"sweep": sweeps_per_second,
		"start": zone_start,
		"great": great_width,
		"good": good_width,
	}


func apply(d: Dictionary) -> void:
	sweeps_per_second = float(d.get("sweep", SWEEP_DEFAULT))
	var s: float = float(d.get("start", 0.6))
	var g: float = float(d.get("great", GREAT_FRACTION))
	var b: float = float(d.get("good", GOOD_FRACTION))
	if not set_zone(s, g, b):
		zone_start = 0.6
		great_width = GREAT_FRACTION
		good_width = GOOD_FRACTION
