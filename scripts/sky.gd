# Masked celestial engraving, independent of gameplay RNG and bloom.
extends Node2D

const STAR_COUNT := 64
const FIELD := Rect2(14.0, 14.0, 356.0, 188.0)
const HUD := Rect2(18.0, 18.0, 90.0, 62.0)
const METEOR_VELOCITY := Vector2(-45.0, 20.0)
const METEOR_LIFE := 1.8
const METEOR_LENGTH := 30

var rng := RandomNumberGenerator.new()
var stars := PackedVector4Array()
var clock := 0.0
var offset := Vector2.ZERO
var moon_visible := true
var moon_center := Vector2(238.0, 109.0)
var moon_radius := 74.0
var moon_strength := 1.0
var meteor_wait := 3.6
var meteor_age := -1.0
var meteor_origin := Vector2.ZERO


func _ready() -> void:
	rng.seed = 20261110
	stars.clear()
	for i in STAR_COUNT:
		var p := Vector2(rng.randf_range(FIELD.position.x, FIELD.end.x),
			rng.randf_range(FIELD.position.y, FIELD.end.y))
		stars.append(Vector4(p.x, p.y, rng.randf() * TAU, rng.randf_range(0.0, 1.0)))
	set_process(false)


func step(dt: float, lag: Vector2, center: Vector2, radius: float) -> void:
	clock += dt
	offset = lag
	moon_center = center
	moon_radius = radius
	if meteor_age >= 0.0:
		meteor_age += dt
		if meteor_age >= METEOR_LIFE:
			meteor_age = -1.0
	else:
		meteor_wait -= dt
		if meteor_wait <= 0.0:
			_start_meteor()
	queue_redraw()


func _start_meteor() -> void:
	meteor_wait = rng.randf_range(5.5, 8.5)
	# Keep the whole trail in open sky at birth; masks still follow moving bodies.
	for attempt in 12:
		var p := Vector2(rng.randf_range(128.0, 350.0), rng.randf_range(28.0, 62.0))
		if _visibility(p) > 0.8 and _visibility(p + METEOR_VELOCITY * 0.8) > 0.8:
			meteor_origin = p
			meteor_age = 0.0
			return


func _visibility(p: Vector2, mask_moon: bool = true) -> float:
	if not FIELD.has_point(p) or HUD.grow(4.0).has_point(p):
		return 0.0
	var edge := minf(minf(p.x - FIELD.position.x, FIELD.end.x - p.x),
		minf(p.y - FIELD.position.y, FIELD.end.y - p.y))
	var visibility := smoothstep(0.0, 5.0, edge)
	if moon_visible and mask_moon:
		var inner := moon_radius + 5.0
		visibility *= lerpf(1.0, smoothstep(inner * inner, (inner + 7.0) * (inner + 7.0),
			p.distance_squared_to(moon_center)), moon_strength)
		if visibility <= 0.0:
			return 0.0
	return visibility


func _draw() -> void:
	for i in stars.size():
		var star := stars[i]
		var depth := 0.35 + star.w * 0.65
		var p := Vector2(
			FIELD.position.x + fposmod(star.x - FIELD.position.x - clock * depth * 0.65, FIELD.size.x),
			star.y + sin(clock * 0.08 + star.z) * 0.7)
		p = (p + offset * depth).floor()
		var alpha := _visibility(p)
		if alpha <= 0.0:
			continue
		var twinkle := 0.78 + 0.22 * sin(clock * (0.65 + star.w * 0.35) + star.z)
		alpha *= (0.30 + star.w * 0.30) * twinkle
		draw_rect(Rect2(p, Vector2.ONE), Color(Ink.INK, alpha))
		if i % 8 == 0:
			# Four tiny arms distinguish a distant star from a round hostile shot.
			for arm in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
				var q: Vector2 = p + arm
				_speck(q, alpha * 0.65)
				if i % 15 == 0:
					_speck(p + arm * 2.0, alpha * 0.30)
	if meteor_age >= 0.0:
		_draw_meteor()


func _draw_meteor() -> void:
	var head := meteor_origin + METEOR_VELOCITY * meteor_age
	var direction := METEOR_VELOCITY.normalized()
	var envelope := smoothstep(0.0, 0.18, meteor_age) * (1.0 - smoothstep(1.1, METEOR_LIFE, meteor_age))
	for i in METEOR_LENGTH:
		var p := (head - direction * float(i)).floor()
		var tail := 1.0 - float(i) / float(METEOR_LENGTH)
		var alpha := _visibility(p) * envelope * tail * tail * 0.70
		if alpha > 0.005:
			draw_rect(Rect2(p, Vector2.ONE), Color(Ink.INK, alpha))
		if i < 12:
			_speck(p + Vector2(0, 1), envelope * tail * 0.18)
	_speck(head + Vector2(1, 0), envelope * 0.65)
	_speck(head + Vector2(0, -1), envelope * 0.45)


func _speck(p: Vector2, alpha: float) -> void:
	alpha *= _visibility(p.floor())
	if alpha > 0.005:
		draw_rect(Rect2(p.floor(), Vector2.ONE), Color(Ink.INK, alpha))
