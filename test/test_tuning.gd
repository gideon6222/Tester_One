extends RefCounted

## Design tests: assertions about *intent* rather than about values.
##
## A snapshot of the constants pins the numbers but says nothing about what
## they are for. These say what the numbers have to remain true of, so a
## balance change that breaks the shape of the game fails here rather than in
## a playtest three weeks later.


func test_difficulty_compounds_but_stays_playable(t: TestHarness) -> void:
	t.gt(Tuning.LEVEL_SPEED_STEP, 1.0, "levels must get harder or there is no ladder")
	t.lt(Tuning.LEVEL_SPEED_STEP, 1.25, "a steeper curve than this outruns a human inside five levels")
	t.eq(Tuning.speed_for(1), Tuning.FORWARD_SPEED, "level 1 is the unscaled baseline")
	t.gt(Tuning.speed_for(10), Tuning.speed_for(1), "level 10 must be faster than level 1")


func test_obstacle_density_has_a_ceiling(t: TestHarness) -> void:
	# Without a cap, a high enough level puts an obstacle in every chunk, and
	# an unavoidable wall is not difficulty - it is the end of the game with
	# extra steps.
	t.lt(Tuning.obstacle_chance_for(50), 1.0, "density must never reach every chunk")
	t.gt(Tuning.obstacle_chance_for(10), Tuning.obstacle_chance_for(1), "density must climb")


func test_a_level_is_a_sane_length(t: TestHarness) -> void:
	# Long enough to build something, short enough to retry without groaning.
	var first := Tuning.level_seconds(1)
	t.gt(first, 15.0, "a level under fifteen seconds is a menu with scenery")
	t.lt(first, 90.0, "a level over ninety seconds makes a death expensive enough to stop playing")


func test_the_player_can_cross_the_track_faster_than_it_arrives(t: TestHarness) -> void:
	# The one relationship that decides whether the game is fair: at the moment
	# an obstacle becomes visible, is there time to be somewhere else? If
	# steering is slower than the track scrolls, no amount of skill helps.
	var seconds_to_cross := 1.0 / Tuning.STEER_RATE * 3.0  # ~3 time constants, corner to corner
	var seconds_of_warning := 60.0 / Tuning.speed_for(1)   # the visible horizon
	t.gt(seconds_of_warning, seconds_to_cross * 2.0,
		"an obstacle arrives faster than the player can cross the lane - the game is unfair by construction")


func test_a_pickup_is_reachable_but_not_free(t: TestHarness) -> void:
	t.gt(Tuning.PICKUP_RADIUS, 0.0, "a pickup with no radius can never be collected")
	t.lt(Tuning.PICKUP_RADIUS, Tuning.LANE_HALF_WIDTH,
		"a pickup wider than half the lane is collected by standing still")


func test_a_hit_costs_something_and_gives_a_moment_back(t: TestHarness) -> void:
	t.gt(float(Tuning.START_LIVES), 1.0, "one life makes the first mistake the last one")
	t.gt(Tuning.HIT_COOLDOWN, 0.0,
		"without immunity after a hit, one obstacle takes every life in a single frame")
