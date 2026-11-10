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
	var backdrop: Node2D = game.backdrop
	var worlds: Node2D = backdrop.worlds
	var random_state: int = game.rng.state
	for stage in range(1, 13):
		backdrop.set_stage(stage)
		var before: PackedFloat32Array = worlds.weights.duplicate()
		for frame in 180:
			var previous_weights: PackedFloat32Array = worlds.weights.duplicate()
			backdrop.step(Vector2.ZERO, 1.0 / 60.0)
			var total := 0.0
			for index in worlds.weights.size():
				var weight: float = worlds.weights[index]
				total += weight
				check(weight >= 0.0 and weight <= 1.0, "Invalid world blend")
				check(absf(weight - previous_weights[index]) < 0.04, "Background snapped during crossfade")
			check(absf(total - 1.0) < 0.0001, "World blend is not normalized")
		check(is_equal_approx(worlds.weights[(stage - 1) % 6], 1.0), "World did not settle")
		if stage > 1:
			check(before != worlds.weights, "World did not change")
	check(game.rng.state == random_state, "Background consumed combat RNG")
	check(backdrop.sky._visibility(game.player, false) == 1.0, "Radial player clearing returned")
	check(backdrop.sky._visibility(Vector2(40, 40), false) == 0, "HUD mask missing")
	var last := -1
	for cycle in 12:
		var bag := {}
		for slot in 4:
			game.start_elite()
			var variant := int(game.boss.variant)
			check(variant != last, "Adjacent elite repeat")
			check(not bag.has(variant), "Elite bag repeated")
			bag[variant] = true
			last = variant
	for kind in range(1, 4):
		for dt in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0, 0.05]:
			for low in [false, true]:
				game.reset()
				game.start_elite()
				game.boss.variant = kind
				if low:
					game.boss.hp = int(game.boss.max) / 2
				var actions := {}
				var first_shot := -1.0
				var shot_count := 0
				var patterns := {}
				var elapsed := 0.0
				while not game.boss.is_empty() and elapsed < 39.0:
					var previous: Vector2 = game.boss.p
					var bullets: int = game.eb.size()
					game.step_elite(dt)
					elapsed += dt
					if game.boss.is_empty():
						break
					var b: Dictionary = game.boss
					if b.has("station_t"):
						if b.has("pattern"):
							patterns[int(b.pattern)] = true
						var resident := float(b.t) - float(b.station_t)
						actions[int(b.get("action", 0))] = true
						if resident < game.EliteVariants.COMBAT_LIFE:
							check(b.p.x >= 190 and b.p.x < 272, "Elite exceeded enemy half")
							check((b.p as Vector2).distance_to(previous) <= 300 * dt + 0.01,
								"Elite movement jumped")
							if game.eb.size() > bullets:
								if first_shot < 0:
									first_shot = resident
								shot_count += game.eb.size() - bullets
					check(game.eb.size() < 200, "Elite projectile budget exceeded")
				check(actions.size() == 4, "Elite lacks full action cycle")
				check(patterns.size() == 2, "Elite lacks alternating attacks")
				check(first_shot >= 1.25 + float(game.EliteVariants.WARN[kind]) - 0.08
					if not low else first_shot >= 0.85 + float(game.EliteVariants.WARN[kind]) - 0.08,
					"Elite fired before warning")
				check(shot_count > 15, "Elite did not fire")
				check(game.boss.is_empty() and elapsed < 38.0, "Elite retreat failed")
				check(game.score == 0 and game.kill_count == 0, "Retreat awarded kill")
	game.reset()
	check(game.elite_deck.is_empty() and game.elite_last == -1, "Reset kept elite deck")
	check(worlds.theme == 0 and worlds.clock == 0, "Reset kept background")
	for kind in range(1, 4):
		for pattern in 2:
			for low in [false, true]:
				var attacker := {"variant": kind, "p": Vector2(268, 108), "hp": 4 if low else 10,
					"max": 10, "t": 4.0, "station_t": 1.0, "action": 1,
					"action_age": float(game.EliteVariants.WARN[kind]) - 0.001,
					"aim": PI, "lane": 108, "anchor": Vector2(268, 108),
					"pattern": pattern, "volley": false, "bend": -24.0 if pattern == 1 else 0.0}
				var opening: Array[Dictionary] = game.EliteVariants.step(attacker, Vector2(20, 180), 0.01)
				var follow: Array[Dictionary] = []
				for frame in 40:
					follow.append_array(game.EliteVariants.step(attacker, Vector2(20, 180), 0.01))
				check(is_equal_approx(float(attacker.aim), PI), "Alternating attack changed locked aim")
				if kind == 1:
					check(opening.size() == ((8 if low else 6) if pattern == 1 else (7 if low else 5)),
						"Foldwing port volley count changed")
					check(follow.size() == (7 if low and pattern == 0 else 0), "Foldwing stacked unsafe extra volley")
				elif kind == 2:
					check(opening.size() == ((7 if low else 6) if pattern == 1 else (12 if low else 10)),
						"Orrery ring count changed")
					check(follow.size() == (opening.size() if pattern == 1 else 0), "Orrery staggered volley failed")
					for shot in opening + follow:
						check(absf(wrapf((shot.v as Vector2).angle() - PI, -PI, PI)) >= 0.42,
							"Orrery closed its telegraphed escape gap")
				else:
					check(opening.is_empty() and follow.size() == (5 if low else 3), "Lancer fired before dash completed")
					check(absf(float(attacker.p.y) - (84.0 if pattern == 1 else 108.0)) < 0.01,
						"Lancer did not follow its marked lane")
	for kind in range(1, 4):
		var locked := {"variant": kind, "p": Vector2(260, 108), "hp": 10, "max": 10,
			"t": 3.0, "station_t": 1.0, "action": 1, "action_age": 0.2,
			"aim": 1.23, "lane": 108, "anchor": Vector2(260, 108)}
		game.EliteVariants.step(locked, Vector2(10, 20), 0.05)
		check(is_equal_approx(locked.aim, 1.23), "Elite tracked after aim lock")
		for source in ["erase", "thorn", "bullet"]:
			game.reset()
			game.start_elite()
			game.boss.variant = kind
			game.boss.p = Vector2(80, 108)
			game.boss.hp = 1
			match source:
				"erase":
					game.do_erase()
				"thorn":
					game.trigger_thorn(game.player)
				"bullet":
					game.pb.append({"p": Vector2(80, 108), "v": Vector2.RIGHT * 500, "dmg": 99})
					game.step_pb(0.0)
			check(game.kill_count == 1 and game.score == 4, "New elite kill reward failed")
			check(game.boss.is_empty() and game.loop_n == 1, "Elite kill advanced loop")
	game.reset()
	game.paused = true
	var frozen: float = worlds.clock
	game._process(0.05)
	check(worlds.clock == frozen, "Pause advanced scenery")
	# Isolate the engraved layer to measure visibility and exclusion zones.
	game.visible = false
	backdrop.sky.visible = false
	backdrop.set_moon(false)
	worlds.weights.fill(0.0)
	worlds.queue_redraw()
	await RenderingServer.frame_post_draw
	var blank: Image = screen.get_texture().get_image()
	for stage in range(2, 7):
		worlds.set_stage(stage)
		worlds.step(3.0, Vector2.ZERO)
		await RenderingServer.frame_post_draw
		var frame: Image = screen.get_texture().get_image()
		var changed := 0
		var protected_changes := 0
		var cores := 0
		for y in 216:
			for x in 384:
				var p := Vector2(x, y)
				var color := frame.get_pixel(x, y)
				if color != blank.get_pixel(x, y):
					changed += 1
					if backdrop.sky._visibility(p, false) == 0:
						protected_changes += 1
					if minf(color.r, minf(color.g, color.b)) > 0.97:
						cores += 1
		check(changed > 80, "Environment engraving invisible")
		check(protected_changes == 0, "Environment polluted protected subject/HUD")
		check(cores == 0, "Environment added bloom core")
		var before_motion := frame.get_data()
		worlds.step(1.0, Vector2.ZERO)
		await RenderingServer.frame_post_draw
		check(screen.get_texture().get_image().get_data() != before_motion, "Environment animation static")
	game.visible = true
	backdrop.sky.visible = true
	# Render one representative environment per page and every elite pose.
	var sheet := Image.create(384 * 3, 216 * 2, false, Image.FORMAT_RGBA8)
	for stage in range(1, 7):
		game.reset()
		game.loop_n = stage
		game.feed_backdrop(3.0)
		game.paused = false
		if stage > 1:
			game.start_elite()
			game.boss.variant = 1 + (stage - 2) % 3
			game.boss.p = Vector2(260, 112)
			game.boss.t = 3.0
			game.boss.station_t = 1.0
			game.boss.action = 1 if stage < 5 else 2
			game.boss.action_age = 0.4
			game.boss.charge = 0.65
			game.boss.aim = PI
		game.queue_redraw()
		await RenderingServer.frame_post_draw
		var image: Image = game.get_viewport().get_texture().get_image()
		image.save_png("res://.shots/world-%d.png" % stage)
		sheet.blit_rect(image, Rect2i(0, 0, 384, 216),
			Vector2i((stage - 1) % 3 * 384, (stage - 1) / 3 * 216))
	sheet.save_png("res://.shots/worlds-contact-sheet.png")
	var gallery := Image.create(80 * 7, 84 * 3, false, Image.FORMAT_RGBA8)
	for kind in range(1, 4):
		for pose in 7:
			game.reset()
			game.start_elite()
			game.boss.variant = kind
			game.boss.p = Vector2(260, 112)
			game.boss.t = 0.55 if pose == 0 else (23.3 if pose == 4 else 3.0)
			game.boss.station_t = 1.0
			game.boss.action = 1 if pose in [2, 5] else (2 if pose in [3, 6] else 0)
			game.boss.charge = 0.85 if pose in [2, 5] else 0.0
			game.boss.recoil = 1.0 if pose in [3, 6] else 0.0
			game.boss.aim = PI
			game.boss.pattern = 1 if pose >= 5 else 0
			game.boss.bend = -24.0 if pose >= 5 else 0.0
			game.boss.retreat_age = 0.55 if pose == 4 else 0.0
			game.queue_redraw()
			await RenderingServer.frame_post_draw
			gallery.blit_rect(screen.get_texture().get_image(), Rect2i(220, 70, 80, 84),
				Vector2i(pose * 80, (kind - 1) * 84))
	gallery.resize(1120, 504, Image.INTERPOLATE_NEAREST)
	gallery.save_png("res://.shots/elite-animation-gallery.png")
	for encounter in ["elite", "small-boss"]:
		game.reset()
		game.loop_n = 4
		game.t = 52.0
		game.wave_clock = 26.0
		if encounter == "elite":
			game.start_elite()
			game.boss.variant = 2
		else:
			game.start_boss()
		for frame in 660:
			var dt := 1.0 / 60.0
			game.t += dt
			game.invuln = 999.0
			game.step_spawn(dt)
			game.step_boss(dt)
			game.step_foes(dt)
			game.step_eb(dt)
			game.step_rings(dt)
			game.feed_backdrop(dt)
		check(not game.foes.is_empty() and not game.boss.is_empty(), "Rendered coexistence encounter lost companions")
		game.queue_redraw()
		_process(3.0)
		transition_age = TRANSITION_TIME
		_process(0.0)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://.shots/%s-escorts-crt.png" % encounter)
	print("WORLDS_ELITES checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
