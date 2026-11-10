extends SceneTree

const Game = preload("res://scripts/game.gd")
const Specials = preload("res://scripts/special_enemies.gd")
const Waves = preload("res://scripts/waves.gd")
var checked := 0
var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		if failures <= 15:
			push_error(message)


func _attack(kind: int, p: Vector2 = Vector2(314, 108)) -> Dictionary:
	var f := Specials.create(kind, p.y, 3)
	f.p = p
	f.state = Specials.State.ATTACK
	f.timer = 0.24 if kind == Specials.Kind.TURRET else 1.25
	f.dir = Vector2.LEFT
	return f


func _timing(dt: float, kind: int) -> void:
	var f := Specials.create(kind, 108.0, 3)
	f.p = Vector2(314, 108)
	var warning_age := 0.0
	var locked := false
	var locked_direction := Vector2.ZERO
	var attacked := false
	var aim_started := false
	for frame in int(8.0 / dt):
		var previous: Vector2 = f.p
		var state := int(f.state)
		var lock_window := 0.30 if kind == Specials.Kind.DRONE else 0.40
		if state == Specials.State.AIM:
			aim_started = true
			warning_age += dt
			if float(f.timer) <= lock_window and not locked:
				locked = true
				locked_direction = f.dir
		var player := Vector2(52, 170) if locked else Vector2(52, 108)
		f.p = Specials.step(f, player, dt)
		if locked and (int(f.state) == Specials.State.AIM or int(f.state) == Specials.State.ATTACK):
			_check((f.dir as Vector2).is_equal_approx(locked_direction), "Special turned after lock")
		if int(f.state) != Specials.State.ATTACK:
			_check(not Specials.hits(f, f.p, previous), "Warning/cooldown caused damage")
		else:
			var minimum := Specials.DRONE_WARNING if kind == Specials.Kind.DRONE else Specials.TURRET_WARNING
			_check(warning_age + 0.0001 >= minimum, "Warning was shorter than promised")
			if kind == Specials.Kind.TURRET:
				_check(not Specials.hits(f, player, previous), "Locked beam followed moved player")
				_check(Specials.hits(f, Vector2(52, 108), previous), "Positive beam hit control failed")
			attacked = true
			if float(f.timer) < (1.10 if kind == Specials.Kind.DRONE else 0.10):
				break
	_check(aim_started and locked and attacked, "Special never completed warning/attack")


func _run() -> void:
	for dt in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0, 0.05]:
		for kind in [Specials.Kind.DRONE, Specials.Kind.TURRET]:
			_timing(dt, kind)
			var f := Specials.create(kind, 108.0, 3)
			f.p = Vector2(314, 108)
			f.state = Specials.State.AIM
			f.timer = Specials.DRONE_WARNING if kind == Specials.Kind.DRONE else Specials.TURRET_WARNING
			var elapsed := 0.0
			var last_change := 0.0
			for frame in int(2.0 / dt):
				var before: Vector2 = f.dir
				f.p = Specials.step(f, Vector2(52, 40 if frame % 2 == 0 else 180), dt)
				elapsed += dt
				if not (f.dir as Vector2).is_equal_approx(before):
					last_change = elapsed
				if int(f.state) == Specials.State.ATTACK:
					break
			var minimum := 0.30 if kind == Specials.Kind.DRONE else 0.40
			_check(elapsed - last_change + 0.0001 >= minimum, "Frame rounding shortened lock window")
	for i in 32:
		var f := _attack(Specials.Kind.TURRET)
		f.dir = Vector2.RIGHT.rotated(TAU * float(i) / 32.0)
		var ray := Specials.beam(f)
		_check(Specials.BOUNDS.grow(0.01).has_point(ray[0]) and Specials.BOUNDS.grow(0.01).has_point(ray[1]), "Beam escaped frame")
		var midpoint := (ray[0] + ray[1]) * 0.5
		_check(Specials.hits(f, midpoint, f.p), "Beam hit geometry missed center")
		_check(not Specials.hits(f, midpoint + (f.dir as Vector2).orthogonal() * 5, f.p), "Beam exceeded collision width")
	var game := Game.new()
	for kind in [Specials.Kind.DRONE, Specials.Kind.TURRET]:
		game.reset()
		game.invuln = 0.0
		game.item_shield = 2
		game.player = Vector2(52, 108)
		var f := _attack(kind, Vector2(58, 108) if kind == Specials.Kind.DRONE else Vector2(314, 108))
		game.foes.append(f)
		game.step_foes(1.0 / 60.0)
		_check(game.item_shield == 1 and game.hull == Game.HULL_MAX, "Attack must consume one shield")
		game.invuln = 0.0
		game.step_foes(1.0 / 60.0)
		_check(game.item_shield == 1, "Same attack consumed shield twice")
		game.reset()
		game.foes.append(_attack(kind, Vector2(58, 108) if kind == Specials.Kind.DRONE else Vector2(314, 108)))
		game.invuln = 1.0
		game.step_foes(1.0 / 60.0)
		_check(game.hull == Game.HULL_MAX, "Special bypassed invulnerability")
		game.reset()
		game.invuln = 0.0
		game.foes.append(_attack(kind))
		game.pb.append({"p": Vector2(314, 108), "v": Vector2.RIGHT * 500, "dmg": 99})
		game.step_foes(1.0 / 60.0)
		_check(game.foes.is_empty() and game.hull == Game.HULL_MAX, "Killed emitter retained its attack")
		for major in ["start_boss", "start_elite", "start_rival"]:
			game.reset()
			var emitter := _attack(kind)
			game.foes.append(emitter)
			game.call(major)
			if major == "start_rival":
				_check(game.foes.is_empty(), "Big boss retained a special emitter")
			else:
				_check(int(emitter.state) == Specials.State.LEAVE, "Minor encounter retained a special attack")
		game.reset()
		var erased := _attack(kind)
		erased.hp = 999
		game.foes.append(erased)
		game.do_erase()
		_check(int(erased.state) != Specials.State.ATTACK and int(erased.state) != Specials.State.AIM, "ERASE retained attack")
		if kind == Specials.Kind.TURRET:
			_check(float(erased.timer) >= 3.4, "ERASE failed to restore full cooldown")
		game.reset()
		game.invuln = 0.0
		game.hull = 1
		var lethal := _attack(kind, Vector2(58, 108) if kind == Specials.Kind.DRONE else Vector2(314, 108))
		game.foes.append(lethal)
		game.step_foes(1.0 / 60.0)
		_check(game.dead, "Lethal attack failed")
		for survivor in game.foes:
			_check(int(survivor.state) == Specials.State.LEAVE, "Death retained active emitter")
		game.reset()
		_check(game.foes.is_empty() and not game.drone_introduced and not game.turret_introduced, "Restart leaked specials")
	# Retaliation mutates the same foe array being stepped.
	game.reset()
	game.invuln = 0
	game.item_thorn = true
	game.foes.append(_attack(Specials.Kind.DRONE, Vector2(60, 108)))
	game.foes.append(_attack(Specials.Kind.DRONE, Vector2(58, 108)))
	game.step_foes(0.016)
	_check(game.hull == 2 and game.foes.is_empty(), "Thorn caused extra damage or retained drone")
	for seed_value in 32:
		for loop_n in [1, 2, 3, 8]:
			game.reset()
			game.rng.seed = seed_value
			game.loop_n = loop_n
			game.drone_introduced = loop_n >= 3
			game.special_next_at = 0
			var special_seen := false
			for age in range(0, 41):
				game.foes.clear()
				game.wave_pending.clear()
				game.wave_clock = float(age)
				game.t = float(age) + (0.0 if loop_n == 1 else 12.0)
				game.spawn_wave()
				var cost := 0
				var specials := 0
				for member in game.wave_pending:
					cost += Waves.COST[int(member.kind)]
					if int(member.kind) >= Specials.Kind.DRONE:
						specials += 1
						special_seen = true
						_check(loop_n >= 2 and game.t <= Game.BOSS_AT - 6.0, "Special introduced in forbidden window")
						_check(age >= (20 if int(member.kind) == Specials.Kind.DRONE and loop_n == 2 else 18), "Special introduced too early")
				_check(specials <= 1 and game.wave_pending.size() <= 3, "Special wave exceeded unit cap")
				_check(cost <= int(Waves.profile(loop_n, float(age)).budget), "Special wave exceeded budget")
			_check(special_seen == (loop_n >= 2), "Scheduled introduction missing")
	# Active and queued special threats share the same reservation.
	game.reset()
	game.loop_n = 3
	game.wave_clock = 24
	game.t = 36
	game.foes.append(_attack(Specials.Kind.DRONE))
	game.spawn_wave()
	for member in game.wave_pending:
		_check(int(member.kind) < 3, "Overlapped special threats")
	game.reset()
	game.loop_n = 3
	game.drone_introduced = true
	game.special_intro_waves = 2
	game.wave_clock = 24
	game.t = 36
	for i in 2:
		game.wave_pending.clear()
		game.spawn_wave()
		for member in game.wave_pending:
			_check(int(member.kind) == 0, "Introduction's following waves must be shard-only")
	game.wave_pending.clear()
	game.spawn_wave()
	_check(game.wave_pending[0].kind == Specials.Kind.TURRET, "Turret must follow completed introduction")
	game.free()
	print("SPECIAL_CHECK assertions=%d failures=%d" % [checked, failures])
	quit(0 if failures == 0 else 1)
