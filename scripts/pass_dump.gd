# Halfmoon pass dump — diagnostic only, armed by HALFMOON_DUMP.
#
# Saves each intermediate buffer of the render chain so a highlight, a blur or a
# mask can be measured where it is actually produced instead of guessed from the
# final CRT frame.
#
# HALFMOON_DUMP takes one time or a comma list ("1.6,2.8,4.0"); every listed
# time writes its own numbered set.
#
#   screen_N.png   384x216  raw game raster (Backdrop + Halfmoon)
#   bright_N.png   192x108  luminance extraction
#   narrow_N.png   192x108  tight core tier
#   wide_N.png      96x54   skirt tier
#   far_N.png       96x54   wide field tier
#   streak_N.png   192x108  anamorphic bar
#   combine_N.png  192x108  summed bloom (what the CRT adds)
#   final_N.png    window   root frame, CRT applied
extends Node

var clock := 0.0
var times: Array[float] = []
var idx := 0
var busy := false


func _ready() -> void:
	var raw := OS.get_environment("HALFMOON_DUMP")
	if raw == "":
		raw = "3.4"
	for part in raw.split(",", false):
		var v := part.strip_edges()
		if v.is_valid_float():
			times.append(float(v))
	set_process(true)


func _process(dt: float) -> void:
	clock += float(dt)
	if busy or idx >= times.size():
		return
	if clock >= times[idx]:
		busy = true
		_flush(idx)
		idx += 1


func _flush(which: int) -> void:
	# Textures are only valid after the current frame has finished drawing.
	await RenderingServer.frame_post_draw

	# `get_parent()` is statically a Node, so the boot fields are only reachable
	# through an untyped reference. Annotating it as Control and then touching
	# `.screen` fails at runtime because that property lives on boot.gd, not on
	# Control.
	var boot: Node = get_parent()
	if boot == null:
		busy = false
		return
	var dir := "user://shots"
	DirAccess.make_dir_recursive_absolute(dir)

	var pairs := [
		["screen", "screen"],
		["bright", "bright"],
		["narrow", "narrow_v"],
		["wide", "wide_v"],
		["streak", "streak"],
		["combine", "combine"],
	]
	for pr in pairs:
		var vp = boot.get(pr[1])
		if vp == null or not (vp is SubViewport):
			continue
		var img: Image = (vp as SubViewport).get_texture().get_image()
		if img != null:
			img.save_png("%s/%s_%d.png" % [dir, pr[0], which])

	var root_img := get_tree().root.get_texture().get_image()
	if root_img != null:
		root_img.save_png("%s/final_%d.png" % [dir, which])
	print("PASSDUMP wrote set %d to %s" % [which, dir])
	busy = false
