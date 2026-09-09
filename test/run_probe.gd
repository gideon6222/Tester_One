extends SceneTree

## A balance probe, not a test. **Nothing here can fail.**
##
##   godot --headless --path . --script res://test/run_probe.gd
##
## It plays every policy over several levels and prints the readings a tuning
## pass needs. That is a different job from a test: a test says whether the game
## still does what it did, and this says what the game currently IS.
##
## Two reasons it is worth having from the first commit.
##
## **A single level is not a calibration.** On one game here four scripted
## policies swung 25% level to level on layout luck alone, and a `par` set from
## level one put the best policy on three stars there and two everywhere else -
## none of which was visible in the level-one numbers, which looked clean and
## well separated. Take the mean over five or six.
##
## **The table it prints should be a description of the game.** If every policy
## fails for a different, legible reason, the columns tell you what the game
## rewards. If two of them score the same, one of them is not testing anything -
## and that is the single most useful signal this file produces.

const LEVELS := [1, 2, 3, 4, 5, 6]


func _initialize() -> void:
	print("")
	print("  %-9s %6s %7s %7s %6s %6s" % ["policy", "level", "score", "dist", "lives", "won"])
	print("  %s" % "-".repeat(50))

	for name in Policies.ALL:
		var score := 0
		var wins := 0
		for level in LEVELS:
			var r := Policies.play(name, level)
			score += int(r["score"])
			if r["won"]:
				wins += 1
			print("  %-9s %6d %7d %7.0f %6d %6s" % [
				name, level, r["score"], r["distance"], r["lives"], str(r["won"]),
			])
		print("  %-9s %6s %7.0f %7s %6s %6d/%d" % [
			name, "MEAN", float(score) / LEVELS.size(), "", "", wins, LEVELS.size()])
		print("")

	quit(0)
