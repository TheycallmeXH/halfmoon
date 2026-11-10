# Rendered check: run this scene with the real Compatibility renderer.
extends "res://scripts/boot.gd"

const CORES := [
	Vector2i(40, 60), Vector2i(61, 60), Vector2i(80, 81), Vector2i(101, 81),
	Vector2i(240, 60), Vector2i(261, 60), Vector2i(280, 81), Vector2i(301, 81)]
const COLD := [Vector2i(145, 60), Vector2i(165, 60), Vector2i(325, 60)]

class Fixture extends Node2D:
	func _draw() -> void:
		draw_rect(Rect2(0, 0, 384, 216), Ink.INK)
		draw_rect(Rect2(192, 0, 192, 216), Ink.PAPER)
		for point in CORES:
			draw_rect(Rect2(Vector2(point), Vector2.ONE), Color(1, 1, 0.97))
		draw_rect(Rect2(Vector2(COLD[0]), Vector2.ONE), Color(0.915, 0.902, 0.845))
		for point in [COLD[1], COLD[2]]:
			draw_rect(Rect2(Vector2(point), Vector2.ONE), Ink.PAPER)


func _ready() -> void:
	super._ready()
	game.set_process(false)
	game.hide()
	screen.get_node("Backdrop").hide()
	screen.add_child(Fixture.new())
	# Allow every dependent viewport in the blur graph to consume the fixture.
	for frame in 12:
		await RenderingServer.frame_post_draw
	var extracted := bright.get_texture().get_image()
	var failures := 0
	for point in CORES:
		var value := extracted.get_pixel(point.x / 2, point.y / 2).r
		if value < 0.5:
			failures += 1
			push_error("Isolated core was lost at %s (%.4f)" % [point, value])
	for point in COLD:
		var value := extracted.get_pixel(point.x / 2, point.y / 2).r
		if value > 0.001:
			failures += 1
			push_error("Paper/FLASH leaked into bloom at %s (%.4f)" % [point, value])
	extracted.save_png("res://.shots/highlight_sampling.png")
	print("HIGHLIGHT_CHECK cores=8 parities=4 cold_controls=3 failures=%d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
