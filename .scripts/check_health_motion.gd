extends "res://scripts/boot.gd"

var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func capture(rect: Rect2i) -> Image:
	game.queue_redraw()
	await RenderingServer.frame_post_draw
	return screen.get_texture().get_image().get_region(rect)


func differences(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				count += 1
	return count


func _ready() -> void:
	super._ready()
	set_process(false)
	game.set_process(false)
	var ages := [0.0, 0.04, 0.08, 0.20, 1.50, 1.78, 1.87, 1.95, 2.01]
	var sheet := Image.create(50 * ages.size(), 12 * 3, false, Image.FORMAT_RGBA8)
	sheet.fill(Ink.PAPER)
	for kind in 3:
		game.reset()
		game.backdrop.set_moon(false)
		game.backdrop.sky.visible = false
		game.backdrop.worlds.visible = false
		var enemy: Dictionary
		if kind == 0:
			game.foe_shard(108)
			enemy = game.foes.back()
		elif kind == 1:
			game.start_elite()
			game.boss.variant = 2
			enemy = game.boss
		else:
			game.start_boss()
			enemy = game.boss
		enemy.p = Vector2(260, 108)
		enemy.t = 3.0
		enemy.hp = 6
		enemy.max = 10
		var bar: Rect2 = game.enemy_health_rect(enemy, kind > 0)
		check(bar.size.y == 2 and bar.size.x <= 32, "Health bar too large")
		var area := Rect2i(235, int(bar.position.y) - 4, 50, 12)
		var blank := await capture(area)
		game._mark_enemy_hit(enemy)
		var counts: Array[int] = []
		for index in ages.size():
			game.health_clock = ages[index]
			var image := await capture(area)
			counts.append(differences(image, blank))
			sheet.blit_rect(image, Rect2i(0, 0, 50, 12), Vector2i(index * 50, kind * 12))
			if index == 3:
				var rows := {}
				for y in 12:
					for x in 50:
						if image.get_pixel(x, y) != blank.get_pixel(x, y):
							rows[y] = true
				check(rows.size() <= 2, "Health bar gained an outline or thick halo")
		check(counts[0] == 0 and counts[8] == 0, "Health animation endpoint popped")
		check(counts[1] > 0 and counts[1] < counts[2] and counts[2] < counts[3],
			"Health reveal did not unfold")
		check(counts[3] == counts[4], "Health animation did not settle")
		check(counts[5] < counts[4] and counts[6] < counts[5] and counts[7] < counts[6],
			"Health exit did not contract")
		game.health_clock = 1.86
		var before_refresh := await capture(area)
		game._mark_enemy_hit(enemy)
		var after_refresh := await capture(area)
		check(before_refresh.get_data() == after_refresh.get_data(), "Hit during fade caused a pop")
		game.health_clock += 0.2
		check(is_equal_approx(game.enemy_health_visibility(enemy), 1.0), "Refreshed health failed to reopen")
		game.paused = true
		var clock: float = game.health_clock
		game._process(0.05)
		check(game.health_clock == clock, "Pause advanced health animation")
	sheet.resize(sheet.get_width() * 3, sheet.get_height() * 3, Image.INTERPOLATE_NEAREST)
	sheet.save_png("res://.shots/health-animation-strip.png")
	print("HEALTH_MOTION checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
