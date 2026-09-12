extends RefCounted

## The wall around `src/sim/`, asserted rather than remembered.
##
## INDEX.md standing rule 2: a pure simulation core with no renderer in it.
## `src/sim/` never touches a Node, a Viewport, an input event or a real frame.
## That is what makes the whole-run golden, the headless harness and any future
## rewrite possible - `test/run_tests.gd` loads these files with no window, no
## GPU and no scene tree, so the moment one of them reaches for the engine the
## suite stops being able to run at all.
##
## **The rule lived in a doc comment at the top of every sim file, which is a
## note rather than a gate.** Notes do not fail. The audit found three repos
## whose sim headers now contradict each other about what the wall even covers,
## which is what a rule looks like when nothing reads it. This file reads the
## files.
##
## The sibling web game has the same test as `test/sim-boundary.test.mjs`, and
## its header records the same origin: "that rule used to live in a comment at
## the top of pure-entry.ts, which is a note rather than a gate."
##
## **Comments and string literals are stripped before matching.** This is not a
## nicety: every sim file in this studio carries a header that names the
## forbidden things in order to forbid them, so a matcher that reads raw text
## fails on the paragraph above and on nothing else - a gate that fires every
## time is not a gate. The stripper has its own positive control below, because
## a stripper that is too greedy would blank the code and pass everything.


## The engine surface `src/sim` may not touch, and why each one is here.
##
## Ordered roughly by how often it has actually happened. Each entry is
## [token, what it means]; a token ending in `(` is matched as a call, and every
## token must be preceded by something that is not part of an identifier, so
## `_physics_process(` does not report itself twice as `_process(` and a field
## called `_last_input_event` is not an `InputEvent`.
const FORBIDDEN := [
	["extends Node", "a simulation that IS a node cannot be constructed without a scene tree"],
	["Node3D", "a node type in the simulation drags the whole scene tree into the test runner"],
	["Viewport", "screen space belongs to the presentation layer; the sim has no pixels"],
	["InputEvent", "the sim takes decisions as arguments, never raw input - see Sim.steer_to"],
	["get_tree(", "there is no tree here; this is the error a headless run dies on"],
	["get_node(", "reaching into the scene by path couples the sim to how the game is drawn"],
	["_process(", "a real frame's delta is not reproducible; the caller passes dt in"],
	["_physics_process(", "same, and it also means the physics server is deciding something"],
	["await ", "a frame the sim waits on is a frame the golden cannot replay"],
	["randf(", "an unseeded roll makes the whole-run golden flake about one run in ten"],
	["randi(", "as above - use SimUtil.hash2 for place-keyed decisions or SimRng for a stream"],
	["Input.", "polling the device for input is the presentation layer's job"],

	# The same family as randf/randi and caught for the same reason. Listed
	# separately rather than matched as a prefix so the failure names the call.
	["randf_range(", "an unseeded roll, spelled differently"],
	["randi_range(", "an unseeded roll, spelled differently"],
	["randfn(", "an unseeded roll, spelled differently"],
]

## `FileAccess` and `DirAccess` are deliberately NOT gate tokens: INDEX.md rule 2
## settles that the wall excludes the renderer, not the disk - `src/sim` may use
## them under `user://`, provided serialisation is a pure state/Dictionary pair
## round-tripped by a test that touches no file.


func _sim_files() -> Array[String]:
	var out := _walk("res://src/sim")
	out.sort()
	return out


## Recursive on purpose. A sim that grows a subdirectory is exactly when a file
## stops being looked at, and a non-recursive walk would keep passing while the
## wall quietly stopped covering half the code.
##
## It RETURNS its findings rather than filling an array passed in, because a
## `Packed*Array` handed to a function is copy-on-write and an `append` inside
## would have detached it silently - the walk would have run correctly and
## handed back nothing, which is the one failure shape this whole file exists to
## refuse.
func _walk(path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for d in dir.get_directories():
		out.append_array(_walk(path + "/" + d))
	for f in dir.get_files():
		# `.gd` in a source checkout; an exported build ships `.gd.remap` and no
		# source at all, which is why this suite is a desk and CI gate.
		if f.ends_with(".gd"):
			out.append(path + "/" + f)
	return out


## One line of GDScript with its comment and its string literals removed.
##
## `state` carries the triple-quoted-string flag between lines. Scanned
## character by character rather than with two regexes, because the two orders
## are both wrong: strip comments first and `Color("#ff8800")` loses the rest of
## its line, strip strings first and an apostrophe inside a comment ("the cell's
## own coordinates") opens a string that never closes and swallows the file.
func _strip(line: String, state: Dictionary) -> String:
	var out := ""
	var i := 0
	var n := line.length()
	while i < n:
		var quote: String = state["quote"]
		if quote != "":
			if line.substr(i, quote.length()) == quote:
				state["quote"] = ""
				i += quote.length()
			elif line[i] == "\\":
				i += 2
			else:
				i += 1
			continue
		var c := line[i]
		if c == "#":
			break
		if c == "\"" or c == "'":
			if line.substr(i, 3) == c + c + c:
				state["quote"] = c + c + c
				i += 3
			else:
				state["quote"] = c
				i += 1
			continue
		out += c
		i += 1
	# A plain string cannot span a line in GDScript; a triple-quoted one is the
	# only thing that carries over.
	var carried: String = state["quote"]
	if carried.length() == 1:
		state["quote"] = ""
	return out


## True if `token` appears in `code` not preceded by part of an identifier.
func _uses(code: String, token: String) -> bool:
	var at := code.find(token)
	while at >= 0:
		if at == 0:
			return true
		# `is_valid_identifier()` is false for a digit, because an identifier
		# cannot START with one - hence the separate digit test. Without it,
		# `_physics_process(` would also report itself as `_process(`.
		var prev := code[at - 1]
		if not (prev == "_" or prev.is_valid_identifier() or (prev >= "0" and prev <= "9")):
			return true
		at = code.find(token, at + 1)
	return false


## The whole gate. One assertion per file, listing every offence in it, so a
## file with three problems is one failure that names all three rather than the
## first one three times.
func test_nothing_under_src_sim_touches_the_engine(t: TestHarness) -> void:
	for path in _sim_files():
		var text := FileAccess.get_file_as_string(path)
		var offences: Array[String] = []
		var state := {"quote": ""}
		var lines := text.split("\n")
		for idx in lines.size():
			var code := _strip(lines[idx], state)
			for entry in FORBIDDEN:
				var token: String = entry[0]
				var why: String = entry[1]
				if _uses(code, token):
					offences.append("      %s:%d  uses `%s` - %s" % [path, idx + 1, token, why])
		t.eq(offences.size(), 0, "%s crosses the simulation boundary\n%s" % [path, "\n".join(offences)])


## A wall around an empty room passes every test ever written about it.
func test_there_is_actually_something_behind_the_wall(t: TestHarness) -> void:
	var files := _sim_files()
	t.gt(float(files.size()), 2.0,
		"only %d files under res://src/sim - the simulation moved and this gate is now guarding nothing" % files.size())


## The positive control for the stripper, and the reason this file can be
## trusted at all.
##
## Two ways this gate can be vacuous and neither is visible from a green run: a
## stripper that removes too little fires on every sim header in the studio
## (and would be "fixed" by deleting the rule from the header), and one that
## removes too much blanks the code and passes anything. So: prove that a real
## call is still seen, and that each of the three things that must be invisible
## is invisible.
func test_the_stripper_hides_comments_and_strings_but_not_code(t: TestHarness) -> void:
	var state := {"quote": ""}
	t.ok(_uses(_strip("\tvar v := get_tree()", state), "get_tree("),
		"a bare call was stripped away - this gate would pass anything")
	t.ok(not _uses(_strip("## never touches a Node, a Viewport or an InputEvent", state), "InputEvent"),
		"a doc comment naming the rule trips the rule - every sim file in the studio has one")
	t.ok(not _uses(_strip("\tvar s := \"call get_tree() for the root\"", state), "get_tree("),
		"a string literal trips the rule")
	t.ok(_uses(_strip("\tvar c := Color(\"#ff8800\") if get_tree() else null", state), "get_tree("),
		"a `#` inside a string swallowed the rest of the line, hiding a real call after it")
	t.ok(not _uses(_strip("\tvar s := 'the cell\\'s own coordinates' # and get_tree()", state), "get_tree("),
		"an apostrophe inside a quoted string or a trailing comment confused the scanner")
	t.eq(state["quote"], "",
		"the scanner finished a line still inside a string - it will blank every line after it")
	t.ok(not _uses("\tvar x := _physics_process_hint", "_process("),
		"a token matched in the middle of an identifier")
