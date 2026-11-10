# Cached paper beneath a slowly animated moon and a separate sky layer.
extends Node2D

const W := 384.0
const H := 216.0

const PAPER := Color(0.925, 0.910, 0.851)
const INK := Color(0.129, 0.129, 0.118)
const SOOT := Color(0.396, 0.388, 0.353)

const FRAME := Rect2(9.0, 8.0, W - 18.0, H - 16.0)
const MOON_R := 74.0
const MOON_C := Vector2(238.0, 106.0)
const REDRAW_INTERVAL := 1.0 / 24.0

var moon_visible := true
var scenery_visible := true
var scenery_blend := 1.0
var scenery_alpha := 1.0

var sky: Node2D
var worlds: Node2D
var redraw_acc := 0.0
var moon_center := MOON_C
var moon_radius := MOON_R

# Parallax: the scenery drifts a hair against the hull, and the moon breathes.
# Both are tiny and slow — the point is that a still screen is never dead.
var lag := Vector2.ZERO
var breath := 0.0
var clock := 0.0


func _ready() -> void:
	var paper := Node2D.new()
	paper.name = "Paper"
	paper.set_script(preload("res://scripts/backdrop_paper.gd"))
	paper.z_index = -2
	add_child(paper)
	sky = Node2D.new()
	sky.name = "Sky"
	sky.set_script(preload("res://scripts/sky.gd"))
	sky.z_index = -1
	add_child(sky)
	worlds = Node2D.new()
	worlds.name = "Worlds"
	worlds.set_script(preload("res://scripts/worlds.gd"))
	worlds.mask = sky
	worlds.z_index = -1
	add_child(worlds)
	material = worlds.material
	_update_moon()
	set_process(false)
	queue_redraw()


func set_moon(on: bool) -> void:
	if moon_visible == on:
		return
	moon_visible = on
	if sky != null:
		sky.moon_visible = on
		sky.queue_redraw()
	queue_redraw()


func set_scenery(on: bool, immediate: bool = false) -> void:
	scenery_visible = on
	if immediate:
		scenery_blend = 1.0 if on else 0.0
		_apply_scenery()


func _apply_scenery() -> void:
	scenery_alpha = smoothstep(0.0, 1.0, scenery_blend)
	if sky != null:
		sky.modulate.a = scenery_alpha
	if worlds != null:
		worlds.modulate.a = scenery_alpha
	queue_redraw()


func step(lag_target: Vector2, dt: float) -> void:
	var target := 1.0 if scenery_visible else 0.0
	var next := move_toward(scenery_blend, target, dt / (0.7 if scenery_visible else 0.45))
	if next != scenery_blend:
		scenery_blend = next
		_apply_scenery()
	clock += dt
	lag = lag.lerp(lag_target, 1.0 - exp(-6.0 * dt))
	breath = lerpf(breath, lag_target.length() * 0.9, 1.0 - exp(-4.0 * dt))
	redraw_acc += dt
	if redraw_acc < REDRAW_INTERVAL:
		return
	var elapsed := redraw_acc
	redraw_acc = fmod(redraw_acc, REDRAW_INTERVAL)
	worlds.step(elapsed - redraw_acc, lag)
	_update_moon()
	sky.step(elapsed - redraw_acc, lag, moon_center, moon_radius)
	queue_redraw()


func _draw() -> void:
	if moon_visible:
		draw_moon((float(worlds.weights[0]) if worlds != null else 1.0) * scenery_alpha)


func set_stage(loop_n: int) -> void:
	if worlds != null:
		worlds.set_stage(loop_n)


func reset_world() -> void:
	set_scenery(true, true)
	clock = 0.0
	redraw_acc = 0.0
	lag = Vector2.ZERO
	breath = 0.0
	if worlds != null:
		worlds.reset_world()
	if sky != null:
		sky.clock = 0.0
		sky.offset = Vector2.ZERO
		sky.meteor_age = -1.0
		sky.meteor_wait = 3.6
		sky.queue_redraw()
	_update_moon()
	set_moon(true)
	queue_redraw()


func _update_moon() -> void:
	# Motion: the disc drifts on a slow lissajous and the halftone pattern
	# rotates with it, so the surface reads as a slowly turning body rather
	# than a printed circle with a wobble. Amplitudes are in whole pixels and
	# the periods are long — this should be felt, not watched.
	var drift := Vector2(
		sin(clock * 0.21) * 3.0 + sin(clock * 0.07) * 1.5,
		cos(clock * 0.17) * 2.0 + cos(clock * 0.09) * 1.0
	)
	moon_center = MOON_C + lag.floor() + drift.floor()
	moon_radius = MOON_R + breath + sin(clock * 0.6) * 0.6
	if sky != null:
		sky.moon_center = moon_center
		sky.moon_radius = moon_radius
		sky.moon_visible = moon_visible
		sky.moon_strength = float(worlds.weights[0]) if worlds != null else 1.0


func draw_moon(alpha: float = 1.0) -> void:
	if alpha < 0.002:
		return
	var c := moon_center
	var rad := moon_radius
	var extent := rad * 80.0 / MOON_R
	draw_texture_rect(worlds.moon_texture, Rect2((c - Vector2.ONE * extent).floor(),
		Vector2.ONE * extent * 2.0), false, Color(1, 1, 1, alpha))

	# A few moving paper flecks sit over the cached four-ink engraving.
	var spin := clock * 0.08
	Ink.screen_dots_rot(self, c, rad - 2.0, 6.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.22 * alpha), 4, spin)
	Ink.ring(self, c, rad, 1.0, Color(INK, alpha))
