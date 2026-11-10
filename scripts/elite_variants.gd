extends RefCounted

const NAMES := ["crystal", "foldwing", "orrery", "lancer"]
const WARN := [0.0, 0.85, 1.05, 0.80]
const CORE := Color(1.0, 1.0, 1.0)
const COMBAT_LIFE := 32.0


static func step(b: Dictionary, player: Vector2, dt: float) -> Array[Dictionary]:
	var shots: Array[Dictionary] = []
	var kind := int(b.variant)
	var age := float(b.t) - float(b.station_t)
	var state := int(b.get("action", 0))
	var timer := float(b.get("action_age", 0.0)) + dt
	var low := float(b.hp) <= float(b.max) * 0.5
	b.recoil = maxf(0.0, float(b.get("recoil", 0.0)) - dt * 4.0)
	if state == 0:
		var target := Vector2(259 + sin(age * 0.7) * 9, 108 + sin(age * 0.95) * 42)
		if kind == 2:
			target = Vector2(258 + cos(age * 0.8) * 10, 108 + sin(age * 0.8) * 32)
		elif kind == 3:
			target = Vector2(264, 108 + sin(age * 0.65) * 46)
		var origin: Vector2 = b.p
		b.p = origin.move_toward(origin.lerp(target, 1.0 - exp(-2.4 * dt)), 140.0 * dt)
		if timer >= (0.85 if low else 1.25):
			state = 1
			timer = 0.0
			b.aim = (player - (b.p as Vector2)).normalized().angle()
			if kind == 3:
				b.aim = PI
			b.anchor = b.p
			b.lane = clampf(player.y, 38.0, 174.0)
			b.volley = false
			b.pattern = int(b.get("cycle", 0)) % 2
			b.bend = (24.0 if float(b.lane) < 108.0 else -24.0) if int(b.pattern) == 1 else 0.0
	elif state == 1:
		if kind == 3:
			var target := Vector2(268, float(b.lane))
			b.p = (b.p as Vector2).move_toward(target, 145.0 * dt)
		if timer >= float(WARN[kind]):
			state = 2
			timer = 0.0
			b.anchor = b.p
			b.recoil = 1.0
			if kind == 1:
				if int(b.pattern) == 0:
					_fan(shots, b.p, float(b.aim), 7 if low else 5, 0.15, 142.0)
				else:
					for side in [-1, 1]:
						var port := (b.p as Vector2) + Vector2(-5, side * 17)
						_fan(shots, port, float(b.aim) + side * 0.18,
							4 if low else 3, 0.12, 132.0)
			elif kind == 2:
				# A locked, player-facing gap remains open throughout the volley.
				_orbit(shots, b, low, false)
	elif state == 2:
		if kind == 1 and low and timer >= 0.20 and not bool(b.volley) and int(b.pattern) == 0:
			b.volley = true
			b.recoil = 1.0
			_fan(shots, b.p, float(b.aim) + 0.075, 7, 0.15, 142.0)
		if kind == 2 and int(b.pattern) == 1 and timer >= 0.24 and not bool(b.volley):
			b.volley = true
			_orbit(shots, b, low, true)
			b.recoil = 0.65
		if kind == 3:
			var progress := clampf(timer / 0.38, 0.0, 1.0)
			var anchor: Vector2 = b.anchor
			var bend := float(b.get("bend", 0.0))
			b.p = anchor + Vector2(-68.0 * sin(progress * PI * 0.5),
				bend * sin(progress * PI * 0.5))
			if timer >= 0.38:
				_fan(shots, b.p, float(b.aim), 5 if low else 3, 0.20, 155.0)
				b.recoil = 1.0
		if timer >= (0.38 if kind == 3 else 0.40):
			state = 3
			timer = 0.0
	elif state == 3:
		# Deliberate firing window before the next hover and warning.
		if timer >= (0.85 if kind == 3 else 0.65):
			state = 0
			timer = 0.0
			b.cycle = int(b.get("cycle", 0)) + 1
	b.action = state
	b.action_age = timer
	b.charge = clampf(timer / float(WARN[kind]), 0.0, 1.0) if state == 1 else 0.0
	return shots


static func _orbit(shots: Array[Dictionary], b: Dictionary, low: bool, second: bool) -> void:
	var staggered := int(b.get("pattern", 0)) == 1
	var count := (7 if low else 6) if staggered else (12 if low else 10)
	for i in count:
		var angle := float(b.aim) + 0.43 + (TAU - 0.86) * float(i) / float(count - 1)
		if second:
			angle += 0.12 if i < count / 2 else -0.12
		shots.append({"p": b.p, "v": Vector2.from_angle(angle) * (108.0 if second else 118.0),
			"r": 1.5, "shape": "diamond"})


static func _fan(shots: Array[Dictionary], p: Vector2, aim: float, count: int,
		spread: float, speed: float) -> void:
	for i in count:
		shots.append({"p": p, "v": Vector2.from_angle(aim + (i - (count - 1) * 0.5) * spread) * speed,
			"r": 1.5, "shape": "dart"})


static func _panel(ci: Node2D, p: Vector2, points: PackedVector2Array, angle: float,
		scale: Vector2, flash: float) -> void:
	var polygon := PackedVector2Array()
	for point in points:
		polygon.append((p + (point * scale).rotated(angle)).floor())
	Ink.paper_edge(ci, polygon)
	Ink.fill_poly(ci, polygon, Ink.INK.lerp(Ink.MUTE, flash))
	if polygon.size() >= 3:
		Ink.fill_poly(ci, PackedVector2Array([p.floor(), polygon[1], polygon[2]]),
			Ink.MUTE.lerp(Ink.PAPER, flash * 0.65))
		ci.draw_line(p.floor(), polygon[2], Ink.SOOT.lerp(Ink.PAPER, flash), 1.0)
		# Etched pixels live inside the armor; the one-pixel perimeter stays crisp.
		var bounds := Rect2(points[0], Vector2.ZERO)
		for vertex in points:
			bounds = bounds.expand(vertex)
		for y in range(int(bounds.position.y) + 2, int(bounds.end.y) - 1, 3):
			for x in range(int(bounds.position.x) + 2, int(bounds.end.x) - 1, 4):
				var pixel := Vector2(x, y)
				if Geometry2D.is_point_in_polygon(pixel, points) and Geometry2D.is_point_in_polygon(pixel + Vector2(1, 1), points):
					ci.draw_rect(Rect2((p + (pixel * scale).rotated(angle)).floor(), Vector2.ONE), Ink.SOOT)
		ci.draw_line(polygon[0], polygon[1], Ink.PAPER, 1.0)
		ci.draw_rect(Rect2(p.floor(), Vector2(2, 1)), Ink.PAPER)


static func _wire(ci: Node2D, a: Vector2, b: Vector2, color: Color) -> void:
	ci.draw_line(a.floor(), b.floor(), Color(Ink.PAPER, 0.045), 7.0)
	ci.draw_line(a.floor(), b.floor(), Color(Ink.PAPER, 0.14), 5.0)
	ci.draw_line(a.floor(), b.floor(), Ink.PAPER, 3.0)
	ci.draw_line(a.floor(), b.floor(), color, 1.0)


static func draw(ci: Node2D, b: Dictionary) -> void:
	var p: Vector2 = b.p
	var time := float(b.t)
	var kind := int(b.variant)
	var state := int(b.get("action", 0))
	var age := float(b.get("action_age", 0.0))
	var charge := float(b.get("charge", 0.0))
	var recoil := float(b.get("recoil", 0.0))
	var flash := clampf(float(b.hurt) * 8.0, 0.0, 1.0)
	var retreat := float(b.get("retreat_age", 0.0))
	var deploy := smoothstep(0.0, 1.15, time) * (1.0 - smoothstep(0.0, 0.9, retreat))
	var angle := sin(time * 1.6) * 0.06
	if kind == 1:
		var spread := deploy * (1.0 - charge * 0.68 + recoil * 0.3)
		for side in [-1, 1]:
			var hinge := p + Vector2(1, side * 3)
			var wing := PackedVector2Array([Vector2.ZERO, Vector2(13, side * 21),
				Vector2(-11, side * 16), Vector2(-5, side * 4)])
			_panel(ci, hinge, wing, angle, Vector2(1, maxf(0.14, spread)), flash)
			ci.draw_line(hinge.floor(), (hinge + Vector2(6, side * 14 * spread)).floor(), Ink.SOOT)
			var tip := hinge + Vector2(-8, side * 12 * spread)
			Ink.dot(ci, tip, 1.0, Ink.INK)
			var nozzle := (hinge + Vector2(-5, side * 17 * spread)).floor()
			ci.draw_rect(Rect2(nozzle - Vector2(2, 1), Vector2(4, 3)), Ink.INK)
			ci.draw_rect(Rect2(nozzle, Vector2(2, 1)), Ink.PAPER)
			if state == 1:
				ci.draw_rect(Rect2(nozzle - Vector2(3 + int(charge * 3), 0), Vector2(2, 1)), Ink.MUTE)
		_panel(ci, p + Vector2(recoil * 3, 0),
			PackedVector2Array([Vector2(-10, 0), Vector2(0, -5), Vector2(10, 0), Vector2(0, 5)]),
			angle, Vector2.ONE, flash)
		for i in 3:
			var end := p + Vector2(14 + i * 3, sin(time * 4 + i) * 3)
			ci.draw_line((p + Vector2(7, i - 1)).floor(), end.floor(), Ink.SOOT)
	elif kind == 2:
		for ring in 3:
			var radius := (16.0 + ring * 5.0 - charge * 4.0 + recoil * 2.0) * maxf(0.24, deploy)
			var rotation := time * (0.7 if ring % 2 == 0 else -0.55) + ring
			for segment in 8:
				var a := rotation + TAU * segment / 8.0
				var a2 := a + 0.48
				var v1 := Vector2(cos(a) * radius, sin(a) * radius * (0.50 + ring * 0.16))
				var v2 := Vector2(cos(a2) * radius, sin(a2) * radius * (0.50 + ring * 0.16))
				_wire(ci, p + v1, p + v2, Ink.SOOT)
				if segment % 2 == 0:
					var plate := (p + v1).floor()
					ci.draw_rect(Rect2(plate - Vector2(2, 2), Vector2(5, 4)), Ink.PAPER)
					ci.draw_rect(Rect2(plate - Vector2(1, 1), Vector2(3, 2)), Ink.INK)
					ci.draw_rect(Rect2(plate + Vector2(1, -1), Vector2.ONE), Ink.MUTE)
					ci.draw_line((p + v1 * 0.48).floor(), (p + v1 * 0.86).floor(), Ink.SOOT)
		_panel(ci, p, PackedVector2Array([Vector2(-8, 0), Vector2(0, -10),
			Vector2(8, 0), Vector2(0, 10)]), -time * 0.25, Vector2.ONE, flash)
	else:
		var extension := deploy * (1.0 - charge * 0.65)
		for side in [-1, 1]:
			_panel(ci, p, PackedVector2Array([Vector2(5, side * 2), Vector2(19, side * 13),
				Vector2(-1, side * 7)]), angle, Vector2(1, maxf(0.18, extension)), flash)
		_panel(ci, p, PackedVector2Array([Vector2(-16, 0), Vector2(9, -6),
			Vector2(14, 0), Vector2(9, 6)]), angle, Vector2.ONE, flash)
		for i in 4:
			var vent := (p + Vector2(2 + i * 3, -2)).floor()
			ci.draw_rect(Rect2(vent, Vector2(1, 4)), Ink.SOOT)
		ci.draw_line((p + Vector2(-13, 0)).floor(), (p + Vector2(-5, 0)).floor(), Ink.PAPER)
		for side in [-1, 1]:
			ci.draw_rect(Rect2((p + Vector2(12, side * 4)).floor(), Vector2(3, 1)), Ink.PAPER)
		if state == 2:
			for i in 5:
				var tail := p + Vector2(17 + i * 4, sin(time * 35 + i) * 2)
				ci.draw_rect(Rect2(tail.floor(), Vector2(3, 1)), Color(Ink.INK, 0.65 - i * 0.11))
	# Small white source, kept within the existing bloom budget.
	ci.draw_rect(Rect2((p + Vector2(-3, -1)).floor(), Vector2(2, 1)), CORE)
	if state == 1:
		var direction := Vector2.from_angle(float(b.get("aim", PI)))
		if kind == 3:
			for i in 19:
				var x := p.x - 21 - i * 4
				var bend := float(b.get("bend", 0.0))
				var preview := p.y + bend * clampf((p.x - x) / 68.0, 0.0, 1.0)
				ci.draw_rect(Rect2(Vector2(x, preview).floor(), Vector2(2, 1)),
					Color(Ink.INK, 0.16 + charge * 0.25))
		else:
			for side in [-1, 1]:
				var cue := p + direction.rotated(side * (0.43 if kind == 2 else 0.30)) * (28 + charge * 9)
				ci.draw_line((cue - direction * 3).floor(), cue.floor(), Color(Ink.INK, 0.45))
		Ink.ring(ci, p, 8 + (1 - charge) * 22, 1.0, Color(Ink.INK, 0.2 + charge * 0.3))
	if state == 3:
		for i in 3:
			var vent := p + Vector2(10 + age * 12 + i * 3, (i - 1) * 6)
			ci.draw_rect(Rect2(vent.floor(), Vector2(2, 1)), Color(Ink.SOOT, maxf(0, 0.4 - age * 0.4)))
