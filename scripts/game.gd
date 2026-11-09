# Halfmoon 闂?a 384x216 ink shmup, drawn with whole pixels only.
#
# Hull sits on the left and fires by itself; you only dodge.
#   arrows / WASD   steer
#   Shift           focus: slow drift, thin silhouette
#   Space           ERASE, when the hatched gauge is full: wipes the screen
#   R               restart after a blot-out
#
# Nothing on screen is a string: hull = tick marks, score = tally marks,
# ink gauge = a hatched bar, loop count = ticks. The raster is upscaled 3x by
# the CRT shader on the wrapping SubViewportContainer.
class_name Halfmoon
extends Node2D

const W := 384.0
const H := 216.0

const PAPER := Color(0.925, 0.910, 0.851)
const INK := Color(0.129, 0.129, 0.118)
const MUTE := Color(0.702, 0.686, 0.635)
const SOOT := Color(0.396, 0.388, 0.353)

const SPEED := 113.0
const FOCUS_SPEED := 43.0
# Inertia tuning: how fast velocity chases the stick, and how fast it bleeds
# off when released. Heavier than before 闂?the ship now carries real momentum
# and needs a beat to settle, which is what makes dodging feel weighty.
const ACCEL := 6.2
const BRAKE := 4.4
const ACCEL_FOCUS := 13.0
const BRAKE_FOCUS := 11.0
# Weapon: cooldown gated by the trigger, not a free-running clock.
const FIRE_COOLDOWN := 0.19
const SHOT_SPEED := 520.0
# Length in SOURCE pixels of every projectile's tail. Trimmed by distance, not
# by sample count, so the streak looks identical at 60, 120 or uncapped fps.
const TAIL_LEN := 13.0
const HULL_MAX := 3
const BOSS_AT := 52.0
const ERASE_GAIN := 0.070
const LEFT_LIMIT := 16.0
# 2026-11-09: the craft may now cross the whole field.
#
# The right half used to be an air wall at W*0.58 (222.7). That wall was
# carrying a second job nobody had written down: it kept the player OUT of
# every boss body, which is why no contact damage existed anywhere in the
# file. Removing the wall without adding the contact rule would have turned
# the game into "park inside the 28px ink disc and out-damage it", so the
# contact hurt lands in the same change (see step_boss / step_elite /
# step_rival).
#
# The limit is derived from the FRAME, not from the raster: the printed
# border is what the eye reads as "the edge of the world", and the hull is
# ~26px wide, so 14px in from the rule is the furthest it can sit without
# crossing the line.
const RIGHT_LIMIT := FRAME.end.x - 14.0     # 361
const TOP_LIMIT := FRAME.position.y + 12.0  # 20
const BOTTOM_LIMIT := FRAME.end.y - 12.0    # 196
const FRAME := Rect2(9.0, 8.0, W - 18.0, H - 16.0)

# Movement bounds, derived from the frame instead of from the raster.
#
# Everything used to be culled against W/H 闂?the RASTER size 闂?while the visible
# playfield is the FRAME rect, 9..375 by 8..208. Crafts therefore entered at
# W+16..W+26 and were allowed to run to -26, i.e. up to 35 px OUTSIDE the
# printed border, on both sides. On a screen this small that is a quarter of
# the field: enemies visibly walked in over the frame line.
#
# These are the raster-edge equivalent of the old values, pulled in to the
# frame edge. Spawning still happens just outside the border (a craft must not
# pop into existence inside it) 闂?the distance is simply short enough that the
# breach lasts a fraction of a second instead of half a second.
const SPAWN_MARGIN := 6.0
const CULL_MARGIN := 12.0
const SPAWN_X := FRAME.end.x + SPAWN_MARGIN      # 381
const CULL_X_LEFT := FRAME.position.x - CULL_MARGIN   # -3
const CULL_X_RIGHT := FRAME.end.x + CULL_MARGIN      # 387
const CULL_Y_TOP := FRAME.position.y - CULL_MARGIN   # -4
const CULL_Y_BOTTOM := FRAME.end.y + CULL_MARGIN     # 220
const MOON_C := Vector2(238.0, 106.0)
const MOON_R := 74.0

var rng := RandomNumberGenerator.new()

var t := 0.0
var hull := HULL_MAX
var score := 0
var gauge := 0.0
var invuln := 0.0
var dead := false
var dead_t := 0.0
var loop_n := 1
var boss: Dictionary = {}
var flash := 0.0
var shake := 0.0
var shake_age := 0.0       # seconds since the shake began, drives the falloff
var shake_seed := 0.0      # per-hit phase, so no two hits shake identically
var shake_dir := Vector2.ZERO  # kick direction, away from the impact
var focus_on := false
var erase_t := 0.0

var player := Vector2(52.0, H * 0.5)
var vel := Vector2.ZERO
# Directional animation state.
#
# These replaced an older pair (bank/pitch) that sheared one rigid polygon. That
# approach could not distinguish "moving left" from "moving right" 鈥?the nose
# always pointed right, so every input direction produced the same sticker at a
# different place. Three signed/unsigned channels give the drawn hull enough
# freedom to answer each direction differently, which is the whole requirement.
# yaw and roll are signed; wing_flap is a 0..1 magnitude used for the engine
# plume and for the wing fold's amplitude.
var hull_yaw := 0.0    # -1 nose down .. +1 nose up
var hull_roll := 0.0   # -1 hard left .. +1 hard right
var wing_flap := 0.0   # 0 idle .. 1 full deflection
var trail_w := 0.0     # engine wake strength, 0..1
var lag := Vector2.ZERO  # field counter-drift against the hull
# Flame skeleton: a chain of joints trailing the nozzle. Bone 0 is pinned to the
# ship; each further bone is dragged toward the one before it, so the plume whips
# like a rope instead of moving as one rigid lamp. Updated in step_player.
var bones: Array[Vector2] = []
var bones_vel: Array[Vector2] = []
const BONE_COUNT := 6
var hit_t := 0.0       # seconds since the last hit, drives the impact punch
var kill_t := 0.0      # seconds since the last kill, drives the burst rings
var hit_stop := 0.0    # remaining freeze time on impact, in seconds
var fire_t := 0.0
var cannon := 0
var cooldown := 0.0
var trigger := false
# Fires 1.0 -> 0.0 over ~0.12 s after each round leaves the muzzle. Drives the
# discharge wave in the gun strip and the muzzle kick on the hull. Kept here
# rather than derived in the HUD because drawing must not mutate state, and a
# wave that the drawing computed from `cooldown` would run BACKWARDS whenever the
# trigger was released.
var shot_pulse := 0.0

# ---- ammunition -------------------------------------------------------------
#
# Every tier is now a MAGAZINE + RELOAD, not a countdown.
#
# The old model gave each special weapon a lifetime (13/10/10/9 s) and let the
# base gun fire forever. Two problems with that:
#
#   1. the timer was invisible in the moment. You could hold fire, notice the
#      stream thin out, and only then realise the tier had expired 閳?the
#      remaining time lived in one thin bar in a corner;
#   2. it made the special guns *better than free*: they never ran dry, so the
#      only cost of using one was waiting out its timer, and the optimal play
#      was to hold fire for the full duration no matter what the screen looked
#      like.
#
# A magazine makes the cost legible and local: you spend shots, you see the
# count, and running dry costs a pause you chose to risk. The base gun has an
# endless reserve but still needs the 1.5 s change-overs, so spamming it is no
# longer free either 閳?which is what makes the other tiers worth picking up
# rather than merely "more damage for a while".
#
#   tier   mag  reload  reserve   rounds per volley
#   BASE    30   1.5 s  infinite  1
#   BOMB    10   2.2 s  50        1
#   MG      45   1.6 s  120       1
#   SPREAD  18   2.0 s  54        1 (volley = 1 round, 3 pellets)
#   LASER   12   2.0 s  36        1
#
# "Rounds" counts trigger pulls, not pellets: a SPREAD volley spends one round
# even though it puts three pellets in the air. Otherwise its 18-round magazine
# would be six volleys and the tier would be unusable.
const WEAPON_BASE := 0
const WEAPON_BOMB := 1
const WEAPON_MG := 2
const WEAPON_SPREAD := 3
const WEAPON_LASER := 4
const WEAPON_FLAK := 5
const WEAPON_RAIL := 6
const WEAPON_SWARM := 7
# Every loop that walks the tiers uses this instead of a literal, so adding a
# tier is a change to the tables and nothing else. A bare `range(5)` somewhere
# is exactly how the reward plate letters stayed blank for eighteen rounds.
const WEAPON_LAST := 7

# ---- the tier table ---------------------------------------------------------
#
#   tier     cd     dmg      mag  reload  restock  cadence / identity
#   BASE     0.19    1        30   1.5 s   infinite twin barrels
#   BOMB     0.38    5        10   2.2 s   50      44 px blast
#   MG       0.105   1        45   1.6 s   120     pure rate of fire
#   SPREAD   0.22    1x3      18   2.0 s   54      3 pellets, +/-11 deg
#   LASER    0.26    1        12   2.0 s   36      pierce 3, no splash
#   FLAK     0.36    1x5      20   2.1 s   60      5 pellets +/-24 deg + shards
#   RAIL     0.62    3         6   2.4 s   18      pierce 3, heavy single rod
#   SWARM    0.34    1x2      18   1.9 s   54      2 darts, one steer each
#
# `dmg` is per PELLET. The rounds-per-volley column is implicit: one trigger
# pull spends one round no matter how many pellets leave the muzzle.
const WEAPON_MAG := [30, 10, 45, 18, 12, 20, 6, 18]
const WEAPON_RELOAD := [1.5, 2.2, 1.6, 2.0, 2.0, 2.1, 2.4, 1.9]
# How many rounds ONE pickup adds. -1 = the base gun, which has no reservoir.
const WEAPON_RESERVE := [-1, 50, 120, 54, 36, 60, 18, 54]

const WEAPON_CD := [0.19, 0.38, 0.105, 0.22, 0.26, 0.36, 0.62, 0.34]
const WEAPON_DMG := [1, 5, 1, 1, 1, 1, 2, 1]
const WEAPON_GLYPH := ["", "B", "G", "S", "L", "F", "R", "W"]

# Blast: radius in source pixels, and damage to everything except the direct
# target.
#
# HISTORY, because this constant has now been raised twice and the reasons
# matter more than the number:
#   15 -> 30 on 2026-11-09 ("大幅提高爆炸弹的爆破范围"), damage held at 2 -- the
#   argument was "doubling the area IS the strength increase". The user came
#   back and said the tier was still weak, which settles that argument: area
#   alone does not read as power. A 30px circle on a 384px field reaches only
#   the craft that were already touching the target, and splash 2 could not even
#   kill a loop-1 shard (2hp), so a perfect shot into a cluster left two of the
#   three on 1hp. The tier read as a slow single-target gun with a cosmetic ring.
#   30 -> 44 now, and this time the damage moves with it: splash 2 -> 4 and the
#   direct hit 3 -> 5. All three together, one pass.
#
# WHY 44 AND NOT 54:
#   * `THORN_RADIUS` is 46 ON PURPOSE and must stay above the player's blast --
#     see the comment on it: the thorn is the passive you buy by taking a hit,
#     and a passive that out-ranges the weapon it supports is a reward for being
#     hit. 44 keeps that ordering intact (44 < 46). Raising the bomb past it
#     would silently turn a tuned passive into a downgrade, and the thorn is not
#     mine to touch in this change.
#   * The splash ring is drawn at BOMB_BLAST_R, and draw_rings adds a
#     `rad*1.16` companion whenever w > 1.2 -- the bomb ring uses w = 1.4, so
#     the drawn outer stroke is 44 * 1.16 = 51px. The ERASE sweep is capped at
#     190 for exactly this reason (past the raster edge the per-row scanline
#     strokes clip into a diagonal band across the plate). 51 is comfortably
#     inside the 384x216 raster wherever the burst lands.
#   * 44 is 1.47x the old radius = 2.15x the area. Together with the splash
#     number, one shell now covers the gap between two lanes of a normal
#     three-craft wave, which is what turns "aim at one craft" into "aim at a
#     cluster" instead of merely increasing the number on the stat line.
#
# The radius is a HARD edge on purpose. Falloff would make "did that kill it?"
# unanswerable at a glance, which is the one thing this project refuses.
const BOMB_BLAST_R := 44.0
# 2 -> 4. Paired with the direct hit going 3 -> 5, a shell now reads as "5 to
# the thing I hit, 4 to everything beside it". Splash at 2 was the real reason
# the tier felt weak: it could not kill a shard outright, so the one weapon
# built for clearing groups could not clear a group.
const BOMB_BLAST_DMG := 4
# Ceiling on how many craft one shell may splash.
#
# This constant was DECLARED AND NEVER READ for its whole life -- the splash
# loop had no counter and no break, so the ceiling was documented but absent.
# It is wired in now, which matters more with the larger radius: an uncapped
# loop over `foes` on every contact is O(n^2) work in the one place a late-loop
# field is most crowded. 6 -> 8 to match the area; the direct target does not
# consume a slot (it is skipped before the counter).
const BOMB_BLAST_MAX := 8

# FLAK shards: a pellet that connects seeds a short spray of paper shards that
# wound neighbours. This is what separates FLAK from SPREAD -- SPREAD puts more
# damage on one body by closing distance, FLAK spreads a little damage across a
# cluster. Radius is deliberately small: it should reach the craft that was
# ALREADY beside the target, not sweep the wave.
const FLAK_SHRED_R := 11.0
const FLAK_SHRED_DMG := 1
const FLAK_SHRED_MAX := 3

# ---- SPREAD cluster burst ----------------------------------------------------
#
# A SPREAD pellet that connects throws FRAG_COUNT small rounds outward in a
# ring. Three directions at 120 degrees, each at half the parent's damage, so
# one connecting pellet can chain into a neighbour but never into the whole
# screen.
#
# The children are NOT re-armable: they carry `frag: true` and the cluster
# branch skips anything carrying it. A pellet that bursts into bursting pellets
# is a chain reaction, and one SPREAD volley would clear a wave.
#
# Speed is deliberately LOW (SHOT_SPEED * 0.55): these are shrapnel, not shots.
# A fast ring would read as a second volley and make the tier ambiguous; a slow
# ring reads as the pellet coming apart.
const FRAG_COUNT := 3
const FRAG_DMG := 1
const FRAG_SPEED := 0.55
const FRAG_LIFE := 0.55
# ---- what a cache can carry -------------------------------------------------
#
# An explicit pool, not a numeric range.
#
# The old call was `rng.randi_range(WEAPON_BOMB, WEAPON_LASER)`, which silently
# assumed the tiers were a contiguous block and that every index in it was
# equally desirable. Both assumptions break the moment tiers are added: a range
# would hand out the three new specials at the same rate as BOMB while also
# needing a code edit at every future tier. The pool states the actual odds.
#
# BOMB and MG appear twice: they are the two tiers that work against any wave,
# so they are the ones that keep a run's output up. RAIL appears once -- it is
# the slowest trigger in the game and should feel like a find.
const CACHE_POOL := [
	WEAPON_BOMB, WEAPON_BOMB,
	WEAPON_MG, WEAPON_MG,
	WEAPON_SPREAD, WEAPON_SPREAD,
	WEAPON_LASER,
	WEAPON_FLAK,
	WEAPON_RAIL,
	WEAPON_SWARM,
]

# ---- the armoury ------------------------------------------------------------
#
# ONE array pair is the truth, and `weapon` is only the cursor into it.
#
# The first magazine implementation kept a single `ammo` / `reserve` pair and
# reset them whenever the tier changed. That works only while the player can
# never hold two tiers at once. With a wheel selector it becomes a pair of
# mirrored copies that drift: switching away would silently discard rounds the
# player had paid for, and switching back would refill for free. So the state
# is per-tier, and there is no scalar left to disagree with it.
#
#   mag[k]    rounds currently loaded in tier k
#   stock[k]  rounds in tier k's reservoir; -1 means "no reservoir" (base gun)
#
# `has_rounds(k)` is the single predicate every decision goes through: the wheel
# skips empty tiers, the pickup refuses to arm an empty one, and the fallback to
# base checks it after every reload.
var mag: Array[int] = [30, 0, 0, 0, 0, 0, 0, 0]
var stock: Array[int] = [-1, 0, 0, 0, 0, 0, 0, 0]
# The cursor into the arrays above. Nothing about the tier's ammunition lives
# here -- this is only "which row am I reading".
var weapon := WEAPON_BASE
# Wheel input, written by boot.gd and consumed once per frame here.
#
# It has to arrive from outside this script: the render chain puts this node
# inside a SubViewport whose `handle_input_locally` is false, and the
# SubViewport is never fed by its parent TextureRect -- there is no
# SubViewportContainer anywhere in the pipeline. So `_unhandled_input` here
# would never fire once, and the whole wheel would look like a dead feature.
var wheel_pending := 0

# ---- reload -----------------------------------------------------------------
#
# One timer drives both the mechanical state and the ring in the HUD, so the two
# can never disagree. `reload_t` counts UP from 0 to `reload_len`; the ring
# sweeps by `reload_t / reload_len` and `ammo` refills at exactly 1.0.
var reload_t := 0.0
var reload_len := 0.0
var reloading := false
# ---- kill streak ------------------------------------------------------------
#
# A streak is a burst of kills inside a short window, not a lifetime total.
# 2.2 s is about one wave cycle: long enough to chain through a three-craft
# wave, short enough that stopping to dodge breaks it. Eight kills is roughly
# 2.5..4 s of continuous output, which is the point where the player has found
# a rhythm but has not been holding the button for so long that a reward feels
# routine.
const STREAK_WINDOW := 2.2
const STREAK_STEP := 8
# Flat per-kill chance, on top of the streak counter. 12% means a cache turns up
# roughly every 8 kills on average either way, but unpredictably 闁?see note_kill.
const CACHE_DROP_CHANCE := 0.12

var kill_streak := 0
var streak_t := 0.0
var caches: Array[Dictionary] = []

# ---- breathing heal ---------------------------------------------------------
#
# Seven seconds of not being hit buys the first segment, then one segment every
# five. From one segment that is ten seconds to full, so a 52 s loop can return
# at most two segments: recovery exists, but three segments still mean
# something.
const HEAL_DELAY := 7.0
const HEAL_STEP := 5.0

var heal_t := 0.0
var heal_acc := 0.0

# ---- pause ------------------------------------------------------------------
var paused := false
var esc_held := false

# ---- elite -------------------------------------------------------------
#
# A mid-loop mini boss. Its ONLY job is to break the wave rhythm once, halfway
# to the boss 闂?it is not a damage check and it is not a gate.
#
# It went through a bad first version that taught the real lesson here: the
# elite shared the `boss` slot, and nothing retired it. A player who ignored it
# (or who could not reach it) left it alive forever, which meant `start_boss`
# never ran and the 52 s boss never appeared at all. The symptom read as "the
# boss has no attacks"; the cause was that the boss was never created.
#
# Fixes, all three required:
#   1. a hard lifetime (ELITE_LIFE) after which it withdraws;
#   2. the boss schedule does NOT wait for the elite 闂?see step_boss;
#   3. it spawns much less often. Once per loop was still too frequent; it is
#      now one per two loops, i.e. every other 52 s cycle.
const ELITE_AT := 26.0
const ELITE_LIFE := 11.0
const ELITE_EVERY := 2          # appear on loops 2, 4, 6 ...

var elite_done := false
var elite_next_loop := ELITE_EVERY

var pb: Array[Dictionary] = []
var eb: Array[Dictionary] = []
var foes: Array[Dictionary] = []
var sparks: Array[Dictionary] = []
var rings: Array[Dictionary] = []

var spawn_t := 0.8
var grain: Array[Vector3] = []
var backdrop: Node2D

# Capture hook, armed by HALFMOON_SHOT so verification runs need no desktop
# screenshot round-trip. HALFMOON_WARP starts the clock closer to a boss.
var cap_on := false
var cap_n := 0
var cap_warp := 0.0
var cap_accum := 0.0
const CAP_TIMES := [3.1, 5.4]
# Blast probe bookkeeping. `blast_watch` is armed by HALFMOON_STATE=blast and
# cleared once the verdict has been printed, so a 5.4 s capture run reports
# exactly one result instead of a verdict per frame.
var blast_watch := false
var blast_ref := Vector2.ZERO
var blast_printed := false
# The probe's own craft, in placement order, so the verdict can print every
# survivor's REAL distance to the burst and compare it with the radius.
#
# A verdict that only counts bodies cannot distinguish "the radius is right"
# from "the layout drifted", which is the trap this probe has already fallen
# into twice: it once measured from the layout origin instead of the burst, and
# once let the shell stop at the nearest craft so the far craft was only 20px
# from the impact. Both runs printed PASS on a radius that never changed.
var blast_probe: Array[Dictionary] = []
# Set when the probe's shell is CONSUMED, not merely when `pb` is momentarily
# empty. The first version waited for an empty `pb`, which is ALSO true on the
# frames before the shell reaches anything -- the report then fired while all
# three craft were still alive and said the blast did nothing.
# ---- passive items -----------------------------------------------------------
#
# Three defensive pickups, on the SAME `caches` array as the weapon tiers, with
# a `passive` field on the cache that says which one it is.
#
# Why one array and not a second one: the pickup path already owns magnetise,
# the 14px grab radius, the 6s expiry and the `hold` probe escape. A parallel
# array would need all four again, and the two would drift -- which is the
# project's fourth silent failure, but with an entire subsystem attached.
#
# Three fields, three jobs, and each is read exactly once:
#
#   ITEM_SHIELD  absorbs the next ITEM_SHIELD_CHARGES hits entirely. COMMON.
#   ITEM_THORN   on contact, detonates a mid-size blast at the impact. RARE.
#   ITEM_BARRAGE fires one half-field sweep the moment it is picked up. VERY RARE.
#
# "同道具不可叠加，只能刷新为初始状态" -- so each is a counter or a bool, and
# picking a second one RESETS rather than adds. That is the whole reason the
# state is three scalars and not three arrays.
#
# "不同道具可以共存" -- they are independent fields, so nothing can shadow
# anything else.
const ITEM_NONE := -1
const ITEM_SHIELD := 0
const ITEM_THORN := 1
const ITEM_BARRAGE := 2

const ITEM_SHIELD_CHARGES := 2
# Blast radius on a contact. Larger than the player's BOMB (44) on purpose: the
# player did not aim this, so it has to be worth having taken the hit for.
const THORN_RADIUS := 46.0
const THORN_DMG := 5
# Fraction of the field one barrage clears. "立即清除一半敌人" -- literally half,
# rounded up, so one craft is always killed and three are never all left.
const BARRAGE_FRACTION := 0.5

# Drop odds, per cache that spawns. Tuned so the three are visibly different in
# frequency: a shield roughly one cache in three, a thorn one in eleven, a
# barrage one in twenty. Weapon tiers get whatever is left, which is still the
# majority -- the armoury is the game, the passives are a floor under it.
const ITEM_CHANCE_SHIELD := 0.30
const ITEM_CHANCE_THORN := 0.09
const ITEM_CHANCE_BARRAGE := 0.05

# Live state. Two scalars, because only two of the three PERSIST:
#
#   item_shield   charges remaining, decremented per hit absorbed
#   item_thorn    armed until it fires once
#
# A barrage has no state at all -- "被拾取后立即清除一半敌人" means it fires the
# instant the pickup lands and leaves nothing behind. A `item_barrage` flag
# would be a field nothing ever reads, i.e. this project's twelfth silent
# failure with a passive item built on top of it.
var item_shield := 0        # charges remaining
var item_thorn := false     # armed until the next contact fires it

var blast_landed := false
var blast_impact_n := 0
# Counts down to an injected ERASE, in real seconds since _ready. 0 disables.
# Needed because ERASE is a 1.1 s effect fired by an input the probe cannot
# press: without it the only way to photograph the wipe is to hold Space.
var erase_at := 0.0
# Delayed one-shot probes for the passive items, same mechanism: real seconds
# since _ready, fires once, disarms. 0 = disabled.
var hurt_at := 0.0
var barrage_at := 0.0
var rearm_at := 0.0
# Probe-only: when > 0, step_rival forces the twin's reload_t to this value
# every frame. A seeded value would be counted past by the time the shutter
# opens; pinning it is the only way to photograph a mid-change-over reliably.
var reload_pin := 0.0
# Probe counter: how many change-overs the twin has completed. Printed by the
# rival probe so "did he ever reload" has a number instead of an inference from
# a frozen `fire` value in the log.
var rival_reloads := 0
var rival_report_at := 0.0
var hud_report_done := false


func _ready() -> void:
	rng.seed = 20261107
	# Resolve the baked backdrop sibling and mirror the moon state into it.
	var par := get_parent()
	if par != null:
		backdrop = par.get_node_or_null("Backdrop") as Node2D
	cap_on = OS.get_environment("HALFMOON_SHOT") != ""
	var wr := OS.get_environment("HALFMOON_WARP")
	if wr != "":
		cap_warp = float(wr)
	DirAccess.make_dir_recursive_absolute("user://shots")
	reset()
	if cap_warp > 0.0:
		t = cap_warp
	# Verification states, used by capture runs so the fx can be inspected
	# without playing into them: HALFMOON_STATE=hit|kill|dead
	var st := OS.get_environment("HALFMOON_STATE")
	match st:
		"hit":
			hurt_player()
			hit_stop = 0.0
			invuln = 0.0
		"kill":
			for k in 4:
				var q := Vector2(150.0 + float(k) * 46.0, 80.0 + float(k % 2) * 60.0)
				puff_heavy(q, 22)
				rings.append({"c": q, "r0": 2.0, "r1": 14.0, "r": 2.0, "t": 0.0, "w": 1.0, "life": 0.26})
				rings.append({"c": q, "r0": 4.0, "r1": 34.0, "r": 4.0, "t": 0.0, "w": 1.6, "life": 0.48})
			add_shake(3.0)
		"dead":
			hull = 1
			hurt_player()
		"last":
			# One life left, but NOT dead. `hit` only costs one segment from
			# three, so it can never reach the flashing state; asserting it
			# directly is the only way to photograph the blink without playing
			# into it. invuln is cleared so the state is the real one.
			hull = 1
			invuln = 0.0
		"weapon":
			# Every weapon tier on the field at once, plus a cache, so one frame
			# shows all bullet shapes and a pickup plate.
			_grant_tier(WEAPON_SWARM)
			mag[WEAPON_SWARM] = int(WEAPON_MAG[WEAPON_SWARM])
			for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
				caches.append({
					"p": Vector2(60.0 + float(k - 1) * 36.0, 132.0),
					"t": 0.5, "kind": k, "picked": false, "hold": true,
				})
		"tiercount":
			# NUMERIC assertion, not a picture: fire each tier once through the
			# real trigger path and count what actually left the muzzle, plus
			# the damage each round carries.
			#
			# A picture cannot answer "is a SWARM volley 2 darts or 3" -- darts
			# that overlap on a 384px raster look the same either way, and the
			# `tier` probe PLACES its rounds rather than firing them, so it
			# never exercises the volley loop at all. A balance number needs a
			# probe that reads the number.
			var report := ""
			for tw2 in range(WEAPON_BASE, WEAPON_LAST + 1):
				pb.clear()
				weapon = tw2
				mag[tw2] = int(WEAPON_MAG[tw2])
				stock[tw2] = int(WEAPON_RESERVE[tw2])
				cooldown = 0.0
				reloading = false
				# The real fire path, so a volley that builds N pellets is
				# measured through the same code the player uses.
				var saved_trigger := trigger
				trigger = true
				step_fire(0.0)
				trigger = saved_trigger
				var n := pb.size()
				var d0 := 0
				if n > 0:
					d0 = int((pb[0] as Dictionary).get("dmg", 0))
				report += " %d:%dx%d" % [tw2, n, d0]
			pb.clear()
			weapon = WEAPON_BASE
			mag[WEAPON_BASE] = int(WEAPON_MAG[WEAPON_BASE])
			reloading = false
			print("TIERCOUNT%s" % report)
		"tier":
			# silhouette is only 1~2px wide can be photographed at a known
			# position instead of wherever a real shot happens to be on the
			# shutter frame.
			#
			# This exists because of a measurement failure, not for
			# convenience: `HALFMOON_STATE=weapon` arms SWARM, and the 3.1s
			# shutter then landed on frames where ONLY SWARM rounds were
			# airborne -- so the raw 384x216 raster came back with a maximum
			# luma of 0.9078 (paper) and glow_budget reported gate_px=0. That
			# number says nothing about the CORE budget; it says the shutter
			# missed every tier that carries one. A probe that cannot place the
			# object it is measuring produces confident zeroes.
			#
			# HALFMOON_TIER is the weapon index (0..7). Rounds are placed at
			# x=200 on five rows so several are visible in one frame and the
			# per-round pixel count is unambiguous.
			var tw := int(OS.get_environment("HALFMOON_TIER"))
			weapon = tw
			mag[tw] = int(WEAPON_MAG[tw])
			stock[tw] = int(WEAPON_RESERVE[tw])
			var tlens: Array[float] = [3.0, 6.0, 3.0, 3.0, 9.0, 2.5, 12.0, 3.0]
			for row in 5:
				# FROZEN, not flying. A round placed at x=200 with SHOT_SPEED
				# leaves the field in 0.36s, so the first version of this probe
				# measured an empty field and reported gate_px=0 for all eight
				# tiers -- a confident zero, which is the worst kind of
				# measurement. `pin_p` holds the body and rebuilds a level wake
				# every frame in step_pb, so the tier's real _wake_span and its
				# real _wake_cfg are what get photographed.
				pb.append({
					"p": Vector2(200.0, 60.0 + float(row) * 24.0),
					"v": Vector2.ZERO,
					"pin_p": Vector2(200.0, 60.0 + float(row) * 24.0),
					"len": tlens[tw], "dmg": 1, "pierce": 1,
					"wk": tw,
				})
				# Pre-load the trail so the wake is on the very first drawn
				# frame. A fresh round has a one-point trail and draw_streak
				# returns immediately, so without this the probe would
				# photograph the body and no tail at all.
				var tb: Dictionary = pb[pb.size() - 1]
				var tq: Array = []
				for tstep in 24:
					tq.append(Vector2(200.0 - float(tstep), 60.0 + float(row) * 24.0))
				tb.trail = tq
			print("TIER wk=%d placed=%d" % [tw, pb.size()])
			# Three pinned HOSTILE rounds in the row below, one per tier the
			# twin can actually fire. `draw_eb` resolves its stamp through
			# _wake_cfg(wk, true) and its span through _wake_span(wk, true), so
			# this is the only way to see the hostile sync without waiting for a
			# live duel to place a volley in front of the shutter.
			var hrts: Array[float] = [1.2, 2.4, 1.4]
			for hi in 3:
				var hwk: int = [WEAPON_BASE, WEAPON_MG, WEAPON_BOMB][hi]
				eb.append({
					"p": Vector2(200.0, 180.0 + float(hi) * 10.0),
					"v": Vector2(-HOSTILE_SHOT_SPEED, 0.0),
					"r": hrts[hi], "life": 7.0, "wk": hwk,
					"pin_p": Vector2(200.0, 180.0 + float(hi) * 10.0),
					"trail": [],
				})
			print("TIER hostile=%d" % eb.size())
		"reload":
			# Mid-change-over, so the ring can be photographed at a known sweep.
			# The magazine is zeroed AFTER arming the tier -- _grant_tier loads
			# it, so setting it first would be overwritten and the strip would
			# show a full magazine next to a half-swept reload ring, which is a
			# state that cannot occur in play and would make the screenshot lie.
			_grant_tier(WEAPON_BOMB)
			_select_tier(WEAPON_BOMB)
			mag[WEAPON_BOMB] = 0
			reloading = true
			# A very long change-over, held at 55%. The capture happens at 3.1 s
			# and a real BOMB reload is 2.2 s, so a truthful reload_len means the
			# state has already completed by the time the shutter opens and every
			# "mid-reload" screenshot is really a screenshot of "ready". The
			# PROGRESS RATIO is what is being photographed, and 0.55 of a long
			# change-over looks exactly like 0.55 of a short one.
			#
			# `reload_len` is only a denominator (see step_reload and the ring's
			# prog computation), so inflating it changes nothing else.
			reload_len = 60.0
			reload_t = reload_len * 0.55
		"rivalreload":
			# The twin mid-change-over, so the arc and the shrunken plume can be
			# photographed.
			#
			# `reload_t` alone is not enough: step_rival counts it up every
			# frame, so seeding it at 55% of a 1.6s reload only holds for
			# 0.72s and the 3.1s shutter opens on a finished change-over. The
			# probe therefore pins it every frame via `reload_pin`, which
			# `step_rival` re-applies after the count -- the same trick
			# HALFMOON_STATE=reload uses with its inflated reload_len.
			player = Vector2(52.0, H * 0.5)
			boss_beat_this_loop = true
			start_rival()
			boss.p = Vector2(W * 0.62, H * 0.5)
			boss.t = 3.0
			boss.reloading = true
			boss.mag = 0
			boss.fire = 99.0
			reload_pin = RIVAL_RELOAD * 0.55
		"rival":
			# The duel stage, already in progress: the twin is on station and has
			# had time to settle into its lane. Placing it straight there (rather
			# than warping the clock) is necessary because the rival only spawns
			# after the boss dies — a clock warp alone can never reach it.
			player = Vector2(52.0, H * 0.5)
			boss_beat_this_loop = true
			start_rival()
			boss.p = Vector2(W * 0.62, H * 0.5 + 26.0)
			boss.t = 3.0
			boss.fire = 0.0
			# Reported once the run ends, so the number of completed
			# change-overs is a fact rather than an inference from a frozen
			# `fire` reading in the DBG stream.
			rival_report_at = 8.0
		"bossatk":
			# The boss parked on station at full health, so the new attack set can
			# be photographed from its first volley.
			start_boss()
			boss.p = Vector2(W * 0.775, H * 0.5)
			boss.t = 2.0
			boss.fire = 0.0
		"elite":
			# Drop the elite in immediately, in phase 2, so the denser attack set
			# and the rotating fan are both visible on the first frame.
			start_elite()
			boss.hp = int(boss.max) / 2
			boss.p = Vector2(W * 0.70, H * 0.5)
			boss.t = 2.0
		"heal":
			# Mid-regeneration: one segment missing and the delay already served,
			# so the heal pip is drawn partially filled.
			hull = HULL_MAX - 1
			heal_t = HEAL_DELAY
			heal_acc = HEAL_STEP * 0.6
			invuln = 0.0
		"death":
			# The death screen, fully settled, so the retry cue is on screen.
			hull = 1
			hurt_player()
			dead_t = 2.2
		"field":
			# One of each craft class on the field at once, each parked at a
			# readable x, so a single frame shows all three silhouettes side by
			# side. The alternates run spawn routines and would drift off their
			# rows before the capture at 3.1 s.
			for spec in [[0, 60.0, 70.0], [0, 120.0, 150.0],
					[1, 90.0, 110.0], [2, 150.0, 92.0], [2, 190.0, 140.0]]:
				var fkd: int = spec[0]
				var fp := Vector2(float(spec[1]), float(spec[2]))
				var fhp := 3 + fkd * 2
				foes.append({
					"kind": fkd, "p": fp, "speed": 1.0,
					"hp": fhp, "max": fhp,
					"ph": 0.0, "amp": 0.0, "base": fp.y, "r": 5.0 if fkd == 0 else (8.0 if fkd == 1 else 7.0),
					"fire": 0.42 if fkd > 0 else 999.0,
					"spin": 1.1 if fkd == 2 else 0.0,
					"hover": 5.0, "vy": 30.0 if fkd == 1 else -22.0,
				})
		"glyphcheck":
			# Seven reward plates, one per special tier, so a single frame
			# answers "do all seven letters draw?".
			#
			# The letter table silently drops unknown characters (see ink.gd),
			# and only printing the coverage keeps that failure from looking
			# exactly like a working feature -- the B/G/S bug survived eighteen
			# rounds precisely because the one letter that DID work was the one
			# a tester picked up by chance.
			#
			# Two rows on the LEFT of the moon, not one row across the field.
			# The moon disc covers x 164..312, and a plate on that ground is
			# only legible as an outline; more important, a plate placed within
			# 14px of the player is COLLECTED on the first frame, which silently
			# arms a tier and puts a letter in the bottom cluster -- the
			# screenshot then shows six plates and a mystery gun instead of
			# seven plates and a thesis.
			for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
				var idx: int = k - WEAPON_BOMB
				var gx := 58.0 + float(idx % 4) * 30.0
				var gy := 64.0 if idx < 4 else 148.0
				caches.append({
					"p": Vector2(gx, gy),
					"t": 0.5, "kind": k, "picked": false, "hold": true,
				})
			var report := "GLYPH"
			for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
				var gl: String = WEAPON_GLYPH[k]
				report += " %s=%d" % [gl, Ink.glyph_ok(gl)]
			print(report)
		"stock":
			# Every tier held at once, RAIL armed. The frame has to show three
			# things at the same time and they live in three different places:
			# the top-right bars (what is left), the bottom cells (loaded), the
			# tier letter (armed).
			for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
				stock[k] = int(WEAPON_RESERVE[k])
				mag[k] = int(WEAPON_MAG[k])
			# Half a reserve so the hairline under the cells lands mid-bar
			# instead of pinned full, which is the only readable position.
			stock[WEAPON_RAIL] = int(WEAPON_RESERVE[WEAPON_RAIL]) / 2
			# Two tiers emptied so "held but empty" and "armed" are both on
			# the same frame: FLAK and SWARM show as ghosts.
			stock[WEAPON_FLAK] = 0
			mag[WEAPON_FLAK] = 0
			stock[WEAPON_SWARM] = 0
			mag[WEAPON_SWARM] = 0
			_select_tier(WEAPON_RAIL)
			# The ring itself is printed, not just the armed tier: the whole
			# point of the selector is that empty tiers are SKIPPED, and only
			# the ring proves which ones the wheel will actually visit.
			var ring_report := ""
			for rk in range(WEAPON_BASE, WEAPON_LAST + 1):
				if has_rounds(rk):
					ring_report += ("%d " % rk)
			print("STOCK armed=%d mag=%d stock=%d ring=[%s]" % [
				weapon, mag[weapon], stock[weapon], ring_report,
			])
		"blast":
			# The radius/length probe. The check is not the picture -- it is the
			# printout. Two lessons are baked into this version:
			#
			# 1. GEOMETRY MUST BE MEASURED FROM THE BURST, and the burst is not
			#    where the layout put it. The shell travels 442 px/s, so on a
			#    slow frame (dt capped at 0.05) it advances up to 22px between
			#    checks and the impact lands several pixels PAST the first craft
			#    it was aimed at. An earlier version placed craft at 12/22/32
			#    from a layout origin, the shell stopped at the nearest one, and
			#    the far craft turned out to be 20px from the burst -- inside a
			#    30px radius, therefore dead, therefore "the blast kills
			#    everything". The numbers described the layout, not the radius.
			#    This version stores a reference to every probe craft and reads
			#    its REAL distance to `blast_ref` at verdict time.
			#
			# 2. DISTANCES MUST BE EXPRESSIONS OF BOMB_BLAST_R, not literals.
			#    Hardcoded 0/20/40 only describe a 30px radius; raising R to 54
			#    with those literals would still PASS (all three inside) and say
			#    nothing. Every distance below is a fraction of the constant, so
			#    the probe follows the constant.
			#
			# Layout, all on the shell's row so contact is unambiguous:
			#   0.00R  the DIRECT target, 9hp  -> must lose exactly WEAPON_DMG
			#   0.25R  splash only,        9hp  -> must lose exactly BLAST_DMG
			#   0.60R  splash, 1hp             -> must die
			#   1.30R  1hp                     -> must be untouched
			#   1.60R  1hp                     -> must be untouched
			#   +38px  1hp  ABSOLUTE           -> must die  (pins R >= 42)
			#   +50px  1hp  ABSOLUTE           -> must live (pins R <= 52)
			#
			# THE BURST POSITION IS PINNED, so there is no error budget left to
			# swallow. The shell is spawned 3px behind the direct craft, i.e.
			# already inside the 7.5px contact window (craft r 5 + 2.5), and
			# step_foes tests `b.p` BEFORE step_pb advances it -- so the very
			# first check lands and the burst is at bc - 3.0, whatever the frame
			# rate. Spawning it 28px out (the previous form) meant the round
			# advanced up to 22px per check at the dt cap and the burst could
			# land anywhere in a 25px window, which is exactly how this probe
			# managed to report PASS on a radius that had not changed.
			#
			# With the burst pinned, the groups are separated by 15..16px of true
			# margin at R = 44:
			#   0.60R -> 26.4 placed, ~29.4 from the burst, dies  (14.6 inside)
			#   1.30R -> 57.2 placed, ~60.2 from the burst, lives (16.2 outside)
			var bc := Vector2(120.0, H * 0.5)
			# speed: 0 freezes them -- with normal shard speed they drift left a
			# few px per frame and the measured distance stops matching the
			# radius the probe set (a first run reported 11.9/21.9/31.9 for
			# craft placed at 12/22/32).
			var plan: Array[Dictionary] = [
				{"tag": "direct", "f": 0.00, "hp": 9},
				{"tag": "splash", "f": 0.25, "hp": 9},
				{"tag": "in060", "f": 0.60, "hp": 1},
				{"tag": "out130", "f": 1.30, "hp": 1},
				{"tag": "out160", "f": 1.60, "hp": 1},
				# The two ABSOLUTE anchors. Fraction-based points scale with the
				# constant, so on their own they cannot fail when the constant
				# changes -- revert R to 30 and every fraction still straddles
				# 30 correctly, PASS, and the probe has certified nothing. These
				# two sit at a fixed pixel distance and therefore pin the radius
				# to a bracket from BOTH sides:
				#   38px placed -> 41 from the burst. Must DIE, so R > 41.
				#                  At the old R = 30 this craft survives -> FAIL.
				#   50px placed -> 53 from the burst. Must LIVE, so R < 53.
				#                  At R = 54 this craft would die -> FAIL.
				{"tag": "edge41", "abs": 38.0, "hp": 1},
				{"tag": "edge53", "abs": 50.0, "hp": 1},
			]
			blast_probe.clear()
			for e in plan:
				# `abs` = absolute source pixels from bc; `f` = fraction of R.
				# Both exist because they answer different questions: the
				# fractions prove the blast is coherent with its own constant,
				# the absolutes prove the constant itself is the claimed value.
				var rq: float = (float(e.abs) if e.has("abs") else float(e.f) * BOMB_BLAST_R)
				var q := bc + Vector2(rq, 0.0)
				# Keep every probe craft inside the play box even if R grows
				# again: a craft clamped off its intended distance would make
				# the verdict a lie, so the clamp is reported, not silent.
				var qx := minf(q.x, W - 8.0)
				var foe := {
					"kind": 0, "p": Vector2(qx, q.y), "speed": 0.0,
					"hp": int(e.hp), "max": int(e.hp), "ph": 0.0, "amp": 0.0,
					"base": q.y, "r": 5.0, "fire": 999.0, "spin": 0.0,
					"hover": 5.0, "vy": 0.0,
					# Identity for the verdict. Matching by position would break
					# the moment a craft is nudged; matching by tag survives both
					# removal (the tag simply stops appearing in `foes`) and
					# in-place mutation (splash writes hp on the same Dictionary
					# object that lives in the array).
					"blast_tag": String(e.tag),
				}
				foes.append(foe)
				blast_probe.append({
					"tag": String(e.tag), "f": float(e.get("f", -1.0)),
					"abs": float(e.get("abs", -1.0)),
					"hp0": int(e.hp),
					# Intent, recorded at placement. Deriving it from the tag
					# name later meant `edge53` (which must live, and lives
					# OUTSIDE) was reported as an "intended inside" overshoot
					# on a frame where nothing was wrong: the BLASTNOTE line
					# fired on a completely healthy run.
					"want_in": not (String(e.tag).begins_with("out")
						or String(e.tag) == "edge53"),
					"clamped": qx < q.x - 0.01,
				})
			_grant_tier(WEAPON_BOMB)
			_select_tier(WEAPON_BOMB)
			mag[WEAPON_BOMB] = int(WEAPON_MAG[WEAPON_BOMB])
			# The shell is placed mid-flight rather than fired, so the test does
			# not depend on where the muzzle happens to point.
			#
			# It is spawned 3px BEHIND the direct craft, i.e. ALREADY INSIDE the
			# contact window (craft r 5 + 2.5 = 7.5), so it connects on the first
			# frame's check and the burst is at a known point instead of somewhere
			# in a 25px window. The old 28px standoff let the shell advance up to
			# 22px per check at the dt cap, and that variance is how an earlier
			# version of this probe reported PASS on a radius that never changed.
			#
			# Damage comes from the TABLE, not a literal. The old probe hardcoded
			# `"dmg": 3`, so after the direct-hit raise it would have kept
			# measuring the old value and reported a delta no real shell produces.
			pb.append({
				"p": bc + Vector2(-3.0, 0.0),
				"v": Vector2(SHOT_SPEED * 0.85, 0.0),
				"len": 6.0, "dmg": int(WEAPON_DMG[WEAPON_BOMB]), "pierce": 1,
				"bomb": true, "wk": WEAPON_BOMB,
			})
			blast_ref = bc
			blast_watch = true
		"erase":
			# The wipe, photographed mid-flight.
			#
			# ERASE is the only effect in the game with a 1.1s tail, and the
			# capture at 3.1s means the probe has to fire the gauge EARLY
			# (1.2s) for the shutter to catch the sweep crossing the field.
			# A wave is placed right-to-left so the staggered disintegration is
			# legible against a known layout.
			for k in 7:
				var q := Vector2(120.0 + float(k) * 32.0, 60.0 + float(k % 3) * 44.0)
				foes.append({
					"kind": 0, "p": q, "speed": 0.0,
					"hp": 1, "max": 1, "ph": 0.0, "amp": 0.0,
					"base": q.y, "r": 5.0, "fire": 999.0, "spin": 0.0,
					"hover": 5.0, "vy": 0.0,
				})
			# Hostile fire too, so the round-burning half of the effect is
			# visible in the same frame.
			for k in 6:
				eb_add(Vector2(220.0 + float(k) * 20.0, 40.0 + float(k) * 24.0),
					Vector2(-120.0, 0.0), 1.5)
			gauge = 1.0
			# 3.02s: the shutter lands 0.08s into the wipe.
			#
			# The offset is a MEASUREMENT, not a preference. draw_rings fades
			# every ring by `a = fade²`, so at 0.32s into a 0.42s life the
			# surviving alpha is 0.057 -- the effect is present in the sim and
			# invisible on the plate, which is precisely what the first capture
			# showed: three ghost hairlines and no impact. At 0.08s the same
			# ring is at 0.65 alpha with the radius already 40% open, which is
			# the widest, brightest frame the curve ever offers.
			erase_at = 3.02
		"items":
			# The three passive plates side by side, plus the two persistent
			# ones already armed so the HUD markers are on the same frame.
			#
			# `hold` is set for the same reason glyphcheck needs it: a plate
			# within 14px of the craft is collected on the first frame and
			# silently arms a passive, so the screenshot would show two plates
			# and a mystery shield.
			item_shield = ITEM_SHIELD_CHARGES
			item_thorn = true
			var placed := PackedVector2Array([
				Vector2(70.0, 70.0), Vector2(110.0, 70.0), Vector2(150.0, 70.0),
			])
			var items: Array[int] = [ITEM_SHIELD, ITEM_THORN, ITEM_BARRAGE]
			for k in 3:
				caches.append({
					"p": placed[k], "t": 0.5, "kind": WEAPON_BOMB,
					"passive": items[k], "picked": false, "hold": true,
				})
			print("ITEMS shield=%d thorn=%s" % [item_shield, str(item_thorn)])
		"shieldhit":
			# One shielded hit, photographed mid-contract. item_shield is set
			# to 1 so the decrement is visible in the printout.
			item_shield = 1
			hurt_player()
			hit_stop = 0.0
			print("SHIELD after=%d hull=%d" % [item_shield, hull])
		"thornhit":
			# A real hit with a thorn armed, so the two feedback layers are on
			# screen together -- which is the one thing this effect must get
			# right.
			#
			# The hit is DELAYED to 3.02s, not fired in _ready. Firing at load
			# means the 3.1s shutter catches the hit's own ring already faded
			# (a = fade² puts a 0.34s ring at 0.04 alpha by then) and the
			# thorn's 0.42s rings gone entirely -- the first capture showed an
			# empty field with the kills already scored, which proves the
			# logic and shows nothing about the effect.
			item_thorn = true
			for k in 6:
				var a := TAU * float(k) / 6.0
				var q := player + Vector2(30.0, 0.0).rotated(a)
				foes.append({
					"kind": 0, "p": q, "speed": 0.0,
					"hp": 1, "max": 1, "ph": 0.0, "amp": 0.0,
					"base": q.y, "r": 5.0, "fire": 999.0, "spin": 0.0,
					"hover": 5.0, "vy": 0.0,
				})
			hurt_at = 3.02
			# And the HUD marker has to survive the blast: item_thorn is set
			# here and CLEARED inside hurt_player, so by the time the shutter
			# opens the tick has already vanished. The probe therefore arms the
			# thorn AGAIN at 3.10s -- the HUD then shows it armed on the same
			# frame as the blast it just spent itself on. That state cannot
			# occur in play; it exists only to prove the marker draws at all.
			rearm_at = 3.08
		"barrage":
			# Nine craft spread across the field, then the barrage. The printout
			# is the verdict: exactly ceil(9/2)=5 must die, and they must be the
			# five FURTHEST RIGHT.
			#
			# Delayed like thornhit, for the same reason: the column of impacts
			# has to land in the shutter's first tenth, not in _ready.
			for k in 9:
				var q := Vector2(120.0 + float(k) * 26.0, 56.0 + float(k % 3) * 40.0)
				foes.append({
					"kind": 0, "p": q, "speed": 0.0,
					"hp": 1, "max": 1, "ph": 0.0, "amp": 0.0,
					"base": q.y, "r": 5.0, "fire": 999.0, "spin": 0.0,
					"hover": 5.0, "vy": 0.0,
				})
			barrage_at = 3.02
		"fullarea":
			# Only meaningful together with HALFMOON_DIR; the position itself is
			# reported by HALFMOON_DBG (px=/py=). This arm exists so the run does
			# not have to hand-drive for eight seconds to reach the corner.
			player = Vector2(RIGHT_LIMIT - 40.0, H * 0.5)
			print("FULLAREA start px=%.1f limit=%.1f" % [player.x, RIGHT_LIMIT])
	sync_backdrop()


func sync_backdrop() -> void:
	if backdrop != null and backdrop.has_method("set_moon"):
		backdrop.set_moon(boss.is_empty())


# Single entry point for screen shake. Strength adds up to a cap, the age resets
# so every hit restarts the decay, and the kick direction points away from the
# blow. Keeping one door means the feel stays consistent across every event.
func add_shake(amount: float, from_point := Vector2.INF) -> void:
	var before := shake
	shake = minf(shake + amount, 14.0)
	if shake > before:
		shake_age = 0.0
		shake_seed = rng.randf() * TAU
		if from_point != Vector2.INF:
			var d := player - from_point
			if d.length() > 0.5:
				shake_dir = d.normalized()
			else:
				shake_dir = Vector2(-1.0, 0.0)
		elif before <= 0.0:
			shake_dir = Vector2(-1.0, 0.0)


# Kept out of _process's hot path: called once per frame after the sim step.
func feed_backdrop(dt: float) -> void:
	if backdrop != null and backdrop.has_method("step"):
		backdrop.step(lag, dt)


func reset() -> void:
	t = 0.0
	hull = HULL_MAX
	score = 0
	gauge = 0.0
	invuln = 1.0
	dead = false
	dead_t = 0.0
	loop_n = 1
	boss = {}
	flash = 0.0
	shake = 0.0
	player = Vector2(52.0, H * 0.5)
	fire_t = 0.0
	pb.clear()
	eb.clear()
	foes.clear()
	sparks.clear()
	rings.clear()
	spawn_t = 0.8
	erase_t = 0.0
	# Everything the new systems added has to be cleared here too. A miss in
	# reset() is invisible in a fresh launch and shows up as "the second run
	# starts with a laser" or "the second run already spawned the elite".
	vel = Vector2.ZERO
	hull_yaw = 0.0
	hull_roll = 0.0
	wing_flap = 0.0
	trail_w = 0.0
	lag = Vector2.ZERO
	cooldown = 0.0
	cannon = 0
	trigger = false
	shot_pulse = 0.0
	hit_t = 0.0
	kill_t = 0.0
	hit_stop = 0.0
	weapon = WEAPON_BASE
	# The armoury has to be rebuilt from empty, not merely re-selected. A stale
	# `stock[]` would hand the next run a SPREAD that was earned in the previous
	# one -- the exact class of bug the comment above warns about.
	for k in range(0, WEAPON_LAST + 1):
		mag[k] = 0
		stock[k] = 0
	mag[WEAPON_BASE] = int(WEAPON_MAG[WEAPON_BASE])
	stock[WEAPON_BASE] = -1
	# Passive items clear on a fresh run. A shield carried into the next run
	# would be the third time a per-run system leaked across `reset()`.
	item_shield = 0
	item_thorn = false
	wheel_pending = 0
	reloading = false
	reload_t = 0.0
	reload_len = 0.0
	kill_streak = 0
	streak_t = 0.0
	caches.clear()
	heal_t = 0.0
	heal_acc = 0.0
	elite_done = false
	# The elite's loop gate has to be re-armed too, and this line was missing.
	#
	# `elite_done = false` alone looks like a full reset, but the gate is a
	# separate variable: start_elite() sets elite_next_loop = loop_n + 2, and
	# step_elite_clock only spawns while loop_n <= elite_next_loop. So a run that
	# died on loop 5 left the gate at 7, and the next run 鈥?which starts at loop 1
	# 鈥?passed the gate on loops 1, 2 and 3, spawning an elite on every loop
	# instead of every second one. A restart silently changed the difficulty.
	elite_next_loop = ELITE_EVERY
	# Rival stage: the flag, the promotion gate and the loop gate all have to go
	# back to their start values, for the same reason the elite gate does above.
	# `boss_beat_this_loop` in particular: leave it true and a fresh run starts
	# with the duel armed, so the twin flies in before the player has met the
	# boss at all.
	rival_done = false
	rival_next_loop = 1
	boss_beat_this_loop = false
	paused = false
	esc_held = false
	# Clearing the chain is enough: step_player rebuilds it lazily when it finds
	# `bones` empty (see the flame skeleton block).
	bones.clear()
	bones_vel.clear()


func _process(dt: float) -> void:
	dt = minf(dt, 0.05)

	# ---- pause ----------------------------------------------------------
	# Edge-triggered, because polling is_key_pressed would flip the flag every
	# frame while ESC is held. Everything below is skipped entirely, so `t`
	# freezes and nothing in the world advances 闂?the pause is a real stop,
	# not a slowed sim.
	#
	# The CRT shader keeps running (grain, shimmer, flicker are TIME-driven).
	# That is deliberate: the tube is a display, not part of the world, and a
	# static CRT frame would look broken rather than paused.
	var esc_now := Input.is_key_pressed(KEY_ESCAPE)
	if esc_now and not esc_held:
		paused = not paused
	esc_held = esc_now
	if paused:
		# Wheel input is dropped while paused, not banked. A notch rolled during
		# a pause would otherwise fire on the first frame after unpausing, and
		# the player would read it as a random tier change.
		wheel_pending = 0
		queue_redraw()
		return

	# ---- breathing heal -------------------------------------------------
	# Runs before the hit-stop / dead early-returns so that time spent in a
	# hit-stop still counts as "not being hit". The delay only cares about
	# damage, and damage resets it in hurt_player().
	step_heal(dt)

	# Hit-stop: a few frames of near-frozen time on impact. This is what makes
	# a blow land 闂?the world pauses for it. Gameplay clocks keep running on the
	# frozen frame, so nothing drifts out of sync.
	if hit_stop > 0.0:
		hit_stop = maxf(0.0, hit_stop - dt)
		hit_t = maxf(0.0, hit_t - dt)
		kill_t = maxf(0.0, kill_t - dt)
		flash = maxf(0.0, flash - dt * 2.0)
		shake_age += dt
		shake = maxf(0.0, shake - dt * 26.0)
		queue_redraw()
		return

	if dead:
		dead_t += dt
		flash = maxf(0.0, flash - dt * 2.4)
		shake_age += dt
		shake = maxf(0.0, shake - dt * 20.0)
		step_sparks(dt)
		step_rings(dt)
		step_caches(dt)
		capture_tick(dt)
		wheel_pending = 0
		# R restarts, but also any of the fire keys, so the reflex that failed
		# to dodge does something useful instead of replaying the death screen.
		if dead_t > 0.6 and (Input.is_key_pressed(KEY_R)
			or Input.is_key_pressed(KEY_X) or Input.is_key_pressed(KEY_Z)
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
			reset()
		queue_redraw()
		return

	t += dt
	shot_pulse = maxf(0.0, shot_pulse - dt / 0.12)
	flash = maxf(0.0, flash - dt * 3.2)
	shake_age += dt
	shake = maxf(0.0, shake - dt * 24.0)
	invuln = maxf(0.0, invuln - dt)
	erase_t = maxf(0.0, erase_t - dt)
	hit_t = maxf(0.0, hit_t - dt)
	kill_t = maxf(0.0, kill_t - dt)
	# ---- wheel, consumed once -------------------------------------------
	# One notch is one tier change. Consuming here rather than inside
	# step_player keeps the selector out of the movement code, and clearing the
	# flag unconditionally means a notch can never survive into a later frame
	# and fire on its own.
	if wheel_pending != 0:
		_cycle_tier(wheel_pending)
		wheel_pending = 0
	# ---- injected ERASE -------------------------------------------------
	# Real seconds, not game time: the probe is photographing a moment, and
	# the shutter is on the wall clock. Fires once, then disarms.
	if erase_at > 0.0:
		erase_at -= dt
		if erase_at <= 0.0:
			do_erase()
	# ---- injected passive-item probes ------------------------------------
	# Same wall-clock countdown as erase_at, and the same argument: the shutter
	# is on real seconds, so a probe aimed at a specific visual moment has to
	# be scheduled in real seconds too.
	if hurt_at > 0.0:
		hurt_at -= dt
		if hurt_at <= 0.0:
			hurt_player()
			print("THORN armed=%s hull=%d" % [str(item_thorn), hull])
	if barrage_at > 0.0:
		barrage_at -= dt
		if barrage_at <= 0.0:
			var before := foes.size()
			trigger_barrage()
			print("BARRAGE before=%d after=%d" % [before, foes.size()])
	if rearm_at > 0.0:
		rearm_at -= dt
		if rearm_at <= 0.0:
			# See the thornhit probe for why this second arm exists: the marker
			# must be visible on the same frame the blast is.
			item_thorn = true
	if rival_report_at > 0.0:
		rival_report_at -= dt
		if rival_report_at <= 0.0:
			print("RIVAL reloads=%d mag=%d tier=%d hp=%d" % [
				rival_reloads, int(boss.get("mag", -1)),
				int(boss.get("tier", -1)),
				(int(boss.hp) if not boss.is_empty() else -1),
			])
	step_streak(dt)
	step_reload(dt)

	step_player(dt)
	step_fire(dt)
	step_spawn(dt)
	step_elite_clock(dt)
	step_boss(dt)
	# Contact damage lives OUTSIDE step_boss because that function returns from
	# six different branches (empty slot, elite takeover, boss takeover, rival,
	# entrance, on-station). Putting the check at each return point is six
	# chances to miss one, and the missed one would be the boss the player can
	# actually reach.
	_check_major_contact()
	step_foes(dt)
	step_pb(dt)
	step_eb(dt)
	step_caches(dt)
	step_sparks(dt)
	step_rings(dt)
	_report_blast()
	capture_tick(dt)
	feed_backdrop(dt)
	if OS.get_environment("HALFMOON_DBG") != "" and t > 1.0:
		# mag / stock / px / py are appended rather than interleaved: every
		# existing probe script greps `wpn=` and reads to the end of the line,
		# and a field inserted mid-string would silently break them.
		print("DBG t=%.2f foes=%d pb=%d eb=%d boss=%s hp=%s fire=%.2f cache=%d wpn=%d rings=%d arrive=%.2f mag=%d stock=%d px=%.1f py=%.1f" % [
			t, foes.size(), pb.size(), eb.size(),
			("elite" if boss.has("is_elite") else ("boss" if not boss.is_empty() else "-")),
			(str(int(boss.get("hp", -1)) if not boss.is_empty() else "-")),
			(float(boss.get("fire", -1.0)) if not boss.is_empty() else -1.0),
			caches.size(), weapon, rings.size(),
			float(boss.get("arrive", 0.0)),
			mag[weapon], stock[weapon], player.x, player.y,
		])
	queue_redraw()


# ---- breathing heal -------------------------------------------------------
func step_heal(dt: float) -> void:
	heal_t += dt
	if hull >= HULL_MAX:
		# Full: keep the timer at the threshold so the first hit after a long
		# healthy stretch still costs the full delay. Without this the timer
		# would keep growing and the next hit would heal instantly.
		heal_t = maxf(heal_t, HEAL_DELAY)
		heal_acc = 0.0
		return
	if heal_t < HEAL_DELAY:
		return
	heal_acc += dt
	if heal_acc < HEAL_STEP:
		return
	heal_acc -= HEAL_STEP
	hull += 1
	# Visual: one paper ring at the hull, under the bloom gate so it does not
	# light the glow pass.
	rings.append({"c": player, "r0": 4.0, "r1": 22.0, "r": 4.0, "t": 0.0, "w": 1.0, "life": 0.34})
	flash = maxf(flash, 0.10)


# ---- kill streak -----------------------------------------------------------
func step_streak(dt: float) -> void:
	if kill_streak <= 0:
		return
	streak_t += dt
	if streak_t > STREAK_WINDOW:
		kill_streak = 0
		streak_t = 0.0


func note_kill(at: Vector2, tough: float) -> void:
	# Called from the kill path. `tough` 0..1 scales how much the streak counts
	# a kill for: a shard is 1, a coil is 1.5, the elite 3, the boss 6.
	streak_t = 0.0
	kill_streak += maxi(1, int(round(tough)))
	if kill_streak >= STREAK_STEP:
		kill_streak -= STREAK_STEP
		_spawn_cache(at)
		return
	# ---- second source: rare direct drop ---------------------------------
	# The first build only dropped from the streak counter, which meant every
	# cache came at the same rhythm and the only other source was the elite 闁?	# so a player who never reached 8 kills in 2.2 s (i.e. a defensive player)
	# never saw a single weapon. A small flat chance on every kill makes the
	# drop unpredictable instead of metronomic, and rewards aggressive play
	# without locking the systems behind it.
	if rng.randf() < CACHE_DROP_CHANCE:
		_spawn_cache(at)


func _spawn_cache(at: Vector2) -> void:
	# Cap on how many can WAIT on the field, not on how many one event may drop.
	# The first version truncated the array itself to two, so the boss's three
	# caches silently became two and the oldest was destroyed before the player
	# ever saw it.
	var waiting := 0
	for c in caches:
		if float(c.t) < 6.0:
			waiting += 1
	if waiting >= 4:
		return
	# Never spawn past the frame edge 闂?a cache that lands outside the border is
	# unreachable.
	var x := clampi(int(at.x), int(FRAME.position.x) + 12, int(FRAME.end.x) - 12)
	var y := clampi(int(at.y), int(FRAME.position.y) + 12, int(FRAME.end.y) - 12)
	# ---- what this cache carries -----------------------------------------
	# One roll decides between a passive item and a weapon tier, then the
	# remaining cases fall to the armoury.
	#
	# Rolled in ITEM order, and each is a SEPARATE `randf()`, not a shared
	# cumulative threshold. Two reasons:
	#
	#   1. a shared threshold makes the later odds depend on the earlier ones,
	#      so tuning the shield's rate silently retunes the barrage's -- and
	#      the code stops showing what the numbers mean;
	#   2. the three are meant to read as "common / rare / very rare" in play,
	#      and the only way to verify that is to be able to point at one
	#      constant per item.
	#
	# `passive` is the field the pickup path reads. It is ITEM_NONE for every
	# weapon cache, which is what `_grant_tier` already ignores -- so a weapon
	# cache has NO extra field and behaves exactly as before.
	var passive := ITEM_NONE
	var roll := rng.randf()
	if roll < ITEM_CHANCE_SHIELD:
		passive = ITEM_SHIELD
	elif roll < ITEM_CHANCE_SHIELD + ITEM_CHANCE_THORN:
		passive = ITEM_THORN
	elif roll < ITEM_CHANCE_SHIELD + ITEM_CHANCE_THORN + ITEM_CHANCE_BARRAGE:
		passive = ITEM_BARRAGE
	caches.append({
		"p": Vector2(float(x), float(y)),
		"t": 0.0,
		"kind": CACHE_POOL[rng.randi_range(0, CACHE_POOL.size() - 1)],
		"passive": passive,
		"picked": false,
	})


# ---- armoury queries -------------------------------------------------------
#
# Every decision about ammunition goes through these three, so there is no
# second place that can disagree about what "empty" means.
func cur_mag() -> int:
	return mag[weapon]


func cur_stock() -> int:
	return stock[weapon]


func has_rounds(kind: int) -> bool:
	# The base gun is constant by construction: its stock is -1 (no reservoir)
	# and its magazine is the only budget it has, but an empty base magazine
	# refills itself, so the tier is never unavailable.
	if int(WEAPON_RESERVE[kind]) < 0:
		return true
	return mag[kind] > 0 or stock[kind] > 0


# ---- tier selection --------------------------------------------------------
#
# `_select_tier` is what the wheel and the pigeonhole probes both call. It
# refuses an empty tier rather than arming a gun that cannot fire: a selector
# that can land on a dead weapon is worse than no selector, because the player
# then has to work out why the trigger does nothing.
func _select_tier(kind: int) -> void:
	if kind == weapon:
		return
	if not has_rounds(kind):
		return
	# A change-over does NOT survive a tier change. Keeping `reload_t` would
	# let the player bank progress on a long reload, switch away, come back and
	# find it nearly done -- which is a free magazine. Clearing it costs one
	# full reload for the new tier, which is the same rule the tier change
	# always had before the selector existed.
	reloading = false
	reload_t = 0.0
	reload_len = 0.0
	weapon = kind


# Wheel step. `dir` is +1 forward, -1 back.
#
# The ring is built fresh each time from the tiers that can actually fire, plus
# the base gun which always can. Building it from state rather than keeping an
# index means there is no cached list to go stale when a tier is picked up or
# runs dry mid-session.
func _cycle_tier(dir: int) -> void:
	var ring: Array[int] = [WEAPON_BASE]
	for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
		if has_rounds(k):
			ring.append(k)
	# One candidate special: the wheel would otherwise spin on the spot and
	# read as broken input.
	if ring.size() <= 2:
		return
	var at := ring.find(weapon)
	# The current tier is not in the ring, which happens for exactly one frame
	# when the last round of the last magazine is spent. Land on base first.
	if at < 0:
		at = 0
	var n := ring.size()
	var nxt := (at + dir + n) % n
	# Never step onto the tier already armed -- with one special in the ring the
	# modulo can point back at it, and the HUD would appear frozen.
	if ring[nxt] == weapon:
		nxt = (nxt + dir + n) % n
	_select_tier(ring[nxt])


# Called by boot.gd, which owns the only input surface that receives events.
func queue_wheel(dir: int) -> void:
	# Clamp rather than accumulate: two wheel notches inside one frame are
	# indistinguishable from one at 60 fps, and letting them stack would make a
	# fast flick jump four tiers.
	wheel_pending = dir if wheel_pending == 0 else wheel_pending


# ---- reload ----------------------------------------------------------------
#
# One place owns the reload state, so `reloading`, `reload_t` and the loaded
# count can never drift apart. The HUD reads those three; it does not run its
# own timer.
func step_reload(dt: float) -> void:
	if not reloading:
		return
	reload_t += dt
	if reload_t < reload_len:
		return
	_finish_reload()


func _begin_reload() -> void:
	if reloading:
		return
	# Nothing to load: an empty reservoir cannot be reloaded, so the tier simply
	# ends and the base gun takes over. That is what makes the reservoir a real
	# budget rather than a formality.
	if int(WEAPON_RESERVE[weapon]) >= 0 and stock[weapon] <= 0:
		_fall_back_to_base()
		return
	reloading = true
	reload_t = 0.0
	reload_len = float(WEAPON_RELOAD[weapon])


func _finish_reload() -> void:
	weapon_loaded()
	reloading = false
	reload_t = 0.0
	reload_len = 0.0
	# Out of ammunition entirely: fall back to the base gun. Done after the
	# refill so the base magazine starts full.
	if int(WEAPON_RESERVE[weapon]) >= 0 and stock[weapon] <= 0 and mag[weapon] <= 0:
		_fall_back_to_base()


# The refill itself, split out so the pickup path can arm a fresh tier with the
# SAME arithmetic the reload path uses. Two implementations of "fill a magazine
# from a reservoir" is how a partial load ends up costing the wrong number of
# rounds in one of the two places.
func weapon_loaded() -> void:
	var want: int = int(WEAPON_MAG[weapon])
	if int(WEAPON_RESERVE[weapon]) >= 0:
		# Pull from the reservoir. A partial load is legal: a tier that has 5
		# rounds left fills to 5, not to a full magazine it cannot pay for.
		var take: int = mini(want, stock[weapon])
		mag[weapon] = take
		stock[weapon] -= take
	else:
		mag[weapon] = want


func _fall_back_to_base() -> void:
	reloading = false
	reload_t = 0.0
	reload_len = 0.0
	weapon = WEAPON_BASE
	mag[WEAPON_BASE] = int(WEAPON_MAG[WEAPON_BASE])


# A pickup. Renamed from equip_weapon: equipping is now a decision the player
# makes, and picking a cache up is not one.
func _grant_tier(kind: int) -> void:
	# Stock stacks without a ceiling, which is the point of a cache-based
	# armoury: a second BOMB cache must be worth having, not worth nothing.
	stock[kind] += int(WEAPON_RESERVE[kind])
	# Arm it now if it is the only thing the player has, or if what they ARE
	# holding has just run dry. Never yank a loaded special out of their hands:
	# a pickup that re-guns you mid-fight reads as an input glitch.
	if weapon == WEAPON_BASE or not has_rounds(weapon):
		_select_tier(kind)
	if mag[kind] <= 0 and stock[kind] > 0:
		# Load it the moment it becomes useful rather than making the player
		# pay a change-over for something they just collected. Uses the reload
		# tier's own duration only when it is actually armed.
		if weapon == kind:
			_begin_reload()
		else:
			var take: int = mini(int(WEAPON_MAG[kind]), stock[kind])
			mag[kind] = take
			stock[kind] -= take


# ---- caches ----------------------------------------------------------------
func step_caches(dt: float) -> void:
	var i := caches.size() - 1
	while i >= 0:
		var c := caches[i]
		c.t = float(c.t) + dt
		var life := float(c.t)
		# `hold` freezes a cache in place and makes it unpickable. Only probes
		# set it: a plate laid out for a screenshot would otherwise be dragged
		# to the craft by the magnet, collected, and silently arm a tier before
		# the shutter opens -- the frame then shows six plates and a gun nobody
		# asked for. It is read here and nowhere else, which is the only reason
		# it is allowed to exist at all.
		if bool(c.get("hold", false)):
			i -= 1
			continue
		# Magnetise toward the player after 1.4 s, and drift while waiting so a
		# stationary cache still reads as a live object.
		if life > 1.4:
			var to_p := (player - (c.p as Vector2))
			if to_p.length() > 0.5:
				c.p = (c.p as Vector2) + to_p.normalized() * minf(70.0, to_p.length() * 5.0) * dt
		if player.distance_to(c.p as Vector2) < 14.0:
			# ---- ONE pickup path, two kinds of payload -------------------
			# A cache carries either a weapon tier or a passive item, never
			# both. Branching on `passive` here rather than giving passives
			# their own array keeps magnetise, the grab radius, the expiry and
			# the `hold` probe escape in ONE place -- see the header of
			# ITEM_NONE for why a second array would drift.
			var passive := int(c.get("passive", ITEM_NONE))
			var pc: Vector2 = c.p as Vector2
			if passive == ITEM_NONE:
				_grant_tier(int(c.kind))
				add_shake(1.2, pc)
				rings.append({"c": pc, "r0": 3.0, "r1": 20.0, "r": 3.0, "t": 0.0, "w": 1.0, "life": 0.18})
			else:
				_grant_item(passive, pc)
			caches.remove_at(i)
			i -= 1
			continue
		# Expire: a cache nobody collects must not sit there forever.
		if life > 6.0:
			caches.remove_at(i)
		i -= 1


func capture_tick(dt: float) -> void:
	if not cap_on:
		return
	cap_accum += dt
	if cap_n >= CAP_TIMES.size():
		return
	# CAP_TIMES are absolute seconds since _ready, so an fx injected at load
	# can be photographed on its very first frame.
	if cap_accum >= float(CAP_TIMES[cap_n]):
		call_deferred("grab_shot")


func grab_shot() -> void:
	if cap_n >= CAP_TIMES.size():
		return
	# Capture the root window, not this SubViewport: we want to verify what the
	# player actually sees, CRT shader included.
	var img := get_tree().root.get_texture().get_image()
	if img == null:
		return
	img.save_png("user://shots/shot_%d.png" % cap_n)
	cap_n += 1
	if cap_n >= CAP_TIMES.size():
		printerr("CAPTURE_DONE")
		get_tree().quit()


# ---------------------------------------------------------------- simulation

func step_player(dt: float) -> void:
	var dir := Vector2.ZERO
	# Verification hook: HALFMOON_DIR=up|down|left|right drives the stick for
	# the whole run so the four hull poses can be photographed without a human
	# hand on the keyboard. Read every frame rather than cached, so the variable
	# stays a pure input override and leaves no state behind.
	match OS.get_environment("HALFMOON_DIR"):
		"up": dir = Vector2(0.0, -1.0)
		"down": dir = Vector2(0.0, 1.0)
		"left": dir = Vector2(-1.0, 0.0)
		"right": dir = Vector2(1.0, 0.0)
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	focus_on = Input.is_key_pressed(KEY_SHIFT)
	# Trigger: Space fires, but Space also arms ERASE when the gauge is full.
	# ERASE wins over shooting, so the player never accidentally spends a full
	# gauge on a wasted shot 闂?the button does the bigger thing first.
	trigger = (Input.is_key_pressed(KEY_X) or Input.is_key_pressed(KEY_Z)
		or Input.is_key_pressed(KEY_J) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))
	if cap_on and OS.get_environment("HALFMOON_AUTO") != "":
		trigger = true
	if Input.is_key_pressed(KEY_SPACE):
		if gauge >= 1.0:
			do_erase()
		else:
			trigger = true

	# Inertia: acceleration toward the input vector, drag when released.
	# Focus tightens both, so it feels like a precision brake, not a swap.
	var target := dir.normalized() * (FOCUS_SPEED if focus_on else SPEED)
	var acc := ACCEL_FOCUS if focus_on else ACCEL
	if dir.length() <= 0.0:
		acc = BRAKE_FOCUS if focus_on else BRAKE
	vel = vel.lerp(target, 1.0 - exp(-acc * dt))
	player += vel * dt

	player.x = clampf(player.x, LEFT_LIMIT, RIGHT_LIMIT)
	player.y = clampf(player.y, TOP_LIMIT, BOTTOM_LIMIT)

	# ---- directional animation ------------------------------------------
	# Three separate channels, because the craft needs to answer three
	# different questions with three different parts of its body:
	#
	#   yaw   vertical input  -> nose pitch AND wing tips rising/falling
	#   roll  horizontal input -> wing sweep AND canopy slide
	#   flap  total deflection -> engine thrust flare, wing fold amplitude
	#
	# The upward and downward speeds are deliberately asymmetric: gravity
	# fights a climb and helps a dive, so the nose lifts slower than it
	# drops. That asymmetry is what reads as weight rather than as a slider.
	hull_yaw = lerpf(hull_yaw, clampf(-vel.y / SPEED, -1.0, 1.0),
		1.0 - exp(-(7.5 if vel.y < 0.0 else 10.0) * dt))
	hull_roll = lerpf(hull_roll, clampf(vel.x / SPEED, -1.0, 1.0),
		1.0 - exp(-11.0 * dt))
	# Flap follows the input error rather than the velocity, so it peaks while
	# the craft is CHANGING direction and settles once it is on course. A
	# velocity-driven flap would stay pinned at maximum during a held climb and
	# the wings would stop breathing.
	var deflect := Vector2(clampf(vel.x / SPEED, -1.0, 1.0),
		clampf(vel.y / SPEED, -1.0, 1.0)).length()
	wing_flap = lerpf(wing_flap, clampf(deflect, 0.0, 1.0), 1.0 - exp(-14.0 * dt))

	# Engine trail strength follows speed, so drifting leaves a longer wake.
	trail_w = lerpf(trail_w, clampf(vel.length() / SPEED, 0.0, 1.0), 1.0 - exp(-8.0 * dt))

	# ---- flame skeleton ------------------------------------------------
	# A verlet-style chain, not a single offset point. Bone 0 is pinned to the
	# nozzle; every later bone is pulled toward the one before AND toward its
	# own rest position behind it. That is what makes the plume trail: the
	# nozzle always matches the hull exactly (so it never detaches), while the
	# far bones lag behind and overshoot, giving the whip.
	if bones.is_empty():
		bones.clear()
		bones_vel.clear()
		for i in BONE_COUNT:
			bones.append(player + Vector2(-9.0 - float(i) * 3.4, 0.0))
			bones_vel.append(Vector2.ZERO)
	# Bone 0 is pinned AND its velocity is pinned.
	bones[0] = player + Vector2(-9.0, 0.0)
	bones_vel[0] = vel

	# The rest direction leans with the hull's motion, not just straight back.
	# Pure -X rest is why vertical movement produced no lag at all: the spring
	# target never moved vertically, so the chain snapped back to horizontal
	# within two frames and the plume read as rigid while the ship went up and
	# down. `lean` translates the ship's vertical velocity into a trailing angle,
	# so climbing leaves the flame hanging low and diving pulls it up.
	var lean := clampf(-vel.y / SPEED, -1.0, 1.0) * 0.55

	for i in range(1, BONE_COUNT):
		var prev := bones[i - 1]
		# Each bone's rest slot points backward with a share of the lean. Later
		# bones lean more, which is what makes the tail whip rather than the
		# whole plume tilting as one rigid rod.
		var share := float(i) / float(BONE_COUNT - 1)
		var slot := Vector2(-3.4, lean * 3.4 * share)
		var rest := prev + slot

		var cur := bones[i]
		# Softer and softer toward the tail. The old 20.0 was stiff enough that
		# the chain matched the nozzle within a couple of frames 闂?no lag, no
		# whip, which is exactly the "no vertical follow" the user reported.
		var stiff := 11.0 - float(i) * 1.4
		var damp := 7.5 - float(i) * 0.85
		var v: Vector2 = bones_vel[i]
		v += (rest - cur) * stiff * dt
		# Gravity-ish drag: the tail always sags a hair, which reads as weight.
		v.y += 5.0 * share * dt
		v *= 1.0 - clampf(damp * dt, 0.0, 0.85)
		cur += v * dt
		# Hard cap on how far a bone may stray from its rest slot. Without this
		# a fast diagonal dash stretches the chain until it is longer than the
		# screen and the flame vanishes.
		var off := cur - rest
		var reach := 6.0
		if off.length() > reach:
			cur = rest + off.normalized() * reach
			v *= 0.3
		bones_vel[i] = v
		bones[i] = cur

	# Screen-space micro lag: the field shifts a hair against the motion.
	lag = lag.lerp(-vel * 0.035, 1.0 - exp(-10.0 * dt))


func step_fire(dt: float) -> void:
	# Cooldown model: a timer that always drains, but the trigger is what gates
	# the shot. Holding fire gives a steady cadence; tapping gives exactly one
	# round; releasing lets the cooldown finish while idle.
	cooldown = maxf(0.0, cooldown - dt)
	if not trigger:
		return
	# A reload outranks the trigger: holding fire through a change-over must
	# not skip the refill, and it must not fire a shot either.
	if reloading:
		return
	if cooldown > 0.0:
		return
	# Empty magazine: start the change-over and swallow this trigger pull.
	# Doing it BEFORE the cooldown check means the reload begins on the same
	# frame the last round is spent, not one frame later.
	if mag[weapon] <= 0:
		_begin_reload()
		return
	cooldown = float(WEAPON_CD[weapon])
	cannon = 1 - cannon
	# One trigger pull = one round, regardless of how many pellets the tier
	# throws. A SPREAD or FLAK volley still costs a single round.
	mag[weapon] -= 1
	shot_pulse = 1.0

	var dmg: int = int(WEAPON_DMG[weapon])
	# Muzzle points come from the WINGS, not the centreline.
	#
	# They used to be `player + Vector2(8, 卤3)`, i.e. 3px above and below the
	# fuselage axis, and the firing craft drew nothing there 鈥?so the rounds
	# visibly left from mid-air just past the nose. Two things were wrong: the
	# offset was a hardcoded guess that had no relation to the hull geometry, and
	# it did not follow the wings when they folded.
	#
	# wing_muzzle() reads the SAME body-space transform the hull is drawn with,
	# so a climbing craft fires from raised tips and a focused craft (wings
	# tucked) fires from a narrow pair. The hardpoint is the wingtip itself,
	# which is where the render already draws a solid mass.
	var muzzle := wing_muzzle(player, 1.0)

	if weapon == WEAPON_SPREAD:
		# CLUSTER: three pellets that BURST ON CONTACT.
		#
		# 2026-11-09: "再加强一下霰弹（最开始做的那个），强化为集束弹，击中敌人后
		# 再向四周霰射 3 枚伤害较低的子弹".
		#
		# That changes what the tier IS. It used to be "three pellets, useful
		# only at close range because at range one connects" -- a strict
		# downgrade of BASE outside its sweet spot. Now a pellet that CONNECTS
		# becomes a small burst point, so the tier pays off twice: once for
		# closing the distance, and once for hitting something inside a group.
		#
		# The child rounds are spawned in step_foes with `frag: true` so they
		# cannot spawn children of their own -- a pellet that bursts into
		# pellets that burst is a chain reaction, not a shotgun.
		for k in 3:
			var a := deg_to_rad((float(k) - 1.0) * 11.0)
			pb.append({
				"p": muzzle,
				"v": Vector2(SHOT_SPEED, 0.0).rotated(a),
				"len": 3.0,
				"dmg": 1,
				"pierce": 1,
				"cluster": true,
				"wk": WEAPON_SPREAD,
			})
		return

	if weapon == WEAPON_LASER:
		# A single piercing needle.
		#
		# Damage dropped 2 -> 1 on 2026-11-09 ("减少穿透弹的伤害，现在太超模了") and
		# pierce went 2 -> 3 at the same time, i.e. the shots it DOES pass through
		# went from two to three craft while each of them takes half. Against one
		# body that is 3.85 DPS (0.73x of base) instead of 7.7; against a column
		# of three it is 11.5. The tier stops being the answer to every question
		# and becomes the answer to one: shoot a line.
		pb.append({
			"p": muzzle,
			"v": Vector2(SHOT_SPEED * 1.15, 0.0),
			"len": 9.0,
			"dmg": dmg,
			"pierce": 3,
			"laser": true,
			"wk": WEAPON_LASER,
		})
		return

	if weapon == WEAPON_FLAK:
		# Five pellets over a 48-degree fan: twice SPREAD's spread with twice
		# its pellets, at a slower cadence and with a shorter reach.
		#
		# The tier's identity is not the fan, though -- it is what happens on
		# contact. A connecting pellet seeds FLAK_SHRED_DMG onto up to three
		# bodies inside FLAK_SHRED_R, so aiming INTO a cluster wounds all of it.
		# SPREAD rewards closing distance with one body; FLAK rewards aiming at
		# the middle of a group. Same family, opposite question.
		for k in 5:
			var a := deg_to_rad((float(k) - 2.0) * 12.0)
			pb.append({
				"p": muzzle,
				"v": Vector2(SHOT_SPEED * 0.92, 0.0).rotated(a),
				"len": 2.5,
				"dmg": 1,
				"pierce": 1,
				"flak": true,
				"wk": WEAPON_FLAK,
			})
		return

	if weapon == WEAPON_RAIL:
		# One heavy rod. Pierce 3, a 0.62 s cadence -- the slowest trigger in
		# the game. It is the only round whose weight is carried by LENGTH
		# (12 px) rather than by the tail, so at a glance it reads as a solid
		# object crossing the field rather than a tracer.
		#
		# DAMAGE 3 -> 2 on 2026-11-09 ("继续削穿甲弹的伤害，建议砍半").
		#
		# Literal halving is 1.5, and this is an integer damage system, so the
		# only two real candidates were 2 and 1. 1 was rejected on arithmetic:
		# pierce 3 x 1 damage is 3 total, which is strictly WORSE than BASE's
		# single-target 5.26 DPS while costing a 0.62 s cadence and a 6-round
		# magazine -- the tier would stop being a tier. 2 gives 6 total across
		# a full column, i.e. 1.14x BASE's single-target output, and 0.38x of
		# the old 3-per-pierce. That is "roughly halved" in practice without
		# deleting the tier.
		#
		# The tier's identity stays pierce, not damage: it is the only round
		# that pays off for lining craft up.
		pb.append({
			"p": muzzle,
			"v": Vector2(SHOT_SPEED * 1.25, 0.0),
			"len": 12.0,
			"dmg": dmg,
			"pierce": 3,
			"rail": true,
			"wk": WEAPON_RAIL,
		})
		return

	if weapon == WEAPON_SWARM:
		# Two darts, each allowed a LIMITED number of steering events (see
		# step_pb). Speed raised 0.80 -> 1.45 of SHOT_SPEED on 2026-11-09: the
		# tier's problem was that a dart which has to correct could not catch
		# anything it had already passed.
		#
		# COUNT 3 -> 2 on 2026-11-09 ("把追踪弹的一发三颗变成两颗").
		#
		# The fan is now built around TWO darts instead of three, and that
		# changes the angles, not just the loop bound. A 3-dart fan spread
		# (-9, 0, +9) has a centre dart; with two there is no centre, so the
		# pair is offset symmetrically at (+/-4.5) to keep the volley centred
		# on the aim line. Reusing the old angles with a bound of 2 would fire
		# (-9, 0) -- both darts on the same side of where the player aimed.
		#
		# `lane` still numbers the darts 0..1, and step_pb picks the lane-th
		# nearest target, so the two still split across two different craft.
		for k in 2:
			var a := deg_to_rad((float(k) - 0.5) * 9.0)
			pb.append({
				"p": muzzle,
				"v": Vector2(SHOT_SPEED * 1.45, 0.0).rotated(a),
				"len": 3.0,
				"dmg": 2,
				"pierce": 1,
				"homing": SWARM_TURNS,
				"home_t": 0.0,
				"lane": k,
				"wk": WEAPON_SWARM,
			})
		return

	if weapon == WEAPON_BOMB:
		pb.append({
			"p": muzzle,
			"v": Vector2(SHOT_SPEED * 0.85, 0.0),
			"len": 6.0,
			"dmg": dmg,
			"pierce": 1,
			"bomb": true,
			"wk": WEAPON_BOMB,
		})
		return

	# Base tier and MG alternate BETWEEN THE WINGS; MG simply fires much more
	# often because WEAPON_CD drives the cadence above.
	#
	# The side is `cannon`, which was already being flipped once per round for
	# this purpose 鈥?it just had nothing but a 6px y-offset to flip, so the
	# alternation was invisible. Now each round physically leaves from the tip
	# that is drawn on that side, so the twin-gun rhythm is the hull's own
	# animation instead of an abstract counter.
	var side := -1.0 if cannon == 0 else 1.0
	# Slight outward toe, so the two barrels converge rather than fire two
	# parallel laser-straight lines. Focused fire is dead straight: the tier's
	# whole point is precision, and a converging pair would spray.
	var tilt := 0.0 if focus_on else -side * 1.2
	pb.append({
		"p": wing_muzzle(player, side),
		"v": Vector2(SHOT_SPEED, 0.0).rotated(deg_to_rad(tilt)),
		"len": 5.0 if focus_on else 3.0,
		"dmg": dmg,
		"pierce": 1,
		"wk": weapon,
	})


func step_spawn(dt: float) -> void:
	if not boss.is_empty():
		return
	spawn_t -= dt
	if spawn_t > 0.0:
		return
	spawn_wave()
	# Interval tightens with the clock AND the loop. The old `t * 0.004` term
	# only bought 0.2s across a whole loop, so pacing never changed; 0.010 makes
	# the last third visibly denser. The floor stays at 0.62 because with waves
	# of up to three craft a 0.42 floor produced ~7 arrivals per second, which
	# stops being a shmup and becomes a wall.
	# Spawn cadence, eased.
	#
	# Was max(0.62, 1.55 - loop*0.10 - t*0.010): by t=45 s that sat on the 0.62
	# floor with three craft per wave, i.e. ~4.8 craft per second arriving into
	# a 384 px field. The floor was raised to 0.78 and the two ramp rates cut
	# roughly in half, so the late game stays dense without turning into a wall:
	# at t=45 s, loop 1, the interval is 1.10 s instead of 0.62 s 闂?a 44% cut
	# in arrivals for the same wave size.
	# Spawn cadence, eased again 鈥?this time the whole curve was lifted, not just
	# the floor.
	#
	# At 0.78/1.55 the late game was still one wave every 0.9 s with up to three
	# craft in it. Measured against the field, that is 3.3 craft/second arriving
	# into 384 px, which the player cannot clear even with a full magazine 鈥?
	# surviving depended on dodging rather than on shooting, and the run stopped
	# feeling like a shmup.
	#
	# New floor 1.05 and a shallower ramp: at t=45 s, loop 1, the interval is
	# 1.30 s instead of 0.98 s, roughly a 25% cut in arrivals for the same wave
	# size. The floor is what matters most: it is the value the last third of
	# every loop sits on.
	spawn_t = maxf(1.05, 1.70 - float(loop_n) * 0.05 - t * 0.004)


func spawn_wave() -> void:
	# Difficulty ladder, expressed as "what is allowed to exist right now".
	#
	# The old version picked a random kind and only special-cased the first few
	# seconds, so a run felt identical at 5s and at 45s: one craft every ~1.4s
	# of the same two types. Now the roster opens up over time and the wave size
	# grows with both the clock and the loop, so the last ten seconds before the
	# boss are always the loudest part of the loop.
	# ---- the ladder -------------------------------------------------------
	# Two separate things ramp, and they used to ramp on the same clock, which is
	# why the curve felt like a wall at t鈮?6 s rather than a slope:
	#
	#   ROSTER  which craft may appear. Opens once per third of the loop.
	#   COUNT   how many arrive at once. This is the brutal one 鈥?it multiplies
	#           with the roster, so unlocking the coil and doubling the wave on
	#           the same second is a step, not a ramp.
	#
	# They are now staggered: the roster opens at 12/26, and the wave grows at
	# 34 and again only on later loops. The single hardest frame of the curve is
	# therefore a +1 craft, not a +1 craft of the worst type at the same time.
	var kinds: Array[int] = [0]
	if t > 12.0:
		kinds.append(1)
	if t > 26.0:
		kinds.append(2)
	# The second drift craft is a WEIGHT, not a new kind: it makes kind 1 twice
	# as likely, which raises aimed fire without raising the ceiling.
	if t > 40.0:
		kinds.append(1)

	var count := 1
	if t > 34.0:
		count += 1
	# Loop scaling is gentler: +1 per loop after the first, capped at 2 total.
	count += clampi(loop_n - 1, 0, 1)
	# Three is the ceiling. At the 1.05 s floor, three arrivals is ~2.9 craft per
	# second, which is already dense; four was a curtain.
	count = mini(count, 3)

	# Spread the wave vertically so a multi-craft spawn does not arrive as one
	# solid wall the player cannot thread.
	var span := H - 64.0
	var step := span / float(count)
	for n in count:
		var y := 32.0 + step * (float(n) + 0.5) + rng.randf_range(-step * 0.22, step * 0.22)
		y = clampf(y, 30.0, H - 30.0)
		var kind: int = kinds[rng.randi_range(0, kinds.size() - 1)]
		if kind == 0:
			foe_shard(y)
		elif kind == 1:
			foe_drift(y)
		else:
			foe_coil(y)


func foe_shard(y: float) -> void:
	foes.append({
		"kind": 0,
		"p": Vector2(SPAWN_X, y),
		"speed": 86.0 + float(loop_n) * 5.0,
		# 2 HP at loop 1, then +1 every two loops instead of one every loop. A
		# shard is the trash mob of the roster and it stopped being disposable
		# around loop 3, when it took four shots with a 0.19s cooldown while
		# four of them were already on screen.
		"hp": 1 + int(ceil(float(loop_n) * 0.5)),
		"max": 1 + int(ceil(float(loop_n) * 0.5)),
		# ph = 0 so the weave starts ON the spawn row. A random phase offsets y
		# by up to amp on the very first frame, which reads as the craft
		# appearing off its intended lane 闂?see foe_coil for the full argument.
		"ph": 0.0,
		"amp": rng.randf_range(9.0, 20.0),
		"base": y,
		"r": 5.0,
		"fire": 999.0,
		"spin": 0.0,
	})


func foe_drift(y: float) -> void:
	foes.append({
		"kind": 1,
		"p": Vector2(SPAWN_X, y),
		"speed": 39.0 + float(loop_n) * 3.0,
		# 5 base, +1 every two loops (was +2 every loop). The drift craft fires
		# every 1.75 s and its whole job is area denial, so it must not also be
		# a bullet sponge.
		"hp": 4 + loop_n,
		"max": 4 + loop_n,
		# Kind 1's weave is driven by `t`, which starts at 0 for every run, so a
		# random ph is harmless there and is kept for variety.
		"ph": rng.randf() * TAU,
		"amp": 8.0,
		"base": y,
		"r": 8.0,
		"fire": 1.2,
		"spin": 0.0,
	})


func foe_coil(y: float) -> void:
	foes.append({
		"kind": 2,
		"p": Vector2(SPAWN_X, y),
		"speed": 66.0,
		# 6 base, +1 every two loops (was +2 every loop). The coil parks and
		# fires three-way spreads, so it already taxes the player's attention;
		# its 7 + 2(loop-1) pool meant a mid-run coil ate a third of the gauge.
		"hp": 5 + loop_n,
		"max": 5 + loop_n,
		# ph = 0, not random.
		#
		# Kind 2's weave now runs from the spawn frame (see step_foes), so a
		# random phase would offset y by up to amp at the instant of creation 闂?
		# the craft would materialise up to 21 px off its own spawn row, which
		# is the same teleport the branch fix was meant to remove, just moved to
		# t = 0 instead of t = 2. sin(0) = 0 keeps the entry continuous.
		"ph": 0.0,
		"amp": 18.0,
		"base": y,
		"r": 7.0,
		"fire": 1.0,
		"spin": 0.0,
		"hover": W * 0.72,
	})


func step_boss(dt: float) -> void:
	if boss.is_empty():
		# ---- loop order: elite → boss → rival ---------------------------
		# The three majors are staged, not clocked independently.
	 #
		# `beat_boss` rewinds `t` to BOSS_AT - 18..34 s so the next loop starts
		# sooner; a plain `if t >= RIVAL_AT` check would then never fire, because
		# the rewind lands BELOW BOSS_AT and the boss re-arms first. So the
		# rival is owned by a flag rather than by a clock reading: the boss
		# completing is what promotes the loop into its duel stage.
		#
		# Order, per loop: elite (26 s) → boss (52 s) → rival (~78 s). The rival
		# never shares the field with the boss, matching the spawn rule above.
		if rival_done == false and boss_beat_this_loop:
			rival_done = true
			start_rival()
			return
		if t >= BOSS_AT:
			start_boss()
		return
	# The boss OUTRANKS the elite.
	#
	# Both live in the `boss` slot so only one major enemy exists at a time, but
	# priority matters: when the boss clock arrives, whatever elite is still on
	# the field is retired and the boss takes over. The previous version had no
	# such rule, so an ignored elite blocked the boss indefinitely and the boss
	# was never constructed at all — which the player experienced as "the boss
	# has no attacks".
	if boss.has("is_elite"):
		if t >= BOSS_AT:
			var old: Vector2 = boss.p
			boss = {}
			puff(old, 10)
			start_boss()
			return
		step_elite(dt)
		return
	if boss.has("is_rival"):
		step_rival(dt)
		return
	var bt: float = float(boss.t) + dt
	boss.t = bt
	var bp: Vector2 = boss.p
	var target := W * 0.775
	# Entrance moves at a fixed SPEED, not a fixed step per frame.
	#
	# `bp.x - 54.0 * dt` looks frame-rate independent and is not: it is
	# 54 * dt per frame, so the pixels-per-SECOND figure is 54 only if dt is
	# the real delta. Under the dump probe the frame time balloons to ~0.13 s,
	# the clamp in _process caps dt at 0.05, and the boss then crawls in at 8 px/s
	# instead of 54 闁?a 13 s entrance instead of 2 s. On screen that is
	# indistinguishable from "the boss has no attacks", because it never reaches
	# the attack branch at all.
	#
	# The fix is to close the gap toward the target with an exponential ease on
	# TIME, which is stable at any frame rate and also reads better: the boss
	# decelerates into position instead of stopping dead.
	if bp.x > target + 1.0:
		var nx: float = lerpf(bp.x, target, 1.0 - exp(-3.2 * dt))
		boss.p = Vector2(maxf(target, nx), bp.y)
		return
	boss.p = Vector2(target, H * 0.5 + sin(bt * 0.72) * H * 0.26)
	var frac := float(boss.hp) / float(boss.max)
	boss.fire = float(boss.fire) - dt
	if float(boss.fire) <= 0.0:
		# ---- attack rotation -------------------------------------------
		# Each phase owns a fixed ORDER, and within it a rotating cursor, so the
		# fight has a rhythm the player can learn without it becoming a pattern
		# they can ignore. A pure "pick a random move" boss reads as noise: the
		# player never gets to feel clever, they just get unlucky.
		#
		# The old code always fired the SAME combination per phase, which meant
		# the entire 30-second fight contained exactly three distinct moments.
		var step_i := int(boss.get("atk_i", 0))
		boss.atk_i = step_i + 1
		var ln := float(loop_n)
		if frac > 0.66:
			# Phase 1: readable singles. Teach the vocabulary.
			match step_i % 4:
				0:
					boss_ring(12, 135.0 + ln * 6.0)
					boss.fire = 2.05 - ln * 0.05
				1:
					boss_fan(5, 150.0)
					boss.fire = 1.85 - ln * 0.05
				2:
					boss_snipe()
					boss.fire = 1.70 - ln * 0.05
				_:
					boss_sweep(4, 142.0 + ln * 5.0)
					boss.fire = 1.95 - ln * 0.05
		elif frac > 0.33:
			# Phase 2: combinations that overlap. Pairs force sequencing.
			match step_i % 4:
				0:
					boss_ring(8, 118.0)
					boss_fan(5, 150.0)
					boss.fire = 1.60 - ln * 0.05
				1:
					boss_twin_ring(7, 126.0 + ln * 5.0)
					boss.fire = 1.75 - ln * 0.05
				2:
					boss_rain(4)
					boss_snipe()
					boss.fire = 1.65 - ln * 0.05
				_:
					boss_spiral(3)
					boss_sweep(3, 138.0)
					boss.fire = 1.55 - ln * 0.05
		else:
			# Phase 3: everything, but the recovery stays long enough to survive.
			#
			# A frantic final phase is the conventional choice and it is wrong
			# here: this palette has no red, no health flash, and no screen shake
			# big enough to signal panic. Density is the ONLY signal available,
			# so it has to stay survivable 鈥?the pressure comes from the
			# variety, not from the rate.
			match step_i % 5:
				0:
					boss_twin_ring(9, 145.0 + ln * 5.0)
					boss.fire = 1.45 - ln * 0.05
				1:
					boss_rain(5)
					boss_fan(7, 165.0)
					boss.fire = 1.50 - ln * 0.05
				2:
					boss_lure(3, 158.0 + ln * 5.0)
					boss.fire = 1.55 - ln * 0.05
				3:
					boss_spiral(4)
					boss_sweep(4, 152.0)
					boss.fire = 1.40 - ln * 0.05
				_:
					boss_ring(14, 150.0)
					boss_snipe()
					boss.fire = 1.50 - ln * 0.05
	boss.tick = float(boss.tick) - dt
	if float(boss.tick) <= 0.0:
		boss.tick = 0.85
		var aim := (player - bp).normalized()
		eb_add(bp, aim * (155.0 + float(loop_n) * 5.0), 2.0)
	boss.hurt = maxf(0.0, float(boss.hurt) - dt)
	step_chip(dt)
	step_telegraph(dt)


func step_telegraph(dt: float) -> void:
	# Aimed-shot warning fades out over 0.24 s. Its only job is to be gone
	# before the round arrives 鈥?a line that outlives its bullet reads as a
	# persistent hazard and the player dodges a thing that no longer exists.
	if not boss.has("telegraph"):
		return
	var tg: Dictionary = boss.telegraph
	tg.t = float(tg.t) + dt
	if float(tg.t) > 0.24:
		boss.erase("telegraph")
	else:
		boss.telegraph = tg


func step_chip(dt: float) -> void:
	# The impact chip is a decaying timestamp, not an effect list. One chip per
	# body is enough: two shells landing in the same frame should not stack
	# visible bites on a 28 px disc.
	if not boss.has("chip"):
		return
	var ch: Dictionary = boss.chip
	ch.t = float(ch.t) + dt
	if float(ch.t) > 0.20:
		boss.erase("chip")
	else:
		boss.chip = ch


func start_boss() -> void:
	# Health eased twice over: base 190 -> 165, and the per-loop ramp 62 -> 42.
	# The boss is a 30-second damage check, and at 190 it asked for ~52 hits with
	# a 0.19 s cooldown while the player was also dodging three-way spreads 闂?
	# which read as "the fight will not end" rather than as "the fight is hard".
	var hp := 165 + 42 * (loop_n - 1)
	# Enter from just outside the frame, not from 55 px beyond it. The boss has
	# r = 28, so starting at SPAWN_X + 28 puts its leading edge exactly on the
	# border: it slides in from behind the frame line instead of being drawn
	# floating in the empty margin outside the picture.
	boss = {
		"p": Vector2(SPAWN_X + 28.0, H * 0.5),
		"hp": hp, "max": hp,
		"t": 0.0, "fire": 1.7, "tick": 0.6,
		"r": 28.0, "hurt": 0.0, "ph": 0.0,
	}
	add_shake(2.5)
	sync_backdrop()


func boss_ring(n: int, sp: float) -> void:
	var bp: Vector2 = boss.p
	var base := float(boss.t) * 0.6
	for i in n:
		var a := base + TAU * float(i) / float(n)
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.5)


func boss_fan(n: int, sp: float) -> void:
	var bp: Vector2 = boss.p
	var aim := (player - bp).normalized().angle()
	for i in n:
		var a := aim + (float(i) - float(n - 1) * 0.5) * 0.18
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.4)


func boss_spiral(n: int) -> void:
	var bp: Vector2 = boss.p
	var ph: float = float(boss.ph) + 0.44
	boss.ph = ph
	for i in n:
		var a := ph + TAU * float(i) / float(n)
		eb_add(bp, Vector2(102.0, 0.0).rotated(a), 1.4)


# ---- boss attack vocabulary (second pass) -----------------------------------
#
# The first build had three moves 鈥?ring, fan, spiral 鈥?and they all shared one
# property: a full volley leaves at once from the centre of the body. That makes
# every phase feel the same to dodge (step sideways, wait), so the three phases
# read as "faster, not different".
#
# The five below each require a DIFFERENT answer from the player, which is what
# makes a boss fight legible as a sequence rather than as a metronome:
#
#   snipe     one fast aimed round with a telegraph line 鈥?reads as a threat
#   sweep     a continuous angular march 鈥?punishes standing still
#   rain      vertical columns from above 鈥?punishes hugging one lane
#   twin_ring two counter-rotating rings 鈥?punishes a single dodge direction
#   lure      rounds that fly straight, then turn toward the player 鈥?punishes
#             predicting the initial direction

func boss_snipe() -> void:
	# Aimed shot with a telegraph, so the threat is visible before it arrives.
	# Without the line this is indistinguishable from a stray bullet of any other
	# volley 鈥?and a bullet with no read is just a random hit.
	var bp: Vector2 = boss.p
	var aim := (player - bp).normalized()
	rings.append({"c": bp, "r0": 3.0, "r1": 5.0, "r": 3.0, "t": 0.0, "w": 1.0, "life": 0.22})
	# Telegraph: a dashed ray along the firing direction, drawn by rings? No 鈥?
	# rings are circles. The line lives in `boss.telegraph`, see draw_boss.
	boss.telegraph = {"p": bp, "d": aim, "t": 0.0}
	eb_add(bp, aim * 215.0, 2.4)


func boss_sweep(n: int, sp: float) -> void:
	# A marching fan: each volley fires `n` rounds, and the fan's centre angle
	# advances between volleys. Consecutive fans cover different sectors, so the
	# safe gap moves and the player has to follow it instead of parking.
	var bp: Vector2 = boss.p
	var ph: float = float(boss.ph) + 0.30
	boss.ph = ph
	var base := PI + ph
	for i in n:
		var a := base + (float(i) - float(n - 1) * 0.5) * 0.13
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.5)


func boss_rain(cols: int) -> void:
	# Vertical drops from above the field, not from the body.
	#
	# Firing these from the boss would make them yet another radial spray. Coming
	# down from the top edge instead forces the player to read the whole column
	# rather than only the disc 鈥?different information, different dodge.
	for i in cols:
		var x := FRAME.position.x + 24.0 + (FRAME.size.x - 48.0) * float(i) / maxf(1.0, float(cols - 1))
		var jitter := rng.randf_range(-7.0, 7.0)
		eb_add(Vector2(floorf(x + jitter), FRAME.position.y - 6.0), Vector2(0.0, 128.0), 1.6)


func boss_twin_ring(n: int, sp: float) -> void:
	# Two rings, opposite directions, different speeds. A single ring always has
	# the same safe gap on the same side; counter-rotation makes the gap sweep
	# past the player twice per volley.
	var bp: Vector2 = boss.p
	var ph: float = float(boss.ph) + 0.5
	boss.ph = ph
	for i in n:
		var a := ph + TAU * float(i) / float(n)
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.5)
	for i in n:
		var a2 := -ph * 1.35 + TAU * float(i) / float(n)
		eb_add(bp, Vector2(sp * 0.72, 0.0).rotated(a2), 1.3)


func boss_lure(n: int, sp: float) -> void:
	# Straight-flying rounds that become aimed after a delay.
	#
	# The turn happens in step_eb via `lure_t`. This is the one attack that
	# punishes "predict where it started": a player who dodges the launch
	# direction is still hit when the round bends back.
	var bp: Vector2 = boss.p
	var aim := (player - bp).normalized().angle()
	for i in n:
		var a := aim + (float(i) - float(n - 1) * 0.5) * 0.22
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.5)
		eb[eb.size() - 1]["lure_t"] = 1.15
		eb[eb.size() - 1]["lure_sp"] = sp * 0.85


# ---- rival: the real enemy craft -------------------------------------------
#
# A boss that is the PLAYER, mirrored.
#
# This is the one boss in the game that is not a shape on a clock: it flies the
# player's own hull, moves like the player, and shoots at the player's own
# cadence. Everything about it is copied on purpose, because the point of the
# fight is confrontation rather than spectacle 鈥?you are fighting your own
# silhouette, and it is as fast and as accurate as you are.
#
# What is deliberately NOT copied:
#
#   * it never changes weapon tier. Tier-swapping would make the mirror
#     unreadable: the player would have to identify which gun the twin is
#     holding before they could predict its rhythm.
#   * it does not focus-brake. Focus exists to let a human thread a gap; an AI
#     using it looks like it is hesitating.
#   * its health is a pool, not 3 hearts. Hearts would mean three hits ends it,
#     which either trivialises the fight or forces absurd damage numbers.
#
# SPAWN RULE: while the rival is alive, `step_spawn` returns early, so the
# field stays empty except for the two craft. That is the whole design 鈥?a duel
# needs a clear field, and adds would turn every bullet read into a two-body
# problem.
const RIVAL_AT := 78.0          # third boss of the loop
# HP dropped 90 -> 55, and the per-loop step 26 -> 16.
#
# The duel was the longest fight in the game (a 90 HP twin taking 1-damage BASE
# rounds at 5.3/s is ~17 seconds of perfect tracking) while the twin shot back
# the entire time. Length is not difficulty in a mirror match -- it is just
# exposure, and every extra second is another chance for the player to be
# clipped by a round they had already read. Shortening it also makes the
# duel's identity clearer: it is a sharp exchange, not an endurance test.
const RIVAL_HP := 55
const RIVAL_HP_STEP := 16

# ---- the twin's arsenal ------------------------------------------------------
#
# Its rounds travel slower than the player's. A player round is aimed at a
# scripted dodge; the twin's is aimed at a human who has to SEE it, decide, and
# move. At SHOT_SPEED (520) a round crosses the field in 0.7s, which is inside
# human reaction time when the screen is already busy.
const HOSTILE_SHOT_SPEED := 300.0
# Volleys per special-tier magazine. Small on purpose: the duel must not be
# decided by a tier the PLAYER is not holding, so the twin's specials are short
# bursts between stretches of base fire.
const HOSTILE_MAG := 4

# ---- the twin reloads --------------------------------------------------------
#
# 2026-11-09: "让他也来换弹冷却". The twin used to fire without pause, which
# made it the only thing in the game with no cost model -- the player pays a
# magazine and a change-over for every round, and the mirror is supposed to be
# a mirror.
#
# RIVAL_MAG counts VOLLEYS, the same way the player's magazine counts trigger
# pulls rather than pellets. 6 volleys at BASE's 0.19 s cadence is ~1.1 s of
# fire, then a 1.6 s change-over: 41% uptime. That is the whole nerf -- the
# duel is no longer "when do I get to shoot", it is "when is he reloading".
const RIVAL_MAG := 6
const RIVAL_RELOAD := 1.6

# ---- the twin's aim ----------------------------------------------------------
#
# "降低子弹精度". A perfect aiming AI cannot be juked: every round it fires is
# a round the player must already have moved for, so the only counter is to
# never stop, and the fight stops rewarding reading. Per-volley angular error
# makes the twin BEATABLE by movement rather than only by distance.
#
# 0.11 rad is ~6.3 degrees. At the duel's ~200-250 px standoff that is a 22-28
# px lateral offset, i.e. roughly one hull width -- wide enough that a standing
# target is missed about half the time, narrow enough that a stationary player
# still gets hit often enough to respect it.
#
# The error is rolled PER VOLLEY, not per round, so a BOMB shell is off by one
# angle rather than scattering; and it is applied in `_fire_rival_volley` so
# every tier inherits it without a second code path.
const RIVAL_AIM_ERROR := 0.11

var rival_done := false
var rival_next_loop := 1
# Set when the loop's boss dies. It is what promotes the loop into the duel
# stage — see the loop-order comment in step_boss for why a clock cannot do it.
var boss_beat_this_loop := false


func start_rival() -> void:
	rival_done = true
	rival_next_loop = loop_n + 1
	var hp := RIVAL_HP + RIVAL_HP_STEP * (loop_n - 1)
	boss = {
		# Enters from the right at the player's own cruise height, so the first
		# thing the player sees is a mirror of themselves at the same altitude.
		"p": Vector2(SPAWN_X + 10.0, player.y),
		"hp": hp, "max": hp,
		"t": 0.0, "fire": 0.0, "tick": 0.0,
		"r": 13.0, "hurt": 0.0, "ph": 0.0,
		# Mirror state. These are the same channels the player's drawing reads,
		# so `draw_rival` can call the player's own transform helpers unchanged.
		"vel": Vector2(-SPEED * 0.7, 0.0),
		"yaw": 0.0, "roll": 0.0, "flap": 0.0, "trail": 0.0,
		"cannon": 0,
		# ---- the twin's arsenal state -----------------------------------
		# The mirror flies the player's own tier table (see _fire_rival_volley).
		# `shots` is how many volleys it has left of the current tier and
		# `tier` is which tier that is; _cycle_rival_tier owns both.
		"tier": WEAPON_BASE, "shots": HOSTILE_MAG,
		# Reload state, mirroring the player's three fields exactly:
		# `mag` volleys left before the change-over, `reloading` a bool, and
		# `reload_t` counting UP to RIVAL_RELOAD. Same shape as the player's
		# own, because the twin is supposed to be read as a mirror and a
		# different reload model would need a different explanation.
		"mag": RIVAL_MAG, "reloading": false, "reload_t": 0.0,
		# Focus state, driven by the same "am I at my station?" test the
		# player's Shift answers. Read by draw_rival to tuck the wings.
		"focus": false,
		"is_rival": true,
	}


func step_rival(dt: float) -> void:
	var bt: float = float(boss.t) + dt
	boss.t = bt
	var bp: Vector2 = boss.p

	# ---- mirror movement: the PLAYER'S OWN CONTROL LAW -------------------
	# "优化真敌机的行为逻辑 ... 全部仿照主控战机来".
	#
	# The previous version chased a target point with `v.lerp(dir*spd, ...)`,
	# where spd was capped by distance. That is a PD chase, not the player's
	# controller, and it reads as an AI: it arrives at the target and STOPS,
	# it has no momentum, and it never overshoots.
	#
	# step_player does something different and it is the thing being mirrored:
	#   vel = vel.lerp(dir.normalized() * SPEED, 1 - exp(-ACCEL * dt))
	#   player += vel * dt
	# i.e. velocity chases a CONSTANT-SPEED target vector, so the craft always
	# carries momentum, always overshoots slightly, and needs a beat to settle.
	# Same constants, same brake, same focus brake.
	#
	# The rival also flies the SAME bounds as the player (LEFT_LIMIT.. RIGHT_LIMIT,
	# TOP_LIMIT.. BOTTOM_LIMIT) instead of hovering at a fixed x. Now that the
	# air wall is gone on the player's side, a rival that cannot use the field
	# would be the only craft in the game with a wall -- which is the exact
	# asymmetry a mirror fight must not have.
	#
	# Its lane target drifts on a slow sine so the duel is not a stalemate at
	# identical altitude, and it keeps a standoff distance from the player
	# rather than ramming: two craft with contact damage flying the same law
	# would otherwise decide the fight by collision.
	var lane := sin(bt * 0.55) * 30.0
	var standoff := 58.0
	# The rival mirrors the player laterally: it sits standoff px to the RIGHT
	# of the player, so the fight stays a duel instead of both craft orbiting
	# the same column.
	var tgt_x := clampf(player.x + standoff, LEFT_LIMIT, RIGHT_LIMIT)
	var tgt_y := clampf(player.y + lane, TOP_LIMIT, BOTTOM_LIMIT)
	var want := Vector2(tgt_x, tgt_y)
	var dir := want - bp
	# The rival's own focus state: it brakes when it is close to its station,
	# which is what the player does with Shift to thread a gap.
	var focusing := dir.length() < 40.0
	var target_v := dir.normalized() * (FOCUS_SPEED if focusing else SPEED)
	if dir.length() < 6.0:
		target_v = Vector2.ZERO
	var acc := ACCEL_FOCUS if focusing else ACCEL
	if dir.length() < 6.0:
		acc = BRAKE_FOCUS if focusing else BRAKE
	var v: Vector2 = boss.vel
	v = v.lerp(target_v, 1.0 - exp(-acc * dt))
	boss.vel = v
	bp += v * dt
	# Same clamp the player gets, so neither craft can leave the field.
	bp.x = clampf(bp.x, LEFT_LIMIT, RIGHT_LIMIT)
	bp.y = clampf(bp.y, TOP_LIMIT, BOTTOM_LIMIT)
	boss.p = bp

	# Bank / yaw / flap: the player's own smoothing constants. `focusing`
	# narrows the wings the same way, so a focusing rival visibly tucks.
	boss.roll = lerpf(float(boss.roll), clampf(v.x / SPEED, -1.0, 1.0), 1.0 - exp(-11.0 * dt))
	boss.yaw = lerpf(float(boss.yaw), clampf(-v.y / SPEED, -1.0, 1.0),
		1.0 - exp(-(7.5 if v.y < 0.0 else 10.0) * dt))
	boss.flap = lerpf(float(boss.flap),
		clampf(Vector2(clampf(v.x / SPEED, -1.0, 1.0),
			clampf(v.y / SPEED, -1.0, 1.0)).length(), 0.0, 1.0),
		1.0 - exp(-14.0 * dt))
	boss.trail = lerpf(float(boss.trail), clampf(v.length() / SPEED, 0.0, 1.0), 1.0 - exp(-8.0 * dt))
	boss.focus = focusing

	# ---- mirror fire: the player's arsenal, WITH a change-over -----------
	#
	# "子弹和射击模式全部仿照主控战机来" then "让他也来换弹冷却". The twin
	# now runs the SAME tier table AND the same magazine shape, because a twin
	# that fires without pause is the only object in the game with no cost
	# model.
	#
	# The reload is checked BEFORE the cooldown, in the same order the player's
	# step_fire uses: a change-over outranks the trigger, and holding fire
	# through it must not skip it.
	var rt := float(boss.get("reload_t", 0.0))
	if bool(boss.get("reloading", false)):
		rt += dt
		boss.reload_t = rt
		# Probe pin: see `reload_pin`. Applied AFTER the count so the value the
		# drawer reads is the pinned one on every frame, not just the first.
		if reload_pin > 0.0:
			boss.reload_t = reload_pin
			boss.reloading = true
			boss.mag = 0
			boss.hurt = maxf(0.0, float(boss.hurt) - dt)
			step_chip(dt)
			return
		# The wings tuck while it is reloading, so the change-over is legible
		# from the silhouette rather than only from the missing fire.
		if rt >= RIVAL_RELOAD:
			boss.reloading = false
			boss.reload_t = 0.0
			boss.mag = RIVAL_MAG
			rival_reloads += 1
		else:
			boss.hurt = maxf(0.0, float(boss.hurt) - dt)
			step_chip(dt)
			return
	boss.fire = float(boss.fire) - dt
	if float(boss.fire) <= 0.0 and bp.x < RIGHT_LIMIT - 4.0:
		var tier := int(boss.get("tier", WEAPON_BASE))
		boss.fire = float(WEAPON_CD[tier])
		boss.cannon = 1 - int(boss.cannon)
		var side := -1.0 if int(boss.cannon) == 0 else 1.0
		# SAME hull transform the player fires from, but driven by the RIVAL'S
		# OWN yaw/roll, not by the globals.
		#
		# `wing_muzzle(p, side)` reads `hull_yaw` and `hull_roll` -- the PLAYER's
		# state -- so calling it here would place the twin's muzzle according to
		# a craft on the other side of the screen. The two lead helpers take the
		# angle as an ARGUMENT, which is exactly why they are usable here: the
		# muzzle lands on the rival's own visible wingtip, whichever way it is
		# currently leaning.
		var body_ang := float(boss.yaw) * 0.13 - float(boss.roll) * 0.04
		var muzzle: Vector2
		if side < 0.0:
			muzzle = (_fin_lead(bp, body_ang)[0] as Vector2) + Vector2(-1.0, 0.0)
		else:
			muzzle = (_ventral_lead(bp, body_ang)[0] as Vector2) + Vector2(-1.0, 0.0)
		var aim := (player - muzzle).normalized()
		# AIM ERROR, rolled once per volley. See RIVAL_AIM_ERROR for the
		# arithmetic. Applied to `aim` rather than inside the volley builder so
		# every tier inherits one rule instead of three.
		aim = aim.rotated(rng.randf_range(-RIVAL_AIM_ERROR, RIVAL_AIM_ERROR))
		_fire_rival_volley(tier, muzzle, aim)
		# The magazine decrements per VOLLEY, like the player's per trigger
		# pull. Running dry starts the change-over on the same frame the last
		# round leaves, exactly as step_fire does.
		boss.mag = int(boss.get("mag", RIVAL_MAG)) - 1
		# Same for the tier's own shot budget. Both counters tick per volley,
		# and whichever hits zero FIRST forces the change-over -- otherwise
		# `shots` (4) would run out before `mag` (6), the tier would rotate,
		# and _cycle_rival_tier would refill the magazine. `mag` would then
		# never reach zero and the twin would never reload, which is exactly
		# what happened on the first run of this change: no reload appeared in
		# a 12-second log.
		boss.shots = int(boss.get("shots", 0)) - 1
		if int(boss.mag) <= 0 or int(boss.shots) <= 0:
			boss.reloading = true
			boss.reload_t = 0.0
		if int(boss.shots) <= 0:
			_cycle_rival_tier()

	boss.hurt = maxf(0.0, float(boss.hurt) - dt)
	step_chip(dt)


# Volleys the twin puts in the air for one trigger pull, by tier.
#
# ONLY THREE tiers are reachable: BASE, BOMB, MG. Everything past those is
# single-target or cluster work (LASER pierce, RAIL pierce, FLAK shred, SWARM
# homing), and an AI holding any of them stops being a mirror and becomes a
# damage source the player cannot answer -- there is no dodge for a round that
# is already inside your hitbox. `_cycle_rival_tier` enforces the same three, so
# the branches below are the whole reachable space and the `_` arm is a
# defensive default rather than a fourth tier.
func _fire_rival_volley(tier: int, muzzle: Vector2, aim: Vector2) -> void:
	var spd := HOSTILE_SHOT_SPEED
	var base_ang := aim.angle()
	var shots: Array = []
	match tier:
		WEAPON_MG:
			shots.append([base_ang, 1])
		WEAPON_BOMB:
			shots.append([base_ang, 1])
		_:
			# BASE, plus any tier that somehow reaches here.
			shots.append([base_ang, 1])
	for sh in shots:
		var a := float(sh[0])
		var dmg := int(sh[1])
		var mv := Vector2(spd, 0.0).rotated(a)
		eb_add(muzzle, mv, 1.4)
		var last: Dictionary = eb[eb.size() - 1]
		last["wk"] = tier
		last["dmg"] = dmg
		# The one tier whose round is HEAVIER gets a fatter body so the player
		# can read "that one hurts more" before it arrives. A 1px dot at
		# HOSTILE_SHOT_SPEED is not enough warning for a 5-damage shell.
		if tier == WEAPON_BOMB:
			last.r = 2.4


# Tier rotation for the twin: BASE, BOMB, MG -- and nothing past MG.
#
# The rotation is fixed rather than derived from the player's own stock. A twin
# that only ever fires what the player happens to be holding cannot be tuned:
# its difficulty would swing with the RNG of the drop table. A fixed three-tier
# rotation is identical in every run, so the duel is a known quantity.
func _cycle_rival_tier() -> void:
	var ring: Array[int] = [WEAPON_BASE, WEAPON_BOMB, WEAPON_MG]
	var at := ring.find(int(boss.get("tier", WEAPON_BASE)))
	if at < 0:
		at = 0
	var nxt := (at + 1) % ring.size()
	boss.tier = ring[nxt]
	boss.shots = HOSTILE_MAG
	# A tier change refills the magazine, the same way the player's
	# _select_tier clears the change-over rather than carrying it across.
	#
	# It does NOT clear `reloading`: the rotation happens on the same frame the
	# change-over starts (see the caller), so clearing the flag here would
	# cancel the reload it had just triggered. The reload finishes on its own
	# timer and refills `mag` to RIVAL_MAG then.
	boss.mag = RIVAL_MAG


func beat_rival() -> void:
	var bp: Vector2 = boss.p
	boss = {}
	score += 18
	gauge = 1.0
	add_shake(5.5)
	flash = 0.62
	puff(bp, 40)
	rings.append({"c": bp, "r0": 12.0, "r1": 130.0, "r": 12.0, "t": 0.0, "w": 1.4, "life": 1.3})
	# The duel is the loop's payoff, so it hands out a full gauge rather than
	# partial credit: the player just proved they can out-fly their own
	# silhouette, and there is nothing left in the loop to spend it on.
	for k in 2:
		_spawn_cache(bp + Vector2(-16.0, -14.0 + float(k) * 28.0))
	# ---- the loop advances HERE, and only here -------------------------
	# The rival is the last stage, so it owns the counter. Advancing in
	# beat_boss instead would make the duel part of the NEXT loop's timeline,
	# and the elite clock would fire before the player ever met the twin.
	loop_n += 1
	boss_beat_this_loop = false
	rival_done = false
	rival_next_loop = loop_n + 1
	eb.clear()
	# New loop, so the elite gets another appearance.
	elite_done = false
	t = BOSS_AT - maxf(18.0, 34.0 - float(loop_n) * 2.0)
	sync_backdrop()
	spawn_t = 1.5


func draw_rival() -> void:
	# Draws the PLAYER'S hull. Every transform below is the same helper the
	# player's own drawing uses, fed the rival's mirrored state 鈥?which is why
	# the two silhouettes cannot drift apart as the values are tuned. If the
	# player's hull shape changes, the rival changes with it, for free.
	var p: Vector2 = boss.p
	var yaw := float(boss.yaw)
	var roll := float(boss.roll)
	var flap := float(boss.flap)
	var focusing := bool(boss.get("focus", false))
	# Reload state, for the same reason the player's HUD has a ring: a
	# change-over is a period when the twin CANNOT hurt you, and the player has
	# to be able to see it without counting its shots. Two channels, both
	# borrowed from the player's own vocabulary:
	#
	#   the plume dims and shortens (thrust is going elsewhere)
	#   a hairline reload arc closes around the craft
	#
	# The arc is a RING, drawn with Ink.ring at a radius that stays inside the
	# 190px cap, and it is the only ring on the twin -- so it cannot collide
	# with the hit feedback's own rings.
	var rival_reloading := bool(boss.get("reloading", false))
	var reload_prog := 0.0
	if rival_reloading:
		reload_prog = clampf(float(boss.get("reload_t", 0.0)) / maxf(RIVAL_RELOAD, 0.001), 0.0, 1.0)
	var trail := float(boss.trail)
	var hurt := float(boss.hurt)
	var body_ang := yaw * 0.13 - roll * 0.04

	# ---- engine wake, mirrored -------------------------------------------
	# The plume points LEFT here (the rival faces left), so the whole chain is
	# built with positive x. Built inline rather than reusing flame_spine(),
	# which is hard-wired to the player's bone list.
	var plume := (7.5 + sin(float(boss.t) * 26.0) * 1.3) * (0.85 + trail * 1.05)
	# Focus tucks the plume exactly the way it does on the player's craft, so a
	# braking twin visibly shortens its flame. Same constant, same read.
	if focusing:
		plume *= 0.55
	# A change-over starves the engine too, so the plume shrinks while the twin
	# is reloading. This is the second half of the "he cannot hurt you right
	# now" read: the first is the missing fire, and a silent weapon alone is
	# indistinguishable from a twin that is simply out of range.
	if rival_reloading:
		plume *= 0.45
	plume *= 0.94 + flap * 0.20
	var flick := 0.85 + sin(float(boss.t) * 41.0) * 0.15
	var stretch := 1.0 + trail * 0.55
	var f_scale := [1.30, 0.98, 0.70]
	var f_half := [3.0, 2.2, 1.5]
	var f_alpha := [0.20 + trail * 0.18, 0.34 + trail * 0.24, 0.55 + trail * 0.30]
	for k in 3:
		var ln: float = plume * float(f_scale[k]) * flick * stretch
		var steps := int(maxf(1.0, floorf(ln)))
		for i in steps:
			var tq := float(i) / maxf(ln, 1.0)
			var wq: float = float(f_half[k]) * (1.0 - tq * tq)
			draw_rect(Rect2(p.x + 9.0 + float(i), p.y - wq, 1.0, maxf(1.0, floorf(wq * 2.0))),
				Color(INK.r, INK.g, INK.b, float(f_alpha[k])), true)

	# ---- hull: the player's outline, mirrored in x ------------------------
	# Mirroring is done by flipping the x sign of every point in hull space
	# rather than by scaling the transform, because a negative scale also
	# mirrors the fin shading and the canopy would end up on the wrong face.
	var src := _hull_xf(p, body_ang)
	var body := PackedVector2Array()
	for vtx in src:
		body.append(Vector2(floorf(p.x - (vtx.x - p.x)), vtx.y))

	# Paper halo, exactly as the player has: this is what keeps a black
	# silhouette legible over the black moon.
	var halo := PackedVector2Array()
	for vtx in body:
		var d: Vector2 = vtx - p
		if d.length() > 0.5:
			halo.append(vtx + d.normalized() * 1.6)
		else:
			halo.append(vtx)
	Ink.fill_poly(self, halo, Color(PAPER.r, PAPER.g, PAPER.b, 0.92))

	var body_col := Color(INK.r, INK.g, INK.b, 1.0)
	if hurt > 0.0:
		body_col = INK.lerp(Color(0.33, 0.33, 0.30), 0.75)
	Ink.fill_poly(self, body, body_col)

	# Fin shading slab, mirrored the same way.
	var fin := _body_slab(p, body_ang, _hull_kin())
	if fin.size() >= 3:
		var finm := PackedVector2Array()
		for vtx in fin:
			finm.append(Vector2(floorf(p.x - (vtx.x - p.x)), vtx.y))
		Ink.fill_poly(self, finm, Color(0.30, 0.30, 0.28))

	# Canopy: mirrored position, same dither.
	var cc := _pt_xf(p, Vector2(6.2 - roll * 0.8, -2.6 + yaw * 1.2), body_ang)
	var cx2 := floorf(p.x - (cc.x - p.x))
	Ink.dither_rect(self, Rect2(cx2 - 3.0, cc.y, 3.0, 2.0), PAPER, 8)

	# ---- muzzle flash -----------------------------------------------------
	# Same alternation the player uses, mirrored: a 1px core at the barrel that
	# just fired. It reads as a twin because it is literally the same cue.
	#
	# Was 2x1; now 1px plus a sub-gate spark below it. The width was the problem:
	# a 2px CORE slab at the barrel is the widest gate source anywhere in the
	# game, and it fires on EVERY volley from every twin -- it was the single
	# biggest contributor to "the duel looks hazy" in a long fight. One pixel is
	# the same read at this scale (the hull is 26px; 1px vs 2px of light on it is
	# not a difference anyone can see at 3x), at half the budget.
	#
	# The spark under it is FLASH, i.e. under the gate, so the flash is still a
	# 2px-tall mark -- it just does not feed the glow chain twice.
	var cd := float(boss.fire)
	if cd > FIRE_COOLDOWN - 0.05:
		var side := -3.0 if int(boss.cannon) == 0 else 3.0
		var mz := Vector2(p.x - 9.0, p.y + side)
		draw_rect(Rect2(floorf(mz.x) - 1.0, floorf(mz.y), 1.0, 1.0), CORE, true)
		draw_rect(Rect2(floorf(mz.x) - 1.0, floorf(mz.y) + 1.0, 1.0, 1.0),
			Color(FLASH.r, FLASH.g, FLASH.b, 0.70), true)

	# ---- health: a tick run above the craft -------------------------------
	# Deliberately NOT the boss's curved arc: the rival wears the player's
	# silhouette, so its health belongs in the player's own HUD language 鈥?	# a straight run of ticks, like the old hull marks.
	var frac := float(boss.hp) / float(boss.max)
	var ticks := 18
	var lit := int(round(frac * float(ticks)))
	for i in ticks:
		var q := Vector2(p.x - 18.0 + float(i) * 2.0, p.y - 14.0)
		if i < lit:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 3.0), INK, true)
		else:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 1.0),
				Color(INK.r, INK.g, INK.b, 0.25), true)

	# ---- reload arc -------------------------------------------------------
	# "He is reloading" has to be readable at a glance, because it is the one
	# window in the duel where the player can stop dodging and shoot back. The
	# player's own HUD says this with a 16-dot ring; the twin gets the same
	# device at the same 5.0 radius, so a player who has learned the bottom
	# cluster can read the enemy too without being taught anything new.
	#
	# Drawn ABOVE the health ticks (p.y - 26) rather than around the hull: the
	# hull is only 26px long and a 5px ring centred on it would sit inside the
	# silhouette, where a 1px arc disappears into the ink.
	#
	# Radius 5.0 keeps the dot pitch at 1.96px -- the value the HUD comment
	# already established as the smallest arc that still reads as a sweep
	# instead of as texture.
	if rival_reloading:
		var arc_c := Vector2(p.x, p.y - 26.0)
		var segs := 16
		var lit_segs := int(round(reload_prog * float(segs)))
		for i in segs:
			var a := -PI * 0.5 + TAU * float(i) / float(segs)
			var q := Vector2(floorf(arc_c.x + cos(a) * 5.0), floorf(arc_c.y + sin(a) * 5.0))
			if i < lit_segs:
				draw_rect(Rect2(q.x, q.y, 1.0, 1.0), INK, true)
			else:
				draw_rect(Rect2(q.x, q.y, 1.0, 1.0),
					Color(INK.r, INK.g, INK.b, 0.18), true)


# ---- elite -------------------------------------------------------------
#
# A mid-loop mini boss at t = 26 s, i.e. halfway to the 52 s boss. Its job is
# not to be a damage check but to force one necessary position change in the
# middle of a run, when the wave rhythm has settled and the player is coasting.
# ---- elite -------------------------------------------------------------
#
# A mid-loop mini boss at t = 26 s, i.e. halfway to the 52 s boss. Its job is
# not to be a damage check but to force one necessary position change in the
# middle of a run, when the wave rhythm has settled and the player is coasting.
#
#   health  55 + 18*loop      (vs the boss's 165 + 42*loop)
#   radius  14                (half the boss)
#   attack  two phases        (vs three)
#   reward  +4 score, +0.20 gauge, one guaranteed cache
#   lifetime ~6..9 s
func step_elite_clock(dt: float) -> void:
	if elite_done or t < ELITE_AT:
		return
	# Loop gate: the elite only appears on its designated loops. Appearing every
	# loop made it a rhythm, and a rhythm is not an interruption.
	if loop_n > elite_next_loop:
		return
	if boss.is_empty():
		start_elite()


func start_elite() -> void:
	elite_done = true
	elite_next_loop = loop_n + ELITE_EVERY
	var hp := 55 + 18 * (loop_n - 1)
	boss = {
		"p": Vector2(SPAWN_X + 14.0, H * 0.5),
		"hp": hp, "max": hp,
		"t": 0.0, "fire": 1.2, "tick": 0.8,
		"r": 14.0, "hurt": 0.0, "ph": 0.0,
		"is_elite": true,
	}


func step_elite(dt: float) -> void:
	var bt: float = float(boss.t) + dt
	boss.t = bt
	# Hard lifetime. An elite that nobody kills withdraws instead of squatting in
	# the boss slot forever 闂?that was the bug that kept the real boss from ever
	# spawning.
	if bt > ELITE_LIFE:
		var leaving: Vector2 = boss.p
		boss = {}
		puff(leaving, 12)
		rings.append({"c": leaving, "r0": 18.0, "r1": 2.0, "r": 18.0, "t": 0.0, "w": 1.0, "life": 0.30})
		return
	var bp: Vector2 = boss.p
	var target := W * 0.70
	# Entrance: exponential ease on TIME, same reasoning as the boss. A per-frame
	# step turns into a crawl whenever the frame time grows.
	if bp.x > target + 1.0:
		var nx: float = lerpf(bp.x, target, 1.0 - exp(-4.5 * dt))
		boss.p = Vector2(maxf(target, nx), bp.y)
		return
	var frac := float(boss.hp) / float(boss.max)
	# Phase 2 moves faster vertically; the amplitude grows 22% -> 30% of H.
	var amp := H * (0.22 if frac > 0.5 else 0.30)
	var freq := 1.1 if frac > 0.5 else 1.5

	# ---- the "teleport" was a phase discontinuity ---------------------------
	# On the frame the entrance finishes, the craft switches from "hold y at the
	# spawn row" to "y = centre + sin(bt * freq) * amp". `bt` at that moment is
	# already ~1 s, so the sine can be anywhere 鈥?the body jumps up to 2*amp
	# (about 95 px) in ONE frame. That is the teleport being reported.
	#
	# The fix is to anchor the sine to the moment the craft takes up station, so
	# the sweep starts at sin(0) = 0 and therefore at the exact y it already
	# occupies. Continuous by construction.
	if not boss.has("station_t"):
		boss.station_t = bt
		# Arrival flourish: TWO rings spawned on the single frame the craft takes
		# up station, not one per frame.
		#
		# The previous version appended a ring every frame for 0.30 s, i.e. about
		# 18 overlapping rings with radii 4..14 鈥?a solid grey disc that pulsed
		# once and then vanished, which is the opposite of a blink. A blink is
		# two expanding rings, one fast and one slow, released together.
		#
		# They are spawned here (inside the `not has` branch) because that branch
		# runs exactly once per elite. Spawning them by `since < 0.30` looked
		# equivalent and was not: `since` is a duration, not an edge.
		var sp: Vector2 = boss.p
		rings.append({"c": sp, "r0": 5.0, "r1": 26.0, "r": 5.0, "t": 0.0, "w": 1.2, "life": 0.26})
		rings.append({"c": sp, "r0": 3.0, "r1": 15.0, "r": 3.0, "t": 0.0, "w": 1.0, "life": 0.38})
	var since := bt - float(boss.station_t)
	boss.p = Vector2(bp.x, H * 0.5 + sin(since * freq) * amp)

	# The ring is a separate object; `arrive` is only the shell's own flash, and
	# it decays from 1 to 0 across the same 0.30 s so the body lands WITH the
	# rings instead of after them.
	boss.arrive = maxf(0.0, 1.0 - since / 0.30)

	boss.fire = float(boss.fire) - dt
	if float(boss.fire) <= 0.0:
		if frac > 0.5:
			# Phase 1: a ring answerable by finding the gap, plus aimed shots.
			boss.fire = 1.5 - float(loop_n) * 0.06
			elite_ring(8, 125.0 + float(loop_n) * 5.0)
		else:
			# Phase 2: denser ring AND a rotating fan, so standing still is
			# no longer survivable 闂?that is the position change the elite
			# exists to force.
			boss.fire = 1.2 - float(loop_n) * 0.06
			elite_ring(12, 138.0 + float(loop_n) * 5.0)
			elite_fan_sweep(5, 150.0)

	# Aimed burst, both phases, faster in phase 2.
	boss.tick = float(boss.tick) - dt
	if float(boss.tick) <= 0.0:
		boss.tick = 1.05 if frac > 0.5 else 0.78
		var aim := (player - bp).normalized()
		var n := 3 if frac > 0.5 else 4
		for k in n:
			eb_add(bp, aim * (145.0 + float(loop_n) * 4.0), 1.9)
		# Small angular spread so the burst covers a lane, not a single point.
		pass
	boss.hurt = maxf(0.0, float(boss.hurt) - dt)
	step_chip(dt)


func elite_ring(n: int, sp: float) -> void:
	var bp: Vector2 = boss.p
	var base := float(boss.t) * 0.8
	for i in n:
		var a := base + TAU * float(i) / float(n)
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.4)


func elite_fan_sweep(n: int, sp: float) -> void:
	var bp: Vector2 = boss.p
	var aim := (player - bp).normalized().angle()
	# The sweep angle advances every volley, so consecutive fans cover
	# different sectors rather than repeating the same five lanes.
	var ph: float = float(boss.ph) + 0.14
	boss.ph = ph
	for i in n:
		var a := aim + (float(i) - float(n - 1) * 0.5) * 0.16 + ph
		eb_add(bp, Vector2(sp, 0.0).rotated(a), 1.4)


func beat_elite() -> void:
	var bp: Vector2 = boss.p
	boss = {}
	score += 4
	gauge = minf(1.0, gauge + 0.20)
	add_shake(3.2)
	flash = 0.35
	puff(bp, 26)
	# Contrast with the boss: the boss bursts OUTWARD, the elite implodes. Two
	# different death languages make the two tiers read as different events
	# rather than the same event at two sizes.
	for i in 3:
		rings.append({"c": bp, "r0": 30.0 + float(i) * 8.0, "r1": 2.0, "r": 30.0,
			"t": 0.0, "w": 1.2, "life": 0.42 + float(i) * 0.08})
	_spawn_cache(bp)
	# The elite drops TWO, at different tiers. One cache from the hardest fight
	# in the first half of a loop felt like the wrong exchange rate.
	_spawn_cache(bp + Vector2(-18.0, 14.0))
	spawn_t = maxf(spawn_t, 0.9)


func eb_add(p: Vector2, v: Vector2, r: float) -> void:
	# Enemy rounds carry a short position history. One anchor was not enough:
	# at 112px/s a bullet covers under 2px per frame, so a single stored point
	# drew a 2px stub that vanished under the round's own disc. Four samples
	# span ~8px, which is the shortest tail that reads as motion.
	eb.append({"p": p, "v": v, "r": r, "life": 7.0, "trail": [p]})


# ---- major contact ----------------------------------------------------------
#
# The craft can now cross the whole field (see RIGHT_LIMIT), which means it can
# physically enter a boss body. Before this rule existed the air wall was
# silently doing the work of keeping the player out: the boss had no contact
# damage because contact was impossible.
#
# 0.80 of the radius, not the full radius, so the hit lands when the hull is
# visibly INSIDE the disc rather than when it brushes the outermost pixel. Any
# looser and the player gets punished for grazing a shape that looks like
# background scenery.
#
# hurt_player() already sets 1.35 s of invulnerability, so this can fire every
# frame without ever stacking.
func _check_major_contact() -> void:
	if boss.is_empty() or dead or invuln > 0.0:
		return
	var bc: Vector2 = boss.p
	var br: float = float(boss.r)
	if player.distance_to(bc) < br * 0.80:
		hurt_player()
		# The craft is pushed out along the radial, not knocked backwards: a
		# knock-back inside a 28 px body would leave it still inside and the
		# next frame would not be able to punish again (invuln), so the player
		# would sit in the boss through the whole invulnerability window.
		var out := (player - bc)
		if out.length() < 0.5:
			out = Vector2(-1.0, 0.0)
		player = bc + out.normalized() * (br * 0.80 + 3.0)
		player.x = clampf(player.x, LEFT_LIMIT, RIGHT_LIMIT)
		player.y = clampf(player.y, TOP_LIMIT, BOTTOM_LIMIT)


# The blast probe's verdict.
#
# Printed only after the shell has actually landed: `pb` empties the frame the
# round connects, so an empty `pb` plus an armed watch is the moment to read
# what survived. A fixed delay would race the impact at any dt cap.
#
# TWO outputs, and both are required:
#
#   BLAST impact_x=... r=... inside=.. outside=.. => PASS     (the radius)
#   BLASTCASE tag=... want=... got=... d=... -> ok            (per craft)
#
# The first line alone was not enough, and that is the whole reason this probe
# has lied twice. It counts survivors by distance, so it can only say "nothing
# inside is left alive" -- it cannot tell you WHETHER the direct hit did its
# damage, whether the splash number is what the table says, or whether the
# layout drifted. The second line is per-craft: intended fraction of the radius,
# the REAL measured distance to the burst, and the health delta. A verdict that
# prints health deltas is a verdict about numbers rather than about geometry.
func _report_blast() -> void:
	if not blast_watch or blast_printed:
		return
	# Two conditions, both required. `blast_landed` is raised by step_pb the
	# moment the probe's shell connects with anything, which is the only event
	# that can make the verdict meaningful. Waiting on an empty `pb` alone
	# reported on the very first frame, while the shell was still in flight.
	if not blast_landed:
		return
	blast_printed = true
	blast_watch = false
	# Survivors, by tag: a craft that died is simply absent from `foes`.
	var live := {}
	for f in foes:
		if f.has("blast_tag"):
			live[String(f.blast_tag)] = f
	# The radius test counts ONLY the binary craft (tags `in*` / `out*`).
	#
	# Counting every body on the field was the old rule and it is now wrong by
	# construction: the probe deliberately parks a 9hp craft whose whole job is
	# to SURVIVE its splash and report the damage number, and a craft that is
	# meant to live inside the radius cannot also be part of "nothing inside is
	# alive". Mixing the two tests would make the radius verdict fail on a
	# working blast.
	var inside := 0
	var outside := 0
	for f in foes:
		if not f.has("blast_tag"):
			continue
		var tag := String(f.blast_tag)
		var d: float = (f.p as Vector2).distance_to(blast_ref)
		if tag.begins_with("in"):
			inside += 1
		elif tag.begins_with("out"):
			outside += 1
		# A craft the probe INTENDED to be inside landed outside the radius:
		# the burst is somewhere other than bc, and every number on the following
		# lines is about the wrong geometry. Reported, not scored.
		var intended_in := not (tag.begins_with("out") or tag == "edge53")
		if d > BOMB_BLAST_R and intended_in:
			print("BLASTNOTE tag=%s intended_inside d=%.1f r=%.1f" % [tag, d, BOMB_BLAST_R])
	var radius_ok := (inside == 0 and outside >= 1)
	print("BLAST impact_x=%.1f r=%.1f inside=%d outside=%d => %s" % [
		blast_ref.x, BOMB_BLAST_R, inside, outside,
		("PASS" if radius_ok else "FAIL"),
	])
	# ---- per-craft: distance, and the health delta the table promises ------
	#
	# The expectations are DERIVED from the constants, never typed in. A probe
	# that hardcodes "should end at 4hp" silently becomes a test of the old
	# balance the moment the table changes -- which is exactly the class of
	# failure the direct-hit raise would have introduced here.
	var define: int = int(WEAPON_DMG[WEAPON_BOMB])
	var all_ok := radius_ok
	for e in blast_probe:
		var tag := String(e.tag)
		var frac := float(e.f)
		var absp := float(e.abs)
		var hp0 := int(e.hp0)
		var entry: Dictionary = (live[tag] if live.has(tag) else {})
		var alive := not entry.is_empty()
		var hp1: int = (int(entry.hp) if alive else 0)
		var d: float = -1.0
		if alive:
			d = (entry.p as Vector2).distance_to(blast_ref)
		var want := ""
		var ok := false
		if tag == "direct":
			# Takes the shell's own damage and NOT the splash: the splash loop
			# skips the body it just hit, which is what stops one shell from
			# billing the same craft twice.
			want = "hp=%d" % (hp0 - define)
			ok = alive and hp1 == hp0 - define
		elif tag == "splash":
			want = "hp=%d" % (hp0 - BOMB_BLAST_DMG)
			ok = (not alive) or hp1 == maxi(0, hp0 - BOMB_BLAST_DMG)
		elif tag == "edge41":
			# ABSOLUTE lower bracket: 41px from the burst must be lethal.
			# Written against a literal so the claim is "R >= 42", not "R is
			# whatever it happens to be". Reverting R to 30 turns this BAD.
			want = "dead(R>=42)"
			ok = not alive
		elif tag == "edge53":
			# ABSOLUTE upper bracket: 53px from the burst must survive, so
			# "R <= 52". 44 satisfies it with 9px of margin; 54 (the value this
			# round considered and rejected) would fail it. Together the two
			# absolutes are the only part of this probe that can catch a change
			# to BOMB_BLAST_R itself.
			want = "hp=%d(R<=52)" % hp0
			ok = alive and hp1 == hp0
		elif tag.begins_with("in"):
			want = "dead"
			ok = not alive
		else:
			want = "hp=%d" % hp0
			ok = alive and hp1 == hp0
		# A craft clamped off its intended distance would make the whole
		# verdict a lie, so it is a failure, not a footnote.
		if bool(e.clamped):
			ok = false
			want += "+UNCLAMPED"
		if not ok:
			all_ok = false
		# The placed distance is printed next to the MEASURED one. When they
		# disagree you are looking at a burst that landed somewhere other than
		# bc, and every verdict on that line is about the wrong geometry.
		var placed := (absp if absp >= 0.0 else frac * BOMB_BLAST_R)
		print("BLASTCASE tag=%s placed=%.1f want=%s got=%s d=%.1f -> %s" % [
			tag, placed, want, ("dead" if not alive else "hp=%d" % hp1), d,
			("ok" if ok else "BAD"),
		])
	print("BLASTVERDICT %s" % ("PASS" if all_ok else "FAIL"))


func step_foes(dt: float) -> void:
	var i := foes.size() - 1
	while i >= 0:
		var f := foes[i]
		var k := int(f.kind)
		var p: Vector2 = f.p

		# Each craft rides a scripted weave; see the "ride the curve exactly"
		# block below for why the body must not chase it.
		var target := p
		var target_vy := 0.0
		if k == 0:
			target.x -= float(f.speed) * dt
			var a0 := float(f.ph) + target.x * 0.033
			target.y = float(f.base) + weave_wave(a0) * float(f.amp)
			target_vy = weave_slope(a0) * float(f.amp) * -(float(f.speed) * 0.033)
		elif k == 1:
			target.x -= float(f.speed) * dt
			var a1 := float(f.ph) + t * 1.1
			target.y = float(f.base) + weave_wave(a1) * float(f.amp)
			target_vy = weave_slope(a1) * float(f.amp) * 1.1
			f.fire = float(f.fire) - dt
			if float(f.fire) <= 0.0 and target.x < W - 8.0:
				f.fire = 1.75
				eb_add(target, (player - target).normalized() * (112.0 + float(loop_n) * 4.0), 1.5)
		else:
			# y is driven by the weave on EVERY frame, including while the craft
			# is still flying in.
			#
			# The old form only assigned y inside the `else` (hovered) branch,
			# so during the approach y stayed frozen at the spawn row and then
			# snapped to `base + sin(ph + t*1.35) * amp` the instant x reached
			# `hover`. By then t had advanced ~2 s, so the sine could be at any
			# value: a vertical jump of up to 2 x amp = 42 px, one frame, on
			# screen. That is the "teleport".
			#
			# Now the weave runs from spawn. `ph` is 0 for this kind (see
			# foe_coil) so sin(ph)=0 puts the craft exactly on its spawn row at
			# t=0, and every later frame is continuous.
			var a2 := float(f.ph) + t * 1.35
			target.y = float(f.base) + weave_wave(a2) * float(f.amp)
			target_vy = weave_slope(a2) * float(f.amp) * 1.35
			if target.x > float(f.hover):
				target.x -= float(f.speed) * dt
			else:
				f.fire = float(f.fire) - dt
				if float(f.fire) <= 0.0:
					f.fire = 1.3
					f.spin = float(f.spin) + 0.72
					for j in 3:
						var a3 := float(f.spin) + TAU * float(j) / 3.0
						eb_add(target, Vector2(98.0, 0.0).rotated(a3), 1.4)

		# Ride the curve exactly.
		#
		# Two earlier versions both failed for the same root cause: they made the
		# body chase its scripted position. Chasing ties vertical speed to the
		# remaining error, so the craft hangs where the error is small (apex and
		# floor) and rushes where it is large (mid-swing). That reads as a ball
		# being dropped, twice per cycle, whatever the underlying wave is.
		#
		# The scripted point IS the body's position 闂?no easing toward it, no
		# knockback offset, nothing superimposed. `target_vy` is still computed
		# because the call sites need it for firing leads; it is no longer stored
		# on the craft.
		p.x = target.x
		p.y = target.y
		f.p = p
		# Vertical speed is stored purely for the DRAWING: the silhouette banks
		# into its own arc with it. It has no effect on movement 鈥?the craft is
		# still pinned exactly to the scripted curve above. Kept in a dictionary
		# field rather than recomputed in the draw pass because the draw pass has
		# no access to the phase and would have to duplicate the wave maths,
		# which is how the two drift apart.
		f.vy = target_vy

		# Hit flash decay, per craft. Must tick here because enemies are
		# dictionaries, not nodes 闂?nothing else advances their timers.
		if f.has("hit_t"):
			f.hit_t = maxf(0.0, float(f.hit_t) - dt)

		var j2 := pb.size() - 1
		while j2 >= 0:
			var b: Dictionary = pb[j2]
			if (b.p as Vector2).distance_to(p) <= float(f.r) + 2.5:
				# Damage and pierce come from the round, so the weapon tiers
				# share one hit path. `pierce` counts how many craft one round
				# may pass through: decrement it here and only remove the round
				# when it reaches zero.
				var dmg: int = maxi(1, int(b.get("dmg", 1)))
				var pierce: int = int(b.get("pierce", 1)) - 1
				f.hp = int(f.hp) - dmg
				var impact: Vector2 = b.p as Vector2

				# ---- hit feedback, per tier ---------------------------
				# Every tier used to land identically: one 0.18 s flash, six
				# specks, one 9 px ring, 0.85 shake. So a 3-damage bomb shell
				# and a 1-damage MG tick felt the same, and the only way to tell
				# them apart was to watch the health bar 闂?which is exactly what
				# a player cannot do while dodging.
				#
				# Weight now scales with what the round actually carries:
				#   flash duration  0.10 (MG) .. 0.26 (BOMB)
				#   debris count    3      .. 10
				#   contact ring    6 px   .. 16 px
				#   shake           0.30   .. 1.90
				#   hit-stop        0      .. 0.030
				# LASER sits mid-range on impact but its pierce means its damage
				# shows up as several consecutive pops rather than one heavy one.
				var w_kind: int = int(b.get("wk", WEAPON_BASE))
				if w_kind == WEAPON_BOMB and blast_watch:
					blast_landed = true
					blast_ref = b.p as Vector2
					blast_impact_n += 1
				var heavy: float = 0.0    # 0 = feather, 1 = shell
				var sparks_n := 3
				var flash_dur := 0.10
				var ring_r := 6.0
				var sh := 0.30
				var stop_t := 0.0
				match w_kind:
					WEAPON_MG:
						heavy = 0.0
					WEAPON_BASE:
						heavy = 0.25
						sparks_n = 4
						flash_dur = 0.14
						ring_r = 8.0
						sh = 0.55
					WEAPON_SPREAD:
						heavy = 0.35
						sparks_n = 5
						flash_dur = 0.16
						ring_r = 10.0
						sh = 0.70
					WEAPON_LASER:
						heavy = 0.55
						sparks_n = 6
						flash_dur = 0.20
						ring_r = 11.0
						sh = 0.95
						stop_t = 0.010
					WEAPON_BOMB:
						heavy = 1.0
						sparks_n = 10
						flash_dur = 0.26
						ring_r = 16.0
						sh = 1.90
						stop_t = 0.030
					WEAPON_SWARM:
						# Lightest contact in the game on purpose: the darts
						# land within a quarter second of each other, and
						# anything heavier per dart would strobe the screen
						# twice and stop reading as one volley.
						heavy = 0.10
						sparks_n = 2
						flash_dur = 0.08
						ring_r = 4.0
						sh = 0.18
					WEAPON_FLAK:
						# Mid-weight, sits between SPREAD and LASER. The fan is
						# what carries the tier, not the individual pellet, so a
						# single contact must not out-punch a SPREAD pellet.
						heavy = 0.45
						sparks_n = 6
						flash_dur = 0.18
						ring_r = 12.0
						sh = 0.80
						stop_t = 0.010
					WEAPON_RAIL:
						# Second-heaviest in the game, behind BOMB only. It fires
						# once per 0.62 s, so the whole tier's weight budget is
						# spent on this one contact.
						heavy = 0.80
						sparks_n = 8
						flash_dur = 0.24
						ring_r = 14.0
						sh = 1.40
						stop_t = 0.030
				# ---- frag contact: a chip landing, not a hit --------------
				# A frag IS a SPREAD round by `wk` -- that is what keeps it on
				# the same ammo, pierce and damage path -- so the match above
				# just handed it SPREAD's weight. That weight is wrong here in
				# exactly one way: SPREAD's numbers say "a pellet connected".
				# Three frags are born on EVERY connecting pellet, so at
				# SPREAD weight one burst flashes the screen four times and
				# the debris reads as the tier's damage instead of as its
				# consequence.
				#
				# So the weight is overridden at the CONTACT and the tier
				# table is left alone: `wk` is the ammo channel, not the
				# feedback channel. Every number here sits below MG.
				var is_frag := bool(b.get("frag", false))
				if is_frag:
					heavy = 0.05
					sparks_n = 0
					flash_dur = 0.06
					ring_r = 2.5
					sh = 0.08
					stop_t = 0.0
				f.hit_t = flash_dur
				puff(impact, sparks_n)

				# Directional spray: debris thrown back along the round's travel,
				# which is what makes a hit read as coming FROM somewhere rather
				# than simply happening. NO core speck here -- a white core feeds
				# the bloom chain, and three hits per second each lighting the
				# glow pass is what made contacts feel like explosions.
				var away := (b.v as Vector2).normalized()
				var spray := 2 + int(heavy * 4.0)
				for d in spray:
					var sl := rng.randf_range(0.10, 0.20) + heavy * 0.10
					sparks.append({
						"p": impact,
						"v": (-away).rotated(rng.randf_range(-0.5, 0.5))
							* rng.randf_range(34.0, 62.0) * (1.0 + heavy * 0.6),
						"life": sl, "max": sl,
						"g": 30.0, "core": false,
					})
				# Micro-stop scales too: a shell should punch, an MG tick should
				# not stop the world at all.
				if stop_t > 0.0:
					hit_stop = maxf(hit_stop, stop_t)
				# One ring, not two. The double burst read as a small detonation;
				# a single ring the size of the craft says "contact" and stops.
				rings.append({"c": impact, "r0": 1.0, "r1": ring_r, "r": 1.0,
					"t": 0.0, "w": 0.8 + heavy * 0.6, "life": 0.20 + heavy * 0.10})
				add_shake(sh, impact)

				# ---- per-tier extra layer ---------------------------
				# The numbers above make the tiers differ in DEGREE. These make
				# them differ in KIND, which is what a player actually
				# recognises: a rod leaves a slot, a swarm leaves bites, flak
				# throws shards. All three are carried by `sparks`, so nothing
				# new has to be ticked or drawn.
				# ---- per-tier extra layer ---------------------------
				# The numbers above make the tiers differ in DEGREE. These make
				# them differ in KIND, which is what a player actually
				# recognises: a rod leaves a slot, a swarm leaves bites, flak
				# throws shards. All three are carried by `sparks`, so nothing
				# new has to be ticked or drawn.
				match w_kind:
					WEAPON_SWARM:
						_mark_bites(impact, 2.0, 0.10)
					WEAPON_FLAK:
						_mark_shards(impact, away, 78.0 * (1.0 + heavy * 0.55), 0.22)
					WEAPON_RAIL:
						_mark_trough(impact, 5, 0.18)
				# A frag's mark is the chip coming off an edge, perpendicular to
				# the round's travel. `away` is the round's own direction, so
				# (-away.y, away.x) is the cross axis.
				if is_frag:
					_mark_split(impact, Vector2(-away.y, away.x), 0.14)

				# ---- SPREAD cluster burst ----------------------------------
				# The pellet comes apart. Three frag rounds leave at 120 degrees
				# and HALF the parent's damage, so the tier's payoff is "a
				# connecting pellet is a burst point" rather than "three pellets
				# that mostly miss at range".
				#
				# Frag rounds cannot chain: they carry `frag` and this branch
				# skips anything carrying it. Without that, one SPREAD volley
				# into a cluster is a chain reaction and the tier clears a wave.
				#
				# Low speed on purpose -- shrapnel, not a second volley.
				if w_kind == WEAPON_SPREAD and not bool(b.get("frag", false)):
					var base_ang := (b.v as Vector2).angle()
					for fi in FRAG_COUNT:
						# 120-degree ring, offset so no frag flies straight
						# back down the parent's own line (which is where the
						# target already is, so it would be wasted).
						var fa := base_ang + PI + TAU * float(fi) / float(FRAG_COUNT)
						var fv := Vector2(SHOT_SPEED * FRAG_SPEED, 0.0).rotated(fa)
						pb.append({
							"p": impact,
							"v": fv,
							"len": 2.0,
							"dmg": FRAG_DMG,
							"pierce": 1,
							"frag": true,
							"frag_life": FRAG_LIFE,
							"wk": WEAPON_SPREAD,
						})

				# ---- flak shred -----------------------------------------
				# The tier's identity. SPREAD rewards closing distance with
				# ONE body; FLAK rewards aiming at the MIDDLE of a group.
				# Deliberately capped at FLAK_SHRED_MAX bodies and 1 damage
				# each: a spray that wounds a cluster, never a second shell.
					#
					# Shred kills count exactly like direct kills (score, gauge,
					# streak), the same rule the bomb splash already follows.
					var shred_hits := 0
					for oi in range(foes.size() - 1, -1, -1):
						if shred_hits >= FLAK_SHRED_MAX:
							break
						var other2: Dictionary = foes[oi]
						if other2 == f:
							continue
						var op2: Vector2 = other2.p
						if impact.distance_to(op2) > FLAK_SHRED_R:
							continue
						shred_hits += 1
						other2.hp = int(other2.hp) - FLAK_SHRED_DMG
						if int(other2.hp) <= 0:
							score += 1
							gauge = minf(1.0, gauge + ERASE_GAIN)
							var ok2: int = int(other2.kind)
							note_kill(op2, 1.0 if ok2 == 0 else (1.5 if ok2 == 1 else 2.0))
							puff_heavy(op2, 10)
							rings.append({"c": op2, "r0": 3.0, "r1": 16.0, "r": 3.0,
								"t": 0.0, "w": 1.0, "life": 0.26})
							foes.remove_at(oi)
						else:
							other2.hit_t = 0.12
							puff(op2, 3)

				# ---- bomb blast ------------------------------------
				# The tier's identity. Everything inside the radius except the
				# direct target takes BOMB_BLAST_DMG, which is what turns a slow
				# single-target slug into a wave-clearing tool. Splash hits use
				# a reduced version of the same feedback so the screen does not
				# double-flash on one shell.
				#
				# Kills from splash count exactly like direct kills 闁?score,
				# gauge, streak. Otherwise the one tier built for clearing waves
				# would be the one tier that earns nothing from clearing them.
				if w_kind == WEAPON_BOMB:
					# `BOMB_BLAST_MAX` was DECLARED AND NEVER READ for its whole
					# life: the loop below had no counter and no break, so the
					# constant documented a ceiling the code did not have -- this
					# project's sixteenth silent failure (a field nobody reads) in
					# its purest form. Wiring it in now matters more than before,
					# because the radius grew from 30 to 44 and an uncapped loop
					# over `foes` is O(n^2) per contact on a late-loop field.
					var blast_hits := 0
					for oi in range(foes.size() - 1, -1, -1):
						if blast_hits >= BOMB_BLAST_MAX:
							break
						var other: Dictionary = foes[oi]
						if other == f:
							continue
						var op: Vector2 = other.p
						if impact.distance_to(op) > BOMB_BLAST_R:
							continue
						blast_hits += 1
						other.hp = int(other.hp) - BOMB_BLAST_DMG
						if int(other.hp) <= 0:
							score += 1
							gauge = minf(1.0, gauge + ERASE_GAIN)
							var ok: int = int(other.kind)
							note_kill(op, 1.0 if ok == 0 else (1.5 if ok == 1 else 2.0))
							puff_heavy(op, 14)
							rings.append({"c": op, "r0": 4.0, "r1": 24.0, "r": 4.0, "t": 0.0, "w": 1.2, "life": 0.34})
							foes.remove_at(oi)
						else:
							other.hit_t = 0.16
							puff(op, 4)
					rings.append({"c": impact, "r0": BOMB_BLAST_R * 0.35, "r1": BOMB_BLAST_R,
						"r": BOMB_BLAST_R * 0.35, "t": 0.0, "w": 1.4, "life": 0.30})

				if pierce <= 0:
					pb.remove_at(j2)

				if int(f.hp) <= 0:
					score += 1
					gauge = minf(1.0, gauge + ERASE_GAIN)
					# Streak weight by craft class: shard 1, drift 1.5, coil 2,
					# so a coil-heavy stretch also earns a cache without the
					# player having to farm trash.
					note_kill(p, 1.0 if k == 0 else (1.5 if k == 1 else 2.0))
					# Kill punch: a brief stop, a ring burst, and a heavier
					# debris spray scaled by how tough the craft was.
					kill_t = 0.30
					hit_stop = maxf(hit_stop, 0.035)
					add_shake(2.2, p)
					puff_heavy(p, 22)
					# Two rings at different speeds: a tight core flash and a
					# wider shock. Two reads far heavier than one.
					rings.append({"c": p, "r0": 2.0, "r1": 14.0, "r": 2.0, "t": 0.0, "w": 1.0, "life": 0.26})
					rings.append({"c": p, "r0": 4.0, "r1": 34.0, "r": 4.0, "t": 0.0, "w": 1.6, "life": 0.48})
					foes.remove_at(i)
					break
			j2 -= 1

		if i < foes.size() and foes[i] == f and int(f.hp) > 0:
			# Cull one craft-radius past the frame edge, not 26 px past the
			# raster edge. The old value let a craft run 17 px outside the
			# printed border before it disappeared, which read as it sliding
			# along the margin.
			if p.x < CULL_X_LEFT - float(f.r):
				foes.remove_at(i)
			elif invuln <= 0.0 and player.distance_to(p) < float(f.r) * 0.80:
				hurt_player()
				puff(p, 6)
				if k == 0:
					foes.remove_at(i)
		i -= 1


# ---- SWARM homing -----------------------------------------------------------
#
# How many steering events one dart gets, and how long it waits between them.
#
# The bug this replaces: `homing` was a one-shot flag, and the single steer
# happened on the VERY FIRST frame the round existed. At that instant the dart
# is still beside the muzzle, ~28px from a craft that may be 300px away, so the
# correction angle is a degree or two -- mathematically a steer, practically
# nothing. Three darts therefore flew their initial fan into empty space, and
# the moment the target drifted they were unrecoverable.
#
# Now a dart steers every SWARM_TURN_GAP seconds until it has spent
# SWARM_TURNS events, and the FIRST event is delayed past the muzzle so the
# dart has closed some distance and the angle is meaningful. Steering is still
# bounded: an unbounded tracker can only be outrun, never dodged, and this file
# already made that argument for the enemy lure in step_eb.
const SWARM_TURNS := 4
const SWARM_TURN_GAP := 0.10


# One steering event for one dart.
#
# TARGET SELECTION, and this is the second half of the bug: darts that all lock
# the SAME craft arrive as one overlapping point, so the volley is worth one
# dart's damage and misses together. Each dart carries a `lane` 0..N-1 and
# picks the lane-th nearest craft instead, spreading the volley across the
# field. With only one target alive every lane collapses onto it -- which is
# correct, because there is nothing else to shoot.
#
# The lane count is NOT hard-coded here: `_pick_target` clamps the lane to the
# number of candidates, so this keeps working when the volley size changes.
# It went from 3 darts to 2 on 2026-11-09 and only the firing loop needed the
# edit -- which is what the clamp was for.
#
# Targets AHEAD of the dart are preferred; a craft already behind it cannot be
# hit without the round turning around, and a round that turns around has
# stopped being a shot. The bias is a distance discount, not a filter, so a
# dart with only a trailing target still turns.
func _steer_dart(b: Dictionary) -> void:
	var from: Vector2 = b.p as Vector2
	var aim := _pick_target(from, int(b.get("lane", 0)))
	if aim == Vector2.INF:
		return
	var spd: float = (b.v as Vector2).length()
	b.v = (aim - from).normalized() * spd
	# A steer is a beat the round spent thinking, so it flares briefly --
	# otherwise the correction is invisible at 740 px/s and the dart reads as
	# having missed by luck.
	rings.append({"c": from, "r0": 1.0, "r1": 5.0, "r": 1.0,
		"t": 0.0, "w": 0.5, "life": 0.12})


# The `lane`-th best target for a dart at `from`.
#
# Builds the candidate list with a forward bias, sorts by score, and returns
# the lane-th entry clamped to the last one. Returning Vector2.INF means "no
# target at all", the only sentinel that can never be a position.
func _pick_target(from: Vector2, lane: int) -> Vector2:
	var cand: Array = []
	for f in foes:
		var fp: Vector2 = f.p as Vector2
		# Forward bias: anything to the LEFT of the dart costs 120px of
		# apparent distance, so a trailing craft is picked only when it is the
		# only thing on the field.
		var d := from.distance_to(fp)
		if fp.x < from.x:
			d += 120.0
		cand.append([d, fp])
	if not boss.is_empty():
		var bp: Vector2 = boss.p as Vector2
		var bd := from.distance_to(bp)
		if bp.x < from.x:
			bd += 120.0
		cand.append([bd, bp])
	if cand.is_empty():
		return Vector2.INF
	cand.sort_custom(func(a, b): return a[0] < b[0])
	var idx := mini(lane, cand.size() - 1)
	return cand[idx][1] as Vector2


func step_pb(dt: float) -> void:
	var i := pb.size() - 1
	while i >= 0:
		var b: Dictionary = pb[i]
		var prev: Vector2 = b.p
		# ---- SWARM: bounded, periodic steering -------------------------
		# `homing` is the REMAINING number of steering events, not a flag. It
		# decrements once per event and the dart commits when it reaches zero.
		#
		# The first steer is delayed by SWARM_TURN_GAP so the dart has cleared
		# the muzzle before it aims. Steering on frame zero -- which is what the
		# old one-shot flag did -- computed the angle from a point 28px off the
		# wing against a target hundreds of pixels away, i.e. an angle so shallow
		# it changed nothing and the volley flew on straight into empty space.
		#
		# `home_t` accumulates time since the last event. It is stored per-round
		# rather than derived from a global clock because there can be several
		# SWARM volleys alive at once with different start times.
		if b.has("homing") and int(b.homing) > 0:
			b.home_t = float(b.get("home_t", 0.0)) + dt
			if float(b.home_t) >= SWARM_TURN_GAP:
				b.home_t = 0.0
				b.homing = int(b.homing) - 1
				_steer_dart(b)
		b.p = prev + (b.v as Vector2) * dt
		# Frag rounds expire. Shrapnel that outlives its parent would become a
		# free shotgun ticking across the screen.
		if b.has("frag_life"):
			b.frag_life = float(b.frag_life) - dt
			if float(b.frag_life) <= 0.0:
				pb.remove_at(i)
				i -= 1
				continue
		# Trail: keep the last few positions so the shot leaves a streak.
		# A shot moving 334px/s covers ~5.6px per frame, so a straight line from
		# the previous position is already a 5px tail; storing three positions
		# extends it and lets the tail curve if the vector ever changes.
		#
		# The span is PER TIER (see _wake_span). Trimming every round to the
		# global TAIL_LEN is what made a tier unable to ask for a longer tail,
		# and raising the global would have lengthened all seven at once.
		#
		# `pin_p` is probe-only (HALFMOON_STATE=tier): the round is held at a
		# fixed point and given a synthetic level wake, because a round that
		# actually flies leaves the field in 0.36s and the shutter photographs
		# an empty field. Kept inside the normal path rather than in the probe
		# so the wake it shows is produced by the SAME _wake_span the game uses
		# -- otherwise the probe would be measuring its own idea of the tail.
		if b.has("pin_p"):
			var pp: Vector2 = b.pin_p
			b.p = pp
			var pq: Array = []
			for ps in 26:
				pq.append(Vector2(pp.x - float(ps), pp.y))
			trim_trail(pq, _wake_span(int(b.get("wk", WEAPON_BASE))))
			b.trail = pq
			pb[i] = b
			i -= 1
			continue
		var tr: Array = b.get("trail", [])
		tr.push_front(prev)
		trim_trail(tr, _wake_span(int(b.get("wk", WEAPON_BASE))))
		b.trail = tr
		pb[i] = b
		if (b.p as Vector2).x > CULL_X_RIGHT:
			pb.remove_at(i)
		i -= 1
	if boss.is_empty():
		return
	var bb := boss
	var bp: Vector2 = bb.p
	var j := pb.size() - 1
	while j >= 0:
		var b2: Dictionary = pb[j]
		if (b2.p as Vector2).distance_to(bp) <= float(bb.r) * 0.86:
			# Damage and pierce apply to the boss too, otherwise the laser tier
			# would be a downgrade against the one target it is meant for.
			var pierce: int = int(b2.get("pierce", 1)) - 1
			var bdmg: int = maxi(1, int(b2.get("dmg", 1)))
			var bwk: int = int(b2.get("wk", WEAPON_BASE))
			bb.hp = int(bb.hp) - bdmg

			# ---- boss hit feedback ------------------------------------
			# A boss that only flinched for 0.12 s with two debris specks read as
			# a health bar being ground down rather than a body being hit. On a
			# 28 px silhouette every connect needs to be legible.
			#
			# Three layers, all scaled by tier so the bomb and the MG still read
			# differently against a large target:
			#   flash   闁?the hurt tint on the disc itself
			#   chip    闁?a paper bite at the impact point, so the round reads as
			#             removing something
			#   ring    闁?a small shock at the contact, sized below the body so
			#             it never competes with the boss's own health arc
			var bheavy := 0.0
			match bwk:
				WEAPON_BOMB: bheavy = 1.0
				WEAPON_RAIL: bheavy = 0.8
				WEAPON_LASER: bheavy = 0.6
				WEAPON_FLAK: bheavy = 0.45
				WEAPON_SPREAD: bheavy = 0.35
				WEAPON_BASE: bheavy = 0.2
				WEAPON_SWARM: bheavy = 0.10
				_: bheavy = 0.0
			# A frag on a boss is still a frag: it arrives as debris, not as a
			# shell, so its weight is pushed below even SWARM's.
			var b_is_frag := bool(b2.get("frag", false))
			if b_is_frag:
				bheavy = 0.05
			bb.hurt = 0.12 + bheavy * 0.22
			var hit_at: Vector2 = b2.p as Vector2
			puff(hit_at, 2 + int(bheavy * 6.0))
			# Chip: a 2..4 px paper bite for a beat, then it heals over.
			var chip := 2 + int(bheavy * 2.0)
			if bwk == WEAPON_RAIL:
				# The rod is the only round that arrives with its own width, so
				# it takes a wider bite out of the disc. On a 56px silhouette a
				# 4px notch is the biggest single-fact mark the surface can take
				# without reading as damage geography.
				chip = 4
			if b_is_frag:
				chip = 1
			bb.chip = {"p": hit_at, "t": 0.0, "r": float(chip)}
			rings.append({"c": hit_at, "r0": 1.0, "r1": 6.0 + bheavy * 10.0, "r": 1.0,
				"t": 0.0, "w": 0.7 + bheavy * 0.5, "life": 0.16 + bheavy * 0.10})
			if bwk == WEAPON_LASER:
				# The pierce tier leaves a burning line rather than a pop.
				rings.append({"c": hit_at, "r0": 3.0, "r1": 3.0 + bheavy * 8.0, "r": 3.0,
					"t": 0.0, "w": 1.0, "life": 0.22})
			# ---- boss-unique contact marks ---------------------------
			# The same three marks, scaled for a 28px silhouette: bites pushed
			# out to r 3 so they clear the boss's own health arc, shards faster,
			# trough long enough to bite the disc instead of sitting inside it.
			match bwk:
				WEAPON_SWARM:
					_mark_bites(hit_at, 3.0, 0.10)
				WEAPON_FLAK:
					_mark_shards(hit_at, b2.v as Vector2, 72.0 + bheavy * 30.0, 0.22)
				WEAPON_RAIL:
					_mark_trough(hit_at, 6, 0.18)
			if b_is_frag:
				var bav := (b2.v as Vector2).normalized()
				_mark_split(hit_at, Vector2(-bav.y, bav.x), 0.14)
			if pierce <= 0:
				pb.remove_at(j)
		j -= 1
	if int(bb.hp) <= 0:
		if boss.has("is_rival"):
			beat_rival()
		elif boss.has("is_elite"):
			beat_elite()
		else:
			beat_boss()


func beat_boss() -> void:
	var bp: Vector2 = boss.p
	boss = {}
	score += 12
	add_shake(4.5)
	flash = 0.55
	puff(bp, 44)
	rings.append({"c": bp, "r0": 15.0, "r1": 150.0, "r": 15.0, "t": 0.0, "w": 1.4, "life": 1.6})
	gauge = minf(1.0, gauge + 0.28)
	# The boss drops THREE caches in a fan. It is the end of the boss stage and
	# the only reasonable place to hand the player a real power spike before
	# the duel that follows.
	_spawn_cache(bp)
	_spawn_cache(bp + Vector2(-14.0, -20.0))
	_spawn_cache(bp + Vector2(-14.0, 20.0))
	eb.clear()
	# The loop does NOT advance here any more.
	#
	# It used to: `loop_n += 1` plus a `t` rewind to BOSS_AT - 18..34 s. That
	# worked when the boss was the last stage of a loop, and breaks the moment
	# there is a stage after it — the rewind lands below BOSS_AT, the boss clock
	# re-arms first, and the duel stage can never start.
	#
	# Instead this flag promotes the loop into its duel stage, and `beat_rival`
	# owns the advance. One stage owns the loop counter, and it is the last one.
	boss_beat_this_loop = true
	sync_backdrop()


func step_eb(dt: float) -> void:
	var i := eb.size() - 1
	while i >= 0:
		var b: Dictionary = eb[i]
		# ---- lure homing ------------------------------------------------
		# `lure_t` counts down while the round flies straight; when it hits
		# zero the velocity vector is steered toward the player's CURRENT
		# position and then frozen there.
		#
		# Steering toward the player every frame would be an undodgeable homing
		# missile 鈥?the only counter would be to keep moving forever. One
		# steering event is fair: it punishes "predict the launch angle" without
		# taking the dodge away, because the turn itself is slow enough to react
		# to and the new heading is fixed once set.
		if b.has("lure_t"):
			var lt: float = float(b.lure_t) - dt
			if lt <= 0.0:
				var v0: Vector2 = b.v as Vector2
				var want := (player - (b.p as Vector2))
				if want.length() > 1.0:
					var turn := v0.normalized().lerp(want.normalized(), 0.85).normalized()
					b.v = turn * float(b.get("lure_sp", v0.length()))
					# The trail is dropped on the turn: keeping the old wake
					# makes the round read as still travelling in the old
					# direction while its head walks off the line.
					b.trail = [b.p]
				b.erase("lure_t")
			else:
				b.lure_t = lt
		var prev: Vector2 = b.p
		var p: Vector2 = prev + (b.v as Vector2) * dt
		b.p = p
		# Probe hold (HALFMOON_STATE=tier): same reason as the friendly branch --
		# a hostile round at 300px/s crosses the field in 0.9s, so the shutter
		# photographs empty space and the wake can never be inspected. The trail
		# is rebuilt level from the SAME _wake_span the game uses, so what is
		# photographed is the real hostile span and the real hostile stamp.
		if b.has("pin_p"):
			var hpp: Vector2 = b.pin_p
			b.p = hpp
			var hq: Array = []
			for hs in 26:
				hq.append(Vector2(hpp.x + float(hs), hpp.y))
			trim_trail(hq, _wake_span(int(b.get("wk", WEAPON_BASE)), true))
			b.trail = hq
			eb[i] = b
			i -= 1
			continue
		# Trail history, trimmed by distance so the tail is the same length at
		# any frame rate. See trim_trail().
		#
		# Hostile rounds get their own span table (`hostile = true`): the twin's
		# BOMB shell is the one hostile round with mass, and it asks for 17px.
		# Reading `wk` here is what keeps that promise; the hostile default is
		# still TAIL_LEN, so the other tiers are unchanged.
		var tr: Array = b.get("trail", [])
		tr.push_front(prev)
		trim_trail(tr, _wake_span(int(b.get("wk", WEAPON_BASE)), true))
		b.trail = tr
		b.life = float(b.life) - dt
		if float(b.life) <= 0.0 or p.x < CULL_X_LEFT or p.x > CULL_X_RIGHT \
				or p.y < CULL_Y_TOP or p.y > CULL_Y_BOTTOM:
			eb.remove_at(i)
			i -= 1
			continue
		eb[i] = b
		if invuln <= 0.0 and player.distance_to(p) <= float(b.r) + 2.0:
			eb.remove_at(i)
			# ---- per-tier damage ------------------------------------------
			# The twin now fires more than one tier, so a hostile round that
			# carries BOMB has to hurt like one. `hurt_player()` costs exactly
			# one hull segment, so the tiers differ in WHAT THEY THREATEN
			# rather than in how many segments they take: a BOMB round also
			# knocks the craft harder and shakes more, which is the difference
			# the player feels without a second health model.
			var hwk := int(b.get("wk", WEAPON_BASE))
			hurt_player()
			if hwk == WEAPON_BOMB:
				add_shake(3.0, p)
				flash = maxf(flash, 0.75)
				rings.append({"c": p, "r0": 4.0, "r1": 34.0, "r": 4.0,
					"t": 0.0, "w": 1.4, "life": 0.32})
				puff(p, 12)
		i -= 1


# ---- passive items: pickup cue --------------------------------------------
#
# One function, three intensities, and the intensity ORDER must be readable
# without knowing the item: shield < thorn < barrage.
#
# All three follow one rule that comes from draw_rings using a = 0.85*fade^2:
# a ring is only visible for the first THIRD of its life. So every ring here
# starts at (or very near) its final radius and dies inside 0.22 s -- the
# impact lives in the first 0.1 s by construction, not by tuning.
#
# Nothing here writes a field that no reader touches. In particular NO "t" is
# written into a `sparks` entry: step_sparks only counts `life` down and never
# reads `t`, so a `t` there is a dead field (this file's 12th silent-failure
# class -- see the barrage for where that already happened).
func _item_pick_fx(item: int, at: Vector2) -> void:
	var a0 := Vector2(floorf(at.x), floorf(at.y))
	match item:
		ITEM_SHIELD:
			# LIGHT, and it must say "something closed around me". Both rings
			# CONTRACT: r0 big, r1 small. A contracting ring is the one motion
			# that reads as a layer seating itself; an expanding one would read
			# as a hit, which is the opposite of what a free pickup means.
			#
			# w = 1.0 on both on purpose: at w > 1.2 draw_rings adds a THIRD
			# concentric stroke, and three rings for the lightest item in the
			# game is exactly the intensity inversion this ordering forbids.
			rings.append({"c": a0, "r0": 22.0, "r1": 6.0, "r": 22.0,
				"t": 0.0, "w": 1.0, "life": 0.15})
			rings.append({"c": a0, "r0": 15.0, "r1": 4.0, "r": 15.0,
				"t": 0.0, "w": 1.0, "life": 0.10})
			# Six slow specks, no gravity, no core: dust being displaced by a
			# shell, not debris from a break.
			for k in 6:
				var a := TAU * float(k) / 6.0 + 0.26
				var life := 0.11
				sparks.append({
					"p": a0,
					"v": Vector2(34.0, 0.0).rotated(a),
					"life": life, "max": life,
					"g": 0.0, "w": 1, "core": false,
				})
		ITEM_THORN:
			# MEDIUM and POINTED: "loaded". Sharpness comes from RIGID wedges,
			# not from fast dots -- the same 3-pixel wedge `_mark_shards` uses,
			# so the two effects speak one vocabulary. Each wedge's three
			# pixels share one velocity and one gravity, so the triangle
			# travels as a piece and never degrades into three dots.
			#
			# One ring only, w 1.6 -> that one entry draws three concentric
			# strokes, which is already the middle intensity. Expanding, so it
			# reads as the shards being driven outward by the load.
			rings.append({"c": a0, "r0": 12.0, "r1": 28.0, "r": 12.0,
				"t": 0.0, "w": 1.6, "life": 0.18})
			for k in 10:
				var a := TAU * float(k) / 10.0
				var sd := Vector2(1.0, 0.0).rotated(a)
				var nm := Vector2(-sd.y, sd.x)
				for tip in [sd, nm, -nm]:
					var to: Vector2 = tip
					var life := 0.14
					sparks.append({
						"p": a0 + Vector2(floorf(to.x), floorf(to.y)),
						"v": sd * 130.0,
						"life": life, "max": life,
						"g": 0.0, "w": 1, "core": false,
					})
			add_shake(2.0, a0)
		ITEM_BARRAGE:
			# HEAVY, and it must NOT read as an explosion (that is THORN's
			# blast and ERASE's sweep). The mark is a SIGNAL COLUMN: eight
			# specks dropped in a vertical line ABOVE the craft, all falling at
			# one speed, converging on the ship inside 0.13 s. "Something was
			# called down onto me" -- one direction, one column, no radius.
			#
			# It is centred ON THE CRAFT, while the barrage's own strike lands
			# on the far side of the field; the two never share a centre, which
			# is what keeps the summon and the bombardment separable.
			#
			# 320 px/s x 0.13 s = 41px: the topmost speck (41px up) reaches
			# the craft exactly as it dies, so the column visibly ARRIVES
			# rather than hanging in the air.
			for k in 8:
				var life := 0.13
				sparks.append({
					"p": a0 + Vector2(0.0, -6.0 - float(k) * 5.0),
					"v": Vector2(0.0, 320.0),
					"life": life, "max": life,
					"g": 0.0, "w": 2 if k == 3 else 1,
					"core": k == 3,
				})
			# One wide ring, w 1.6: one entry, three strokes, 42px reach. The
			# widest of the three, which is how the heaviest item announces
			# itself without any part of it being bigger on the plate.
			rings.append({"c": a0, "r0": 6.0, "r1": 42.0, "r": 6.0,
				"t": 0.0, "w": 1.6, "life": 0.22})
			add_shake(3.0, a0)
# ---- passive items: pickup ------------------------------------------------
#
# "同道具不可叠加，只能刷新为初始状态" -- every branch RESETS, it never adds.
# That is why each passive is a plain scalar (a charge count or a bool) rather
# than a counter that grows: the moment a second shield can raise the count
# above ITEM_SHIELD_CHARGES, the HUD needs a scaling readout and the balance
# stops being a constant.
#
# "不同道具可以共存" -- the three branches touch different fields, so nothing
# here can shadow anything else.
#
# The pickup CUE is a separate function (`_item_pick_fx`) so the state change
# and the visual never drift: one line per item here, one function per item
# there.
func _grant_item(item: int, at: Vector2) -> void:
	match item:
		ITEM_SHIELD:
			# Refresh, do not stack: two shields is still two charges.
			item_shield = ITEM_SHIELD_CHARGES
		ITEM_THORN:
			item_thorn = true
		ITEM_BARRAGE:
			# Fires IMMEDIATELY -- there is no held state. See the note above
			# `item_thorn` for why a flag would have been a dead field.
			trigger_barrage()
	_item_pick_fx(item, at)


# ---- passive items: THORN -------------------------------------------------
#
# A contact detonation at the point of impact. Called from hurt_player, which
# means it fires on the SAME frame as the standard hit feedback.
#
# ---- how it stays readable ON TOP of hurt_player --------------------------
#
# hurt_player already draws: shake 6.0, flash 0.55, hit_stop 0.09, one ring
# 6 -> 40 at w 1.6, 20 specks, and a knock-back. A thorn blast dropped on top
# of that unmodified would double every channel and read as one big mess
# rather than as two events.
#
# Three separations, and all three are needed:
#
#   1. IT IS STAGGERED BY ONE BEAT. The thorn's rings start at t = 0.10, after
#      the hit's own ring has already opened. The player sees "I was hit"
#      followed by "and then something hit back", which is the actual
#      narrative. Simultaneous would read as a single bigger hit.
#   2. IT IS ABOVE THE CRAFT, NOT AROUND IT. hurt_player's ring is centred on
#      the craft and expands to 40; the thorn's three rings are centred on the
#      same point but start at 14 and reach 46, i.e. they are strictly OUTSIDE
#      the hit ring at every moment they overlap. Two concentric families at
#      different radii, not one blurred blob.
#   3. ITS DEBRIS TRAVELS, THE HIT'S DEBRIS DOES NOT. hurt_player uses `puff`,
#      which is near-zero initial velocity and `g = 0` -- dust that hangs.
#      The thorn throws heavy shards at 150..260 px/s with gravity 40, so the
#      second event is the only one with outward motion.
#
# Scale: radius 46 sits between the player's BOMB (44) and the ERASE sweep
# (190). At ERASE scale this would be a second screen-clear and the passive
# would be worth more than the weapon it is supposed to support; at BOMB scale
# it would not be worth taking a hit for.
func trigger_thorn(at: Vector2) -> void:
	item_thorn = false
	# ---- the retaliation: NO RINGS AT ALL -----------------------------
	#
	# Rings were the wrong instrument here, and it took two failed captures to
	# see why. `draw_rings` draws THREE concentric strokes per entry (the main
	# annulus, a `rad*0.62` inner hairline, and a `rad*1.16` outer hairline
	# whenever w > 1.2). So N lobes is 3N circles on screen:
	#
	#   two concentric rings   ->  6 circles
	#   six lobes              -> 18 circles   (a rosette)
	#   three lobes            ->  9 circles   (still a rosette)
	#
	# Every attempt to encode "spikes" with more rings produced more circles,
	# because the ring pool cannot draw one circle -- it draws a family.
	#
	# So the horn's whole visual identity is carried by what the ring pool
	# does NOT do: DIRECTIONAL DEBRIS. hurt_player's feedback is a ring (no
	# direction, all radius) plus near-stationary dust; the thorn's is a
	# spray of heavy shards with an outward velocity. Ring and spray, at the
	# same centre, in the same frame, cannot be confused -- which is the
	# separation the two ring-based attempts were trying and failing to buy
	# with radius arithmetic.
	#
	# ---- TWO VELOCITY BANDS, and why one band was not enough ---------
	#
	# The single-band version threw 18 shards at 150..260 px/s. Measured
	# against the damping (step_sparks multiplies v by 1 - 3.4*dt, so a
	# shard travels v0/3.4 * (1 - e^-3.4T)), a 260 px/s shard is only 22px
	# out at 0.10s and 25px at 0.14s. The blast is 46px wide but the visible
	# cloud is 25px wide at its brightest -- the damage radius and the
	# visual radius disagreed, and the blast read as a BOMB instead of as a
	# thorn.
	#
	# The outer band therefore flies at 420..480 px/s (T=0.14s -> 47..51px),
	# so the cloud reaches the damage radius exactly when it is brightest;
	# the inner band stays slow (120..200) and lives longer, so the two
	# bands separate in time as well as in space. No new array, no new
	# field -- only velocity and life, both of which step_sparks reads.
	var rdir := (-vel).normalized()
	if rdir.x < 0.2:
		rdir = Vector2.RIGHT
	# Outer band: fast, wide, carries the blast's actual radius.
	for k in 8:
		var a := rdir.angle() + rng.randf_range(-0.62, 0.62)
		var life := rng.randf_range(0.30, 0.34)
		sparks.append({
			"p": at,
			"v": Vector2(rng.randf_range(420.0, 480.0), 0.0).rotated(a),
			"life": life, "max": life,
			"g": 30.0, "w": 2, "core": rng.randf() < 0.30,
		})
	# Inner band: slow, back-splashed, and it OUTLIVES the outer band, so the
	# blast has a second phase that reads as "and there is more of it".
	for k in 10:
		var a := rdir.angle() + PI + rng.randf_range(-0.9, 0.9)
		var life := rng.randf_range(0.40, 0.50)
		sparks.append({
			"p": at,
			"v": Vector2(rng.randf_range(120.0, 200.0), 0.0).rotated(a),
			"life": life, "max": life,
			"g": 55.0, "w": 1 + (1 if rng.randf() < 0.3 else 0),
			"core": false,
		})
	# A paper-colour flash on the hull, NOT a white one. Measured against
	# draw_flash's quantisation (floor(flash*0.70*8)/8), keeping flash at
	# hurt_player's own 0.55 puts the hit at alpha 0.375 -- and bumping it
	# any higher lands on 0.625, which is ERASE's value, so the two effects
	# would share a frame. NOT raising it is the only way to keep the three
	# flashes on three different steps.
	flash = maxf(flash, 0.55)
	# The shake has to point AT the attacker. `add_shake(amount, from_point)`
	# derives the kick from player - from_point, and from_point == player
	# gives a zero vector that falls back to (-1, 0) -- the wrong way for a
	# counter-attack. Passing `at - rdir * 8` makes the same subtraction
	# produce rdir, so the camera kicks toward the thing that was hit and the
	# debris flies the same way.
	add_shake(2.4, at - rdir * 8.0)
	hit_stop = maxf(hit_stop, 0.11)
	# ---- damage ---------------------------------------------------------
	var kept: Array[Dictionary] = []
	for f in foes:
		var fp: Vector2 = f.p as Vector2
		if at.distance_to(fp) > THORN_RADIUS:
			kept.append(f)
			continue
		f.hp = int(f.hp) - THORN_DMG
		if int(f.hp) > 0:
			kept.append(f)
			f.hit_t = 0.20
			puff(fp, 6)
		else:
			score += 1
			gauge = minf(1.0, gauge + ERASE_GAIN)
			var ok: int = int(f.kind)
			note_kill(fp, 1.0 if ok == 0 else (1.5 if ok == 1 else 2.0))
			puff_heavy(fp, 16)
	foes = kept
	if not boss.is_empty():
		var bp: Vector2 = boss.p as Vector2
		if at.distance_to(bp) <= THORN_RADIUS + float(boss.r) * 0.6:
			boss.hp = int(boss.hp) - THORN_DMG
			boss.hurt = 0.28
			boss.chip = {"p": bp, "t": 0.0, "r": 5.0}
			if int(boss.hp) <= 0:
				beat_boss()


# ---- passive items: BARRAGE ---------------------------------------------------
#
# "被拾取后立即清除一半敌人" -- half, once, on pickup.
#
# ---- WHICH half, and why it matters -----------------------------
#
# Killing a random half reads as a glitch: the player cannot tell the passive
# did anything, because half the craft they were aiming at are still there and
# half of some other group are gone. Killing the half that is FARTHEST RIGHT
# reads as "the barrage covered the far field" -- one continuous region, one
# direction, one story.
#
# So: sort by x descending, take the right-hand ceil(n/2). The strike therefore
# always lands on the side the player is NOT standing on, which is also the
# side they are least able to defend, i.e. the side that most needs clearing.
#
# ---- and how it differs from ERASE ------------------------------
#
# Both clear a lot of craft, so they must not look alike. ERASE is SELF-
# CENTRED: rings open FROM the craft, debris travels WITH the sweep, and the
# player is the origin of the event. A barrage has no centre at all -- it is
# ARTILLERY FROM OFF-SCREEN, so its marks enter from the right edge, and the
# region that dies is the right half rather than everything.
#
# Concretely: ERASE draws one enormous ring from the ship; the barrage draws a
# COLUMN OF SMALL IMPACTS walking in from the right edge. Different origin,
# different shape, different direction, and only one of them is centred on the
# player.
func trigger_barrage() -> void:
	if foes.is_empty() and boss.is_empty():
		return
	# ---- target selection ----------------------------------------------
	# `from_right` is decided BEFORE the sort, because the comparator reads it.
	# Declaring it below (as the first draft did) is a scope error the parser
	# catches, not a runtime bug -- the closure captures the variable, not its
	# value, so it has to exist at the point the comparator is built.
	var from_right := player.x < W * 0.5
	var ordered: Array[Dictionary] = []
	for f in foes:
		ordered.append(f)
	ordered.sort_custom(func(a, b):
		if from_right:
			return (a.p as Vector2).x > (b.p as Vector2).x
		return (a.p as Vector2).x < (b.p as Vector2).x)
	var n := ordered.size()
	var take := int(ceil(float(n) * BARRAGE_FRACTION))
	take = mini(take, n)
	var victims: Array[Dictionary] = []
	for k in take:
		victims.append(ordered[k])
	# ---- the strike: a column walking in from the right ---------------
	# Impacts are laid at the victims' own y, staggered left-to-right in TIME
	# so the column visibly travels inward.
	#
	# NO RINGS, for the same reason the thorn has none: every ring entry
	# becomes THREE concentric strokes (`draw_rings` draws rad, rad*0.62 and
	# rad*1.16), so nine impacts would be twenty-seven circles -- a cloud,
	# not a bombardment.
	#
	# Each impact is therefore a DESCENDING SHARD BURST plus one hot speck.
	# The direction is downward and in from the right, which is the whole
	# difference from ERASE: ERASE opens outward from the craft (radial,
	# self-centred), a barrage falls (directed, off-screen).
	#
	# Stagger 0.022s per impact, capped at 0.22s. The first version used 0.05
	# capped at 0.45, which spread six impacts over 0.3s -- and since the whole
	# burst has to live inside the first tenth of a second to be seen at all
	# (see the fade² argument on the thorn), most of the column was still
	# pending when the frame closed. 0.022 puts all six on screen inside
	# 0.13s, so the barrage reads as ONE strike rather than as a queue.
	# WHICH EDGE depends on where the player is. A barrage must never land on
	# the player's own head: at RIGHT_LIMIT the old right-only rule dropped
	# shells directly onto the craft, where the blast reads identically to a
	# thorn detonation and the whole "off-screen artillery" argument collapses.
	# So the half is chosen by the player's own position, and the impact
	# column enters from the edge that half belongs to.
	#
	# `from_right` was already decided above, for the comparator; it is the
	# same fact driving both, so the target set and the muzzle edge cannot
	# disagree.
	#
	# Sparks are born with `delay` (see step_sparks), NOT with a `t` field.
	# `t` was written here once and never read, which silently turned the
	# whole staggered column into one simultaneous flash.
	#
	# Per-impact gap: n=2 -> 0.042s, n=5 -> 0.042s, n=9 -> 0.028s.
	#
	# The floor is 0.028 (1.7 frames), because anything shorter reads as
	# simultaneous AND as sequential at the same time, which is the worst of
	# both. The whole column fits inside 0.20s so the first impact is still
	# in its brightest tenth when the last lands.
	var per := 0.028
	if victims.size() > 1:
		per = clampf(0.20 / float(victims.size() - 1), 0.028, 0.042)
	for k in victims.size():
		var v: Dictionary = victims[k]
		var vp: Vector2 = v.p as Vector2
		var t0 := float(k) * per
		for s in 12:
			var life := rng.randf_range(0.24, 0.42)
			# Down AND inward: the velocity field has to point the same way
			# the column is travelling, or "artillery from off-screen" reads as
			# a generic downward sprinkle.
			var vx := rng.randf_range(40.0, 140.0) * (-1.0 if from_right else 1.0)
			var vy := rng.randf_range(40.0, 120.0)
			sparks.append({
				"p": vp + Vector2(rng.randf_range(-6.0, 6.0), -6.0),
				"v": Vector2(vx, vy),
				"life": life, "max": life,
				"delay": t0,
				"g": 60.0, "w": 1,
				"core": rng.randf() < 0.35,
			})
		# One hot speck at the impact itself: a shell head, 1px, gone fast.
		var l2 := 0.16
		sparks.append({
			"p": vp, "v": Vector2.ZERO,
			"life": l2, "max": l2,
			"delay": t0,
			"g": 0.0, "w": 1, "core": true,
		})
	# ---- muzzle marks on the frame edge ------------------------------
	# The one piece of evidence that survives when only ONE craft is hit.
	# A downward sprinkle says "something fell"; it does not say WHERE it
	# came from. Five frozen pixels on the border the column entered through
	# are the only mark in the effect whose position is a statement about
	# origin rather than about the victims.
	#
	# Frozen, not travelling: sparks damp at 3.4/s, so a pixel crossing 200px
	# would need v0 ≈ 2300 and would be a bullet, not a muzzle flash. Life
	# 0.07s is about four frames of afterglow.
	var entry_x := FRAME.end.x - 2.0 if from_right else FRAME.position.x + 2.0
	for mk in 5:
		var l3 := 0.07
		sparks.append({
			"p": Vector2(entry_x, FRAME.position.y + 26.0 + float(mk) * 26.0),
			"v": Vector2.ZERO,
			"life": l3, "max": l3,
			"g": 0.0, "w": 1, "core": false,
		})
	# ---- the kill -------------------------------------------------------
	# Score, gauge and streak are credited exactly like a normal kill, or the
	# passive would be the one thing in the game that wipes a wave for free.
	var killed: Array[Dictionary] = []
	for v2 in victims:
		var vp2: Vector2 = v2.p as Vector2
		var ok: int = int(v2.kind)
		note_kill(vp2, 1.0 if ok == 0 else (1.5 if ok == 1 else 2.0))
		puff_heavy(vp2, 18)
		score += 1
		gauge = minf(1.0, gauge + ERASE_GAIN)
		killed.append(v2)
	for v3 in killed:
		for idx in range(foes.size() - 1, -1, -1):
			if foes[idx] == v3:
				foes.remove_at(idx)
				break
	add_shake(3.4)
	flash = maxf(flash, 0.30)
	hit_stop = maxf(hit_stop, 0.06)


func hurt_player() -> void:
	# ---- SHIELD absorbs the hit entirely --------------------------------
	#
	# Checked BEFORE anything else, so a shielded hit costs no hull, plays no
	# hurt feedback, and does not start the knock-back. A shield that still
	# shoves the craft around would read as a hit that was not taken, and the
	# player would start dodging hits they were immune to.
	#
	# The shield DOES set a short invulnerability. Without it a body-checked
	# craft could spend all its charges inside one continuous contact -- the
	# physical overlap lasts several frames, and "absorbs two hits" has to mean
	# two EVENTS, not two frames of one event.
	if item_shield > 0:
		item_shield -= 1
		invuln = 1.35
		# ---- the shield taking a blow, not the hull ---------------------
		# Same vocabulary as the pickup but inverted: the ring CONTRACTS
		# instead of expanding (r0 30 -> r1 6), which is the only way a ring
		# reads as "something wrapped around me and held". A shield that also
		# shook and flashed white would be a hit that cost no health, which
		# reads as a bug.
		rings.append({"c": player, "r0": 30.0, "r1": 6.0, "r": 30.0,
			"t": 0.0, "w": 2.0, "life": 0.26})
		rings.append({"c": player, "r0": 20.0, "r1": 5.0, "r": 20.0,
			"t": 0.06, "w": 1.2, "life": 0.30})
		hit_t = 0.20
		# A real but small shake: the impact is felt, the damage is not.
		add_shake(2.0, player)
		# Shards flying OUT from the break point, so the absorbed charge is
		# visibly spent rather than the blow simply vanishing.
		for k in 8:
			var a := TAU * float(k) / 8.0
			var life := 0.20
			sparks.append({
				"p": player, "v": Vector2(90.0, 0.0).rotated(a),
				"life": life, "max": life,
				"g": 20.0, "w": 1, "core": false,
			})
		return
	# ---- THORN retaliates, but only AFTER the hit resolves -------------
	# Called here rather than at the contact site so it fires for every damage
	# source with one code path. The stagger inside trigger_thorn is what keeps
	# the two events legible; it is NOT delayed in code, because delaying would
	# let a second hit land first and consume the charge against the wrong
	# event.
	var thorns := item_thorn
	hull -= 1
	invuln = 1.35
	# Impact punch: a heavy shake, a white flash, and a short hit-stop so the
	# player feels the blow rather than just losing a tick.
	add_shake(6.0, player)
	flash = 0.55
	hit_t = 0.42
	hit_stop = 0.09
	# The hull is knocked backwards along the vector it was hit from.
	vel = -vel * 0.55 + Vector2(-46.0, 0.0)
	puff(player, 20)
	# A shock ring anchors the impact in space.
	rings.append({"c": player, "r0": 6.0, "r1": 40.0, "r": 6.0, "t": 0.0, "w": 1.6, "life": 0.34})
	# The thorn fires LAST, after the hull's own feedback is queued, so its
	# rings sit on top of a fully-declared hit rather than competing with it.
	var thorn_at := player
	if hull <= 0:
		dead = true
		dead_t = 0.0
		add_shake(8.0, player)
		hit_stop = 0.22
		flash = 0.85
		rings.append({"c": player, "r0": 10.0, "r1": 96.0, "r": 10.0, "t": 0.0, "w": 2.0, "life": 0.9})
		# A lethal hit still spends the thorn: the blast is what killed the
		# attacker, and refusing to fire on death would make the passive
		# silently useless exactly when it matters most.
	if thorns:
		trigger_thorn(thorn_at)


func do_erase() -> void:
	# ---- ERASE: the tier's one big moment -----------------------------
	#
	# 2026-09-11: "优化杀敌数量满之后的清屏爆炸特效，极致的爽感".
	#
	# The old version did the arithmetic correctly and drew it flatly: one ring
	# from the craft, one 4-speck puff per craft, screen shake 3.5. On a screen
	# of up to nine targets that is nine identical small pops -- a spreadsheet
	# being deleted, not a wave being erased.
	#
	# Five things carry the weight now, in the order they are felt:
	#
	#   1. TIME STOPS FIRST. hit_stop is set BEFORE the kills are processed, so
	#      the frame the button is pressed is a held frame. The player sees the
	#      wave stop existing rather than watching it fade.
	#   2. THE SWEEP, not a ring. A ring centred on the craft says "radius";
	#      a column crossing the whole field at the wave's speed says "the
	#      screen is being wiped". It is built from the ring pool as an
	#      extremely wide, fast ring -- no new array, no new draw code.
	#   3. EVERY KILL EXPLODES ITS OWN CENTRE. Each craft gets a bright core ring
	#      plus a heavy ring, and the cores are staggered in time by their x
	#      position so the wave appears to disintegrate RIGHT TO LEFT, in the
	#      direction the wipe is travelling.
	#   4. THE DEBRIS LEANS WITH THE WIPE. puff_heavy is isotropic; a directional
	#      burst (puff_erase) throws everything to the right, so the whole field
	#      reads as motion rather than as a set of unrelated pops.
	#   5. THE SCREEN GOES WHITE FOR ONE FRAME. flash 0.75 -> 0.92 and shake
	#      3.5 -> 6.5. This is the only place in the game allowed that much
	#      flash, which is what makes it feel like a resource being spent.
	gauge = 0.0
	flash = 0.92
	# Frames are held BEFORE the kills resolve, so the impact lands on a frozen
	# frame. 0.14 is long enough to read as a punch and short enough that it
	# never feels like a stutter.
	hit_stop = maxf(hit_stop, 0.14)
	add_shake(6.5)
	invuln = 1.1
	erase_t = 0.5
	# ---- hostile fire: burned, not deleted ----------------------------------
	# Each round gets a small burst at its own position, so clearing the screen
	# is visible as many small events rather than as rounds blinking out.
	for b in eb:
		var bp: Vector2 = b.p as Vector2
		puff(bp, 2)
		rings.append({"c": bp, "r0": 1.0, "r1": 7.0, "r": 1.0,
			"t": 0.0, "w": 0.6, "life": 0.18})
	eb.clear()
	# ---- the wipe ----------------------------------------------------------
	# SHORT AND FRONT-LOADED, deliberately.
	#
	# First version put the sweep on a 1.1 s life, on the theory that a long
	# tail reads as a big gesture. Captured at 0.48s into it, the field was
	# already empty and the ring was a faint line near the border -- the effect
	# was there and could not be seen. In play the same argument applies
	# harder: a 1.1s sweep is still crossing the screen while new waves spawn
	# underneath it, so the player reads "something flashed" rather than "the
	# screen was wiped".
	#
	# The punch therefore lives in the first 0.35s and decays to nothing by
	# 0.6s. Everything below is sized so the densest sub-second of the effect
	# is what a 60fps eye actually gets.
	# The wide ring IS the wipe: it starts at the craft and crosses the whole
	# field inside 0.42s, at a low weight and enormous radius, so a 1.5px
	# stroke at 300px radius reads as a moving boundary rather than as a
	# circle drawn round the ship.
	# Radius 190, NOT 300 or 470. `Ink.ring` is a per-row scan of a filled
	# annulus: every row emits two draw_rects spanning from the inner to the
	# outer radius. Once the outer radius passes the raster edge those rects
	# get clipped to the part still on screen, and because they are horizontal
	# bars the surviving slivers line up into a DIAGONAL BAND across the plate.
	# That band was visible in the capture crossing the moon at an angle.
	#
	# 190 is the largest value where `draw_rings`' own `rad * 1.16` companion
	# ring (220) plus the craft's x (52) still lands inside 384, so the wipe
	# reaches the far edge as a COMPLETE circle.
	rings.append({"c": player, "r0": 6.0, "r1": 190.0, "r": 6.0,
		"t": 0.0, "w": 2.6, "life": 0.42})
	# A second, tighter ring for the core of the blast, so the effect has a
	# near field as well as the sweep.
	rings.append({"c": player, "r0": 4.0, "r1": 150.0, "r": 4.0,
		"t": 0.0, "w": 2.0, "life": 0.30})
	# ---- a THIRD, slow ring as the "shock floor" ---------------------
	# The two above are fast and thin, so at any single frame the player sees
	# one or two hairlines crossing the field -- measured in the capture, that
	# is exactly what it looked like: geometry, not force. This one is wide,
	# slow and heavy: it stays near the craft and gives the effect a MASS at
	# the point of origin, which is what the eye reads as a blow rather than as
	# a diagram.
	rings.append({"c": player, "r0": 10.0, "r1": 96.0, "r": 10.0,
		"t": 0.0, "w": 5.0, "life": 0.26})
	var kept: Array[Dictionary] = []
	for f in foes:
		var fp: Vector2 = f.p as Vector2
		f.hp = int(f.hp) - 9
		# ---- per-craft disintegrate -----------------------------------
		# Staggered by x so the wave comes apart right-to-left, matching the
		# direction the wipe travels. 0.0..0.55s across the field; a craft at
		# the left edge goes almost immediately, one at the right edge a beat
		# later, and the eye reads a wave being consumed.
		# Stagger by x so the wave comes apart LEFT TO RIGHT: `lag_x` grows
		# with x, so the smallest x dies first and the largest last. An earlier
		# comment here said "right-to-left", which is the opposite of the
		# arithmetic -- a comment that disagrees with the code it sits on is
		# worse than no comment, because the next person to reuse it will
		# mirror the wrong direction. Caught by review.
		var lag_x := clampf((fp.x - FRAME.position.x) / 360.0, 0.0, 1.0) * 0.22
		if int(f.hp) > 0:
			# Survived: it still gets hit hard, so the wipe is not "no-sell"
			# against a tough craft.
			kept.append(f)
			puff_erase(fp, 8)
			f.hit_t = 0.22
			rings.append({"c": fp, "r0": 3.0, "r1": 22.0, "r": 3.0,
				"t": lag_x, "w": 1.2, "life": lag_x + 0.34})
		else:
			score += 1
			gauge = 0.0
			# A bright core at the craft, then a heavy shell: two rings at two
			# sizes is what reads as "that thing came apart" rather than "that
			# thing disappeared".
			#
			# `life` INCLUDES the stagger. step_rings computes age = t + dt and
			# k = age / life, so a ring with t=0.55 and life=0.36 is already
			# past its own end on the first frame and never draws. The delay
			# therefore has to be folded into the lifespan.
			rings.append({"c": fp, "r0": 2.0, "r1": 30.0, "r": 2.0,
				"t": lag_x, "w": 1.4, "life": lag_x + 0.36})
			rings.append({"c": fp, "r0": 5.0, "r1": 58.0, "r": 5.0,
				"t": lag_x, "w": 1.8, "life": lag_x + 0.52})
			puff_erase(fp, 26)
	foes = kept
	if not boss.is_empty():
		boss.hp = int(boss.hp) - 26
		boss.hurt = 0.30
		boss.chip = {"p": boss.p as Vector2, "t": 0.0, "r": 6.0}
		# The boss takes the wipe at its own position, not at the craft: a
		# 28px disc sitting inside the sweep should visibly eat it.
		rings.append({"c": boss.p as Vector2, "r0": 8.0, "r1": 46.0, "r": 8.0,
			"t": 0.0, "w": 2.0, "life": 0.44})
		if int(boss.hp) <= 0:
			beat_boss()


# Directional debris for the ERASE wipe.
#
# puff_heavy throws evenly in all directions, which is right for a normal kill
# and wrong for a wipe: an isotropic burst counteracts the sweep, because half
# of every explosion flies backwards. This biases the cone to +X, so the whole
# field's debris travels WITH the wipe and the screen reads as one gesture.
func puff_erase(p: Vector2, n: int) -> void:
	for i in n:
		var a := rng.randf_range(-0.85, 0.85)
		var sp := rng.randf_range(70.0, 210.0)
		var life := rng.randf_range(0.22, 0.62)
		sparks.append({
			"p": p,
			"v": Vector2(sp, 0.0).rotated(a),
			"life": life, "max": life,
			"g": rng.randf_range(-6.0, 14.0),
			"w": 1 + (1 if rng.randf() < 0.4 else 0),
			"core": rng.randf() < 0.35,
		})


func puff(p: Vector2, n: int) -> void:
	for i in n:
		var a := rng.randf() * TAU
		var sp := rng.randf_range(12.0, 66.0)
		sparks.append({
			"p": p,
			"v": Vector2(sp, 0.0).rotated(a),
			"life": rng.randf_range(0.22, 0.60),
			"max": 0.60,
			"g": 0.0,
			"w": 1,
		})


# Heavier debris: bigger specks that arc, drift and fade. Used on kills and
# on the hull taking a hit, where plain dust reads as too quiet.
#
# `core` is now explicit. Only a fraction of heavy debris is flagged hot, so a
# kill still throws a few white sparks that the bloom chain can catch, without
# turning the whole burst into light. Callers that want a silent puff of dust
# leave it false.
func puff_heavy(p: Vector2, n: int) -> void:
	for i in n:
		var a := rng.randf() * TAU
		var sp := rng.randf_range(28.0, 132.0)
		sparks.append({
			"p": p,
			"v": Vector2(sp, 0.0).rotated(a),
			"life": rng.randf_range(0.30, 0.85),
			"max": 0.85,
			"g": rng.randf_range(-8.0, 26.0),
			"w": 1 + (1 if rng.randf() < 0.35 else 0),
			"core": rng.randf() < 0.28,
		})


# ---- per-tier contact marks -------------------------------------------------
#
# Each new tier owns exactly ONE extra contact layer, and it is carried by the
# two arrays that already exist: `sparks` and `rings`. No new array, no new
# dictionary field -- a field written into a round dictionary that no reader
# touches is this project's twelfth silent-failure class.
#
# Three helpers instead of hand-copied blocks at each of the two contact sites
# (ordinary craft, boss): both sites need the same mark at two scales, and two
# copies is exactly how the small version and the big version drift apart.

func _mark_bites(p: Vector2, r: float, life: float) -> void:
	# SWARM: three 1px bites, frozen, gone in a tenth of a second.
	#
	# Not debris. Debris implies mass, and SWARM is the lightest round in the
	# game. Three pixels pinned round the contact read as teeth rather than as
	# a small explosion, and because they never move they cost one dictionary
	# each and nothing at all in the step pass.
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.52
		sparks.append({
			"p": p + Vector2(floorf(cos(a) * r), floorf(sin(a) * r)),
			"v": Vector2.ZERO,
			"life": life, "max": life,
			"g": 0.0, "w": 1, "core": false,
		})


func _mark_shards(p: Vector2, dir: Vector2, speed: float, life: float) -> void:
	# FLAK: three wedge shards thrown APART along the round's own line of
	# travel -- one above the axis, one on it, one below.
	#
	# Each shard is a RIGID 3-pixel wedge: one tip pixel ahead, two flanking
	# pixels behind it. All three pixels of a wedge carry the SAME velocity and
	# the same gravity, so the wedge travels as one piece and never deforms.
	# Give them independent velocities and the triangle degrades into three
	# unrelated dots inside one frame -- which is why this is one loop over
	# three directions, not three separate specks.
	if dir.length() < 0.5:
		dir = Vector2.RIGHT
	var d := dir.normalized()
	for sd in [-0.42, 0.0, 0.42]:
		var sdir := d.rotated(float(sd))
		var nrm := Vector2(-sdir.y, sdir.x)
		for tip in [sdir, nrm, -nrm]:
			var to: Vector2 = tip
			sparks.append({
				"p": p + Vector2(floorf(to.x), floorf(to.y)),
				"v": sdir * speed,
				"life": life, "max": life,
				"g": 18.0, "w": 1, "core": false,
			})


func _mark_trough(p: Vector2, half: int, life_t: float) -> void:
	# RAIL: a horizontal ink slot cut across the contact, 3px tall and
	# 2*half px long, which CLOSES from both ends and is gone in 0.18 s.
	#
	# The shrink is free. The existing spark stepper only counts `life` down,
	# so handing the outer pixels SHORTER lives makes the row retract toward
	# its own centre with no new code, no new field, and no per-frame maths
	# anywhere: the ends simply run out of life first.
	#
	# The cross-section tapers too: the middle row runs the full length, the
	# two flanking rows are shorter, so the slot reads as a cut rather than as
	# a solid bar laid on top of the target.
	for row in 3:
		var ty := float(row - 1)
		var span := half if row == 1 else mini(half, 3)
		for tx in range(-span, span):
			var t := life_t * (1.0 - absf(float(tx)) / float(span + 1))
			sparks.append({
				"p": p + Vector2(float(tx), ty),
				"v": Vector2.ZERO,
				"life": maxf(t, 0.04), "max": life_t,
				"g": 0.0, "w": 1, "core": false,
			})


func _mark_split(p: Vector2, across: Vector2, life_s: float) -> void:
	# SPREAD frag: two 1px chips knocked out SIDEWAYS from the wound.
	#
	# The only contact in the game that resolves PERPENDICULAR to the round
	# that caused it. Every other tier's mark runs along the round's own line:
	# FLAK's shards fly back down it, RAIL's slot is cut across it, SWARM's
	# bites sit on a ring round it, LASER adds a second ring, BOMB adds the
	# blast ring, and MG/BASE add nothing but the shared spray. Two flecks
	# leaving to either side is a chip knocked off an EDGE, which is what a
	# fragment landing looks like.
	#
	# Life 0.14 s, travel under 7 px, no gravity: both flecks die inside the
	# wound. A single frag burst puts up to four of these on screen at once,
	# so none of them may become something the player has to track.
	if across.length() < 0.5:
		across = Vector2.UP
	var sd := across.normalized()
	for sgn in [-1.0, 1.0]:
		sparks.append({
			"p": p + Vector2(floorf(sd.x * sgn), floorf(sd.y * sgn)),
			"v": sd * (sgn * 46.0),
			"life": life_s, "max": life_s,
			"g": 0.0, "w": 1, "core": false,
		})


func step_sparks(dt: float) -> void:
	var i := sparks.size() - 1
	while i >= 0:
		var s: Dictionary = sparks[i]
		# ---- delayed birth -------------------------------------------------
		# `delay` is a REAL countdown, not a flag. A spark with delay > 0 does
		# not exist yet: it does not move, it does not age, and draw_sparks
		# skips it. This is how a staggered impact is expressed without adding
		# a second array or a per-frame timer per effect.
		#
		# It replaces the `t` field that was written on the barrage's sparks.
		# step_sparks never read `t`, so every impact in that column spawned
		# on the SAME frame and the intended 0.022 s cadence did not exist --
		# only the rings were staggered. The field was dead on arrival, which
		# is this project's twelfth silent failure with a passive item on it.
		var delay := float(s.get("delay", 0.0))
		if delay > 0.0:
			s.delay = delay - dt
			sparks[i] = s
			i -= 1
			continue
		s.p = (s.p as Vector2) + (s.v as Vector2) * dt
		s.v = (s.v as Vector2) * (1.0 - 3.4 * dt)
		# Vertical drift: heavier specks arc down, so debris reads as weight.
		s.v = (s.v as Vector2) + Vector2(0.0, float(s.g) * dt)
		s.life = float(s.life) - dt
		if float(s.life) <= 0.0:
			sparks.remove_at(i)
		else:
			sparks[i] = s
		i -= 1


func step_rings(dt: float) -> void:
	var i := rings.size() - 1
	while i >= 0:
		var r: Dictionary = rings[i]
		# Ease-out expansion: fast at birth, slowing as it dissipates, which
		# reads as a shockwave rather than a mechanical growth.
		var age := float(r.t) + dt
		r.t = age
		var life := float(r.get("life", 1.9))
		var k := clampf(age / life, 0.0, 1.0)
		var ease := 1.0 - pow(1.0 - k, 2.4)
		r.r = float(r.r0) + (float(r.r1) - float(r.r0)) * ease
		if age >= life:
			rings.remove_at(i)
		else:
			rings[i] = r
		i -= 1


# -------------------------------------------------------------------- drawing

func _draw() -> void:
	# Camera shake, done properly:
	#   - a decaying sinusoid per axis at two different frequencies, so the two
	#     axes never line up into a diagonal slide;
	#   - multiplied by a fast noise wobble for grit;
	#   - quantised to whole raster pixels at the END, so a shake of 2px stays a
	#     clean 2px kick instead of smearing sub-pixel softness into the art.
	# The previous version picked a random integer every frame, which read as
	# jitter rather than impact 闂?no shape, all noise.
	var sh := Vector2.ZERO
	if shake > 0.0:
		var age := shake_age
		var fall := exp(-age * 7.0)
		var amp := shake * fall
		var ox := sin(age * 43.0) * 0.6 + sin(age * 11.0) * 0.4
		var oy := cos(age * 37.0) * 0.6 + cos(age * 8.3) * 0.4
		# Rotate the shake's phase per hit so every blow feels slightly different.
		var rot := sin(shake_seed * 5.1)
		var dx := ox * cos(rot) - oy * sin(rot)
		var dy := ox * sin(rot) + oy * cos(rot)
		sh = Vector2(roundf(dx * amp), roundf(dy * amp))
		# Bias: a hit should push the field AWAY from the impact point.
		sh += shake_dir * roundf(amp * 0.55)

	draw_set_transform(sh, 0.0, Vector2.ONE)

	draw_rings()
	draw_pb()
	draw_foes()
	draw_boss()
	draw_eb()
	draw_player()
	draw_caches()
	draw_sparks()
	draw_frame_hi()
	draw_hud()
	draw_flash()
	draw_overlay()
	draw_pause_layer()

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_paper() -> void:
	draw_rect(Rect2(0.0, 0.0, W, H), PAPER, true)


# Re-stroke only the inner bezel: cheap, keeps the frame crisp above the game,
# while the heavy corner blocks stay baked in the backdrop node.
func draw_frame_hi() -> void:
	Ink.rect(self, FRAME, 1.0)


func draw_grain() -> void:
	pass


func draw_rings() -> void:
	for r in rings:
		var rad := float(r.r)
		var life := float(r.get("life", 1.9))
		var fade := clampf(1.0 - float(r.t) / life, 0.0, 1.0)
		if fade <= 0.0:
			continue
		# Squared falloff: bright at birth, gone quickly, no lingering ghosts.
		var a := fade * fade
		var wv := float(r.get("w", 1.0))
		Ink.ring(self, r.c as Vector2, rad, wv, Color(INK.r, INK.g, INK.b, 0.85 * a))
		Ink.ring(self, r.c as Vector2, rad * 0.62, 1.0, Color(INK.r, INK.g, INK.b, 0.38 * a))
		if wv > 1.2:
			Ink.ring(self, r.c as Vector2, rad * 1.16, 1.0, Color(INK.r, INK.g, INK.b, 0.30 * a))


const CORE := Color(1.0, 1.0, 0.97)   # only this reaches the bloom gate

# Hit-flash colour, pinned just under the bloom gate.
#
# The bloom chain keys on luminance above 0.915, and paper itself sits at
# 0.9078 闂?so on this palette there is no such thing as "bright but not
# glowing". Anything hotter than paper launches the glow pass, which is what
# turned every enemy hit into a light bomb. Flash therefore has to read as the
# ink LIFTING toward paper, not as a white knock-out: same hue as the stock,
# lower alpha. That is also why it looks softer than a pure-white stamp.
const FLASH := Color(0.915, 0.902, 0.845)

func trim_trail(tr: Array, span_limit := TAIL_LEN) -> void:
	# Keep whatever number of samples spans `span_limit` source pixels.
	#
	# Trimming by sample count was the bug behind "the trail does not exist":
	# at high frame rates one step is under a pixel, so three or four samples
	# covered barely two pixels and the tail hid entirely inside the round's
	# own paper pad. Distance is the only unit that survives a change of frame
	# rate, and it makes friendly and hostile wake match at any speed.
	#
	# `span_limit` is per-call so a tier can ask for a longer wake without
	# moving the global TAIL_LEN and silently lengthening every other round.
	# A per-tier tail is what "give the laser and the swarm a distinct trail"
	# actually requires; one global constant can only make every tracer the
	# same length.
	var span := 0.0
	var keep := 1
	while keep < tr.size():
		span += (tr[keep - 1] as Vector2).distance_to(tr[keep] as Vector2)
		if span > span_limit:
			break
		keep += 1
	if keep < 2 and tr.size() >= 2:
		# A single step can be longer than the limit on a slow frame (520px/s at
		# 20fps covers 26px). Resizing to one point would drop the wake entirely
		# for that frame, so always keep a pair and let the streak be as long as
		# one step.
		keep = 2
	if keep < tr.size():
		tr.resize(keep)


# Per-tier wake geometry, in source pixels of TRAVELLED DISTANCE.
#
# This is the only place a tier may deviate from TAIL_LEN. Putting a longer tail
# here and not in the global constant is the whole point of the parameter: a
# global bump lengthens all seven tiers at once, which is not a design change,
# it is a smudge.
#
# Only two tiers ask for more:
#
#   LASER  22  the needle is 9px of body plus a 3px collar; a 13px wake is
#              barely longer than the round itself, so the beam had no tail --
#              it was a scratch with a smudge behind it.
#   SWARM  19  the darts steer. A 2px-pitch dotted wake needs length to SHOW
#              the curve, and the curve is the only evidence that the round
#              turned at all.
#
# Everything else stays on TAIL_LEN, so five of the seven tiers are pixel-for-
# pixel what they were before this change.
func _wake_span(wk: int, hostile := false) -> float:
	if hostile:
		# The twin's shell is the only hostile round with MASS: a 4.8px disc at
		# 300px/s with a 13px wake is a fat thing dragging a stub. 17px is not
		# decoration, it is the length at which the eye reads "that one is
		# heavy" before the disc arrives -- and it matters, because that round
		# costs a hull segment AND a hard shake.
		#
		# BASE / MG hostile rounds stay at TAIL_LEN: they arrive in volleys, and
		# a screen full of long wakes is a screen with no negative space left
		# to dodge into.
		if wk == WEAPON_BOMB:
			return 17.0
		return TAIL_LEN
	match wk:
		WEAPON_LASER:
			return 22.0
		WEAPON_SWARM:
			return 19.0
		_:
			return TAIL_LEN


# Per-tier wake shape. Alphas and geometry only -- span lives in _wake_span()
# and nowhere else, so the number cannot drift between the sampler and the
# painter.
#
# The keys exist because a wake is a STAMP and the tiers disagree about the
# stamp, not about the path:
#
#   pitch  distance between stamped cells. 1 = a continuous line; 2 = a dotted
#          line whose gaps are real gaps. SWARM's identity is three tiny things,
#          and a continuous wake turns it back into one thing.
#   dash   alternate one ink cell with one paper cell. Over cream the ink cells
#          are the dashes; over the ink moon the paper cells are. A single-
#          colour dotted line survives on only one of those grounds.
#   rails  1 = one cell per step. 2 = two cells, at y-1 and y+1, with a paper
#          seam between them: a TUBE rather than a scratch.
#   split  how many px keep both rails. After it the wake closes to one
#          hairline at reduced alpha, and that step down is the read that says
#          "the light is losing coherence behind the point".
#
# Returning {} means "the stock tracer", which is exactly the pixel every tier
# got before: the caller supplies 0.46 / 0.72 as the default at the call site,
# where those numbers have always been visible.
#
# NO WAKE KEY EMITS CORE BY DEFAULT, and that is a deliberate budget decision
# rather than an omission. A CORE cell on a wake looks free -- one pixel per
# round -- but the tiers that fire MANY rounds per trigger multiply it: MG runs
# ~7 rounds on screen, SPREAD 9 pellets, FLAK 10 chunks. A hot wake cell would
# turn each of those into its own light source and the field would read as a
# string of lamps.
#
# `hot` is the one exception and it is opt-in per tier: [step, count] marks a
# short run of CORE cells along the polyline. Two properties make it safe where
# a blanket `head_hot` would not be:
#
#   1. it is a DISTANCE index, so the run stays the same size after a turn;
#   2. the run is CONTIGUOUS, and bloom_bright downsamples with a four-point
#      MAX, so k contiguous pixels survive at half resolution as roughly k/2
#      bright px -- whereas k scattered pixels survive as k separate ones. Same
#      gate_px, but one cluster instead of k, which is the number that decides
#      whether the glow reads as light or as lamps.
#
# Only SWARM sets it: see its arm below for why the tier that owns a paper pad
# cannot carry a body core at all.
func _wake_cfg(wk: int, hostile := false) -> Dictionary:
	if hostile:
		# The twin's wake is a TIER TELL, not decoration.
		#
		# The rival only rotates BASE / BOMB / MG, and BASE and MG draw the
		# SAME square pellet -- so before this there was no way to read which
		# of the two you were being shot with except by counting arrival rate,
		# which is exactly the thing you cannot do while dodging. The wake now
		# answers it: a rapid tier leaves a dash, a heavy tier leaves a thick
		# tail. Both are made of ink, so nothing new feeds the glow chain.
		match wk:
			WEAPON_BOMB:
				# Thick for the first stretch, then one closed hairline. The
				# taper is what makes it read as mass slowing down rather than
				# as a rectangle with a leak.
				return {"ink": 0.60, "paper": 0.90, "rails": 2, "split": 6.0}
			WEAPON_MG:
				# Distance-pitched dashes: a stream, not a corridor.
				return {"ink": 0.55, "paper": 0.85, "dash": true, "pitch": 2.0}
			_:
				return {}
	match wk:
		WEAPON_LASER:
			# PRISM WAKE. The body is a tube: ink rail, paper seam, ink rail.
			# A stock 1px tracer behind that reads as a scratch escaping from a
			# pipe, because the tube simply stops. Continuing the two rails and
			# then collapsing them into one hairline is the only shape that
			# says the beam came apart BEHIND the point instead of being cut
			# off behind it, and it costs two extra rects per step.
			#
			# ink 0.40 not 0.46: there are two lit cells per step instead of
			# one, so the same alpha would read twice as heavy as the tracer.
			#
			# split 14 and not 9, and the number is measured against the BODY,
			# not chosen. The needle's body is 9px of rails plus a collar, and
			# it is drawn AFTER the wake -- so every wake cell inside those 9px
			# is painted and then covered. At split=9 the whole tube portion of
			# the wake existed only where the body already is, i.e. its visible
			# length was ZERO: the first capture showed a 1px line behind the
			# beam, exactly the scratch-coming-out-of-a-pipe read this was
			# meant to fix. At 14 there are 5px of visible tube past the body
			# and then 8px of closing hairline, which is the intended sequence.
			return {"ink": 0.40, "paper": 0.90, "rails": 2, "split": 14.0}
		WEAPON_SWARM:
			# DART WAKE, and it follows the TRAIL, not the -X axis.
			#
			# The previous version stamped `sx - kk`: a straight horizontal
			# line. That was a lie the moment a dart steered. These rounds turn
			# up to four times, and after each turn the old wake still pointed
			# -X, i.e. down a direction the dart had not flown since -- the
			# faster the steering, the more wrong it looked. Walking the actual
			# polyline fixes it for free, because the walker already exists.
			#
			# pitch 2 is the dash, expressed as DISTANCE so the gap is the same
			# size after a turn as before one. Skipping cells instead would tie
			# the gap to sample count, and step_pb pushes a sample per FRAME --
			# the dash would change length with frame rate.
			#
			# `hot` [2, 2]: SWARM was the ONLY tier with no CORE pixel anywhere,
			# and it cannot simply be given one on the body. Its round is a 3x3
			# PAPER pad with a 1px ink dot inside, and that pad is doing real
			# work -- it is the liner that lets a 1px dot exist over the boss
			# disc. A CORE pixel would have to go ON the pad (destroying the
			# dot-vs-pad contrast) or replace the dot (turning the dart into a
			# light, i.e. exactly the "every round is a lamp" failure).
			#
			# So the highlight goes in the WAKE. The run STARTS AT 2px and not
			# at 0, and that offset is load-bearing rather than cosmetic: the
			# paper pad is 3x3 centred on the head, so a CORE cell at distance
			# 0 or 1 is painted and then COVERED by the pad drawn immediately
			# after the wake. The first version started at 0 and produced
			# exactly zero visible gate pixels -- verified by dumping the raw
			# 384x216 raster and finding no (255,255,247) anywhere in the frame.
			#
			# 2px behind the dot is the first cell the pad does not own, so the
			# read is a dart with a bright leader trailing it -- and because the
			# run is DENSE (hot_pitch 1) at the head of a DOTTED wake, the
			# leader is the one solid stretch.
			#
			# Budget: the volley went from 3 darts to 2 on 2026-11-09, so the
			# per-frame CORE cost of a full barrage dropped from 6px to 4px
			# (2 darts x 2px hot run at a 0.34s cadence). Re-tallied rather
			# than left as the old number -- this comment is the only place
			# the SWARM share of the glow budget is written down.
			return {"ink": 0.82, "paper": 0.92, "paper_hold": 0.55,
				"dash": true, "pitch": 2.0,
				"hot": [3, 2], "hot_pitch": 1.0}
		_:
			return {}


func draw_streak(head: Vector2, tr: Array, ink_a: float, paper_a: float, cfg := {}) -> void:
	# Walk the polyline by ARC LENGTH, one source pixel at a time.
	#
	# Per-segment sampling collapsed the whole tail: a step is often under a
	# pixel, so int(distance) came out as 1 and the single sample landed at
	# f=0 闂?exactly under the round, where the round then covered it.
	#
	# Paper and ink fade together, pixel by pixel. A single flat paper box over
	# the bounding box read as a white capsule with a hard end; the ramp lets
	# the wake dissolve into the paper instead of stopping.
	#
	# `cfg` carries the per-tier stamp (see _wake_cfg). An empty cfg reproduces
	# the old one-cell-per-pixel tracer byte for byte, which is what five of the
	# seven tiers pass.
	if tr.size() < 2:
		return
	var pitch := maxf(1.0, float(cfg.get("pitch", 1.0)))
	var rails := int(cfg.get("rails", 1))
	var split := float(cfg.get("split", 0.0))
	var dash := bool(cfg.get("dash", false))
	var pts := PackedVector2Array()
	pts.append(head)
	for q in tr:
		pts.append(q as Vector2)
	var total := 0.0
	for i in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	if total < 1.0:
		return
	var steps := int(total / pitch)
	var walked := 0.0
	var seg := 0
	for s in steps:
		var want := float(s) * pitch
		while seg < pts.size() - 1:
			var sl := pts[seg].distance_to(pts[seg + 1])
			if walked + sl >= want:
				break
			walked += sl
			seg += 1
		if seg >= pts.size() - 1:
			break
		var sl2 := pts[seg].distance_to(pts[seg + 1])
		var q := pts[seg].lerp(pts[seg + 1], (want - walked) / maxf(sl2, 0.001))
		var fade := 1.0 - want / total
		var qx := floorf(q.x)
		var qy := floorf(q.y)
		var cell := Rect2(qx, qy, 1.0, 1.0)
		# `paper_hold` raises the PAPER liner's floor along the tail.
		#
		# Needed because the two grounds want opposite things. On cream the liner
		# is invisible and only the ink fades matter; over the INK MOON the liner
		# is the entire wake, and at paper_a*fade it is already down to 40% by
		# mid-tail -- measured off the raw raster: the dash cells came out at
		# ~0.42 luma against a 0.22 ground, i.e. a mid-grey thread, WEAKER than
		# the 5px hand-drawn wake this replaced (which used a flat 0.80).
		#
		# hold = 0.55 means the liner never drops below 55% of its own alpha:
		# the ink keeps its squared falloff (so the tail still dissolves) while
		# the light edge that carries the round on the dark ground survives.
		var ph := float(cfg.get("paper_hold", 0.0))
		var papf := fade if ph <= 0.0 else ph + (1.0 - ph) * fade
		var pap := Color(PAPER.r, PAPER.g, PAPER.b, paper_a * papf)
		# ---- the dash: ink on even cells, PAPER on odd cells ----------------
		# The alternation is the whole mechanism and it is two-grounds-specific:
		#
		#   on CREAM    the paper cells merge into the field; the ink cells are
		#               the dashes.
		#   on the MOON the ink cells merge into the disc; the PAPER cells are
		#               the dashes.
		#
		# One colour of dash can only work on one of those grounds, and these
		# rounds spend about half their life over the moon. The first attempt at
		# an "arc bridge" replaced the paper cells with a low-alpha ink cell on
		# the theory that a continuous faint trail would show the curve better --
		# and it measurably DELETED the moon dashes (raw raster: the wake went
		# from 0.42-luma light cells to mid-grey on a 0.22 ground). The bridge
		# was reverted; the arc is carried by `paper_hold` instead, which keeps
		# the paper cells bright far enough down the tail that the polyline's
		# bend is legible without touching the alternation.
		if dash and s % 2 == 1:
			if paper_a > 0.0:
				draw_rect(cell, pap, true)
			continue
		if rails >= 2 and want < split:
			# ---- the tube: paper core between two ink rails ----------------
			# The BODY's own construction, continued: ink at y-1 and y+1, paper
			# down the middle. Drawing the wake any other way made the beam look
			# severed behind its own point.
			#
			# The centre is at FULL paper alpha, and the first version was not
			# (0.55) -- which is the one thing this pass got measurably wrong.
			# Measured off the raw 384x216 raster: the seam came out at 0.598
			# luma and the rails at 0.19, against an ink-moon ground of 0.221.
			# So over the moon the rails were INVISIBLE (a 0.09 delta from the
			# ground) and the seam was a mid grey -- the whole 3px tube collapsed
			# into one dirty line, in exactly the half of the field the beam
			# spends most of its life in.
			#
			# At full paper the polarity does the work on BOTH grounds, the same
			# way it does on the body:
			#   cream field  the centre vanishes into the ground, two ink rails
			#                remain => a tube
			#   ink moon     the centre is the bright line, the rails are the two
			#                dark shoulders => the same tube, inverted ground
			# No extra pixels: the 0.55 was buying nothing but mud.
			draw_rect(Rect2(qx, qy - 1.0, 1.0, 1.0), pap, true)
			draw_rect(Rect2(qx, qy + 1.0, 1.0, 1.0), pap, true)
			draw_rect(Rect2(qx, qy, 1.0, 1.0), pap, true)
			var ic := Color(INK.r, INK.g, INK.b, ink_a * fade * fade)
			draw_rect(Rect2(qx, qy - 1.0, 1.0, 1.0), ic, true)
			draw_rect(Rect2(qx, qy + 1.0, 1.0, 1.0), ic, true)
			continue
		# ---- the closed hairline -------------------------------------------
		if paper_a > 0.0:
			draw_rect(cell, pap, true)
		var ka := ink_a * fade * fade
		if rails >= 2:
			# Past the split the wake is one pixel and DIMMER. The alpha step
			# is the whole difference between "a tube that closed" and "a tube
			# that suddenly lost half its pixels".
			ka *= 0.62
		draw_rect(cell, Color(INK.r, INK.g, INK.b, ka), true)

	# ---- hot run: the tier's highlighted leader -------------------------
	# Stamped AFTER the body of the wake so it sits on top, and sampled at its
	# OWN pitch (_wake_cfg's `hot_pitch`, normally 1.0). Two reasons it is a
	# second pass instead of a branch inside the loop:
	#
	#   1. the hot run is DENSE and the rest of the wake may be sparse (SWARM
	#      is pitch 2). One pitch cannot express both, and forcing pitch 1 on
	#      the whole wake would delete the dash;
	#   2. it must not disturb the fade. The run is at the head, where fade is
	#      near 1.0, so the CORE pixels are stamped at full strength instead of
	#      inheriting a squared falloff that would put them under the gate on
	#      the second cell.
	var hot: Array = cfg.get("hot", [])
	if hot.size() == 2:
		var h0 := float(hot[0])
		var hn := int(hot[1])
		var hp := maxf(1.0, float(cfg.get("hot_pitch", 1.0)))
		var hwalk := 0.0
		var hseg := 0
		for hs in hn:
			var hw := h0 + float(hs) * hp
			if hw >= total:
				break
			while hseg < pts.size() - 1:
				var hsl: float = pts[hseg].distance_to(pts[hseg + 1])
				if hwalk + hsl >= hw:
					break
				hwalk += hsl
				hseg += 1
			if hseg >= pts.size() - 1:
				break
			var hsl2: float = pts[hseg].distance_to(pts[hseg + 1])
			var hq := pts[hseg].lerp(pts[hseg + 1], (hw - hwalk) / maxf(hsl2, 0.001))
			draw_rect(Rect2(floorf(hq.x), floorf(hq.y), 1.0, 1.0), CORE, true)


func draw_pb() -> void:
	for b in pb:
		var p: Vector2 = b.p
		var ln := float(b.len)
		var tr: Array = b.get("trail", [])
		var wk: int = int(b.get("wk", WEAPON_BASE))
		# ---- SWARM: dotted dart wake --------------------------------------
		# The dash USED to be hand-drawn here (sx - kk, one horizontal run) and
		# the whole tier `continue`d past draw_streak. That is no longer needed:
		# draw_streak now takes a per-tier stamp (`pitch` / `dash`), so the dash
		# lives in ONE walker instead of two.
		#
		# Two things are gained, and the second is why this was worth changing:
		#
		#   1. the 3x3 paper pad and the 2px dot become a body drawn AFTER the
		#      wake, so the dot sits on top of its own tail instead of the tail
		#      being painted around a pre-existing pad;
		#   2. the wake now follows the TRAIL POLYLINE. The old one ran -X in a
		#      straight line, which these rounds contradict on their first steer
		#      -- a dart turning upward kept dragging a horizontal line behind
		#      it. Walking the stored positions costs nothing and is correct by
		#      construction, and 19px of pitch-2 dashes finally SHOWS the turn.
		#
		# The turn still has to drop the old wake (step_pb sets b.trail = [b.p]
		# on a steer), otherwise the dash would re-trace the abandoned heading.
		if wk == WEAPON_SWARM:
			# Alphas come OUT of the cfg, not from literals here. Passing 0.82 /
			# 0.80 while the cfg also carries 0.82 / 0.92 gave the tier two
			# sources for one number, and the ink/paper alphas in the cfg would
			# then have been a lie: draw_streak reads its `ink_a` / `paper_a`
			# ARGUMENTS, not the dict, for those two. One source or none.
			var scfg := _wake_cfg(wk)
			draw_streak(p, tr, float(scfg.get("ink", 0.46)), float(scfg.get("paper", 0.72)),
				scfg)
			var sx := floorf(p.x)
			var sy := floorf(p.y)
			# Paper pad first, then the 1px dot. A lone ink pixel has no edge
			# at all over the boss disc; this pad is the liner every tier in
			# this file carries so a tiny round can exist on both grounds.
			draw_rect(Rect2(sx - 1.0, sy - 1.0, 3.0, 3.0), PAPER, true)
			draw_rect(Rect2(sx, sy, 1.0, 1.0), INK, true)
			continue
		# ---- FRAG: the cluster's debris -----------------------------------
		# A frag has NO AXIS, and that is the entire shape problem.
		#
		# The cluster fires three of them on a 120-degree ring, so a frag can
		# travel backwards, straight up or straight down. Every other
		# projectile in this file is drawn as a body with a tail running -X,
		# which only works because a player round always flies +X. Do that
		# here and three headings out of four draw a bullet lying on its side.
		#
		# So this is not a body. It is a 2x2 BLOCK with one corner taken out,
		# and the missing corner is rotated onto the TAIL side of the
		# velocity. A block has no front and no back -- it can be flying any
		# way up -- and a chip that is visibly MISSING a piece is the read
		# that says "this came off something".
		#
		# No CORE anywhere on it. Three frags are born on every connecting
		# pellet, so a hot head on each would strobe the bloom chain; this is
		# the one round in the game that never lights the glow pass.
		#
		# Drawn BEFORE the shared wake and `continue`, exactly like SWARM,
		# because draw_streak stamps a pixel on every trail sample and would
		# turn the torn shred back into a tracer.
		if bool(b.get("frag", false)):
			var fv := b.v as Vector2
			var d := fv.normalized() if fv.length() > 0.5 else Vector2.RIGHT
			var fx := floorf(p.x)
			var fy := floorf(p.y)
			# Fracture corner: the tail is -velocity, so the paper pixel goes
			# on the far side of the block. Both tests are >= 0, so a frag
			# fired exactly along an axis lands on one stable corner instead
			# of flickering between two on tiny velocity noise.
			var pcx := 0.0 if d.x >= 0.0 else 1.0
			var pcy := 0.0 if d.y >= 0.0 else 1.0
			draw_rect(Rect2(fx, fy, 2.0, 2.0), INK, true)
			draw_rect(Rect2(fx + pcx, fy + pcy, 1.0, 1.0), PAPER, true)
			# That paper pixel IS the liner, and it earns both grounds on its
			# own: over cream it disappears and the block reads as an L;
			# over the ink moon it is the single bright pixel that gives a
			# 2x2 dark mass an edge. One pixel serves both, which is why this
			# projectile carries no pad -- a pad would make it look like the
			# SWARM dot or a cache plate.
			#
			# Shred: a short torn tail on the -velocity side, one pixel per
			# step, fading. Length comes from `len`, so the field keeps a
			# reader on this branch instead of going stale for frags.
			var shred := int(clampf(floorf(ln), 1.0, 3.0))
			draw_rect(Rect2(fx + floorf(-d.x), fy + floorf(-d.y), 1.0, 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.80), true)
			for si in shred:
				var off := -d * (2.0 + float(si))
				draw_rect(Rect2(fx + floorf(off.x), fy + floorf(off.y), 1.0, 1.0),
					Color(INK.r, INK.g, INK.b, 0.55 - 0.12 * float(si)), true)
			# Crumble: in the last 0.12 s the corner OPPOSITE the fracture goes
			# to paper. The chip visibly loses material before it despawns,
			# instead of winking out as a solid square. `frag_life` is already
			# ticked in step_pb -- reading it here keeps it from being
			# a write-only field.
			if float(b.get("frag_life", FRAG_LIFE)) < 0.12:
				draw_rect(Rect2(fx + 1.0 - pcx, fy + 1.0 - pcy, 1.0, 1.0), PAPER, true)
			continue
		# Friendly wake: lighter than hostile fire so the two never read as the
		# same thing, but built the same way.
		#
		# Per-tier stamp, resolved through _wake_cfg. An empty dict is the stock
		# 1px tracer, which is what BASE / MG / BOMB / SPREAD / FLAK / RAIL all
		# still get -- the two tiers the request named are the only ones with a
		# non-default wake.
		var wcfg := _wake_cfg(wk)
		draw_streak(p, tr, float(wcfg.get("ink", 0.46)), float(wcfg.get("paper", 0.72)), wcfg)
		# ---- per-tier silhouettes ---------------------------------------
		# All tiers are the same weapon, so they all fly as ink on paper. What
		# changes is the SHAPE, and the shape has to answer one question the
		# player asks without reading a label: what am I carrying?
		#
		# Each round is also given a lit underside — one paper line under the
		# body, offset down — because the whole pass is about bodies with a top
		# and a bottom instead of flat silhouettes. It costs one draw_rect per
		# round and is the only cheap way a 1px projectile reads as solid.
		if wk == WEAPON_LASER:
			# Laser: a NEEDLE. Two hairline rails, a bright head, and a paper
			# underside so the beam has thickness rather than being a scratch.
			# The rail gap is what separates it from the base tracer at a
			# glance: a line with a hole in it cannot be mistaken for a tracer.
			draw_rect(Rect2(floorf(p.x - ln), floorf(p.y) - 1.0, ln + 1.0, 1.0), INK, true)
			draw_rect(Rect2(floorf(p.x - ln), floorf(p.y) + 1.0, ln + 1.0, 1.0), INK, true)
			# The core rail, at paper alpha: the beam is a tube.
			draw_rect(Rect2(floorf(p.x - ln * 0.8), floorf(p.y), ln * 0.8 + 1.0, 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.90), true)
			# Head: a 2px tall paper collar round a white core, so it reads as a
			# focused point rather than a cut-off rail.
			draw_rect(Rect2(floorf(p.x) - 1.0, floorf(p.y) - 1.0, 2.0, 3.0), PAPER, true)
			# ---- the hot run ------------------------------------------------
			# ONE pixel became THREE, laid along the beam's own seam, and the
			# reason is a budget argument rather than a brightness one.
			#
			# `CORE` is already (1, 1, 0.97); there is nothing to turn up. What
			# the bloom chain reacts to is how much of the frame sits above its
			# gate and how those pixels CONNECT: bloom_bright downsamples with a
			# four-point MAX, so a 3px contiguous run survives as a 2~3px bright
			# shape at half resolution, while three isolated pixels survive as
			# three isolated pixels. Same count, different result -- the run
			# reads as light, the trio reads as lamps.
			#
			# Placed ON THE SEAM and not on the collar, because the seam is
			# already the brightest line in the tier: paper at 0.90. A hot run
			# continuing that line is the beam's tip burning, which is the read
			# the tier wants; hot pixels scattered round the collar would read
			# as a gem on the nose.
			#
			# Cost: 3px per round, up from 1. LASER is one round per trigger at
			# a 0.26s cadence and a ~0.6s flight, so at most three are ever
			# alive -- 9px of the frame's budget, in one cluster each.
			for hx in 3:
				draw_rect(Rect2(floorf(p.x) - 1.0 - float(hx), floorf(p.y), 1.0, 1.0),
					CORE, true)
			continue

		if wk == WEAPON_BOMB:
			# Bomb: a SHELL. Fat, with a paper band round the waist so the mass
			# is divided and the eye reads a cylinder rather than a slab. The
			# band is the pseudo-3D: a cylinder lit from above has one bright
			# ring, and a ring is cheaper than a highlight.
			draw_rect(Rect2(floorf(p.x - ln), floorf(p.y) - 1.0, ln + 1.0, 3.0), INK, true)
			draw_rect(Rect2(floorf(p.x - ln * 0.55), floorf(p.y) - 1.0, 1.0, 3.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.55), true)
			# Nose: steps in to a point, so the shell has a front.
			draw_rect(Rect2(floorf(p.x) + 0.0, floorf(p.y) - 1.0, 1.0, 3.0), INK, true)
			draw_rect(Rect2(floorf(p.x) + 1.0, floorf(p.y), 1.0, 1.0), INK, true)
			# ---- the nose highlight: 3px going DOWN to 2px ---------------
			# This was a full 1x3 CORE column, i.e. the LARGEST single gate
			# source anywhere in the game. It was also the only one that was
			# not a dot: three stacked pixels at 1x, upscaled 3x, is a 3x9
			# bright bar on a 20px-wide shell.
			#
			# It goes to 1x2 CORE plus one FLASH pixel. The read is unchanged --
			# the nose is still the tallest lit mark on the tier, and still the
			# only thing on the shell past the gate -- but the column stops
			# being a bar. The freed pixel pays for the LASER's hot run, which is
			# on a tier that fires a third as many rounds.
			#
			# BOMB is the tier where "smaller" is the correct direction: it
			# already announces itself by being 3px thick and 7px long and by
			# exploding into a 44px radius. It does not need to also be the
			# brightest thing on the field.
			draw_rect(Rect2(floorf(p.x), floorf(p.y) - 1.0, 1.0, 2.0), CORE, true)
			draw_rect(Rect2(floorf(p.x), floorf(p.y) + 1.0, 1.0, 1.0),
				Color(FLASH.r, FLASH.g, FLASH.b, 0.60), true)
			continue

		if wk == WEAPON_SPREAD:
			# Spread: a PELLET — short, with a ring collar behind the head. The
			# collar is what says "this one came from a cluster"; a plain tracer
			# would be indistinguishable from the base round at speed.
			draw_rect(Rect2(floorf(p.x - ln), floorf(p.y), ln + 1.0, 1.0), INK, true)
			draw_rect(Rect2(floorf(p.x - ln), floorf(p.y) + 1.0, ln * 0.6, 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.70), true)
			# Collar: two 1px fins above and below the body.
			draw_rect(Rect2(floorf(p.x - ln * 0.75), floorf(p.y) - 1.0, 1.0, 1.0), INK, true)
			draw_rect(Rect2(floorf(p.x - ln * 0.75), floorf(p.y) + 1.0, 1.0, 1.0), INK, true)
			# Head: UNCHANGED at 1px, and it stays 1px on purpose. SPREAD is the
			# highest-multiplicity tier in the game after FLAK: three pellets per
			# trigger, plus three FRAGS per pellet that connects. Giving this
			# round a wider head would multiply the frame's gate pixels by ~6,
			# which is the arithmetic that turned every enemy hit into a light
			# bomb back in the FLASH rewrite. One pixel per pellet is the ceiling
			# this tier can afford, and it already has it.
			draw_rect(Rect2(floorf(p.x) - 1.0, floorf(p.y), 1.0, 1.0), CORE, true)
			continue

		if wk == WEAPON_FLAK:
			# Flak: a SLUG, not a pellet. Two pixels THICK and barely three
			# long, so a volley reads at a glance as a handful of thrown chunks
			# -- which is the whole separation from SPREAD, whose pellets are
			# one pixel thin and twice the length.
			#
			# Length is CLAMPED rather than read straight from `len`: the
			# silhouette IS the identity, and a longer spawn length would
			# quietly turn the slug back into a tracer with a belt on it.
			var fl := clampf(floorf(ln), 1.0, 2.0)
			var fx := floorf(p.x)
			var fy := floorf(p.y)
			# Lit underside: one paper row under the body. Invisible on cream,
			# and the only thing that gives a 2px dark block an edge over the
			# ink moon. Drawn first so the fins can sit on top of it.
			draw_rect(Rect2(fx - fl, fy + 2.0, fl + 1.0, 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.92), true)
			# Body: 2px thick. The thickness IS the message.
			draw_rect(Rect2(fx - fl, fy, fl + 1.0, 2.0), INK, true)
			# Waist: a 1px paper band cut across the body. A chunk with a belt
			# round it reads as a cartridge; without the band the same
			# rectangle is just a block, and a block is what BOMB already is.
			draw_rect(Rect2(fx - maxf(1.0, floorf(fl * 0.5)), fy, 1.0, 2.0), PAPER, true)
			# Fins: one pixel above, one below, at the tail. Two fangs on a
			# squat body is the read that says "shrapnel" rather than
			# "bullet", and it costs two draw_rect calls.
			draw_rect(Rect2(fx - fl, fy - 1.0, 1.0, 1.0), INK, true)
			draw_rect(Rect2(fx - fl, fy + 2.0, 1.0, 1.0), INK, true)
			# Muzzle core: one pixel only -- the sole colour on this tier
			# allowed past the bloom gate.
			#
			# UNCHANGED, and the reason is multiplicity. FLAK fires FIVE chunks
			# per trigger at 0.36s, so five heads are airborne most of the time
			# and each connecting chunk seeds three shreds. Five pixels of gate
			# budget per volley is already the second-largest single-tier load
			# in the game; widening the head here would be the fastest route to
			# a lit field of any change in this pass. The tier also has no
			# shortage of identity -- 2px body, waist band, two fins -- so it
			# does not need light to be recognisable.
			draw_rect(Rect2(fx, fy, 1.0, 1.0), CORE, true)
			continue

		if wk == WEAPON_RAIL:
			# Rail: a ROD. Three pixels tall, twelve long, ink rails top and
			# bottom with a paper core between them -- and the core is INSET
			# one pixel at BOTH ends, so the ink closes round it.
			#
			# The distinguishing fact against LASER is exactly that closure.
			# LASER is two hairlines with a seam running the full length: a
			# needle. This is a solid bar with a window cut INTO it. A core that
			# touched either end would reopen the bar into two rails and the two
			# tiers would become one.
			var rl := clampf(floorf(ln), 6.0, 12.0)
			var rx := floorf(p.x)
			var ry := floorf(p.y)
			# Solid bar: one block, 3px tall. Nothing here is a hairline.
			draw_rect(Rect2(rx - rl + 1.0, ry - 1.0, rl, 3.0), INK, true)
			# Paper core, inset 1px at both ends.
			draw_rect(Rect2(rx - rl + 2.0, ry, maxf(1.0, rl - 2.0), 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.95), true)
			# ---- hot filament: 1px becomes 2px --------------------------
			# RAIL is the cheapest place in the game to put a second gate pixel:
			# 0.62s cadence -- the slowest trigger -- one round per pull, and a
			# 12px body so the light has something to sit on. At most TWO are
			# ever alive (12px of travel at 650px/s is 0.02s... but the 0.62s
			# cadence means the previous round has already left the field), i.e.
			# this change costs the frame 2px of gate budget across the whole
			# tier.
			#
			# The second pixel goes 1px BACK along the seam, not up or down.
			# Stacking it vertically would make a 2px-tall nose, which is what
			# BOMB's nose is; a 2px run along the axis reads as the filament
			# being fed, which is the rod's story. It also keeps the nose a flat
			# WALL (the tier's stated difference from LASER): the wall is
			# untouched, the light behind it is longer.
			draw_rect(Rect2(rx, ry, 1.0, 1.0), CORE, true)
			draw_rect(Rect2(rx - 1.0, ry, 1.0, 1.0), CORE, true)
			continue

		# muzzle core. The core is the only thing on screen that clears the bloom
		# gate, so every shot carries a small flare and the field reads as a lit
		# tube rather than flat print.
		#
		# This is BASE's ONLY gate pixel, and it stays 1px. BASE is the tier the
		# player always has and can always fire: a 30-round magazine at 0.19s is
		# up to TEN rounds airborne at once, and the twin fires it too, so this
		# single pixel is already the most frequently drawn CORE in the game.
		# Widening it would be the one change in this pass capable of washing
		# the field out on its own.
		draw_rect(Rect2(floorf(p.x - ln), floorf(p.y), ln + 1.0, 1.0), INK, true)
		draw_rect(Rect2(floorf(p.x - ln * 0.7), floorf(p.y) + 1.0, ln * 0.7, 1.0),
			Color(PAPER.r, PAPER.g, PAPER.b, 0.65), true)
		draw_rect(Rect2(floorf(p.x) - 1.0, floorf(p.y), 1.0, 1.0), CORE, true)
		if wk == WEAPON_MG:
			# MG: a second highlight a third of the way back, so a dense stream
			# reads as dashes rather than a solid line when they overlap.
			#
			# This was CORE at alpha 0.50 -- which is the one thing in this file
			# that CANNOT work the way it looks like it works. Alpha does not
			# dim a CORE pixel out of the gate: the pixel is blended over the ink
			# body into a mid grey (~0.56 luma), so it was never above the gate
			# AT ALL. It did not add glow, it only added a grey dab that made the
			# stream look dirty. "A dimmer light" is not a thing this palette can
			# express; FLASH is the palette's answer and it is a different hue
			# family, not a dimmed CORE.
			#
			# So it becomes FLASH at a readable alpha: a genuine second mark that
			# stays under the gate on purpose. MG keeps its dash cadence, the
			# field keeps its budget, and the grey dab becomes an intentional
			# sub-gate hit -- which is exactly the distinction the project
			# already made once when it replaced CORE hit-flashes with FLASH.
			draw_rect(Rect2(floorf(p.x - ln * 0.45), floorf(p.y), 1.0, 1.0),
				Color(FLASH.r, FLASH.g, FLASH.b, 0.90), true)


# ---- caches ----------------------------------------------------------------
# A cache is a small plate that states which tier it carries.
#
# 2026-11-09: the plates were 11-12px across and carried a 5x7 letter inside
# them. On a 384x216 raster that is a 33-36px object at 3x -- LARGER than a
# shard craft (r=5, so 10px) and about half the length of the player's own hull.
# Seven of them on screen read as a wall of boxes, and the report was "icons are
# too big, the whole thing looks blurry and wrong". The cause was not the fill
# or the bevel; it was the FOOTPRINT, and the footprint was being driven by the
# letter.
#
# So the letter is gone and the plate is 7x7. Two reasons this is not a loss:
#
#   1. the letter was REDUNDANT. The bottom cluster already prints the armed
#      tier's letter at 1x, right next to the magazine. A second copy floating
#      on the field answered a question nobody had.
#   2. a 5x7 glyph inside a 7x7 plate has exactly 1px of margin. At 3x under
#      CRT bleed that margin is the plate, so the letter was always fighting
#      its own frame.
#
# What identifies the tier now is pure SILHOUETTE, at a size that reads as
# debris rather than as furniture:
#
#   BOMB     square with clipped top corners  -- a blunt crate
#   MG       taller than wide                -- a magazine
#   SPREAD   rhombus                          -- a fan point
#   LASER    pointed hexagon                  -- a prism
#   FLAK     trapezoid, wide at the tail      -- a scatter cone
#   RAIL     flat wide bar                    -- one rail
#   SWARM    three-tooth comb                 -- three darts
#
# The treatment is `_facet_body`'s: a paper halo and ONE solid ink plate. No
# bevel, no per-edge colouring, no inverted fill.
#
# Why the fill had to flip, and this is the whole point of the rewrite:
#
# the plates used to be PAPER-FILLED with an INK OUTLINE. On the cream field
# that is a shape whose inside is the same colour as the ground it sits on, so
# all that is left is a 1px ring. At 3x under CRT bleed, a 1px ring around a
# 7px hole does not read as an object, it reads as a smudge -- and with seven of
# them on one frame the whole field looked blurred. That is exactly the report.
#
# Every hostile in this file already solved this: solid ink + paper halo. The
# plate now does the same, so a pickup is the same KIND of mark as a craft,
# just inert. The rectangle that used to be the plate's outline is now the
# plate's body, which is the only way a 7px object gets a readable mass.
# ---- passive item plates ---------------------------------------------------
#
# The three passives must be distinguishable from the seven weapon plates at
# pickup speed, and the project already established (see the cache header) that
# 7px CANNOT hold seven distinct outlines, let alone ten. The accepted solution
# for weapons was: one shared 7x7 square, fingerprinted by interior paper seams.
#
# Adding three more seam patterns to that system would make ten fingerprints --
# and the number of seams is already close to the discrimination limit
# (1, 2, 3 lines and a cross is the whole vocabulary that survives at this size).
#
# So the passives invert the PLATE instead. A weapon plate is solid ink with
# paper seams; a passive plate is solid PAPER with an INK outline and an ink
# glyph inside. That is one bit of information, readable at a glance, that
# costs no new shape vocabulary at all:
#
#     weapon  = dark square, light marks inside
#     passive = light square, dark mark inside
#
# Polarity alone tells the player "this is not a gun" before any detail
# resolves, which is exactly what a pickup has to do. And because the plate is
# PAPER on a PAPER field, it ALSO needs the ink outline the old cache used to
# carry -- without it the plate would dissolve into the cream ground, which is
# the failure the previous redesign already paid for.
# Row spans of the 7px disc, dy = -3..3 -> [x0, x1]. Hand-written, not derived
# from Ink.ring: Ink.ring emits its two edge pixels at the poles as
# (cx-ox)..(cx+1), which at rr=3 lands asymmetrically, and this plate has to be
# mirror-symmetric or the three items do not read as one family.
const ITEM_DISC_ROWS := [
	[-1, 1],
	[-2, 2],
	[-3, 3],
	[-3, 3],
	[-3, 3],
	[-2, 2],
	[-1, 1],
]


# One horizontal run of the disc, given a row offset dy in -3..3 around `p`.
func _item_disc_row(p: Vector2, dy: int, col: Color) -> void:
	var half: Array = ITEM_DISC_ROWS[dy + 3]
	var x0 := int(half[0])
	var x1 := int(half[1])
	draw_rect(Rect2(floorf(p.x + float(x0)), floorf(p.y + float(dy)),
		float(x1 - x0 + 1), 1.0), col, true)


func draw_item_plate(p: Vector2, item: int) -> void:
	var at := Vector2(floorf(p.x), floorf(p.y))

	# 1. Shadow: the same pseudo-3D every weapon plate carries, so the two
	#    families still sit ON the field in the same way. SOOT at 0.45, one
	#    pixel down-right -- no new tone.
	for dy in range(-3, 4):
		_item_disc_row(at + Vector2(1.0, 1.0), dy, Color(SOOT.r, SOOT.g, SOOT.b, 0.45))

	# 2. Paper body: this IS the inversion. A weapon plate is ink; this is
	#    paper. On the cream field a paper disc has no silhouette at all, which
	#    is why step 3 (the ink ring) is the object and not a decoration.
	for dy in range(-3, 4):
		_item_disc_row(at, dy, PAPER)

	# 3. Ink ring, 1px, hugging the disc exactly: leftmost and rightmost pixel
	#    of every row, and the full span on the two pole rows (they have no
	#    interior). This doubles as the paper liner's boundary: the mark drawn
	#    in step 4 always has at least 1px of paper between itself and the
	#    ring, so it reads on BOTH an ink craft and the paper field.
	for dy in range(-3, 4):
		var half: Array = ITEM_DISC_ROWS[dy + 3]
		var x0 := int(half[0])
		var x1 := int(half[1])
		if dy == -3 or dy == 3:
			draw_rect(Rect2(at.x + float(x0), at.y + float(dy),
				float(x1 - x0 + 1), 1.0), INK, true)
		else:
			draw_rect(Rect2(at.x + float(x0), at.y + float(dy), 1.0, 1.0), INK, true)
			draw_rect(Rect2(at.x + float(x1), at.y + float(dy), 1.0, 1.0), INK, true)

	# 4. The item mark: INK on PAPER. Same geometry as the weapon seams would
	#    still read differently, because polarity already separates the
	#    families -- but the three here also avoid the seam grammar outright.
	#
	# The interior of the disc is only 5px wide on the middle rows and 3px on
	# the near-pole rows, so every mark below is also a statement about what
	# FITS: a 5px centred diagonal cannot exist (its ends are the ring), which
	# is why THORN's slash is a 4px staircase displaced up-right, not a
	# centred 45-degree line.
	match item:
		ITEM_SHIELD:
			# Closed 3x3 ring: 8 pixels, empty centre. A ring is the only
			# mark at this size that says "something surrounds something".
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					draw_rect(Rect2(at.x + float(dx), at.y + float(dy), 1.0, 1.0), INK, true)
		ITEM_THORN:
			# 4px diagonal staircase, (-1,-2) -> (2,1). Every pixel sits in
			# paper interior: (-1,-2) and (2,1) are the extreme cells that
			# still clear the ring by 1px. Sharp, and the only diagonal axis
			# in the whole game.
			for k in range(-1, 3):
				draw_rect(Rect2(at.x + float(k), at.y + float(k - 1), 1.0, 1.0), INK, true)
		_:
			# BARRAGE: three detached dots in a VERTICAL column, at the
			# centre. SWARM is three dots in a HORIZONTAL row in PAPER; this
			# is the same count on the other axis in INK, and the column is
			# literally the shape a barrage draws when it lands.
			for dy in [-2, 0, 2]:
				draw_rect(Rect2(at.x, at.y + float(dy), 1.0, 1.0), INK, true)

	# 5. Outer glint. THE GLOW LIVES OUTSIDE THE PLATE, and that is a
	#    constraint, not a preference.
	#
	#    A passive plate is PAPER-FILLED with an INK RING: the one thing in the
	#    game with inverted polarity against a weapon plate. Touching the fill
	#    or the ring at all would cost exactly that read -- a lit interior turns
	#    the light square back into a dark square with a bright middle, which is
	#    the weapon plate's grammar. So the glow has to sit in the 2px annulus
	#    between the ring (r=3) and the pulse ring (r=7..8.5).
	#
	#    Shape: a four-armed star, 5px from the centre. Vertical arms CLEAR the
	#    bloom gate; horizontal arms are FLASH, i.e. deliberately just under it.
	#
	#    Why mixed, and why only two gate pixels: a CORE ring would be 20+
	#    pixels of pure light per plate and three plates would light the field
	#    into haze. A single CORE pixel per plate would be a lamp, not a glint.
	#    Two, opposite each other on the VERTICAL axis, is the shape the eye
	#    reads as a star catching light -- and it is 2px of gate budget, so
	#    four waiting pickups cost 8px total.
	#
	#    The horizontal pair is FLASH so the star still reads as four-pointed
	#    while contributing nothing to the glow chain: the same trick that
	#    keeps every enemy hit from blooming, used here for the arms.
	#
	#    Pulsed rather than constant: `Ink.now()` is the project's 8fps quantised
	#    clock, so the glint ticks in whole pixels at the same rate as the hand-
	#    drawn boil and never looks like a modern additive shader stuck on top.
	var gph := Ink.now()
	var gk := 0.5 + 0.5 * sin(gph * 2.1)
	# Vertical arms: the gate pair. Present whenever the pulse is up, so the
	# glint blinks rather than dims -- a dimmed CORE pixel would drop UNDER the
	# gate and the two states would be "lit" and "not lit" anyway, just less
	# legibly.
	if gk > 0.34:
		draw_rect(Rect2(at.x, at.y - 5.0, 1.0, 1.0), CORE, true)
		draw_rect(Rect2(at.x, at.y + 5.0, 1.0, 1.0), CORE, true)
	var fa := Color(FLASH.r, FLASH.g, FLASH.b, 0.55 + gk * 0.45)
	draw_rect(Rect2(at.x - 5.0, at.y, 1.0, 1.0), fa, true)
	draw_rect(Rect2(at.x + 5.0, at.y, 1.0, 1.0), fa, true)
	# Inner echo: two FLASH pixels hugging the ring at r=4 on the SAME vertical
	# axis. Without them the two CORE pixels float with no connection to the
	# plate; with them the light has a path from the plate edge outward, which
	# is what makes it read as emitted rather than pasted.
	draw_rect(Rect2(at.x, at.y - 4.0, 1.0, 1.0), Color(FLASH.r, FLASH.g, FLASH.b, 0.42), true)
	draw_rect(Rect2(at.x, at.y + 4.0, 1.0, 1.0), Color(FLASH.r, FLASH.g, FLASH.b, 0.42), true)


func draw_caches() -> void:
	for c in caches:
		var p: Vector2 = c.p
		var life := float(c.t)
		# Blink out in the last second so a cache never vanishes unexplained.
		if life > 5.0 and fmod(life, 0.3) < 0.15:
			continue
		# ---- branch on payload -------------------------------------------
		# A passive item is drawn by its own function and the weapon path is
		# untouched, so nothing about the seven existing plates changes.
		#
		# The pulse ring is drawn for BOTH: it is the "this is a pickup"
		# signal, not a weapon-specific one, and without it a passive plate
		# (paper on paper) would have no motion at all while it waits.
		var passive := int(c.get("passive", ITEM_NONE))
		if passive != ITEM_NONE:
			draw_item_plate(p, passive)
			if life < 1.4:
				var pr := 7.0 + sin(life * 9.0) * 1.5
				Ink.ring(self, p, pr, 1.0, Color(INK.r, INK.g, INK.b, 0.30))
			continue
		var kind := int(c.kind)
		var pts := _cache_shape(p, kind)

		# Drop shadow: the same polygon, offset down-right, in SOOT. This is the
		# pseudo-3D that matters most for a pickup 鈥?it is the only object in the
		# game that sits ON the field rather than IN it, and a shadow is what
		# says so.
		var sh := PackedVector2Array()
		for v in pts:
			sh.append(v + Vector2(1.0, 1.0))
		Ink.fill_poly(self, sh, Color(SOOT.r, SOOT.g, SOOT.b, 0.45))

		# Body: solid ink, exactly the craft treatment. A pickup is inert, so
		# its ink is slightly lifted toward the page -- one value, no gradient,
		# which keeps it distinguishable from a hostile silhouette without
		# introducing a third tone that the CRT would turn into a band.
		Ink.fill_poly(self, pts, Color(INK.r, INK.g, INK.b, 0.92))

		# Interior seams: the tier's actual mark. One pixel per step, drawn at
		# paper so the plate reads as an object with structure cut into it.
		#
		# This replaced both the letter AND the seven-silhouette scheme. The
		# letter could not fit a 7px plate; seven outlines could not survive at
		# 7px either (measured: they collapsed into blobs). A seam needs no
		# margin and is the one mark this palette can guarantee at this size.
		for seg in _cache_seams(kind):
			var pair: Array = seg
			var a: Vector2 = pair[0]
			var b: Vector2 = pair[1]
			var dir := b - a
			# Steps along the dominant axis, so a diagonal seam is a real
			# staircase rather than a single pixel at each end.
			var span_sum := absf(dir.x) + absf(dir.y)
			var steps2 := int(maxf(1.0, floorf(span_sum)))
			for s in range(0, steps2 + 1):
				var q := a + dir * (float(s) / float(steps2))
				draw_rect(Rect2(floorf(p.x + q.x), floorf(p.y + q.y), 1.0, 1.0),
					Color(PAPER.r, PAPER.g, PAPER.b, 0.82), true)

		# No letter. See the header: the armed tier's letter is already printed
		# at 1x in the bottom cluster, and a 5x7 glyph inside a 7x7 plate has
		# nothing left around it.

		# Pulse ring while it waits, so a dropped cache is noticeable on a busy
		# screen without adding a permanent marker. Scaled to the new plate:
		# 7.0..8.5 rather than 7.5..10.5, so the ring hugs the object instead of
		# floating a plate's width away from it.
		if life < 1.4:
			var rr := 7.0 + sin(life * 9.0) * 1.5
			Ink.ring(self, p, rr, 1.0, Color(INK.r, INK.g, INK.b, 0.30))


# Per-tier plate silhouettes, in world space around `p`.
#
# EVERY plate is the SAME 7x7 square. That is a deliberate reversal of the
# previous design, and the reason is measured rather than aesthetic:
#
# seven distinguishable OUTLINES do not exist at 7px. The previous set tried a
# crate, a magazine, a rhombus, a prism, a trapezoid, a bar and a comb inside a
# 7px box, and at 3x the comb collapsed into an ink blob, the magazine into two
# vertical lines, and the whole row read as "several small dark smudges". A
# silhouette needs roughly 9-11px before its corners survive CRT bleed; that is
# exactly why the ORIGINAL plates were 11-12px, and shrinking them was what
# forced this problem in the first place.
#
# So the outline stops carrying information and stops being a miniaturised
# version of the projectile. The tier is encoded INSIDE the plate, as 1px paper
# seams, which is the only mark this palette can guarantee at this size:
#
#   BOMB     horizontal seam                   -- a heavy bar across
#   MG       two vertical seams                -- a magazine's ribs
#   SPREAD   three diagonal ticks radiating    -- a fan opening right
#   LASER    one vertical seam, full height    -- a beam down the middle
#   FLAK     two horizontal seams              -- a banded shell
#   RAIL     one horizontal seam, full width   -- one rail, edge to edge
#   SWARM    three short horizontal seams      -- three stacked darts
#
# The squares all share one size, so a pickup never implies "bigger = better",
# and the seam is the same device the hull and every hostile already use.
func _cache_shape(p: Vector2, kind: int) -> PackedVector2Array:
	var o := PackedVector2Array()
	# One silhouette for all seven. `kind` is accepted and ignored on purpose:
	# keeping the parameter means the call site does not change, and the
	# discrimination lives in _cache_seams() where it is actually readable.
	if kind != WEAPON_LAST:
		pass
	o = _poly_around(p, [
		Vector2(-3.0, -3.0), Vector2(3.0, -3.0), Vector2(3.0, 3.0),
		Vector2(-3.0, 3.0),
	])
	return o


# Interior seams: the tier's actual mark.
#
# Returned as a list of [from, to] pairs in plate-local pixels, relative to the
# plate centre.
#
# COUNT and ORIENTATION only. That is the constraint, and it is a measurement,
# not a preference: on a 7px ink square the only interior patterns that survive
# 3x CRT bleed are "one line", "two lines", "three lines" and "a cross", each in
# a horizontal or a vertical reading. A radial fan and an edge-to-edge cut were
# tried first and both failed in the same way -- the fan collapsed into a single
# hook, the edge cut bisected the plate into two separate blocks.
#
# So the seven tiers are ordered by how many marks they carry, and the
# orientation separates the pairs:
#
#   BOMB     cross        a burst opening from one point
#   MG       3 vertical   a magazine's ribs
#   SPREAD   3 horizontal three layers opening out
#   FLAK     2 horizontal two bands -- a shell in segments
#   RAIL     1 horizontal one rail, the full width
#   LASER    1 vertical   one beam, the full height
#   SWARM    3 dots       three dots, not lines at all -- and NOT the volley
#                          size. The plate is a permanent pickup identity; it
#                          deliberately does not track how many darts leave the
#                          muzzle, because a pickup whose icon changes shape
#                          when a balance number moves is unreadable to anyone
#                          who learned it yesterday.
#
# No two tiers share both a count and an orientation, and every seam stops
# strictly inside the outline so the silhouette stays a clean square.
func _cache_seams(kind: int) -> Array:
	match kind:
		WEAPON_BOMB:
			return [[Vector2(-2.0, 0.0), Vector2(2.0, 0.0)],
				[Vector2(0.0, -2.0), Vector2(0.0, 2.0)]]
		WEAPON_MG:
			return [[Vector2(-2.0, -2.0), Vector2(-2.0, 2.0)],
				[Vector2(0.0, -2.0), Vector2(0.0, 2.0)],
				[Vector2(2.0, -2.0), Vector2(2.0, 2.0)]]
		WEAPON_SPREAD:
			return [[Vector2(-2.0, -2.0), Vector2(2.0, -2.0)],
				[Vector2(-2.0, 0.0), Vector2(2.0, 0.0)],
				[Vector2(-2.0, 2.0), Vector2(2.0, 2.0)]]
		WEAPON_FLAK:
			return [[Vector2(-2.0, -1.0), Vector2(2.0, -1.0)],
				[Vector2(-2.0, 1.0), Vector2(2.0, 1.0)]]
		WEAPON_RAIL:
			return [[Vector2(-2.0, 0.0), Vector2(2.0, 0.0)]]
		WEAPON_LASER:
			return [[Vector2(0.0, -2.0), Vector2(0.0, 2.0)]]
		_:
			# SWARM: three dots, degenerate one-pixel seams. A dot is not a
			# short line: at this size three dots read as a group of objects,
			# which is exactly the tier's meaning.
			return [[Vector2(-2.0, 0.0), Vector2(-2.0, 0.0)],
				[Vector2(0.0, 0.0), Vector2(0.0, 0.0)],
				[Vector2(2.0, 0.0), Vector2(2.0, 0.0)]]


func _poly_around(p: Vector2, rel: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in rel:
		var vv: Vector2 = v
		out.append(Vector2(floorf(p.x + vv.x), floorf(p.y + vv.y)))
	return out


func draw_eb() -> void:
	for b in eb:
		var p: Vector2 = b.p
		var rr := float(b.r)
		var tr: Array = b.get("trail", [])

		# Hostile wake: built by the same helper as friendly fire, only hotter
		# ink and a stronger paper pad 闁?enemy rounds are read against the dark
		# disc far more often than not.
		#
		# 2026-11-09: this now passes the tier, so the twin's wake carries the
		# SAME vocabulary as the player's -- but resolved through the hostile
		# branch of _wake_cfg, which is a strictly smaller set:
		#
		#   BOMB  thick, then a closed hairline, 17px
		#   MG    distance-pitched dashes
		#   BASE  the stock tracer
		#
		# Why the twin gets a wake vocabulary at all: BASE and MG draw the SAME
		# square pellet, so before this the only way to know which was incoming
		# was the arrival rate -- i.e. the one thing you cannot measure while
		# dodging. The wake answers it in peripheral vision.
		#
		# Why NOT the rest of the player's set: the twin cannot fire LASER,
		# SPREAD, FLAK, RAIL or SWARM (see _cycle_rival_tier), so those configs
		# are unreachable here. They are not passed "just in case" -- a wake
		# table that lists tiers the enemy can never fire is a claim nothing
		# tests, and this project has been bitten by exactly that before.
		var hwk := int(b.get("wk", WEAPON_BASE))
		var hcfg := _wake_cfg(hwk, true)
		draw_streak(p, tr, float(hcfg.get("ink", 0.60)), float(hcfg.get("paper", 0.90)),
			hcfg)

		# ---- the round itself -------------------------------------------
		# The first version drew a PAPER pad exactly 2px larger than the pellet
		# and then the pellet in full INK. Against the boss 闁?also a full INK
		# disc 闁?those two shapes merged into one black mass and the volley read
		# as decoration on the boss rather than as incoming fire. Three changes:
		#
		#   1. the pad is BIGGER (rr*2 + 4 instead of +2), so every round carries
		#      a visible cream ring at its edge;
		#   2. the pellet is INK but the pad is pure PAPER at full alpha, giving
		#      a hard light/dark ring instead of a soft one;
		#   3. a 1px hot centre is dropped in for rr >= 3 so the round has an
		#      interior reference point when several overlap.
		#
		# Everything is placed from ONE integer anchor: packing the pad and the
		# pellet separately let floor() push them apart by a pixel, which at 3x
		# upscale reads as a white square with a dark notch in one corner.
		var body := maxf(1.0, floorf(rr * 2.0) + 1.0)
		var pad := body + 4.0
		var ox := floorf(p.x - pad * 0.5)
		var oy := floorf(p.y - pad * 0.5)
		# Paper pad: this is what separates the round from the BOSS disc.
		#
		# Over cream paper the pad is invisible (same colour), and that is fine 闁?		# there the dark pellet already reads. The pad earns its place exactly
		# where it was needed: over the ink disc, where a black pellet on black
		# ground had no edge at all and the volley looked like decoration.
		draw_rect(Rect2(ox, oy, pad, pad), PAPER, true)
		var bx := ox + 2.0
		var by := oy + 2.0
		# ---- per-tier hostile body --------------------------------------
		# The twin now fires more than one tier, so a hostile round has to say
		# WHICH tier it is, the same way the player's rounds do. Same palette,
		# same "no colours" rule: shape only.
		#
		#   BASE/MG  a square pellet, as it always was
		#   BOMB     a round shell, visibly larger and rounder
		#
		# Nothing else exists here -- the twin is limited to three tiers (see
		# _cycle_rival_tier), so this is the whole space.
		var wk := int(b.get("wk", WEAPON_BASE))
		if wk == WEAPON_BOMB:
			# A disc rather than a square, so the shell reads as mass. The
			# paper pad already separates it from the boss; the round body is
			# what separates it from a tracer.
			Ink.disc(self, Vector2(bx + body * 0.5, by + body * 0.5), rr, INK)
			# An equatorial paper seam, one row: the same "cylinder lit from
			# above" device the player's shell uses, so the two BOMB rounds
			# read as the same ammunition seen from opposite sides.
			draw_rect(Rect2(bx, floorf(by + body * 0.5), body, 1.0),
				Color(PAPER.r, PAPER.g, PAPER.b, 0.55), true)
			draw_rect(Rect2(bx + body * 0.5 - 1.0, by + body * 0.5 - 1.0, 1.0, 1.0),
				FLASH, true)
		elif rr < 2.0:
			draw_rect(Rect2(bx, by, body, body), INK, true)
		else:
			Ink.disc(self, Vector2(bx + body * 0.5, by + body * 0.5), rr, INK)
			if rr >= 3.0:
				# Interior point, NOT a bloom core: FLASH sits under the gate so
				# a screen full of bullets never lights the glow pass.
				var cs := maxf(1.0, floorf(rr * 0.5))
				draw_rect(Rect2(bx + body * 0.5 - cs * 0.5, by + body * 0.5 - cs * 0.5, cs, cs),
					FLASH, true)


func draw_foes() -> void:
	for f in foes:
		var p: Vector2 = f.p
		var k := int(f.kind)
		var s := float(f.r)
		# Flash state: how much of the hit window is left. Drawn as an overlay on
		# the silhouette so the craft reads as the same object briefly
		# overexposed rather than as a different sprite.
		var flash_k := clampf(float(f.get("hit_t", 0.0)) / 0.14, 0.0, 1.0)
		# Stable per-craft phase. Derived from the craft's own position instead of
		# from a counter, so two crafts spawned on the same frame still animate
		# out of step and nothing has to be stored or reset.
		var seed := float(p.x) * 0.07 + float(p.y) * 0.11
		# Bank into the arc. The weave already carries a slope; feeding it to the
		# silhouette is what stops the roster reading as sliding cut-outs. This is
		# the cheapest cue that a craft is flying rather than being dragged.
		var lean := clampf(float(f.get("vy", 0.0)) / 70.0, -1.0, 1.0) * 0.34

		# Paper halo first, so silhouettes survive the dark moon.
		Ink.disc(self, p, s + 1.5, Color(PAPER.r, PAPER.g, PAPER.b, 0.90))
		if k == 0:
			_draw_shard(p, s, lean, seed)
		elif k == 1:
			_draw_drift(p, s, lean, seed, float(f.get("fire", 9.0)))
		else:
			_draw_coil(p, s, lean, float(f.spin), float(f.get("fire", 9.0)))
		pips(p + Vector2(0.0, s + 4.0), int(f.hp))

		# ---- hit flash -----------------------------------------------------
		# A soft lift stamped over the craft, fading out over the hit window.
		#
		# This used to be CORE, i.e. pure white, which sits above the bloom
		# chain's gate. Every hit therefore lit the glow pass and bloomed a 5px
		# craft into a 20px ball of light -- far brighter than anything else on
		# a paper-toned screen, so it read as an explosion rather than a hit.
		# FLASH is deliberately just UNDER the gate: brighter than paper, so
		# contact is unmistakable, but it never feeds the bloom chain.
		if flash_k > 0.0:
			Ink.disc(self, p, s * (0.70 + flash_k * 0.08),
				Color(FLASH.r, FLASH.g, FLASH.b, 0.08 + flash_k * 0.26))


# Rotate a body-space point list into world space and snap it to the pixel grid.
# Every enemy goes through this, so no craft can end up on a half-pixel edge and
# develop a seam once the CRT upscales by 3.
func _body_xf(p: Vector2, pts: Array, ang: float) -> PackedVector2Array:
	var c := cos(ang)
	var s := sin(ang)
	var out := PackedVector2Array()
	for v in pts:
		var vv: Vector2 = v
		out.append(Vector2(floorf(p.x + vv.x * c - vv.y * s),
			floorf(p.y + vv.x * s + vv.y * c)))
	return out


# ---------------------------------------------------------------------------
# Pseudo-3D, in a palette of ink, paper and two greys.
#
# The complaint was that every hostile was "one round blob": a single flat ink
# mass with an even 1px ring around it. That look comes from one specific
# mistake 鈥?stroking the WHOLE outline at one alpha. An even stroke says "this
# is a cut-out", because in real light the edge facing the light is bright and
# the edge facing away is dark, and a uniform line makes both the same.
#
# So every hostile is built from the same four steps, and no enemy is allowed to
# skip one:
#
#   1. HALO     paper, one pixel proud. Separation from the background.
#   2. BEVEL    the body stamped twice, offset up-left and down-right, in MUTE
#               and SOOT. Only a 1px crescent of each survives, which is the
#               lit face and the shadowed face. This is the entire "3D".
#   3. BODY     INK, on top of both.
#   4. EDGES    the outline stroked PER EDGE, coloured by which way the edge's
#               outward normal faces relative to an upper-left light. Lit edges
#               go MUTE, shadowed edges go SOOT, silhouette edges that face
#               almost directly at the light get PAPER.
#
# Step 4 is the one that fixes "all one round blob". A polygonal body with
# per-edge lighting reads as faceted; the same body with one uniform ring reads
# as a sticker. It also costs nothing extra 鈥?same number of segments, just a
# different colour per segment.
#
# Light direction, in screen space (y down): upper-left, i.e. (-0.707, -0.707).
const LIGHT := Vector2(-0.7071, -0.7071)


# Render one faceted body. `pts` is in WORLD space (already transformed), because
# the lighting has to be computed in screen space 鈥?a body-space normal would
# rotate with the craft and the highlight would follow the ship around, which
# looks like the light source is attached to the enemy.
func _facet_body(pts: PackedVector2Array, body_col: Color, halo := 1.0) -> void:
	var n := pts.size()
	if n < 3:
		return
	var c := Vector2.ZERO
	for v in pts:
		c += v
	c /= float(n)

	# ---- HOW THICK THE OUTLINE IS -------------------------------------------
	# Every hostile is now drawn with the SAME treatment as the player craft:
	# a filled ink body and ONE paper hairline, no bevel, no per-edge colouring.
	# The reference point is the player, and matching it is the whole request.
	#
	# What went wrong before, in order, because it is worth not repeating:
	#
	#   1. per-edge colouring on a 10px body put a 1px rim on each of four sides,
	#      so the rim became the object and the ink core vanished;
	#   2. the "small body" variant tried to keep the rim ink and only light the
	#      sun-facing edges, which still left a doubled contour 鈥?the silhouette
	#      read as a line drawn ROUND a shape rather than as the shape itself;
	#   3. the MUTE/SOOT bevel on the big bodies (boss, elite) added a second and
	#      third value to the rim, which is what "澶お澶矖" was seeing: at 3x with
	#      CRT bleed a 1px crescent in a third tone reads as a 2-3px band.
	#
	# The player has none of this. It is: paper halo, solid ink, one paper seam.
	# That is what every hostile gets now. Depth is carried by FORM (the shapes
	# below are faceted and asymmetric) and by the halo, not by rim thickness.
	#
	# `halo` scales the paper padding; it is the only per-craft difference.
	if halo > 0.0:
		# The expansion factor must come from the shape's own size, not from
		# whatever vertex happens to be index 0 鈥?using pts[0] made the halo
		# silently wider or narrower depending on vertex order, which is the
		# kind of per-shape drift that is impossible to eyeball.
		var mean_r := 0.0
		for v in pts:
			mean_r += v.distance_to(c)
		mean_r = maxf(1.0, mean_r / float(n))
		var k := 1.0 + halo / mean_r
		var out := PackedVector2Array()
		for v in pts:
			out.append(c + (v - c) * k)
		Ink.fill_poly(self, out, Color(PAPER.r, PAPER.g, PAPER.b, 0.92))

	# Body: one solid fill, exactly like the player's hull.
	Ink.fill_poly(self, pts, body_col)


# kind 0 -- shard. A dart, not a diamond.
#
# It flies left, so the point faces left and the notch faces the way it came:
# the silhouette states its own direction of travel without an arrow, a trail or
# a colour. A symmetric lozenge cannot do that, and an even outline makes it a
# floating tile rather than a craft.
func _draw_shard(p: Vector2, s: float, lean: float, seed: float) -> void:
	# A slow tumble plus the weave bank. Two frequencies, one of them per-craft,
	# so a wave of six shards never animates as one rigid formation.
	var ang := lean + sin(seed * 3.1 + t * 1.9) * 0.10
	var body := [
		Vector2(-s * 1.15, 0.0),          # nose, pointing along travel
		Vector2(-s * 0.15, s * 0.70),
		Vector2(s * 0.80, s * 0.46),
		Vector2(s * 0.34, 0.0),           # tail notch
		Vector2(s * 0.80, -s * 0.46),
		Vector2(-s * 0.15, -s * 0.70),
	]
	_facet_body(_body_xf(p, body, ang), INK, 1.0)


# kind 1 -- drift craft. A gunship, and the only one that AIMS.
#
# Its silhouette has to show a gun: two nacelles outboard, a barrel line pointing
# at the player, and a charge pip that fills before it fires. The telegraph is
# not decoration 鈥?this craft's 1.75 s aimed shot is the one attack in the roster
# a player can learn to read, so it has to be readable.
func _draw_drift(p: Vector2, s: float, lean: float, seed: float, fire: float) -> void:
	var ang := lean + sin(seed * 2.1 + t * 1.3) * 0.05
	# A slab with a stepped prow. The prow is two extra vertices rather than one,
	# because a single point at 8px reads as a pin stuck on a box.
	var hull := [
		Vector2(-s * 1.05, -s * 0.16),    # prow, upper
		Vector2(-s * 1.05, s * 0.16),     # prow, lower
		Vector2(-s * 0.42, s * 0.66),
		Vector2(s * 0.34, s * 0.80),
		Vector2(s * 0.92, s * 0.50),
		Vector2(s * 1.00, s * 0.00),
		Vector2(s * 0.92, -s * 0.50),
		Vector2(s * 0.34, -s * 0.80),
		Vector2(-s * 0.42, -s * 0.66),
	]
	_facet_body(_body_xf(p, hull, ang), INK, 1.2)

	# Dorsal ridge: one paper hairline along the spine, from prow to stern. It is
	# the only internal line, and it is what makes the slab read as a body with a
	# top surface rather than a flat plate.
	var r0 := _body_xf(p, [Vector2(-s * 0.55, -s * 0.30)], ang)[0]
	var r1 := _body_xf(p, [Vector2(s * 0.62, -s * 0.14)], ang)[0]
	Ink.dashed(self, r0, r1, 1.0, 0.0, 2.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.30))

	# Nacelles: two engine mouths aft, drawn in paper so they survive the ink.
	for sy in [-1.0, 1.0]:
		var n0 := p + Vector2(s * 0.62, float(sy) * s * 0.52)
		draw_rect(Rect2(floorf(n0.x), floorf(n0.y), maxf(1.0, floorf(s * 0.34)), 1.0),
			Color(PAPER.r, PAPER.g, PAPER.b, 0.62), true)

	# The barrel: aimed at the player, always. Drawing the real aim vector (not
	# the body's forward axis) is what makes the craft look like it is tracking
	# you, and it is honest 鈥?the shot leaves along this line.
	var aim := (player - p)
	if aim.length() > 0.1:
		aim = aim.normalized()
		var b0 := p + aim * (s * 0.70)
		var b1 := p + aim * (s * 1.35)
		Ink.dashed(self, b0, b1, 1.0, 0.0, 1.4, Color(INK.r, INK.g, INK.b, 0.80))
		# Charge pip: a single pixel that swells as the shot reaches the muzzle.
		var ch := clampf(1.0 - fire / 0.55, 0.0, 1.0)
		if ch > 0.0:
			Ink.disc(self, b1, 1.0 + ch * 1.6, Color(INK.r, INK.g, INK.b, 0.30 + ch * 0.55))

	# Aft plume: two short paper breaths behind the nacelles.
	var wake := 0.18 + 0.14 * sin(seed * 4.0 + t * 9.0)
	for sy in [-1.0, 1.0]:
		var w0 := p + Vector2(s * 1.02, float(sy) * s * 0.52)
		Ink.dashed(self, w0, w0 + Vector2(s * 0.55, 0.0), 1.0, 0.0, 1.0,
			Color(PAPER.r, PAPER.g, PAPER.b, wake))


# kind 2 -- coil. A hexagonal gyro, and the roster's only hoverer.
#
# It used to be three concentric CIRCLES, which is the other half of the "all
# one round blob" complaint: a ring on a ring on a ring is a bullseye, and a
# bullseye has no faces for the light to catch. A hexagon does 鈥?six faces at six
# angles, so the per-edge lighting in _facet_body has something to work with.
#
# When it is about to fire the whole assembly COMPRESSES toward the core: the
# hexagon shrinks and the arms retract. That is the tell, and it costs no new
# object 鈥?the body simply winds up, the way a spring does.
func _draw_coil(p: Vector2, s: float, lean: float, spin: float, fire: float) -> void:
	var wind := clampf(1.0 - fire / 0.55, 0.0, 1.0)
	wind = wind * wind * (3.0 - 2.0 * wind)
	var k := 1.0 - wind * 0.22

	# Outer plate: a hexagon, rotated so a flat face points up. A vertex pointing
	# up would put the highlight on a 1px corner instead of a 4px face.
	var outer := []
	for j in 6:
		var a := TAU * float(j) / 6.0
		outer.append(Vector2(cos(a), sin(a)) * (s * k))
	_facet_body(_body_xf(p, outer, 0.0), INK, 1.2)

	# Inner plate: NO paper plate. This used to be a paper hexagon at 56% with
	# dashed facet edges, and that is exactly what read as a thick outline: it
	# left only a ~3px ink band between the paper plate and the silhouette edge,
	# so the hexagon's weight was a dark RING around a light disc rather than a
	# solid body. The player craft has no such ring 鈥?it is ink with one paper
	# seam 鈥?so the coil gets the same: a single paper hairline across the plate.
	var seam_a := _body_xf(p, [Vector2(-s * 0.72 * k, -s * 0.30 * k)], 0.0)[0]
	var seam_b := _body_xf(p, [Vector2(s * 0.72 * k, s * 0.30 * k)], 0.0)[0]
	Ink.dashed(self, seam_a, seam_b, 1.0, 0.0, 2.0,
		Color(PAPER.r, PAPER.g, PAPER.b, 0.72))
	var seam_c := _body_xf(p, [Vector2(-s * 0.30 * k, s * 0.66 * k)], 0.0)[0]
	var seam_d := _body_xf(p, [Vector2(s * 0.30 * k, s * 0.66 * k)], 0.0)[0]
	Ink.dashed(self, seam_c, seam_d, 1.0, 0.0, 2.0,
		Color(PAPER.r, PAPER.g, PAPER.b, 0.52))

	# Three arms. They retract into the plate as the volley arms.
	var arm_len := s * (1.30 - wind * 0.18)
	for j in 3:
		var a := spin + TAU * float(j) / 3.0
		var d := Vector2(cos(a), sin(a))
		Ink.dashed(self, p + d * (s * 0.62 * k), p + d * arm_len, 1.0, 0.0, 2.0, INK)
		# A 2x2 bead at each tip: mass at the end of a lever, not a stroke that
		# simply stops.
		draw_rect(Rect2(floorf(p.x + d.x * arm_len), floorf(p.y + d.y * arm_len),
			2.0, 2.0), INK, true)

	if wind > 0.02:
		# Charge: a tight hexagon at the core that closes as the volley arms.
		var cl := []
		for j in 6:
			var a := TAU * float(j) / 6.0
			cl.append(Vector2(cos(a), sin(a)) * s * (0.30 + 0.30 * (1.0 - wind)) * k)
		var cpts := _body_xf(p, cl, 0.0)
		for i in cpts.size():
			Ink.dashed(self, cpts[i], cpts[(i + 1) % cpts.size()], 1.0, 0.0, 1.5,
				Color(INK.r, INK.g, INK.b, 0.30 + wind * 0.55))


func weave_wave(ph: float) -> float:
	return sin(ph)


# d/dph of weave_wave, in the same normalised units. Used as a feed-forward
# velocity term: the body is told the speed its own curve is already carrying,
# so it traces the path instead of chasing it. Chasing is what produced the
# stall-at-the-extremes / rush-through-the-middle silhouette.
func weave_slope(ph: float) -> float:
	return cos(ph)

func pips(at: Vector2, hp: int) -> void:
	var n := mini(hp, 6)
	if n <= 0:
		return
	var x0 := floorf(at.x - float(n - 1) * 1.5)
	for i in n:
		draw_rect(Rect2(x0 + float(i) * 3.0, at.y, 1.0, 2.0), INK, true)


func draw_boss() -> void:
	if boss.is_empty():
		return
	if boss.has("is_rival"):
		draw_rival()
		return
	if boss.has("is_elite"):
		draw_elite()
		return
	var p: Vector2 = boss.p
	var rad := float(boss.r)
	var hurt := float(boss.hurt)
	var bt := float(boss.t)

	# ---- aimed-shot telegraph ----------------------------------------------
	# Drawn UNDER the shell so the line appears to come out from behind the
	# body. A dashed ray that fades over 0.24 s: long enough to register, short
	# enough that the player never has to keep dodging a line whose bullet is
	# already dead.
	if boss.has("telegraph"):
		var tg: Dictionary = boss.telegraph
		var tf: float = 1.0 - float(tg.t) / 0.24
		var tdir: Vector2 = tg.d
		var tfrom: Vector2 = tg.p + tdir * (rad * 0.9)
		var tto: Vector2 = tfrom + tdir * 240.0
		Ink.dashed(self, tfrom, tto, 1.0, 0.0, 3.0,
			Color(INK.r, INK.g, INK.b, 0.16 + tf * 0.34))

	# ---- a faceted ink shell, not a disc ------------------------------------
	# The boss was a flat disc with a curving outline stroke. A disc has no
	# faces, so per-edge lighting has nothing to act on and it can only ever be
	# a round blob 鈥?which is exactly the complaint.
	#
	# The shell is now a 10-gon. That is the smallest vertex count that still
	# reads as a body rather than a polygon: at r=28 each facet is ~17px long,
	# long enough for the lit/shadowed transition to be visible as a facet
	# rather than as a pixel-level dither. The silhouette is still round-ish
	# because the vertices are on a circle; what changed is that every edge now
	# carries its own colour.
	var spin := bt * 0.42
	var ring_pts := PackedVector2Array()
	var segs := 10
	for i in segs:
		var a := TAU * float(i) / float(segs) + spin * 0.10
		ring_pts.append(p + Vector2(cos(a), sin(a)) * rad)
	_facet_body(ring_pts, Color(0.29, 0.29, 0.27) if hurt > 0.0 else INK, 1.6)

	# ---- the turning face ---------------------------------------------------
	# Two paper bites that orbit at different rates. They are what makes the
	# shell read as a body turning in place instead of a coin, and they are the
	# only paper marks large enough to break the ink.
	var bofs := Vector2(cos(spin), sin(spin)) * (rad * 0.30)
	Ink.disc(self, p + bofs, rad * 0.34, PAPER)
	# Second bite: smaller, counter-rotating. Sitting inside the crescent it
	# carves the light shape into a comma, so the turning reads as a face
	# rather than as a hole sliding around a coin.
	var bofs2 := Vector2(cos(-spin * 0.7 + 1.1), sin(-spin * 0.7 + 1.1)) * (rad * 0.54)
	Ink.disc(self, p + bofs2, rad * 0.17, PAPER)

	# ---- iris: the attack telegraph -----------------------------------------
	# One paper disc at the centre. Its radius runs from 0.10*rad (shut) to
	# 0.42*rad (open) across the last 0.85 s before a volley. Because it is the
	# same paper as the bites and lives inside the shell, it reads as the body
	# opening rather than as an indicator bolted on 鈥?the boss's tell should be
	# its own anatomy.
	if boss.has("fire"):
		var fire_cd := float(boss.get("fire", 0.0))
		var open := clampf(1.0 - fire_cd / 0.85, 0.0, 1.0)
		open = open * open * (3.0 - 2.0 * open)
		var iris := rad * lerpf(0.10, 0.42, open)
		Ink.disc(self, p, iris, PAPER)
		# A shadowed rim on the lower-right of the iris: the aperture has depth,
		# it is a hole, so its far wall is dark.
		if iris > 3.0:
			for i in 8:
				var a2 := TAU * float(i) / 8.0
				if cos(a2 - 0.785) > 0.2:
					var q := p + Vector2(cos(a2), sin(a2)) * iris
					draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 1.0),
						Color(INK.r, INK.g, INK.b, 0.5), true)

	# Impact chip: a paper bite at the exact point the round landed, fading over
	# ~0.20 s. Advanced in step_boss/step_elite, never here 鈥?drawing must not
	# mutate state.
	if boss.has("chip"):
		var ch: Dictionary = boss.chip
		var ct := float(ch.t)
		if ct < 0.20:
			var cp: Vector2 = ch.p
			var cr := float(ch.r) * (1.0 - ct / 0.20)
			if cr > 0.5:
				Ink.disc(self, cp, cr, PAPER)

	# HP: a curved tick run hugging the crown. Dots follow the circle, so nothing
	# in this silhouette is a straight line.
	var frac := float(boss.hp) / float(boss.max)
	var steps := 26
	var lit := int(frac * float(steps))
	for i in steps:
		var a2 := PI + 0.36 + (PI - 0.72) * float(i) / float(steps - 1)
		var q := p + Vector2(cos(a2), sin(a2)) * (rad + 10.0)
		if i < lit:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 2.0, 2.0), INK, true)
		else:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.22), true)


# ---- elite silhouette --------------------------------------------------------
#
# A faceted octahedron, NOT a smaller version of the boss shell.
#
# Tier has to be readable by SHAPE alone: the palette has one ink and one paper,
# so size and outline are the only cues available. A shrunken disc would read as
# "the boss, further away"; a four-pointed crystal reads as a different enemy,
# which is what it is.
#
# The facets are the point here. A diamond drawn as two flat triangles is a
# sign; the same diamond split into four faces with four different edge colours
# is a solid, and that is the pseudo-3D the whole pass is about.
func draw_elite() -> void:
	var p: Vector2 = boss.p
	var rad := float(boss.r)
	var hurt := float(boss.hurt)
	var bt := float(boss.t)
	var frac := float(boss.hp) / float(boss.max)

	# Slow axial rock. A crystal that rocks is a rotor; a static one is a sign.
	var rock := sin(bt * 1.35) * 0.16
	# Breathe 4%: enough to keep it alive, small enough to keep the hitbox honest.
	var br := rad * (1.0 + sin(bt * 2.4) * 0.035)

	# Body: 6 vertices = an octahedron seen edge-on. Two side points, a top, a
	# bottom, and two intermediate shoulders that make the waist concave. The
	# concave waist is what stops it reading as a plain diamond.
	var d := _crystal(p, br, rock)
	# `arrive` flashes the shell for 0.30 s after taking up station, so the
	# body lands WITH the two arrival rings instead of after them. It was being
	# written every frame and never read 鈥?a silent no-op; the rings were doing
	# all the work. Deriving the colour here is the only place it can be spent.
	var arrive := float(boss.get("arrive", 0.0))
	var body_col := INK
	if hurt > 0.0:
		body_col = Color(0.33, 0.33, 0.30)
	elif arrive > 0.0:
		body_col = INK.lerp(Color(0.33, 0.33, 0.30), arrive * 0.85)
	_facet_body(d, body_col, 1.4)

	# Core: ONE paper seam down the vertical axis, not a smaller paper crystal.
	# The nested paper crystal left only a ~7px ink band on each side, so the
	# body read as a dark ring around a light diamond 鈥?the same "澶矖" failure
	# the coil had, and the same reason. The player craft carries its volume with
	# a single seam on solid ink, so the elite does too. The seam runs between
	# the top and bottom points, which is where a real facet edge would be.
	var top := _body_xf(p, [Vector2(0.0, -br * 0.74)], rock)[0]
	var bot := _body_xf(p, [Vector2(0.0, br * 0.74)], rock)[0]
	Ink.dashed(self, top, bot, 1.0, 0.0, 2.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.66))
	# A short cross seam, so the seam network reads as facets rather than a slit.
	var lf := _body_xf(p, [Vector2(-br * 0.42, 0.0)], rock)[0]
	var rt := _body_xf(p, [Vector2(br * 0.42, 0.0)], rock)[0]
	Ink.dashed(self, lf, rt, 1.0, 0.0, 2.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.44))

	# Orbit ticks: three marks rotating around the body. Speed doubles in phase 2
	# (50% health left), so the silhouette itself telegraphs the escalation.
	var spin := bt * (2.6 if frac > 0.5 else 5.2)
	for i in 3:
		var a := spin + TAU * float(i) / 3.0
		var q := p + Vector2(cos(a), sin(a)) * (br + 5.0)
		draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 1.0), INK, true)

	# Charge tell, same idea as the boss iris on a smaller body: the gap between
	# the ticks closes as the next ring arms.
	if boss.has("fire"):
		var fire_cd := float(boss.get("fire", 0.0))
		var open := clampf(1.0 - fire_cd / 0.60, 0.0, 1.0)
		if open > 0.0:
			Ink.ring(self, p, br + 2.5 + open * 2.0, 1.0,
				Color(INK.r, INK.g, INK.b, 0.18 + open * 0.45))

	# Health: same curved tick run as the boss, at a smaller radius so the two
	# healths never overlap when both exist across a loop.
	var steps := 14
	var lit := int(frac * float(steps))
	for i in steps:
		var a2 := PI + 0.30 + (PI - 0.60) * float(i) / float(steps - 1)
		var q := p + Vector2(cos(a2), sin(a2)) * (br + 8.0)
		if i < lit:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 2.0), INK, true)
		else:
			draw_rect(Rect2(floorf(q.x), floorf(q.y), 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.20), true)


# Six-vertex crystal: left, right, top, bottom, plus two concave shoulders.
func _crystal(p: Vector2, r: float, ang: float) -> PackedVector2Array:
	var body := [
		Vector2(0.0, -r * 1.15),          # top point
		Vector2(r * 0.52, -r * 0.34),     # shoulder, right
		Vector2(r * 1.00, 0.0),           # equator, right
		Vector2(r * 0.52, r * 0.34),      # shoulder, right-below
		Vector2(0.0, r * 1.15),           # bottom point
		Vector2(-r * 0.52, r * 0.34),
		Vector2(-r * 1.00, 0.0),
		Vector2(-r * 0.52, -r * 0.34),
	]
	return _body_xf(p, body, ang)


# ---------------------------------------------------------------------------
# PLAYER 鈥?side profile
# ---------------------------------------------------------------------------

func draw_player() -> void:
	var p := player
	if dead:
		return

	# Body frame shared by every part. Small: the craft leans, it does not rotate
	# to face its velocity 鈥?a 24px interceptor that turns its nose at the mouse
	# reads as a different genre.
	var body_ang := hull_yaw * 0.13 - hull_roll * 0.04

	# ---- engine wake ----------------------------------------------------
	# Graded flame, not a fixed 3-stroke fan. Four nested layers, each shorter and
	# fainter than the one inside it, drawn back-to-front so the effect is a
	# density gradient along the plume rather than an outline.
	#
	# The plume is deliberately NARROWER than the fuselage at the nozzle: an
	# 11px-tall flame on a 6px-tall body makes the engine the biggest shape on
	# the sprite, and the ship reads as a blob with a grey cloud behind it.
	var plume := (7.5 + sin(t * 26.0) * 1.3) * (0.85 + trail_w * 1.05)
	if focus_on:
		plume *= 0.55
	plume *= 0.94 + wing_flap * 0.20
	var flick := 0.85 + sin(t * 41.0) * 0.15
	var stretch := 1.0 + trail_w * 0.55

	var spine := flame_spine()

	# Layer 3: faint outer tip, drawn first so the hot layers sit on top.
	_flame_spine(spine, plume * 1.30 * flick * stretch, 3.0, Color(INK.r, INK.g, INK.b, 0.20 + trail_w * 0.18))
	# Layer 2: the mid wash.
	_flame_spine(spine, plume * 0.98 * flick * stretch, 2.2, Color(INK.r, INK.g, INK.b, 0.34 + trail_w * 0.24))
	# Layer 1: bright body.
	_flame_spine(spine, plume * 0.70 * stretch, 1.5, Color(INK.r, INK.g, INK.b, 0.55 + trail_w * 0.30))

	# Layer 0: the white-hot core, pinned to the front third of the spine so it
	# can never lag behind the nozzle.
	var core_len := plume * 0.40 * (1.0 + trail_w * 0.25)
	if core_len > 1.5:
		_core_along_spine(spine, core_len)

	# After-image wake: the hull's own residue along the recent path.
	if trail_w > 0.28:
		for k in 3:
			var echo := p - vel * (0.038 + float(k) * 0.030)
			var fade_k := (1.0 - float(k) * 0.33) * trail_w
			Ink.dashed(self, Vector2(echo.x - 12.0, echo.y), Vector2(echo.x - 15.0 - trail_w * 5.0, echo.y),
				1.0, 0.0, 1.5, Color(INK.r, INK.g, INK.b, 0.16 * fade_k))

	# ---- hull ------------------------------------------------------------
	# A SIDE PROFILE, not a plan view.
	#
	# The previous outline was a symmetric delta wing with a large vertical span.
	# Every part of it was mirrored about the body axis, so it read as the craft
	# seen from ABOVE 鈥?and once the eye settles on a plan view it cannot be
	# talked out of it, which is why the ship looked like it was facing the
	# camera. A side-scroller needs a side view: a horizontal fuselage, a dorsal
	# fin sweeping up and aft, a small ventral fin below, a canopy hump on top
	# of the nose section.
	#
	# That also fixes the second problem. In plan view the only place a gun can
	# plausibly sit is the tip of the point, which is why the muzzle flash kept
	# appearing as a bar stuck on the nose. In side view the gun ports live on
	# the fin roots, one per fin, and the alternation is between the dorsal and
	# the ventral root 鈥?two visibly different places on the body.
	# ---- invulnerable: FLASH, don't dissolve ----------------------------
	# This used to replace the hull with a dashed outline for the whole 1.35 s of
	# invulnerability. Two problems with that:
	#
	#   * the craft VANISHED at the exact moment the player most needs to see
	#     where it is. A hit knocks it back and the next thing the player has to
	#     judge is the reposition 鈥?drawing it as a ring of dots throws away
	#     every cue for that;
	#   * a dashed outline on a 26px craft is a dozen disconnected specks, which
	#     is the same "blob" failure the enemies had.
	#
	# Instead the hull is drawn SOLID and blinks. That is the conventional
	# reading of "hit but not dead", it keeps the silhouette on screen the whole
	# time, and it needs no new vocabulary.
	#
	# 12 Hz, and never fully off: dropping to alpha 0 would read as the craft
	# having been destroyed, which is precisely the state it is NOT in.
	var blink := 1.0
	if invuln > 0.0:
		blink = 0.42 + absf(sin(invuln * TAU * 6.0)) * 0.58

	# Paper halo: one pixel of cream around the whole craft. This is what keeps a
	# black silhouette legible over the black moon as well as over cream paper.
	# The halo stays at full alpha during the blink: it is what holds the craft's
	# POSITION on screen while the body itself fades, so the player never loses
	# track of where they were knocked to.
	Ink.fill_poly(self, _hull_xf(p, body_ang, 1.15), Color(PAPER.r, PAPER.g, PAPER.b, 0.92))

	Ink.fill_poly(self, _hull_xf(p, body_ang), Color(INK.r, INK.g, INK.b, blink))

	# Dorsal fin shading: the fin's upper face catches the light, so it is drawn
	# one step lighter than the fuselage. At 1x this is the only way the fin
	# reads as a surface instead of as a spike.
	var k_fin := _hull_kin()
	var fin_top := _body_slab(p, body_ang, k_fin)
	if fin_top.size() >= 3:
		Ink.fill_poly(self, fin_top, Color(0.30, 0.30, 0.28))

	# ---- seams -----------------------------------------------------------
	# One paper hairline along the fin's leading edge. It is drawn from the same
	# body-space points the outline uses, so it tracks the fold exactly: the line
	# stands up straighter as the craft pitches, and lies back when it dives.
	var fin_lead := _fin_lead(p, body_ang)
	Ink.dashed(self, fin_lead[0], fin_lead[1], 1.0, 0.0, 2.0,
		Color(PAPER.r, PAPER.g, PAPER.b, 0.34))
	# Ventral fin mark, shorter and fainter 鈥?it is the far side of the craft and
	# should not compete with the dorsal fin.
	var ven_lead := _ventral_lead(p, body_ang)
	Ink.dashed(self, ven_lead[0], ven_lead[1], 1.0, 0.0, 2.0,
		Color(PAPER.r, PAPER.g, PAPER.b, 0.24))

	# Canopy: a dithered hump on top of the nose section. In side view this is
	# the single strongest "which way is forward" cue, so it slides with pitch
	# and squashes as the nose comes down.
	var cw := clampf(3.0 - hull_yaw * 0.7, 2.0, 4.0)
	var cc := _pt_xf(p, Vector2(6.2 - hull_roll * 0.8, -2.6 + hull_yaw * 1.2), body_ang)
	Ink.dither_rect(self, Rect2(cc.x, cc.y, cw, 2.0), PAPER, 8)

	# Exhaust: a single paper slot at the very tail, where the plume leaves.
	var ex := _pt_xf(p, Vector2(-12.0, -0.4), body_ang)
	draw_rect(Rect2(ex.x, ex.y, 1.0, 2.0), Color(PAPER.r, PAPER.g, PAPER.b, 0.85), true)

	# ---- wing-gun muzzle flash ------------------------------------------
	# Fires from the fin ROOT that just shot, not from the nose. This is the
	# visible half of the alternation: the flash jumps between the dorsal and the
	# ventral root, so the twin-gun rhythm is legible on the hull itself.
	if shot_pulse > 0.02:
		var side := -1.0 if cannon == 0 else 1.0
		var mz := wing_muzzle(p, side)
		var mh := 1.0 + shot_pulse * 2.0
		draw_rect(Rect2(mz.x, mz.y - mh * 0.5, 2.0 + shot_pulse * 2.0, mh),
			Color(INK.r, INK.g, INK.b, 0.30 + shot_pulse * 0.55), true)

	# ---- impact punch ----------------------------------------------------
	if hit_t > 0.0:
		var k := hit_t / 0.42
		var rr := 5.0 + (1.0 - k) * 12.0
		Ink.ring(self, p, rr, 1.0, Color(PAPER.r, PAPER.g, PAPER.b, 0.85 * k))
		for i in 4:
			var a2 := TAU * float(i) / 4.0 + 0.6
			var d := Vector2(cos(a2), sin(a2))
			Ink.dashed(self, p + d * 4.0, p + d * (7.0 + (1.0 - k) * 10.0), 1.0, 0.0, 1.5,
				Color(INK.r, INK.g, INK.b, 0.55 * k))

	if focus_on:
		draw_rect(Rect2(p.x - 0.5, p.y - 0.5, 1.0, 1.0), PAPER, true)


# Body-space -> world, snapped to whole pixels.
func _pt_xf(p: Vector2, v: Vector2, ang: float) -> Vector2:
	var c := cos(ang)
	var s := sin(ang)
	return Vector2(floorf(p.x + v.x * c - v.y * s), floorf(p.y + v.x * s + v.y * c))


# The three deformation channels, resolved once so the silhouette, the seams and
# the gun ports can never disagree about where the fin is.
func _hull_kin() -> Dictionary:
	var g := 1.0 + (0.40 if focus_on else 0.0)
	return {
		"g": g,
		"nose": -hull_yaw * 1.8,          # nose rides up on a climb
		"sweep": hull_roll * 2.4,          # fin lies back when moving forward
		"fin": (7.0) * g,                  # dorsal fin height
		"ven": (4.0) * g,                  # ventral fin depth
		"breath": sin(t * 2.2) * 0.30,     # idle
	}


# Forward gun port on the DORSAL fin root.
func _fin_lead(p: Vector2, ang: float) -> Array:
	var k := _hull_kin()
	var root := Vector2(5.0, -2.0 + float(k.nose) * 0.30)
	var tip := Vector2(-4.2 - float(k.sweep), -float(k.fin) + float(k.breath))
	return [_pt_xf(p, root, ang), _pt_xf(p, tip, ang)]


# Forward gun port on the VENTRAL fin root.
func _ventral_lead(p: Vector2, ang: float) -> Array:
	var k := _hull_kin()
	var root := Vector2(1.0, 2.0)
	var tip := Vector2(-5.6 - float(k.sweep) * 0.5, float(k.ven) - float(k.breath))
	return [_pt_xf(p, root, ang), _pt_xf(p, tip, ang)]


# Wing hardpoint, in world space, for the fin that is firing this round.
#
# The two ports are the two fin roots, which in a side view sit at visibly
# different heights 鈥?that separation is what makes "left/right alternation"
# legible at all once the craft is drawn in profile. Reading the same kinematics
# as the silhouette keeps the flash attached to the drawn fin instead of
# drifting off it as the craft pitches.
func wing_muzzle(p: Vector2, side: float) -> Vector2:
	var body_ang := hull_yaw * 0.13 - hull_roll * 0.04
	if side < 0.0:
		return _fin_lead(p, body_ang)[0] + Vector2(1.0, 0.0)
	return _ventral_lead(p, body_ang)[0] + Vector2(1.0, 0.0)


# The dorsal fin as its own filled slab, for the lighter face.
#
# A one-polygon craft cannot shade its fin separately, but a fin is a distinct
# plane angled away from the fuselage, so it MUST be a different value or the
# whole craft is one flat black shape. Drawing the fin region again in a lighter
# grey, over the ink body, gives it that plane without splitting the silhouette
# into parts that could separate under the CRT's blur.
func _body_slab(p: Vector2, ang: float, k: Dictionary) -> PackedVector2Array:
	var fin: float = float(k.fin)
	var sweep: float = float(k.sweep)
	var br: float = float(k.breath)
	return _pts_xf(p, [
		Vector2(4.8, -2.0),
		Vector2(-4.2 - sweep, -fin + br),
		Vector2(-7.0 - sweep, -fin * 0.94 + br),
		Vector2(-3.2 - sweep * 0.3, -2.4),
	], ang)


func _pts_xf(p: Vector2, pts: Array, ang: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in pts:
		out.append(_pt_xf(p, v as Vector2, ang))
	return out


# Side-profile interceptor.
#
# Outline order runs clockwise from the nose: along the top edge, up the dorsal
# fin's leading edge, around its tip, back down the trailing edge to the spine,
# aft to the tail, along the belly (including the ventral fin), and forward
# again. One polygon, because at 26 x 14 px two touching ink shapes cannot be
# separated by a 1px cream gap 鈥?the seam has to be a paper line ON the ink.
#
# 26 long, 7 tall for the fuselage, 7 up for the fin. The asymmetry is the whole
# point: a mirrored outline is a plan view, and a plan view reads as a craft
# pointing at the camera.
func _hull_xf(p: Vector2, ang: float, grow := 0.0) -> PackedVector2Array:
	var k := _hull_kin()
	var nose: float = float(k.nose)
	var sweep: float = float(k.sweep)
	var fin: float = float(k.fin) + grow
	var ven: float = float(k.ven) + grow
	var br: float = float(k.breath)
	# The nose is BLUNT, not tapered to a point.
	#
	# A 26px fuselage drawn as a needle 鈥?a single vertex out at x=13 with the
	# body only 4px tall there 鈥?is a stick glued to the front of the craft, and
	# that is what it looked like. A blunt nose two or three pixels tall reads as
	# a nose because it has mass.
	var raw := [
		Vector2(10.6 + grow, -1.1 - grow + nose),                # nose, upper lip
		Vector2(11.0 + grow, 1.1 + grow + nose),                 # nose, lower lip
		Vector2(8.8 + grow, 1.5 + grow + nose * 0.60),
		Vector2(4.6 + grow, 2.0 + grow + nose * 0.24),
		Vector2(1.0 + grow, 2.2 + grow),                         # ventral fin root
		Vector2(-2.4 - sweep * 0.5 + grow, ven * 0.96 - br),     # ventral tip, leading
		Vector2(-5.6 - sweep * 0.5 + grow, ven - br),            # ventral tip, trailing
		Vector2(-8.8 + grow, 2.0 + grow),
		Vector2(-12.4 + grow, 1.2 + grow),                       # tail, lower
		Vector2(-12.4 + grow, -1.2 - grow),                      # tail, upper
		Vector2(-8.6 + grow, -2.2 - grow),                       # aft spine
		Vector2(-3.2 - sweep * 0.3 + grow, -2.4 - grow),         # fin trailing root
		Vector2(-7.0 - sweep + grow, -fin * 0.94 + br),          # fin tip, trailing
		Vector2(-4.2 - sweep + grow, -fin + br),                 # fin tip, leading
		Vector2(4.8 + grow, -2.2 - grow + nose * 0.28),          # dorsal fin root
		Vector2(8.8 + grow, -1.5 - grow + nose * 0.60),
	]
	var out := PackedVector2Array()
	for v in raw:
		out.append(_pt_xf(p, v as Vector2, ang))
	return out


func _flame_run(p: Vector2, length: float, bend: float, half_h: float, col: Color) -> void:
	# One flame layer: a filled wedge tapering to nothing at the tail, so the
	# silhouette narrows instead of ending in a flat cut. Rows are 1px, and the
	# tail offset by `bend` gives the plume its lean.
	var steps := int(maxf(1.0, floorf(length)))
	for i in steps:
		var tt := float(i) / float(steps)
		# Width falls off toward the tail: full at the nozzle, zero at the tip.
		var w := half_h * (1.0 - tt * tt)
		if w < 0.5:
			w = 0.5
		var x := p.x - 8.0 - float(i)
		var y := p.y + bend * tt
		draw_rect(Rect2(floorf(x), floorf(y - w), 1.0, maxf(1.0, floorf(w * 2.0))), col, true)


# Resample the bone chain into a smooth polyline with a fixed number of points.
# Catmull-Rom between joints: the bones themselves are coarse (6 joints over
# ~20px), so drawing bones directly would show angular kinks. Interpolating
# makes the plume read as a curved stream.
func flame_spine() -> PackedVector2Array:
	var n := bones.size()
	if n < 2:
		return PackedVector2Array([player + Vector2(-9.0, 0.0), player + Vector2(-16.0, 0.0)])
	var out := PackedVector2Array()
	var per := 3   # samples between each pair of joints
	for i in n - 1:
		var p0 := bones[maxi(0, i - 1)]
		var p1 := bones[i]
		var p2 := bones[i + 1]
		var p3 := bones[mini(n - 1, i + 2)]
		for s in per:
			var u := float(s) / float(per)
			# Catmull-Rom
			var a := p1 * 2.0
			var b := (p2 - p0) * u
			var c := (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * u * u
			var d := (-p0 + p1 * 3.0 - p2 * 3.0 + p3) * u * u * u
			out.append((a + b + c + d) * 0.5)
	out.append(bones[n - 1])
	return out


# Draw one flame layer along a spine. Width tapers along the SPINE LENGTH, not
# along world x, so the plume narrows correctly even when it curves.
func _flame_spine(spine: PackedVector2Array, length: float, half_h: float, col: Color) -> void:
	if spine.size() < 2 or length < 1.0:
		return
	# Walk the spine accumulating arc length; stop at `length`.
	var acc := 0.0
	var total := length
	for i in spine.size() - 1:
		var a := spine[i]
		var b := spine[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.01:
			continue
		if acc + seg > total:
			seg = total - acc
			b = a + (b - a).normalized() * seg
		var steps := int(maxf(1.0, floorf(seg)))
		for s in steps:
			var f := float(s) / float(steps)
			var tt := (acc + seg * f) / maxf(total, 0.001)
			var pos := a.lerp(b, f)
			# Taper: full at the nozzle, zero at the tip.
			var w := half_h * (1.0 - tt * tt)
			if w < 0.5:
				w = 0.5
			draw_rect(Rect2(floorf(pos.x), floorf(pos.y - w), 1.0, maxf(1.0, floorf(w * 2.0))), col, true)
		acc += seg
		if acc >= total:
			break


# The white core, constrained to the front of the spine. Pinning it there is
# what stops it "lagging behind" 鈥?the tail may whip, the highlight stays put.
func _core_along_spine(spine: PackedVector2Array, length: float) -> void:
	if spine.size() < 2:
		return
	var acc := 0.0
	for i in spine.size() - 1:
		var a := spine[i]
		var b := spine[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.01:
			continue
		if acc + seg > length:
			seg = length - acc
			b = a + (b - a).normalized() * seg
		var steps := int(maxf(1.0, floorf(seg)))
		for s in steps:
			var f := float(s) / float(steps)
			var pos := a.lerp(b, f)
			draw_rect(Rect2(floorf(pos.x), floorf(pos.y - 1.0), 1.0, 2.0), CORE, true)
		acc += seg
		if acc >= length:
			break


func draw_sparks() -> void:
	for s in sparks:
		# Not born yet. `delay` is counted down in step_sparks; a spark still
		# waiting must not be drawn at its spawn position, or the whole
		# staggered column would appear as a flash at the start.
		if float(s.get("delay", 0.0)) > 0.0:
			continue
		var fade := clampf(float(s.life) / float(s.max), 0.0, 1.0)
		var w := int(s.get("w", 1))
		var a := 0.22 + fade * 0.78
		# Bigger debris shrinks as it dies, which reads as burning out.
		var size := float(w) if fade > 0.35 else 1.0
		var sp: Vector2 = s.p
		# Hot debris only glows when the CALLER asked for it.
		#
		# This used to key purely on `fade > 0.72` with no regard for the `core`
		# flag, so every speck -- including the six thrown by an ordinary hit --
		# spent the first quarter of its life as pure white. Each of those is
		# above the bloom gate, meaning every bullet that connected lit the glow
		# pass six times over. That, not the hull flash, was what made enemy
		# hits read as detonations.
		var hot: bool = bool(s.get("core", false)) and fade > 0.72
		if hot:
			draw_rect(Rect2(floorf(sp.x), floorf(sp.y), size, size), CORE, true)
		else:
			draw_rect(Rect2(floorf(sp.x), floorf(sp.y), size, size),
				Color(INK.r, INK.g, INK.b, a), true)


# Repaint paper outside the inner bezel so nothing pokes past the frame.
func draw_mask() -> void:
	pass


func draw_frame() -> void:
	pass


# ---------------------------------------------------------------------------
# HUD 鈥?a single instrument panel, not four scattered marks.
#
# Everything is anchored to the FRAME itself:
#
#   * a hairline "rail" runs just inside the border and every readout hangs
#     from it, so the panel is visibly part of the plate;
#   * one baseline for all bottom readouts (the rail), so the ink gauge, the
#     gun cluster and the loop ticks sit on the same line;
#   * one spacing unit (4 px) and one tick length (3 px) for every mark;
#   * brackets around the ink gauge, so the "fill target" is a drawn container
#     rather than a floating rectangle.
#
# Everything stays text-free and inside the palette: ink on paper, or paper on
# ink when a mark sits over the moon.
# ---------------------------------------------------------------------------

const HUD_RAIL := 3.0          # distance from the frame rule to the rail
const HUD_INSET := 14.0        # left/right padding for readouts
const HUD_TICK := 3.0          # every mark is this long
const HUD_STEP := 4.0          # spacing unit


func draw_hud() -> void:
	var f := FRAME
	var rail_x := f.position.x + HUD_RAIL
	var rail_y := f.position.y + HUD_RAIL
	var rail_r := f.end.x - HUD_RAIL
	var rail_b := f.end.y - HUD_RAIL

	# ---- 1. rails -------------------------------------------------------
	# Four corner brackets rather than a full second rectangle. A complete inner
	# rectangle would compete with the frame rule and read as "two borders"; a
	# broken rail reads as registration marks on a printed plate, which is the
	# language the rest of the art already speaks.
	var arm := 18.0
	var rail := Color(INK.r, INK.g, INK.b, 0.55)
	_corner_bracket(Vector2(rail_x, rail_y), 1.0, 1.0, arm, rail)
	_corner_bracket(Vector2(rail_r, rail_y), -1.0, 1.0, arm, rail)
	_corner_bracket(Vector2(rail_x, rail_b), 1.0, -1.0, arm, rail)
	_corner_bracket(Vector2(rail_r, rail_b), -1.0, -1.0, arm, rail)

	# ---- 2. kills: "K NN" in the 5x7 pixel font -------------------------
	#
	# Replaces the tally the plate used before. The tally was elegant and
	# completely unreadable in a live game: to know the score you had to count
	# slash-crossed groups, which nobody does while dodging. A label plus a
	# numeral answers "how many" in one glance.
	#
	# The string is drawn left-anchored on the rail and zero-padded to two
	# digits, so the readout never changes width as the count crosses 10 鈥?a
	# readout that reflows mid-run pulls the eye for no reason.
	var kills := mini(score, 99)
	var kill_label := "K %02d" % kills
	var kill_pos := Vector2(rail_x + 6.0, rail_y + 9.0)
	Ink.text(self, kill_pos, kill_label, INK, 2.0)

	# ---- 2b. armoury: which tiers are still in the bag -------------------
	#
	# The top-right corner was deliberately empty until the wheel selector
	# existed. Now there is a question the player must answer BEFORE rolling
	# the wheel -- "what do I still have?" -- and no other mark can answer it:
	# the bottom cluster describes only the ARMED tier.
	#
	# Seven vertical bars, right-aligned so the row grows leftward and can never
	# collide with anything, one per special tier in index order (B G S L F R W).
	# A tier that can still fire is solid; an empty one is only a ghost at 0.13
	# alpha, the same vocabulary the magazine cells use for "nothing loaded".
	# The armed tier is marked by a 1px underline under its own bar -- an
	# underline is the smallest possible "you are here" and adds no new glyph.
	#
	# No box, no label, no number: a frame around seven bars would read as one
	# instrument and the bar count is the whole content.
	var bar_w := 3.0
	var bar_h := 5.0
	var bar_pitch := 5.0
	var bar_y := rail_y + 9.0
	# 7 bars at 5px pitch span 34px; anchor the RIGHT edge 6px inside the rail.
	var bar_x1 := rail_r - 6.0 - float(WEAPON_LAST - WEAPON_BOMB) * bar_pitch
	for k in range(WEAPON_BOMB, WEAPON_LAST + 1):
		var bx := bar_x1 + float(k - WEAPON_BOMB) * bar_pitch
		var armed := (k == weapon)
		var live := has_rounds(k)
		var a := 0.55 if live else 0.13
		if armed:
			a = 1.0
		draw_rect(Rect2(floorf(bx), floorf(bar_y), bar_w, bar_h),
			Color(INK.r, INK.g, INK.b, a), true)
		if armed:
			# Underline: sits 1px below the bar. Drawn at 0.75 rather than the
			# hairline 0.45 because at 3x with chroma the 0.45 version broke into
			# a dark red smear and stopped reading as "you are here". Still no
			# new element: it is the same 1px rule the frame already uses.
			draw_rect(Rect2(floorf(bx), floorf(bar_y + bar_h + 1.0), bar_w, 1.0),
				Color(INK.r, INK.g, INK.b, 0.75), true)

	# ---- 3. hull: three hearts, 1px silhouette, 2x ----------------------
	#
	# The hull was a row of vertical ticks. Ticks state a number but carry no
	# meaning about what is being lost, so a new player reads "3" without
	# learning that it is lives. A heart is unambiguous at 7px and still draws
	# entirely in hairlines, so it belongs to the same vocabulary as everything
	# else on the plate.
	#
	# THE LAST HEART BLINKS. A hull at 1 is the only state where the next hit
	# ends the run, and it is also the state a player is least likely to notice:
	# the difference between two hearts and one is a single small glyph in a
	# corner they are not looking at. Blinking is the smallest change that makes
	# that state announce itself without adding a new element or a colour.
	var hy := rail_y + 26.0
	for i in HULL_MAX:
		# 7px glyph at 2x is 14px wide; 18px pitch leaves a clear 4px gap.
		var x := rail_x + 7.0 + float(i) * 18.0
		var alive := i < hull
		var col := INK
		if not alive:
			# Spent hearts stay on the plate as hollow silhouettes, so the
			# maximum is still legible and the row never shifts.
			col = Color(INK.r, INK.g, INK.b, 0.20)
		elif hull == 1:
			# ~2.6Hz, never fully dark: dropping the icon out entirely would
			# read as "already lost" at the bottom of the fade and make the
			# player think they had died.
			col = Color(INK.r, INK.g, INK.b, 0.45 + sin(t * 16.0) * 0.55)
			col.a = clampf(col.a, 0.30, 1.0)
		Ink.heart(self, Vector2(x, hy), alive, col, 2.0)

	# ---- 3b. healing pip ---------------------------------------------------
	# A single hairline bar under the hearts that fills while a segment is
	# regenerating. Without it the heal is invisible until the heart pops back,
	# and a silent heal reads as a bug ("why did I get a life?").
	if hull < HULL_MAX:
		var hx := rail_x + 7.0
		var hyy := rail_y + 42.0
		var hw := 40.0
		if heal_t < HEAL_DELAY:
			# Still in the "cannot heal yet" window: a dim static rule, so the
			# player can see the system exists before it does anything.
			draw_rect(Rect2(hx, hyy, hw, 1.0), Color(INK.r, INK.g, INK.b, 0.14), true)
		else:
			var hf := clampf(heal_acc / HEAL_STEP, 0.0, 1.0)
			draw_rect(Rect2(hx, hyy, floorf(hw * hf), 1.0), Color(INK.r, INK.g, INK.b, 0.55), true)
			draw_rect(Rect2(hx, hyy, hw, 1.0), Color(INK.r, INK.g, INK.b, 0.14), true)

	# ---- 3c. passive item state -----------------------------------------
	#
	# Shield and thorn are PERSISTENT state and have to be visible without
	# the player looking for them; the barrage has no state and is absent by
	# design (see the note on `item_shield`).
	#
	# Both markers live on the heal pip's row and grow RIGHTWARD from the
	# heart row's own left edge, so the whole left column reads as one block:
	# kills, hull, heal progress, then what is protecting the hull.
	#
	# ---- why two SHAPES and not two colours ------------------------------
	# There are no colours. A shield charge and an armed thorn therefore have
	# to differ in geometry, and they differ in the same vocabulary the pickup
	# plates use -- a horizontal bar versus a vertical stack:
	#
	#   shield   1px bar per charge, drawn SIDE BY SIDE (a wall)
	#   thorn    a small vertical tick, standing alone at the row's right
	#
	# Both are at 2x-equivalent weight (2px strokes) because this corner is
	# where `focus_field` blurs hardest; at 1px they would be eaten to grey.
	# `rail_y + 48`, NOT +42: the heal pip already owns that row, and the first
	# draft drew the shield bars straight through it. Two readouts sharing a
	# baseline is a rule everywhere else on this plate; here they are different
	# KINDS of information (recovery vs protection), so they get separate rows.
	var item_y := rail_y + 49.0
	var item_x := rail_x + 7.0
	# ---- why TWO fixed slots and not "only the ones you still hold" -------
	# The first version drew `for k in item_shield`, i.e. only the remaining
	# charges. That makes the row SHORTEN when a charge is spent, and a row
	# that changes shape is a different object -- the player reads "something
	# else appeared" rather than "a charge went away". Both slots are
	# therefore always drawn, and a spent charge is the SAME 3x2 cell at
	# alpha 0.13, which is the magazine-cell vocabulary: dim means empty, and
	# it is the same shape as full.
	#
	# ---- why 6px pitch and not 4 -----------------------------------------
	# At 4px pitch a 3px cell leaves a 1px gap. Under 3x CRT bleed plus
	# focus_field at its strongest in this corner, a 1px gap is smeared into
	# nothing and the two cells merge into one 10px bar -- which reads as
	# "one" rather than "two". 6px pitch leaves a 3px gap that survives.
	#
	# ---- why rail_y + 49 and not +42 or +48 -------------------------------
	# The heal pip owns rail_y + 42 exactly (one 1px rule). +48 put the thorn
	# tick's top at rail_y + 44, one row from the pip, and under 3x bleed the
	# two read as one object. +49 leaves rows 43-44 as real paper.
	#
	# Shield charges: BOTH slots always drawn, dim for spent.
	for k in ITEM_SHIELD_CHARGES:
		var a := 1.0 if k < item_shield else 0.13
		draw_rect(Rect2(floorf(item_x + float(k) * 6.0), floorf(item_y), 3.0, 2.0),
			Color(INK.r, INK.g, INK.b, a), true)
	# Thorn: a vertical tick, 2 wide, 6 tall, standing to the RIGHT of the
	# widest the shield row can ever be (slot 1 ends at item_x + 9, this
	# starts at item_x + 12 -> 3px of air, so both can be present at once).
	var ta := 1.0 if item_thorn else 0.13
	draw_rect(Rect2(floorf(item_x + 12.0), floorf(item_y - 4.0), 2.0, 6.0),
		Color(INK.r, INK.g, INK.b, ta), true)
	# ---- probe readout ---------------------------------------------------
	# Printed only when a probe asked for it, and only once, so a normal run
	# never pays for it. This is the "可读中间量" the project requires of every
	# effect: the HUD is the only place the two passives are visible, and a
	# silent HUD is indistinguishable from a passive that never armed.
	if OS.get_environment("HALFMOON_ITEMHUD") != "":
		if item_shield > 0 or item_thorn:
			if hud_report_done == false:
				hud_report_done = true
				print("ITEMHUD shield=%d thorn=%s" % [item_shield, str(item_thorn)])

	# ---- 4. ink gauge: bottom rail, graduated container ------------------
	# The gauge is the readout that matters most, so it gets the widest
	# footprint, its own end caps and internal graduations. Graduations are
	# what turn a rectangle into an instrument: with them, the fill level can
	# be judged at a glance against a known scale rather than as "some
	# fraction".
	#
	# Graduations run as MAJOR/MINOR, the way a measuring scale does: a quarter
	# mark is a 3px tick reaching up out of the bar, an eighth mark is a 1px
	# tick sitting on its own edge. One uniform row of dots would read as
	# texture; two heights read as a scale.
	var gx := rail_x + HUD_INSET
	var gw := 86.0
	var gh := 5.0
	var gy := rail_b - HUD_INSET
	var g := Rect2(gx, gy, gw, gh)
	Ink.rect(self, g, 1.0, 0.0, Color(INK.r, INK.g, INK.b, 0.45))
	# Graduations sit OUTSIDE the bar, not through it.
	#
	# Drawing a 1px line through the container was wrong: the fill is hatched,
	# so a tick crossing the interior reads as a cut in the vessel and splits
	# the gauge into four unrelated boxes. An instrument's graduations live on
	# the frame beside the scale 鈥?above the bar here, where there is paper and
	# nothing to interrupt.
	for q in range(1, 4):
		var mx := gx + floorf(gw * float(q) / 4.0)
		draw_rect(Rect2(mx, gy - 4.0, 1.0, 3.0), Color(INK.r, INK.g, INK.b, 0.40), true)
	for q in range(1, 8, 2):
		var nx := gx + floorf(gw * float(q) / 8.0)
		draw_rect(Rect2(nx, gy - 2.0, 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.24), true)
	if gauge > 0.0:
		Ink.hatch(self, Rect2(g.position.x + 1.0, g.position.y + 1.0,
			floorf((g.size.x - 2.0) * gauge), g.size.y - 2.0), 2.0, 45.0, 1.0)
	# End caps: two short verticals that close the container, so the bar reads
	# as an enclosed vessel instead of an open line.
	_vert(gx - 2.0, gy - 1.0, gh + 2.0, Color(INK.r, INK.g, INK.b, 0.55))
	_vert(gx + gw + 1.0, gy - 1.0, gh + 2.0, Color(INK.r, INK.g, INK.b, 0.55))
	if gauge >= 1.0:
		# Full: the caps pulse solid. Still no text, still no colour -- the
		# plate simply closes around a full gauge.
		var blink := 0.55 + sin(t * 9.0) * 0.45
		_vert(gx - 2.0, gy - 1.0, gh + 2.0, Color(INK.r, INK.g, INK.b, blink))
		_vert(gx + gw + 1.0, gy - 1.0, gh + 2.0, Color(INK.r, INK.g, INK.b, blink))

	# ---- 5. gun cluster: three SEPARATE marks -----------------------------
	# Three readings, three objects, three gaps.
	#
	# The first version welded all of this into one enclosed channel with
	# hairline dividers, on the theory that a single frame makes it one
	# instrument. It did not: three unrelated quantities were pressed against
	# each other with 1px between them, so the eye could not tell where one
	# ended and the next began. "Simple" and "merged" are not the same thing 鈥?
	# a divider is still a boundary the eye has to parse, and at 1px with CRT
	# bleed it is not even a clean one.
	#
	# So the container is gone. What is left is three marks with real air
	# between them, each answering exactly one question:
	#
	#   A  can I shoot yet    one round standing on the rail
	#   B  how much is left   five counted cells
	#   C  when does it come  a ring that closes while reloading, and sits
	#      back                 open and dim when ready
	var cx := gx + gw + 12.0
	var cy := rail_b - HUD_INSET
	var gh2 := gh + 2.0
	var top := cy - 1.0
	# ONE baseline for the whole cluster: the ink gauge's bottom edge. Declared
	# here rather than inside the magazine block, because all three marks read
	# from it and a declaration after first use is a parse error waiting to
	# happen.
	var base_y := gy + gh - 1.0
	var cell_h := 7.0
	var cell_top := base_y - cell_h + 1.0

	var cd_len := float(WEAPON_CD[weapon])
	var ready := 1.0 - clampf(cooldown / maxf(cd_len, 0.001), 0.0, 1.0)

	# ---- A. the round, VERTICAL -----------------------------------------
	# A bullet standing on the rail, muzzle up.
	#
	# Horizontal was wrong for the same reason a magazine is drawn vertically:
	# a round is an object with a TOP and a BOTTOM, and its shape carries that.
	# Lying on its side next to a horizontal magazine it read as another bar in
	# a row of bars 鈥?which is exactly what "this indication is unclear" meant.
	# Standing it up gives the cluster one object that is obviously not a gauge.
	#
	# Where the height comes from: the glyph is 9px tall against a 7px band, so
	# it stands proud of the rail. That asymmetry is deliberate 鈥?it is the only
	# mark in the bottom row that breaks the band, which is what makes the eye
	# locate it first.
	#
	# The animation scale is derived from WEAPON_CD:
	#   MG    0.105 s -> a sharp kick, over before the next round
	#   BASE  0.19  s -> a visible kick
	#   BOMB  0.38  s -> the round takes a beat to reseat
	# A fixed animation duration would read as "jammed" on MG (never settles)
	# and as "nothing happening" on BOMB.
	# NO progress rail. A second vertical bar next to a five-cell magazine next
	# to a ring was the thing that made the cluster read as redundant: three
	# marks in a row all answering "when", where only one is needed. The round
	# alone carries the cycle, through its kick.
	#
	# The kick has to do ALL the work now, so it is amplified and given a
	# vertical component as well: the round drops back into the chamber and
	# re-seats. That is a motion, not a gauge, which is exactly what was asked
	# for 鈥?and a motion is easier to read at the edge of vision than a fill.
	var kick := (1.0 - ready) * clampf(cd_len / 0.10, 1.0, 4.0) * 2.0
	var recoil := floorf(kick * 0.45)

	var body_a := 0.28 if reloading else 1.0
	var icol := Color(INK.r, INK.g, INK.b, body_a)
	var pcol := Color(PAPER.r, PAPER.g, PAPER.b, 0.55 + 0.45 * body_a)

	# The round: 5 wide, 7 tall 鈥?the SAME height as the cells, sitting on the
	# SAME baseline.
	#
	# It used to be 9px and hang 4px below the row. That is what "灏勫嚮鎸囩ず鍋忕浜?
	# meant: measured, the cells ended on row 195 and the round on 199, so the
	# one mark that exists to be found at a glance was the one mark not on the
	# line. It now occupies exactly the cells' band.
	#
	# The kick moves it BACK (left) and DOWN (into the chamber) together, so the
	# motion still has a direction that matches firing, but the vertical part is
	# capped at 1px: any more and the glyph leaves the shared band mid-animation,
	# which is precisely the drift that was just fixed. The recoil therefore
	# reads mostly horizontal and is amplified to compensate.
	# VERTICAL ONLY. No horizontal component at all.
	#
	# The kick used to push the round left as well, on the reasoning that a
	# cartridge travels backwards into the breech. The problem is that a glyph
	# that slides sideways in a row of three fixed marks reads as MISALIGNMENT
	# rather than as motion 鈥?the eye cannot tell "it moved" from "it was drawn
	# in the wrong place", and with the magazine right beside it the sideways
	# travel kept re-opening the alignment question this pass just closed.
	#
	# So the whole animation is a vertical twitch: the round is flicked up out of
	# the chamber on the shot and settles back down. That is the axis with no
	# neighbour to be compared against, so the motion can never look like drift.
	var bullet_h := 7.0
	var by0 := base_y - bullet_h + 1.0 - floorf(kick * 1.1)
	var bx0 := cx + 3.0
	# Tip.
	draw_rect(Rect2(bx0 + 2.0, by0, 1.0, 1.0), icol, true)
	# Ogive: two steps, 3px then full width.
	draw_rect(Rect2(bx0 + 1.0, by0 + 1.0, 3.0, 1.0), icol, true)
	# Shoulders and body.
	draw_rect(Rect2(bx0, by0 + 2.0, 5.0, 3.0), icol, true)
	# Case crimp: one row at MUTE, NOT paper.
	#
	# It was drawn in PAPER, on the theory that a light line against ink reads as
	# a seam. On the cream field the paper line is the SAME colour as the
	# background, so it did not read as a seam 鈥?it read as a GAP, and the case
	# below it looked like a detached bar floating under the bullet. MUTE is
	# darker than the paper behind the glyph, so the line is visible as a line
	# and the case stays attached to the body.
	draw_rect(Rect2(bx0, by0 + 5.0, 5.0, 1.0), Color(MUTE.r, MUTE.g, MUTE.b, body_a), true)
	# Case.
	draw_rect(Rect2(bx0, by0 + 6.0, 5.0, 1.0), icol, true)
	# Rim light: the left column at paper alpha. This is the pseudo-3D cue 鈥?a
	# cylinder lit from the upper left, drawn in one line instead of a gradient,
	# which is all a two-tone palette can afford.
	draw_rect(Rect2(bx0, by0 + 2.0, 1.0, 3.0),
		Color(PAPER.r, PAPER.g, PAPER.b, 0.26 * body_a), true)
	# Muzzle flash on the tip: 1px that appears only while the round is flying
	# out of the barrel. At 5px wide this is the only animation channel with room
	# left, so the kick and the flash together carry the whole cycle.
	if ready < 0.34:
		var fa := (0.34 - ready) / 0.34
		draw_rect(Rect2(bx0 + 2.0, by0 - 1.0 - floorf(fa * 2.0), 1.0, 1.0),
			Color(INK.r, INK.g, INK.b, 0.30 + fa * 0.60), true)

	# ---- B. magazine -----------------------------------------------------
	# Five cells, ON THE INK GAUGE'S BASELINE.
	#
	# Alignment was measured, not guessed: the gauge spans rows 191-195, the
	# cells were at 190-196, the round at 191-199 and the ring at 188-199. Four
	# objects, four different vertical extents, no shared edge 鈥?which is what
	# "鍋忕浜? was describing. Everything in this row now shares ONE baseline:
	# the gauge's bottom edge, `rail_b - HUD_INSET + gh - 1`.
	#
	# Heights are also normalised. All three marks are 7px tall and hang from
	# `cell_top`, which is derived from the shared baseline declared above 鈥?see
	# "ONE baseline for the whole cluster".
	var mx0 := cx + 13.0
	var mag_max: int = int(WEAPON_MAG[weapon])
	var units := float(mag[weapon]) / float(maxf(1.0, float(mag_max))) * 5.0
	for i in 5:
		var cell := Rect2(mx0 + float(i) * 5.0, cell_top, 4.0, cell_h)
		var sub := clampf(units - float(i), 0.0, 1.0)
		if sub >= 1.0:
			draw_rect(cell, INK, true)
		elif sub > 0.0:
			Ink.hatch(self, Rect2(cell.position.x, cell.position.y,
				maxf(1.0, floorf(cell.size.x * sub)), cell.size.y), 2.0, 45.0, 1.0)
			Ink.rect(self, cell, 1.0, 0.0, Color(INK.r, INK.g, INK.b, 0.24))
		else:
			Ink.rect(self, cell, 1.0, 0.0, Color(INK.r, INK.g, INK.b, 0.13))
	# Empty magazine: the CELLS themselves fade, no stroked box around them.
	#
	# There used to be an `Ink.rect` drawn around the whole five-cell group,
	# blinking. That box was the "妗? in the report, and it was wrong for a
	# concrete reason: a stroked rectangle round a group of filled cells reads as
	# a CONTAINER, and a container implies the cells are its contents rather than
	# five independent rounds. On an empty magazine it also became the loudest
	# object in the HUD 鈥?a blinking hollow box is a much bigger gesture than the
	# state deserves.
	#
	# Dropping the alpha of the empty cells says "nothing loaded" with the same
	# marks that say "loaded", so the strip never changes shape.
	if mag[weapon] <= 0 and not reloading:
		var bl := absf(sin(t * 9.0)) * 0.55
		for i in 5:
			var cell := Rect2(mx0 + float(i) * 5.0, cell_top, 4.0, cell_h)
			Ink.rect(self, cell, 1.0, 0.0, Color(INK.r, INK.g, INK.b, 0.10 + bl * 0.30))

	# Reservoir: a hairline UNDER the cells, sharing the same bottom alignment.
	#
	# The denominator is ONE PICKUP's worth, not a ceiling, because stock now
	# stacks without bound. A bar that fills against an imagined maximum would
	# be pinned full after three pickups and stop carrying information; against
	# "what one more cache would give me" it stays a budget the player can read.
	var rmax: int = int(WEAPON_RESERVE[weapon])
	if rmax > 0:
		var rf := clampf(float(stock[weapon]) / float(rmax), 0.0, 1.0)
		var ry := base_y + 2.0
		draw_rect(Rect2(mx0, ry, 21.0, 1.0), Color(INK.r, INK.g, INK.b, 0.12), true)
		draw_rect(Rect2(mx0, ry, floorf(21.0 * rf), 1.0),
			Color(INK.r, INK.g, INK.b, 0.42), true)

	# ---- C. reload ring --------------------------------------------------
	# Both states are the SAME drawing at different values, so there is nothing
	# to snap between:
	#   radius  ready 5.0, contracts to 4.1 at the start of a reload and opens
	#           back out 鈥?the ring physically closes and refills
	#   dots    16 dots, unlit at low alpha; a reload lights them one by one,
	#           so "ready" is simply "all 16 lit"
	#   core    grows from nothing, so the first frame of a reload is visibly
	#           different from the last frame of ready
	#
	# Radius 5.0 鈥?its original size, restored.
	#
	# It was briefly shrunk to 3.0 on the assumption that "the box is too big"
	# referred to this ring. It did not: the ring was fine, and shrinking it to
	# the height of the cells made the reload progress unreadable 鈥?16 dots on a
	# 3px circle step 1.18px apart and the arc reads as a texture, not a sweep.
	#
	# 5.0 is also the radius where the dot pitch is 1.96px, so consecutive dots
	# land on clearly distinct pixels and the closing sweep is countable. Left at
	# its original size and CENTRED on the cells' band rather than on the old
	# `top`, so it is still aligned with the rest of the row.
	var rx := mx0 + 21.0 + 14.0
	var ry2 := cell_top + cell_h * 0.5
	var prog := clampf(reload_t / maxf(reload_len, 0.001), 0.0, 1.0) if reloading else 1.0
	var rr := 5.0 - (1.0 - prog) * 0.9
	var segs := 16
	var lit_segs := int(round(prog * float(segs)))
	for i in segs:
		var a := -PI * 0.5 + TAU * float(i) / float(segs)
		var q := Vector2(floorf(rx + cos(a) * rr), floorf(ry2 + sin(a) * rr))
		if i < lit_segs:
			draw_rect(Rect2(q.x, q.y, 1.0, 1.0), INK, true)
		else:
			draw_rect(Rect2(q.x, q.y, 1.0, 1.0), Color(INK.r, INK.g, INK.b, 0.10), true)
	# Core: the interior fill that carries progress when the hairline arc alone
	# is too thin to read from the corner of the eye.
	if prog < 1.0:
		if prog > 0.08:
			Ink.disc(self, Vector2(rx, ry2), 2.6 * prog, Color(INK.r, INK.g, INK.b, 0.55))
	else:
		draw_rect(Rect2(floorf(rx), floorf(ry2), 1.0, 1.0),
			Color(INK.r, INK.g, INK.b, 0.45 + absf(sin(t * 3.0)) * 0.10), true)

	# Tier letter: right of the ring, on the cells' baseline.
	# Only for specials 鈥?the base gun has no name to announce, and a glyph that
	# always reads the same becomes furniture the eye stops seeing.
	if weapon != WEAPON_BASE:
		var gl: String = WEAPON_GLYPH[weapon]
		Ink.text(self, Vector2(rx + 6.0, cell_top + 1.0), gl, INK, 1.0)

	# ---- 6. loop count: right end of the bottom rail --------------------
	# Same baseline, same tick length, growing leftward from the rail's turn so
	# it can never collide with the gun cluster however high the loop count
	# gets.
	for i in mini(loop_n - 1, 8):
		var x := rail_r - HUD_STEP - float(i) * HUD_STEP
		draw_rect(Rect2(x, rail_b - HUD_INSET, 1.0, gh), INK, true)


# One L-shaped bracket at a corner, `sx`/`sy` pointing along the two arms.
#
# Drawn as two 1px runs that meet exactly, so the corner is one continuous
# hairline. Each arm is inset by 0 (the corner is shared) and the arms are drawn
# from the corner outward, which keeps the joint pixel solid instead of leaving
# a hole where two rectangles would overlap.
func _corner_bracket(c: Vector2, sx: float, sy: float, arm: float, col: Color) -> void:
	var x0 := floorf(c.x) if sx > 0.0 else floorf(c.x - arm)
	var y0 := floorf(c.y) if sy > 0.0 else floorf(c.y - arm)
	# horizontal arm
	draw_rect(Rect2(x0, floorf(c.y), arm, 1.0), col, true)
	# vertical arm
	draw_rect(Rect2(floorf(c.x), y0, 1.0, arm), col, true)


func _vert(x: float, y: float, h: float, col: Color) -> void:
	draw_rect(Rect2(floorf(x), floorf(y), 1.0, floorf(h)), col, true)


# ---- pause layer -------------------------------------------------------------
#
# Drawn last, with the shake transform reset to identity first: a paused screen
# must not inherit a camera kick from the frame the pause landed on.
#
# Two vertical bars, the universal pause glyph, drawn as ink hairlines rather
# than as a filled shape so it speaks the same vocabulary as the HUD. The veil
# is paper at low alpha 鈥?the world stays visible underneath, because the point
# of the pause is that the run is still there waiting.
func draw_pause_layer() -> void:
	if not paused:
		return
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_rect(Rect2(0.0, 0.0, W, H),
		Color(PAPER.r, PAPER.g, PAPER.b, 0.55), true)
	# Two bars at the centre, 5px wide, 22px tall, 7px apart.
	var bw := 5.0
	var bh := 22.0
	var gap := 7.0
	var cx0 := W * 0.5 - (bw + gap * 0.5)
	var cy0 := H * 0.5 - bh * 0.5
	for i in 2:
		var bx := floorf(cx0 + float(i) * (bw + gap))
		Ink.rect(self, Rect2(bx, floorf(cy0), bw, bh), 1.0, 0.0, INK)
	# A slow pulse on the outline, so the pause reads as "waiting" rather than
	# as a still frame of the game that has stopped responding.
	var pulse := 0.30 + absf(sin(Time.get_ticks_msec() * 0.0016)) * 0.30
	for i in 2:
		var bx := floorf(cx0 + float(i) * (bw + gap))
		Ink.rect(self, Rect2(bx, floorf(cy0), bw, bh), 1.0, 0.0,
			Color(INK.r, INK.g, INK.b, pulse))


func draw_flash() -> void:
	if flash > 0.0:
		draw_rect(Rect2(0.0, 0.0, W, H), Color(PAPER.r, PAPER.g, PAPER.b, floorf(flash * 0.70 * 8.0) / 8.0), true)


func draw_overlay() -> void:
	if not dead:
		return
	var a := clampf(dead_t * 1.1, 0.0, 1.0)
	draw_rect(Rect2(0.0, 0.0, W, H), Color(PAPER.r, PAPER.g, PAPER.b, floorf(a * 0.55 * 8.0) / 8.0), true)
	var c := player
	# Ink blot: stepped pixel rings, no antialiasing.
	for i in 4:
		var rr := 6.0 + dead_t * (19.0 + float(i) * 11.0)
		var fade := clampf(1.0 - dead_t * 0.52, 0.0, 1.0) * (1.0 - float(i) * 0.2)
		if fade > 0.0:
			Ink.ring(self, c, rr, 1.0, Color(INK.r, INK.g, INK.b, 0.50 * fade))
	Ink.disc(self, c, 4.0 + sin(dead_t * 6.0) * 0.6, Color(INK.r, INK.g, INK.b, minf(1.0, dead_t * 1.4) * 0.90))
	# Wordless restart cue: a blinking hollow ring at centre.
	if dead_t > 1.8:
		var pulse := 0.30 + sin(dead_t * 4.0) * 0.25
		Ink.ring(self, Vector2(W * 0.5, H * 0.5), 9.0, 1.0, Color(INK.r, INK.g, INK.b, pulse))
		Ink.ring(self, Vector2(W * 0.5, H * 0.5), 10.0, 1.0, Color(INK.r, INK.g, INK.b, pulse * 0.4))
