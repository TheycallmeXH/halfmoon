extends "res://scripts/boot.gd"

var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func press_fire(keycode: Key = KEY_X) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	_input(event)


func _ready() -> void:
	super._ready()
	set_process(false)
	game.set_process(false)
	# Continuous cadence must stay within one frame of the design interval,
	# including the 20 fps simulation clamp. No accumulated frame-rounding loss.
	for fps in [20, 30, 60, 165]:
		for kind in 8:
			game.reset()
			game.weapon = kind
			game.mag[kind] = 10000
			game.trigger = true
			var dt: float = 1.0 / fps
			var shots := 0
			var previous_shot := 0.0
			var worst_error := 0.0
			for frame in fps * 8:
				var loaded: int = game.mag[kind]
				game.step_fire(dt)
				var now := float(frame) * dt
				if game.mag[kind] < loaded:
					if shots > 0:
						worst_error = maxf(worst_error,
							absf(now - previous_shot - float(game.WEAPON_CD[kind])))
					previous_shot = now
					shots += 1
				game.pb.clear()
			var ideal := int(ceilf((8.0 - dt) / float(game.WEAPON_CD[kind])))
			check(absi(shots - ideal) <= 1, "Cadence drift fps=%d tier=%d count=%d ideal=%d" %
				[fps, kind, shots, ideal])
			check(worst_error <= dt + 0.0001, "Cadence jitter exceeds one frame")
			print("CADENCE fps=%d tier=%d shots=%d max_error=%.5f" % [fps, kind, shots, worst_error])
	# A complete press/release between polling frames still emits exactly once.
	for keycode in [KEY_X, KEY_Z, KEY_J, KEY_SPACE]:
		game.reset()
		press_fire(keycode)
		game.step_fire(1.0 / 60.0)
		check(game.mag[0] == 29 and game.pb.size() == 1, "Short key tap lost")
		game.step_fire(0.3)
		check(game.mag[0] == 29, "Short tap repeated")
	game.reset()
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	_input(mouse)
	game.step_fire(0.016)
	check(game.pb.size() == 1, "Short mouse tap lost")
	# Early tap survives a nearly completed cooldown, but never spends ammo early.
	game.reset()
	game.cooldown = 0.06
	press_fire()
	game.step_fire(0.03)
	check(game.mag[0] == 30, "Buffered tap bypassed cooldown")
	game.step_fire(0.031)
	check(game.mag[0] == 29, "Buffered tap lost at cooldown end")
	game.reset()
	game.cooldown = 0.4
	press_fire()
	for frame in 30:
		game.step_fire(0.02)
	check(game.mag[0] == 30, "Expired tap emitted late")
	# Idle time cannot accumulate shot credit.
	game.reset()
	game.step_fire(20.0)
	game.trigger = true
	game.step_fire(0.02)
	check(is_equal_approx(game.cooldown, game.WEAPON_CD[0]), "Idle banked firing credit")
	game.trigger = false
	game.step_fire(20.0)
	game.trigger = true
	game.step_fire(0.02)
	check(game.mag[0] == 28, "Idle caused a catch-up burst")
	# Last discharge starts one reload immediately without changing ammo budgets.
	for kind in 8:
		game.reset()
		game.weapon = kind
		game.mag[kind] = 1
		game.stock[kind] = 4 if kind > 0 else -1
		game.trigger = true
		game.step_fire(0.016)
		check(game.reloading and game.mag[kind] == 0, "Last shot delayed automatic reload")
		game.trigger = false
		game.step_reload(float(game.WEAPON_RELOAD[kind]))
		check(not game.reloading and game.mag[kind] > 0, "Automatic reload failed")
		if kind > 0:
			check(game.mag[kind] + game.stock[kind] == 4, "Automatic reload created ammunition")
	# A tap near reload completion fires once; old taps do not wait a full reload.
	game.reset()
	game.mag[0] = 0
	game._begin_reload()
	game.reload_t = game.reload_len - 0.04
	press_fire()
	game.step_reload(0.05)
	game.step_fire(0.05)
	check(game.mag[0] == 29, "Reload-end tap lost")
	game.reset()
	game.mag[0] = 0
	game._begin_reload()
	press_fire()
	for frame in 80:
		game.step_reload(0.02)
		game.step_fire(0.02)
	check(game.mag[0] == 30, "Old reload tap fired after expiry")
	for state in ["paused", "dead"]:
		game.reset()
		game.set(state, true)
		press_fire()
		check(game.fire_buffer == 0.0, "Inactive game accepted tap")
	game.reset()
	game.gauge = 1.0
	press_fire(KEY_SPACE)
	check(game.fire_buffer == 0.0, "ERASE press also queued a shot")
	game.queue_fire()
	game.paused = true
	game._process(0.016)
	check(game.fire_buffer == 0.0, "Pause retained queued shot")
	# Actual raster: a continuous sweep between the old 1/16 steps, symmetric
	# ready silhouette, fixed bounds and no growing disc in the ring center.
	game.reset()
	game.backdrop.set_scenery(false, true)
	game.reloading = true
	game.reload_len = 1.0
	var strip := Image.create(78 * 7, 23, false, Image.FORMAT_RGBA8)
	var previous_mass := -1.0
	var samples := {}
	for index in 7:
		var progress: float = [0.0, 0.25, 0.50, 0.52, 0.54, 0.75, 1.0][index]
		game.reload_t = progress
		game.queue_redraw()
		await RenderingServer.frame_post_draw
		var image: Image = screen.get_texture().get_image()
		strip.blit_rect(image, Rect2i(115, 181, 78, 23), Vector2i(index * 78, 0))
		var mass := 0.0
		for y in range(187, 199):
			for x in range(167, 179):
				mass += maxf(0.0, Ink.PAPER.get_luminance() - image.get_pixel(x, y).get_luminance())
		check(mass > previous_mass, "Reload sweep does not advance continuously")
		previous_mass = mass
		samples[image.get_region(Rect2i(167, 187, 12, 12)).get_data().hex_encode()] = true
		if progress < 1.0:
			check(image.get_pixel(172, 192).get_luminance() > 0.8, "Reload center became a solid disc")
		if index == 2:
			get_viewport().get_texture().get_image().save_png("res://.shots/reload-smooth-crt.png")
	check(samples.size() == 7, "Reload reverted to stepped progress")
	strip.resize(strip.get_width() * 3, strip.get_height() * 3, Image.INTERPOLATE_NEAREST)
	strip.save_png("res://.shots/reload-smooth-strip.png")
	# Inspect the discharge silhouette on every tier. Specials always emit
	# from their actual single hardpoint; the two rapid guns alternate wings.
	var gallery := Image.create(8 * 56, 3 * 30, false, Image.FORMAT_RGBA8)
	for kind in 8:
		game.reset()
		game.backdrop.set_scenery(false, true)
		game.invuln = 0.0
		game.weapon = kind
		game.mag[kind] = 4
		game.trigger = true
		game.step_fire(0.0)
		var side := (-1.0 if game.cannon == 0 else 1.0) if kind in [0, 2] else 1.0
		var muzzle: Vector2 = game.wing_muzzle(game.player, side)
		check(game.pb[0].p == muzzle, "Projectile and flash hardpoints disagree")
		game.pb.clear()
		for row in 3:
			game.shot_pulse = 1.0 - float(row) * 0.5
			game.queue_redraw()
			await RenderingServer.frame_post_draw
			var image: Image = screen.get_texture().get_image()
			gallery.blit_rect(image, Rect2i(Vector2i(game.player) - Vector2i(20, 15),
				Vector2i(56, 30)), Vector2i(kind * 56, row * 30))
	gallery.resize(gallery.get_width() * 3, gallery.get_height() * 3, Image.INTERPOLATE_NEAREST)
	gallery.save_png("res://.shots/shooting-muzzle-gallery.png")
	print("SHOOTING_FEEL checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
