class_name MechSort
extends RefCounted

## The water sort / ball sort / screw sort puzzle: pour the top run of one tube
## onto a tube whose top matches, until every tube holds one colour.
##
## An enormous genre on phones right now, and mechanically it is three rules and
## a generator. The three rules are easy. **The generator is the whole problem**,
## and it is where every hand-rolled version of this goes wrong.
##
## ## Why you cannot just shuffle and deal
##
## Solvability is a global reachability property. No local placement rule can
## guarantee it, because whether a board can be solved depends on the entire
## tree of pours available from it, not on how any one tube looks. Deal a board
## at random and a real fraction of them are dead on arrival, and the player
## cannot tell the difference between "I am stuck" and "this was impossible" -
## which is the worst failure state a puzzle can have, because it teaches them
## that thinking harder does not help.
##
## So: **generate, then verify with an actual solver, and throw the board away
## if it does not solve.** `generate` does exactly that, and it is honest about
## it - if it cannot find a solvable board inside its budget it returns false
## rather than handing back a board it has not checked.
##
## The solver is a depth-first search over a canonical, permutation-invariant
## key. That last part is the optimisation that makes it practical: two boards
## whose tubes are the same multiset are the same position however the tubes are
## ordered on screen, and collapsing them cuts the search enormously.

const EMPTY := -1

## How many units a tube holds. Four is the genre standard.
var capacity: int = 4
## `tubes[i]` is a stack, bottom first. A colour is any non-negative int.
var tubes: Array = []
var moves: int = 0


func _init(tube_capacity: int = 4) -> void:
	capacity = maxi(tube_capacity, 2)


## The colour on top of a tube, or EMPTY.
func top_color(tube: int) -> int:
	if tube < 0 or tube >= tubes.size():
		return EMPTY
	var stack: Array = tubes[tube]
	return EMPTY if stack.is_empty() else int(stack[-1])


## How many of the same colour sit on top of a tube, ready to pour together.
func top_run(tube: int) -> int:
	if tube < 0 or tube >= tubes.size():
		return 0
	var stack: Array = tubes[tube]
	if stack.is_empty():
		return 0
	var color := int(stack[-1])
	var n := 0
	for i in range(stack.size() - 1, -1, -1):
		if int(stack[i]) != color:
			break
		n += 1
	return n


func free_space(tube: int) -> int:
	if tube < 0 or tube >= tubes.size():
		return 0
	return capacity - (tubes[tube] as Array).size()


## Whether a pour is legal, and worth anything.
##
## The "worth anything" half matters. Pouring a full tube of one colour into an
## empty tube is legal by the naive rules and achieves nothing except an
## infinite loop for the solver and a wasted tap for the player, so it is
## refused here rather than allowed and then regretted.
func can_move(from: int, to: int) -> bool:
	if from == to:
		return false
	if from < 0 or to < 0 or from >= tubes.size() or to >= tubes.size():
		return false
	var run := top_run(from)
	if run == 0 or free_space(to) == 0:
		return false
	var destination := top_color(to)
	if destination != EMPTY and destination != top_color(from):
		return false
	# Moving a complete, already-sorted tube into an empty one is a no-op.
	if destination == EMPTY and run == (tubes[from] as Array).size():
		return false
	return true


## Pour. Returns how many units moved, or 0 if the move was illegal.
func move(from: int, to: int) -> int:
	if not can_move(from, to):
		return 0
	var amount := mini(top_run(from), free_space(to))
	var source: Array = tubes[from]
	var destination: Array = tubes[to]
	var color := int(source[-1])
	for _i in amount:
		source.pop_back()
		destination.append(color)
	moves += 1
	return amount


## Every tube is empty, or full of a single colour.
##
## "Full" rather than "uniform" on purpose: a tube holding two of a colour and
## nothing else is not finished, because the other two of that colour are
## somewhere else.
func is_solved() -> bool:
	for i in tubes.size():
		var stack: Array = tubes[i]
		if stack.is_empty():
			continue
		if stack.size() != capacity:
			return false
		var first := int(stack[0])
		for v in stack:
			if int(v) != first:
				return false
	return true


func legal_moves() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for from in tubes.size():
		for to in tubes.size():
			if can_move(from, to):
				out.append(Vector2i(from, to))
	return out


func is_stuck() -> bool:
	return not is_solved() and legal_moves().is_empty()


# --- solving --------------------------------------------------------------

## Search for a solution. Returns the move list, or an empty array.
##
## Depth-first rather than breadth-first, deliberately. BFS finds the SHORTEST
## solution and is hopeless here: a real board measured in the research took
## over ten minutes and nine million states to solve optimally, against a few
## hundred iterations for a depth-first search that merely finds *a* solution.
## For generation, and for a hint button, any solution is the whole requirement.
##
## `budget` caps the states examined so this can never hang a frame. Returning
## an empty array means "not solved within the budget", which is not the same as
## "unsolvable" - `solvable` below is the honest wrapper.
## The board is snapshotted and restored around the search, unconditionally.
##
## The search works by pouring and un-pouring its way through thousands of
## states, and the recursion undoes each move it backtracks out of - but the
## path that SUCCEEDS is never backtracked, so without this the board is left
## sitting in the solved state. That is invisible while testing the solver in
## isolation and catastrophic in use: pressing a hint button would finish the
## player's puzzle for them, and the generator would hand out solved boards.
func solve(budget: int = 20000) -> Array[Vector2i]:
	var saved_tubes: Array = []
	for stack in tubes:
		saved_tubes.append((stack as Array).duplicate())
	var saved_moves := moves

	var visited := {}
	var path: Array[Vector2i] = []
	var examined := [0]
	var found := _search(visited, path, budget, examined)

	tubes = saved_tubes
	moves = saved_moves
	return path if found else []


## Whether this board can be solved within the budget.
func solvable(budget: int = 20000) -> bool:
	return is_solved() or not solve(budget).is_empty()


## The next move of some solution, for a hint button. `Vector2i(-1, -1)` if
## there is not one.
func hint(budget: int = 20000) -> Vector2i:
	var solution := solve(budget)
	return Vector2i(-1, -1) if solution.is_empty() else solution[0]


# --- generation -----------------------------------------------------------

## Build a solvable board.
##
## `colors` distinct colours, each appearing exactly `capacity` times, dealt
## into `colors` full tubes plus `empty_tubes` spare ones. Two spares is the
## genre standard and is what makes the puzzle tractable at all.
##
## **Returns false rather than handing back an unverified board.** If it cannot
## find a solvable deal inside `attempts`, the caller is told, and should either
## raise the attempts or make the board easier. Silently returning the last
## attempt is how a player ends up on a level that cannot be finished.
func generate(colors: int, empty_tubes: int, rng: MechRng,
		attempts: int = 40, budget: int = 20000) -> bool:
	if colors < 1 or empty_tubes < 1:
		return false
	for _attempt in attempts:
		var pool: Array = []
		for c in colors:
			for _i in capacity:
				pool.append(c)
		rng.shuffle(pool)

		tubes = []
		var cursor := 0
		for _i in colors:
			var stack: Array = []
			for _j in capacity:
				stack.append(pool[cursor])
				cursor += 1
			tubes.append(stack)
		for _i in empty_tubes:
			tubes.append([])
		moves = 0

		# A deal that is already finished is not a puzzle.
		if is_solved():
			continue
		if solvable(budget):
			return true
	tubes = []
	return false


## How hard the board is, as the length of the solution the solver found.
##
## A weak measure and labelled as one: it is the length of *a* solution, not the
## shortest, so it ranks boards roughly rather than exactly. It is still far
## better than counting colours, which is what difficulty is usually based on
## and which says nothing about how tangled a particular deal is.
func rough_difficulty(budget: int = 20000) -> int:
	return solve(budget).size()


func state() -> Dictionary:
	return {
		"tubes": tubes.size(),
		"capacity": capacity,
		"moves": moves,
		"solved": is_solved(),
		"stuck": is_stuck(),
		"legal_moves": legal_moves().size(),
	}


func to_dict() -> Dictionary:
	var rows: Array = []
	for stack in tubes:
		rows.append((stack as Array).duplicate())
	return {"capacity": capacity, "tubes": rows, "moves": moves}


func apply(data: Dictionary) -> bool:
	if not data.has("capacity") or not data.has("tubes"):
		return false
	if typeof(data["tubes"]) != TYPE_ARRAY:
		return false
	var cap := int(data["capacity"])
	if cap < 2:
		return false
	var restored: Array = []
	for row in data["tubes"]:
		if typeof(row) != TYPE_ARRAY:
			return false
		var stack: Array = []
		for v in row:
			stack.append(int(v))
		if stack.size() > cap:
			return false
		restored.append(stack)
	capacity = cap
	tubes = restored
	moves = int(data.get("moves", 0))
	return true


# --- internals ------------------------------------------------------------

## A canonical key for this position.
##
## The tubes are sorted, so two boards holding the same multiset of tubes are
## one position however they are ordered on screen. This is the difference
## between a search that finishes and one that does not: the research measured
## the same real board at 773 iterations with a plain search and 381 with a
## permutation-invariant one.
func _key() -> String:
	var parts: Array[String] = []
	for stack in tubes:
		parts.append(",".join((stack as Array).map(func(v): return str(v))))
	parts.sort()
	return "|".join(parts)


func _search(visited: Dictionary, path: Array[Vector2i], budget: int, examined: Array) -> bool:
	if is_solved():
		return true
	if examined[0] >= budget:
		return false
	examined[0] += 1

	var key := _key()
	if visited.has(key):
		return false
	visited[key] = true

	for step in legal_moves():
		var amount := move(step.x, step.y)
		if amount == 0:
			continue
		path.append(step)
		if _search(visited, path, budget, examined):
			return true
		path.pop_back()
		_undo(step.x, step.y, amount)
		moves -= 1
	return false


## Pour `amount` back. Only ever called on a move this search just made, so the
## colours being moved back are known to be contiguous on top of the
## destination.
func _undo(from: int, to: int, amount: int) -> void:
	var source: Array = tubes[from]
	var destination: Array = tubes[to]
	for _i in amount:
		source.append(destination.pop_back())
