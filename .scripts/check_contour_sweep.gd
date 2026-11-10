extends SceneTree


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var game = load("res://scripts/game.gd").new()
	root.add_child(game)
	game.set_process(false)
	game.hide()
	var cases: Array[PackedVector2Array] = []
	var raw_failures := 0
	var checked := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 4083
	for sample in 30000:
		game.focus_on = sample % 2 == 0
		game.hull_yaw = rng.randf_range(-1, 1)
		game.hull_roll = rng.randf_range(-1, 1)
		game.t = rng.randf_range(0, 30)
		var angle: float = game.hull_yaw * 0.13 - game.hull_roll * 0.04
		var hull: PackedVector2Array = game._hull_xf(Vector2(80, 80) +
			Vector2(rng.randf(), rng.randf()), angle)
		assert(not Geometry2D.triangulate_polygon(hull).is_empty(),
			"Player silhouette is invalid before offset")
		var bad := false
		for distance in [2.0, 3.0]:
			for contour in Geometry2D.offset_polygon(hull, distance, Geometry2D.JOIN_ROUND):
				var pixels := PackedVector2Array()
				for point in contour:
					pixels.append(point.floor())
				checked += 1
				if Geometry2D.triangulate_polygon(pixels).is_empty():
					raw_failures += 1
					bad = true
		if bad and cases.size() < 32 and not cases.has(hull):
			cases.append(hull)
			if cases.size() == 1:
				print("CONTOUR_REPRO focus=%s yaw=%s roll=%s t=%s" %
					[game.focus_on, game.hull_yaw, game.hull_roll, game.t])
	if raw_failures == 0:
		push_error("Sweep did not reach the original invalid contour")
		quit(1)
		return
	var probe := Node2D.new()
	root.add_child(probe)
	var index := [0]
	probe.draw.connect(func(): Ink.paper_edge(probe, cases[index[0]]))
	for sample in cases.size():
		index[0] = sample
		probe.queue_redraw()
		await process_frame
		await RenderingServer.frame_post_draw
	print("CONTOUR_SWEEP offsets=%d raw_invalid=%d rendered_repros=%d" %
		[checked, raw_failures, cases.size()])
	quit()
