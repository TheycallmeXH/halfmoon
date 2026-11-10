# Run with the real Compatibility renderer to exercise the HUD draw path.
extends "res://scripts/boot.gd"

var failures := 0
var checked := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func kills() -> int:
	return int(game.kill_count)


func counter_image(value: int) -> Image:
	game.reset()
	game.set_process(false)
	game.paused = false
	game.score = value
	game.kill_count = value
	game.queue_redraw()
	for frame in 3:
		await RenderingServer.frame_post_draw
	return screen.get_texture().get_image().get_region(Rect2i(18, 20, 160, 14))


func _ready() -> void:
	super._ready()
	game.set_process(false)
	var at_99 := await counter_image(99)
	var at_100 := await counter_image(100)
	check(at_99.get_data() != at_100.get_data(), "HUD counter sticks at 99")
	var samples: Array[Image] = []
	for value in [0, 9, 10, 34, 99, 100, 134, 999, 1000, 9999, 10000]:
		samples.append(await counter_image(value))
		if value == 134:
			for frame in 8:
				await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://.shots/counter_crt_134.png")
	for index in range(1, samples.size()):
		check(samples[index].get_data() != samples[index - 1].get_data(), "Counter failed to advance")
	var sheet := Image.create(160, 22 * samples.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Ink.PAPER)
	for index in samples.size():
		sheet.blit_rect(samples[index], Rect2i(0, 0, 160, 14), Vector2i(0, index * 22))
	sheet.resize(640, sheet.get_height() * 4, Image.INTERPOLATE_NEAREST)
	sheet.save_png("res://.shots/counter_sheet.png")
	for method in ["beat_elite", "beat_boss", "beat_rival"]:
		game.reset()
		game.boss = {"p": Vector2(280, 108)}
		game.call(method)
		check(kills() == 1, "%s credited %d kills for one enemy" % [method, kills()])
		var reward: int = {"beat_elite": 4, "beat_boss": 12, "beat_rival": 18}[method]
		check(game.score == reward, "Weighted reward changed")
		check(game.loop_n == (2 if method == "beat_boss" else 1), "Victory advanced the wrong loop")
	for tier in [game.WEAPON_BOMB, game.WEAPON_FLAK, game.WEAPON_SPREAD]:
		for direct_last in [false, true]:
			game.reset()
			for position in [Vector2(210, 108), Vector2(200, 108), Vector2(300, 160)]:
				game.foe_shard(position.y)
				var foe: Dictionary = game.foes.back()
				foe.p = position
				foe.amp = 0.0
				foe.speed = 0.0
				foe.hp = 1
			if direct_last:
				var direct: Dictionary = game.foes[1]
				game.foes.remove_at(1)
				game.foes.append(direct)
			game.pb.append({"p": Vector2(200, 108), "v": Vector2.RIGHT * 500,
				"dmg": 99, "wk": tier})
			game.step_foes(0.0)
			var expected := 1 if tier == game.WEAPON_SPREAD else 2
			check(kills() == expected, "Splash credited the wrong number of kills")
			check(game.foes.size() == 3 - expected and game.foes.back().p == Vector2(300, 160),
				"Splash removed the wrong enemy or retained a dead target")
			check(not game.foes.any(func(f: Dictionary) -> bool: return int(f.hp) <= 0),
				"Splash retained a dead target")
			game.step_foes(0.0)
			check(kills() == expected, "A removed target credited a second kill")
	for source in ["bullet", "thorn", "barrage", "erase", "expiry"]:
		game.reset()
		var foe: Dictionary = game.Specials.create(game.Specials.Kind.DRONE, 108, 3)
		foe.p = Vector2(80, 108)
		foe.hp = 1
		foe.state = game.Specials.State.ATTACK
		foe.timer = 0.001 if source == "expiry" else 0.2
		game.foes.append(foe)
		match source:
			"bullet":
				game.pb.append({"p": Vector2(80, 108), "v": Vector2.RIGHT * 500, "dmg": 99})
				game.step_foes(0.0)
			"thorn":
				game.trigger_thorn(game.player)
			"barrage":
				game.trigger_barrage()
			"erase":
				game.do_erase()
			"expiry":
				game.step_foes(0.016)
		check(kills() == (0 if source == "expiry" else 1), "%s counted incorrectly" % source)
		check(game.foes.is_empty(), "%s retained a removed target" % source)
	game.reset()
	check(kills() == 0 and game.score == 0, "Restart retained counters")
	check(Ink.glyph_rows("3") == [30, 1, 1, 14, 1, 1, 30], "Digit 3 has an incorrect silhouette")
	check(Ink.glyph_rows("4") == [2, 6, 10, 18, 31, 2, 2], "Digit 4 has an incorrect silhouette")
	for digit in 10:
		var rows := Ink.glyph_rows(str(digit))
		check(rows.size() == 7 and Ink.glyph_ok(str(digit)) == 7, "Missing digit %d" % digit)
		for other in digit:
			check(rows != Ink.glyph_rows(str(other)), "Duplicate digit silhouette")
	at_100.save_png("res://.shots/counter_100.png")
	print("COUNTER_CHECK checked=%d failures=%d" % [checked, failures])
	get_tree().quit(0 if failures == 0 else 1)
