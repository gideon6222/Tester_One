class_name Sim
extends RefCounted

## The whole game, with no renderer in it.
##
## This is the shape that everything else in the repo depends on. `Sim` owns
## every number that decides what happens; the scene in `src/game/` reads those
## numbers and draws them, and never the other way round. Two things fall out
## of that, and both are worth more than they cost:
##
## 1. `test/` can play a whole level in milliseconds with no window, no GPU and
##    no scene tree - so a golden test over an entire run is possible, which is
##    a far stronger safety net than testing any single function.
## 2. Rendering can be rewritten, or replaced entirely, without touching a line
##    of game logic.
##
## The rule that keeps it true: **nothing in this file may reference a Node, a
## Viewport, an input event or a delta that came from a real frame.** If it
## needs to know something about the world, it takes it as an argument.

signal picked_up(x: float, z: float)
signal hit_obstacle(x: float, z: float)
signal level_finished(won: bool)

var level: int = 1
var lives: int = Tuning.START_LIVES
var score: int = 0
var distance: float = 0.0        ## metres travelled this level
var x: float = 0.0               ## lateral position
var target_x: float = 0.0        ## where the player is steering to
var over: bool = false
var won: bool = false
var time: float = 0.0
var hit_timer: float = 0.0

## Live entities. Each is {x, z, taken} - plain dictionaries rather than nodes,
## because a node here would drag the scene tree into the test runner.
var obstacles: Array[Dictionary] = []
var pickups: Array[Dictionary] = []

## Every decision in this game is keyed on a place - which chunk, which level -
## so they all go through `SimUtil.hash2` and there is no need for a stream.
## `SimRng` exists for the games built from this template, where there usually
## is one: anything whose value decides *when* something happens (scatter
## velocity, flight time) must come from a seeded stream rather than randf(),
## or the golden below starts flaking. See its own docs for the full rule.
var _chunk_spawned: int = -1


func _init(start_level: int = 1) -> void:
	restart(start_level)


## Full reset. Called at boot and between levels; the test harness calls it to
## get a clean, identical starting state on any machine.
func restart(start_level: int = 1) -> void:
	level = start_level
	lives = Tuning.START_LIVES
	score = 0
	distance = 0.0
	x = 0.0
	target_x = 0.0
	over = false
	won = false
	time = 0.0
	hit_timer = 0.0
	obstacles.clear()
	pickups.clear()
	# Spawning is seeded on (chunk, level), so level 3 is the same level 3
	# every time it is played, on any device.
	_chunk_spawned = -1


## The next level, keeping what the RUN owns rather than what the LEVEL owns.
##
## **This function is why the template has it at all.** A game built from an
## earlier version of this repo emitted `level_finished` and had nothing
## connected to it - so `over` went true at the end of the first level,
## `advance()` returned early from then on, and the game sat frozen with a live
## HUD. To the person holding the phone that is indistinguishable from a crash,
## and it was the first thing they hit.
##
## Decide deliberately what carries across: score usually does, lives and
## position usually do not.
func next_level() -> void:
	var carried := score
	restart(level + 1)
	score = carried


## One step. `dt` is seconds; the caller decides whether that came from a real
## frame or from a test stepping at a fixed rate, and the result is identical
## either way.
func advance(dt: float) -> void:
	if over:
		return

	time += dt
	if hit_timer > 0.0:
		hit_timer -= dt

	var speed := Tuning.speed_for(level)
	distance += speed * dt

	# Steering is smoothed rather than snapped, and the smoothing is
	# frame-rate independent - see SimUtil.smooth for why that matters.
	x = lerpf(x, target_x, SimUtil.smooth(Tuning.STEER_RATE, dt))
	x = clampf(x, -Tuning.LANE_HALF_WIDTH, Tuning.LANE_HALF_WIDTH)

	_spawn_ahead()
	_collide()
	_retire_passed()

	if distance >= Tuning.CHUNK * Tuning.CHUNKS_PER_LEVEL:
		over = true
		won = true
		level_finished.emit(true)


## Steer toward a lateral position. The only input the simulation accepts.
func steer_to(new_target_x: float) -> void:
	target_x = clampf(new_target_x, -Tuning.LANE_HALF_WIDTH, Tuning.LANE_HALF_WIDTH)


## Everything a harness or a HUD needs, in one dictionary.
##
## Deliberately flat and all-scalar: a golden test asserts this whole thing at
## once, and a nested structure would make a one-field change unreadable in the
## diff.
func state() -> Dictionary:
	return {
		"level": level,
		"lives": lives,
		"score": score,
		"distance": snappedf(distance, 0.001),
		"x": snappedf(x, 0.001),
		"obstacles": obstacles.size(),
		"pickups": pickups.size(),
		"over": over,
		"won": won,
	}


# --- internals ------------------------------------------------------------

## Spawn decisions are keyed on (chunk, level) through the hash, never on the
## rng stream, so they do not shift when something unrelated draws a value.
## Anything that consumes the stream out of order changes every later value.
func _spawn_ahead() -> void:
	var horizon := distance + 60.0
	var last_chunk := int(horizon / Tuning.CHUNK)
	while _chunk_spawned < last_chunk:
		_chunk_spawned += 1
		_spawn_chunk(_chunk_spawned)


func _spawn_chunk(c: int) -> void:
	if c < 2:
		return  # a couple of empty chunks so the player is never hit on frame one
	var z := float(c) * Tuning.CHUNK

	if SimUtil.hash2(c, 91 + level) < Tuning.obstacle_chance_for(level):
		obstacles.append({
			"x": _lane_x(SimUtil.hash2(c, 300 + level)),
			"z": z,
			"taken": false,
		})

	# A separate seed offset, so adding or removing obstacles does not move
	# every pickup. Sharing an offset is the classic way a small content change
	# turns into a total reshuffle of the world.
	if SimUtil.hash2(c, 555 + level) < Tuning.PICKUP_CHANCE:
		pickups.append({
			"x": _lane_x(SimUtil.hash2(c, 700 + level)),
			"z": z + Tuning.CHUNK * 0.5,
			"taken": false,
		})


## Places inside the reachable lane, never across the full width of the road
## mesh. Anything the player must reach or dodge goes through here.
func _lane_x(unit: float) -> float:
	return (unit - 0.5) * 2.0 * Tuning.LANE_HALF_WIDTH


func _collide() -> void:
	for p in pickups:
		if p.taken:
			continue
		if absf(p.z - distance) < Tuning.PICKUP_RADIUS and absf(p.x - x) < Tuning.PICKUP_RADIUS:
			p.taken = true
			score += Tuning.PICKUP_SCORE
			picked_up.emit(p.x, p.z)

	if hit_timer > 0.0:
		return
	for o in obstacles:
		if o.taken:
			continue
		var reach := Tuning.OBSTACLE_RADIUS + Tuning.PLAYER_RADIUS
		if absf(o.z - distance) < reach and absf(o.x - x) < reach:
			o.taken = true
			lives -= 1
			hit_timer = Tuning.HIT_COOLDOWN
			hit_obstacle.emit(o.x, o.z)
			if lives <= 0:
				over = true
				won = false
				level_finished.emit(false)
			return


## Entities behind the player are dropped. Without this the arrays grow for the
## whole level and every collision check gets slower as the run goes on - which
## reads as "the game slows down near the end" and gets blamed on rendering.
func _retire_passed() -> void:
	var cutoff := distance - 12.0
	obstacles = obstacles.filter(func(o): return o.z > cutoff)
	pickups = pickups.filter(func(p): return p.z > cutoff)
