extends RefCounted

## Behaviour of the simulation, tested by playing it - with no window, no GPU
## and no scene tree, because `Sim` has no idea any of those exist.


func test_a_fresh_sim_starts_where_it_should(t: TestHarness) -> void:
	var s := Sim.new()
	t.eq(s.level, 1, "level")
	t.eq(s.lives, Tuning.START_LIVES, "lives")
	t.eq(s.score, 0, "score")
	t.eq(s.over, false, "a fresh run is not over")


func test_time_moves_the_player_forward(t: TestHarness) -> void:
	var s := Sim.new()
	s.advance(1.0)
	t.approx(s.distance, Tuning.speed_for(1), 0.2, "one second should cover one second of track")


func test_steering_is_smoothed_and_clamped(t: TestHarness) -> void:
	var s := Sim.new()
	s.steer_to(999.0)
	t.approx(s.target_x, Tuning.LANE_HALF_WIDTH, 0.001, "steering past the edge must clamp")
	# Smoothed, so one frame does not teleport the player to the target.
	var before := s.x
	s.advance(1.0 / 60.0)
	t.gt(s.x, before, "the player should move toward the target")
	t.lt(s.x, s.target_x, "the player should not arrive in a single frame")


func test_the_track_is_populated(t: TestHarness) -> void:
	var s := Sim.new()
	s.advance(2.0)
	t.gt(float(s.obstacles.size()), 0.0, "no obstacles were spawned in the first two seconds")
	t.gt(float(s.pickups.size()), 0.0, "no pickups were spawned in the first two seconds")


## The counterpart to the threshold test in test_util: not just "can the roll
## fire" but "does the mechanic actually occur in a played run".
func test_both_kinds_of_thing_occur_across_several_levels(t: TestHarness) -> void:
	var seen_obstacle := false
	var seen_pickup := false
	for level in range(1, 5):
		var s := Sim.new(level)
		for i in 600:
			s.advance(1.0 / 60.0)
			if not s.obstacles.is_empty():
				seen_obstacle = true
			if not s.pickups.is_empty():
				seen_pickup = true
			if s.over:
				break
	t.ok(seen_obstacle, "no obstacle appeared in four whole levels")
	t.ok(seen_pickup, "no pickup appeared in four whole levels")


func test_running_into_things_costs_lives_and_ends_the_run(t: TestHarness) -> void:
	# Driven down the middle with no steering, which on this seed is fatal.
	var s := Sim.new()
	for i in 4000:
		s.advance(1.0 / 60.0)
		if s.over:
			break
	t.ok(s.over, "a run must end one way or the other")
	if not s.won:
		t.eq(s.lives, 0, "a lost run ends at zero lives")


func test_immunity_stops_one_obstacle_taking_every_life(t: TestHarness) -> void:
	var s := Sim.new()
	var lost_in_one_frame := false
	var last := s.lives
	for i in 4000:
		s.advance(1.0 / 60.0)
		if last - s.lives > 1:
			lost_in_one_frame = true
		last = s.lives
		if s.over:
			break
	t.ok(not lost_in_one_frame, "more than one life was lost in a single frame")


## Entities behind the player must be dropped, or the arrays grow for the whole
## level and every collision check gets slower as the run goes on - which reads
## as "the game slows down near the end" and gets blamed on rendering.
func test_passed_entities_are_retired(t: TestHarness) -> void:
	var s := Sim.new()
	for i in 900:
		s.advance(1.0 / 60.0)
		if s.over:
			break
	t.lt(float(s.obstacles.size()), 40.0, "obstacles are accumulating instead of being retired")
	t.lt(float(s.pickups.size()), 40.0, "pickups are accumulating instead of being retired")


func test_a_level_can_be_finished(t: TestHarness) -> void:
	# Steered onto a clear line rather than left to crash, to prove the win
	# path exists at all.
	var s := Sim.new()
	for i in 6000:
		# park in whichever half currently has no obstacle in front
		var danger := 0.0
		for o in s.obstacles:
			if not o.taken and o.z > s.distance and o.z < s.distance + 14.0:
				danger = o.x
				break
		s.steer_to(-Tuning.LANE_HALF_WIDTH if danger > 0.0 else Tuning.LANE_HALF_WIDTH)
		s.advance(1.0 / 60.0)
		if s.over:
			break
	t.ok(s.over, "the run should have ended within a hundred seconds")
	t.ok(s.won, "a player who dodges should be able to finish level 1")


## Playing well must beat not playing. If it does not, the mechanic is
## decoration - which is exactly what happened on another game here, where four
## completely different play styles scored identically.
func test_dodging_beats_standing_still(t: TestHarness) -> void:
	var passive := Sim.new()
	for i in 6000:
		passive.advance(1.0 / 60.0)
		if passive.over:
			break

	var active := Sim.new()
	for i in 6000:
		var danger := 0.0
		for o in active.obstacles:
			if not o.taken and o.z > active.distance and o.z < active.distance + 14.0:
				danger = o.x
				break
		active.steer_to(-Tuning.LANE_HALF_WIDTH if danger > 0.0 else Tuning.LANE_HALF_WIDTH)
		active.advance(1.0 / 60.0)
		if active.over:
			break

	t.gt(active.distance, passive.distance,
		"steering got no further than never touching the screen - dodging is decoration")
