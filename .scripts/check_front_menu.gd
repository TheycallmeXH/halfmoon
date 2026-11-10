extends "res://scripts/boot.gd"

var checked := 0
var failures := 0
var exits := 0


func capture_exit() -> void:
	exits += 1


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func key(code: Key, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.echo = echo
	_input(event)


func finish_launch() -> void:
	for i in 125:
		_process(1.0 / 60)


func _ready() -> void:
	front_enabled = true
	super._ready()
	# Fixture inputs are explicit; real pointer motion must not change captured states.
	set_process_input(false)
	if "--exit-check" in OS.get_cmdline_user_args():
		set_process(false)
		tree_exiting.connect(func(): print("FRONT_EXIT tree_exiting"))
		await RenderingServer.frame_post_draw
		front.age = 1.0
		front.pointer(front.SECONDARY.get_center())
		front.activate()
		return
	front.exit_requested.disconnect(_exit_game)
	front.exit_requested.connect(capture_exit)
	set_process(false)
	check(front.visible and not game.is_processing(), "Title did not freeze combat")
	var old_t: float = game.t
	for i in 30:
		_process(1.0 / 60)
	check(game.t == old_t, "Menu advanced combat clock")
	await RenderingServer.frame_post_draw
	front_view.get_texture().get_image().save_png("res://.shots/title-native.png")
	get_viewport().get_texture().get_image().save_png("res://.shots/title-crt.png")
	var title: Image = front_view.get_texture().get_image()
	var ink_pixels := 0
	for y in range(116, 390):
		for x in range(430, 665):
			if title.get_pixel(x, y).get_luminance() < 0.4:
				ink_pixels += 1
	check(ink_pixels > 6500, "Portrait missing or blank")
	var portrait_image: Image = front.portrait.texture.get_image()
	check(portrait_image.get_size() == Vector2i(1632, 1536), "Pilot portrait not loaded")
	check(portrait_image.get_pixel(0, 600).a == 0.0, "Portrait exterior not removed")
	check(portrait_image.get_pixel(780, 470).a == 1.0, "Portrait face became transparent")
	check(portrait_image.get_pixel(1400, 180).a == 0.0, "Reference dialogue box remained")
	var portrait_bounds := Rect2(front.portrait.position -
		Vector2(portrait_image.get_size()) * front.portrait.scale * 0.5,
		Vector2(portrait_image.get_size()) * front.portrait.scale)
	check(portrait_bounds.position.x - 5 >= 384 and portrait_bounds.end.x + 5 < 732
		and portrait_bounds.position.y - 3 > 120 and portrait_bounds.end.y + 3 < 414,
		"Pilot portrait escaped the right half or covered title")
	check(front.font.get_font_name().to_upper().contains("SPACE"), "BM SPACE not loaded")
	check(front.font.resource_path != "" or front.font.get_font_name() != "",
		"Font missing")
	check(ProjectSettings.get_setting("application/config/name") == "Katuria's SEISHIN ATTACK"
		and front.GAME_TITLE == "SEISHIN ATTACK", "Game branding is inconsistent")
	check(front.AUTHOR_LOGO.get_width() > 0, "Author logo failed to load")
	check(front.preview_source == game, "Cover craft does not use player geometry source")
	check(float(front_mat.get_shader_parameter("unified_noise")) > 0.0
		and float(front_mat.get_shader_parameter("unified_noise")) <= 0.04,
		"Unified retro noise is missing or too strong")
	check(title.get_pixel(50, 200) == title.get_pixel(51, 200),
		"Paper fibers or protected paper regions remain")
	var idle: Image = front_view.get_texture().get_image()
	front.pointer(front.PRIMARY.get_center())
	front.advance(0.05)
	await RenderingServer.frame_post_draw
	var active: Image = front_view.get_texture().get_image()
	var changed := 0
	var escaped := 0
	for y in 432:
		for x in 768:
			if idle.get_pixel(x, y) != active.get_pixel(x, y):
				changed += 1
				if y < 120:
					escaped += 1
	check(changed > 500, "Hover has no reverse-video response")
	check(escaped == 0, "Hover corrupted title typography")
	get_viewport().get_texture().get_image().save_png("res://.shots/title-hover-crt.png")
	front.pointer(front.PRIMARY.get_center())
	front.advance(0.05)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(active.get_region(Rect2i(front.PRIMARY)).get_data() !=
		front_view.get_texture().get_image().get_region(Rect2i(front.PRIMARY)).get_data(),
		"Hover scanline is static")
	front.pointer(Vector2.ZERO)
	check(font_has_menu_labels(), "Menu labels unavailable")
	# Compare the portrait at clean and broken signal phases with UI time frozen.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var clean: Image = front_view.get_texture().get_image()
	front.portrait_mat.set_shader_parameter("clock", 1.25)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var glitched: Image = front_view.get_texture().get_image()
	var glitch_pixels := 0
	var outside := 0
	var portrait_rect: Rect2 = front.PORTRAIT_AREA.grow(3)
	for y in 432:
		for x in 768:
			if clean.get_pixel(x, y) != glitched.get_pixel(x, y):
				glitch_pixels += 1
				if not portrait_rect.has_point(Vector2(x, y)):
					outside += 1
	check(glitch_pixels > 200, "Portrait glitch is invisible")
	check(outside == 0, "Portrait glitch changed menu text")
	get_viewport().get_texture().get_image().save_png("res://.shots/title-glitch-crt.png")
	front.portrait_mat.set_shader_parameter("clock", 2.0)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(clean.get_data() == front_view.get_texture().get_image().get_data(),
		"Portrait did not recover after glitch")
	front.pointer(Vector2(610, 210))
	for i in 20:
		front.advance(0.016)
	check(front.portrait.position.x > front.PORTRAIT_HOME.x
		and front.portrait.position.x < front.PORTRAIT_HOME.x + 6,
		"Portrait parallax missing or excessive")
	check(front.portrait_hover > 0.8, "Portrait hover scanner did not engage")
	check(front.ship_pos.x > 198 and front.ship_pos.x < 245, "Preview ship did not follow pointer")
	front.interact(Vector2(610, 210))
	check(front.signal_kick == 1.0 and front.pulses.size() == 1,
		"Portrait click did not trigger signal burst")
	front.interact(Vector2(610, 210))
	check(front.pulses.size() == 1, "Signal clicks lack rate limit")
	front.advance(0.016)
	check(float(front.portrait_mat.get_shader_parameter("impact")) > 0.9,
		"Portrait click did not reach shader")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.shots/title-interactive-crt.png")
	for i in 60:
		front.advance(0.016)
	check(front.pulses.is_empty() and front.signal_kick == 0.0, "Click effect did not expire")
	front.interact(Vector2(-50, 200))
	check(front.pulses.is_empty(), "Letterbox click triggered signal wave")
	front.show_title()
	check(front.parallax == Vector2.ZERO and front.portrait_hover == 0.0,
		"New menu retained pointer state")
	front.age = 0.5
	front.interact(Vector2(150, 160))
	check(front.pulses.size() == 1 and front.signal_kick == 0.0,
		"Background signal wave missing or corrupted portrait")
	var max_pulses := 0
	for i in 100:
		front.advance(0.016)
		front.interact(Vector2(150, 160))
		max_pulses = maxi(max_pulses, front.pulses.size())
	check(max_pulses <= 6, "Unbounded signal wave accumulation")
	front.show_title()
	front.age = 1.0
	key(KEY_UP)
	check(front.selected == 1, "Title navigation did not wrap to EXIT")
	key(KEY_ENTER)
	check(exits == 1 and front.visible, "Title keyboard EXIT failed")
	key(KEY_DOWN)
	check(front.selected == 0, "Title navigation did not wrap to START")
	front.pointer(front.SECONDARY.get_center())
	check(front.hovered == 1, "Title EXIT mouse target missing")
	front.activate()
	check(exits == 2 and front.visible, "Title mouse EXIT failed")
	front.pointer(Vector2.ZERO)
	key(KEY_DOWN)
	check(front.selected == 0, "Title navigation failed after hover")
	key(KEY_R, true)
	check(front.visible, "Echo started flight")
	key(KEY_ENTER)
	check(front.visible and launch_active and front.departing, "Start did not begin departure")
	check(game.fire_buffer == 0 and game.pb.is_empty(), "Start queued weapon fire")
	var departure_start: Vector2 = front.ship_pos
	key(KEY_ENTER)
	key(KEY_ESCAPE)
	check(launch_age == 0.0 and launch_active, "Repeated input restarted or cancelled departure")
	var held_confirm := InputEventKey.new()
	held_confirm.keycode = KEY_ENTER
	held_confirm.pressed = true
	Input.parse_input_event(held_confirm)
	for i in 42:
		_process(1.0 / 60)
	check(front.ship_pos.x > departure_start.x + 200 and not game.is_processing(),
		"Ship failed to fly out before gameplay")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.shots/launch-departure.png")
	for i in 24:
		_process(1.0 / 60)
	check(launch_black.color.a > 0.99 and front.visible,
		"Departure did not reach full black before switch")
	await RenderingServer.frame_post_draw
	var black_frame: Image = get_viewport().get_texture().get_image()
	check(black_frame.get_pixel(black_frame.get_width() / 2,
		black_frame.get_height() / 2).get_luminance() < 0.01, "Black transition is not black")
	get_viewport().get_texture().get_image().save_png("res://.shots/launch-black.png")
	for i in 20:
		_process(1.0 / 60)
	check(launch_switched and not front.visible and launch_black.color.a < 1.0
		and launch_black.color.a > 0.0 and not game.paused,
		"Gameplay fade-in missing or shows pause")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.shots/launch-fade-in.png")
	finish_launch()
	check(not launch_active and game.is_processing() and not game.paused
		and not launch_black.visible, "Flight failed to start automatically")
	check(Input.is_key_pressed(KEY_ENTER), "Held-confirm test did not hold the input")
	held_confirm.pressed = false
	Input.parse_input_event(held_confirm)
	game.set_process(false)
	game.run_elapsed = 125
	game.score = 164
	game.kill_count = 63
	game.loop_n = 4
	game.dead = true
	game.dead_t = 0.84
	_process(0.0)
	check(not front.visible, "Result skipped death animation")
	game.dead_t = 0.9
	_process(0.0)
	check(front.visible and front.mode == 1 and not game.is_processing(), "Death did not open result")
	check(front.stats.score == 164 and front.stats.kills == 63 and front.stats.loop == 4
		and front.stats.time == 125, "Result statistics changed")
	key(KEY_ENTER)
	check(front.visible, "Result accepted stale death-frame input")
	for i in 30:
		_process(1.0 / 60)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://.shots/result-crt.png")
	front_view.get_texture().get_image().save_png("res://.shots/result-native.png")
	key(KEY_UP)
	check(front.selected == 2, "Result navigation did not wrap to EXIT")
	key(KEY_ENTER)
	check(exits == 3 and front.visible, "Result EXIT failed")
	front.pointer(front.TERTIARY.get_center())
	check(front.hovered == 2, "Result EXIT mouse target missing")
	key(KEY_DOWN)
	key(KEY_DOWN)
	check(front.selected == 1, "Keyboard selection missing")
	key(KEY_ENTER)
	check(front.visible and front.mode == 0, "Return did not open title")
	front.age = 1.0
	# Empty paper must not start a flight; only the visible action is clickable.
	var event := InputEventMouseButton.new()
	event.pressed = true
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = front_tube.position + front_tube.size * Vector2(0.71, 0.45)
	_input(event)
	check(front.visible, "Click on illustration started flight")
	check(front.signal_kick == 1.0 and front.pulses.size() == 1,
		"Mouse input did not reach portrait interaction")
	event.position = front_tube.position + front_tube.size * Vector2(0.26, 0.62)
	_input(event)
	check(launch_active, "Mouse action did not start flight")
	finish_launch()
	game.set_process(false)
	check(game.score == 0 and game.kill_count == 0 and game.run_elapsed == 0
		and game.loop_n == 1 and not game.dead, "New flight retained result data")
	front.show_result({"score": 99999999, "kills": 999999, "loop": 100, "time": 5999})
	front_tube.show()
	front.age = 1
	front.selected = 2
	key(KEY_R)
	check(launch_active and front.visible and front.departing, "Retry failed")
	finish_launch()
	game.set_process(false)
	# The menu viewport tracks the same letterboxed 16:9 rectangle on resize.
	var initial_size := get_window().size
	for dimensions in [Vector2(768, 432), Vector2(1024, 768), Vector2(1280, 720)]:
		get_window().size = Vector2i(dimensions)
		await get_tree().process_frame
		_refit()
		check(front_tube.size == tube.size and front_tube.position == tube.position,
			"Menu resized away from CRT")
		check(front_tube.size.x <= dimensions.x and front_tube.size.y <= dimensions.y,
			"Menu clipped at resize")
	get_window().size = initial_size
	_show_title()
	print("FRONT_MENU checks=%d failures=%d portrait_ink=%d" % [checked, failures, ink_pixels])
	get_tree().quit(1 if failures else 0)


func font_has_menu_labels() -> bool:
	return front.font.has_char(65) and front.font.has_char(72)
