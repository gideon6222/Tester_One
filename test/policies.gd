class_name Policies
extends RefCounted

## Scripted players.
##
## These are not test fixtures. They are **the definition of "playing well"** -
## the thing every balance number in the game is measured against - and that is
## why they live in the repo rather than in a session. On a sibling game `par`
## was once set from a policy typed into a browser console whose lookahead was
## slightly longer than the committed one; it scored 65% higher and the constant
## went in 44% too high. Nobody could have caught that by reading the number.
##
## **Write one policy per way of failing.** The set below is the placeholder
## game's; the shape is what carries to a real one:
##
##   PASSIVE  touches nothing - proves that not playing earns nothing
##   DODGER   survives without going for anything
##   GREEDY   goes for the pickups and takes the hits that come with it
##
## Two rules learned the hard way on games built from this template:
##
## **Every policy must fail for a DIFFERENT reason.** When two of them score the
## same, one is not testing anything - and if the one that reads the level ever
## loses to the one that ignores it, the bot is wrong before the game is. Fix
## the bot before touching a single constant, or a whole balance pass gets built
## on a measurement of the wrong thing.
##
## **The pair that proves a decision exists must differ in exactly one thing.**
## If two policies share all their code and one argument, the gap between their
## scores is a claim about the GAME. If they differ in how well they drive, it
## is a claim about the bots.
##
## And drive them through the same seam a thumb uses. A helper that computes its
## own inputs is a second, usually worse player - which has already made eight
## tests fail for reasons unrelated to what they asserted.

const PASSIVE := "passive"
const DODGER := "dodger"
const GREEDY := "greedy"

const ALL := [PASSIVE, DODGER, GREEDY]


static func steer(name: String, s: Sim, mem: Dictionary) -> void:
	match name:
		PASSIVE:
			pass
		DODGER:
			_dodger(s)
		GREEDY:
			_greedy(s)


## Steers away from whatever is in front. Deliberately crude: a policy with
## cleverness in it becomes a second thing that can change, and then a golden
## failure means "the bot got better" as often as "the game changed".
static func _dodger(s: Sim) -> void:
	for o in s.obstacles:
		if o.taken or o.z <= s.distance or o.z > s.distance + 14.0:
			continue
		s.steer_to(-Tuning.LANE_HALF_WIDTH if o.x > 0.0 else Tuning.LANE_HALF_WIDTH)
		return


## Goes for the pickups, and eats whatever is in the way of doing so.
static func _greedy(s: Sim) -> void:
	for p in s.pickups:
		if p.taken or p.z <= s.distance or p.z > s.distance + 20.0:
			continue
		s.steer_to(p.x)
		return


## Play one whole level with one policy and hand back the final state, plus any
## extra readings a balance pass wants that the golden does not.
static func play(name: String, level: int = 1, seconds: float = 0.0) -> Dictionary:
	var s := Sim.new(level)
	var mem := {}
	var step := 1.0 / 60.0
	var limit := seconds if seconds > 0.0 else Tuning.level_seconds(level) + 2.0
	var n := int(round(limit / step))
	for i in n:
		if s.over:
			break
		steer(name, s, mem)
		s.advance(step)
	var out := s.state()
	out["seconds"] = snappedf(s.time, 0.001)
	return out
