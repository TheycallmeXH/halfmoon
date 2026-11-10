extends SceneTree

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
	var game = load("res://scripts/game.gd").new()
	root.add_child(game)
	game.set_process(false)
	for thorn in [false, true]:
		game.reset()
		game.invuln = 0.0
		game.item_thorn = thorn
		if thorn:
			game.start_boss()
			game.boss.p = game.player + Vector2(20, 0)
			game.boss.hp = 1
		for i in 3:
			game.eb_add(game.player, Vector2.ZERO, 1.0)
		game.step_eb(0.0)
		check(game.hull == game.HULL_MAX - 1, "Projectile contact did not resolve once")
		check(game.eb.size() == (0 if thorn else 2), "Contact/retaliation kept stale projectiles")
		check(not game.item_thorn, "Retaliation was not consumed")
		check(game.invuln > 0.0, "Contact did not grant invulnerability")
	game.reset()
	game.eb_add(Vector2(200, 100), Vector2(-20, 0), 1.0)
	game.eb_add(Vector2(220, 120), Vector2(-30, 0), 1.0)
	game.step_eb(0.05)
	check(game.eb.size() == 2, "Movement removed a live round")
	check(game.eb[0].p == Vector2(199, 100), "Dictionary movement did not persist")
	check(game.eb[1].p == Vector2(218.5, 120), "Dictionary movement did not persist")
	game.eb[0].pin_p = Vector2(210, 110)
	game.step_eb(0.05)
	check(game.eb[0].p == Vector2(210, 110), "Pinned projectile movement did not persist")
	print("PROJECTILE_CLEAR checks=%d failures=%d" % [checked, failures])
	quit(1 if failures else 0)
