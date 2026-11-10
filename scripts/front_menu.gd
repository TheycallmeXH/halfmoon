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
	ship_pos = Vector2(198, 191)
	portrait.position = PORTRAIT_HOME
	portrait_mat.set_shader_parameter("proximity", 0.0)
	portrait_mat.set_shader_parameter("impact", 0.0)
	if craft_layer != null:
		craft_layer.queue_redraw()


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
	queue_redraw()


func pointer(p: Vector2) -> void:
	if departing:
		return
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


func interact(p: Vector2) -> void:
	if departing:
		return
	if age < 0.35 or age - last_pulse < 0.12 or not Rect2(36, 124, 696, 280).has_point(p):
		return
	last_pulse = age
	pulses.append({"position": p, "age": 0.0})
	if pulses.size() > 6:
		pulses.pop_front()
	if PORTRAIT_AREA.has_point(p):
		signal_kick = 1.0
	queue_redraw()


func activate() -> void:
	if age < 0.35 or departing:
		return
	if selected == (1 if mode == Mode.TITLE else 2):
		exit_requested.emit()
	elif selected == 1 and mode == Mode.RESULT:
		title_requested.emit()
	else:
		start_requested.emit()


func handle_key(keycode: Key) -> void:
	if departing:
		return
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
	_text(Vector2(171, 49), "'s", 16, Color(INK, 0.8))
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
	for pulse in pulses:
		var life: float = pulse.age / 0.8
		var p: Vector2 = pulse.position
		var color := Color(PAPER if p.x > 430 else INK, (1.0 - life) * 0.45)
		var reach := 5.0 + life * 38.0
		# Broken diamond wave, deliberately mechanical rather than a soft glow.
		for side in 4:
			var angle := float(side) * PI * 0.5
			var a := p + Vector2.from_angle(angle) * reach
			var b := p + Vector2.from_angle(angle + PI * 0.5) * reach
			a = a.lerp(b, 0.16)
			b = b.lerp(p + Vector2.from_angle(angle) * reach, 0.16)
			var segment_box := Rect2(a.min(b), (a - b).abs()).grow(1)
			var clear := not segment_box.intersects(PRIMARY.grow(6)) \
				and not segment_box.intersects(SECONDARY.grow(6))
			if mode == Mode.RESULT:
				clear = clear and not segment_box.intersects(TERTIARY.grow(6))
			if clear and Rect2(36, 126, 696, 278).encloses(segment_box):
				draw_line(a, b, color, 1)
	if hovered < 0 and Rect2(40, 130, 680, 270).has_point(pointer_pos):
		var tint := Color(PAPER if pointer_pos.x > 430 else INK, 0.45)
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			draw_line(pointer_pos + direction * 5, pointer_pos + direction * 10, tint, 1)


func _draw_preview_ship(canvas: Node2D) -> void:
	if mode != Mode.TITLE and not departing:
		return
	var p := ship_pos + Vector2(0, floorf(sin(mechanical_time * 1.6) * 2))
	for i in 18:
		var x := 84 + i * 14
		var wave := floorf(sin(float(i) * 0.65 - mechanical_time * 2.2) * (3.0 + signal_kick * 7.0))
		canvas.draw_line(Vector2(x, 222), Vector2(x, 222 - wave), Color(INK, 0.18), 1)
	for i in 3:
		var length := 10 + i * 7 + int(fposmod(age * 32, 4))
		canvas.draw_line(p + Vector2(-17 - length, i * 3 - 3),
			p + Vector2(-18, i * 3 - 3), Color(INK, 0.12 + i * 0.08), 1)
	if departing:
		var thrust := clampf(departure_age / 0.35, 0.0, 1.0)
		for i in 4:
			var length := 15.0 + thrust * 70.0 + float(i) * 8.0
			canvas.draw_line(p + Vector2(-25, (i - 2) * 2),
				p + Vector2(-length, (i - 2) * 3), Color(INK, 0.48 - i * 0.09), 1)
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
