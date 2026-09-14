class_name MechMerge
extends RefCounted

## The 2048 board: slide everything one way, merge equal neighbours, spawn one
## new tile.
##
## Tiles are stored as TIERS, not as face values. Tier 1 is the tile printed
## "2", tier 2 is "4", tier 11 is "2048". Two reasons, and the second one is the
## one that bites:
##
## 1. A merge is `tier + 1`, which is simpler and exact, where doubling a face
##    value is an unbounded integer that eventually stops being representable.
## 2. **The face values are a theme, not the mechanic.** The same board with the
##    same rules is 2048 with powers of two printed on it, a merge game with
##    animals, or Threes with a different spawn rule. Storing tiers keeps the
##    rule and the skin separate, so the skin can change without anyone touching
##    the merge logic.
##
## Empty is tier 0.
##
## ## The rule everybody gets wrong
##
## **A tile may only merge once per move.** Sliding `[2,2,4]` left gives
## `[4,4]`, never `[8]`. Without that guard a row of four identical tiles
## collapses to one in a single move, the board empties itself, and the game
## becomes unloseable. The guard is `_merged_at` below and it is asserted
## directly, because it is invisible until somebody lines up four of a kind.

signal merged(tier: int, at: Vector2i)   ## the NEW tier, at its resting cell
signal spawned(tier: int, at: Vector2i)

const UP := Vector2i(0, -1)
const DOWN := Vector2i(0, 1)
const LEFT := Vector2i(-1, 0)
const RIGHT := Vector2i(1, 0)

## Spawn odds. 2048 spawns a "2" ninety percent of the time and a "4" the rest.
## The single most load-bearing number in the game: raising the chance of the
## higher tile makes the board fill faster and the game shorter, and it is the
## first dial to reach for if a board feels too generous.
const SPAWN_HIGH_CHANCE := 0.10

var size: int = 4
## Row-major, `size * size` entries of tier.
var cells: PackedInt32Array = PackedInt32Array()
var score: int = 0
## The highest tier ever reached this game. The thing the player is actually
## playing for, and the one number that should survive on the results screen.
var best_tier: int = 0
var moves: int = 0


func _init(board_size: int = 4) -> void:
	size = maxi(board_size, 2)
	clear()


func clear() -> void:
	cells = PackedInt32Array()
	cells.resize(size * size)
	score = 0
	best_tier = 0
	moves = 0


## A fresh board with its opening tiles placed.
func start(rng: MechRng, starting_tiles: int = 2) -> void:
	clear()
	for _i in starting_tiles:
		spawn(rng)


func at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= size or y >= size:
		return -1
	return cells[y * size + x]


func set_at(x: int, y: int, tier: int) -> void:
	if x < 0 or y < 0 or x >= size or y >= size:
		return
	cells[y * size + x] = tier
	if tier > best_tier:
		best_tier = tier


## The face value a tier is printed as, for a board themed on powers of two.
static func face_value(tier: int) -> int:
	return 0 if tier <= 0 else 1 << tier


func empty_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in size:
		for x in size:
			if cells[y * size + x] == 0:
				out.append(Vector2i(x, y))
	return out


## Place one new tile in a random empty cell. Returns false if there was no
## room, which is not by itself a game over - see `is_over`.
func spawn(rng: MechRng) -> bool:
	var free := empty_cells()
	if free.is_empty():
		return false
	var cell := free[rng.range_i(0, free.size() - 1)]
	var tier := 2 if rng.chance(SPAWN_HIGH_CHANCE) else 1
	set_at(cell.x, cell.y, tier)
	spawned.emit(tier, cell)
	return true


## Slide the whole board one way, merging as it goes.
##
## Returns the score gained, or -1 if nothing moved at all. **-1 rather than 0
## matters**: a move that changes nothing must not spawn a new tile, or the
## player can fill the board by repeatedly pressing a direction that does
## nothing, and the game ends through no decision of theirs.
func slide(direction: Vector2i) -> int:
	var gained := 0
	var moved := false
	# Which cells have already absorbed a merge this move. The one-merge-per-move
	# rule, and the whole reason this array exists.
	var merged_at := {}

	# Walk each line from the far edge inward, so the tile nearest the wall
	# settles first and everything behind it packs against it.
	for line_index in size:
		var cells_in_line := _line_cells(direction, line_index)
		for i in range(1, cells_in_line.size()):
			var from: Vector2i = cells_in_line[i]
			var tier := at(from.x, from.y)
			if tier == 0:
				continue
			var target := from
			var absorbed := false

			# Slide as far as it will go.
			while true:
				var next := target + direction
				var value := at(next.x, next.y)
				if value == -1:
					break            # the wall
				if value == 0:
					target = next    # keep going through empty space
					continue
				if value == tier and not merged_at.has(next):
					target = next
					absorbed = true
				break                 # blocked, merged or not

			if target == from:
				continue

			set_at(from.x, from.y, 0)
			if absorbed:
				var new_tier := tier + 1
				set_at(target.x, target.y, new_tier)
				merged_at[target] = true
				gained += face_value(new_tier)
				merged.emit(new_tier, target)
			else:
				set_at(target.x, target.y, tier)
			moved = true

	if not moved:
		return -1
	score += gained
	moves += 1
	return gained


## Whether any direction would change anything.
##
## Cheaper than it looks and worth calling rather than inferring: a full board
## is NOT a game over while two equal tiles are adjacent, and a player staring
## at a board with one legal move left is exactly the moment this must be right.
func has_move() -> bool:
	for y in size:
		for x in size:
			var tier := cells[y * size + x]
			if tier == 0:
				return true
			if at(x + 1, y) == tier or at(x, y + 1) == tier:
				return true
	return false


func is_over() -> bool:
	return not has_move()


func state() -> Dictionary:
	return {
		"score": score,
		"moves": moves,
		"best_tier": best_tier,
		"best_value": face_value(best_tier),
		"empty": empty_cells().size(),
		"over": is_over(),
	}


func to_dict() -> Dictionary:
	return {
		"size": size,
		"cells": Array(cells),
		"score": score,
		"best_tier": best_tier,
		"moves": moves,
	}


## Total or false. A board restored at the wrong size, or with a cell count that
## does not match it, would index out of its own array on the first slide.
func apply(data: Dictionary) -> bool:
	for key in ["size", "cells", "score", "best_tier", "moves"]:
		if not data.has(key):
			return false
	var n := int(data["size"])
	if n < 2:
		return false
	var raw: Array = data["cells"]
	if raw.size() != n * n:
		return false
	var restored := PackedInt32Array()
	for v in raw:
		var tier := int(v)
		if tier < 0 or tier > 63:  # 1 << 63 is already past what an int holds
			return false
		restored.append(tier)
	size = n
	cells = restored
	score = int(data["score"])
	best_tier = int(data["best_tier"])
	moves = int(data["moves"])
	return true


# --- internals ------------------------------------------------------------

## The cells of one line, ordered from the wall the tiles are moving toward.
## Index 0 is against the wall, so the loop above can skip it and every tile
## behind it settles in the right order.
func _line_cells(direction: Vector2i, line_index: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for step in size:
		var cell: Vector2i
		if direction == LEFT:
			cell = Vector2i(step, line_index)
		elif direction == RIGHT:
			cell = Vector2i(size - 1 - step, line_index)
		elif direction == UP:
			cell = Vector2i(line_index, step)
		else:  # DOWN
			cell = Vector2i(line_index, size - 1 - step)
		out.append(cell)
	return out
