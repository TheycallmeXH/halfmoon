extends RefCounted

enum Kind { SHIELD, THORN, BARRAGE, MAGNET, RELOADER, CAPACITOR, PHASE, PHOENIX }
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }

const NAMES := ["Shield", "Thorn", "Barrage", "Magnet", "Quickloader",
	"Capacitor", "Phase fuse", "Phoenix core"]
const RARITIES := [Rarity.COMMON, Rarity.RARE, Rarity.EPIC, Rarity.COMMON,
	Rarity.UNCOMMON, Rarity.RARE, Rarity.EPIC, Rarity.LEGENDARY]
# Absolute chance per cache. The remaining 56% stays in the weapon pool.
const WEIGHTS := [0.16, 0.075, 0.0, 0.105, 0.10, 0.0, 0.0, 0.0]
const DURATION := 45.0
const CAPACITOR_KILLS := 12
const HUD_ORDER := [Kind.SHIELD, Kind.THORN, Kind.MAGNET, Kind.RELOADER]
const MASKS := [
	["011111110", "111111111", "111111111", "111111111", "011111110",
		"011111110", "001111100", "000111000", "000010000"],
	["000010000", "001010100", "000111000", "111111111", "001111100",
		"011010110", "010010010", "000010000", "000000000"],
	["010010010", "010010010", "010010010", "010010010", "111111111",
		"011111110", "001111100", "000111000", "000010000"],
	["011000110", "111000111", "111000111", "111000111", "111000111",
		"111000111", "011101110", "001111100", "000111000"],
	["000111000", "001111100", "011001110", "110000011", "111100111",
		"011000110", "001001100", "000111000", "000010000"],
	["000011100", "000111000", "001110000", "011111110", "000111100",
		"000111000", "001110000", "011100000", "011000000"],
	["000111000", "001000100", "010111010", "100101001", "101010101",
		"100101001", "010111010", "001000100", "000111000"],
	["100010001", "110111011", "111111111", "011111110", "001111100",
		"000111000", "001010100", "010010010", "000010000"],
]


static func roll(value: float) -> int:
	var threshold := 0.0
	for item in WEIGHTS.size():
		threshold += float(WEIGHTS[item])
		if value < threshold:
			return item
	return -1


static func _inside(mask: Array, x: int, y: int) -> bool:
	return x >= 0 and x < 9 and y >= 0 and y < 9 and mask[y][x] == "1"


static func draw_icon(canvas: CanvasItem, position: Vector2, item: int,
		fraction: float, opacity: float = 1.0, paper_edge: bool = false) -> void:
	if item < 0 or item >= MASKS.size():
		return
	var origin := position.floor()
	var mask: Array = MASKS[item]
	if paper_edge:
		for y in 9:
			for x in 9:
				if _inside(mask, x, y):
					canvas.draw_rect(Rect2(origin + Vector2(x - 1, y - 1), Vector2(3, 3)),
						Ink.PAPER)
	var cells: Array[Vector2] = []
	for y in range(8, -1, -1):
		for x in 9:
			if not _inside(mask, x, y):
				continue
			var border := not (_inside(mask, x - 1, y) and _inside(mask, x + 1, y)
				and _inside(mask, x, y - 1) and _inside(mask, x, y + 1))
			canvas.draw_rect(Rect2(origin + Vector2(x, y), Vector2.ONE),
				Color(Ink.INK, opacity * (0.42 if border else 0.06)))
			if item != Kind.SHIELD or not border:
				cells.append(Vector2(x, y))
	var filled := int(round(cells.size() * clampf(fraction, 0.0, 1.0)))
	for index in filled:
		canvas.draw_rect(Rect2(origin + cells[index], Vector2.ONE), Color(Ink.INK, opacity))


static func draw_rarity(canvas: CanvasItem, position: Vector2, item: int,
		opacity: float = 1.0) -> void:
	for pip in int(RARITIES[item]) + 1:
		canvas.draw_rect(Rect2(position.floor() + Vector2(pip * 2, 0), Vector2.ONE),
			Color(Ink.INK, opacity * 0.7))


static func draw_pickup(canvas: CanvasItem, center: Vector2, item: int) -> void:
	var p := center.floor()
	var plate := PackedVector2Array([p + Vector2(-5, -6), p + Vector2(5, -6),
		p + Vector2(6, -5), p + Vector2(6, 5), p + Vector2(5, 6),
		p + Vector2(-5, 6), p + Vector2(-6, 5), p + Vector2(-6, -5)])
	Ink.paper_edge(canvas, plate)
	canvas.draw_colored_polygon(plate, Ink.PAPER)
	canvas.draw_polyline(plate + PackedVector2Array([plate[0]]), Ink.INK, 1.0)
	draw_icon(canvas, p - Vector2(4, 5), item, 1.0)
	draw_rarity(canvas, p + Vector2(-4, 5), item)
	# Keep the established two-pixel bloom budget per pickup.
	for side in [-1, 1]:
		canvas.draw_rect(Rect2(p + Vector2(side * 7, -1), Vector2.ONE), Color(1, 1, 0.97))
