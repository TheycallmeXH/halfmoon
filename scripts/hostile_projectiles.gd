# Shape carries threat identity; only twelve one-pixel cores feed bloom.
extends RefCounted


static func draw(canvas: Node2D, b: Dictionary, hot: bool, bomb: bool, machine: bool) -> void:
	var p: Vector2 = (b.p as Vector2).floor()
	var radius := float(b.r)
	var velocity: Vector2 = b.v
	var angle := velocity.angle()
	var direction := velocity.normalized()
	var side := direction.orthogonal()
	var points: Array[Vector2] = []
	var style := str(b.get("shape", "dart" if radius < 2.0 else "diamond"))
	if bomb:
		Ink.disc(canvas, p, radius + 1.5, Ink.PAPER)
		Ink.disc(canvas, p, radius, Ink.INK)
		canvas.draw_line(p - side * radius * 0.65, p + side * radius * 0.65, Ink.PAPER, 1)
		canvas.draw_line(p - direction * radius * 0.6, p - direction * radius * 0.6 + side * 2, Ink.SOOT, 1)
	elif style == "seed":
		points = [Vector2(3, 0), Vector2(0, -2), Vector2(-3, 0), Vector2(0, 2)]
	elif machine:
		points = [Vector2(3, -1), Vector2(3, 1), Vector2(-2, 1), Vector2(-2, -1)]
	elif style == "dart":
		points = [Vector2(4, 0), Vector2(-2, -2), Vector2(-1, 0), Vector2(-2, 2)]
	else:
		var r := maxf(2.0, radius)
		points = [Vector2(r + 1, 0), Vector2(0, -r), Vector2(-r, 0), Vector2(0, r)]
	if not points.is_empty():
		var rim := PackedVector2Array()
		var body := PackedVector2Array()
		for point in points:
			rim.append((p + (point + point.normalized() * 1.3).rotated(angle)).floor())
			body.append((p + point.rotated(angle)).floor())
		canvas.draw_colored_polygon(rim, Ink.PAPER)
		canvas.draw_colored_polygon(body, Ink.INK)
		var glint := (p - side).floor()
		canvas.draw_rect(Rect2(glint, Vector2.ONE), Ink.PAPER)
		if radius >= 2.0:
			canvas.draw_rect(Rect2((p - direction).floor(), Vector2.ONE), Ink.SOOT)
	# Short asymmetric glints preserve a solid ink head and readable collision.
	var core := (p + direction).floor()
	canvas.draw_rect(Rect2(core, Vector2.ONE), Color(1, 1, 0.97) if hot else Ink.PAPER)
	if hot and (bomb or radius >= 2.0):
		for distance in [3.0, 4.0]:
			canvas.draw_rect(Rect2((p + side * distance).floor(), Vector2.ONE), Color(Ink.PAPER, 0.65))
