# Cached engravings, clipped to the field and HUD; entities carry their own rims.
extends Node2D

const NAMES := ["halfmoon", "ringed_giant", "motes", "broken_megastructure", "diatoms", "crystal_slice"]
const FADE_TIME := 2.4
const PRINT_TONES := [0.025, 0.16, 0.34, 0.57]
const PRINT_EDGES := [0.10, 0.28, 0.49]
var weights := PackedFloat32Array([1, 0, 0, 0, 0, 0])
var from_weights := weights.duplicate()
var theme := 0
var fade_age := FADE_TIME
var clock := 0.0
var offset := Vector2.ZERO
var mask: Node2D
var layers: Array[Dictionary] = []
var moon_texture: Texture2D


func _ready() -> void:
	var ink_mask := ShaderMaterial.new()
	ink_mask.shader = preload("res://shaders/world_mask.gdshader")
	material = ink_mask
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build()
	set_process(false)


func set_stage(loop_n: int) -> void:
	var next := posmod(loop_n - 1, NAMES.size())
	if next == theme:
		return
	from_weights = weights.duplicate()
	theme = next
	fade_age = 0.0


func reset_world() -> void:
	clock = 0.0
	theme = 0
	weights = PackedFloat32Array([1, 0, 0, 0, 0, 0])
	from_weights = weights.duplicate()
	fade_age = FADE_TIME
	queue_redraw()


func step(dt: float, lag: Vector2) -> void:
	clock += dt
	offset = lag
	fade_age = minf(FADE_TIME, fade_age + dt)
	var blend := smoothstep(0.0, FADE_TIME, fade_age)
	for i in weights.size():
		weights[i] = lerpf(from_weights[i], 1.0 if i == theme else 0.0, blend)
	queue_redraw()


func _layer(scene: int, center: Vector2, spin: float, drift: Vector2, phase: float = 0.0) -> Dictionary:
	var layer := {"scene": scene, "center": center, "spin": spin, "drift": drift,
		"phase": phase, "points": PackedVector3Array()}
	layers.append(layer)
	return layer


func _point(layer: Dictionary, p: Vector2, alpha: float) -> void:
	layer.points.append(Vector3(p.x, p.y, alpha))


func _surface(layer: Dictionary, size: Vector2i) -> void:
	layer.image = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	layer.image.fill(Color.TRANSPARENT)
	layer.origin = Vector2(size) * 0.5


func _fill_ellipse(layer: Dictionary, radius: Vector2, color: Color,
		center: Vector2 = Vector2.ZERO) -> void:
	var image: Image = layer.image
	var origin: Vector2 = layer.origin + center
	for y in range(-int(radius.y), int(radius.y) + 1):
		var half := int(sqrt(maxf(0.0, 1.0 - float(y * y) / (radius.y * radius.y))) * radius.x)
		image.fill_rect(Rect2i(int(origin.x) - half, int(origin.y) + y, half * 2 + 1, 1), color)


func _fill_polygon(layer: Dictionary, vertices: PackedVector2Array, color: Color) -> void:
	var image: Image = layer.image
	var origin: Vector2 = layer.origin
	var low := 10000.0
	var high := -10000.0
	for p in vertices:
		low = minf(low, p.y)
		high = maxf(high, p.y)
	for y in range(int(floorf(low)), int(ceilf(high)) + 1):
		var crossings: Array[float] = []
		for i in vertices.size():
			var a := vertices[i]
			var b := vertices[(i + 1) % vertices.size()]
			if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
				crossings.append(a.x + (float(y) - a.y) * (b.x - a.x) / (b.y - a.y))
		crossings.sort()
		for i in range(0, crossings.size() - 1, 2):
			var left := int(ceilf(crossings[i]))
			var right := int(floorf(crossings[i + 1]))
			if right >= left:
				image.fill_rect(Rect2i(int(origin.x) + left, int(origin.y) + y, right - left + 1, 1), color)


func _line(layer: Dictionary, a: Vector2, b: Vector2, alpha: float, pitch: float = 1.0) -> void:
	var count := maxi(1, int(a.distance_to(b) / pitch))
	for i in count + 1:
		_point(layer, a.lerp(b, float(i) / float(count)), alpha)


func _etch_line(layer: Dictionary, a: Vector2, b: Vector2, color: Color = Ink.MUTE) -> void:
	var image: Image = layer.image
	var origin: Vector2 = layer.origin
	var count := maxi(1, int(ceilf(a.distance_to(b) * 1.5)))
	for i in count + 1:
		var p := Vector2i((origin + a.lerp(b, float(i) / count)).floor())
		if Rect2i(Vector2i.ZERO, image.get_size()).has_point(p) and image.get_pixelv(p).a > 0.1:
			image.set_pixelv(p, color)


func _etch_ellipse(layer: Dictionary, radius: Vector2, center: Vector2 = Vector2.ZERO,
		color: Color = Ink.MUTE) -> void:
	var count := maxi(24, int(radius.x * 7.0))
	for i in count:
		var a := TAU * float(i) / count
		var b := TAU * float(i + 1) / count
		_etch_line(layer, center + Vector2(cos(a), sin(a)) * radius,
			center + Vector2(cos(b), sin(b)) * radius, color)


func _printed_ink(value: float, p: Vector2, curved: bool) -> Color:
	var x := int(p.x)
	var y := int(p.y)
	var level := 0
	for edge: float in PRINT_EDGES:
		if value >= edge:
			level += 1
	# Only the narrow border between two ink plates receives a coarse dot screen.
	var rank: float = Ink.BAYER[(posmod(y, 4)) * 4 + posmod(x, 4)] / 16.0
	for i in PRINT_EDGES.size():
		var edge: float = PRINT_EDGES[i]
		if absf(value - edge) < 0.024:
			level = i + (1 if rank < (value - edge + 0.024) / 0.048 else 0)
			break
	# Curved engraving carries the round forms; facets retain straight plate marks.
	var bend := int(p.x * p.x * 0.0025) if curved else 0
	var hatch := posmod(y + int(p.x * 0.35) + bend, 8)
	if (level == 1 or level == 2) and hatch == 0:
		level -= 1
	var tone: float = PRINT_TONES[level]
	return Color(Ink.INK.lerp(Ink.PAPER, tone), 0.96)


func _relief(layer: Dictionary, shape: String, radii: Vector2, gain: float = 1.0) -> void:
	var image: Image = layer.image
	var origin: Vector2 = layer.origin
	var light := Vector3(-0.55, -0.60, 0.58).normalized()
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a < 0.1:
				continue
			var p := Vector2(x, y) - origin
			var q := p / radii
			var value := 0.0
			match shape:
				"sphere", "cell":
					var depth := sqrt(maxf(0.0, 1.0 - q.length_squared()))
					var normal := Vector3(q.x, q.y, depth)
					var diffuse := maxf(0.0, normal.dot(light))
					value = 0.025 + pow(diffuse, 1.35) * 0.68
					if shape == "cell":
						value *= 0.72
						value += pow(maxf(0.0, 1.0 - depth), 2) * 0.22
						value += (0.5 + 0.5 * cos(p.x * 0.57)) * 0.045 * depth
				"ring":
					var radial := Vector2(p.x, p.y / 0.89).length()
					var bevel := sin(clampf((radial - 103.0) / 19.0, 0.0, 1.0) * PI)
					value = 0.04 + bevel * 0.30 + maxf(0.0, -q.x - q.y) * 0.15
				"facets":
					var seam := q.x * 0.55 + q.y * 0.75
					if q.x < -0.20:
						value = 0.38 + (1.0 - q.y) * 0.10
					elif seam > 0.22:
						value = 0.12 + (1.0 - q.x) * 0.12
					else:
						value = 0.025 + (1.0 - q.y) * 0.065
				"shard":
					value = 0.10 + (1.0 - q.y) * 0.09
					if q.x + q.y < -0.15:
						value += 0.24
			image.set_pixel(x, y, _printed_ink(value * gain, p, shape == "sphere" or shape == "cell"))


func _planet_ring() -> void:
	var band := _layer(1, Vector2(263, 116), 0.005, Vector2(2, 1))
	_surface(band, Vector2i(256, 144))
	var image: Image = band.image
	for y in image.get_height():
		for x in image.get_width():
			var p: Vector2 = Vector2(x, y) - band.origin
			var local := p.rotated(0.38)
			var q := local / Vector2(108, 25)
			var radius := q.length()
			if radius < 0.79 or radius > 1.03:
				continue
			# The rear arc passes behind the globe; the near arc casts a narrow shadow.
			if local.y < 0.0 and p.length() < 60.0:
				continue
			if radius > 0.87 and radius < 0.90:
				continue
			var tone := 0.18 + (radius - 0.79) * 1.4
			if local.x > 18 and local.x < 65 and local.y > 0:
				tone *= 0.35
			image.set_pixel(x, y, _printed_ink(tone, p, false))


func _ellipse(layer: Dictionary, radius: Vector2, alpha: float, angle: float = 0.0,
		center: Vector2 = Vector2.ZERO, broken: bool = false) -> void:
	var samples := maxi(24, int(radius.x * 6.5))
	for i in samples:
		if broken and i % 53 > 38:
			continue
		var a := TAU * float(i) / float(samples)
		_point(layer, center + Vector2(cos(a) * radius.x, sin(a) * radius.y).rotated(angle), alpha)


func _build() -> void:
	layers.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 202611101
	var moon := {}
	_surface(moon, Vector2i(160, 160))
	_fill_ellipse(moon, Vector2(74, 74), Color(Ink.INK, 0.88))
	_relief(moon, "sphere", Vector2(74, 74), 0.72)
	moon_texture = ImageTexture.create_from_image(moon.image)
	# Sparse curved cloud belts replace the uniform stipple fill.
	var globe := _layer(1, Vector2(263, 116), 0.0, Vector2(2, 1))
	_surface(globe, Vector2i(128, 128))
	_fill_ellipse(globe, Vector2(58, 58), Color(Ink.INK, 0.88))
	_relief(globe, "sphere", Vector2(58, 58))
	for row in [-43, -31, -16, -11, 8, 13, 29, 42]:
		var half := sqrt(54.0 * 54.0 - float(row * row))
		for x in range(-int(half), int(half)):
			var y: float = row + sin(x * 0.035 + row) * 3.0
			_etch_line(globe, Vector2(x, y), Vector2(x + 1, y),
				Ink.SOOT if row == -31 or row == 13 else Ink.INK.lerp(Ink.SOOT, 0.5))
	_etch_ellipse(globe, Vector2(9, 3), Vector2(20, 25), Ink.MUTE)
	_ellipse(globe, Vector2(58, 58), 0.58)
	for row in [-34, -17, 8, 29]:
		var half := sqrt(54.0 * 54.0 - float(row * row))
		for sample in int(half * 2):
			var x := -half + sample
			_point(globe, Vector2(x, row + sin(x * 0.035 + row) * 3), 0.19)
	_planet_ring()
	var satellite := _layer(1, Vector2(144, 61), 0.08, Vector2(5, 2), 1.0)
	_ellipse(satellite, Vector2(7, 7), 0.40)
	_line(satellite, Vector2(-3, -3), Vector2(4, 3), 0.28)
	# Motes: sparse small objects, never shaped like a hostile round.
	for i in 16:
		var dust := _layer(2, Vector2(rng.randf_range(115, 358), rng.randf_range(28, 194)),
			rng.randf_range(-0.09, 0.09), Vector2(3 + i % 5, 2), rng.randf() * TAU)
		var size := rng.randf_range(2.0, 6.0)
		if i % 5 == 0:
			size = 32.0 + i
			dust.center = [Vector2(146, 41), Vector2(291, 172), Vector2(347, 63), Vector2(164, 190)][i / 5]
		_surface(dust, Vector2i(112, 80))
		_fill_polygon(dust, PackedVector2Array([Vector2(-size, -size * 0.15),
			Vector2(size * 0.55, -size * 0.45), Vector2(size, size * 0.05),
			Vector2(-size * 0.4, size * 0.7)]), Color(Ink.INK, 0.85))
		_relief(dust, "shard", Vector2(size, size * 0.7))
		_etch_line(dust, Vector2(-size + 3, -size * 0.11),
			Vector2(size * 0.52, -size * 0.37))
		_etch_line(dust, Vector2(size * 0.52, -size * 0.37),
			Vector2(-size * 0.35, size * 0.56), Ink.SOOT)
		_line(dust, Vector2(-size, -1), Vector2(size, 1), 0.30)
		_line(dust, Vector2(size, 1), Vector2(-size * 0.4, size * 0.6), 0.24)
		_line(dust, Vector2(-size * 0.4, size * 0.6), Vector2(-size, -1), 0.24)
	for i in 2:
		var flow := _layer(2, Vector2(224, 116), 0.006, Vector2(4, 1), i)
		for j in 180:
			var x := -110.0 + j
			_point(flow, Vector2(x, sin(x * 0.025 + i) * 10.0 + i * 46.0 - 23.0), 0.14)
	# Broken megastructure: an off-centre, screen-sized skeleton with clear gaps.
	var ribs := _layer(3, Vector2(292, 122), -0.018, Vector2(2, 2))
	_surface(ribs, Vector2i(256, 256))
	for segment in 24:
		if segment % 7 < 2:
			continue
		var a := TAU * float(segment) / 24.0
		var b := a + TAU / 24.0 * 0.88
		var v1 := Vector2(cos(a), sin(a) * 0.89)
		var v2 := Vector2(cos(b), sin(b) * 0.89)
		_fill_polygon(ribs, PackedVector2Array([v1 * 103, v2 * 103, v2 * 122, v1 * 122]),
			Color(Ink.INK, 0.88))
	_relief(ribs, "ring", Vector2(122, 108))
	for segment in 24:
		if segment % 7 < 2:
			continue
		var a := TAU * float(segment) / 24.0
		var b := a + TAU / 24.0 * 0.88
		var v1 := Vector2(cos(a), sin(a) * 0.89)
		var v2 := Vector2(cos(b), sin(b) * 0.89)
		_etch_line(ribs, v1 * 119, v2 * 119, Ink.SOOT)
		_etch_line(ribs, v1 * 105 + v1.orthogonal() * 4,
			v1 * 117 + v1.orthogonal() * 4, Ink.SOOT)
	for radius in [65, 72, 103, 110, 122]:
		_ellipse(ribs, Vector2(radius, radius * 0.89), 0.26 if radius < 110 else 0.38,
			0.0, Vector2.ZERO, true)
	for i in 24:
		if i % 7 == 0 or i % 7 == 1:
			continue
		var a := TAU * i / 24.0
		var direction := Vector2(cos(a), sin(a) * 0.89)
		_line(ribs, direction * 73.0, direction * 110.0, 0.31)
		_line(ribs, direction * 93.0, direction * 108.0 + direction.orthogonal() * 7.0, 0.19)
	for i in 9:
		var shard := _layer(3, Vector2(110 + i * 22, 50 + i % 3 * 53), 0.07, Vector2(3, 3), i)
		_line(shard, Vector2(-5, -3), Vector2(7, 1), 0.26)
		_line(shard, Vector2(-5, -3), Vector2(-2, 4), 0.22)
	# Diatom membranes: large enough to read as microscopic specimens, not bullets.
	var cells := [Vector2(282, 122), Vector2(151, 48), Vector2(184, 163),
		Vector2(347, 37), Vector2(320, 194)]
	for i in cells.size():
		var cell := _layer(4, cells[i],
			0.025 * (-1.0 if i % 2 == 0 else 1.0), Vector2(4, 3), i * 1.7)
		cell.tilt = [-0.28, 0.50, -0.64, -0.40, 0.20][i]
		var radii := Vector2(57, 30) if i == 0 else Vector2(19 + i * 2, 11 + i)
		_surface(cell, Vector2i(128, 80))
		_fill_ellipse(cell, radii, Color(Ink.INK, 0.85))
		_relief(cell, "cell", radii)
		_etch_ellipse(cell, radii - Vector2(3, 2), Vector2.ZERO, Ink.SOOT)
		_etch_line(cell, Vector2(-radii.x + 5, 0), Vector2(radii.x - 5, 0), Ink.SOOT)
		var pores := 9 if i == 0 else 5
		for j in pores:
			var x := -radii.x * 0.7 + float(j) * radii.x * 1.4 / (pores - 1)
			var height := sqrt(maxf(0.0, 1.0 - pow(x / radii.x, 2))) * radii.y
			_etch_ellipse(cell, Vector2(2, height * 0.55), Vector2(x, 0), Ink.MUTE.lerp(Ink.SOOT, 0.3))
		_ellipse(cell, radii, 0.40)
		_ellipse(cell, radii - Vector2(3, 2), 0.20)
		for j in 12:
			var a := TAU * j / 12.0
			var p := Vector2(cos(a) * radii.x, sin(a) * radii.y)
			_line(cell, p, p + p.normalized() * 4.0, 0.24)
	# Crystal slice: engraved angular cells and parallel internal fault lines.
	var crystals := [Vector2(328, 160), Vector2(259, 62), Vector2(156, 126),
		Vector2(350, 28), Vector2(213, 197), Vector2(131, 41)]
	for i in crystals.size():
		var crystal := _layer(5, crystals[i],
			0.012 * (-1.0 if i % 2 == 0 else 1.0), Vector2(2, 2), i)
		var radii := Vector2(66, 43) if i == 0 else Vector2(20 + i % 3 * 7, 18 + i % 2 * 7)
		crystal.tilt = i * 0.71
		var vertices: Array[Vector2] = []
		for j in 6:
			var a := TAU * j / 6.0 + 0.30
			vertices.append(Vector2(cos(a), sin(a)) * radii)
		_surface(crystal, Vector2i(144, 104))
		_fill_polygon(crystal, PackedVector2Array(vertices), Color(Ink.INK, 0.84))
		_relief(crystal, "facets", radii)
		for j in 6:
			_line(crystal, vertices[j], vertices[(j + 1) % 6], 0.31)
			_etch_line(crystal, vertices[j] * 0.91, vertices[(j + 1) % 6] * 0.91)
		_etch_line(crystal, vertices[2] * 0.91, Vector2(radii.x * 0.34, radii.y * 0.2))
		_etch_line(crystal, vertices[4] * 0.91, Vector2(radii.x * 0.34, radii.y * 0.2))
		for j in 5:
			_etch_line(crystal, Vector2(-radii.x, -radii.y * 0.5 + j * 5),
				Vector2(radii.x * 0.2, -radii.y * 0.1 + j * 5), Ink.SOOT)
	for layer in layers:
		if layer.has("image"):
			layer.texture = ImageTexture.create_from_image(layer.image)
			layer.erase("image")


func _draw() -> void:
	if mask == null:
		return
	for layer in layers:
		var strength: float = weights[int(layer.scene)]
		if strength < 0.002:
			continue
		var time := clock * 0.16 + float(layer.phase)
		var drift: Vector2 = layer.drift
		var center: Vector2 = layer.center + Vector2(sin(time) * drift.x, cos(time * 0.73) * drift.y) + offset * 0.35
		var angle := clock * float(layer.spin) + float(layer.get("tilt", 0.0))
		var cs := cos(angle)
		var sn := sin(angle)
		var breathe := 1.0 + sin(time * 1.4) * 0.018
		if layer.has("texture"):
			draw_set_transform(center.floor(), angle, Vector2.ONE * breathe)
			draw_texture(layer.texture, -layer.origin, Color(1, 1, 1, strength))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		for sample: Vector3 in layer.points:
			var local := Vector2(sample.x * cs - sample.y * sn, sample.x * sn + sample.y * cs) * breathe
			var p := (center + local).floor()
			var alpha: float = strength * sample.z
			if alpha > 0.005:
				draw_rect(Rect2(p, Vector2.ONE), Color(Ink.INK, alpha))
