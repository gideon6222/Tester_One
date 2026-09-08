class_name TestHarness
extends RefCounted

## A deliberately small test harness.
##
## GUT and gdUnit4 both exist and both are good; this is here because the first
## job of this repo is to prove the pipeline - headless run, real assertions,
## non-zero exit, CI gate - with nothing to download and no chance of an addon
## lagging an engine release. It is about a hundred lines and it does the four
## things the tests here actually need.
##
## Swapping it for GUT later is a deliberate open decision, not an oversight.
## See NOTES.md. If the assertions below start growing doubles and mocks, that
## is the signal to switch.

var failures: Array[String] = []
var checks: int = 0
var _current: String = ""


func begin(test_name: String) -> void:
	_current = test_name


func _fail(msg: String) -> void:
	failures.append("%s: %s" % [_current, msg])


func ok(condition: bool, msg: String) -> void:
	checks += 1
	if not condition:
		_fail(msg)


func eq(actual: Variant, expected: Variant, msg: String) -> void:
	checks += 1
	if actual != expected:
		_fail("%s\n      expected: %s\n      actual:   %s" % [msg, str(expected), str(actual)])


func approx(actual: float, expected: float, tolerance: float, msg: String) -> void:
	checks += 1
	if absf(actual - expected) > tolerance:
		_fail("%s\n      expected: %f +/- %f\n      actual:   %f" % [msg, expected, tolerance, actual])


func gt(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if actual <= bound:
		_fail("%s (expected > %s, got %s)" % [msg, str(bound), str(actual)])


func lt(actual: float, bound: float, msg: String) -> void:
	checks += 1
	if actual >= bound:
		_fail("%s (expected < %s, got %s)" % [msg, str(bound), str(actual)])


## Compares two dictionaries field by field and reports every difference, not
## just the first. A golden that stops at the first mismatch turns one run into
## one bug found; this turns it into all of them.
func dict_eq(actual: Dictionary, expected: Dictionary, msg: String) -> void:
	checks += 1
	var diffs: Array[String] = []
	for k in expected.keys():
		if not actual.has(k):
			diffs.append("  %s: MISSING (expected %s)" % [k, str(expected[k])])
		elif actual[k] != expected[k]:
			diffs.append("  %s: expected %s, got %s" % [k, str(expected[k]), str(actual[k])])
	for k in actual.keys():
		if not expected.has(k):
			diffs.append("  %s: UNEXPECTED (%s)" % [k, str(actual[k])])
	if not diffs.is_empty():
		_fail("%s\n%s" % [msg, "\n".join(diffs)])


## Runs every `test_*` method on each supplied script instance.
static func run_all(suites: Array) -> int:
	var t := TestHarness.new()
	var total := 0
	for suite in suites:
		var suite_name: String = suite.get_script().resource_path.get_file()
		for m in suite.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			total += 1
			t.begin("%s > %s" % [suite_name, name.substr(5).replace("_", " ")])
			suite.call(name, t)

	print("")
	if t.failures.is_empty():
		print("  %d tests, %d assertions, all passing" % [total, t.checks])
		return 0
	for f in t.failures:
		print("  FAIL  %s" % f)
	print("")
	print("  %d tests, %d assertions, %d FAILED" % [total, t.checks, t.failures.size()])
	return 1
