extends SceneTree

const Game = preload("res://scripts/game.gd")
var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		if failures <= 8:
			push_error(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var game := Game.new()
	root.add_child(game)
	game.set_process(false)
	# With zero elapsed time, switching from entrance to combat cannot move
	# the body. An off-center approach also catches a hardcoded center reset.
	game.reset()
	game.start_boss()
	game.boss.p = Vector2(Game.W * 0.775, 81)
	game.boss.t = 1.5
	game.step_boss(0.0)
	check((game.boss.p as Vector2).is_equal_approx(Vector2(Game.W * 0.775, 81)),
		"Cell boss changed position at zero-time entrance handoff")
	game.reset()
	game.start_rival()
	var original: Vector2 = game.boss.p
	game.step_rival(0.0)
	check((game.boss.p as Vector2).is_equal_approx(original),
		"Rival boundary clamp teleported the entrance")
	for dt in [0.05, 1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0]:
		for low in [false, true]:
			for variant in range(-1, 4):
				game.reset()
				if variant < 0:
					game.start_boss()
				else:
					game.start_elite()
					game.boss.variant = variant
				if low:
					game.boss.hp = int(game.boss.max) / 2
				var entered := false
				var worst := 0.0
				for frame in int(3.5 / dt):
					var before: Vector2 = game.boss.p
					var dock := Game.W * (0.775 if variant < 0 else 0.70)
					var approaching := before.x > dock + 1.0
					game.step_boss(dt)
					var after: Vector2 = game.boss.p
					var distance := before.distance_to(after)
					if not approaching:
						entered = true
						worst = maxf(worst, distance)
						check(distance <= (300.0 if variant > 0 else 120.0) * dt + 0.01,
							"Entrance/combat jump variant=%d dt=%.5f distance=%.3f" %
							[variant, dt, distance])
					else:
						check(distance <= 620.0 * dt + 0.01, "Approach exceeded entrance speed")
					game.eb.clear()
				check(entered, "Enemy never completed entrance")
				print("HANDOFF variant=%d low=%s dt=%.5f max_step=%.4f" % [variant, low, dt, worst])
		for lane in [30.0, 108.0, 186.0]:
			game.reset()
			game.player.y = lane
			game.start_rival()
			for frame in int(2.0 / dt):
				var before: Vector2 = game.boss.p
				game.step_rival(dt)
				var after: Vector2 = game.boss.p
				check(after.distance_to(before) <= Game.SPEED * dt + 0.01,
					"Rival approach snapped inside bounds")
				if before.x <= Game.RIGHT_LIMIT:
					check(after.x <= Game.RIGHT_LIMIT, "Rival escaped after entering")
				game.eb.clear()
	game.reset()
	check(game.boss.is_empty(), "Restart retained entrance state")
	game.free()
	print("ENTRY_HANDOFF checks=%d failures=%d" % [checked, failures])
	quit(1 if failures else 0)
