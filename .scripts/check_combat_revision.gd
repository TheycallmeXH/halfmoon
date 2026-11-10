extends "res://scripts/boot.gd"

var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func key_reload(echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.pressed = true
	event.echo = echo
	_input(event)


func fire_at(p: Vector2, major: bool) -> void:
	game.pb.append({"p": p, "v": Vector2.RIGHT * 500, "dmg": 1})
	if major:
		game.step_pb(0.0)
	else:
		game.step_foes(0.0)


func capture_bar(enemy: Dictionary, major: bool) -> Image:
	game.queue_redraw()
	await RenderingServer.frame_post_draw
	var rect: Rect2 = game.enemy_health_rect(enemy, major).grow(1)
	return screen.get_texture().get_image().get_region(Rect2i(rect))


func _ready() -> void:
	super._ready()
	set_process(false)
	game.set_process(false)
	for kind in range(game.WEAPON_BASE, game.WEAPON_LAST + 1):
		for reserve in [0, 1, 3, 100]:
			game.reset()
			game.weapon = kind
			var capacity: int = game.WEAPON_MAG[kind]
			game.mag[kind] = maxi(1, capacity / 2)
			game.stock[kind] = reserve if kind > 0 else -1
			var loaded: int = game.mag[kind]
			var before: int = loaded + maxi(0, game.stock[kind])
			key_reload()
			check(game.reloading == (kind == 0 or reserve > 0), "R did not respect reservoir")
			check(game.weapon == kind, "Manual reload discarded a usable magazine")
			if game.reloading:
				game.step_reload(float(game.reload_len) * 0.5)
				check(game.mag[kind] == loaded, "Ammo refilled before timer completed")
				var age: float = game.reload_t
				key_reload(true)
				key_reload()
				check(game.reload_t == age, "Repeated R restarted reload")
				game.step_reload(float(game.reload_len))
				check(not game.reloading and game.mag[kind] <= capacity, "Reload did not finish")
				if kind > 0:
					check(game.mag[kind] + game.stock[kind] == before, "Partial reload lost/created ammunition")
					check(game.mag[kind] == mini(capacity, before), "Partial reload loaded wrong count")
				else:
					check(game.mag[kind] == capacity, "Base reload failed")
			game.mag[kind] = capacity
			key_reload()
			check(not game.reloading, "Full magazine started reload")
		game.reset()
		if kind > 0:
			game._grant_tier(kind)
			game._cycle_tier(1)
			check(game.weapon == game.WEAPON_BASE, "Single-special wheel cannot select base")
			game._cycle_tier(-1)
			check(game.weapon == kind, "Single-special wheel cannot return")
			game.mag[kind] = 1
			game.stock[kind] = 7
			key_reload()
			game.step_reload(0.2)
			game._cycle_tier(1)
			check(not game.reloading and game.mag[kind] == 1 and game.stock[kind] == 7,
				"Switching during reload spent ammo")
			game._select_tier(kind)
			key_reload()
			game.step_reload(0.2)
			var age: float = game.reload_t
			game._grant_tier(kind)
			check(is_equal_approx(game.reload_t, age), "Pickup restarted reload")
			var budget: int = 8 + int(game.WEAPON_RESERVE[kind])
			game.step_reload(float(game.reload_len))
			check(game.mag[kind] + game.stock[kind] == budget, "Pickup/reload lost ammunition")
	game.reset()
	game.mag[0] = 1
	game.paused = true
	key_reload()
	check(not game.reloading, "R reloaded during pause")
	game.paused = false
	game.dead = true
	key_reload()
	check(not game.reloading, "R reloaded after death")
	# Health bars are measured in the raw viewport, excluding CRT time noise.
	for target in 11:
		game.reset()
		game.backdrop.set_moon(false)
		game.backdrop.sky.visible = false
		game.t = 10.0
		game.health_clock = 10.0
		var major := target >= 5
		var enemy: Dictionary
		if target < 3:
			game.call(["foe_shard", "foe_drift", "foe_coil"][target], 108.0)
			enemy = game.foes.back()
			enemy.speed = 0.0
			enemy.amp = 0.0
		elif target < 5:
			enemy = game.Specials.create(target, 108, 3)
			enemy.state = game.Specials.State.COOL
			enemy.timer = 100.0
			game.foes.append(enemy)
		else:
			if target == 5:
				game.start_boss()
			elif target == 6:
				game.start_rival()
			else:
				game.start_elite()
				game.boss.variant = target - 7
			enemy = game.boss
			enemy.t = 3.0
			enemy.station_t = 1.0
		enemy.p = Vector2(260, 108)
		enemy.hp = 40
		enemy.max = 40
		var hidden := await capture_bar(enemy, major)
		fire_at(enemy.p, major)
		check(int(enemy.hp) == 39, "Health test failed to hit target")
		check(is_equal_approx(enemy.health_until, 12.0), "Hit did not start two-second bar")
		game.health_clock = 10.2
		var shown := await capture_bar(enemy, major)
		check(shown.get_data() != hidden.get_data(), "Hit health bar did not render")
		game.t = 11.5
		game.health_clock = 11.5
		var held := await capture_bar(enemy, major)
		check(held.get_data() == shown.get_data(), "Health bar disappeared before two seconds")
		fire_at(enemy.p, major)
		check(is_equal_approx(enemy.health_until, 13.5), "Repeated hit failed to refresh health bar")
		game.t = 13.51
		game.health_clock = 13.51
		var expired := await capture_bar(enemy, major)
		check(expired.get_data() == hidden.get_data(), "Health bar remained after two seconds")
		game._mark_enemy_hit(enemy)
		var deadline: float = enemy.health_until
		game._advance_loop()
		check(enemy.health_until == deadline and game.health_clock == 13.51,
			"Loop rewind changed health visibility duration")
	# Splash, reflection and ERASE must reveal surviving targets as well.
	for source in ["bomb", "flak", "thorn", "erase"]:
		game.reset()
		for x in [200, 210]:
			game.foe_shard(108)
			var enemy: Dictionary = game.foes.back()
			enemy.p = Vector2(x, 108)
			enemy.amp = 0.0
			enemy.speed = 0.0
			enemy.hp = 40
			enemy.max = 40
		if source == "thorn":
			game.trigger_thorn(Vector2(205, 108))
		elif source == "erase":
			game.do_erase()
		else:
			game.pb.append({"p": Vector2(200, 108), "v": Vector2.RIGHT * 500, "dmg": 1,
				"wk": game.WEAPON_BOMB if source == "bomb" else game.WEAPON_FLAK})
			game.step_foes(0.0)
		for enemy in game.foes:
			check(enemy.get("health_until", -1) == 2.0, "Secondary damage missed health reveal")
	for dt in [1.0 / 30, 1.0 / 60, 1.0 / 165, 0.05]:
		for variant in range(1, 4):
			game.reset()
			game.loop_n = 2
			game.t = 50
			game.start_elite()
			game.boss.variant = variant
			var elapsed := 0.0
			var retreat_time := 0.0
			while game.boss.has("is_elite") and elapsed < 39:
				if float(game.boss.get("retreat_age", 0)) > 0:
					retreat_time += dt
				game.t += dt
				game.step_boss(dt)
				elapsed += dt
				if elapsed < 32:
					check(game.boss.has("is_elite"), "New elite retired before 32 seconds")
			check(game.boss.is_empty() and elapsed < 38 and retreat_time > 1.2,
				"Elite exit too short or blocked next boss")
		var turret: Dictionary = game.Specials.create(game.Specials.Kind.TURRET, 108, 3)
		var elapsed := 0.0
		var departure := -1.0
		while not turret.expired and elapsed < 21:
			turret.p = game.Specials.step(turret, Vector2(52, 108), dt)
			elapsed += dt
			if int(turret.state) == game.Specials.State.LEAVE and departure < 0:
				departure = elapsed
		check(turret.expired and turret.shots == 3 and departure > 12.0,
			"Turret did not remain for three volleys")
		check(elapsed - departure > 1.2, "Turret retreat too short")
	game.reset()
	game.visible = false
	game.backdrop.sky.visible = false
	game.backdrop.set_moon(false)
	var worlds: Node2D = game.backdrop.worlds
	worlds.weights.fill(0)
	worlds.queue_redraw()
	await RenderingServer.frame_post_draw
	var blank: Image = screen.get_texture().get_image()
	worlds.set_stage(4)
	worlds.step(3, Vector2.ZERO)
	await RenderingServer.frame_post_draw
	var background: Image = screen.get_texture().get_image()
	var bottom_changes := 0
	for y in range(177, 200):
		for x in range(30, 355):
			if background.get_pixel(x, y) != blank.get_pixel(x, y):
				bottom_changes += 1
	check(bottom_changes > 30, "Bottom background is still clipped")
	game.visible = true
	game.backdrop.sky.visible = true
	game.reset()
	game.loop_n = 4
	game.feed_backdrop(3)
	game.start_elite()
	game.boss.variant = 2
	game.boss.p = Vector2(270, 108)
	game.boss.t = 3
	game.boss.station_t = 1
	game.boss.hp = 35
	game._mark_enemy_hit(game.boss)
	for y in [70, 155]:
		game.foe_drift(y)
		var enemy: Dictionary = game.foes.back()
		enemy.p = Vector2(205, y)
		game._mark_enemy_hit(enemy)
	game.health_clock += 0.2
	game.queue_redraw()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.shots/combat-revision.png")
	print("COMBAT_REVISION checks=%d failures=%d bottom_pixels=%d" % [checked, failures, bottom_changes])
	get_tree().quit(1 if failures else 0)
