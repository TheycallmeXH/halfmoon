# Halfmoon path probe — diagnostic only, armed by HALFMOON_PATH.
#
# Records ONE enemy's y position every frame for a fixed window, then reports
# per-frame deltas. A steering body shows a smooth delta curve that swings
# through zero and back. The old parabola showed the delta collapsing toward ~0
# and then flipping sign, twice per period — a stall plus a snap. That is the
# measurable form of "the curve still looks like a bounce", and it is what this
# fixture exists to catch.
#
# Follows the tracked craft by DICTIONARY REFERENCE, not by index: the foes array
# shrinks whenever a craft dies, so an index would silently start sampling its
# neighbour.
#
# Writes user://shots/path.csv and prints a one-line summary.
extends Node

var game: Node
var t := 0.0
var window := 6.0
var want_kind := 0
var tracked: Dictionary = {}
var samples: Array[Vector2] = []
var started := false


func _ready() -> void:
	var boot := get_parent()
	if boot != null:
		game = boot.get("game")
	# HALFMOON_PATH is "seconds" or "seconds:kind", e.g. "20:2" tracks a coil,
	# which is the only kind whose entry used to teleport. Default stays kind 0
	# so existing invocations keep their meaning.
	var raw := OS.get_environment("HALFMOON_PATH")
	for part in raw.split(":", false):
		var v := part.strip_edges()
		if v.is_valid_float():
			if window <= 6.0 and not started:
				window = float(v)
				started = true
			else:
				want_kind = int(float(v))
	started = false
	# Keep the player alive for the duration, when asked.
	#
	# Kinds unlock on the GAME clock: the coil only appears after t > 15 s, and
	# the boss at 52 s. An unattended run dies within twenty seconds, which
	# freezes `t` — so a 30-second window could expire having never seen the
	# craft it was asked to track, and the probe reported nothing at all.
	# Pinpoint invulnerability is the smallest change that makes those kinds
	# reachable without adding a bot that also shoots.
	if game != null and OS.get_environment("HALFMOON_INVULN") != "":
		game.set("invuln", 9999.0)
		set_process(true)
		return
	set_process(true)


func _process(dt: float) -> void:
	if game == null:
		return
	# Keep the pin alive while sampling, in case something sets invuln back
	# (a hit resets it to 1.35 s; hurt_player also decrements hull).
	if OS.get_environment("HALFMOON_INVULN") != "":
		game.set("invuln", 9999.0)
	# Track the GAME clock, not this node's own uptime.
	#
	# `window` used to be the probe's own elapsed time, which starts at boot and
	# keeps running through a death screen — while the game clock freezes. So a
	# "26 s" window could expire before the coil (unlocked at t > 15 s) had ever
	# spawned, and the probe reported "not enough samples" for a craft it simply
	# never saw. The game's own `t` is the only clock that matters here.
	var gt: float = float(game.get("t"))
	if gt > window:
		_finish()
		return

	var foes: Array = game.get("foes")
	if tracked.is_empty():
		# Wait for the requested kind. Sampling a shard just because it is the
		# first craft on screen is how the coil's entry teleport went unmeasured.
		for f in foes:
			if int(f.get("kind", 9)) == want_kind:
				tracked = f
				break
		return

	var p: Vector2 = tracked.get("p", Vector2.ZERO)
	samples.append(p)
	# The craft died or was culled: the recorded arc is already a full cycle or
	# two, so stop here rather than padding the file with stale points.
	if samples.size() > 2 and p == samples[samples.size() - 2] and not foes.has(tracked):
		_finish()


func _finish() -> void:
	set_process(false)
	if samples.size() < 12:
		print("PATH not enough samples (%d)" % samples.size())
		return

	var dir := "user://shots"
	DirAccess.make_dir_recursive_absolute(dir)

	var f := FileAccess.open("%s/path.csv" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string("x,y,dy,ddy\n")
		for i in samples.size():
			var dy := 0.0
			var ddy := 0.0
			if i >= 1:
				dy = samples[i].y - samples[i - 1].y
			if i >= 2:
				ddy = dy - (samples[i - 1].y - samples[i - 2].y)
			f.store_string("%.2f,%.3f,%.3f,%.3f\n" % [samples[i].x, samples[i].y, dy, ddy])
		f.close()

	# Count the stall-snap signature: a delta that goes small and then reverses.
	var flips := 0
	var stall_then_flip := 0
	var last_sign := 0
	var small_run := 0
	for i in range(1, samples.size()):
		var dy := samples[i].y - samples[i - 1].y
		if absf(dy) < 0.15:
			small_run += 1
			continue
		var s := 1 if dy > 0.0 else -1
		if last_sign != 0 and s != last_sign:
			flips += 1
			if small_run > 0:
				stall_then_flip += 1
		last_sign = s
		small_run = 0

	# Largest second difference = the sharpest corner in the arc. A parabola's
	# reversal is a step in ddy; a sine's is the same value spread over frames.
	var max_ddy := 0.0
	var max_dy := 0.0
	var min_dy := 0.0
	for i in range(1, samples.size()):
		var dy := samples[i].y - samples[i - 1].y
		max_dy = maxf(max_dy, dy)
		min_dy = minf(min_dy, dy)
		if i >= 2:
			max_ddy = maxf(max_ddy, absf(dy - (samples[i - 1].y - samples[i - 2].y)))

	print("PATH n=%d flips=%d stallFlips=%d dy=[%.2f,%.2f] maxDDY=%.3f" % [
		samples.size(), flips, stall_then_flip, min_dy, max_dy, max_ddy])
