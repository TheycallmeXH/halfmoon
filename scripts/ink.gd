# Halfmoon — ink primitives, pixel edition.
#
# The play field renders at 384x216 and is upscaled 3x with nearest filtering,
# so every helper here snaps to whole pixels and refuses smooth curves.
# Circles become octagonal blobs, arcs become dot runs, and the hand-drawn
# "boil" wobble is quantised so it never produces half-pixel fuzz.
class_name Ink
extends RefCounted

# Deliberately desaturated: cream paper, cold charcoal ink, one warm grey.
const PAPER := Color(0.925, 0.910, 0.851)   # #ECE8D9
const INK := Color(0.129, 0.129, 0.118)     # #21211E
const MUTE := Color(0.702, 0.686, 0.635)    # #B3AFA2
const SOOT := Color(0.396, 0.388, 0.353)    # #65635A

# 16-step ordinal ramp between paper and ink. Dithering picks a step, drawing
# a flat colour picks a step: nothing is anti-aliased, everything is banded.
static func px(v: float) -> float:
	return floorf(v)


# Quantised hand-drawn boil. 8 fps, whole-pixel offsets only.
static func now() -> float:
	return floorf(float(Time.get_ticks_msec()) * 0.032) * 0.125


static func wob(p: Vector2, ph: float, amp: float) -> Vector2:
	var tt := now()
	var dx := floorf(sin(tt * 4.7 + ph) * amp)
	var dy := floorf(cos(tt * 3.9 + ph * 1.7) * amp)
	return Vector2(px(p.x + dx), px(p.y + dy))


# One ink stroke: a 1px ghost offset by a pixel, then the main run.
# Width is snapped to whole pixels so nothing lands between the raster.
static func stroke(ci: CanvasItem, a: Vector2, b: Vector2, w := 1.0, ph := 0.0, amp := 1.0, col := INK) -> void:
	var a1 := wob(a, ph, amp)
	var b1 := wob(b, ph + 1.4, amp)
	var a2 := wob(a, ph + 3.1, amp * 0.55) + Vector2(1.0, -1.0)
	var b2 := wob(b, ph + 4.5, amp * 0.55) + Vector2(-1.0, 1.0)
	var ghost := col
	ghost.a *= 0.30
	ci.draw_line(a2, b2, ghost, maxf(1.0, floorf(w * 0.5)), false)
	ci.draw_line(a1, b1, col, maxf(1.0, floorf(w)), false)


static func poly(ci: CanvasItem, pts: PackedVector2Array, w := 1.0, closed := true, ph := 0.0, amp := 1.0, col := INK) -> void:
	var n := pts.size()
	if n < 2:
		return
	var last := n if closed else n - 1
	for i in last:
		stroke(ci, pts[i], pts[(i + 1) % n], w, ph + float(i) * 0.7, amp, col)


static func rect(ci: CanvasItem, r: Rect2, w := 1.0, ph := 0.0, col := INK) -> void:
	var x0 := px(r.position.x)
	var y0 := px(r.position.y)
	var x1 := px(r.end.x) - 1.0
	var y1 := px(r.end.y) - 1.0
	if x1 < x0 or y1 < y0:
		return
	var t := maxf(1.0, floorf(w))
	ci.draw_rect(Rect2(x0, y0, x1 - x0 + 1.0, t), col, true)
	ci.draw_rect(Rect2(x0, y1, x1 - x0 + 1.0, t), col, true)
	ci.draw_rect(Rect2(x0, y0, t, y1 - y0 + 1.0), col, true)
	ci.draw_rect(Rect2(x1 - t + 1.0, y0, t, y1 - y0 + 1.0), col, true)


static func fill_rect(ci: CanvasItem, r: Rect2, col: Color) -> void:
	var x0 := px(r.position.x)
	var y0 := px(r.position.y)
	ci.draw_rect(Rect2(x0, y0, floorf(r.size.x), floorf(r.size.y)), col, true)


static func fill_poly(ci: CanvasItem, pts: PackedVector2Array, col: Color) -> void:
	if pts.size() >= 3:
		ci.draw_colored_polygon(pts, col)


# A crisp one-pixel rim with two faint outer steps, following the actual hull.
# Draw the body afterwards so the wash never covers its interior detail.
static func paper_edge(ci: CanvasItem, pts: PackedVector2Array) -> void:
	if pts.size() < 3:
		return
	for band in [Vector2(3.0, 0.045), Vector2(2.0, 0.14)]:
		for contour in Geometry2D.offset_polygon(pts, band.x, Geometry2D.JOIN_ROUND):
			var pixels := PackedVector2Array()
			for point in contour:
				pixels.append(point.floor())
			ci.draw_colored_polygon(pixels, Color(PAPER, band.y))
	for offset in [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1),
			Vector2(-1, 0), Vector2(1, 0), Vector2(-1, 1), Vector2(0, 1), Vector2(1, 1)]:
		var shifted := PackedVector2Array()
		for point in pts:
			shifted.append(point + offset)
		ci.draw_colored_polygon(shifted, PAPER)


static func dot(ci: CanvasItem, p: Vector2, r: float, col := INK) -> void:
	ci.draw_rect(Rect2(px(p.x - r), px(p.y - r), maxf(1.0, floorf(r * 2.0)), maxf(1.0, floorf(r * 2.0))), col, true)


# Pixel disc: per-row span from a true circle test, corners cut once so the
# silhouette reads as a blob instead of a staircase block.
static func disc(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var cx := int(px(c.x))
	var cy := int(px(c.y))
	var rr := floorf(r)
	var y := int(-rr)
	while y <= int(rr):
		var fy := float(y)
		var half := floorf(sqrt(maxf(0.0, rr * rr - fy * fy)))
		if absf(fy) > rr - 1.0:
			half = floorf(half * 0.62)
		if half >= 0.0:
			ci.draw_rect(Rect2(float(cx - int(half)), float(cy + y), float(int(half) * 2 + 1), 1.0), col, true)
		y += 1


# Pixel ring — a true circle outline, drawn per scanline.
#
# The previous version drew it as four straight runs (top/bottom/left/right)
# linked by one-pixel diagonal steps. At the sizes this game uses, those runs
# came out as eight long straight spokes radiating from the disc, which looked
# like a mechanical antenna array rather than a drawn circle. This scanline form
# has no straight segments at all: each row contributes the two pixels where the
# circle crosses it, so the outline is continuous and curved everywhere.
static func ring(ci: CanvasItem, c: Vector2, r: float, w := 1.0, col := INK) -> void:
	var cx := int(px(c.x))
	var cy := int(px(c.y))
	var rr := floorf(r)
	var t := int(maxf(1.0, floorf(w)))
	if rr < 1.0:
		return
	# Outer edge per row, then carve the inner radius out of it. Using the same
	# radius test for both keeps the ring an even 1px all the way round.
	var y := -int(rr)
	while y <= int(rr):
		var fy := float(y)
		var outer := floorf(sqrt(maxf(0.0, rr * rr - fy * fy)))
		var inner := floorf(sqrt(maxf(0.0, (rr - float(t)) * (rr - float(t)) - fy * fy)))
		if inner >= outer:
			# Near the poles the annulus is thinner than a pixel: emit the two
			# edge pixels only, so the ring never grows a cap.
			inner = outer - 1.0
		var ox := int(outer)
		var ix := int(inner)
		ci.draw_rect(Rect2(float(cx - ox), float(cy + y), float(ox - ix + 1), float(t)), col, true)
		ci.draw_rect(Rect2(float(cx + ix + 1), float(cy + y), float(ox - ix + 1), float(t)), col, true)
		y += 1


static func dashed(ci: CanvasItem, a: Vector2, b: Vector2, w := 1.0, phase := 0.0, dash := 3.0, col := INK) -> void:
	var d := b - a
	var ln := floorf(d.length())
	if ln < 1.0:
		return
	var dir := d / d.length()
	var t := fposmod(phase, dash * 2.0)
	var t_w := maxf(1.0, floorf(w))
	while t < ln:
		var e := minf(t + dash, ln)
		var q0 := a + dir * t
		var q1 := a + dir * e
		ci.draw_line(Vector2(px(q0.x), px(q0.y)), Vector2(px(q1.x), px(q1.y)), col, t_w, false)
		t += dash * 2.0


# Ordered dither fill: the only way a colour ramp appears in this style.
static func dither_rect(ci: CanvasItem, r: Rect2, col: Color, level: int) -> void:
	var x0 := int(px(r.position.x))
	var y0 := int(px(r.position.y))
	var x1 := int(px(r.position.x + r.size.x))
	var y1 := int(px(r.position.y + r.size.y))
	for y in range(y0, y1):
		for x in range(x0, x1):
			# 4x4 Bayer matrix, thresholds at 4 / 8 / 12 of 16.
			var bx := (x & 3)
			var by := (y & 3)
			var rank := int(BAYER[by * 4 + bx])
			if rank < level:
				ci.draw_rect(Rect2(x, y, 1.0, 1.0), col, true)


const BAYER := [
	0, 8, 2, 10,
	12, 4, 14, 6,
	3, 11, 1, 9,
	15, 7, 13, 5,
]


# Hatch fill, snapped to a pixel lattice. Used for the ink gauge and corners.
static func hatch(ci: CanvasItem, r: Rect2, step := 4.0, ang := 45.0, w := 1.0, col := INK) -> void:
	if r.size.x <= 1.0 or r.size.y <= 1.0:
		return
	var a := deg_to_rad(ang)
	var dir := Vector2(cos(a), sin(a))
	var nrm := Vector2(-dir.y, dir.x)
	var c := r.get_center()
	var rad := r.size.length()
	var k := -rad
	while k <= rad:
		var p0 := c + nrm * k - dir * rad
		var p1 := c + nrm * k + dir * rad
		var seg := _clip(p0, p1, r)
		if seg.size() == 2:
			var q0 := Vector2(px(seg[0].x), px(seg[0].y))
			var q1 := Vector2(px(seg[1].x), px(seg[1].y))
			ci.draw_line(q0, q1, col, maxf(1.0, floorf(w)), false)
		k += step


static func _clip(p0: Vector2, p1: Vector2, r: Rect2) -> PackedVector2Array:
	var t0 := 0.0
	var t1 := 1.0
	var dx := p1.x - p0.x
	var dy := p1.y - p0.y
	var edges := [
		[-dx, p0.x - r.position.x],
		[dx, r.end.x - p0.x],
		[-dy, p0.y - r.position.y],
		[dy, r.end.y - p0.y],
	]
	for e in edges:
		var p: float = e[0]
		var q: float = e[1]
		if absf(p) < 0.0001:
			if q < 0.0:
				return PackedVector2Array()
		else:
			var tt := q / p
			if p < 0.0:
				t0 = maxf(t0, tt)
			else:
				t1 = minf(t1, tt)
	if t0 > t1:
		return PackedVector2Array()
	return PackedVector2Array([p0 + Vector2(dx, dy) * t0, p0 + Vector2(dx, dy) * t1])


# Dithered dot screen inside a disc: coarse 2px dot lattice, ordered ranks.
static func screen_dots(ci: CanvasItem, c: Vector2, r: float, step := 3.0, col := INK, level := 8) -> void:
	var rr := floorf(r)
	var cy := int(px(c.y))
	var cx := int(px(c.x))
	var st := maxi(1, int(step))
	var y := -int(rr)
	while y <= int(rr):
		var x := -int(rr)
		while x <= int(rr):
			if Vector2(float(x), float(y)).length() <= rr - 1.0:
				var bx := (cx + x) & 3
				var by := (cy + y) & 3
				if int(BAYER[by * 4 + bx]) < level:
					ci.draw_rect(Rect2(float(cx + x), float(cy + y), 1.0, 1.0), col, true)
			x += st
		y += st


# Dot screen with a rotating lattice. A disc whose halftone rotates reads as a
# turning body; a fixed lattice reads as a printed sticker.
static func screen_dots_rot(ci: CanvasItem, c: Vector2, r: float, step := 3.0, col := INK, level := 8, spin := 0.0) -> void:
	var rr := floorf(r)
	if rr < 1.0:
		return
	var inner_sq := (rr - 1.0) * (rr - 1.0)
	var cy := int(px(c.y))
	var cx := int(px(c.x))
	var st := maxi(1, int(step))
	var cs := cos(spin)
	var sn := sin(spin)
	var half := int(rr)
	var gy := -half
	while gy <= half:
		var gx := -half
		while gx <= half:
			# Rotate the lattice lookup, not the sample point, so the dots keep
			# their 1px size and never smear.
			# Rotation preserves radius; reject outside samples before rotating.
			if float(gx * gx + gy * gy) <= inner_sq:
				var rx := float(gx) * cs - float(gy) * sn
				var ry := float(gx) * sn + float(gy) * cs
				var lx := int(roundf(rx))
				var ly := int(roundf(ry))
				var bx := (lx + 4 * 1024) & 3
				var by := (ly + 4 * 1024) & 3
				if int(BAYER[by * 4 + bx]) < level:
					ci.draw_rect(Rect2(float(cx + gx), float(cy + gy), 1.0, 1.0), col, true)
			gx += st
		gy += st


# Tally marks in a 1px grid: groups of four crossed by a slash.
static func tally(ci: CanvasItem, origin: Vector2, count: int, h := 10.0, gap := 3.0, col := INK) -> void:
	var groups := count / 5
	var rest := count % 5
	var ox := px(origin.x)
	var oy := px(origin.y)
	for g in groups:
		var gx := ox + float(g) * (gap * 4.0 + 8.0)
		for i in 4:
			ci.draw_rect(Rect2(gx + float(i) * gap, oy - h, 1.0, h + 1.0), col, true)
		# crossing slash, stepped 1px diagonally
		var steps := int(floorf(h))
		for s in steps:
			ci.draw_rect(Rect2(gx - 2.0 + float(s) * 0.55, oy - 1.0 - float(s), 1.0, 1.0), col, true)
	var ox2 := ox + float(groups) * (gap * 4.0 + 8.0)
	for i in rest:
		ci.draw_rect(Rect2(ox2 + float(i) * gap, oy - h, 1.0, h + 1.0), col, true)


static func tally_width(count: int, gap := 3.0) -> float:
	var groups := count / 5
	var rest := count % 5
	return float(groups) * (gap * 4.0 + 8.0) + float(rest) * gap


# ---------------------------------------------------------------------------
# Pixel font — 5x7 bitmap glyphs, drawn as hard 1px rectangles.
#
# Why a bitmap table instead of a TTF: the whole game renders at 384x216 and
# upscales by an integer factor with `TEXTURE_FILTER_NEAREST`. Any engine-drawn
# text would be rasterised at the source resolution and then blown up with
# whatever hinting the font carries — stroke weights would come out uneven and
# the baseline would land off the pixel grid. A hand-built table guarantees
# every stem is exactly one source pixel, which is the only stroke weight this
# plate uses anywhere else.
#
# Glyphs are stored as 7 rows of 5 bits (0b10000 = leftmost pixel). Rows are
# drawn top-down, so an uppercase letter occupying rows 0..6 sits 7px tall and
# a digit using rows 0..6 does the same.
#
# Only the characters the HUD needs are present. Adding a glyph is one line;
# adding an unknown character draws nothing rather than failing.
const GLYPH_W := 5
const GLYPH_H := 7

static func glyph_rows(ch: String) -> Array[int]:
	match ch:
		"K":
			return [0b10010, 0b10100, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001]
		"i":
			return [0b00100, 0b00000, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100]
		"l":
			return [0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100]
		"L":
			return [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111]
		# The weapon-tier letters. B / G / S were MISSING until now, and the
		# failure was perfectly silent: `glyph_rows` returns [] for an unknown
		# character, `text()` advances the cursor and draws nothing, so a BOMB
		# cache carried a blank plate. Only LASER's L ever rendered — which hid
		# the bug completely, because the one letter a tester is most likely to
		# pick up by chance is the one that works.
		"B":
			return [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110]
		"G":
			return [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110]
		"S":
			return [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110]
		# The three letters added with FLAK / RAIL / SWARM.
		#
		# Same trap as B / G / S: an unknown character returns [], `text()`
		# advances the cursor and draws NOTHING, so a missing tier letter is a
		# blank plate, not an error. `glyph_ok()` exists so a probe can assert
		# coverage instead of trusting the eye to notice an absence.
		#
		# F: top bar, stem, mid bar. Two horizontals is the most a 5px cell
		# affords; a third would close the counter and turn it into an E.
		"F":
			return [0b11110, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000, 0b10000]
		# R: bar, both sides to the waist, closed bowl, then the leg stepping
		# right. The leg MUST step -- a straight stem under a closed bowl reads
		# as a P at this size.
		"R":
			return [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001]
		# W: two stems at the top, THREE at the bottom. The third stem appearing
		# only in the lower half is the whole difference between a W and a
		# pair of parallel uprights; a 5px cell cannot afford the diagonal steps
		# a larger alphabet uses, so the count of verticals carries the letter.
		"W":
			return [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b10101]
		"0":
			return [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110]
		"1":
			return [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110]
		"2":
			return [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111]
		"3":
			return [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110]
		"4":
			return [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010]
		"5":
			return [0b11111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b01110]
		"6":
			return [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110]
		"7":
			return [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000]
		"8":
			return [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110]
		"9":
			return [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b00100]
		":":
			return [0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000, 0b00000]
		" ":
			return [0, 0, 0, 0, 0, 0, 0]
		_:
			return []


# Width of a string in source pixels, 1px gap between glyphs.
static func text_width(s: String, scale := 1.0) -> float:
	if s.length() == 0:
		return 0.0
	return (float(s.length()) * float(GLYPH_W) + float(s.length() - 1)) * scale


# Coverage test for one character, used by the glyph probe.
#
# Returns the number of non-empty rows, or -1 when the character has no entry
# at all. A caller distinguishes "missing glyph" (no entry) from "entry that
# happens to have blank rows" (a legal space), which a boolean cannot.
static func glyph_ok(ch: String) -> int:
	if ch == " ":
		return GLYPH_H
	var rows := glyph_rows(ch)
	if rows.is_empty():
		return -1
	var n := 0
	for r in rows:
		if r != 0:
			n += 1
	return n


# Draw `s` with its LEFT edge at origin.x and its TOP edge at origin.y.
#
# Naming the anchor explicitly is deliberate: every caller in this project
# positions readouts against a rail or a baseline, and a function that centres
# its own text would force each caller to subtract half the width, which then
# drifts as the digit count grows.
static func text(ci: CanvasItem, origin: Vector2, s: String, col := INK, scale := 1.0) -> void:
	var ox := px(origin.x)
	var oy := px(origin.y)
	var cursor := 0.0
	for idx in s.length():
		var rows := glyph_rows(s[idx])
		if rows.is_empty():
			cursor += float(GLYPH_W + 1) * scale
			continue
		for gy in GLYPH_H:
			var bits: int = rows[gy]
			if bits == 0:
				continue
			# Walk the 5 bits of this row and emit one rectangle per run of set
			# pixels rather than one per pixel. Fewer draw_rect calls, and the
			# runs stay whole pixels, which is what keeps a scaled glyph from
			# developing seams between neighbouring cells.
			var run_start := -1
			for gx in range(0, GLYPH_W + 1):
				var on: bool = gx < GLYPH_W and ((bits >> (GLYPH_W - 1 - gx)) & 1) == 1
				if on and run_start < 0:
					run_start = gx
				elif not on and run_start >= 0:
					ci.draw_rect(Rect2(ox + cursor + float(run_start) * scale,
						oy + float(gy) * scale,
						float(gx - run_start) * scale, scale), col, true)
					run_start = -1
		cursor += float(GLYPH_W + 1) * scale


# Heart glyph, 7x6, drawn at a 1px origin.
#
# Solid form: filled silhouette. Hollow form: 1px outline only, which is what a
# spent life looks like. Two forms share the same silhouette so a damaged row
# still reads as "these were lives" instead of three unrelated icons.
#
# The dip in the top centre is the whole reason this reads as a heart at this
# size: a plain diamond or rounded square would be cheaper and would say
# nothing.
const HEART_ROWS := [
	0b0110110,
	0b1111111,
	0b1111111,
	0b0111110,
	0b0011100,
	0b0001000,
]

static func heart(ci: CanvasItem, origin: Vector2, filled: bool, col := INK, scale := 1.0) -> void:
	var ox := px(origin.x)
	var oy := px(origin.y)
	var nrows := HEART_ROWS.size()
	for gy in nrows:
		var bits: int = HEART_ROWS[gy]
		if filled:
			# Filled: one rectangle per run of set pixels.
			var run_start := -1
			for gx in range(0, 8):
				var on: bool = gx < 7 and ((bits >> (6 - gx)) & 1) == 1
				if on and run_start < 0:
					run_start = gx
				elif not on and run_start >= 0:
					ci.draw_rect(Rect2(ox + float(run_start) * scale, oy + float(gy) * scale,
						float(gx - run_start) * scale, scale), col, true)
					run_start = -1
		else:
			# Hollow: keep only pixels with a missing 4-neighbour, i.e. the
			# silhouette, and drop the interior.
			for gx in 7:
				if ((bits >> (6 - gx)) & 1) != 1:
					continue
				var has_left: bool = gx > 0 and ((bits >> (7 - gx)) & 1) == 1
				var has_right: bool = gx < 6 and ((bits >> (5 - gx)) & 1) == 1
				var has_up: bool = gy > 0 and (((HEART_ROWS[gy - 1] as int) >> (6 - gx)) & 1) == 1
				var has_down: bool = gy < nrows - 1 and (((HEART_ROWS[gy + 1] as int) >> (6 - gx)) & 1) == 1
				if not (has_left and has_right and has_up and has_down):
					ci.draw_rect(Rect2(ox + float(gx) * scale, oy + float(gy) * scale,
						scale, scale), col, true)
