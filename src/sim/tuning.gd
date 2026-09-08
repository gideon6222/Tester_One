class_name Tuning
extends RefCounted

## Every number that shapes how it feels, in one place, plus the arithmetic
## derived from it.
##
## Pure: nothing here reads live state. That is what lets `test/` check the
## shape of the curves - which is what a balance change accidentally breaks -
## without booting a game.

# --- the track ---
const LANE_HALF_WIDTH := 2.6      ## how far from centre the player may go
const FORWARD_SPEED := 12.0       ## metres per second at level 1
const STEER_RATE := 9.0           ## exponential smoothing rate toward the target lane
const CHUNK := 8.0                ## metres between spawn decisions
const CHUNKS_PER_LEVEL := 40      ## a level is 40 chunks, then the finish

# --- the player ---
const START_LIVES := 3
const PLAYER_RADIUS := 0.55
const HIT_COOLDOWN := 0.6         ## seconds of immunity after a hit

# --- what is on the track ---
const OBSTACLE_CHANCE := 0.55     ## of chunks that hold an obstacle at all
const PICKUP_CHANCE := 0.45
const OBSTACLE_RADIUS := 0.7
const PICKUP_RADIUS := 0.9
const PICKUP_SCORE := 10

# --- how it scales ---
const LEVEL_SPEED_STEP := 1.06    ## speed per level
const LEVEL_DENSITY_STEP := 1.05  ## obstacle density per level


## Speed compounds per level, and it is the only difficulty knob that moves on
## its own. Anything else that scales should be checked against this one: if a
## threat grows faster than the player's ability to react, the ladder ends.
static func speed_for(level: int) -> float:
	return FORWARD_SPEED * pow(LEVEL_SPEED_STEP, level - 1)


static func obstacle_chance_for(level: int) -> float:
	return minf(0.9, OBSTACLE_CHANCE * pow(LEVEL_DENSITY_STEP, level - 1))


## How long a level takes at its own speed. Used by the tests to assert the
## level is a sane length rather than to drive anything.
static func level_seconds(level: int) -> float:
	return (CHUNK * CHUNKS_PER_LEVEL) / speed_for(level)
