class_name MechLightField
extends RefCounted

## Light that travels along a tunnel instead of through rock.
##
## Ported from Coreward's `src/sim/light.ts`, which Gideon named as the thing he
## wanted reusable, and which earned one of only two explicit design approvals in
## eight games of playtest logs: *"the face of the rock looks decent as far as
## how the soft light shows"*.
##
## ## The idea in one line
##
## Light is only allowed to travel through open cells, so the distance that
## matters is the distance ALONG THE PASSAGE, not the straight line across the
## rock in between.
##
## That single rule produces everything this is supposed to say:
##
## - a shaft you have dug is lit all the way down, because the path is short
## - a side branch is dim, because the light went round a corner and its path is
##   longer than the straight line
## - rock you have never opened is black, because there is no path to it at all
##
## ## What is stored is DETOUR, not brightness
##
## Each cell holds how much LONGER the light's actual path was than a clear run
## through open air would have been. Distance falloff is deliberately not in
## here: it belongs in the shader, computed per pixel from the lamp's exact
## position, because the lamp moves continuously and this grid does not.
##
## **Splitting it that way is the whole trick.** Put the falloff in the grid and
## the pool of light visibly steps from cell to cell as the player moves, which
## reads as the lighting being low resolution rather than as the world being
## dark. The renderer side of that split is `recipes/tunnel-lighting.md`.
##
## ## Where else this goes
##
## It is a visibility solve on a grid with a detour cost, so it is not really
## about light. The same call answers "how far is this from the player through
## the actual passages", which is a stealth cone, a sound propagation, a scent
## trail, or a flood-fill AI that should not path through walls.

const DIAG := 1.4142135623730951

## The eight neighbours, orthogonals first so the cheap steps are tried before
## the diagonals and the heap does less work.
const NX := [1, -1, 0, 0, 1, 1, -1, -1]
const NY := [0, 0, 1, -1, 1, -1, 1, -1]

var cols: int = 0
var rows: int = 0

## How fast light dies per unit of DETOUR. Not per unit of distance.
var att: float = 0.55
## Extra cost for a diagonal that has to slip past one rock corner.
var pinch: float = 0.35
## What one step of travel THROUGH rock costs on top of its geometry.
var solid_step: float = 2.0

var _dist := PackedFloat32Array()
var _seen := PackedByteArray()
var _field := PackedFloat32Array()
var _heap := PackedInt32Array()
var _heap_size: int = 0


func _init(grid_cols: int = 0, grid_rows: int = 0) -> void:
	resize(grid_cols, grid_rows)


func resize(grid_cols: int, grid_rows: int) -> void:
	cols = maxi(grid_cols, 0)
	rows = maxi(grid_rows, 0)
	var n := cols * rows
	_dist.resize(n)
	_seen.resize(n)
	_field.resize(n)
	# Every cell can be pushed once per neighbour that improves it. Eight per
	# cell plus slack is the bound the source used and it has never been hit.
	_heap.resize(n * 8 + 8)
	_heap_size = 0
	_field.fill(0.0)


## Feel constants are written in CELLS, because that is the unit a person can
## picture. A solve at `sub` samples per cell needs them in sub-cells.
##
## Two conversions, both one line, done here rather than at three call sites:
## `att` is per unit of detour and a detour in sub-cells is `sub` times the same
## detour in cells; `solid_step` falls out of the seep, because travelling one
## whole CELL through rock must leave `exp(-att * step)` equal to the per-cell
## seep, and that works out the same whatever the sampling is.
##
## `sub = 1` gives cell-unit behaviour, which is what the tests use: they are
## about the geometry, not the resolution.
func set_feel(cell_att: float, corner_pinch: float, per_cell_seep: float, sub: int = 1) -> void:
	var samples := float(maxi(sub, 1))
	var a := maxf(cell_att, 0.0001)
	att = a / samples
	pinch = maxf(corner_pinch, 0.0)
	solid_step = -log(clampf(per_cell_seep, 0.000001, 0.999999)) / a


## The shortest clear-air path between two cells when movement is eight-way.
##
## **Subtracting the RIGHT baseline is why open space comes out at full
## brightness.** Use the Euclidean distance here instead and every distant cell
## looks slightly occluded by nothing at all, which reads as a dirty lens.
static func octile(dx: float, dy: float) -> float:
	var ax := absf(dx)
	var ay := absf(dy)
	return maxf(ax, ay) + (DIAG - 1.0) * minf(ax, ay)


## Solve the whole grid from a lamp at cell (si, sj).
##
## `solid` is row-major, non-zero for rock and zero for open. Returns the
## visibility field, 0..1 per cell, which is reused between calls rather than
## reallocated: solving at 60 Hz on a phone with a fresh array each time is pure
## garbage collection.
##
## A lamp outside the grid returns an all-black field rather than clamping to an
## edge cell, because a lamp off the edge genuinely lights nothing and pretending
## otherwise puts a bright patch in the corner of the screen.
func solve(solid: PackedByteArray, si: int, sj: int) -> PackedFloat32Array:
	var n := cols * rows
	if n == 0 or solid.size() < n:
		return _field

	_field.fill(0.0)
	if si < 0 or si >= cols or sj < 0 or sj >= rows:
		return _field

	for i in n:
		_dist[i] = INF
		_seen[i] = 0
	_heap_size = 0

	var src := sj * cols + si
	_dist[src] = 0.0
	_push(src)

	while _heap_size > 0:
		var c := _pop()
		if _seen[c] != 0:
			continue
		_seen[c] = 1

		var j := c / cols
		var i := c - j * cols
		# Reached, so it gets a value. Then, if it is rock, the walk ends here.
		var detour := maxf(0.0, _dist[c] - octile(float(i - si), float(j - sj)))
		_field[c] = exp(-att * detour)
		var from_rock := solid[c] != 0

		for k in 8:
			var dx: int = NX[k]
			var dy: int = NY[k]
			var ni := i + dx
			var nj := j + dy
			if ni < 0 or ni >= cols or nj < 0 or nj >= rows:
				continue
			var nc := nj * cols + ni
			if _seen[nc] != 0:
				continue
			# THE rule: rock never lights open air.
			#
			# It does two jobs. It keeps a sealed cave sealed, because otherwise
			# a one-cell wall leaks a third of the lamp into the chamber behind
			# it and the shadow the player is reading is a lie. And it turns the
			# fade into the mass into a distance transform that falls out of the
			# same solve, at whatever resolution the grid happens to be.
			if from_rock and solid[nc] == 0:
				continue

			var step := 0.0
			if dx == 0 or dy == 0:
				step = 1.0
			elif from_rock:
				# Inside the mass every neighbour is rock, so the corner rule
				# below would forbid every diagonal and the fade would come out
				# diamond shaped.
				step = DIAG
			else:
				# Both corners rock is a diagonal crack, and light does not
				# squeeze through a crack with no opening. One corner rock is
				# grazing an edge: it costs, but it is allowed, because without
				# that a light turning a corner arrives as a hard diagonal line.
				var a := solid[j * cols + ni]
				var b := solid[nj * cols + i]
				if a != 0 and b != 0:
					continue
				step = DIAG + (pinch if (a != 0 or b != 0) else 0.0)

			# Entering the FIRST wall is free of this: that face is the surface
			# the lamp is falling on. Only rock-to-rock pays.
			if from_rock:
				step += solid_step

			var nd := _dist[c] + step
			if nd < _dist[nc]:
				_dist[nc] = nd
				_push(nc)

	return _field


## The last solved field. Same array `solve` returns.
func field() -> PackedFloat32Array:
	return _field


func value_at(i: int, j: int) -> float:
	if i < 0 or i >= cols or j < 0 or j >= rows:
		return 0.0
	return _field[j * cols + i]


## Scroll the solved field to follow a moving window.
##
## The grid covers a fixed number of rows around the player, so descending one
## metre moves every cell's meaning up one row. Without this the smoothed field
## keeps applying the old row's value to the new row's cell and the whole thing
## smears in the direction of travel as you dig.
##
## Rows shifted in from outside are CLEARED rather than guessed. They are off the
## end of the streamed terrain, nothing is looking at them yet, and the next
## solve fills them before anything does. A guess here is a bright band at the
## edge of the world that arrives one frame before the real values.
func shift(n: int) -> void:
	if n == 0 or rows == 0:
		return
	if absi(n) >= rows:
		_field.fill(0.0)
		return
	if n > 0:
		# The window moved down: row n becomes row 0.
		for j in range(0, rows - n):
			for i in cols:
				_field[j * cols + i] = _field[(j + n) * cols + i]
		for j in range(rows - n, rows):
			for i in cols:
				_field[j * cols + i] = 0.0
	else:
		var m := -n
		for j in range(rows - 1, m - 1, -1):
			for i in cols:
				_field[j * cols + i] = _field[(j - m) * cols + i]
		for j in m:
			for i in cols:
				_field[j * cols + i] = 0.0


func state() -> Dictionary:
	var lit := 0
	var total := 0.0
	for v in _field:
		if v > 0.01:
			lit += 1
		total += v
	return {
		"cols": cols,
		"rows": rows,
		"att": snappedf(att, 0.0001),
		"pinch": snappedf(pinch, 0.0001),
		"solid_step": snappedf(solid_step, 0.0001),
		"lit_cells": lit,
		"total_light": snappedf(total, 0.001),
	}


# --- the heap -------------------------------------------------------------
#
# A binary heap over cell indices, keyed by `_dist`. Written out rather than
# reached for because the whole solver is one array walk and any dependency here
# would be most of the module.

func _push(v: int) -> void:
	if _heap_size >= _heap.size():
		return  # cannot happen: the cap is cells * 8 + 8
	var i := _heap_size
	_heap[i] = v
	_heap_size += 1
	while i > 0:
		var p := (i - 1) >> 1
		if _dist[_heap[p]] <= _dist[_heap[i]]:
			break
		var t := _heap[p]
		_heap[p] = _heap[i]
		_heap[i] = t
		i = p


func _pop() -> int:
	var top := _heap[0]
	_heap_size -= 1
	_heap[0] = _heap[_heap_size]
	var i := 0
	while true:
		var l := i * 2 + 1
		var r := l + 1
		var s := i
		if l < _heap_size and _dist[_heap[l]] < _dist[_heap[s]]:
			s = l
		if r < _heap_size and _dist[_heap[r]] < _dist[_heap[s]]:
			s = r
		if s == i:
			break
		var t := _heap[s]
		_heap[s] = _heap[i]
		_heap[i] = t
		i = s
	return top
