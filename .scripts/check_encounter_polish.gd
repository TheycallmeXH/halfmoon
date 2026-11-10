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
	game.invuln = 999.0
	var rng := RandomNumberGenerator.new()
	var seen := {}
	for seed_value in 40:
		rng.seed = seed_value
		var recent: Array[int] = []
		var last := -1
		for i in 100:
			var wave: Dictionary = game.Waves.plan(4, 42.0, rng, last, PackedInt32Array([0, 0, 0, 0, 0]), 12, recent)
			if wave.members.size() > 1:
				check(not recent.has(int(wave.formation)), "Shape repeated inside four-wave memory")
				recent.push_front(int(wave.formation))
				recent.resize(mini(4, recent.size()))
			seen[wave.name] = true
			last = int(wave.formation)
	check(seen.size() >= 15, "Pair/triple shape pool lacks diversity")
	for dt in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0, 0.05]:
		game.reset()
		game.loop_n = 2
		game.t = 50.0
		game.start_elite()
		game.boss.variant = 0
		var elapsed := 0.0
		var saw_retreat := false
		while game.boss.has("is_elite") and elapsed < 27.0:
			game.t += dt
			game.step_boss(dt)
			elapsed += dt
			if elapsed < 22.0:
				check(not game.boss.is_empty(), "Elite left before a full combat window")
			if not game.boss.is_empty() and game.boss.has("station_t"):
				var resident := float(game.boss.t) - float(game.boss.station_t)
				if resident <= 22.0:
					check(float(game.boss.p.x) < 272.0, "Elite retreated early")
				else:
					saw_retreat = true
		check(game.boss.is_empty() and saw_retreat and elapsed < 26.0, "Elite blocked the next boss or popped away")
		check(game.kill_count == 0, "Elite retreat counted as a kill")
		var f: Dictionary = game.Specials.create(game.Specials.Kind.DRONE, 108, 3)
		f.p = Vector2(314, 108)
		f.state = game.Specials.State.ATTACK
		f.timer = 1.25
		for frame in int(0.5 / dt):
			var before: Vector2 = f.p
			f.p = game.Specials.step(f, game.player, dt)
			if float(f.state_age) > 0.20:
				check(is_equal_approx(before.distance_to(f.p) / dt, 335.0), "Drone failed to reach charge speed")
			check(f.wake.size() <= 48, "Drone wake exceeded budget")
		var distance := 314.0 - float(f.p.x)
		check(absf(distance - game.Specials._charge_distance(float(f.state_age))) < 0.01, "Charge distance depends on FPS")
		check((f.wake[0].p as Vector2).x > float(f.p.x) + 40.0, "Wake follows hull instead of remaining in world space")
		# Segment contact must still catch a fast crossing between frames.
		f.p = Vector2(40, 108)
		check(game.Specials.hits(f, Vector2(52, 108), Vector2(70, 108)), "Fast drone tunneled through player")
	game.reset()
	game.start_elite()
	game.boss.p = Vector2(330, 108)
	game.boss.t = 24.0
	game.boss.station_t = 1.0
	game.boss.hp = 1
	game.step_elite(0.016)
	game.pb.append({"p": game.boss.p, "v": Vector2.RIGHT * 500, "dmg": 1})
	game.step_pb(0.0)
	check(game.boss.is_empty() and game.kill_count == 1 and game.score == 4, "Retreating elite could not be killed normally")
	game.reset()
	game.paused = false
	game.foes.clear()
	game.loop_n = 3
	var drone: Dictionary = game.Specials.create(game.Specials.Kind.DRONE, 94, 3)
	drone.p = Vector2(304, 94)
	drone.state = game.Specials.State.ATTACK
	drone.timer = 1.25
	drone.dir = Vector2(-1.0, 0.17).normalized()
	game.foes.append(drone)
	for frame in 20:
		drone.p = game.Specials.step(drone, game.player, 1.0 / 60.0)
	game.queue_redraw()
	mat.set_shader_parameter("transition_glitch", 0.0)
	for frame in 12:
		await RenderingServer.frame_post_draw
	var original := get_viewport().get_texture().get_image()
	original.save_png("res://.shots/encounter_drone.png")
	mat.set_shader_parameter("grain", 0.0)
	mat.set_shader_parameter("flicker", 0.0)
	mat.set_shader_parameter("shimmer", 0.0)
	# Compare the same frozen scene through inactive and active signal distortion.
	for frame in 6:
		await RenderingServer.frame_post_draw
	var clean := get_viewport().get_texture().get_image()
	mat.set_shader_parameter("transition_phase", 0.34)
	mat.set_shader_parameter("transition_glitch", 0.65)
	for frame in 6:
		await RenderingServer.frame_post_draw
	var distorted := get_viewport().get_texture().get_image()
	distorted.save_png("res://.shots/encounter_glitch.png")
	var changed := 0
	var hud_changes := 0
	for y in range(0, clean.get_height(), 3):
		for x in range(0, clean.get_width(), 3):
			if clean.get_pixel(x, y) != distorted.get_pixel(x, y):
				changed += 1
				if y < clean.get_height() / 6:
					hud_changes += 1
	check(changed > 100, "Signal transition failed to render")
	check(hud_changes == 0, "Signal transition corrupted upper HUD")
	mat.set_shader_parameter("transition_glitch", 0.0)
	transition_age = TRANSITION_TIME
	game.start_elite()
	check(transition_age == 0.0, "Elite entry failed to trigger transition")
	game.paused = true
	_process(0.1)
	check(transition_age == 0.0, "Pause advanced scene transition")
	game.paused = false
	for i in 60:
		_process(1.0 / 60.0)
	check(is_equal_approx(float(mat.get_shader_parameter("transition_glitch")), 0.0), "Transition failed to settle")
	game.reset()
	check(game.wave_recent.is_empty(), "Restart retained recent shapes")
	print("ENCOUNTER_POLISH assertions=%d failures=%d rendered_changes=%d hud_changes=%d" % [checked, failures, changed, hud_changes])
	get_tree().quit(0 if failures == 0 else 1)
