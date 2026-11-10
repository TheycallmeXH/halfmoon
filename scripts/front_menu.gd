extends Node2D

signal start_requested
signal title_requested
signal exit_requested

enum Mode { TITLE, RESULT }
const SIZE := Vector2(768, 432)
const ART = preload("res://assets/menu/pilot_portrait.png")
const AUTHOR_LOGO = preload("res://assets/menu/katuria_logo.svg")
const GAME_TITLE := "SEISHIN ATTACK"
const TYPE = preload("res://assets/fonts/bm_space/BMSPA___.TTF")
const INK := Ink.INK
const PAPER := Ink.PAPER
const PRIMARY := Rect2(76, 248, 268, 40)
const SECONDARY := Rect2(76, 296, 268, 36)
const TERTIARY := Rect2(76, 344, 268, 36)
const PORTRAIT_HOME := Vector2(554, 266)
const PORTRAIT_AREA := Rect2(400, 124, 310, 284)
var mode := Mode.TITLE
var age := 0.0
var selected := 0
var stats := {}
var font: FontFile
var hovered := -1
var hover_age := 0.0
var portrait: Sprite2D
var portrait_mat: ShaderMaterial
var pointer_target := Vector2.ZERO
var parallax := Vector2.ZERO
var pointer_pos := Vector2(-100, -100)
var portrait_hover := 0.0
var signal_kick := 0.0
var last_pulse := -1.0
var pulses: Array[Dictionary] = []
var ship_pos := Vector2(198, 191)
var preview_source: Node2D
var departing := false
var departure_age := 0.0
var departure_origin := Vector2.ZERO
var mechanical_time := 0.0
var craft_layer: Node2D
var feedback_layer: Node2D
var pointer_active := false
var cursor_lock := 0.0
var click_kick := 0.0


func _ready() -> void:
	font = TYPE.duplicate()
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.hinting = TextServer.HINTING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	portrait = Sprite2D.new()
	portrait.texture = ART
	portrait.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	portrait.position = PORTRAIT_HOME
	portrait.scale = Vector2(0.18, 0.18)
	portrait_mat = ShaderMaterial.new()
	portrait_mat.shader = preload("res://shaders/menu_portrait.gdshader")
	portrait_mat.set_shader_parameter("src", portrait.texture)
	portrait.material = portrait_mat
	add_child(portrait)
	craft_layer = Node2D.new()
	craft_layer.draw.connect(_draw_preview_ship.bind(craft_layer))
	add_child(craft_layer)
	feedback_layer = Node2D.new()
	feedback_layer.draw.connect(_draw_feedback.bind(feedback_layer))
	add_child(feedback_layer)


func _reset_signal() -> void:
	departing = false
	departure_age = 0.0
	mechanical_time = 0.0
	pointer_target = Vector2.ZERO
	parallax = Vector2.ZERO
	pointer_pos = Vector2(-100, -100)
	portrait_hover = 0.0
	signal_kick = 0.0
	last_pulse = -1.0
	pulses.clear()
	pointer_active = false
	cursor_lock = 0.0
	click_kick = 0.0
	ship_pos = Vector2(198, 191)
	portrait.position = PORTRAIT_HOME
	portrait_mat.set_shader_parameter("proximity", 0.0)
	portrait_mat.set_shader_parameter("impact", 0.0)
	if craft_layer != null:
		craft_layer.queue_redraw()
	if feedback_layer != null:
		feedback_layer.queue_redraw()


func show_title() -> void:
	mode = Mode.TITLE
	age = 0.0
	selected = 0
	hovered = -1
	hover_age = 0.0
	portrait_mat.set_shader_parameter("clock", 0.0)
	_reset_signal()
	show()
	queue_redraw()


func show_result(data: Dictionary) -> void:
	stats = data.duplicate()
	mode = Mode.RESULT
	age = 0.0
	selected = 0
	hovered = -1
	hover_age = 0.0
	portrait_mat.set_shader_parameter("clock", 0.0)
	_reset_signal()
	show()
	queue_redraw()


func advance(dt: float) -> void:
	var step := clampf(dt, 0.0, 0.05)
	age += step
	hover_age += step
	cursor_lock = lerpf(cursor_lock, 1.0 if hovered >= 0 else 0.0, 1.0 - exp(-step * 18.0))
	click_kick = maxf(0.0, click_kick - step * 5.0)
	mechanical_time = floorf(age * 18.0) / 18.0
	# Servo holds for most of each cycle, then catches up with a short settling motion.
	var servo_target := pointer_target.snapped(Vector2(0.08, 0.08))
	parallax = parallax.lerp(servo_target, 1.0 - exp(-step * 8.0))
	var near_portrait := PORTRAIT_AREA.has_point(pointer_pos)
	portrait_hover = lerpf(portrait_hover, 1.0 if near_portrait else 0.0,
		1.0 - exp(-step * 9.0))
	signal_kick = maxf(0.0, signal_kick - step * 2.0)
	var gate_jitter := Vector2(0.5 if int(age * 12) % 19 == 0 else 0.0, 0)
	portrait.position = PORTRAIT_HOME + (parallax * Vector2(5, 3)).snapped(Vector2(0.5, 0.5)) + gate_jitter
	var ship_target := Vector2(198, 191) + parallax * Vector2(46, 17)
	ship_pos = ship_pos.lerp(ship_target, 1.0 - exp(-step * 8.0))
	if departing:
		departure_age += step
		var spool := clampf(departure_age / 0.28, 0.0, 1.0)
		var flight := maxf(0.0, departure_age - 0.28) / 0.66
		ship_pos = departure_origin + Vector2(-7.0 * sin(spool * PI) + flight * flight * 850.0,
			-flight * flight * 28.0)
	for pulse in pulses:
		pulse.age += step
	while not pulses.is_empty() and pulses[0].age >= 0.8:
		pulses.pop_front()
	portrait_mat.set_shader_parameter("clock", mechanical_time)
	portrait_mat.set_shader_parameter("proximity", portrait_hover)
	portrait_mat.set_shader_parameter("impact", signal_kick)
	craft_layer.queue_redraw()
	feedback_layer.queue_redraw()
	queue_redraw()


func pointer(p: Vector2) -> void:
	if departing:
		return
	pointer_active = Rect2(24, 20, 720, 392).has_point(p)
	pointer_pos = p
	pointer_target = ((p - SIZE * 0.5) / (SIZE * 0.5)).clamp(-Vector2.ONE, Vector2.ONE) \
		if Rect2(24, 20, 720, 392).has_point(p) else Vector2.ZERO
	var next := -1
	if PRIMARY.has_point(p):
		next = 0
	elif SECONDARY.has_point(p):
		next = 1
	elif mode == Mode.RESULT and TERTIARY.has_point(p):
		next = 2
	if next != hovered:
		hover_age = 0.0
	hovered = next
	if hovered >= 0:
		selected = hovered
	queue_redraw()
	feedback_layer.queue_redraw()


func interact(p: Vector2) -> void:
	if departing:
		return
	if age < 0.35 or age - last_pulse < 0.12 or not Rect2(36, 124, 696, 280).has_point(p):
		return
	last_pulse = age
	click_kick = 1.0
	pulses.append({"position": p, "age": 0.0})
	if pulses.size() > 6:
		pulses.pop_front()
	if PORTRAIT_AREA.has_point(p):
		signal_kick = 1.0
	queue_redraw()
	feedback_layer.queue_redraw()


func activate() -> void:
	if age < 0.35 or departing:
		return
	click_kick = 1.0
	if selected == (1 if mode == Mode.TITLE else 2):
		exit_requested.emit()
	elif selected == 1 and mode == Mode.RESULT:
		title_requested.emit()
	else:
		start_requested.emit()


func handle_key(keycode: Key) -> void:
	if departing:
		return
	pointer_active = false
	hovered = -1
	if keycode in [KEY_UP, KEY_DOWN, KEY_TAB, KEY_W, KEY_S]:
		var direction := -1 if keycode in [KEY_UP, KEY_W] else 1
		selected = posmod(selected + direction, 2 if mode == Mode.TITLE else 3)
	elif keycode == KEY_R:
		selected = 0
		activate()
	elif keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_Z, KEY_X]:
		activate()
	elif keycode == KEY_ESCAPE and mode == Mode.RESULT and age >= 0.35:
		title_requested.emit()
	queue_redraw()


func begin_departure() -> void:
	departing = true
	departure_age = 0.0
	departure_origin = ship_pos
	hovered = -1
	signal_kick = 0.65
	pointer_active = false


func _text(p: Vector2, value: String, size: int = 16, color: Color = INK) -> void:
	draw_string(font, p.floor(), value, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func _center(y: float, value: String, size: int, color: Color = INK) -> void:
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(Vector2(floorf((SIZE.x - width) * 0.5), y), value, size, color)


func _button(rect: Rect2, value: String, index: int) -> void:
	var active := selected == index
	var hover := hovered == index
	if active:
		draw_rect(rect, Color(INK, 0.94 if hover else 0.82))
		# Hover raster stays inside the selected command.
		var beam := fposmod(hover_age * 68, rect.size.y)
		for row in range(0, int(rect.size.y), 3):
			draw_line(rect.position + Vector2(0, row),
				rect.position + Vector2(rect.size.x, row), Color(PAPER, 0.08), 1)
		if hover:
			draw_rect(Rect2(rect.position + Vector2(0, beam), Vector2(rect.size.x, 2)),
				Color(PAPER, 0.24))
			if hover_age < 0.12:
				draw_rect(rect, Color(PAPER, (0.12 - hover_age) * 2))
		var cursor := ">" if fmod(age, 1.0) < 0.76 or hover else " "
		_text(rect.position + Vector2(12, 27), cursor, 24, PAPER)
		var offset := 1.0 if hover and fmod(hover_age, 1.7) < 0.055 else 0.0
		_text(rect.position + Vector2(38 + offset, 27), value, 24, PAPER)
		if hover:
			_text(rect.position + Vector2(39, 28), value, 24, Color(PAPER, 0.16))
	else:
		_text(rect.position + Vector2(38, 27), value, 24, Color(INK, 0.55))


func _draw() -> void:
	if font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, SIZE), PAPER)
	_draw_signal_field()
	draw_rect(Rect2(20, 16, 728, 400), Color(INK, 0.7), false, 2)
	_draw_title()
	draw_line(Vector2(52, 115), Vector2(716, 115), Color(INK, 0.42), 2)
	if mode == Mode.TITLE:
		_button(PRIMARY, "START", 0)
		_button(SECONDARY, "EXIT", 1)
	else:
		_text(Vector2(76, 155), "GAME OVER", 24)
		var seconds := int(stats.get("time", 0))
		var lines := ["SCORE  %06d" % int(stats.get("score", 0)),
			"KILLS  %06d" % int(stats.get("kills", 0)),
			"LOOP %02d  TIME %02d:%02d" % [int(stats.get("loop", 1)), seconds / 60, seconds % 60]]
		for row in 3:
			_text(Vector2(76, 183 + row * 23), lines[row], 16)
		_button(PRIMARY, "RETRY", 0)
		_button(SECONDARY, "TITLE", 1)
		_button(TERTIARY, "EXIT", 2)
	_draw_mechanical_details()


func _draw_title() -> void:
	draw_texture_rect(AUTHOR_LOGO, Rect2(55, 27, 112, 28), false)
	_text(Vector2(171, 54), "'s", 16, Color(INK, 0.8))
	var width := font.get_string_size(GAME_TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, 48).x
	var x := floorf((SIZE.x - width) * 0.5)
	# Fixed-size oblique lettering and stepped extrusion, like an arcade cabinet print.
	draw_set_transform_matrix(Transform2D(Vector2(1, 0), Vector2(-0.16, 1), Vector2(x, 99)))
	for depth in range(4, 0, -1):
		_text(Vector2(depth, depth), GAME_TITLE, 48, Color(INK, 0.20))
	_text(Vector2.ZERO, GAME_TITLE, 48, INK)
	_text(Vector2(-1, -1), GAME_TITLE, 48, Color(PAPER, 0.12))
	draw_set_transform(Vector2.ZERO)
	# Thin paper cuts break up the solid letters without soft bloom.
	for y in [72, 80]:
		draw_line(Vector2(x + 6, y), Vector2(x + width - 1, y), Color(PAPER, 0.42), 1)
	for i in 4:
		var p := Vector2(652 + i * 12, 39)
		draw_line(p, p + Vector2(7, -10), Color(INK, 0.18 + i * 0.13), 3)


func _draw_signal_field() -> void:
	var drift := parallax * Vector2(8, 4)
	# Screen-printed diagonal night field; the original portrait sits above it.
	draw_colored_polygon(PackedVector2Array([
		Vector2(448, 130), Vector2(716, 130), Vector2(716, 402), Vector2(366, 402)
	]), INK)
	for i in 44:
		var p := Vector2(466 + fposmod(i * 53.7, 241), 140 + fposmod(i * 37.3, 246))
		p += drift * (0.3 + float(i % 3) * 0.3)
		var light := 0.20 + 0.30 * (0.5 + 0.5 * sin(age * 1.2 + i * 2.4))
		draw_rect(Rect2(p.floor(), Vector2(2 if i % 9 == 0 else 1, 1)), Color(PAPER, light))
	var meteor_phase := fposmod(age, 7.0)
	if meteor_phase > 3.0 and meteor_phase < 3.75:
		var meteor := Vector2(484, 152) + Vector2(180, 70) * (meteor_phase - 3.0)
		draw_line(meteor - Vector2(24, 9), meteor, Color(PAPER, 0.32), 1)
		draw_rect(Rect2(meteor.floor(), Vector2(2, 1)), Color(PAPER, 0.8))
	# Perspective lines move towards the viewer, confined to the night field.
	var vanishing := Vector2(550, 310) + drift
	for i in 9:
		var end := Vector2(372 + i * 43, 402)
		draw_line(vanishing, end, Color(PAPER, 0.13), 1)
	for i in 8:
		var depth := fposmod(float(i) / 8.0 + age * 0.045, 1.0)
		var y := 328.0 + depth * depth * 74.0
		var left := lerpf(448, 366, (y - 130) / 272)
		draw_line(Vector2(left, y), Vector2(716, y), Color(PAPER, 0.17), 1)
	for i in 14:
		var y := 140 + i * 18
		draw_line(Vector2(704, y), Vector2(710, y), Color(PAPER, 0.35), 1)
	var sweep := 140 + fposmod(floorf(age * 7.0) * 4.0, 250)
	draw_line(Vector2(690, sweep), Vector2(710, sweep), Color(PAPER, 0.72), 2)
	# Open registration corners follow the portrait, without enclosing it in a card.
	for corner in [Vector2(416, 136), Vector2(700, 136), Vector2(416, 396), Vector2(700, 396)]:
		var p: Vector2 = corner + parallax * Vector2(5, 3)
		var direction := Vector2(1 if corner.x < PORTRAIT_HOME.x else -1,
			1 if corner.y < PORTRAIT_HOME.y else -1)
		draw_line(p, p + Vector2(direction.x * 12, 0), Color(PAPER, 0.55), 1)
		draw_line(p, p + Vector2(0, direction.y * 10), Color(PAPER, 0.55), 1)


func _pulse_radius(p: Vector2) -> float:
	var limit := minf(minf(p.x - 37, 731 - p.x), minf(p.y - 127, 403 - p.y))
	var exclusions: Array[Rect2] = [PRIMARY.grow(6), SECONDARY.grow(6)]
	if mode == Mode.RESULT:
		exclusions.append(TERTIARY.grow(6))
		exclusions.append(Rect2(68, 132, 300, 107))
	for rect in exclusions:
		var closest := p.clamp(rect.position, rect.end)
		limit = minf(limit, p.distance_to(closest) - 1.0)
	return clampf(limit, 0.0, 18.0)


func _draw_feedback(canvas: Node2D) -> void:
	for pulse in pulses:
		var life: float = clampf(pulse.age / 0.8, 0.0, 1.0)
		var p: Vector2 = pulse.position
		var limit := _pulse_radius(p)
		if limit < 3.0:
			continue
		var reach := lerpf(2.0, limit, 1.0 - pow(1.0 - life, 2.0))
		var color := Color(PAPER if p.x > 430 else INK, pow(1.0 - life, 1.5) * 0.55)
		# Fit the whole ring rather than clipping individual sides.
		canvas.draw_arc(p, reach, 0.0, TAU, 33, color, 1, true)
	if not pointer_active or departing:
		return
	var p := pointer_pos.snapped(Vector2(0.5, 0.5))
	var light := PAPER if hovered >= 0 or p.x > 430 else INK
	var dark := INK if light == PAPER else PAPER
	# Open corners leave the exact hit point unobstructed.
	var radius := lerpf(6.0, 4.5, cursor_lock) - click_kick
	for direction in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var root: Vector2 = p + direction * radius
		var corner := PackedVector2Array([root - Vector2(direction.x * 2.5, 0),
			root, root - Vector2(0, direction.y * 2.5)])
		canvas.draw_polyline(corner, Color(dark, 0.45), 2, true)
		canvas.draw_polyline(corner, Color(light, 0.95), 1, true)
	if hovered >= 0 and click_kick > 0:
		var rect: Rect2 = [PRIMARY, SECONDARY, TERTIARY][hovered]
		canvas.draw_rect(rect, Color(PAPER, click_kick * 0.16))


func _draw_exhaust(canvas: Node2D) -> void:
	var thrust := smoothstep(0.0, 0.38, departure_age) if departing else 0.0
	var flicker := sin(age * 47.0) * 0.5 + sin(age * 79.0) * 0.25
	var length := 9.0 + thrust * 53.0 + flicker * (1.0 + thrust * 3.0)
	var width := 1.3 + thrust * 2.2
	var nozzle := Vector2(-12, 0)
	# All exhaust geometry uses the hull transform: root stays pinned during banking.
	canvas.draw_colored_polygon(PackedVector2Array([nozzle + Vector2(0, -1.2),
		nozzle + Vector2(-length * 0.22, -width),
		nozzle + Vector2(-length, -0.4), nozzle + Vector2(-length * 1.08, 0),
		nozzle + Vector2(-length * 0.65, width * 0.5),
		nozzle + Vector2(-length * 0.2, width), nozzle + Vector2(0, 1.2)]), Color(INK, 0.9))
	canvas.draw_colored_polygon(PackedVector2Array([nozzle + Vector2(0, -0.8),
		nozzle + Vector2(-length * 0.2, -width * 0.55),
		nozzle + Vector2(-length * 0.86, 0),
		nozzle + Vector2(-length * 0.2, width * 0.55),
		nozzle + Vector2(0, 0.8)]), Color(PAPER, 0.95))
	canvas.draw_line(nozzle, nozzle + Vector2(-length * 0.65, 0),
		Color(1, 0.98, 0.86, 0.9), 0.7, true)
	if thrust < 0.05:
		return
	for i in 4:
		var x := -5.0 - i * (5.0 + thrust * 5.0)
		var breadth := width * (0.65 - i * 0.1)
		canvas.draw_polyline(PackedVector2Array([nozzle + Vector2(x + 2, 0),
			nozzle + Vector2(x, -breadth), nozzle + Vector2(x - 3, 0),
			nozzle + Vector2(x, breadth), nozzle + Vector2(x + 2, 0)]),
			Color(INK, thrust * 0.45), 0.6, true)
	for i in 12:
		var phase := fposmod(departure_age * (1.8 + i % 3 * 0.22) + i * 0.137, 1.0)
		var spread := sin(i * 7.3) * (1.0 + phase * 5.0) * thrust
		var ember := nozzle + Vector2(-length * (0.3 + phase * 1.35), spread)
		canvas.draw_line(ember, ember + Vector2(-1 - phase * 4, 0),
			Color(INK, (1.0 - phase) * thrust * 0.45), 0.6, true)


func _draw_preview_ship(canvas: Node2D) -> void:
	if mode != Mode.TITLE and not departing:
		return
	var p := ship_pos + Vector2(0, floorf(sin(mechanical_time * 1.6) * 2))
	for i in 18:
		var x := 84 + i * 14
		var wave := floorf(sin(float(i) * 0.65 - mechanical_time * 2.2) * (3.0 + signal_kick * 7.0))
		canvas.draw_line(Vector2(x, 222), Vector2(x, 222 - wave), Color(INK, 0.18), 1)
	canvas.draw_set_transform(p, parallax.y * 0.08, Vector2(2, 2))
	_draw_exhaust(canvas)
	canvas.draw_set_transform(Vector2.ZERO)
	if is_instance_valid(preview_source):
		# Use the actual player's geometry, including its asymmetric fins and blunt nose.
		canvas.draw_set_transform(p, parallax.y * 0.08, Vector2(2, 2))
		var hull: PackedVector2Array = preview_source._hull_xf(Vector2.ZERO, 0.0)
		Ink.paper_edge(canvas, hull)
		Ink.fill_poly(canvas, hull, INK)
		Ink.fill_poly(canvas, preview_source._body_slab(Vector2.ZERO, 0.0,
			preview_source._hull_kin()), Color(0.30, 0.30, 0.28))
		var dorsal: Array = preview_source._fin_lead(Vector2.ZERO, 0.0)
		var ventral: Array = preview_source._ventral_lead(Vector2.ZERO, 0.0)
		Ink.dashed(canvas, dorsal[0], dorsal[1], 1.0, 0.0, 2.0, Color(PAPER, 0.34))
		Ink.dashed(canvas, ventral[0], ventral[1], 1.0, 0.0, 2.0, Color(PAPER, 0.24))
		Ink.dither_rect(canvas, Rect2(6, -3, 3, 2), PAPER, 8)
		canvas.draw_rect(Rect2(-12, -1, 1, 2), Color(PAPER, 0.85))
		canvas.draw_set_transform(Vector2.ZERO)
	canvas.draw_line(Vector2(84, 238), Vector2(334, 238), Color(INK, 0.2), 1)
	canvas.draw_rect(Rect2(84 + fposmod(age * 35, 240), 237, 10, 2), Color(INK, 0.5))


func _draw_mechanical_details() -> void:
	# Reel-drive marks and discrete phosphor segments stay clear of the text.
	for side in [42.0, 726.0]:
		var center := Vector2(side, 394)
		var angle := floorf(age * 10) * PI / 12
		for tooth in 8:
			var a := angle + tooth * TAU / 8
			var direction := Vector2.from_angle(a)
			draw_line(center + direction * 4, center + direction * 7, Color(INK, 0.42), 1)
		draw_rect(Rect2(center - Vector2.ONE, Vector2(2, 2)), INK)
	for i in 26:
		var on := i <= int(fposmod(mechanical_time * 9, 26))
		draw_rect(Rect2(80 + i * 10, 388, 5, 2), Color(INK, 0.38 if on else 0.09))
	var index := int(age * 5) % 12
	for i in 12:
		var height := 3 + (i * 7 + index * 3) % 9
		draw_rect(Rect2(364, 142 + i * 17, height, 1), Color(INK, 0.18))
	if departing:
		for i in 16:
			var x := 70.0 + fposmod(i * 48.0 - departure_age * 420, 640.0)
			var y := 152.0 + float((i * 31) % 220)
			if y < 236 or x > 380:
				draw_line(Vector2(x, y), Vector2(x + 14, y), Color(INK, 0.16), 1)
