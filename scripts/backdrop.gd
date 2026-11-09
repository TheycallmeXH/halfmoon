# Halfmoon backdrop — every static mark in the frame, drawn exactly once.
#
# Paper plate, grain, horizon rule, inner bezel, hatched corner blocks and the
# scenery moon used to be re-issued every frame: ~3,000 draw calls for content
# that never changes. Splitting them into their own CanvasItem means Godot keeps
# the command buffer and replays it for free; this node only repaints when the
# boss takes over the moon.
extends Node2D

const W := 384.0
const H := 216.0

const PAPER := Color(0.925, 0.910, 0.851)
const INK := Color(0.129, 0.129, 0.118)
const SOOT := Color(0.396, 0.388, 0.353)

const FRAME := Rect2(9.0, 8.0, W - 18.0, H - 16.0)
const MOON_R := 74.0
const MOON_C := Vector2(238.0, 106.0)

var moon_visible := true
var rng := RandomNumberGenerator.new()
var grain: Array[Vector2] = []

# Parallax: the scenery drifts a hair against the hull, and the moon breathes.
# Both are tiny and slow — the point is that a still screen is never dead.
var lag := Vector2.ZERO
var breath := 0.0
var clock := 0.0


func _ready() -> void:
	rng.seed = 20261107
	for i in 240:
		grain.append(Vector2(floorf(rng.randf() * W), floorf(rng.randf() * H)))
	set_process(true)
	queue_redraw()


func set_moon(on: bool) -> void:
	if moon_visible == on:
		return
	moon_visible = on
	queue_redraw()


func step(lag_target: Vector2, dt: float) -> void:
	clock += dt
	lag = lag.lerp(lag_target, 1.0 - exp(-6.0 * dt))
	breath = lerpf(breath, lag_target.length() * 0.9, 1.0 - exp(-4.0 * dt))
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0.0, 0.0, W, H), PAPER, true)

	var o := Vector2(floorf(lag.x), floorf(lag.y))

	if moon_visible:
		draw_moon(o)

	for g in grain:
		draw_rect(Rect2(g.x + o.x, g.y + o.y, 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.10), true)

	draw_horizon(o)
	draw_frame_art()


func draw_moon(o: Vector2) -> void:
	# Motion: the disc drifts on a slow lissajous and the halftone pattern
	# rotates with it, so the surface reads as a slowly turning body rather
	# than a printed circle with a wobble. Amplitudes are in whole pixels and
	# the periods are long — this should be felt, not watched.
	var drift := Vector2(
		sin(clock * 0.21) * 3.0 + sin(clock * 0.07) * 1.5,
		cos(clock * 0.17) * 2.0 + cos(clock * 0.09) * 1.0
	)
	var c := MOON_C + o + Vector2(floorf(drift.x), floorf(drift.y))
	# Breathing radius: +/- 1px, slow.
	var rad := MOON_R + breath * 1.0 + sin(clock * 0.6) * 0.6

	Ink.disc(self, c, rad, Color(INK.r, INK.g, INK.b, 0.88))

	# Halftone veil, rotated by the body's own spin. Two bands only — the
	# erosion stays a printed gradient, not a soft vignette.
	var spin := clock * 0.08
	Ink.screen_dots_rot(self, c, rad - 2.0, 3.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.62), 4, spin)
	Ink.screen_dots_rot(self, c, rad - 10.0, 4.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.30), 3, spin * 1.6)
	Ink.ring(self, c, rad, 1.0, INK)

	# Terminator: a soft crescent of darkness on the lower-right, breathing with
	# the same clock. This is what makes the disc look lit from one side instead
	# of uniformly flat, and it replaces the old straight-line decoration.
	var lit := PI * (0.30 + sin(clock * 0.11) * 0.06)
	var crescent_a := lerpf(0.30, 0.52, 0.5 + 0.5 * sin(clock * 0.11))
	for row in 14:
		var t := float(row) / 13.0
		var y := c.y + rad * (t * 1.6 - 0.8)
		var half := sqrt(maxf(0.0, rad * rad - pow(y - c.y, 2.0)))
		if half <= 0.0:
			continue
		# Dark side: right edge, widest at the vertical middle.
		var depth := floorf(half * (0.30 + 0.24 * (1.0 - absf(t * 2.0 - 1.0))))
		if depth > 0.0:
			draw_rect(Rect2(floorf(c.x + half - depth), floorf(y), depth, 1.0),
				Color(INK.r, INK.g, INK.b, crescent_a))


func draw_horizon(o: Vector2) -> void:
	# One dotted rule across the field, thinning toward the edges. Kept because
	# it anchors the composition; the moon no longer carries any hard lines.
	var y := 130.0 + o.y
	var x := 10.0
	while x < W - 10.0:
		var edge := clampf(minf(x, W - x) / 60.0, 0.0, 1.0)
		if fposmod(x, 5.0) < 1.0:
			draw_rect(Rect2(x + o.x, y, 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.42 * edge), true)
		x += 1.0


func draw_frame_art() -> void:
	var f := FRAME

	# ONE rule, not three.
	#
	# The frame used to be a printed plate: a 3px outer tone at 8..11, a 1px
	# inner rule at 12, and a faint second rule at 15. Three near-parallel lines
	# 3 px apart is a perfectly good printed decoration, and it was the reason
	# the CRT pass could never handle this edge: any kernel wider than ~3 px
	# turns those three lines into three separate soft bands with light gaps
	# between them. That is what read as ghosting, and it forced a growing
	# "exempt the border from focus blur" hack until most of the frame was
	# excluded from the optics entirely.
	#
	# A single 2px band cannot ghost: blurred, it just becomes a soft edge,
	# which is exactly what a CRT border should look like. So the decoration is
	# simplified rather than the optics being further special-cased.
	#
	# Tone: 0.55 rather than full ink. A solid black rule against cream is the
	# strongest contrast edge on screen, and the aberration keys on strong
	# edges — at full opacity it split into red and green halves.
	Ink.rect(self, f, 2.0, 0.0, Color(INK.r, INK.g, INK.b, 0.55))
