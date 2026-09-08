extends SceneTree

## APK size guard. Fails in BOTH directions.
##
##   godot --headless --script res://scripts/check_size.gd
##   godot --headless --script res://scripts/check_size.gd -- --update
##
## Growth is the obvious thing to watch. A shrink matters more, and is the
## reason this exists: on another game here a module split silently dropped the
## call that starts the frame loop. Every test passed, the typecheck was clean,
## the build succeeded, and the game was frozen on launch. The only signal
## anywhere was the bundle getting smaller, because everything reachable solely
## from that loop had been tree-shaken away as unreachable.
##
## A Godot export cannot tree-shake GDScript the same way, but the equivalent
## failures are real: an export preset that quietly stops including a
## directory, an `export_filter` change, a resource that stops being imported.
## All of those show up here as a drop and nowhere else.
##
## Run it after every export, in CI, before the artifact is published.

const APK := "res://build/godot-template.apk"
const BUDGET := "res://size-budget.json"
const TOLERANCE_PERCENT := 10.0


func _initialize() -> void:
	var update := "--update" in OS.get_cmdline_user_args()

	if not FileAccess.file_exists(APK):
		printerr("no %s - run the export first" % APK)
		quit(1)
		return

	var actual := FileAccess.open(APK, FileAccess.READ).get_length()

	if update:
		var f := FileAccess.open(BUDGET, FileAccess.WRITE)
		f.store_string(JSON.stringify({
			"note": "Regenerate with `--update` and commit. Both directions are checked; a shrink means something stopped being included.",
			"apk_bytes": actual,
			"tolerance_percent": TOLERANCE_PERCENT,
		}, "  "))
		f.close()
		print("  recorded budget: %s" % _mb(actual))
		quit(0)
		return

	if not FileAccess.file_exists(BUDGET):
		printerr("no %s - create it with `-- --update`" % BUDGET)
		quit(1)
		return

	var budget: Dictionary = JSON.parse_string(FileAccess.open(BUDGET, FileAccess.READ).get_as_text())
	var expected: int = budget.get("apk_bytes", 0)
	var tol: float = budget.get("tolerance_percent", TOLERANCE_PERCENT)
	var drift := (float(actual) - float(expected)) / float(expected) * 100.0

	print("  apk %s   budget %s   drift %+.2f%%  (+/-%.0f%%)" % [_mb(actual), _mb(expected), drift, tol])

	if absf(drift) <= tol:
		print("  within budget")
		quit(0)
		return

	printerr("")
	printerr("  APK %s by %.2f%%, budget allows %.0f%%" % ["GREW" if drift > 0 else "SHRANK", absf(drift), tol])
	printerr("")
	printerr("  A build that gets smaller for no reason has lost something. Check the")
	printerr("  export preset still includes everything before assuming better packing.")
	printerr("  If the change is intentional, re-record with `-- --update` and commit it.")
	quit(1)


func _mb(bytes: int) -> String:
	return "%.2f MB" % (float(bytes) / 1048576.0)
