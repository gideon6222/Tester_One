class_name MechJuice
extends RefCounted

## The feel bus: hit stop, screen shake, hit flash, haptics and pitch variation,
## in one object that the whole game reports impacts to.
##
## None of this changes a rule. All of it changes whether the rules are worth
## playing, and it is the highest value per line of code in the library.
##
## **One bus per game, not one per entity.** Two objects each running their own
## shake produce a camera that is the sum of two decaying sine waves, which
## reads as a rattle rather than an impact, and two objects each running their
## own hit stop produce a game that freezes twice for one hit. Everything
## reports here, and this decides what the frame actually does.
##
## ## The thing that is easy to get wrong
##
## **This bus must be advanced on UNSCALED time.** Hit stop works by telling the
## game to scale its own delta to zero. If the bus is advanced with that same
## scaled delta, the freeze never ends, because the timer that would end it is
## itself frozen. The shape that works:
##
##     func _process(delta):
##         juice.advance(delta)                  # real seconds, always
##         sim.advance(delta * juice.time_scale())  # scaled seconds
##
## `test_juice.gd` asserts a frozen bus still thaws, with a positive control
## that hangs forever when the two deltas are swapped.
##
## Pure: no nodes, no viewport, no Input calls. Shake is produced as an offset
## and an angle for the renderer to apply, and haptics are produced as a
## REQUEST that a thin Node adapter performs, because `Input.vibrate_handheld`
## is the presentation layer's business and a headless test cannot call it.

signal haptic_requested(duration_ms: int, amplitude: float)

# --- hit stop -------------------------------------------------------------

## Hit stop durations in seconds, by weight. From a 60 fps frame budget:
## light 2-4 frames, medium 5-8, heavy 10-15.
##
## Super Smash Bros' own formula is `frames = damage * 0.65 + 6`, capped near
## 30 frames, which lands in the same band and is worth copying if the game has
## a damage number to feed it - see `hit_stop_for_damage`.
##
## Below about 40 ms the freeze is not perceived as weight, it is perceived as
## a dropped frame. Above about 250 ms it stops being punctuation and becomes a
## pause the player waits out.
const STOP_LIGHT := 0.05    ## 3 frames
const STOP_MEDIUM := 0.10   ## 6 frames
const STOP_HEAVY := 0.20    ## 12 frames
const STOP_MAX := 0.30      ## nothing may freeze the game longer than this

# --- shake ----------------------------------------------------------------

## The exponent trauma is raised to before it becomes shake.
##
## Squaring is what Squirrel Eiserloh's GDC talk "Math for Game Programmers:
## Juicing Your Cameras With Math" is universally quoted as prescribing, and the
## reason for any exponent above 1 is that it makes small traumas nearly
## invisible and large ones dramatic, so a stream of small hits does not leave
## the camera permanently trembling.
##
## **The research turned up a discrepancy worth knowing about**: the worked
## numbers in that talk (trauma 0.3, 0.6, 0.9 producing roughly 3%, 22% and 73%
## of maximum) fit a CUBE, not a square. Squaring 0.3/0.6/0.9 gives 9%/36%/81%.
## So the number everyone repeats and the numbers in the talk itself disagree.
##
## It is left configurable and defaulted to 2.0, which is the widely used
## convention. If small hits still leave the camera busy, raise it to 3.0 rather
## than lowering every trauma value at the call sites.
const SHAKE_EXPONENT := 2.0

## How fast trauma bleeds off, in units per second.
##
## Trauma decays linearly, so the time from full to nothing is `1.0 / decay`.
## That makes the number easy to pick from the duration you actually want:
##
## | decay | full trauma lasts | a medium hit (0.4) lasts |
## |---|---|---|
## | 1.0 | 1.00 s | 0.40 s |
## | 2.4 | 0.42 s | 0.17 s |
## | 28.0 | 0.036 s | 0.014 s |
##
## **The sourced number is not the one used here, and the arithmetic is why.**
## The research found 28.0 in a widely copied Godot implementation. At 28.0 a
## full-strength shake is over in 36 ms, which is two frames at 60 Hz and one on
## the 120 Hz phone these games are played on. That is not a short shake, it is
## an invisible one. 2.4 gives a little under half a second at full trauma and
## about a sixth of a second for an ordinary hit, which is the band shake
## actually reads in.
##
## Recorded rather than quietly changed, because "where did that number come
## from" is a fair question and "a tutorial" is not a good enough answer when
## the tutorial's value cannot be seen.
const TRAUMA_DECAY := 2.4

## Trauma added by weight. Kept well under 1.0 so that several hits landing
## together can still stack into something bigger, which is the whole reason
## trauma is a pool rather than a duration.
const TRAUMA_LIGHT := 0.20
const TRAUMA_MEDIUM := 0.40
const TRAUMA_HEAVY := 0.70

# --- flash ----------------------------------------------------------------

## How long a hit flash lasts.
##
## The sources genuinely disagree, and they disagree because they are describing
## two different effects. 40 to 100 ms is a snappy "that connected" blink, at
## the edge of perception. 250 to 300 ms is a "hurt glow" that tweens out and
## reads as a state rather than an event. Use `FLASH_HIT` for feedback on a
## blow landing and `FLASH_HURT` for the player taking damage.
const FLASH_HIT := 0.07
const FLASH_HURT := 0.28

# --- haptics --------------------------------------------------------------

## Vibration durations in milliseconds, named by what they read as.
##
## Taken from the durations Android's own haptic primitives target: TICK around
## 5 ms, CLICK around 12 ms, THUD around 300 ms. In a game an alarm reads better
## as a repeated pulse than as one long buzz, so `ALARM_MS` is one pulse of a
## pattern rather than the whole thing.
##
## **Two levels, not one.** This studio's player asked for exactly that, as an
## instrument rather than as juice: "when the fish pulls, you should feel a
## small vibration, and when the pole is getting too bent, you should get a good
## amount of vibration to match." A single buzz level is a notification. Two
## distinguishable levels carry information, and they carry it to the thumb,
## which is already on the glass and is not looking at anything.
const HAPTIC_TICK_MS := 5
const HAPTIC_CLICK_MS := 12
const HAPTIC_THUD_MS := 120
const HAPTIC_ALARM_MS := 350

## Amplitude is 0..1, or -1 for "the device default".
##
## Godot's `Input.vibrate_handheld(duration_ms, amplitude)` passes amplitude
## through to Android. iOS ignores the duration entirely and picks from its own
## fixed set, so a pattern tuned by duration alone is an Android pattern.
const HAPTIC_DEFAULT_AMPLITUDE := -1.0

# --- audio ----------------------------------------------------------------

## Pitch variation band for a repeated sound.
##
## An identical sample played more than about five times in a row stops being
## heard as an event and starts being heard as a texture. 0.92 to 1.09 is a
## commonly used band and is narrow enough not to change what the sound IS.
const PITCH_MIN := 0.92
const PITCH_MAX := 1.09


var stop_timer: float = 0.0
var trauma: float = 0.0
var flash_timer: float = 0.0
var flash_duration: float = FLASH_HIT

## Rises forever, drives the shake noise. Advanced on unscaled time with
## everything else here.
var _t: float = 0.0
var _shake_seed: int = 0


func _init(shake_seed: int = 0) -> void:
	_shake_seed = shake_seed


## One step, on REAL seconds. See the header: advancing this with the scaled
## delta it produces is a freeze that never ends.
func advance(dt: float) -> void:
	var step := clampf(dt, 0.0, Mech.MAX_DT)
	_t += step
	if stop_timer > 0.0:
		stop_timer = maxf(0.0, stop_timer - step)
	if flash_timer > 0.0:
		flash_timer = maxf(0.0, flash_timer - step)
	trauma = maxf(0.0, trauma - TRAUMA_DECAY * step)


## What the game should multiply its own delta by this frame: 0.0 while frozen,
## 1.0 otherwise.
func time_scale() -> float:
	return 0.0 if stop_timer > 0.0 else 1.0


func is_frozen() -> bool:
	return stop_timer > 0.0


# --- reporting an impact --------------------------------------------------

## The one call most of a game needs. `weight` is 0..1 and means how big this
## hit was relative to the biggest hit in the game.
##
## Fires everything at once, which is also the correct ORDER: sound, haptics,
## hit stop and flash all belong on the same frame as the impact. Particles can
## land a frame or two later without anyone noticing, and a damage number should
## appear after the freeze releases, or it is a number that appeared during a
## frozen frame and reads as a glitch.
func hit(weight: float = 0.5) -> void:
	var w := Mech.clamp01(weight)
	add_stop(lerpf(STOP_LIGHT, STOP_HEAVY, w))
	add_trauma(lerpf(TRAUMA_LIGHT, TRAUMA_HEAVY, w))
	flash(FLASH_HIT)
	request_haptic(HAPTIC_CLICK_MS if w < 0.5 else HAPTIC_THUD_MS)


## Hit stop from a damage number, using Super Smash Bros' formula:
## `frames = damage * 0.65 + 6`, at 60 fps, capped.
##
## **The cap bites earlier here than it does in Smash.** That game caps near 30
## frames; `STOP_MAX` is 18 frames, because half a second of frozen screen is a
## fighting-game beat and not a phone-game one. The consequence, stated so it is
## not discovered later: this function saturates at about 18.5 damage, and every
## hit above that freezes for the same length. If a game needs its heaviest hits
## to read as heavier still, give them more trauma and a longer flash rather
## than raising the cap - a longer freeze past this point reads as a stutter.
static func hit_stop_for_damage(damage: float) -> float:
	var frames := maxf(damage, 0.0) * 0.65 + 6.0
	return minf(frames / 60.0, STOP_MAX)


## Freeze for `seconds`. The LONGER of the current freeze and the new one wins
## rather than adding: three hits landing on one frame should freeze once, for
## as long as the biggest of them, not for the sum. Summing is how a big combo
## turns into a second and a half of nothing happening.
func add_stop(seconds: float) -> void:
	stop_timer = minf(maxf(stop_timer, seconds), STOP_MAX)


## Add to the trauma pool. Pooled rather than set, so simultaneous hits build,
## but clamped at 1.0 so a bad frame cannot throw the camera off the map.
func add_trauma(amount: float) -> void:
	trauma = Mech.clamp01(trauma + maxf(amount, 0.0))


func flash(seconds: float = FLASH_HIT) -> void:
	flash_duration = maxf(seconds, 0.0001)
	flash_timer = flash_duration


## Ask the presentation layer to buzz. Pure: this emits a request and performs
## nothing, so a headless test can assert the pattern without a device.
func request_haptic(duration_ms: int, amplitude: float = HAPTIC_DEFAULT_AMPLITUDE) -> void:
	if duration_ms <= 0:
		return
	haptic_requested.emit(duration_ms, amplitude)


# --- what the renderer reads ----------------------------------------------

## Current shake strength, 0..1, after the exponent. This is what everything
## below scales by, and what to multiply any bespoke shake by too.
func shake() -> float:
	return pow(trauma, SHAKE_EXPONENT)


## Camera offset in pixels (or metres), given the maximum this game allows.
##
## Value noise rather than `randf()`, for two reasons that both matter. Random
## offsets per frame produce a buzz whose character changes with the frame rate,
## so the same shake is a different effect at 60 and 120 Hz. And a random offset
## is not reproducible, so a filmed run cannot be compared against another one.
## This is smooth, frame-rate independent and seeded.
func shake_offset(max_offset: float) -> Vector2:
	var s := shake() * max_offset
	return Vector2(_noise(0) * s, _noise(1) * s)


## Camera roll in radians. A small amount of rotation does more for the feel of
## an impact than a large amount of translation, because translation can be
## confused with the camera following something.
func shake_angle(max_radians: float) -> float:
	return _noise(2) * shake() * max_radians


## Flash intensity, 1.0 at the instant of the hit falling to 0.0.
##
## Eased rather than linear: a linear fade reads as a light being dimmed, and an
## eased one reads as something being struck.
func flash_intensity() -> float:
	if flash_timer <= 0.0:
		return 0.0
	return Mech.ease_out_quad(flash_timer / flash_duration)


## A pitch for the `n`th play of a repeated sound. Deterministic in `n`, so a
## replay sounds identical, which `randf_range` would not be.
static func pitch_for(n: int, seed_value: int = 0) -> float:
	return lerpf(PITCH_MIN, PITCH_MAX, Mech.hash2(n, seed_value))


func state() -> Dictionary:
	return {
		"stop": snappedf(stop_timer, 0.001),
		"trauma": snappedf(trauma, 0.001),
		"shake": snappedf(shake(), 0.001),
		"flash": snappedf(flash_intensity(), 0.001),
		"frozen": is_frozen(),
	}


# --- internals ------------------------------------------------------------

## Smooth value noise in [-1, 1] on the shared clock, one independent channel
## per `axis`. Interpolated with a smoothstep so the camera is never asked to
## make an instant jump, which is what makes random-per-frame shake look cheap.
##
## 20 Hz, chosen against the display rather than by eye. Screen shake wants to
## read as a fast buzz, so the frequency should be near the top of what the eye
## resolves as motion, but it has to be SAMPLED properly or it aliases into a
## different, slower wobble that changes with the frame rate. At 20 Hz the
## 120 Hz phone gets six samples per cycle and a 60 Hz preview still gets three.
## An earlier 34 Hz gave the phone barely three and the desktop preview under
## two, which is how a shake ends up looking different on the two screens you
## check it on.
const _NOISE_HZ := 20.0

func _noise(axis: int) -> float:
	var x := _t * _NOISE_HZ
	var i := int(floor(x))
	var f := x - float(i)
	var a := Mech.hash3(i, axis, _shake_seed) * 2.0 - 1.0
	var b := Mech.hash3(i + 1, axis, _shake_seed) * 2.0 - 1.0
	var smoothed := f * f * (3.0 - 2.0 * f)
	return lerpf(a, b, smoothed)
