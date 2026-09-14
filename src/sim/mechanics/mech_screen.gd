class_name MechScreen
extends RefCounted

## Leaving one screen, waiting, and arriving at the next - as one mechanism.
##
## Research: `research/finish.md` sections 1 and 4. Every constant here is from a
## primary source (Nielsen's response-time thresholds as restated by NN/g, and
## Material's motion spec), and the ones that are not say so.
##
## **Why the transition and the loading indicator are one object and not two.**
## A real screen change is a single arc: cover the screen, do the work, uncover.
## The spinner is not a separate feature, it is what the covered part shows IF the
## work overruns. Split into two objects, the game has to coordinate them, and the
## coordination is where the bugs are - a spinner that appears over a fade, a fade
## that finishes before the content exists, a swap that happens while the player
## can still see the old screen. Here the swap can only happen at the covered
## moment, because that is the only moment this object will report it.
##
## **The fault this exists to prevent**, from the brief: *"A hard cut between
## screens with 0 ms transition is the single most common hobby-build tell."* It
## reads as a state appearing rather than a place being arrived at.

# --- phases -----------------------------------------------------------------

const IDLE := 0
const OUT := 1       ## covering the screen
const COVERED := 2   ## fully covered, work happening, swap allowed
const IN := 3        ## uncovering onto the new screen

# --- what the player sees while covered -------------------------------------

const NOTHING := 0
const SPINNER := 1
const PROGRESS := 2

## Nielsen's three thresholds, and the spine of everything below. 0.1 s reads as
## instantaneous and as caused by the player. 1.0 s keeps their train of thought.
## 10 s is the limit of attention, past which they assume the app is broken.
const INSTANT := 0.1
const SPINNER_AT := 1.0
const PROGRESS_AT := 10.0

## Once a spinner is up, it stays up at least this long.
##
## **This is the rule that is always missing, and it is why a fast app can look
## broken.** Without it: the work runs 1.05 s, the spinner appears at 1.0 s and
## vanishes 50 ms later. A 50 ms flash is not read as "that was quick", it is read
## as a glitch - something flickered and the player does not know what. Showing it
## for half a second costs 450 ms of honesty and looks deliberate.
##
## **Chosen, not sourced.** NN/g gives the 1 s and 10 s thresholds and does not
## give a minimum display time. 0.5 s is long enough to register as intentional
## and short enough not to be a tax. Said plainly so nobody cites it as field data.
const SPINNER_MIN_VISIBLE := 0.5

# --- durations --------------------------------------------------------------

## Material's motion spec. 200 ms for a small local change, about 300 ms for a
## full screen-to-screen move, 400 ms for something large. **Past 400 ms it reads
## as slow**, which is why `begin` refuses above it.
const LOCAL := 0.20
const SCREEN := 0.30
const LARGE := 0.40
const DURATION_MAX := 0.40

## Exits are faster than entrances, because arrival is watched more closely than
## departure.
##
## **The two briefs disagree here and the overlap is empty, so this says which one
## won and why.** `finish.md` gives 300 ms in against 200 to 250 ms out, a ratio of
## 0.67 to 0.83, described as an example. `premium-motion.md` gives Material 1's
## actual published pair, 225 ms in and 195 ms out, which is 0.867 - outside the
## other band entirely.
##
## The published pair wins over the illustrative example, so this is 0.85, at the
## Material end. The practical consequence is small (at a 300 ms entrance the exit
## is 255 ms rather than 225 ms) and the honest summary is that everyone agrees on
## the DIRECTION and nobody has measured the size.
const EXIT_RATIO := 0.85

# --- state ------------------------------------------------------------------

var enter_s: float = SCREEN
var exit_s: float = SCREEN * EXIT_RATIO

var _phase: int = IDLE
var _t: float = 0.0            ## seconds inside the current phase
var _covered_for: float = 0.0  ## seconds spent covered, drives the affordance
var _spinner_shown_at: float = -1.0
var _ready: bool = false
var _swap_taken: bool = false

# --- starting ---------------------------------------------------------------


## Begin a transition. Returns false and does nothing on a bad duration or while
## one is already running.
##
## Refusing a duration over 400 ms is deliberate: the spec says it reads as slow,
## and a module that silently accepts 2.0 s is a module that lets a game ship a
## transition nobody wants to sit through. Refusing 0 is the same argument from
## the other end, because 0 is the hard cut this whole object exists to prevent.
func begin(duration: float = SCREEN) -> bool:
	if _phase != IDLE:
		return false
	if duration <= 0.0 or duration > DURATION_MAX or not is_finite(duration):
		return false
	enter_s = duration
	exit_s = duration * EXIT_RATIO
	_phase = OUT
	_t = 0.0
	_covered_for = 0.0
	_spinner_shown_at = -1.0
	_ready = false
	_swap_taken = false
	return true


## The new screen's content exists and the transition may finish.
##
## A game with nothing to load calls this immediately after `begin`, and the
## transition is then a pure 300 ms cover-and-uncover with no spinner, which is
## the common case and must stay free of ceremony.
func content_ready() -> void:
	_ready = true

# --- time -------------------------------------------------------------------


## Advance.
##
## **`dt` is NOT clamped by `Mech.MAX_DT`, and it must not be.** A transition is a
## wall-clock promise: the game said 300 ms, and 300 ms is what the player's eye
## is timing. Clamping a stalled frame would stretch a 300 ms transition into
## something longer in real time, which is the opposite of the intent. This is the
## same reasoning as `MechGesture`'s double-tap window, and the opposite of
## `MechNeedle`'s sweep, where a stall must not cost the player the check.
##
## **It must also be UNSCALED time.** A transition into a pause screen runs while
## `Engine.time_scale` is 0, and a transition driven by scaled time would freeze
## halfway and never arrive. Same rule as `MechJuice`.
func advance(dt: float) -> void:
	if _phase == IDLE or dt <= 0.0:
		return
	_t += dt
	match _phase:
		OUT:
			if _t >= exit_s:
				_phase = COVERED
				_t = 0.0
		COVERED:
			_covered_for += dt
			if affordance() == SPINNER and _spinner_shown_at < 0.0:
				_spinner_shown_at = _covered_for
			if _ready and can_uncover():
				_phase = IN
				_t = 0.0
		IN:
			if _t >= enter_s:
				_phase = IDLE
				_t = 0.0

# --- reading it -------------------------------------------------------------


func phase() -> int:
	return _phase


func is_running() -> bool:
	return _phase != IDLE


## How covered the screen is, 0 clear and 1 fully covered. Eased, because a linear
## fade is the other half of the hard-cut tell: it arrives at full opacity at a
## constant rate, which nothing physical does.
func curtain() -> float:
	match _phase:
		OUT:
			return Mech.ease_in_out_cubic(clampf(_t / maxf(exit_s, 0.0001), 0.0, 1.0))
		COVERED:
			return 1.0
		IN:
			return 1.0 - Mech.ease_in_out_cubic(clampf(_t / maxf(enter_s, 0.0001), 0.0, 1.0))
		_:
			return 0.0


## What to show over the covered screen.
##
## Never goes backwards. Once the wait has earned a spinner it keeps one until the
## transition ends, because an indicator that disappears while the player is still
## waiting says the wait ended when it did not.
func affordance() -> int:
	if _phase != COVERED:
		return NOTHING
	if _covered_for >= PROGRESS_AT:
		return PROGRESS
	if _covered_for >= SPINNER_AT or _spinner_shown_at >= 0.0:
		return SPINNER
	return NOTHING


## True once a shown spinner has served its minimum. Always true if none was shown.
func can_uncover() -> bool:
	if _spinner_shown_at < 0.0:
		return true
	return _covered_for - _spinner_shown_at >= SPINNER_MIN_VISIBLE


## Seconds the spinner still owes before it may vanish. 0 when it may go now.
func hold_remaining() -> float:
	if _spinner_shown_at < 0.0:
		return 0.0
	return maxf(0.0, SPINNER_MIN_VISIBLE - (_covered_for - _spinner_shown_at))


## True EXACTLY ONCE, at the first covered frame. The only safe moment to swap
## what is under the curtain, and the reason this returns once rather than
## reporting a state: a swap done twice is a screen built twice.
func take_swap() -> bool:
	if _phase == COVERED and not _swap_taken:
		_swap_taken = true
		return true
	return false


## What a progress bar should SHOW, given how far the work actually is.
##
## **One of the very few measured results in this whole area.** Harrison et al.
## (UIST 2007) found a progress bar that decelerates toward the end is rated about
## 11% SHORTER than a linear bar of identical real duration. So the same wait can
## be made to feel shorter for free, by drawing it differently.
##
## `Mech.ease_out_cubic` is exactly that shape: quick early, slowing as it lands.
## It is monotonic and it maps 0 to 0 and 1 to 1, so the bar never runs backwards
## and never shows full before the work is done - both of which would trade the 11%
## for a much larger loss of trust.
##
## This is display only. Never feed it back into anything that decides when the
## work has finished, or the readout becomes a second source of truth for progress
## (studio rule 10).
func display_progress(real_progress: float) -> float:
	return Mech.ease_out_cubic(clampf(real_progress, 0.0, 1.0))


## Whether a wait of this many seconds is worth any indicator at all. A game
## deciding whether to bother covering the screen can ask before it starts.
func needs_indicator(expected_wait: float) -> bool:
	return expected_wait >= SPINNER_AT


## Whether a delay is short enough to read as caused by the player rather than by
## the machine. Nielsen's 100 ms.
func reads_as_instant(delay: float) -> bool:
	return delay <= INSTANT


func state() -> Dictionary:
	return {
		"phase": _phase,
		"curtain": curtain(),
		"affordance": affordance(),
		"covered_for": _covered_for,
		"hold_remaining": hold_remaining(),
	}


## Only the durations persist. A transition in flight is not a thing to restore:
## a save taken mid-fade should reload onto a settled screen, not half a curtain.
func to_dict() -> Dictionary:
	return {"enter": enter_s, "exit": exit_s}


func apply(d: Dictionary) -> void:
	var e: float = float(d.get("enter", SCREEN))
	if e <= 0.0 or e > DURATION_MAX or not is_finite(e):
		e = SCREEN
	enter_s = e
	exit_s = float(d.get("exit", e * EXIT_RATIO))
	if exit_s <= 0.0 or exit_s > DURATION_MAX or not is_finite(exit_s):
		exit_s = e * EXIT_RATIO
	_phase = IDLE
	_t = 0.0
	_covered_for = 0.0
	_spinner_shown_at = -1.0
	_ready = false
	_swap_taken = false
