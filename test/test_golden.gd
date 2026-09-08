extends RefCounted

## THE important one.
##
## The simulation is deterministic given a level: spawning is keyed on
## (chunk, level) through the hash, and nothing consults randf() or a real
## clock. So twenty simulated seconds produce the same numbers on every
## machine, every time.
##
## That makes a golden test over the *whole game* possible, which is a far
## stronger safety net than testing any single function - and it is what makes
## a large refactor safe to attempt at all. Record it before changing anything,
## never after.
##
## Two runs are recorded, not one, and the pair is the point. `PASSIVE` is
## never touching the screen; `DODGING` is a scripted policy that steers away
## from whatever is in front of it. A change that only moves one of them says
## something a single golden could not: if passive moves and dodging does not,
## spawning changed; if dodging moves and passive does not, steering or
## collision did.
##
## The numbers were recorded, not designed. If a deliberate balance change
## moves them, re-record them in the same commit and say so in the message. A
## change to rendering, layout, input or the build must not touch them - if it
## does, something has leaked into the simulation.

const SECONDS := 20.0

## Never touches the screen: runs straight down the middle and is dead before
## twenty seconds are up, with three lives spent and the level unfinished.
const PASSIVE := {
	"level": 1, "lives": 0, "score": 40, "distance": 238.8, "x": 0.0,
	"obstacles": 7, "pickups": 3, "over": true, "won": false,
}

## The same twenty seconds played by the dodging policy: still alive, one life
## lost, further up the track. Same score, because the policy dodges and does
## not go out of its way for pickups - which is honest, and is why `score` is
## not the field these two are separated on.
const DODGING := {
	"level": 1, "lives": 2, "score": 40, "distance": 240.0, "x": 2.6,
	"obstacles": 7, "pickups": 3, "over": false, "won": false,
}


## Asserted directly, and separately from the goldens below, so that when they
## fail together it is obvious which is the cause. A golden mismatch with this
## passing is a real behaviour change; a golden mismatch with this failing is
## not the golden's fault.
func test_the_same_twenty_seconds_replays_identically(t: TestHarness) -> void:
	t.dict_eq(_play(false), _play(false), "two passive runs differed - the simulation is not deterministic")
	t.dict_eq(_play(true), _play(true), "two dodging runs differed - the simulation is not deterministic")


func test_never_touching_the_screen_is_unchanged(t: TestHarness) -> void:
	_check(t, _play(false), PASSIVE, "PASSIVE")


func test_a_dodging_run_is_unchanged(t: TestHarness) -> void:
	_check(t, _play(true), DODGING, "DODGING")


## Playing well must beat not playing. Recorded goldens pin the numbers; this
## pins the *relationship*, so re-recording carelessly cannot quietly accept a
## game where steering stopped mattering. That has happened: on another game
## here, four completely different play styles scored identically and it took a
## measurement to notice.
func test_dodging_beats_standing_still(t: TestHarness) -> void:
	var passive := _play(false)
	var dodging := _play(true)
	t.gt(dodging["distance"], passive["distance"],
		"steering got no further than never touching the screen - dodging is decoration")


func _check(t: TestHarness, actual: Dictionary, expected: Dictionary, label: String) -> void:
	if expected.is_empty():
		# Print rather than pass silently, so a baseline is never recorded by
		# accident. A golden you have never seen fail is one you do not know
		# works.
		print("")
		print("  %s NOT YET RECORDED. Paste into test_golden.gd:" % label)
		print("  const %s := %s" % [label, str(actual)])
		print("")
		t.ok(false, "no %s golden recorded yet - see the printed state above" % label)
		return
	t.dict_eq(actual, expected, "the simulation changed (%s)" % label)


## `dodge` picks the emptier half of the lane based on the nearest obstacle
## ahead. Deliberately crude: a policy with any cleverness in it becomes a
## second thing that can change, and then a golden failure means "the bot got
## better" as often as "the game changed".
func _play(dodge: bool) -> Dictionary:
	var s := Sim.new()
	var step := 1.0 / 60.0
	var n := int(round(SECONDS / step))
	for i in n:
		if dodge:
			var danger := 0.0
			for o in s.obstacles:
				if not o.taken and o.z > s.distance and o.z < s.distance + 14.0:
					danger = o.x
					break
			s.steer_to(-Tuning.LANE_HALF_WIDTH if danger > 0.0 else Tuning.LANE_HALF_WIDTH)
		s.advance(step)
	return s.state()
