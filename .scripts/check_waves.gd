# Run: Godot --headless --path <project> --script res://.scripts/check_waves.gd
extends SceneTree

const Waves = preload("res://scripts/waves.gd")
const Game = preload("res://scripts/game.gd")

var failures := 0
var checked := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		if failures <= 10:
			push_error(message)


func _run() -> void:
	var rng := RandomNumberGenerator.new()
	var seen := {}
	var plans := 0
	for seed_value in 64:
		rng.seed = seed_value
		for loop_n in [1, 2, 3, 6, 20]:
			var last := -1
			for age in [0.0, 3.9, 6.0, 8.0, 12.0, 14.0, 18.0, 24.0, 26.0, 32.0, 34.0, 38.0, 42.0, 50.0]:
				var profile := Waves.profile(loop_n, age)
				var wave := Waves.plan(loop_n, age, rng, last, PackedInt32Array([0, 0, 0]), 12)
				plans += 1
				seen[wave.name] = true
				var cost := 0
				var shooters := 0
				var coils := 0
				_check(wave.members.size() >= 1 and wave.members.size() <= 3, "Wave size must stay within 1..3")
				_check(float(wave.interval) >= 1.25, "Cadence must respect reaction-time floor")
				for member in wave.members:
					cost += Waves.COST[int(member.kind)]
					shooters += int(int(member.kind) > 0)
					coils += int(int(member.kind) == 2)
					_check(float(member.y) - float(member.amp) >= 30.0 and float(member.y) + float(member.amp) <= 186.0, "Formation must remain inside vertical play area")
					_check(float(member.delay) >= 0.0 and float(member.delay) <= 0.8, "No long pending tail")
					_check(int(member.kind) != 1 or bool(profile.drift), "Drift unlocked too early")
					_check(int(member.kind) != 2 or bool(profile.coil), "Coil unlocked too early")
					if age < 4.0:
						_check(member.kind == 0 and wave.members.size() == 1, "Every loop needs a gentle opening")
				_check(cost <= int(profile.budget), "Wave exceeded threat budget")
				_check(shooters <= int(profile.shooter_cap) and coils <= int(profile.coil_cap), "Wave exceeded shooter limits")
				if wave.members.size() > 1:
					_check(int(wave.formation) != last, "Repeated multi-craft formation")
				last = int(wave.formation)
				var capped := Waves.plan(loop_n, age, rng, last, PackedInt32Array([4, 4, 2]), 0)
				_check(capped.members.is_empty(), "Full field must hold spawns")
				var one_slot := Waves.plan(loop_n, age, rng, last, PackedInt32Array([7, 3, 2]), 1)
				_check(one_slot.members.size() == 1, "Pending members must count toward field cap")
				for member in one_slot.members:
					_check(member.kind == 0, "Shooter saturation must fall back to a non-shooter")
	_check(seen.size() == Waves.NAMES.size(), "All formation types must be reachable")
	_check(float(Waves.profile(1, 15.0).interval) > float(Waves.profile(1, 13.0).interval), "Relief beat must slow arrivals")
	var game := Game.new()
	game.reset()
	# Exercise the real scheduler with no kills; parked coils must stay bounded.
	for loop_n in [1, 3, 20]:
		game.reset()
		game.loop_n = loop_n
		for frame in 3600:
			game.t = minf(game.t + 1.0 / 60.0, 51.9)
			game.invuln = 999.0
			game.step_spawn(1.0 / 60.0)
			game.step_foes(1.0 / 60.0)
			game.step_eb(1.0 / 60.0)
			_check(game.foes.size() + game.wave_pending.size() <= int(Waves.profile(loop_n, game.wave_clock).field_cap), "Integrated scheduler exceeded field cap")
			var shooters := 0
			var coils := 0
			for foe in game.foes:
				shooters += int(int(foe.kind) > 0)
				coils += int(int(foe.kind) == 2)
			for member in game.wave_pending:
				shooters += int(int(member.kind) > 0)
				coils += int(int(member.kind) == 2)
			var profile := Waves.profile(loop_n, game.wave_clock)
			_check(shooters <= int(profile.shooter_cap) and coils <= int(profile.coil_cap), "Integrated scheduler exceeded shooter limits")
	game.reset()
	game.t = 30.0
	game.step_elite_clock(0.016)
	_check(game.boss.is_empty(), "Elite must not appear in loop one")
	game.loop_n = 2
	game.step_elite_clock(0.016)
	_check(game.boss.has("is_elite"), "Elite must appear in loop two")
	game.boss = {}
	game._advance_loop()
	game.t = 30.0
	game.step_elite_clock(0.016)
	_check(game.boss.is_empty(), "Elite must skip loop three")
	game._advance_loop()
	game.t = 30.0
	game.step_elite_clock(0.016)
	_check(game.boss.has("is_elite"), "Elite must return in loop four")
	game.boss = {}
	game.wave_clock = 42.0
	game.spawn_wave()
	game.start_boss()
	game.step_spawn(0.016)
	_check(game.wave_pending.is_empty(), "Boss must cancel unfinished formations")
	var clock_before: float = game.wave_clock
	game.step_spawn(1.0)
	_check(game.wave_clock == clock_before, "Minor encounter entrance needs a spawn grace")
	game.boss.t = 3.0
	game.spawn_t = 0.0
	game.step_spawn(1.0)
	_check(game.wave_clock > clock_before and not game.wave_pending.is_empty(), "Small boss must allow ordinary escorts")
	game.start_rival()
	_check(game.foes.is_empty() and game.eb.is_empty() and game.wave_pending.is_empty(), "Big boss must own the field")
	clock_before = game.wave_clock
	game.step_spawn(1.0)
	game.spawn_wave()
	_check(game.wave_clock == clock_before and game.wave_pending.is_empty(), "Big boss must suspend normal waves")
	game._advance_loop()
	_check(game.t == 12.0 and game.wave_clock == 0.0, "Loop transition must restore forty seconds before boss")
	game.reset()
	_check(game.wave_pending.is_empty() and game.wave_last == -1 and game.wave_clock == 0.0 and game.elite_next_loop == 2, "Restart leaked encounter state")
	for loop_n in [1, 10, 100]:
		game.loop_n = loop_n
		game.foes.clear()
		game.foe_shard(100.0)
		game.foe_drift(100.0)
		game.foe_coil(100.0)
		_check(int(game.foes[0].hp) <= 5 and int(game.foes[1].hp) <= 10 and int(game.foes[2].hp) <= 11, "Regular health must remain bounded")
	for encounter in ["elite", "small_boss"]:
		game.reset()
		game.loop_n = 6
		game.t = 70.0
		if encounter == "elite":
			game.start_elite()
		else:
			game.start_boss()
		game.boss.t = 3.0
		var arrivals := 0
		var elapsed := 0.0
		for frame in 2400:
			var before: int = game.foes.size()
			game.step_spawn(1.0 / 60.0)
			arrivals += maxi(0, game.foes.size() - before)
			game.invuln = 999.0
			game.step_foes(1.0 / 60.0)
			game.step_eb(1.0 / 60.0)
			elapsed += 1.0 / 60.0
			var shooters := 0
			for foe in game.foes:
				_check(int(foe.kind) <= 2, "Minor encounter scheduled a special")
				shooters += int(int(foe.kind) > 0)
			for member in game.wave_pending:
				shooters += int(int(member.kind) > 0)
			_check(game.foes.size() + game.wave_pending.size() <= 5, "Support field cap exceeded")
			_check(shooters <= 1, "Support shooter cap exceeded")
		_check(arrivals > 8 and elapsed > 39.0, "Minor encounter stopped replenishing escorts")
	var entry_times := {}
	for loop_n in [2, 4, 6, 8]:
		game.loop_n = loop_n
		entry_times[game.elite_entry_time()] = true
	_check(entry_times.size() == 4, "Elite cadence repeats on every eligible loop")
	game.free()
	print("WAVE_CHECK plans=%d formations=%d assertions=%d failures=%d" % [plans, seen.size(), checked, failures])
	quit(0 if failures == 0 else 1)
