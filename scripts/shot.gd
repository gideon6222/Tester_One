extends SceneTree

## Take a screenshot of the real game at a chosen moment, or in a chosen STATE.
##
##   godot --path . --resolution 460x996 --script res://scripts/shot.gd -- 14.0
##   godot --path . --resolution 460x996 --script res://scripts/shot.gd -- 45 hit
##   godot --path . --resolution 460x996 --script res://scripts/shot.gd -- hit
##   godot --path . --resolution 460x996 --script res://scripts/shot.gd -- 8 hit before
##
## **WHERE THE FILE LANDS: `build/shot.png`, or `build/shot_<state>.png`, inside
## the repository.** It used to go to `user://shot.png`, which is outside the
## repo, is a different directory on every machine, and was named in no document
## anywhere - while `/ship` step 3 tells the session to attach the screenshot to
## the release. `build/` is gitignored except for its `.gdignore`, so a shot is
## reachable by path, never committed, and never packed into the APK.
##
## **NOT headless**: this needs a real rendering context, which is the whole
## point. Every other check in this repo runs without a GPU and can therefore
## tell you the numbers are right and nothing at all about whether the picture
## is. This is the only tool here that can answer "does it look wrong".
##
## Three things about it are load bearing.
##
## **Use the PHONE's aspect ratio, not the project's base one.** The project is
## 1080x1920 and the phone is about 19.5:9, and with `stretch/aspect = "expand"`
## the canvas the game actually renders into is roughly 1080x2340. A screenshot
## at 540x960 is a screenshot of a layout the phone never sees - and a HUD bug
## that put controls hundreds of pixels off shipped precisely because every
## check was taken at the base size, where the wrong layout and the right one
## are identical. 460x996 is the phone.
##
## **Freeze before advancing**, or how far the run has got depends on how long
## the window took to open. Going through the same seam the tests use means the
## same second of the same level is captured every time, which is what makes two
## screenshots taken a week apart comparable at all.
##
## **Play it, do not watch it.** A passive run is a picture of the game not
## being played, and the drawing paths that only fire on an impact never run.


## THE ARGUMENTS ARE MATCHED BY SHAPE, NOT BY POSITION, and that is a bug fix.
##
## This file used to be:
##
##     for a in OS.get_cmdline_user_args():
##         _seconds = float(a)
##
## Every user argument was assigned to `_seconds`. `float("hit")` is 0.0, so the
## documented two-argument form `-- 45 hit` captured the game at t=0 - the first
## frame, before anything has happened - and exited 0 with a plausible-looking
## PNG. Five repos in this studio have been photographing the title frame that
## way since the file was written, which is the failure INDEX.md rule 6 warns
## about happening inside the tool meant to prevent it.
##
## So: the first NUMERIC argument is the seconds, the first non-numeric one is
## the state, and anything after that is a filename tag. Order does not matter
## and an argument is never silently swallowed - an unrecognised state exits
## non-zero rather than photographing something else.
var _seconds := 12.0
var _state := ""
var _tag := ""

var _main: Main
var _frames := 0

## Set when `_initialize` gives up. **Godot runs one more frame after `quit()`**,
## so without this the shutter below fires on an empty root, saves a black PNG
## and calls `quit(0)` - turning every failure above into a success with a
## plausible-looking file next to it, which is the exact class of bug this file
## was rewritten to remove.
var _abort := false


## THE STATE ARGUMENT, and what it is worth.
##
## Capturing "at 24.5 seconds" means guessing which moment of the game that is,
## and the moments worth photographing are the short ones. A sibling game grew
## NINE near-identical `shot_*.gd` files, 473 lines, differing only in a setup
## call and a filename; every one of them is an arm of `Main.dev_seek`. When
## this game grows a screen, add an arm THERE rather than a file - a state is
## then a word on a command line instead of a script somebody has to find.
##
## **The table used to live here, and that was the bug.** This file knew four
## states and `scripts/movie.ps1` knew none, so the only way to film a moment a
## minute into the game was to film the minute. The names, the descriptions and
## the setup arms are now `Main.dev_states()` and `Main.dev_seek()` in
## `src/game/main.gd`, which means the screenshot tool, the filming tool and the
## suite all ask the same object the same question and there is one writer. A
## name ending in `.json` is an exact saved run; see that seam's header.
##
## The play loop, the shutter and the filename are still shared below on
## purpose, because the nine files drifted apart in exactly those three places.


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.is_valid_float():
			_seconds = float(a)
		elif _state == "":
			_state = a
		else:
			_tag = a if _tag == "" else _tag + "_" + a

	var scene: PackedScene = load("res://src/game/main.tscn")
	_main = scene.instantiate() as Main
	root.add_child(_main)
	_main.freeze()

	var step := 1.0 / 60.0
	var mem := {}

	# No state at all is the one arm this file still owns: play for <seconds>,
	# which is a shot.gd argument and not a state of the game.
	if _state == "":
		for i in int(round(_seconds / step)):
			Policies.steer(Policies.GREEDY, _main.sim, mem)
			_main.advance(step, step)
		return

	if not _main.dev_seek(_state):
		printerr("unknown or unreachable state '%s'. Known states:" % _state)
		printerr("  %-8s %s" % ["(none)", "the game, played for <seconds> seconds"])
		var states: Dictionary = _main.dev_states()
		for k in states:
			printerr("  %-8s %s" % [k, states[k]])
		printerr("  <path>.json  an exact saved run, loaded through SimSave.read_file")
		_abort = true
		quit(1)
		return

	# **Freeze again.** `dev_seek` hands back a RUNNING game, because filming a
	# state is the common case and a film of a frozen game is a still. This is
	# the other case: the shutter below fires five real frames later, and on a
	# game that is running those five frames are however long the window took to
	# open - which is what makes two screenshots taken a week apart comparable or
	# not. `freeze()` would restart the sim; the flag is what stops the clock.
	_main.frozen = true


func _process(_delta: float) -> bool:
	if _abort:
		return true
	# A few frames, so the sky, the shadow map and the MultiMesh buffers have
	# actually been drawn once. Capturing on frame one gives a grey rectangle.
	_frames += 1
	if _frames < 5:
		return false
	var shot_name := "shot"
	if _state != "":
		shot_name += "_" + _state
	if _tag != "":
		shot_name += "_" + _tag
	# `build/` is committed (it holds `.gdignore`), so it always exists.
	var path := "res://build/%s.png" % shot_name
	var err := root.get_texture().get_image().save_png(path)
	if err != OK:
		printerr("could not write %s (error %d)" % [path, err])
		quit(1)
		return true
	print("wrote %s  state='%s'  t=%.1fs" % [path, _state, _seconds])
	quit(0)
	return true
