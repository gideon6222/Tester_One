extends RefCounted

## THE THREE VISUALS TIERS, ANSWERED ON THE DESK.
##
## INDEX.md rule 18: every game ships low, medium and high, low is aimed at a
## 2021 flagship, and low never caps what the game is. This suite is what makes
## the rule a gate rather than a sentence:
##
##   1. The three tiers exist under exactly those names, in that order.
##   2. Each tier costs no more than the next on every setting, with at least
##      one strict step, so "medium is slower than low" cannot ship.
##   3. The player's choice round-trips through the pure pair, and the pair
##      REFUSES a name that is not a tier rather than substituting high.
##   4. The budget arithmetic: a low-tier reading on the S26 predicts the floor
##      phone through `FLOOR_RATIO`, and a reading over budget says so.
##   5. A reading's duty cycle decides whether a thermal soak is owed.
##
## No window, no file, no phone. `run_smoke.gd` covers the renderer side by
## applying each tier to the real viewport and reading the settings back.

var _t: TestHarness


func test_low_medium_and_high_exist_in_that_order(t: TestHarness) -> void:
	_t = t
	_t.eq(Visuals.ORDER, ["low", "medium", "high"], "the tier order is not low, medium, high")
	for name in Visuals.ORDER:
		_t.ok(Visuals.is_tier(name), "tier '%s' is missing from the table" % name)
		_t.ok(not Visuals.settings(name).is_empty(), "tier '%s' has no settings" % name)
	_t.eq(Visuals.TIERS.size(), 3, "there are not exactly three tiers")
	_t.ok(not Visuals.is_tier("ultra"), "a name that is not a tier was accepted")
	_t.ok(Visuals.settings("ultra").is_empty(), "settings() answered for a name that is not a tier")
	_t.ok(Visuals.is_tier(Visuals.DEFAULT), "the default tier is not one of the three")


## Every cost key must be non-decreasing from low to medium to high, and each
## step must raise at least one of them. `fps` 0 means uncapped, which is the
## dearest, so it is mapped to a large number before comparing.
func test_each_tier_costs_no_more_than_the_next(t: TestHarness) -> void:
	_t = t
	var keys := ["fps", "scale", "msaa", "shadows", "effects", "shadow_atlas"]
	for i in range(Visuals.ORDER.size() - 1):
		var a: Dictionary = Visuals.settings(Visuals.ORDER[i])
		var b: Dictionary = Visuals.settings(Visuals.ORDER[i + 1])
		var strictly_more := false
		for k in keys:
			_t.ok(a.has(k) and b.has(k), "tier setting '%s' is missing from a row" % k)
			var ca := _cost(k, a.get(k))
			var cb := _cost(k, b.get(k))
			_t.ok(cb >= ca, "%s: '%s' is dearer on %s (%s) than on %s (%s)" % [
				k, k, Visuals.ORDER[i], str(a.get(k)), Visuals.ORDER[i + 1], str(b.get(k))])
			if cb > ca:
				strictly_more = true
		_t.ok(strictly_more, "%s and %s cost exactly the same, so one of them is not a tier" % [
			Visuals.ORDER[i], Visuals.ORDER[i + 1]])
	_t.lt(float(Visuals.settings("low").scale), 1.0, "low renders at full scale, so it is not low")
	_t.eq(Visuals.settings("low").shadows, false, "low still draws shadows")
	_t.eq(Visuals.settings("high").scale, 1.0, "high does not render at full scale")


func _cost(key: String, v: Variant) -> float:
	if key == "fps":
		return 1000.0 if int(v) == 0 else float(v)
	if v is bool:
		return 1.0 if v else 0.0
	return float(v)


func test_the_choice_round_trips_and_a_bad_one_is_refused(t: TestHarness) -> void:
	_t = t
	for name in Visuals.ORDER:
		_t.eq(Visuals.from_dict(Visuals.to_dict(name)), name, "'%s' did not survive the pair" % name)
	_t.eq(Visuals.from_dict({}), "", "an empty save was not refused")
	_t.eq(Visuals.from_dict({"tier": "ultra"}), "", "a tier that does not exist was not refused")
	_t.eq(Visuals.from_dict({"tier": 3}), "", "a non-string tier was not refused")
	_t.ok(Visuals.from_dict({"tier": "high"}) != Visuals.from_dict({"tier": "low"}),
		"the pair cannot tell two tiers apart")


func test_a_low_reading_predicts_the_floor_phone(t: TestHarness) -> void:
	_t = t
	_t.gt(Visuals.FLOOR_RATIO, 1.0, "the floor ratio says the old phone is faster than the S26")
	# Exactly on budget: predicted floor time must sit inside a 60 fps frame.
	var on: Dictionary = Visuals.judge("low", Visuals.BUDGET_MS.low, 60.0)
	_t.ok(on.within, "a reading exactly on the low budget was judged over")
	_t.approx(on.floor_ms, Visuals.BUDGET_MS.low * Visuals.FLOOR_RATIO, 0.001,
		"the floor prediction is not gpu_ms times the ratio")
	_t.ok(on.floor_ok, "the low budget itself predicts a floor phone that misses 60 fps, so the budget is wrong")
	_t.lt(on.floor_ms, Visuals.FRAME_MS_60, "the low budget leaves no headroom on the floor phone")
	# Over budget is said plainly.
	var over: Dictionary = Visuals.judge("low", Visuals.BUDGET_MS.low * 2.0, 60.0)
	_t.ok(not over.within, "double the low budget was judged within")
	_t.ok(not over.floor_ok, "double the low budget still predicts 60 fps on the floor phone")
	# Only low predicts the floor; high and medium are this phone's own budgets.
	var hi: Dictionary = Visuals.judge("high", 1.0, 120.0)
	_t.eq(hi.floor_ms, 0.0, "high pretends to predict the floor phone")
	_t.ok(hi.floor_ok, "high was judged against the floor phone")
	_t.ok(Visuals.judge("ultra", 1.0, 60.0).is_empty(), "judge() answered for a name that is not a tier")
	# The budgets themselves: each is under the frame at its own rate.
	_t.lt(Visuals.BUDGET_MS.medium, Visuals.FRAME_MS_60, "medium's budget is a whole 60 fps frame or more")
	_t.lt(Visuals.BUDGET_MS.high, 1000.0 / 120.0, "high's budget is a whole 120 Hz frame or more")


func test_the_duty_cycle_decides_whether_a_soak_is_owed(t: TestHarness) -> void:
	_t = t
	var idle: Dictionary = Visuals.judge("medium", 2.0, 60.0)   # 12% duty
	_t.approx(idle.duty, 0.12, 0.001, "duty is not gpu_ms x fps / 1000")
	_t.ok(not idle.soak_owed, "a game idling 88% of every frame was told to soak")
	var busy: Dictionary = Visuals.judge("high", 7.0, 120.0)    # 84% duty
	_t.ok(busy.soak_owed, "a game at 84% duty was excused the soak")
	var edge: Dictionary = Visuals.judge("medium", Visuals.SOAK_FREE_DUTY * 1000.0 / 60.0, 60.0)
	_t.ok(not edge.soak_owed, "exactly on the duty line was told to soak")
	var line := Visuals.report_line("low", 1.234, 0.5, 60.0)
	_t.ok(line.begins_with("VISUALS tier=low gpu=1.23 cpu=0.50 fps=60"),
		"the report line changed shape, and device.ps1 parses it: " + line)
