extends RefCounted

## The random source, tested directly rather than through what it produces.
##
## This file exists because of a specific failure on the sibling web game: the
## same hash used signed right shifts, so it could never return above 0.5 -
## measured maximum 0.499999 over 800,000 samples. Nothing errored. Three
## mechanics whose spawn rolls compared against thresholds above a half had
## never once fired in the whole life of that game, and it failed as *absence*,
## which is the one failure mode a playtest cannot see.
##
## So: assert the range, assert the distribution, and assert that the specific
## thresholds this game compares against can actually come up.


func test_smoothing_is_frame_rate_independent(t: TestHarness) -> void:
	# The property that matters is that the same real time produces the same
	# movement however it is sliced into frames. A naive `t * rate` fails this
	# and drifts on a 120 Hz phone.
	var step := func(n: int, dt: float) -> float:
		var v := 0.0
		for i in n:
			v += (1.0 - v) * SimUtil.smooth(6.0, dt)
		return v
	var at60: float = step.call(60, 1.0 / 60.0)
	var at120: float = step.call(120, 1.0 / 120.0)
	var at30: float = step.call(30, 1.0 / 30.0)
	t.approx(at120, at60, 0.001, "60Hz and 120Hz must land in the same place")
	t.approx(at30, at60, 0.001, "30Hz and 60Hz must land in the same place")


func test_smoothing_saturates_but_never_overshoots(t: TestHarness) -> void:
	t.eq(SimUtil.smooth(6.0, 0.0), 0.0, "a zero delta must move nothing")
	t.ok(SimUtil.smooth(6.0, 10.0) <= 1.0, "a long frame must not overshoot its target")
	t.gt(SimUtil.smooth(6.0, 10.0), 0.99, "a long frame should very nearly arrive")


func test_hash_is_deterministic(t: TestHarness) -> void:
	for a in range(-3, 40):
		for b in range(0, 8):
			t.eq(SimUtil.hash2(a, b), SimUtil.hash2(a, b), "hash(%d,%d) changed between calls" % [a, b])


## THE regression test in this file.
func test_hash_covers_the_whole_unit_interval_evenly(t: TestHarness) -> void:
	var deciles := PackedInt32Array()
	deciles.resize(10)
	var n := 0
	var lo := 1.0
	var hi := 0.0
	for a in range(-400, 400):
		for b in range(0, 60):
			var v := SimUtil.hash2(a, b)
			deciles[int(v * 10.0)] += 1
			lo = minf(lo, v)
			hi = maxf(hi, v)
			n += 1
	t.gt(hi, 0.999, "hash never returned above %f - a signed shift is clearing the top bit" % hi)
	t.lt(lo, 0.001, "hash never returned below %f" % lo)
	for d in 10:
		var pct := float(deciles[d]) / float(n) * 100.0
		t.approx(pct, 10.0, 1.5, "decile %d holds %.2f%% of samples" % [d, pct])


## Every threshold the game actually compares a hash against, checked against
## the source rather than against the spawn it produces.
func test_the_thresholds_the_game_uses_can_all_fire(t: TestHarness) -> void:
	var fires := func(threshold: float) -> int:
		var hit := 0
		for c in 200:
			if SimUtil.hash2(c, 91) < threshold:
				hit += 1
		return hit
	t.gt(fires.call(Tuning.OBSTACLE_CHANCE), 60, "obstacles can never spawn")
	t.gt(fires.call(Tuning.PICKUP_CHANCE), 50, "pickups can never spawn")
	# and the inverse: a threshold must not fire every single time either
	t.lt(fires.call(Tuning.PICKUP_CHANCE), 200, "pickups spawn in literally every chunk")


func test_a_seeded_stream_replays_and_two_seeds_differ(t: TestHarness) -> void:
	var a := SimRng.new(7)
	var b := SimRng.new(7)
	var c := SimRng.new(8)
	var same := true
	var differs := false
	for i in 200:
		var av := a.next()
		if av != b.next():
			same = false
		if av != c.next():
			differs = true
	t.ok(same, "the same seed must replay the same stream")
	t.ok(differs, "a different seed must give a different stream")


func test_a_seeded_stream_is_uniform_and_does_not_repeat(t: TestHarness) -> void:
	var r := SimRng.new(3)
	var seen := {}
	var n := 4000
	for i in n:
		var v := r.next()
		t.ok(v >= 0.0 and v < 1.0, "%f out of range at draw %d" % [v, i])
		seen[v] = true
	# A stream that cycles would silently make every burst identical.
	t.gt(float(seen.size()), float(n) * 0.99, "only %d distinct values in %d draws" % [seen.size(), n])


func test_fmt_keeps_the_readout_narrow(t: TestHarness) -> void:
	t.eq(SimUtil.fmt(0.0), "0", "zero")
	t.eq(SimUtil.fmt(999.0), "999", "under a thousand is exact")
	t.eq(SimUtil.fmt(1000.0), "1.0K", "thousands take a decimal")
	t.eq(SimUtil.fmt(10000.0), "10K", "five figures drop it again so the width holds")
	t.eq(SimUtil.fmt(1000000.0), "1.0M", "millions")
