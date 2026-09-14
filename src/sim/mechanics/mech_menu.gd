class_name MechMenu
extends RefCounted

## Directional menu navigation: up and down pick a row, left and right cycle the
## variants of that row, and one button confirms.
##
## **This is the most-requested unbuilt thing in this studio's playtest logs.**
## Gideon asked for it three times across two games and got it none of those
## times. His words, because every rule below answers one of them:
##
##   "since the text is small I want arrow keys and confirm button to navigate
##    the menues"
##   "make it so clicking the up or down arrow changes what is selected,
##    highlights it, and provides a description"
##   "up down selects the different equipment and left right changes the version
##    of equipment if we have it"
##   "instead of clicking outside the menu to close it, i want an X or back
##    button to prevent accidentally closing out of the menue"
##   "if I dont have other versions yet, make the arrows grey, so it is obvious
##    that this is my only option currently"
##   "make the select button grey unless there is something clickable, then
##    change it to a yellow or other color that fits the theme"
##   "dont show the dots implying that there are additional equipment. only show
##    those if you have different versions to swap between"
##
## The first is an accessibility note and the log itself flags that it applies to
## every screen, not the one he was looking at.
##
## ## Why this owns its own repeat clock
##
## **Godot emits echo events for a held KEYBOARD key and none at all for a held
## gamepad D-pad.** So a menu that leans on the engine's repeat works at a desk
## and does nothing on a controller, and on an on-screen arrow button there is no
## echo either. The only way the three input paths behave alike is for the menu
## to time the repeat itself, which is what `advance` does.
##
## Pure: it is told a direction is held and how much time passed. It never reads
## an input event or a Node.

signal focus_changed(row: int)
signal variant_changed(row: int, variant: int)
signal confirmed(id: String, variant: int)
signal closed()

const DIR_NONE := 0
const DIR_UP := 1
const DIR_DOWN := 2
const DIR_LEFT := 3
const DIR_RIGHT := 4

## Held-direction repeat, in seconds.
##
## The sources disagree and the brief says so: Android uses 400 ms then 50 ms,
## Unity 500 then 100, a Godot proposal 500 then 50. 500 and 100 is the slowest
## of those in both halves, chosen because this is a menu of equipment rather
## than a text field: overshooting a row you wanted is worse than waiting an
## extra tenth of a second, and a player using this BECAUSE the text is small is
## not the player to rush.
const REPEAT_DELAY := 0.5
const REPEAT_INTERVAL := 0.1


class Row extends RefCounted:
	var id: String
	## How many versions of this thing the player owns. 1 means no arrows.
	var variant_count: int = 1
	var variant: int = 0
	## A row can be focusable and still not confirmable - found but not yet
	## unlocked, or owned but not affordable. The description still shows, which
	## is the whole point of the drip-feed: the game hints at what it does.
	var enabled: bool = true
	var description: String = ""

	func _init(row_id: String, variants: int = 1, is_enabled: bool = true, text: String = "") -> void:
		id = row_id
		variant_count = maxi(variants, 1)
		enabled = is_enabled
		description = text


var rows: Array[Row] = []
var focus: int = 0

## Whether up and down wrap around the ends of the list.
##
## True, following the linear-list rule in Xbox's accessibility guidelines. A
## list that stops dead at the bottom makes the player wonder whether the input
## registered; a list that wraps always answers.
var wrap_rows: bool = true

var _held := DIR_NONE
var _held_time := 0.0
var _fired := 0


func add(row: Row) -> Row:
	rows.append(row)
	return row


func add_simple(id: String, variants: int = 1, enabled: bool = true, description: String = "") -> Row:
	return add(Row.new(id, variants, enabled, description))


func focused() -> Row:
	if rows.is_empty():
		return null
	return rows[clampi(focus, 0, rows.size() - 1)]


## What the description panel shows. Empty when there is nothing focused.
func description() -> String:
	var row := focused()
	return "" if row == null else row.description


# --- moving ---------------------------------------------------------------

## One press of a direction. Call on the press, not the hold.
func press(direction: int) -> void:
	_held = direction
	_held_time = 0.0
	_fired = 0
	_step(direction)


## The direction was released. Resets the repeat, so the next press starts from
## the full delay again rather than continuing a run.
func release() -> void:
	_held = DIR_NONE
	_held_time = 0.0
	_fired = 0


## One step of the repeat clock. See the header for why this exists at all.
func advance(dt: float) -> void:
	if _held == DIR_NONE:
		return
	_held_time += clampf(dt, 0.0, Mech.MAX_DT)
	if _held_time < REPEAT_DELAY:
		return
	var due := int((_held_time - REPEAT_DELAY) / REPEAT_INTERVAL) + 1
	while _fired < due:
		_fired += 1
		_step(_held)


func _step(direction: int) -> void:
	if rows.is_empty():
		return
	match direction:
		DIR_UP:
			_move_focus(-1)
		DIR_DOWN:
			_move_focus(1)
		DIR_LEFT:
			_move_variant(-1)
		DIR_RIGHT:
			_move_variant(1)


func _move_focus(step: int) -> void:
	var next := focus + step
	if wrap_rows:
		next = posmod(next, rows.size())
	else:
		next = clampi(next, 0, rows.size() - 1)
	if next == focus:
		return
	focus = next
	focus_changed.emit(focus)


## Variants CLAMP rather than wrap, and that is the decision that makes the grey
## arrows mean something.
##
## If left and right wrapped, an arrow would always be live, so greying it could
## never say "this is your only option" - which is exactly what he asked it to
## say. Wrapping rows and clamping variants is not an inconsistency, it is two
## different questions: the list always has somewhere to go, a single item does
## not have another version.
func _move_variant(step: int) -> void:
	var row := focused()
	if row == null or row.variant_count <= 1:
		return
	var next := clampi(row.variant + step, 0, row.variant_count - 1)
	if next == row.variant:
		return
	row.variant = next
	variant_changed.emit(focus, row.variant)


# --- what the controls must SHOW ------------------------------------------
#
# Every one of these exists so a control can say what it can do BEFORE it is
# pressed. A control that looks live and does nothing is the fault he reported.

## Whether the left arrow should be drawn live or grey.
func can_go_left() -> bool:
	var row := focused()
	return row != null and row.variant_count > 1 and row.variant > 0


func can_go_right() -> bool:
	var row := focused()
	return row != null and row.variant_count > 1 and row.variant < row.variant_count - 1


## Whether the confirm button should be live or grey.
##
## "make the select button grey unless there is something clickable, then change
## it to a yellow or other color that fits the theme."
func can_confirm() -> bool:
	var row := focused()
	return row != null and row.enabled


## Whether to draw the variant dots AT ALL.
##
## "dont show the dots implying that there are additional equipment. only show
## those if you have different versions to swap between."
##
## An indicator that implies options which do not exist is worse than no
## indicator, because the player goes looking for them.
func show_dots() -> bool:
	var row := focused()
	return row != null and row.variant_count > 1


## How many dots, and which is filled. `[0, 0]` when none should be drawn.
func dots() -> Array:
	if not show_dots():
		return [0, 0]
	var row := focused()
	return [row.variant_count, row.variant]


# --- confirming and closing -----------------------------------------------

## Take the focused row. Returns its id, or "" if it could not be taken.
##
## Refusing rather than emitting is deliberate: a disabled row is still focusable
## so its description can teach the player what it is, and pressing confirm on it
## must do visibly nothing rather than quietly something.
func confirm() -> String:
	var row := focused()
	if row == null or not row.enabled:
		return ""
	confirmed.emit(row.id, row.variant)
	return row.id


## Close the menu, deliberately.
##
## **There is no dismiss-by-tapping-outside anywhere in this module, and that is
## the point.** He asked for an explicit X or back three times, across two games,
## and the second ask was about a book that closed itself when it ran out of
## pages - the same family of fault: the screen going away without the player
## choosing it. If a game wants tap-outside, it has to write that itself, and
## then it owns the accidental dismissal.
func close() -> void:
	closed.emit()


## Put the focus somewhere directly, for opening a screen on a chosen row.
func set_focus(index: int) -> void:
	if rows.is_empty():
		return
	var next := clampi(index, 0, rows.size() - 1)
	if next == focus:
		return
	focus = next
	focus_changed.emit(focus)


func state() -> Dictionary:
	var row := focused()
	return {
		"rows": rows.size(),
		"focus": focus,
		"id": "" if row == null else row.id,
		"variant": 0 if row == null else row.variant,
		"can_left": can_go_left(),
		"can_right": can_go_right(),
		"can_confirm": can_confirm(),
		"dots": show_dots(),
	}


## Only the variant choices are saved. The rows themselves are content and
## belong to the game's data, the same rule the draft and progress modules
## follow: a save that can invent rows will restore equipment a later build no
## longer has.
func to_dict() -> Dictionary:
	var picked := {}
	for row in rows:
		picked[row.id] = row.variant
	return {"focus": focus, "variants": picked}


func apply(data: Dictionary) -> bool:
	if not data.has("focus") or not data.has("variants"):
		return false
	if typeof(data["variants"]) != TYPE_DICTIONARY:
		return false
	var picked: Dictionary = data["variants"]
	for row in rows:
		if picked.has(row.id):
			row.variant = clampi(int(picked[row.id]), 0, row.variant_count - 1)
	focus = clampi(int(data["focus"]), 0, maxi(rows.size() - 1, 0))
	return true
