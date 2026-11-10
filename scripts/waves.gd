# Bounded encounter budgets and authored entry shapes, independent of combat.
extends RefCounted

enum Formation { SOLO, GATE, PINCER, ECHELON, VEE, ARROW, ESCORT, FILE,
	STAIRS, SPLIT, RIBBON, HOOK, WEDGE, ZIGZAG, SWEEP, PAIR }

const NAMES := ["solo", "gate", "pincer", "echelon", "vee", "arrow", "escort", "file",
	"stairs", "split", "ribbon", "hook", "wedge", "zigzag", "sweep", "pair"]
const COST := [1, 2, 3, 3, 4]


static func profile(loop_n: int, age: float, support: bool = false) -> Dictionary:
	var rank := mini(maxi(loop_n - 1, 0), 5)
	var warmup := age < 4.0
	var relief := not warmup and fposmod(age, 18.0) >= 14.0
	var drift := age >= 12.0 or (loop_n >= 2 and age >= 6.0)
	var coil := age >= 26.0 or (loop_n >= 2 and age >= 16.0)
	var count := 1
	if age >= (10.0 if loop_n == 1 else 8.0):
		count = 2
	if age >= (28.0 if loop_n == 1 else 24.0):
		count = 3
	var budget := 1
	if drift:
		budget = 2
	if count >= 2:
		budget = 3
	if count >= 3:
		budget = 4
	if age >= 42.0:
		budget = 5
	if not warmup:
		budget += mini(rank, 2)
	if relief:
		budget = maxi(1, budget - 2)
		count = mini(count, 2)
	var interval := maxf(1.25, 2.05 - smoothstep(0.0, 46.0, age) * 0.55 - float(rank) * 0.06)
	if relief:
		interval += 0.35
	if warmup:
		count = 1
		budget = 1
		interval = 2.1
	count = mini(count, budget)
	if support:
		count = mini(count, 2)
		budget = mini(budget, 3)
		interval = 2.8 if relief else 2.5
	return {
		"count": count, "budget": budget, "interval": interval,
		"drift": drift and not warmup, "coil": coil and not warmup,
		"relief": relief, "field_cap": 5 if support else 10 + mini(rank, 2),
		"shooter_cap": 1 if support else (3 if loop_n == 1 else 4),
		"coil_cap": 1 if support else (1 if loop_n == 1 else 2),
	}


static func plan(loop_n: int, age: float, rng: RandomNumberGenerator,
		last: int, active: PackedInt32Array, slots: int,
		recent: Array[int] = [], support: bool = false) -> Dictionary:
	var tuning := profile(loop_n, age, support)
	var count := mini(int(tuning.count), slots)
	if count <= 0:
		return {"formation": Formation.SOLO, "name": "hold", "interval": 0.4, "members": []}
	if count > 1 and rng.randf() < 0.10:
		count -= 1
	var choices: Array[int] = [Formation.SOLO]
	if count == 2:
		choices = [Formation.GATE, Formation.PINCER, Formation.ECHELON,
			Formation.STAIRS, Formation.SPLIT, Formation.SWEEP, Formation.PAIR]
	elif count == 3:
		choices = [Formation.ECHELON, Formation.VEE, Formation.ARROW, Formation.ESCORT,
			Formation.FILE, Formation.RIBBON, Formation.HOOK, Formation.WEDGE, Formation.ZIGZAG]
	if choices.size() > 1:
		choices.erase(last)
	# Exclude the newest four shapes, backing off oldest-first only if needed.
	var available_shapes := choices.duplicate()
	for used in recent:
		if available_shapes.size() > 1:
			available_shapes.erase(used)
	choices = available_shapes
	var formation := choices[rng.randi_range(0, choices.size() - 1)]
	var members := _layout(formation, count, rng)
	var remaining := int(tuning.budget)
	var shooters := active[1] + active[2]
	if active.size() >= 5:
		shooters += active[3] + active[4]
	var coils := active[2]
	# Spend on the escort leader first, leaving one point for each wingman.
	var order: Array[int] = []
	if formation == Formation.ESCORT:
		order = [1, 0, 2]
	if order.is_empty():
		for i in count:
			order.append(i)
	for index in count:
		var member: Dictionary = members[order[index]]
		var available := remaining - (count - index - 1)
		var kinds: Array[int] = [0, 0, 0]
		if tuning.drift and available >= COST[1] and shooters < int(tuning.shooter_cap):
			kinds.append(1)
			kinds.append(1)
		if tuning.coil and available >= COST[2] and shooters < int(tuning.shooter_cap) and coils < int(tuning.coil_cap):
			kinds.append(2)
		var kind := kinds[rng.randi_range(0, kinds.size() - 1)]
		if formation == Formation.ESCORT:
			kind = 1 if index == 0 and kinds.has(1) else 0
		member.kind = kind
		remaining -= COST[kind]
		if kind > 0:
			shooters += 1
		if kind == 2:
			coils += 1
	return {
		"formation": formation, "name": NAMES[formation],
		"interval": float(tuning.interval), "members": members,
	}


static func _layout(formation: int, count: int, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var rows: Array[float] = []
	var delays: Array[float] = []
	var mirror := rng.randf() < 0.5
	match formation:
		Formation.SOLO:
			rows = [rng.randf_range(44.0, 172.0)]
			delays = [0.0]
		Formation.GATE:
			var gap := rng.randf_range(88.0, 128.0)
			rows = [gap - 42.0, gap + 42.0]
			delays = [0.0, 0.0]
		Formation.PINCER:
			rows = [48.0, 168.0]
			delays = [0.0, 0.14]
		Formation.ECHELON:
			if count == 2:
				rows = [64.0, 152.0]
				delays = [0.0, 0.24]
			else:
				rows = [54.0, 108.0, 162.0]
				delays = [0.0, 0.22, 0.44]
		Formation.VEE:
			rows = [74.0, 108.0, 142.0]
			delays = [0.0, 0.30, 0.0]
		Formation.ARROW, Formation.ESCORT:
			rows = [74.0, 108.0, 142.0]
			delays = [0.30, 0.0, 0.30]
		Formation.FILE:
			var lane := rng.randf_range(60.0, 156.0)
			rows = [lane, lane, lane]
			delays = [0.0, 0.40, 0.80]
		Formation.STAIRS:
			rows = [86.0, 122.0]
			delays = [0.0, 0.56]
		Formation.SPLIT:
			rows = [80.0, 140.0]
			delays = [0.0, 0.58]
		Formation.SWEEP:
			rows = [52.0, 106.0]
			delays = [0.0, 0.40]
		Formation.PAIR:
			rows = [94.0, 118.0]
			delays = [0.0, 0.18]
		Formation.RIBBON:
			rows = [82.0, 104.0, 126.0]
			delays = [0.0, 0.28, 0.62]
		Formation.HOOK:
			rows = [60.0, 60.0, 124.0]
			delays = [0.0, 0.38, 0.72]
		Formation.WEDGE:
			rows = [56.0, 108.0, 160.0]
			delays = [0.0, 0.16, 0.64]
		Formation.ZIGZAG:
			rows = [68.0, 144.0, 92.0]
			delays = [0.0, 0.34, 0.68]
	# Move and stretch the complete shape, rather than jittering each wingman.
	var stretch := rng.randf_range(0.88, 1.08)
	var offset := rng.randf_range(-9.0, 9.0)
	var tempo := rng.randf_range(0.85, 1.0)
	var members: Array[Dictionary] = []
	for i in count:
		members.append({
			"kind": 0, "y": clampf(108.0 + ((216.0 - rows[i] if mirror else rows[i]) - 108.0) * stretch + offset, 38.0, 178.0),
			"delay": delays[i] * tempo, "amp": 8.0 if formation == Formation.FILE else 6.0,
		})
	return members
