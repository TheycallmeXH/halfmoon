# Halfmoon highlight probe — diagnostic only, armed by HALFMOON_HILITE.
#
# Paints the SAME 1.0-white core twice in one frame: once on the paper field,
# once on the ink moon. Nothing else differs. If the highlight behaves the
# same on both grounds the final frame's halo profile is identical; if it
# differs, the difference is caused by the ground luminance alone and the
# bloom chain is adding absolutes into a base that cannot absorb them.
#
# This is a measurement fixture, not content — it draws over the game and is
# never mounted unless the env var is set.
extends Node2D

const PAPER_CORE := Vector2(150.0, 46.0)
# A calm patch of the field with no enemy traffic: the rim probe needs an
# undisturbed paper sample to show whether the frame edge carries a fringe.
const MOON_CORE := Vector2(238.0, 106.0)

const CORE := Color(1.0, 1.0, 0.97)


func _ready() -> void:
	set_process(true)


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	_core(PAPER_CORE)
	_core(MOON_CORE)


# Identical geometry at both grounds: a 2px hot disc plus a 1px ring, which is
# the shape the game's bullets and engine plume actually use.
func _core(p: Vector2) -> void:
	Ink.disc(self, p, 2.0, CORE)
	Ink.ring(self, p, 3.0, 1.0, CORE)
