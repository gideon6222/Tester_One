extends SceneTree

## Take a screenshot of the real game at a chosen moment.
##
##   godot --path . --resolution 460x996 --script res://scripts/shot.gd -- 14.0
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

var _main
var _frames := 0
var _seconds := 12.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		_seconds = float(a)

	var scene: PackedScene = load("res://src/game/main.tscn")
	_main = scene.instantiate()
	root.add_child(_main)
	_main.freeze()

	var mem := {}
	var step := 1.0 / 60.0
	for i in int(round(_seconds / step)):
		Policies.steer(Policies.GREEDY, _main.sim, mem)
		_main.advance(step, step)


func _process(_delta: float) -> bool:
	# A few frames, so the sky, the shadow map and the MultiMesh buffers have
	# actually been drawn once. Capturing on frame one gives a grey rectangle.
	_frames += 1
	if _frames < 5:
		return false
	var img := root.get_texture().get_image()
	img.save_png("user://shot.png")
	print("wrote %s/shot.png at t=%.1fs" % [OS.get_user_data_dir(), _seconds])
	quit(0)
	return true
