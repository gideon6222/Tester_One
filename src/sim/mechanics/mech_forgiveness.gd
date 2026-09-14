class_name MechForgiveness
extends RefCounted

## Coyote time and input buffering, plus the algebra for a jump arc you can
## describe in words.
##
## This is the invisible layer. Every mechanic in it exists so that when the
## player fails, they are right about why. Without it a game is technically
## fair and feels like it is cheating, and the report you get back is not "the
## coyote window is too short", it is "the controls feel wrong" - which is the
## complaint this studio has collected in five different games.
##
## ## Why these are two separate timers
##
## They answer two different questions, on two different clocks:
##
## - **Coyote time** asks "was this body on the ground recently enough to be
##   allowed to jump". Its clock starts when the ground is lost.
## - **Input buffering** asks "did the player ask for this recently enough that
##   they still mean it". Its clock starts when the button is pressed.
##
## Merging them into one boolean is the standard mistake. It makes a failure
## impossible to diagnose, and worse, it lets a stale press fire after a pause,
## a cutscene or a respawn, so the character jumps on their own the moment
## control returns. That is why `clear()` exists and why the module is built
## around two independent timers rather than one flag.

## Windows in seconds.
##
## The band real games sit in, from the research: coyote 5 to 8 frames at 60 Hz
## (roughly 83 to 133 ms), buffer 6 to 9 frames (100 to 150 ms). Celeste's five
## frames and Super Mario Odyssey's six to eight are the figures everyone
## repeats, though neither is confirmed from a primary source, so treat them as
## the shape of the answer rather than as gospel.
##
## Past about 200 ms coyote time stops being forgiveness and starts being felt:
## the character visibly hangs in the air before the jump takes, and players
## report it as a bug rather than thanking you for it.
const COYOTE_DEFAULT := 0.10   ## 6 frames at 60 Hz
const BUFFER_DEFAULT := 0.12   ## 7 frames at 60 Hz
const WINDOW_MAX := 0.25       ## past this it is perceptible, not forgiving

var coyote_time: float = COYOTE_DEFAULT
var buffer_time: float = BUFFER_DEFAULT

## Seconds since the ground was lost. Zero while grounded.
var _since_grounded: float = INF
## Seconds since the button was pressed. INF when there is no pending request.
var _since_pressed: float = INF
var _grounded: bool = false


func _init(coyote: float = COYOTE_DEFAULT, buffer: float = BUFFER_DEFAULT) -> void:
	coyote_time = clampf(coyote, 0.0, WINDOW_MAX)
	buffer_time = clampf(buffer, 0.0, WINDOW_MAX)


## One step, before `try_consume` in the same frame.
func advance(dt: float) -> void:
	var step := clampf(dt, 0.0, Mech.MAX_DT)
	if not _grounded and is_finite(_since_grounded):
		_since_grounded += step
	if is_finite(_since_pressed):
		_since_pressed += step


## Tell it where the body is. Call every frame, grounded or not.
func set_grounded(grounded: bool) -> void:
	if grounded:
		_since_grounded = 0.0
	elif _grounded:
		# The exact frame the ground was lost. Starting the clock here rather
		# than letting it run from some earlier default is the whole mechanic.
		_since_grounded = 0.0
	_grounded = grounded


## The player asked. Call on the press, not on the hold.
func press() -> void:
	_since_pressed = 0.0


## Drop any pending request, without touching the ground clock.
##
## **Call this on every pause, cutscene, respawn, menu open and control lock.**
## A press made half a second before a pause is not a press the player still
## means when control returns, and a character that jumps on its own the instant
## a menu closes is the single most common symptom of a buffer with no way to
## be emptied.
func clear() -> void:
	_since_pressed = INF


## Forget everything, ground clock included. For a teleport or a new level.
func reset() -> void:
	_since_pressed = INF
	_since_grounded = INF
	_grounded = false


## True exactly once, on the frame the action should actually happen.
##
## Consumes both timers, so it can be called unconditionally each frame and will
## not fire twice for one press.
func try_consume() -> bool:
	if not _press_is_live() or not _may_act():
		return false
	_since_pressed = INF
	_since_grounded = INF  # spend the coyote window, so one loss of ground is one jump
	return true


## Whether the action would be allowed right now, without consuming anything.
## For a UI that greys out a control - which this studio's player has asked for
## directly: "make the select button grey unless there is something clickable".
func can_act() -> bool:
	return _may_act()


## Whether a press is waiting. Distinct from `can_act`, and worth having
## separately precisely because the two questions are separate.
func has_buffered_press() -> bool:
	return _press_is_live()


func is_in_coyote() -> bool:
	return not _grounded and _since_grounded <= coyote_time


func state() -> Dictionary:
	return {
		"grounded": _grounded,
		"coyote": is_in_coyote(),
		"buffered": has_buffered_press(),
		"can_act": can_act(),
	}


func _may_act() -> bool:
	return _grounded or (is_finite(_since_grounded) and _since_grounded <= coyote_time)


func _press_is_live() -> bool:
	return is_finite(_since_pressed) and _since_pressed <= buffer_time


# --- jump arc algebra -----------------------------------------------------
#
# Every one of these takes numbers a person can picture and returns numbers the
# physics needs. Tuning a jump by typing gravity values is guessing; tuning it
# by saying "three units high, a quarter second to the top" is designing.

## The gravity that makes a jump of `height` peak at `time_to_apex`.
##
##   g = 2h / t^2
##
## Positive, in units per second squared. Apply it downward.
static func gravity_for(height: float, time_to_apex: float) -> float:
	var t := maxf(time_to_apex, 0.0001)
	return 2.0 * maxf(height, 0.0) / (t * t)


## The launch speed that makes a jump of `height` peak at `time_to_apex`.
##
##   v0 = 2h / t
static func jump_velocity_for(height: float, time_to_apex: float) -> float:
	var t := maxf(time_to_apex, 0.0001)
	return 2.0 * maxf(height, 0.0) / t


## How high a launch of `velocity` reaches under `gravity`.
static func height_for(velocity: float, gravity: float) -> float:
	if gravity <= 0.0:
		return INF
	return (velocity * velocity) / (2.0 * gravity)


## Falling faster than you rose.
##
## The single highest-value trick in the file. A symmetric arc feels floaty
## because the player spends as long descending, with nothing to do, as they did
## ascending with a decision to make. Multiplying gravity on the way down keeps
## the rise readable and gets the landing over with.
##
## The sourced band is 1.5x to 3x. Below 1.5 the difference is not felt; above
## about 3 the fall reads as the character being yanked rather than falling.
const FALL_MULTIPLIER_DEFAULT := 2.0

static func fall_gravity(rise_gravity: float, multiplier: float = FALL_MULTIPLIER_DEFAULT) -> float:
	return rise_gravity * maxf(multiplier, 1.0)


## Cut a jump short when the button is released, for variable jump height.
##
## `ratio` is how much upward speed survives the release: 0.0 stops the rise
## dead, 1.0 is no variable height at all, and around 0.4 to 0.5 gives a clearly
## controllable arc without the full stop reading as hitting a ceiling.
##
## Only ever reduces upward speed. Called while falling, or on a jump already
## slower than the cut, it does nothing - without that guard, releasing the
## button at the top of a jump ACCELERATES the fall, which players report as the
## jump being inconsistent.
static func cut_jump(velocity_up: float, ratio: float = 0.45) -> float:
	if velocity_up <= 0.0:
		return velocity_up
	return velocity_up * Mech.clamp01(ratio)
