extends SceneTree

## Rasterize icon.svg to a 512x512 PNG for the Play listing, headless.
##
##   godot --headless --path . --script res://scripts/store_icon.gd -- store/listing/en-US/images/icon.png
##
## Nothing on this PC rasterizes an SVG from the command line (ffmpeg here has no
## librsvg), but the engine does, without a GPU: Image.load_svg_from_string scales
## the vector to any size. Play wants 512x512, 32-bit with alpha, and NO rounded
## corners or shadow, because the store draws those itself.

func _initialize() -> void:
	var out := "res://store/listing/en-US/images/icon.png"
	for a in OS.get_cmdline_user_args():
		out = a if a.begins_with("res://") else "res://" + a
	var f := FileAccess.open("res://icon.svg", FileAccess.READ)
	if f == null:
		printerr("no icon.svg at the project root")
		quit(1)
		return
	var svg := f.get_as_text()
	var img := Image.new()
	# The SVG's own size is whatever it says; scale so the larger side is 512.
	var probe := Image.new()
	if probe.load_svg_from_string(svg, 1.0) != OK:
		printerr("icon.svg did not parse")
		quit(1)
		return
	var side: float = max(probe.get_width(), probe.get_height())
	if img.load_svg_from_string(svg, 512.0 / side) != OK:
		printerr("icon.svg did not rasterize")
		quit(1)
		return
	if img.get_width() != 512 or img.get_height() != 512:
		# A non-square icon is padded onto a transparent square rather than stretched.
		var sq := Image.create(512, 512, false, Image.FORMAT_RGBA8)
		sq.fill(Color(0, 0, 0, 0))
		sq.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()),
			Vector2i((512 - img.get_width()) / 2, (512 - img.get_height()) / 2))
		img = sq
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	var err := img.save_png(out)
	if err != OK:
		printerr("could not write %s (error %d)" % [out, err])
		quit(1)
		return
	print("wrote %s 512x512" % out)
	quit(0)
