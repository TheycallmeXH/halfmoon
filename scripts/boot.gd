# Halfmoon boot 闁?the whole render pipeline, built in code.
#
# Pass graph (every box is a SubViewport):
#
#   Screen   384x216  game raster (Backdrop + Halfmoon)
#        |
#        v
#   Bright   192x108  extract white cores          bloom_bright
#        |
#        +--> BlurH_A 192x108 --\
#        |                       -> BlurV_A 192x108  (narrow halo)
#        |
#        +--> BlurH_W  96x54  --\
#        |                       -> BlurV_W  96x54   (wide skirt)
#        |
#        +--> Streak   192x108  horizontal-only pull  bloom_streak
#
#   Combine  192x108  narrow + wide + streak -> one bloom texture
#        |
#        v
#   Tube (TextureRect, CRT material)  samples Screen + Combine, upscaled by
#                                     an integer factor and letterboxed.
#
# Why so many tiny passes: the reference look needs a hot core, a wide soft
# skirt AND a horizontal anamorphic bar. Those are three radii at three scales.
# As separate 192x108 / 96x54 passes each one is nearly free, and each stays
# independently tunable. Nested loops at 384x216 would cost far more for a worse
# result. Bloom never touches the game's draw path 闁?it only re-reads Screen.
extends Control

const LOGICAL := Vector2i(384, 216)
const HALF := Vector2i(192, 108)
const QUARTER := Vector2i(96, 54)
const BEZEL := Color(0.045, 0.045, 0.043)

var screen: SubViewport
var game: Node2D
var tube: TextureRect
var mat: ShaderMaterial
var scale_now := 3
@export var front_enabled := false
var front: Node2D
var front_view: SubViewport
var front_tube: TextureRect
var front_mat: ShaderMaterial
var launch_active := false
var launch_age := 0.0
var launch_switched := false
var launch_black: ColorRect
const LAUNCH_SWITCH := 1.12
const LAUNCH_DURATION := 1.92

var bright: SubViewport
var narrow_h: SubViewport
var narrow_v: SubViewport
var wide_h: SubViewport
var wide_v: SubViewport
var streak: SubViewport
var combine: SubViewport

var m_bright: ShaderMaterial
var m_combine: ShaderMaterial
var tone_dark := Color(0.129, 0.129, 0.118)
var tone_light := Color(0.925, 0.910, 0.851)
var tone_loop := -1
var transition_age := 1.0
const TRANSITION_TIME := 0.72

const LOOP_PALETTES := [
	[Color(0.129, 0.129, 0.118), Color(0.925, 0.910, 0.851)], # paper
	[Color(0.145, 0.205, 0.198), Color(0.852, 0.884, 0.832)], # sage
	[Color(0.230, 0.174, 0.190), Color(0.900, 0.824, 0.808)], # dusk rose
	[Color(0.215, 0.222, 0.145), Color(0.906, 0.866, 0.738)], # ochre
	[Color(0.150, 0.190, 0.225), Color(0.826, 0.866, 0.878)], # blue grey
]


func _ready() -> void:
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/crt.gdshader")
	mat.set_shader_parameter("src_size", Vector2(LOGICAL))

	# ---- game raster -------------------------------------------------------
	screen = SubViewport.new()
	screen.name = "Screen"
	screen.size = LOGICAL
	screen.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	screen.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	screen.handle_input_locally = false
	screen.transparent_bg = false
	add_child(screen)

	var backdrop := Node2D.new()
	backdrop.name = "Backdrop"
	backdrop.set_script(load("res://scripts/backdrop.gd"))
	screen.add_child(backdrop)

	game = Node2D.new()
	game.name = "Halfmoon"
	game.set_script(load("res://scripts/game.gd"))
	screen.add_child(game)
	game.stage_changed.connect(_begin_transition)

	# ---- bloom chain -------------------------------------------------------
	# Soft luminance extraction: no threshold, no ring. See bloom_bright.gdshader
	# for why a hard gate makes the glow look pasted on.
	bright = _pass("BloomBright", HALF, "res://shaders/bloom_bright.gdshader",
		screen.get_texture(), {"floor_lum": 0.915, "power": 1.6, "gain": 7.0})
	m_bright = _last_mat_of(bright)
	if OS.get_environment("HALFMOON_BLOOMRED") != "":
		m_bright.set_shader_parameter("dbg", 1.0)

	# Narrow tier: the hot core. Tight radius, high weight 鈥?this is the light
	# that sits ON the object.
	narrow_h = _pass("BloomNarrowH", HALF, "res://shaders/bloom_blur.gdshader",
		bright.get_texture(), {"axis": 0.0, "radius": 1.8})
	narrow_v = _pass("BloomNarrowV", HALF, "res://shaders/bloom_blur.gdshader",
		narrow_h.get_texture(), {"axis": 1.0, "radius": 1.8})

	# Mid tier: the visible skirt, at quarter res so a modest radius already
	# spans a long distance in source pixels.
	wide_h = _pass("BloomWideH", QUARTER, "res://shaders/bloom_blur.gdshader",
		bright.get_texture(), {"axis": 0.0, "radius": 2.4})
	wide_v = _pass("BloomWideV", QUARTER, "res://shaders/bloom_blur.gdshader",
		wide_h.get_texture(), {"axis": 1.0, "radius": 2.4})

	# Far tier: a second, much wider cascade. This is the difference between
	# "halo attached to the bullet" and "the field is lit". Two blur passes of a
	# quarter-res buffer reach ~30 source pixels, which is where a glow stops
	# being a ring and starts being light.
	var far_h := _pass("BloomFarH", QUARTER, "res://shaders/bloom_blur.gdshader",
		wide_v.get_texture(), {"axis": 0.0, "radius": 4.0})
	var far_v := _pass("BloomFarV", QUARTER, "res://shaders/bloom_blur.gdshader",
		far_h.get_texture(), {"axis": 1.0, "radius": 4.0})

	streak = _pass("BloomStreak", HALF, "res://shaders/bloom_streak.gdshader",
		wide_v.get_texture(), {"stretch": 26.0, "falloff": 1.5})

	combine = _pass("BloomCombine", HALF, "res://shaders/bloom_combine.gdshader",
		narrow_v.get_texture(),
		{"w_narrow": 1.00, "w_wide": 1.30, "w_far": 1.60, "w_streak": 1.20})
	m_combine = _last_mat_of(combine)
	m_combine.set_shader_parameter("tex_narrow", narrow_v.get_texture())
	m_combine.set_shader_parameter("tex_wide", wide_v.get_texture())
	m_combine.set_shader_parameter("tex_far", far_v.get_texture())
	m_combine.set_shader_parameter("tex_streak", streak.get_texture())

	# ---- composite ---------------------------------------------------------
	var plate := ColorRect.new()
	plate.name = "Plate"
	plate.color = BEZEL
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(plate)
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE)

	tube = TextureRect.new()
	tube.name = "Tube"
	tube.texture = screen.get_texture()
	tube.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tube.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tube.stretch_mode = TextureRect.STRETCH_SCALE
	tube.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tube.material = mat
	add_child(tube)

	# TEXTURE is unavailable in canvas_item shaders on 4.7; every input is bound
	# explicitly. The CRT pass reads the game raster plus one combined bloom.
	mat.set_shader_parameter("src_tex", screen.get_texture())
	# Same raster, second sampler: linear filtering is what lets the chromatic
	# aberration displacement land between texels. See crt.gdshader.
	mat.set_shader_parameter("src_lin", screen.get_texture())
	mat.set_shader_parameter("bloom_tex", combine.get_texture())

	resized.connect(_refit)
	_refit()

	if OS.get_environment("HALFMOON_PERF") != "":
		var probe := Node.new()
		probe.name = "PerfProbe"
		probe.set_script(load("res://scripts/perf_probe.gd"))
		add_child(probe)
	if OS.get_environment("HALFMOON_BLOOMDEBUG") != "":
		var dbg := Node.new()
		dbg.name = "BloomDebug"
		dbg.set_script(load("res://scripts/bloom_debug.gd"))
		add_child(dbg)
	if OS.get_environment("HALFMOON_DUMP") != "":
		var dump := Node.new()
		dump.name = "PassDump"
		dump.set_script(load("res://scripts/pass_dump.gd"))
		add_child(dump)
	if OS.get_environment("HALFMOON_HILITE") != "":
		var hi := Node2D.new()
		hi.name = "HiliteProbe"
		hi.set_script(load("res://scripts/hilite_probe.gd"))
		screen.add_child(hi)
	if OS.get_environment("HALFMOON_PATH") != "":
		var pp := Node.new()
		pp.name = "PathProbe"
		pp.set_script(load("res://scripts/path_probe.gd"))
		add_child(pp)

	set_process(true)
	if front_enabled:
		_build_front()


func _build_front() -> void:
	game.front_managed = true
	front_view = SubViewport.new()
	front_view.name = "FrontScreen"
	front_view.size = Vector2i(768, 432)
	front_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	front_view.handle_input_locally = false
	add_child(front_view)
	front = Node2D.new()
	front.set_script(load("res://scripts/front_menu.gd"))
	front.preview_source = game
	front_view.add_child(front)
	front.start_requested.connect(_start_flight)
	front.title_requested.connect(_show_title)
	front.exit_requested.connect(_exit_game)
	front_mat = mat.duplicate()
	front_mat.set_shader_parameter("unified_noise", 0.15)
	front_mat.set_shader_parameter("grain", 0.12)
	front_mat.set_shader_parameter("grain_rate", 18.0)
	front_mat.set_shader_parameter("src_size", Vector2(768, 432))
	front_mat.set_shader_parameter("src_tex", front_view.get_texture())
	front_mat.set_shader_parameter("src_lin", front_view.get_texture())
	var black := Image.create(1, 1, false, Image.FORMAT_RGB8)
	black.fill(Color.BLACK)
	front_mat.set_shader_parameter("bloom_tex", ImageTexture.create_from_image(black))
	front_mat.set_shader_parameter("transition_glitch", 0.0)
	front_mat.set_shader_parameter("palette_dark", LOOP_PALETTES[0][0])
	front_mat.set_shader_parameter("palette_light", LOOP_PALETTES[0][1])
	front_tube = TextureRect.new()
	front_tube.name = "FrontTube"
	front_tube.texture = front_view.get_texture()
	front_tube.material = front_mat
	front_tube.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	front_tube.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(front_tube)
	launch_black = ColorRect.new()
	launch_black.color = Color(0, 0, 0, 0)
	launch_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(launch_black)
	launch_black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	launch_black.hide()
	_refit()
	_show_title()


func _exit_game() -> void:
	get_tree().quit()


func _show_title() -> void:
	launch_active = false
	launch_age = 0.0
	launch_switched = false
	launch_black.hide()
	game.set_process(false)
	game.paused = true
	game.fire_buffer = 0.0
	front.show_title()
	front_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	front_tube.show()


func _start_flight() -> void:
	if launch_active:
		return
	launch_active = true
	launch_age = 0.0
	launch_switched = false
	game.fire_buffer = 0.0
	front.begin_departure()
	launch_black.color.a = 0.0
	launch_black.show()


func _advance_launch(dt: float) -> void:
	launch_age += clampf(dt, 0.0, 0.05)
	if not launch_switched:
		front.advance(dt)
		var darkness := smoothstep(0.68, 1.04, launch_age)
		launch_black.color.a = darkness
		if launch_age >= LAUNCH_SWITCH:
			launch_switched = true
			game.reset()
			game.paused = false
			game.set_process(false)
			game.queue_redraw()
			front.hide()
			front_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
			front_tube.hide()
			tone_loop = 1
			tone_dark = LOOP_PALETTES[0][0]
			tone_light = LOOP_PALETTES[0][1]
			mat.set_shader_parameter("palette_dark", tone_dark)
			mat.set_shader_parameter("palette_light", tone_light)
			mat.set_shader_parameter("transition_glitch", 0.0)
			transition_age = TRANSITION_TIME
	else:
		launch_black.color.a = 1.0 - smoothstep(1.20, LAUNCH_DURATION, launch_age)
	if launch_age >= LAUNCH_DURATION:
		launch_active = false
		launch_black.hide()
		game.esc_held = Input.is_key_pressed(KEY_ESCAPE)
		q_down = Input.is_key_pressed(KEY_Q)
		e_down = Input.is_key_pressed(KEY_E)
		game.set_process(true)


func _front_pointer(position_in_window: Vector2) -> Vector2:
	var uv := (position_in_window - front_tube.position) / front_tube.size
	# Match the CRT's screen bend so hover and click stay on the printed text.
	var centered := uv * 2.0 - Vector2.ONE
	var curvature: float = front_mat.get_shader_parameter("curvature")
	centered.x *= 1.0 + curvature * centered.y * centered.y
	centered.y *= 1.0 + curvature * centered.x * centered.x
	return (centered * 0.5 + Vector2(0.5, 0.5)) * Vector2(768, 432)


# Create one full-bleed shader pass. Returns the SubViewport; the material
# lands on its only child so _last_mat_of can find it.
func _pass(pname: String, size: Vector2i, shader_path: String, input: Texture2D, params: Dictionary) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = pname
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.handle_input_locally = false
	vp.transparent_bg = true
	add_child(vp)

	var holder := TextureRect.new()
	holder.name = "Pass"
	holder.texture = input
	holder.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	holder.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	holder.stretch_mode = TextureRect.STRETCH_SCALE
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var m := ShaderMaterial.new()
	m.shader = load(shader_path)
	# Feed the input through an explicit sampler, not TEXTURE.
	m.set_shader_parameter("src", input)
	for k in params:
		m.set_shader_parameter(k, params[k])
	holder.material = m

	vp.add_child(holder)
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE)
	return vp


func _last_mat_of(vp: SubViewport) -> ShaderMaterial:
	var child := vp.get_child(vp.get_child_count() - 1) as TextureRect
	return child.material as ShaderMaterial


# ---------------------------------------------------------------- layout

# Integer scaling is mandatory. A fractional upscale of a 1px raster squeezes
# the scanline pattern into moire 闁?that is what made the effects "disappear"
# in an earlier build. Pick the largest whole multiple that fits and letterbox.
func _refit() -> void:
	if tube == null:
		return
	var win := get_viewport_rect().size
	if win.x <= 0.0 or win.y <= 0.0:
		win = Vector2(1152.0, 648.0)

	var fit: float = minf(win.x / float(LOGICAL.x), win.y / float(LOGICAL.y))
	var s: float = floorf(fit)
	if s < 1.0:
		s = fit
	scale_now = int(s)

	var size: Vector2 = Vector2(LOGICAL) * s
	tube.size = size
	tube.position = Vector2(floorf((win.x - size.x) * 0.5), floorf((win.y - size.y) * 0.5))
	tube.pivot_offset = Vector2.ZERO

	mat.set_shader_parameter("upscale", s)
	mat.set_shader_parameter("bezel_thick", clamp(4.0 / max(1.0, s), 1.0, 4.0))
	if front_tube != null:
		front_tube.size = size
		front_tube.position = tube.position
		front_mat.set_shader_parameter("upscale", s * 0.5)


# ------------------------------------------------------- weapon switch input
#
# WHY THE WHEEL IS CAUGHT HERE AND NOT IN game.gd (silent-failure mode #14):
#
# The game node lives inside `Screen`, a SubViewport. `screen.handle_input_locally`
# is false (see _ready), so that SubViewport never translates events into local
# input for its children. A SubViewport only gets fed when something pushes
# events into it -- normally its SubViewportContainer parent. `Tube` is a plain
# TextureRect that merely samples `screen.get_texture()`, so nothing ever calls
# push_input on Screen. Consequence: any `_input` / `_unhandled_input` written in
# game.gd fires exactly zero times, forever, and the feature looks "not wired up"
# instead of looking broken.
#
# `Root` is a Control parented straight into the scene tree, so it is the one
# node in this project that receives full-window InputEvent traffic. Wheel and
# the Q/E fallback therefore live here and hand off to game.queue_wheel().
# Wheel up = -1 (previous tier), wheel down = +1 (next tier).

# Previous-frame state for the Q/E edge detectors. Polled level can not be used
# directly: `Input.is_key_pressed` stays true for every frame the key is held, so
# a level check would step one tier per frame and turn the weapon ring into a
# blur.
var q_down := false
var e_down := false


func _input(event: InputEvent) -> void:
	# _input can fire before _ready has built the game node, so never assume it.
	if game == null:
		return
	if launch_active:
		get_viewport().set_input_as_handled()
		return
	if front != null and front.visible:
		var front_key := event as InputEventKey
		if front_key != null and front_key.pressed and not front_key.echo:
			front.handle_key(front_key.keycode)
		var motion := event as InputEventMouseMotion
		if motion != null:
			front.pointer(_front_pointer(motion.position))
		var click := event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
			front.pointer(_front_pointer(click.position))
			if front.hovered >= 0:
				front.activate()
			else:
				front.interact(_front_pointer(click.position))
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_R:
		game.request_reload()
		return
	if key != null and key.pressed and not key.echo:
		if key.keycode in [KEY_X, KEY_Z, KEY_J] or (key.keycode == KEY_SPACE and game.gauge < 1.0):
			game.queue_fire()
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	# A wheel notch produces BOTH a pressed and a released event. Acting on the
	# release as well would fire twice per notch and step two tiers.
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		game.queue_fire()
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		game.queue_wheel(-1)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		game.queue_wheel(1)
	else:
		return
	# Stop the notch from also reaching anything downstream (pause menu, focus
	# handling) -- one notch must mean one request, not a chain of requests.
	get_viewport().set_input_as_handled()


# Keyboard fallback: Q = previous tier, E = next tier. Q/E are unused elsewhere
# in this project (move is arrows/WASD, Shift inks, X/Z/J/LMB fire, Space erases,
# ESC pauses, R restarts), so nothing else competes for them.
func _process(dt: float) -> void:
	if front != null:
		if launch_active:
			_advance_launch(dt)
			return
		if front.visible:
			front.advance(dt)
			return
		if game.dead and game.dead_t >= 0.85:
			game.set_process(false)
			front.show_result({"score": game.score, "kills": game.kill_count,
				"loop": game.loop_n, "time": game.run_elapsed})
			front_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			front_tube.show()
			return
	if game != null and mat != null:
		var current_loop := maxi(1, int(game.get("loop_n")))
		if current_loop != tone_loop:
			if tone_loop >= 0:
				_begin_transition()
			tone_loop = current_loop
		var target: Array = LOOP_PALETTES[(current_loop - 1) % LOOP_PALETTES.size()]
		var blend := 1.0 - exp(-dt * 1.7)
		tone_dark = tone_dark.lerp(target[0], blend)
		tone_light = tone_light.lerp(target[1], blend)
		mat.set_shader_parameter("palette_dark", tone_dark)
		mat.set_shader_parameter("palette_light", tone_light)
		if not bool(game.get("paused")):
			transition_age = minf(TRANSITION_TIME, transition_age + minf(dt, 0.05))
		var progress := clampf(transition_age / TRANSITION_TIME, 0.0, 1.0)
		var pulse := sin(progress * PI) * (1.0 - progress * 0.6)
		mat.set_shader_parameter("transition_glitch", maxf(0.0, pulse))
		mat.set_shader_parameter("transition_phase", progress)

	if game == null:
		q_down = false
		e_down = false
		return

	# Compare against last frame and fire on the false -> true transition only.
	# The "previous" flags are updated unconditionally, even while paused or
	# while game is null: otherwise a key held through a pause would look like a
	# fresh press the moment the frame after resume runs, i.e. a phantom switch.
	var q_now := Input.is_key_pressed(KEY_Q)
	var e_now := Input.is_key_pressed(KEY_E)

	if q_now and not q_down:
		game.queue_wheel(-1)
	if e_now and not e_down:
		game.queue_wheel(1)

	q_down = q_now
	e_down = e_now


func _begin_transition() -> void:
	transition_age = 0.0
