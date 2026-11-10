# State and geometry shared by special-unit simulation, rendering and probes.
extends RefCounted

enum Kind { DRONE = 3, TURRET = 4 }
enum State { ENTER, AIM, ATTACK, COOL, LEAVE }
const BOUNDS := Rect2(10, 9, 364, 198)
const DRONE_WARNING := 0.85
const TURRET_WARNING := 1.10
const BEAM_WIDTH := 3.0
const CORE := Color(1.0, 1.0, 0.97)
const DOCK_X := 314.0
const DRONE_ENTRY_TIME := 1.35
const TURRET_ENTRY_TIME := 1.70
const DRONE_SPEED := 335.0
const DRONE_ACCEL_TIME := 0.16


static func create(kind: int, y: float, loop_n: int) -> Dictionary:
	var hp := (2 if loop_n < 5 else 3) if kind == Kind.DRONE else mini(9, 6 + int((loop_n - 3) / 2))
	return {
		"kind": kind, "p": Vector2(381, y), "base": y,
		"hp": hp, "max": hp, "r": 5.0 if kind == Kind.DRONE else 9.0,
		"state": State.ENTER, "age": 0.0, "resident": 0.0,
		"dir": Vector2.LEFT, "fire": 999.0, "amp": 0.0, "spin": 0.0,
		"timer": 0.0, "spent": false, "shots": 0, "expired": false,
		"state_age": 0.0,
		"wake": [],
	}


static func _transition(f: Dictionary, state: int, timer: float = 0.0) -> void:
	f.state = state
	f.state_age = 0.0
	f.timer = timer


static func cancel(f: Dictionary, retreat: bool = false) -> void:
	var next := State.LEAVE if retreat or int(f.kind) == Kind.DRONE else State.COOL
	if int(f.state) != State.LEAVE:
		_transition(f, next, 3.4)
	f.spent = true


static func step(f: Dictionary, player: Vector2, dt: float) -> Vector2:
	var p: Vector2 = f.p
	var drone := int(f.kind) == Kind.DRONE
	var state := int(f.state)
	f.age = float(f.age) + dt
	f.state_age = float(f.get("state_age", 0.0)) + dt
	if state == State.ENTER:
		# Capture the placed origin once; probes and authored entrances may relocate it.
		if not f.has("entry_origin"):
			f.entry_origin = p
		var origin: Vector2 = f.entry_origin
		var duration := (DRONE_ENTRY_TIME if drone else TURRET_ENTRY_TIME) * maxf(0.0, origin.x - DOCK_X) / 67.0
		var progress := clampf(float(f.age) / maxf(0.001, duration), 0.0, 1.0)
		p.x = lerpf(origin.x, DOCK_X, 1.0 - (1.0 - progress) * (1.0 - progress))
		p.y = float(f.base) + sin(progress * PI) * (5.0 if drone else 2.5) * (-1.0 if float(f.base) > 108.0 else 1.0)
		if progress >= 1.0 and p.distance_to(player) >= 56.0:
			_transition(f, State.AIM if drone else State.COOL, DRONE_WARNING if drone else 1.0)
			f.dir = (player - p).normalized()
	elif state == State.AIM:
		var lock_window := 0.30 if drone else 0.40
		if float(f.timer) - dt > lock_window:
			f.dir = (player - p).normalized()
		f.timer = float(f.timer) - dt
		if float(f.timer) <= 0.0:
			_transition(f, State.ATTACK, 1.25 if drone else 0.24)
			f.spent = false
			f.shots = int(f.shots) + 1
	elif state == State.ATTACK:
		if drone:
			var attack_age := float(f.state_age)
			p += (f.dir as Vector2) * (_charge_distance(attack_age) - _charge_distance(maxf(0.0, attack_age - dt)))
			# World-space samples stay behind the hull instead of rotating with it.
			var wake: Array = f.get("wake", [])
			if wake.is_empty() or (wake.back().p as Vector2).distance_to(p) >= 2.0:
				wake.append({"p": p, "t": float(f.age)})
			while not wake.is_empty() and (float(f.age) - float(wake[0].t) > 0.22 or wake.size() > 48):
				wake.pop_front()
			f.wake = wake
		f.timer = float(f.timer) - dt
		if float(f.timer) <= 0.0:
			if drone:
				f.expired = true
			else:
				_transition(f, State.COOL, 3.4)
	elif state == State.COOL:
		f.timer = float(f.timer) - dt
		if float(f.timer) <= 0.0:
			_transition(f, State.AIM, TURRET_WARNING)
	elif state == State.LEAVE:
		var age := float(f.state_age)
		p.x += _retreat_distance(age) - _retreat_distance(maxf(0.0, age - dt))
		if p.x > 390.0:
			f.expired = true
	if state != State.ENTER:
		f.resident = float(f.resident) + dt
	if not drone and int(f.state) != State.LEAVE and (float(f.resident) > 15.0 or (int(f.shots) >= 3 and int(f.state) == State.COOL)):
		cancel(f, true)
	if int(f.state) == State.ENTER and float(f.age) > 4.0:
		cancel(f, true)
	return p


static func _charge_distance(age: float) -> float:
	# Integrate smooth acceleration, keeping travel identical at different FPS.
	var ramp := minf(age, DRONE_ACCEL_TIME)
	return 190.0 * ramp + (DRONE_SPEED - 190.0) * ramp * ramp / (2.0 * DRONE_ACCEL_TIME) + maxf(0.0, age - DRONE_ACCEL_TIME) * DRONE_SPEED


static func _retreat_distance(age: float) -> float:
	var acceleration_age := minf(age, 1.1)
	return 12.0 * acceleration_age + 30.0 * acceleration_age * acceleration_age + maxf(0.0, age - 1.1) * 78.0


static func deployment(f: Dictionary) -> float:
	if int(f.state) == State.ENTER:
		return lerpf(0.32, 1.0, smoothstep(0.15, 0.92, clampf((381.0 - float(f.p.x)) / 67.0, 0.0, 1.0)))
	if int(f.state) == State.LEAVE:
		return lerpf(1.0, 0.22, smoothstep(0.0, 0.80, float(f.get("state_age", 0.0))))
	return 1.0


static func remnant(f: Dictionary, violent: bool) -> Dictionary:
	return {"kind": int(f.kind), "p": f.p, "dir": facing(f), "deploy": deployment(f),
		"age": 0.0, "life": 0.46 if violent else 0.34, "violent": violent}


static func draw_remnant(canvas: Node2D, rem: Dictionary) -> void:
	var age := float(rem.age)
	var progress := clampf(age / float(rem.life), 0.0, 1.0)
	var alpha := 1.0 - smoothstep(0.12, 1.0, progress)
	var direction: Vector2 = rem.dir
	var side := direction.orthogonal()
	var drone := int(rem.kind) == Kind.DRONE
	var force := 1.0 if bool(rem.violent) else 0.55
	var chunks: Array = []
	if drone:
		var wing := 6.0 * float(rem.deploy)
		chunks = [
			[Vector2(7, 0), Vector2(-1, -1), Vector2(-1, 1)],
			[Vector2(2, 0), Vector2(-5, -wing), Vector2(-2, 0)],
			[Vector2(2, 0), Vector2(-2, 0), Vector2(-5, wing)]]
	else:
		chunks = [
			[Vector2(-7, -4), Vector2(0, -4), Vector2(0, 3), Vector2(-7, 3)],
			[Vector2(2, -4), Vector2(10, -2), Vector2(10, 3), Vector2(2, 4)],
			[Vector2(-2, -8), Vector2(8, -8), Vector2(8, -6), Vector2(-2, -6)],
			[Vector2(-2, 6), Vector2(8, 6), Vector2(8, 8), Vector2(-2, 8)],
			[Vector2(-12, -3), Vector2(-5, -3), Vector2(-5, -1), Vector2(-12, -1)]]
	for i in chunks.size():
		var spread := 0.0 if i == 0 else (-1.0 if i % 2 == 1 else 1.0)
		var drift := (direction * (32.0 + float(i) * 6.0) + side * spread * 36.0) * age * force
		var center: Vector2 = rem.p + drift + Vector2(0.0, 18.0 * age * age)
		var vertices := PackedVector2Array()
		for point in chunks[i]:
			var local: Vector2 = point
			var angle := (direction.angle() if drone else 0.0) + spread * age * 2.5
			vertices.append((center + local.rotated(angle)).floor())
		_fragment(canvas, vertices, alpha)


static func _fragment(canvas: Node2D, vertices: PackedVector2Array, alpha: float) -> void:
	if alpha >= 1.0:
		Ink.paper_edge(canvas, vertices)
	else:
		var center := Vector2.ZERO
		for point in vertices:
			center += point
		center /= float(vertices.size())
		var rim := PackedVector2Array()
		for point in vertices:
			rim.append((point + (point - center).normalized()).floor())
		canvas.draw_colored_polygon(rim, Color(Ink.PAPER, alpha * 0.85))
	canvas.draw_colored_polygon(vertices, Color(Ink.INK, alpha))


static func facing(f: Dictionary) -> Vector2:
	var state := int(f.state)
	if state == State.ENTER:
		return Vector2.LEFT.rotated(sin(clampf(float(f.age) / (DRONE_ENTRY_TIME if int(f.kind) == Kind.DRONE else TURRET_ENTRY_TIME), 0, 1) * PI) * 0.10)
	if state == State.LEAVE:
		return Vector2.RIGHT.rotated(lerp_angle((f.dir as Vector2).angle(), 0.0, smoothstep(0.0, 0.32, float(f.get("state_age", 0.0)))))
	return f.dir


static func beam(f: Dictionary) -> PackedVector2Array:
	var direction: Vector2 = f.dir
	var origin: Vector2 = f.p + direction * 10.0
	var distance := 500.0
	if absf(direction.x) > 0.0001:
		var dx := ((BOUNDS.end.x if direction.x > 0.0 else BOUNDS.position.x) - origin.x) / direction.x
		distance = minf(distance, maxf(0.0, dx))
	if absf(direction.y) > 0.0001:
		var dy := ((BOUNDS.end.y if direction.y > 0.0 else BOUNDS.position.y) - origin.y) / direction.y
		distance = minf(distance, maxf(0.0, dy))
	return PackedVector2Array([origin, origin + direction * distance])


static func hits(f: Dictionary, player: Vector2, previous: Vector2) -> bool:
	if int(f.state) != State.ATTACK or bool(f.spent):
		return false
	if int(f.kind) == Kind.DRONE:
		return Geometry2D.get_closest_point_to_segment(player, previous, f.p).distance_to(player) <= 11.0
	var ray := beam(f)
	return Geometry2D.get_closest_point_to_segment(player, ray[0], ray[1]).distance_to(player) <= BEAM_WIDTH * 0.5 + 2.0


static func draw(canvas: Node2D, f: Dictionary) -> void:
	var p: Vector2 = f.p
	var direction := facing(f)
	var state := int(f.state)
	var deploy := deployment(f)
	var side := direction.orthogonal()
	var drone := int(f.kind) == Kind.DRONE
	if drone and state == State.AIM:
		# A small engine wind-up before launch; collision/locked aim stay put.
		p -= direction * (1.0 - smoothstep(0.0, 0.30, float(f.timer))) * 1.5
	if drone and state == State.ATTACK:
		deploy *= lerpf(1.0, 0.68, smoothstep(0.0, 0.18, float(f.state_age)))
	if state == State.ENTER or state == State.LEAVE:
		var thrust := 1.0 - deploy if state == State.ENTER else smoothstep(0.12, 0.70, float(f.get("state_age", 0.0)))
		var tail := p - direction * 7.0
		var length := 3.0 + thrust * 10.0 + sin(float(f.age) * 39.0) * 1.0
		canvas.draw_line(tail, tail - direction * length, Ink.PAPER, 3.0)
		canvas.draw_line(tail, tail - direction * length, Ink.SOOT, 1.0)
		if thrust > 0.35:
			canvas.draw_rect(Rect2(tail.floor(), Vector2.ONE), CORE)
	if not drone and (state == State.AIM or state == State.ATTACK):
		var ray := beam(f)
		var length := ray[0].distance_to(ray[1])
		if state == State.AIM:
			var locked := float(f.timer) <= 0.4
			for i in int(length):
				if locked or i % 8 < 3:
					var q := (ray[0] + direction * float(i)).floor()
					canvas.draw_rect(Rect2(q, Vector2.ONE), Ink.MUTE if locked else Ink.SOOT)
		else:
			canvas.draw_line(ray[0], ray[1], Ink.PAPER, 5.0, false)
			canvas.draw_line(ray[0], ray[1], Ink.INK, BEAM_WIDTH, false)
			canvas.draw_line(ray[0], ray[1], Ink.PAPER, 1.0, false)
			canvas.draw_rect(Rect2(ray[0].floor() - Vector2.ONE, Vector2(3, 1)), CORE)
			canvas.draw_line(ray[0] - side * 5, ray[0] + side * 5, Ink.PAPER, 1.0)
	if drone:
		if state == State.ATTACK:
			var wake: Array = f.get("wake", [])
			for i in range(1, wake.size()):
				var fade := clampf(1.0 - (float(f.age) - float(wake[i].t)) / 0.22, 0.0, 1.0)
				var wobble := side * sin(float(wake[i].t) * 65.0) * (1.0 - fade) * 2.0
				var a: Vector2 = wake[i - 1].p - direction * 7.0
				var b: Vector2 = wake[i].p - direction * 7.0 + wobble
				canvas.draw_line(a.floor(), b.floor(), Color(Ink.PAPER, fade * 0.7), 3.0)
				canvas.draw_line(a.floor(), b.floor(), Color(Ink.SOOT, fade * 0.55), 1.0)
			var exhaust := p - direction * 7.0
			var length := 19.0 + sin(float(f.age) * 67.0) * 4.0
			var plume := PackedVector2Array([exhaust + side * 2.0,
				exhaust - direction * length + side * sin(float(f.age) * 49.0) * 1.5,
				exhaust - side * 2.0])
			canvas.draw_colored_polygon(plume, Ink.PAPER)
			canvas.draw_line(exhaust.floor(), (exhaust - direction * length * 0.75).floor(), Ink.SOOT, 1.0)
			canvas.draw_rect(Rect2(exhaust.floor(), Vector2.ONE), CORE)
			for j in 5:
				var distance := 12.0 + fposmod(float(f.age) * 110.0 + float(j) * 11.0, 48.0)
				var q := exhaust - direction * distance + side * sin(float(j) * 2.1 + float(f.age) * 24.0) * distance * 0.07
				canvas.draw_rect(Rect2(q.floor(), Vector2.ONE), Color(Ink.SOOT, (1.0 - distance / 64.0) * 0.65))
		elif state == State.AIM:
			for d in [10.0, 15.0, 20.0]:
				canvas.draw_rect(Rect2((p + direction * d).floor(), Vector2.ONE), Ink.INK)
		var vertices := PackedVector2Array([
			(p + direction * 7).floor(), (p - direction * 5 + side * (6.0 * deploy)).floor(),
			(p - direction * 2).floor(), (p - direction * 5 - side * (6.0 * deploy)).floor()])
		Ink.paper_edge(canvas, vertices)
		canvas.draw_colored_polygon(vertices, Ink.INK)
		canvas.draw_line(p - direction * 2 - side * 2, p - direction * 2 + side * 2, Ink.PAPER, 1)
		if state == State.AIM or state == State.ATTACK:
			canvas.draw_rect(Rect2((p + direction * 2).floor(), Vector2.ONE), CORE)
	else:
		var vertices := PackedVector2Array([
			p + Vector2(-7, -5), p + Vector2(9, -5), p + Vector2(11, -2),
			p + Vector2(11, 2), p + Vector2(9, 5), p + Vector2(-7, 5), p + Vector2(-9, 3), p + Vector2(-9, -3)])
		for sign_value in [-1, 1]:
			var fin := p + Vector2(-2, float(sign_value) * (4.0 + deploy * 3.0) - 1.0)
			canvas.draw_rect(Rect2(fin - Vector2.ONE, Vector2(12, 4)), Ink.PAPER)
			canvas.draw_rect(Rect2(fin, Vector2(10, 2)), Ink.INK)
		_fragment(canvas, vertices, 1.0)
		for x in [3, 6, 9]:
			canvas.draw_line(p + Vector2(x, -3), p + Vector2(x, 3), Ink.SOOT, 1)
		for sign_value in [-1, 1]:
			var root := p + side * float(sign_value) * (1.0 + deploy * 2.0)
			var muzzle := root + direction * (5.0 + deploy * 7.0)
			canvas.draw_line(root, muzzle, Ink.PAPER, 4)
			canvas.draw_line(root, muzzle, Ink.INK, 2)
		canvas.draw_line(p - side * 4, p + side * 4, Ink.PAPER, 1)
		if state == State.AIM:
			var charge := 1.0 - float(f.timer) / TURRET_WARNING
			canvas.draw_line(p - direction * 4, p - direction * 4 + side * (2.0 + charge * 4.0), Ink.PAPER, 1)
