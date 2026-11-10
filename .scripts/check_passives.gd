extends SceneTree

const Game = preload("res://scripts/game.gd")
const Items = preload("res://scripts/passives.gd")
var checked := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checked += 1
	if not ok:
		failures += 1
		push_error(message)


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var game := Game.new()
	root.add_child(game)
	game.set_process(false)
	var counts := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	for sample in 10000:
		var item := Items.roll((sample + 0.5) / 10000.0)
		counts[item if item >= 0 else 8] += 1
	for item in 8:
		check(absi(counts[item] - int(round(Items.WEIGHTS[item] * 10000))) <= 1, "Drop weight drifted")
	check(counts[8] == 5600, "Passive expansion stole weapon drops")
	check(Items.HUD_ORDER == [Game.ITEM_SHIELD, Game.ITEM_THORN, Game.ITEM_MAGNET,
		Game.ITEM_RELOADER], "Retained passive order changed")
	for item in Items.HUD_ORDER:
		game.reset()
		game.caches.append({"p": game.player, "t": 0.0, "kind": Game.WEAPON_BASE, "passive": item})
		game.step_caches(0.0)
		check(game.caches.is_empty() and game.passive_fraction(item) == 1.0, "Real pickup failed")
		game._grant_item(item, game.player)
		check(game.passive_fraction(item) == 1.0, "Duplicate pickup stacked beyond its cap")
		game.reset()
		for other in 8:
			check(game.passive_fraction(other) == 0.0, "Reset retained passive state")
	# Removed effects cannot be granted, including by stale pickup data.
	for removed in [Game.ITEM_CAPACITOR, Game.ITEM_PHASE, Game.ITEM_PHOENIX, Game.ITEM_BARRAGE]:
		game.reset()
		game._grant_item(removed, game.player)
		check(game.passive_fraction(removed) == 0.0, "Removed passive can still be granted")
		check(counts[removed] == 0, "Removed passive still drops")
	# Retained defenses coexist: shield absorbs twice, then thorn responds to damage.
	game.reset()
	for item in Items.HUD_ORDER:
		game._grant_item(item, game.player)
	game.hurt_player()
	check(game.hull == Game.HULL_MAX and game.item_shield == 1 and game.item_thorn, "Shield failed to resolve first")
	check(game.passive_fraction(Game.ITEM_SHIELD) == 0.5, "Shield must lose half its fill per hit")
	game.hurt_player()
	check(game.item_shield == 0 and game.item_thorn, "Shield consumed another passive")
	game.hurt_player()
	check(game.hull == Game.HULL_MAX - 1 and not game.item_thorn, "Thorn failed on actual damage")
	game.hull = 1
	game.hurt_player()
	check(game.dead, "Removed revival prevented death")
	game.reset()
	game._grant_item(Game.ITEM_CAPACITOR, game.player)
	for kill in 20:
		game.credit_kill(1 if kill % 2 else 12)
	check(game.gauge == 0.0 and game.item_capacitor == 0, "Removed capacitor charged the gauge")
	check(game.kill_count == 20 and game.score == 130, "Removing capacitor altered scoring")
	for dt in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 165.0, 0.05]:
		game.reset()
		game._grant_item(Game.ITEM_MAGNET, game.player)
		game._grant_item(Game.ITEM_RELOADER, game.player)
		var elapsed := 0.0
		while elapsed < Items.DURATION + dt:
			game.step_passives(dt)
			elapsed += dt
		check(game.item_magnet == 0.0 and game.item_reloader == 0.0, "Timed passive duration drifted")
		game._grant_item(Game.ITEM_RELOADER, game.player)
		game.paused = true
		game._process(dt)
		check(game.item_reloader == Items.DURATION, "Pause spent a timed passive")
		game.paused = false
		game.dead = true
		game._process(dt)
		check(game.item_reloader == Items.DURATION, "Death spent a timed passive")
		for boosted in [false, true]:
			game.reset()
			if boosted:
				game._grant_item(Game.ITEM_RELOADER, game.player)
			game.mag[Game.WEAPON_BASE] = 0
			game._begin_reload()
			var duration: float = game.reload_len
			elapsed = 0.0
			while game.reloading and elapsed < 10.0:
				game.step_reload(dt)
				elapsed += dt
			var expected := duration / (1.35 if boosted else 1.0)
			check(absf(elapsed - expected) <= dt + 0.001, "Quickloader timing incorrect")
			check(game.cur_mag() == Game.WEAPON_MAG[Game.WEAPON_BASE], "Quickloader granted the wrong ammunition")
	game.reset()
	var start := game.player + Vector2(100, 0)
	game.caches.append({"p": start, "t": 0.0, "kind": Game.WEAPON_BASE})
	game.step_caches(0.1)
	check(game.caches[0].p == start, "Baseline pickup gained an early magnet")
	game._grant_item(Game.ITEM_MAGNET, game.player)
	game.step_caches(0.1)
	check(is_equal_approx((game.caches[0].p as Vector2).distance_to(start), 18.0), "Magnet pull speed incorrect")
	for frame in 60:
		game.step_caches(1.0 / 60.0)
	check(game.caches.is_empty(), "Magnet failed to collect")
	game.reset()
	# The real generator must include the new types, not just the pure roll helper.
	var seen := {}
	game.rng.seed = 9281
	for drop in 3000:
		game.caches.clear()
		game._spawn_cache(Vector2(260, 108))
		seen[int(game.caches[0].passive)] = true
	check(seen.size() == 5, "Live pool must contain four passives and weapons")
	for item in seen:
		check(item == -1 or item in Items.HUD_ORDER, "Live generator spawned a removed passive")
	game.free()
	print("PASSIVES checks=%d failures=%d" % [checked, failures])
	quit(1 if failures else 0)
