extends SceneTree

const Game = preload("res://scripts/game.gd")
const Specials = preload("res://scripts/special_enemies.gd")
var checked := 0
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		if failures <= 12:
			push_error(message)


func _motion(dt: float, kind: int) -> void:
	var f := Specials.create(kind, 74.0, 3)
	var early_speed := 0.0
	var late_speed := 0.0
	var previous_deployment := Specials.deployment(f)
	for frame in int(3.0 / dt):
		var previous: Vector2 = f.p
		f.p = Specials.step(f, Vector2(52, 116), dt)
		var position: Vector2 = f.p
		var speed := (previous.x - position.x) / dt
		if float(f.age) < 0.2:
			early_speed = speed
		if float(f.age) > 1.0:
			late_speed = speed
		_check(position.x <= previous.x and position.x >= Specials.DOCK_X, "Entrance reversed or overshot dock")
		_check(position.distance_to(previous) <= 110.0 * dt, "Entrance teleported")
		_check(Specials.deployment(f) + 0.0001 >= previous_deployment, "Parts folded while entering")
		previous_deployment = Specials.deployment(f)
		_check(not Specials.hits(f, position, previous), "Arrival caused damage")
		if int(f.state) != Specials.State.ENTER:
			break
	_check(early_speed > late_speed * 1.8, "Entrance failed to brake")
	_check((f.p as Vector2).is_equal_approx(Vector2(Specials.DOCK_X, 74)), "Dock pose drifted")
	_check(is_equal_approx(Specials.deployment(f), 1.0), "Docked parts not fully deployed")
	var entry_time := Specials.DRONE_ENTRY_TIME if kind == Specials.Kind.DRONE else Specials.TURRET_ENTRY_TIME
	_check(float(f.age) + 0.0001 >= entry_time and float(f.age) <= entry_time + dt + 0.0001, "Entry duration changed with frame rate")
	var start: Vector2 = f.p
	var original_direction: Vector2 = f.dir
	Specials.cancel(f, true)
	_check((f.p as Vector2).is_equal_approx(start), "Retreat start teleported")
	early_speed = 0.0
	late_speed = 0.0
	for frame in int(2.0 / dt):
		var previous: Vector2 = f.p
		# Repeated cleanup requests must not restart the departure animation.
		Specials.cancel(f, true)
		f.p = Specials.step(f, Vector2(52, 116), dt)
		var position: Vector2 = f.p
		var speed := (position.x - previous.x) / dt
		if frame == 0:
			early_speed = speed
		if float(f.state_age) > 0.65:
			late_speed = speed
		_check(position.x > previous.x and speed <= 159.1, "Retreat reversed or jumped")
		_check(not Specials.hits(f, position, previous), "Retreat retained attack")
		_check((f.dir as Vector2).is_equal_approx(original_direction), "Visual turn changed attack direction")
		if float(f.state_age) >= 0.81:
			_check(Specials.deployment(f) <= 0.23, "Retreat parts failed to retract")
			_check(Specials.facing(f).dot(Vector2.RIGHT) > 0.99, "Retreat nose did not turn right")
		if bool(f.expired):
			break
	_check(bool(f.expired) and float(f.p.x) > 390.0, "Departure failed to finish outside frame")
	_check(late_speed > early_speed * 2.0, "Departure failed to accelerate")


func _run() -> void:
	for dt in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0, 0.05]:
		for kind in [Specials.Kind.DRONE, Specials.Kind.TURRET]:
			_motion(dt, kind)
	var game := Game.new()
	for kind in [Specials.Kind.DRONE, Specials.Kind.TURRET]:
		for source in ["bullet", "thorn", "barrage", "erase"]:
			game.reset()
			game.invuln = 0.0
			var f := Specials.create(kind, 108, 3)
			f.p = Vector2(80, 108)
			f.hp = 1
			f.state = Specials.State.ATTACK
			f.timer = 0.2
			game.foes.append(f)
			match source:
				"bullet":
					game.pb.append({"p": Vector2(80, 108), "v": Vector2.RIGHT * 500, "dmg": 99})
					game.step_foes(0.016)
				"thorn":
					game.trigger_thorn(game.player)
				"barrage":
					game.trigger_barrage()
				"erase":
					game.do_erase()
			_check(game.foes.is_empty() and game.special_remnants.size() == 1, "Missing destroyed structure for %s" % source)
			_check(not game.special_remnants[0].has("hp") and not game.special_remnants[0].has("state"), "Remnant retained gameplay state")
			game._special_departure(f)
			_check(game.special_remnants.size() == 1, "Removal spawned duplicate remnants")
			var rem: Dictionary = game.special_remnants[0]
			game.paused = true
			game._process(0.05)
			_check(float(rem.age) == 0.0, "Pause advanced remnants")
			game.paused = false
			game.step_sparks(0.5)
			_check(game.special_remnants.is_empty(), "Remnant survived past expiry")
	game.reset()
	var exhausted := Specials.create(Specials.Kind.DRONE, 108, 3)
	exhausted.p = Vector2(180, 108)
	exhausted.state = Specials.State.ATTACK
	exhausted.timer = 0.001
	game.foes.append(exhausted)
	game.step_foes(0.016)
	_check(game.foes.is_empty() and game.special_remnants.size() == 1, "Exhausted drone popped without breakup")
	_check(not game.special_remnants[0].violent and game.hull == Game.HULL_MAX and game.score == 0, "Natural breakup caused damage or rewards")
	for i in 16:
		game._special_departure(Specials.create(Specials.Kind.TURRET, 108, 3))
	_check(game.special_remnants.size() == 8, "Remnant pool exceeded bound")
	game.reset()
	_check(game.special_remnants.is_empty(), "Restart retained remnants")
	game.free()
	print("SPECIAL_ANIMATION_CHECK assertions=%d failures=%d" % [checked, failures])
	quit(0 if failures == 0 else 1)
