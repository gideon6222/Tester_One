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
##
## **AND IT REFUSES TO MEASURE A STALE APK**, which is the other half of the job
## and the half that was missing.
##
## A guard whose input is a build artifact has to own the build. This one cannot
## - the export is a separate command - so it does the next best thing and
## checks that the APK in `build/` is newer than every source file that went
## into it. A sibling game added a whole room, nine imported props and a plank
## material, went from 35.62 MB to 64.58 MB against a 10% tolerance, and its
## local check printed `size ok` the entire time, because the APK in `build/`
## was from an earlier session and the guard was answering a question about a
## build nobody had made that day. CI exported first and caught it immediately.
##
## A green local check is not a green build. This is the second time on this
## machine that a local pass and a CI fail disagreed because the local step
## silently measured the wrong thing.

const APK := "res://build/godot-template.apk"
const BUDGET := "res://size-budget.json"
const TOLERANCE_PERCENT := 10.0

## Everything that can change what goes INTO the APK. Imported art counts twice
## over: VRAM-compressed textures are a fixed rate per pixel, so thirty-nine new
## 1K maps are about 39 MB in the package whatever they weigh on disk - the case
## above was almost entirely assets.
const SOURCE_ROOTS: Array[String] = ["res://src", "res://test", "res://scripts", "res://assets"]

## Named one by one rather than swept from the project root, and the omission is
## deliberate: `size-budget.json` is written BY this script, so sweeping the root
## would make every `-- --update` leave behind a file newer than the APK and
## refuse the very next run.
const SOURCE_FILES: Array[String] = [
	"res://project.godot", "res://export_presets.cfg", "res://icon.svg",
]

## `build/` is the OUTPUT and would make every APK newer than itself; the other
## two are generated caches that change on every editor open.
const SKIP_DIRS: Array[String] = ["build", ".godot", "android"]


func _initialize() -> void:
	var update := "--update" in OS.get_cmdline_user_args()

	if not FileAccess.file_exists(APK):
		printerr("no %s - run the export first" % APK)
		quit(1)
		return

	if not _refuse_a_stale_apk():
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


## True if the APK is newer than every source file. Prints and returns false if
## it is not.
##
## Deliberately loud and deliberately not overridable. An escape hatch here is a
## flag that gets typed once, lives in a script forever, and turns the guard
## back into the thing it was. If the APK is old, export; that is the whole fix.
func _refuse_a_stale_apk() -> bool:
	var apk_time := FileAccess.get_modified_time(APK)
	var newest_time := 0
	var newest_path := ""
	for f in SOURCE_FILES:
		if FileAccess.file_exists(f):
			var mt := FileAccess.get_modified_time(f)
			if mt > newest_time:
				newest_time = mt
				newest_path = f
	for r in SOURCE_ROOTS:
		var found := _newest_under(r)
		if int(found["time"]) > newest_time:
			newest_time = int(found["time"])
			newest_path = String(found["path"])

	# A scan that found nothing is a broken scan, not a clean tree. Zero rows
	# after filtering is an answer; zero rows before filtering is a bug, and
	# from outside they look identical.
	if newest_time == 0:
		printerr("")
		printerr("  found no source files at all under %s" % ", ".join(SOURCE_ROOTS))
		printerr("  That is this guard being broken, not the project being empty.")
		return false

	var others := _other_apks()
	if not others.is_empty():
		print("  note: build/ also holds %s - only %s is measured" % [", ".join(others), APK.get_file()])

	if apk_time >= newest_time:
		return true

	printerr("")
	printerr("  THE APK IS OLDER THAN THE CODE. Nothing was measured.")
	printerr("")
	printerr("  %s        %s" % [APK.get_file(), _stamp(apk_time)])
	printerr("  %s        %s   <- newer" % [newest_path, _stamp(newest_time)])
	printerr("")
	printerr("  A size guard that measures whatever happens to be in build/ reports")
	printerr("  `size ok` about a build nobody made today. Export first:")
	printerr("")
	printerr("    scripts\\check.ps1 -Export")
	printerr("")
	return false


func _newest_under(path: String) -> Dictionary:
	var out := {"time": 0, "path": ""}
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for d in dir.get_directories():
		if d in SKIP_DIRS or d.begins_with("."):
			continue
		var deeper := _newest_under(path + "/" + d)
		if int(deeper["time"]) > int(out["time"]):
			out = deeper
	for f in dir.get_files():
		var full := path + "/" + f
		var mt := FileAccess.get_modified_time(full)
		if mt > int(out["time"]):
			out = {"time": mt, "path": full}
	return out


## Every other APK sitting in build/. Not a failure - the measured one is named
## by path so the others cannot be measured by accident - but worth printing,
## because a pile of seven of them is what a stale build looks like from outside.
func _other_apks() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open("res://build")
	if dir == null:
		return out
	for f in dir.get_files():
		if f.ends_with(".apk") and f != APK.get_file():
			out.append(f)
	return out


func _stamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "(no timestamp)"
	var d := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d-%02d-%02d %02d:%02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


func _mb(bytes: int) -> String:
	return "%.2f MB" % (float(bytes) / 1048576.0)
