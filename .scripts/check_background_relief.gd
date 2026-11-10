extends "res://scripts/boot.gd"

var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func _ready() -> void:
	super._ready()
	set_process(false)
	game.set_process(false)
	game.reset()
	game.visible = false
	var backdrop: Node2D = game.backdrop
	var worlds: Node2D = backdrop.worlds
	var sky: Node2D = backdrop.sky
	var moon: Image = worlds.moon_texture.get_image()
	var plate_colors := {}
	for y in moon.get_height():
		for x in moon.get_width():
			var color := moon.get_pixel(x, y)
			if color.a > 0.1:
				plate_colors[color.to_rgba32()] = true
	check(plate_colors.size() >= 3 and plate_colors.size() <= 4,
		"Moon engraving must retain three or four discrete inks, without a smooth ramp")
	sky.visible = false
	var combat_rng: int = game.rng.state
	# Entity contrast is now drawn at its polygon edge; only HUD/frame clear space remains.
	check(sky._visibility(game.player, false) == 1.0, "Radial player clearing returned")
	worlds.weights.fill(0.0)
	backdrop.queue_redraw()
	worlds.queue_redraw()
	await RenderingServer.frame_post_draw
	var blank: Image = screen.get_texture().get_image()
	var records: Array[String] = []
	for stage in range(1, 7):
		worlds.set_stage(stage)
		worlds.step(3.0, Vector2.ZERO)
		# Stage one is already selected after reset, so restore its settled weight.
		if stage == 1:
			worlds.weights[0] = 1.0
		backdrop.queue_redraw()
		await RenderingServer.frame_post_draw
		var image: Image = screen.get_texture().get_image()
		var protected_changes := 0
		var changed := 0
		var dark := 0
		var cores := 0
		var tones := {}
		for y in 216:
			for x in 384:
				var color := image.get_pixel(x, y)
				if color == blank.get_pixel(x, y):
					continue
				changed += 1
				if sky._visibility(Vector2(x, y), false) == 0:
					protected_changes += 1
				if color.get_luminance() < 0.4:
					dark += 1
				if minf(color.r, minf(color.g, color.b)) > 0.97:
					cores += 1
				if color.get_luminance() < 0.75:
					tones[int(color.get_luminance() * 32.0)] = true
		check(changed > 400, "Scenery lost its silhouette")
		check(dark > 150, "Scenery lost its dark anchor")
		check(tones.size() >= 3, "Scenery lost its light/midtone/shadow separation")
		check(protected_changes == 0, "Scenery crossed subject/HUD/frame mask")
		check(cores == 0, "Scenery entered bloom threshold")
		records.append("%s pixels=%d dark=%d tones=%d protected=%d" %
			[worlds.NAMES[stage - 1], changed, dark, tones.size(), protected_changes])
		var before := image.get_data()
		game.paused = true
		var frozen: float = worlds.clock
		game._process(0.05)
		await RenderingServer.frame_post_draw
		check(worlds.clock == frozen, "Pause advanced scenery clock")
		check(screen.get_texture().get_image().get_data() == before, "Pause changed background pixels")
		backdrop.step(Vector2(2, -1), 0.8)
		await RenderingServer.frame_post_draw
		check(screen.get_texture().get_image().get_data() != before, "Background is static")
	# Interrupt multiple transitions, including the wrap back to the first scene.
	for stage in [4, 2, 6, 1, 3, 5, 7]:
		worlds.set_stage(stage)
		for frame in 25:
			var previous: PackedFloat32Array = worlds.weights.duplicate()
			worlds.step(1.0 / 60.0, Vector2.ZERO)
			var total := 0.0
			for i in worlds.weights.size():
				total += worlds.weights[i]
				check(absf(worlds.weights[i] - previous[i]) < 0.04, "Interrupted fade snapped")
			check(absf(total - 1.0) < 0.0001, "Interrupted fade lost normalization")
	check(game.rng.state == combat_rng, "Scenery consumed combat RNG")
	game.reset()
	check(worlds.clock == 0.0 and worlds.theme == 0 and worlds.weights[0] == 1.0,
		"Reset did not restore initial scenery")
	print("BACKGROUND_RELIEF checks=%d failures=%d %s" % [checked, failures, "; ".join(records)])
	get_tree().quit(1 if failures else 0)
