extends "res://scripts/boot.gd"


func _ready() -> void:
	super._ready()
	set_process(false)
	game.set_process(false)
	var args := OS.get_cmdline_user_args()
	var pass_name := str(args[0]) if not args.is_empty() else "1"
	var sheet := Image.create(384 * 3, 216 * 2, false, Image.FORMAT_RGBA8)
	var metrics: Array[String] = []
	for stage in range(1, 7):
		game.reset()
		game.loop_n = stage
		game.feed_backdrop(3.0)
		game.queue_redraw()
		await RenderingServer.frame_post_draw
		var image: Image = screen.get_texture().get_image()
		var dark := 0
		var mean := 0.0
		for y in range(24, 200):
			for x in range(115, 366):
				var pixel := image.get_pixel(x, y)
				var luminance := pixel.get_luminance()
				mean += luminance
				if luminance < 0.40:
					dark += 1
		metrics.append("%s:dark=%d,mean=%.3f" % [game.backdrop.worlds.NAMES[stage - 1],
			dark, mean / (176.0 * 251.0)])
		sheet.blit_rect(image, Rect2i(0, 0, 384, 216),
			Vector2i((stage - 1) % 3 * 384, (stage - 1) / 3 * 216))
		if stage == 2 or stage == 4:
			get_viewport().get_texture().get_image().save_png("res://.shots/background-pass-%s-stage-%d.png" % [pass_name, stage])
	sheet.save_png("res://.shots/background-pass-%s.png" % pass_name)
	print("BACKGROUND_PASS_%s %s" % [pass_name, "; ".join(metrics)])
	get_tree().quit()
