extends "res://scripts/boot.gd"

const Items = preload("res://scripts/passives.gd")

class Icons extends Node2D:
	func _draw() -> void:
		draw_rect(Rect2(0, 0, 384, 216), Ink.PAPER)
		for slot in Items.HUD_ORDER.size():
			var item: int = Items.HUD_ORDER[slot]
			for row in 3:
				var origin := Vector2(64 + slot * 32, 36 + row * 32)
				Items.draw_icon(self, origin, item, float(row) / 2.0)
				Items.draw_rarity(self, origin + Vector2(0, 11), item)
			Items.draw_pickup(self, Vector2(68 + slot * 32, 164), item)

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
	game.hide()
	game.backdrop.hide()
	var icons := Icons.new()
	screen.add_child(icons)
	await RenderingServer.frame_post_draw
	var image: Image = screen.get_texture().get_image()
	var shield_fill: Array[int] = []
	var signatures := {}
	for slot in Items.HUD_ORDER.size():
		var item: int = Items.HUD_ORDER[slot]
		for row in 3:
			var count := 0
			for y in 9:
				for x in 9:
					var color := image.get_pixel(64 + slot * 32 + x, 36 + row * 32 + y)
					if color.get_luminance() < 0.3:
						count += 1
			if item == 0:
				shield_fill.append(count)
			if row == 2:
				check(count > 5, "Icon unreadable")
				var glyph := image.get_region(Rect2i(64 + slot * 32, 100, 9, 9))
				signatures[glyph.get_data().hex_encode()] = true
			var pips := 0
			for x in 9:
				if image.get_pixel(64 + slot * 32 + x, 47 + row * 32).get_luminance() < 0.5:
					pips += 1
			check(pips == int(Items.RARITIES[item]) + 1, "Rarity pips incorrect")
	check(shield_fill[0] == 0 and absi(shield_fill[1] * 2 - shield_fill[2]) <= 1,
		"Shield half-charge did not remove half the visible fill")
	check(signatures.size() == 4, "Passive silhouettes repeat")
	image.get_region(Rect2i(54, 28, 266, 148)).save_png("res://.shots/passive-icons-native.png")
	icons.queue_free()
	await get_tree().process_frame
	game.show()
	game.backdrop.show()
	game.reset()
	game.invuln = 0.0
	game.loop_n = 3
	for item in Items.HUD_ORDER:
		game._grant_item(item, game.player)
	game.passive_pulse.fill(0.0)
	game.flash = 0.0
	game.shake = 0.0
	game.rings.clear()
	game.sparks.clear()
	game.feed_backdrop(3.0)
	game.queue_redraw()
	_process(3.0)
	transition_age = TRANSITION_TIME
	_process(0.0)
	await RenderingServer.frame_post_draw
	screen.get_texture().get_image().save_png("res://.shots/passive-hud-native.png")
	get_viewport().get_texture().get_image().save_png("res://.shots/passive-hud-crt.png")
	# Compare HUD outside the fixed passive rectangle before/after consuming a shield.
	var full_hud: Image = screen.get_texture().get_image()
	var first: Vector2 = game.passive_hud_origin(0)
	var last: Vector2 = game.passive_hud_origin(3)
	var baseline: float = game.FRAME.end.y - game.HUD_RAIL - game.HUD_INSET + 4
	check(first.y + 8 == baseline and last.y == first.y, "Passive row is not baseline aligned")
	check(last.x + 8 == game.FRAME.end.x - game.HUD_RAIL - 7, "Passive row is not right aligned")
	game.hurt_player()
	# Isolate icon state from the existing shared camera shake and hit effects.
	game.shake = 0.0
	game.hit_t = 0.0
	game.rings.clear()
	game.sparks.clear()
	game.passive_pulse.fill(0.0)
	game.queue_redraw()
	await RenderingServer.frame_post_draw
	var half_hud: Image = screen.get_texture().get_image()
	var changed := 0
	for y in range(int(first.y) - 1, int(first.y) + 10):
		for x in range(int(first.x) - 1, int(last.x) + 10):
			if full_hud.get_pixel(x, y) != half_hud.get_pixel(x, y):
				changed += 1
				check(Rect2i(Vector2i(first), Vector2i(9, 9)).has_point(Vector2i(x, y)),
					"Shield use changed another HUD slot")
	check(changed > 4, "Shield consumption invisible")
	# Sparse health sources must reach bloom while staying within the two-pixel bar.
	game.reset()
	game.backdrop.set_scenery(false, true)
	game.invuln = 0.0
	game.foe_shard(108)
	var enemy: Dictionary = game.foes.back()
	enemy.p = Vector2(260, 108)
	enemy.hp = 6
	enemy.max = 10
	game._mark_enemy_hit(enemy)
	game.health_clock = 0.2
	game.queue_redraw()
	for frame in 12:
		await RenderingServer.frame_post_draw
	var rect: Rect2 = game.enemy_health_rect(enemy)
	var source: Image = screen.get_texture().get_image()
	var extracted: Image = bright.get_texture().get_image()
	var cores := 0
	for x in int(rect.size.x):
		var p := Vector2i(rect.position) + Vector2i(x, 1)
		if source.get_pixelv(p).get_luminance() > 0.97:
			cores += 1
			check(extracted.get_pixel(p.x / 2, p.y / 2).r > 0.1, "Health source lost before bloom")
	check(cores > 0 and cores <= 4, "Health glow exceeded its source budget")
	get_viewport().get_texture().get_image().save_png("res://.shots/health-glow-crt.png")
	game.health_clock = 2.1
	game.queue_redraw()
	for frame in 12:
		await RenderingServer.frame_post_draw
	extracted = bright.get_texture().get_image()
	var p := Vector2i(rect.position) + Vector2i(3, 1)
	check(extracted.get_pixel(p.x / 2, p.y / 2).r < 0.001, "Hidden health bar retained glow")
	print("PASSIVE_HUD checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
