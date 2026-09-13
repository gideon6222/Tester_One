class_name ScreenStack
extends RefCounted

## What the Android back button unwinds, as a list of names and nothing else.
##
## **This is a model, not a UI.** It holds strings. It never instantiates a
## Control, never adds a child and never touches the tree, which is the entire
## reason it is here rather than inside `Main`: the back button's behavior is
## then arithmetic the pure suite can drive in milliseconds, exactly the way
## `test_controls.gd` drives the handedness gate. See `test/test_back_button.gd`.
##
## **Why the studio needs it at all.** Every session that has taken the phone
## has asked it the same question - does back unwind one layer at a time, or
## does it drop the player out of the game. That is a question about a stack
## discipline, and a stack discipline is the cheapest thing in the world to
## assert on a desk. The phone can only answer what the desk cannot: thermal,
## safe area, real touch, and the lifecycle around a genuine
## `NOTIFICATION_WM_GO_BACK_REQUEST`.
##
## The names are the game's own. `Main` pushes whatever it opens - "pause",
## "settings", "shop" - and cares only about the depth. Nothing here validates a
## name against a list, because a stack that knows the game's screens is a
## second source of truth for what the game's screens are.

var _names: Array[String] = []


## Opens a layer. The name is for the game to route on and for a failing test to
## be readable; the stack itself only counts.
func push(screen: String) -> void:
	_names.append(screen)


## Closes the top layer and returns its name, or "" when there was nothing open.
##
## An empty pop is a legitimate question ("is anything open?") rather than a
## programming error, because that is precisely the state the back button asks
## about on the last press. It returns "" instead of erroring so the caller can
## treat "nothing left" as an answer.
func pop() -> String:
	if _names.is_empty():
		return ""
	return _names.pop_back()


## The name of the layer a back press would close, or "" when the game itself is
## what is on screen.
func top() -> String:
	if _names.is_empty():
		return ""
	return _names[-1]


func depth() -> int:
	return _names.size()


func is_empty() -> bool:
	return _names.is_empty()


## Drops every layer at once. For a "resume" button or a level restart, never for
## a back press: unwinding the whole stack on one press is the bug this class was
## written to make visible, and `test/test_back_button.gd` fails on it.
func clear() -> void:
	_names.clear()
