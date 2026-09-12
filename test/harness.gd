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

## THE ENGINE'S OWN ERRORS, COUNTED PER TEST.
##
## A runtime error inside a test body is non-fatal in GDScript: the method stops
## at that line, the harness carries on, and every assertion below the error
## silently never runs. On stillwater a test called a method that did not exist,
## the runner printed "all passing", and reintroducing the bug the test was
## written for STILL passed, because the only check that could have caught it
## was unreachable. The assertion floor and the asserted-nothing rule are
## canaries; this is the instrument. A `Logger` is handed every error the engine
## prints - a script error, a `push_error`, a failed load - so a test whose body
## raised one FAILS with the error's own text, whatever its assertions said.
## Warnings are not errors and are left alone.
class _Errors extends Logger:
	var n := 0
	var first := ""

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		n += 1
		if first == "":
			var what := code
			if rationale != "":
				what = "%s: %s" % [code, rationale] if code != "" else rationale
			first = "%s (%s:%d in %s)" % [what, file.get_file(), line, function]

var _errors := _Errors.new()
var _errors_at := 0


func _init() -> void:
	OS.add_logger(_errors)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		OS.remove_logger(_errors)


## Opens a test. Closes the one before it, so a runner that only ever calls
## `begin` (the smoke suite) still gets every body's errors attributed to it -
## except the last, which is why `end()` exists.
func begin(test_name: String) -> void:
	end()
	_current = test_name
	_errors_at = _errors.n
	_errors.first = ""


## Closes the current test: an engine error raised during its body is a failure
## of that test. Call once after the last test; `begin` calls it for the rest.
func end() -> void:
	if _current == "":
		return
	var raised := _errors.n - _errors_at
	if raised > 0:
		_fail("the body raised %d engine error%s, and nothing after the first one ran: %s" % [
			raised, "" if raised == 1 else "s", _errors.first])
	_current = ""


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


## How close two floats have to be to count as the same in a golden.
##
## Not a fudge factor, and it took a failure that read "expected -0.825, got
## -0.825" to justify it. `snappedf(x, 0.001)` produces a double near -0.825
## whose last bits are not the ones the literal `-0.825` parses to, so a
## recorded golden can never match the run it was recorded from - the test is
## unpassable by construction and says nothing about why.
##
## It earns its place a second time in CI. Goldens are recorded on Windows and
## checked on a Linux runner, and identical IEEE arithmetic across two
## toolchains is something people assume rather than something promised. A
## tolerance a thousand times finer than the snap cannot hide a behaviour
## change - the simulation would have to differ by less than a micron - and it
## stops the whole suite becoming a platform detector.
const FLOAT_EPS := 1e-6


func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return absf(a - b) <= FLOAT_EPS
	return a == b


## Compares two dictionaries field by field and reports every difference, not
## just the first. A golden that stops at the first mismatch turns one run into
## one bug found; this turns it into all of them.
func dict_eq(actual: Dictionary, expected: Dictionary, msg: String) -> void:
	checks += 1
	var diffs: Array[String] = []
	for k in expected.keys():
		if not actual.has(k):
			diffs.append("  %s: MISSING (expected %s)" % [k, str(expected[k])])
		elif not _same(actual[k], expected[k]):
			diffs.append("  %s: expected %s, got %s" % [k, str(expected[k]), str(actual[k])])
	for k in actual.keys():
		if not expected.has(k):
			diffs.append("  %s: UNEXPECTED (%s)" % [k, str(actual[k])])
	if not diffs.is_empty():
		_fail("%s\n%s" % [msg, "\n".join(diffs)])


## Runs every `test_*` method on each supplied script instance.
##
## `t` is optional and exists so a runner can read the assertion count back
## afterwards - see MIN_ASSERTIONS in run_tests.gd. Passing nothing behaves
## exactly as before.
##
## **A test method that asserts nothing fails.** It is the small, exact half of
## the assertion floor: in GDScript a runtime error inside a check is non-fatal,
## the method stops at that line and the harness carries on, so a check that
## errors on its FIRST line leaves no trace at all except a count that nobody
## reads. Zero assertions from a method named `test_` is never intentional -
## either it bailed, or it is a placeholder pretending to be coverage.
static func run_all(suites: Array, t: TestHarness = null) -> int:
	if t == null:
		t = TestHarness.new()
	var total := 0
	for suite in suites:
		var suite_name: String = suite.get_script().resource_path.get_file()
		for m in suite.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			total += 1
			t.begin("%s > %s" % [suite_name, name.substr(5).replace("_", " ")])
			var before := t.checks
			suite.call(name, t)
			if t.checks == before:
				t.checks += 1
				t._fail("asserted nothing - it either bailed on its first line or it is a stub")
	t.end()

	print("")
	if t.failures.is_empty():
		print("  %d tests, %d assertions, all passing" % [total, t.checks])
		return 0
	for f in t.failures:
		print("  FAIL  %s" % f)
	print("")
	print("  %d tests, %d assertions, %d FAILED" % [total, t.checks, t.failures.size()])
	return 1
