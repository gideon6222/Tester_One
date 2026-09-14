class_name MechGesture
extends RefCounted

## Turns a stream of touch positions into tap, double tap, long press, drag,
## swipe and fling.
##
## Pure: it is fed positions and deltas by whatever owns the input events, and
## it never touches an `InputEvent` itself. That is what lets a headless test
## drive a whole gesture and assert what came out, which matters more here than
## almost anywhere else in the library, because touch handling is the layer
## where this studio's player has reported the most faults and the hardest ones
## to reproduce by hand.
##
## ## Everything is in dp, not pixels
##
## A threshold in pixels is a different physical distance on every phone. Every
## constant below is in density-independent pixels, the unit Android's own
## platform constants use, and `px_per_dp` converts once at construction. On the
## 1080x2340 xxhdpi phone these games are played on, 1 dp is 3 px.
##
## Where a value below comes from `android.view.ViewConfiguration` the constant
## is named, because those are the numbers every other app on the phone is
## already using, and matching them is why a gesture here feels like a gesture
## anywhere else.

signal tapped(position: Vector2)
signal double_tapped(position: Vector2)
signal long_pressed(position: Vector2)
signal drag_started(position: Vector2)
signal dragged(position: Vector2, delta: Vector2)
signal drag_ended(position: Vector2)
## `direction` is one of the DIR_* constants. `speed` is in dp per second.
signal swiped(direction: int, speed: float)

# --- Android's own numbers ------------------------------------------------

## How far a finger may move and still be a tap. `ViewConfiguration.getScaledTouchSlop`.
const TAP_SLOP_DP := 8.0

## How far before a drag is definitely a drag and not a slow tap.
## `ViewConfiguration.getScaledPagingTouchSlop`.
const DRAG_SLOP_DP := 16.0

## `ViewConfiguration.getLongPressTimeout`, the platform default. The user can
## raise it to 1500 ms in accessibility settings, which a game cannot read, so
## treat this as the fast end rather than as the truth for every player.
const LONG_PRESS_S := 0.4

## `ViewConfiguration.getDoubleTapTimeout` and `getScaledDoubleTapSlop`.
## The minimum exists because two touches closer together than this are one
## finger bouncing, not two deliberate taps.
const DOUBLE_TAP_S := 0.3
const DOUBLE_TAP_MIN_S := 0.04
const DOUBLE_TAP_SLOP_DP := 100.0

## `ViewConfiguration.getScaledMinimumFlingVelocity`, in dp per second.
const MIN_FLING_DPS := 50.0

## The smallest thing a finger can reliably hit. 48 dp is Android's guideline
## and matches its own `MIN_SCROLLBAR_TOUCH_TARGET`; Apple's is 44 pt. At
## 3 px per dp that is 144 px on this phone, and about 9 mm of glass.
##
## **A touch target is not the same shape as the art.** This studio's player
## reported "The button icons don't line up with where you need to press ...
## about .5 inches too high", which is what happens when the hit rect is
## computed from a layout and the icon is drawn somewhere else inside it. Size
## the target from here, centre the art in it, and never the other way round.
const MIN_TOUCH_TARGET_DP := 48.0

# --- directions -----------------------------------------------------------

const DIR_NONE := 0
const DIR_UP := 1
const DIR_DOWN := 2
const DIR_LEFT := 3
const DIR_RIGHT := 4

## How much longer the dominant axis must be before a swipe is called.
##
## **Android has no standard for this and the research found none anywhere**, so
## this is a decision rather than a citation. 1.5 means a swipe 30 degrees off
## an axis still counts, and a true diagonal is refused rather than being
## snapped to whichever axis happened to win by a pixel. A game that wants eight
## directions should read `last_swipe_vector()` instead of forcing this to
## classify something it deliberately will not.
const AXIS_DOMINANCE := 1.5

## Pixels per dp. 3.0 on a 1080x2340 xxhdpi phone. Godot can supply the real one
## with `DisplayServer.screen_get_scale()`, which is a presentation-layer call,
## which is why it is passed in rather than read here.
var px_per_dp: float = 3.0

var _down := false
var _start := Vector2.ZERO
var _last := Vector2.ZERO
var _held := 0.0
var _is_drag := false
var _long_fired := false
var _since_last_tap := INF
var _last_tap_at := Vector2.ZERO
var _velocity := Vector2.ZERO
var _last_swipe := Vector2.ZERO


func _init(pixels_per_dp: float = 3.0) -> void:
	px_per_dp = maxf(pixels_per_dp, 0.0001)


## Convert a dp threshold to this device's pixels.
func dp(value: float) -> float:
	return value * px_per_dp


## The finger went down.
func begin(position: Vector2) -> void:
	_down = true
	_start = position
	_last = position
	_held = 0.0
	_is_drag = false
	_long_fired = false
	_velocity = Vector2.ZERO


## The finger moved. Safe to call with the same position repeatedly.
func move(position: Vector2) -> void:
	if not _down:
		return
	var delta := position - _last
	_last = position

	if not _is_drag and _start.distance_to(position) > dp(DRAG_SLOP_DP):
		_is_drag = true
		drag_started.emit(_start)

	if _is_drag:
		dragged.emit(position, delta)


## The finger came up. This is where a tap, a double tap or a swipe is decided.
func end(position: Vector2) -> void:
	if not _down:
		return
	_down = false
	_last = position
	var travel := _start.distance_to(position)

	if _is_drag:
		drag_ended.emit(position)
		_maybe_swipe(position)
		return

	# A long press already fired: the finger coming up is not also a tap.
	if _long_fired:
		return

	if travel <= dp(TAP_SLOP_DP):
		if _since_last_tap >= DOUBLE_TAP_MIN_S and _since_last_tap <= DOUBLE_TAP_S \
				and _last_tap_at.distance_to(position) <= dp(DOUBLE_TAP_SLOP_DP):
			_since_last_tap = INF  # a double tap is not the first half of a triple
			double_tapped.emit(position)
		else:
			_since_last_tap = 0.0
			_last_tap_at = position
			tapped.emit(position)
	else:
		# Moved more than a tap but less than the drag slop, and let go. This is
		# a flick, and it is the gesture that a naive handler silently drops.
		_maybe_swipe(position)


## One step. Drives the long press timer and the double tap window.
##
## **Two different clocks, deliberately.** Everything that integrates motion uses
## `dt` clamped to `Mech.MAX_DT`, so a phone coming back from the lock screen
## with a three second delta does not teleport a velocity. The double tap window
## uses the RAW delta, because it is a wall-clock question - "did these two taps
## happen close together in real time" - and clamping it means a genuine six
## hundred millisecond gap is counted as fifty, so a tap from before the app was
## backgrounded pairs with the first tap after it and fires a double the player
## never made.
##
## Found by a test rather than by a bug report, which is the whole reason the
## timers are asserted separately.
func advance(dt: float) -> void:
	var step := clampf(dt, 0.0, Mech.MAX_DT)
	if is_finite(_since_last_tap):
		_since_last_tap += maxf(dt, 0.0)

	if not _down:
		return
	_held += step

	# Velocity is smoothed rather than taken from the last frame alone. A single
	# frame's delta at the moment a finger lifts is frequently zero, because the
	# finger stops before it leaves the glass, which is why a naive fling
	# detector misses most flings.
	var instant := (_last - _start) / maxf(_held, 0.0001)
	_velocity = Mech.damp_v2(_velocity, instant, 12.0, step)

	if not _is_drag and not _long_fired and _held >= LONG_PRESS_S \
			and _start.distance_to(_last) <= dp(TAP_SLOP_DP):
		_long_fired = true
		long_pressed.emit(_start)


## Cancel whatever is in progress without emitting anything.
##
## Call it on a pause, a menu opening or the app losing focus. Without it, a
## finger that was mid-drag when a menu opened produces a drag that never ends,
## and the next `begin` is interpreted against a stale start position.
func cancel() -> void:
	_down = false
	_is_drag = false
	_long_fired = false
	_since_last_tap = INF
	_velocity = Vector2.ZERO


func is_dragging() -> bool:
	return _is_drag


## Travel since the finger went down, in pixels. What a pull-back-to-aim control
## reads every frame.
func drag_vector() -> Vector2:
	return _last - _start


## The last swipe as a raw vector, for a game that wants more than four
## directions or wants the angle itself.
func last_swipe_vector() -> Vector2:
	return _last_swipe


## Speed at the moment of release, in dp per second.
func fling_speed_dps() -> float:
	return _velocity.length() / px_per_dp


func state() -> Dictionary:
	return {
		"down": _down,
		"dragging": _is_drag,
		"held": snappedf(_held, 0.001),
		"travel": snappedf(drag_vector().length(), 0.1),
	}


# --- internals ------------------------------------------------------------

func _maybe_swipe(position: Vector2) -> void:
	var v := position - _start
	_last_swipe = v
	if fling_speed_dps() < MIN_FLING_DPS:
		return
	var dir := classify(v)
	if dir != DIR_NONE:
		swiped.emit(dir, fling_speed_dps())


## Which of the four directions a vector points, or DIR_NONE for a diagonal
## too ambiguous to call.
##
## Refusing is deliberate. A classifier that always answers turns a genuinely
## diagonal flick into whichever axis won by a pixel, and the player experiences
## that as the game reading their input at random. Better to do nothing and let
## them swipe again.
static func classify(v: Vector2, dominance: float = AXIS_DOMINANCE) -> int:
	var ax := absf(v.x)
	var ay := absf(v.y)
	if ax <= 0.0001 and ay <= 0.0001:
		return DIR_NONE
	if ax > ay * dominance:
		return DIR_RIGHT if v.x > 0.0 else DIR_LEFT
	if ay > ax * dominance:
		# Screen space: y grows downward.
		return DIR_DOWN if v.y > 0.0 else DIR_UP
	return DIR_NONE


## Whether a point is inside a control, using a hit rect grown to the minimum
## touch target.
##
## Pass the VISUAL rect of the art. The target is expanded around its centre to
## at least 48 dp in each axis, which is the fix for a small icon that is
## correctly drawn and impossible to press.
func hits(visual_rect: Rect2, point: Vector2) -> bool:
	var minimum := dp(MIN_TOUCH_TARGET_DP)
	var size := Vector2(maxf(visual_rect.size.x, minimum), maxf(visual_rect.size.y, minimum))
	var target := Rect2(visual_rect.get_center() - size * 0.5, size)
	return target.has_point(point)
