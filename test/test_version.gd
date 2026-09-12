extends RefCounted

## The version is one fact stored in five places and no code derives any of them.
##
## `Changelog.VERSION`, `Changelog.RELEASES[0].version`, and `version/name` plus
## `version/code` in every export preset. Godot will not read a constant out of a
## script at export time, so the preset copies are typed by hand and they drift.
## When they do, the title screen says one version and the phone's app info says
## another, and "did my build land" - the question the build stamp exists to
## answer - gets two different answers depending on where you look.
##
## **The AAB preset's copies are the dangerous ones**, because nobody sees them
## until a store upload, and by then the upload has been rejected.
##
## **`version/code` is here because leaving it out is what actually happened.**
## Three sibling games carry a version test whose header says exactly what the
## paragraph above says, and every one of them collects only lines beginning
## `version/name=`. Four of five repos in this studio are sitting on
## `version/code=1` after a dozen releases each, and Play rejects any upload
## whose code is not higher than the last. A test that asserts the easy half of
## a rule and quietly skips the half nobody looks at is worse than no test: it
## is the reason nobody looked.
##
## `export_presets.cfg` is read as text rather than through ConfigFile on
## purpose. ConfigFile would need the file to stay a valid Godot config; a text
## read keeps working when Godot rewrites the file, and the failure it produces
## is "the key moved" rather than a parse error.


## How many `[preset.N]` sections the file declares. `[preset.N.options]` is a
## sub-section of the same preset and is deliberately not counted - counting it
## would double every expectation below and the test would then pass with half
## the presets missing a version.
func _preset_count() -> int:
	var n := 0
	for line in _lines():
		if line.begins_with("[preset.") and line.ends_with("]") and not line.ends_with(".options]"):
			n += 1
	return n


## Every value of `key`, in file order. Returns empty if the file is unreadable,
## which the assertions below treat as a failure rather than as "no presets" -
## an empty result from a reader that cannot report failure is the classic way a
## gate goes quiet.
func _values(key: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in _lines():
		if line.begins_with(key + "="):
			out.append(line.split("=", true, 1)[1].strip_edges().trim_prefix("\"").trim_suffix("\""))
	return out


func _lines() -> PackedStringArray:
	var f := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var out := PackedStringArray()
	while not f.eof_reached():
		out.append(f.get_line().strip_edges())
	return out


func test_every_export_preset_carries_the_version_name(t: TestHarness) -> void:
	var presets := _preset_count()
	var names := _values("version/name")
	t.gt(float(presets), 1.0,
		"fewer than two export presets were found in export_presets.cfg - the file moved, or the section header changed")
	t.eq(names.size(), presets,
		"%d presets but %d version/name lines - a preset is shipping with no version at all" % [presets, names.size()])
	for v in names:
		t.eq(v, Changelog.VERSION,
			"an export preset says version/name %s while Changelog.VERSION says %s" % [v, Changelog.VERSION])


## The half every other copy of this test in the studio is missing.
##
## `version/code` is the integer Play orders uploads by. It has no relationship
## to `version/name` that any tool enforces, so the only way it stays right is
## for something to say what it must equal. Tying it to the number of releases
## makes it derive from a fact that already has to be true - the changelog is
## written for every release anyway - rather than from a number somebody
## remembers to bump.
func test_every_export_preset_carries_the_same_version_code(t: TestHarness) -> void:
	var presets := _preset_count()
	var codes := _values("version/code")
	t.eq(codes.size(), presets,
		"%d presets but %d version/code lines - a preset is shipping with no version code" % [presets, codes.size()])

	# Hoisted rather than indexed inside the loop, so an empty read fails on the
	# assertion above and cannot also throw an out-of-bounds that would abort
	# this whole check and take the assertion below it with it.
	var first := codes[0] if not codes.is_empty() else ""
	for c in codes:
		t.eq(c, first,
			"the export presets disagree about version/code (%s vs %s) - Play orders uploads by this number" % [c, first])
	t.eq(int(first) if first != "" else -1, Changelog.RELEASES.size(),
		"version/code is '%s' but the changelog lists %d releases - bump the code in EVERY preset when you add a release, or Play rejects every upload after the first" % [first, Changelog.RELEASES.size()])


func test_the_changelog_leads_with_the_current_version(t: TestHarness) -> void:
	t.gt(float(Changelog.RELEASES.size()), 0.0, "the changelog has at least one release")
	t.eq(Changelog.RELEASES[0]["version"], Changelog.VERSION,
		"the newest changelog entry is not the version being built")
	for r in Changelog.RELEASES:
		t.gt(float(String(r["notes"][0]).length()), 8.0,
			"release %s has a note written in the player's terms" % r["version"])
