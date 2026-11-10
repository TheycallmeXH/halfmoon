extends "res://scripts/boot.gd"

class EdgeProbe extends Node2D:
	var polygon := PackedVector2Array()
	var reference := true

	func _draw() -> void:
		draw_rect(Rect2(0, 0, 384, 216), Ink.INK)
		if reference:
			draw_colored_polygon(polygon, Ink.PAPER)
		else:
			Ink.paper_edge(self, polygon)
			draw_colored_polygon(polygon, Ink.INK)

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
	game.backdrop.visible = false
	var probe := EdgeProbe.new()
	screen.add_child(probe)
	var p := Vector2(192, 108)
	var shapes := [game._hull_xf(p, 0.0), game._hull_xf(p, 0.15),
		game._crystal(p, 25.0, 0.37), game._cache_shape(p, game.WEAPON_BASE),
		PackedVector2Array([p + Vector2(-18.4, -3.2), p + Vector2(15.2, -12.4),
			p + Vector2(3.1, 0.3), p + Vector2(15.2, 12.4), p + Vector2(-18.4, 3.2)])]
	for polygon in shapes:
		probe.polygon = polygon
		probe.reference = true
		probe.queue_redraw()
		await RenderingServer.frame_post_draw
		var body: Image = screen.get_texture().get_image()
		probe.reference = false
		probe.queue_redraw()
		await RenderingServer.frame_post_draw
		var outlined: Image = screen.get_texture().get_image()
		var rim := 0
		for y in range(70, 148):
			for x in range(150, 234):
				var inside := body.get_pixel(x, y).get_luminance() > 0.5
				var expected := false
				if not inside:
					for dy in range(-1, 2):
						for dx in range(-1, 2):
							if body.get_pixel(x + dx, y + dy).get_luminance() > 0.5:
								expected = true
				var actual := outlined.get_pixel(x, y).get_luminance() > 0.5
				check(actual == expected, "Paper contour escaped 1px raster dilation or missed an edge")
				if actual:
					rim += 1
		check(rim > 12, "Paper contour disappeared")
	probe.queue_free()
	game.backdrop.visible = true
	# Render actual entities over a dark planet, including animated thin/folded parts.
	var sheet := Image.create(96 * 5, 88 * 4, false, Image.FORMAT_RGBA8)
	for index in 17:
		game.reset()
		game.visible = true
		var center := Vector2(283, 132)
		if index <= 1:
			game.player = center
			game.focus_on = index == 1
			game.hull_yaw = 0.7 if index == 1 else 0.0
		elif index <= 4:
			game.foes.append({"p": center, "kind": index - 2, "r": 8.0, "hp": 5, "max": 5,
				"spin": 0.65, "vy": 14.0, "fire": 2.0, "hit_t": 0.0})
		elif index <= 8:
			var foe: Dictionary = game.Specials.create(3 if index < 7 else 4, center.y, 4)
			foe.p = center
			foe.age = 3.0
			foe.state = game.Specials.State.COOL if index % 2 else game.Specials.State.LEAVE
			foe.state_age = 0.35
			foe.dir = Vector2.LEFT.rotated(0.45)
			game.foes.append(foe)
		elif index <= 12:
			game.start_elite()
			game.boss.variant = index - 9
			game.boss.p = center
			game.boss.t = 3.0
			game.boss.station_t = 1.0
			game.boss.action = 0
			game.boss.charge = 0.0
		elif index == 13:
			game.start_boss()
			game.boss.p = center
			game.boss.t = 3.0
		elif index == 14:
			game.start_rival()
			game.boss.p = center
		else:
			game.caches.append({"p": center, "t": 2.0, "kind": game.WEAPON_BASE,
				"passive": game.ITEM_SHIELD if index == 16 else game.ITEM_NONE})
		game.loop_n = 2
		game.feed_backdrop(3.0)
		# Keep the dark plate visible here; boss suppression has its own fixture.
		game.backdrop.set_scenery(true, true)
		game.queue_redraw()
		await RenderingServer.frame_post_draw
		var frame: Image = screen.get_texture().get_image()
		sheet.blit_rect(frame, Rect2i(235, 88, 96, 88),
			Vector2i(index % 5 * 96, index / 5 * 88))
		if index == 10:
			get_viewport().get_texture().get_image().save_png("res://.shots/entity-edges-crt.png")
		# Hiding the entity must expose scenery, rather than leaving a radial clearing.
		game.visible = false
		await RenderingServer.frame_post_draw
		var blank: Image = screen.get_texture().get_image()
		var dark_near := 0
		for y in range(111, 154):
			for x in range(262, 305):
				if Vector2(x, y).distance_to(center) > 14.0 and blank.get_pixel(x, y).get_luminance() < 0.4:
					dark_near += 1
		check(dark_near > 200, "Entity still clears a large disk of scenery")
	sheet.resize(960, 704, Image.INTERPOLATE_NEAREST)
	sheet.save_png("res://.shots/entity-edges-gallery.png")
	print("ENTITY_EDGES checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
