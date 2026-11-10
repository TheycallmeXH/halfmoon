extends "res://scripts/boot.gd"

class FadeProbe extends Node2D:
	func _draw() -> void:
		draw_rect(Rect2(0, 0, 384, 216), Ink.INK)
		var hull := PackedVector2Array([Vector2(182, 98), Vector2(202, 98),
			Vector2(202, 118), Vector2(182, 118)])
		Ink.paper_edge(self, hull)
		draw_colored_polygon(hull, Ink.INK)

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
	var probe := FadeProbe.new()
	screen.add_child(probe)
	await RenderingServer.frame_post_draw
	var image: Image = screen.get_texture().get_image()
	var ink := image.get_pixel(220, 108).get_luminance()
	var paper := image.get_pixel(202, 108).get_luminance()
	var mid := image.get_pixel(203, 108).get_luminance()
	var outer := image.get_pixel(204, 108).get_luminance()
	check(paper > mid and mid > outer and outer > ink, "Edge must fade in two decreasing outer steps")
	check((mid - ink) / (paper - ink) < 0.3, "Fringe became an opaque white band")
	check(is_equal_approx(image.get_pixel(205, 108).get_luminance(), ink), "Fringe spread beyond three source pixels")
	check(is_equal_approx(image.get_pixel(191, 108).get_luminance(), ink), "Fringe covered the hull")
	image.save_png("res://.shots/edge-fade-native.png")
	probe.queue_free()
	await get_tree().process_frame
	var backdrop: Node2D = game.backdrop
	backdrop.visible = true
	# The paper and frame are the exact blank plate expected in every boss fight.
	backdrop.set_scenery(false, true)
	await RenderingServer.frame_post_draw
	var blank: Image = screen.get_texture().get_image()
	for stage in range(1, 7):
		for encounter in ["start_boss", "start_rival"]:
			game.reset()
			game.loop_n = stage
			game.feed_backdrop(3.0)
			game.visible = false
			await RenderingServer.frame_post_draw
			check(screen.get_texture().get_image().get_data() != blank.get_data(), "Stage scenery missing before boss")
			game.call(encounter)
			check(not backdrop.scenery_visible, "Boss failed to request scenery suppression on entry")
			var previous := 1.0
			for frame in 30:
				game.feed_backdrop(1.0 / 60.0)
				check(backdrop.scenery_alpha <= previous, "Boss fade reversed")
				previous = backdrop.scenery_alpha
			await RenderingServer.frame_post_draw
			check(backdrop.scenery_alpha == 0.0, "Boss fade did not finish")
			check(screen.get_texture().get_image().get_data() == blank.get_data(), "Boss retained moon, stars or scenery")
			game.visible = true
			game.boss.p = Vector2(275, 108)
			game.boss.t = 3.0
			game.queue_redraw()
			transition_age = TRANSITION_TIME
			_process(0.0)
			await RenderingServer.frame_post_draw
			if stage in [1, 4]:
				get_viewport().get_texture().get_image().save_png(
					"res://.shots/%s-hidden-stage-%d.png" % [encounter, stage])
			game.visible = false
			game.call("beat_boss" if encounter == "start_boss" else "beat_rival")
			check(backdrop.scenery_visible, "Boss defeat failed to restore scenery target")
			game.feed_backdrop(0.25)
			var partial: float = backdrop.scenery_alpha
			check(partial > 0.0 and partial < 1.0, "Scenery restoration snapped")
			game.paused = true
			game._process(0.05)
			check(backdrop.scenery_alpha == partial, "Pause advanced the scenery fade")
			game.feed_backdrop(0.5)
			check(backdrop.scenery_alpha == 1.0, "Scenery restoration did not finish")
			# Reversing a fade must start at its current opacity.
			game.start_rival()
			game.feed_backdrop(0.15)
			var interrupted: float = backdrop.scenery_alpha
			game.boss = {}
			game.sync_backdrop()
			check(backdrop.scenery_alpha == interrupted, "Interrupted fade snapped")
			game.feed_backdrop(0.7)
			game.start_elite()
			game.feed_backdrop(0.05)
			check(backdrop.scenery_visible and backdrop.scenery_alpha == 1.0, "Elite incorrectly hid scenery")
	game.reset()
	check(backdrop.scenery_visible and backdrop.scenery_alpha == 1.0, "Restart inherited hidden scenery")
	print("EDGE_FADE_BOSS checks=%d failures=%d" % [checked, failures])
	get_tree().quit(1 if failures else 0)
