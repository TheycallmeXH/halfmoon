# Stable paper, grain and bezel keep their cached draw commands between frames.
extends Node2D

var grain := PackedVector2Array()


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261107
	for i in 120:
		grain.append(Vector2(floorf(rng.randf() * 384.0), floorf(rng.randf() * 216.0)))
	set_process(false)


func _draw() -> void:
	draw_rect(Rect2(0.0, 0.0, 384.0, 216.0), Ink.PAPER)
	var grain_color := Color(Ink.INK, 0.10)
	for p in grain:
		draw_rect(Rect2(p, Vector2.ONE), grain_color)
	# A single 2px rule avoids parallel edges splitting under CRT defocus.
	Ink.rect(self, Rect2(9.0, 8.0, 366.0, 200.0), 2.0, 0.0, Color(Ink.INK, 0.55))
