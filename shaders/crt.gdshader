// Halfmoon CRT 闂?shown on the TextureRect that displays the 384x216 raster.
//
// Two corrections went into this version:
//
// 1. GLOW DIRECTION. The old bloom masked on *brightness*, but this art is dark
//    ink on cream paper: the paper is the bright thing, so the glow was washing
//    the field while real highlights stayed flat. Bloom is now an INK BLEED 闂?//    it samples the neighbours' darkness and lets it leak outward, so strokes
//    get a soft ink halo exactly like wet ink on paper. That is the glow this
//    style wants, and it is far more visible against the cream.
//
// 2. STRENGTH. The previous pass was dialled so far down that the tube read as
//    "no effect". These values sit between the too-strong early version and the
//    invisible one: focus is soft but obvious, bleed is present but not muddy.
//
// Order is fixed: blur is the sample stage, everything else consumes it.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D src_tex : filter_nearest, repeat_disable;

// Chromatic aberration reads through a LINEAR tap of the same raster.
//
// The aberration displacement is a fraction of a source pixel 闂?that is the
// whole point, it must read as glass rather than as a channel error. But the
// main tap is `filter_nearest`, and under nearest a sub-pixel UV offset does
// not move the sample at all: the offset rounds back to the same texel and
// every channel returns identical colour. That is why raising `chroma` did
// nothing measurable for several rounds 闂?the branch was running, the
// amplitude was simply annihilated by the sampler.
//
// A second sampler bound to the same texture with linear filtering lets the
// displacement land between texels, so the fringe actually appears. The main
// image keeps nearest, so the pixel grid stays hard.
uniform sampler2D src_lin : filter_linear, repeat_disable;

uniform vec2 src_size = vec2(384.0, 216.0);
uniform float unified_noise = 0.0;

uniform float curvature : hint_range(0.0, 0.45) = 0.052;

// Focus field: sharp centre, softening outward.
// focus_radius is in half-diagonal units (0 = centre, 1 = corner), so 0.30
// means the inner 30% of the way to a corner stays perfectly sharp.
// max_kernel is the radius in SOURCE pixels. 4.2 at 384 wide reads as clearly
// out of focus at the corners; anything larger starts duplicating structure at
// a spacing the eye reads as a ghost.
uniform float defocus : hint_range(0.0, 4.0) = 2.20;
uniform float focus_radius : hint_range(0.0, 0.9) = 0.26;
uniform float focus_falloff : hint_range(0.4, 4.0) = 1.95;
uniform float max_kernel : hint_range(0.0, 8.0) = 2.6;

// Ink bleed: darkness spread outward from strokes.
uniform float bleed : hint_range(0.0, 1.0) = 0.62;
uniform float bleed_cut : hint_range(0.0, 1.0) = 0.10;
uniform float bleed_radius : hint_range(0.0, 6.0) = 1.9;

// Optical bloom, combined by the bloom chain in boot.gd into one texture:
// narrow halo + wide skirt + far field + anamorphic streak.
// `bloom_tint` warms it very slightly, which is what stops a cold glow from
// looking like a filter.
uniform sampler2D bloom_tex : filter_linear, repeat_disable;
uniform float bloom_strength : hint_range(0.0, 8.0) = 2.60;
// How much a dark ground reflects instead of absorbing the halo. 0 = the old
// plain add (grey plaque on the moon, clipped smudge on paper). 0.35 keeps the
// halo strong over paper, where it is the point, and leaves the disc with ~65%
// so the halftone dots stay readable under it.
uniform float bloom_surface : hint_range(0.0, 1.0) = 0.35;
uniform vec4 bloom_tint : source_color = vec4(1.0, 0.975, 0.930, 1.0);

// Radial chromatic aberration. Zero at the centre, growing with radius so the
// middle of the screen stays colour-clean and only the rim separates.
// `chroma` is the maximum split in source pixels at the very corner.
// Radial aberration with a dead zone: the inner 55% of the frame gets zero split,
// so only the rim fringes. Small amplitude 闂?a fraction of a source pixel.
uniform float chroma : hint_range(0.0, 6.0) = 1.60;
uniform float chroma_knee : hint_range(0.5, 6.0) = 1.9;
uniform float chroma_dbg : hint_range(0.0, 1.0) = 0.0;
// How much of the split's own colour is kept. 1.0 = the displaced channel at
// full chroma (magenta/cyan ink over the art), 0.0 = no colour at all. The
// fringe lives inside the palette only when this stays low; this is a
// saturation control, not a strength control.
uniform float chroma_saturation : hint_range(0.0, 1.0) = 0.55;
// Opacity of the fringe layer. Read as "how thick the glass is": low keeps the
// split as a suggestion on the shoulders of an edge, high turns every
// silhouette into a doubled outline.
uniform float chroma_opacity : hint_range(0.0, 1.0) = 0.46;

// Film grain, animated. Two independent requirements:
//   grain        闂?amplitude (keep tiny; this art is flat paper)
//   grain_rate   闂?how many times a second the pattern is re-seeded
// A low rate makes it breathe like film; a high rate reads as video noise.
uniform float grain : hint_range(0.0, 0.4) = 0.038;
uniform float grain_rate : hint_range(1.0, 60.0) = 12.0;
// Slow, whole-frame luminance drift. Much gentler than a per-pixel flicker:
// this is a lamp warming and cooling, not a strobing screen.
uniform float shimmer : hint_range(0.0, 0.1) = 0.018;

uniform float scanline : hint_range(0.0, 1.0) = 0.18;
uniform float flicker : hint_range(0.0, 0.1) = 0.009;
uniform float vignette : hint_range(0.0, 1.0) = 0.30;
uniform float lift : hint_range(0.0, 0.6) = 0.10;
uniform float lift_target : hint_range(0.0, 1.0) = 0.66;
uniform float exposure : hint_range(0.5, 2.0) = 1.00;
uniform float gamma : hint_range(0.4, 1.6) = 0.835;

// Set from boot.gd to the whole-number upscale actually in use, so the scan
// band is always the same fraction of one source pixel no matter the window.
uniform float upscale = 3.0;
uniform float bezel_thick = 1.4;

uniform vec4 tint : source_color = vec4(1.0, 0.995, 0.970, 1.0);
uniform vec4 bezel : source_color = vec4(0.045, 0.045, 0.043, 1.0);
// Loop palette: low-saturation paper/ink pairs, blended at the end of the
// optical chain so gameplay drawing stays palette-independent.
uniform vec4 palette_dark : source_color = vec4(0.129, 0.129, 0.118, 1.0);
uniform vec4 palette_light : source_color = vec4(0.925, 0.910, 0.851, 1.0);
uniform float palette_strength : hint_range(0.0, 1.0) = 0.52;
uniform float transition_glitch : hint_range(0.0, 1.0) = 0.0;
uniform float transition_phase : hint_range(0.0, 1.0) = 1.0;

float rnd(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 barrel(vec2 uv, float k) {
	vec2 p = uv * 2.0 - 1.0;
	p.x *= 1.0 + k * p.y * p.y;
	p.y *= 1.0 + k * p.x * p.x;
	return p * 0.5 + 0.5;
}

// Distance from the printed frame, in SOURCE PIXELS.
//
// Still measured in pixels rather than normalised extent: the frame sits 0.037
// of the height in but only 0.023 of the width, so a normalised band would
// protect the horizontal sides more than the vertical ones.
//
// Note: the frame is now a SINGLE 2px rule (see backdrop.gd), so it no longer
// needs to be exempt from the focus blur at all. This helper is kept because
// the chromatic aberration still uses it to spare the border from its split.
float border_dist(vec2 uv) {
	vec2 e = min(uv, vec2(1.0) - uv) * src_size;
	return min(e.x, e.y);
}

// Focus field: 0 at centre, 1 at the corners.
//
// Two properties matter here, and getting either wrong produces a visible ring
// in the middle of the picture rather than a gradient:
//
//   * it must be CONTINUOUS 鈥?an earlier `clamp(rr - radius)` produced a hard
//     disc where blur switched on, which read as a circular seam around the
//     centre of the screen;
//   * it must vanish smoothly 鈥?the blur amount is proportional to this value,
//     so a non-zero slope at the centre would blur the play area.
//
// Using `pow(t, 2.0)` on a normalised radius gives both: zero value AND zero
// slope at the origin, rising to 1 at the corner with no discontinuity anywhere.
//
// THE BORDER IS NOT EXEMPT ANY MORE.
//
// It was, for a while, and that exemption kept growing: 18..30 px, then
// 50..80 px, until it covered 74% of the frame height and 42% of its width.
// The blur effectively vanished from the whole picture 鈥?sharpness measured
// 0.68 at the centre versus 15..21 at the corners, i.e. the optics were
// running backwards.
//
// The reason the exemption kept growing was that the frame art was THREE rules
// 3 px apart, and a 9 px kernel turns three close parallel lines into three
// separate soft bands: genuine ghosting, fixed by hiding the border from the
// blur. That is solving the symptom. The frame is now one 2 px rule, which
// blurs into a clean soft edge, so the exemption is simply gone.
//
// The kernel is also smaller now (see max_kernel): 9.24 px was what made both
// the ghosting AND the loss of the effect necessary in the first place.
float focus_field(vec2 uv) {
	vec2 c = (uv - vec2(0.5)) * 2.0;
	float rr = length(c) / 1.4142;   // 0 centre, 1 corner
	float t = clamp((rr - focus_radius) / max(1.0 - focus_radius, 0.001), 0.0, 1.0);
	return t * t;
}

// Focus blur kernel.
//
// THE DOUBLE-IMAGE BUG: the old kernel was six taps at a radius that reached
// ~8 source pixels (centre + four axis + two diagonal). Six taps at 8px apart
// is not a blur, it is six copies of the image offset from each other 闂?which
// showed up as ghosting, worst at the corners where the radius is largest.
// Two fixes, both required:
//
//   1. Taps now sit on TWO concentric rings (8 outer + 4 inner), giving 13
//      samples. Enough overlap that neighbouring taps' footprints touch, so
//      what you get is a continuous disc of light rather than discrete copies.
//   2. The radius is capped much lower (see max_kernel). At a 384-wide raster,
//      3px of blur already reads as strongly out of focus; 8px was just
//      duplicating the artwork at a distance the eye reads as structure.
vec3 sample_src(vec2 uv, vec2 px) {
	float f = focus_field(uv);
	if (f <= 0.0) {
		return texture(src_tex, uv).rgb;
	}
	// No pow() shaping now: focus_field already returns a smooth quadratic, so
	// squaring it again would over-concentrate the blur at the very corners and
	// leave the mid-field flat.
	float amt = f * defocus * max_kernel;
	if (amt <= 0.02) {
		return texture(src_tex, uv).rgb;
	}
	vec2 o = px * amt;

	// Inner ring: 4 taps at 0.45r, weighted heavily 闂?this is what keeps the
	// core of the blur coherent and prevents the "six copies" look.
	vec3 s = texture(src_tex, uv).rgb * 0.30;
	s += texture(src_tex, uv + vec2(o.x * 0.45, 0.0)).rgb * 0.085;
	s += texture(src_tex, uv - vec2(o.x * 0.45, 0.0)).rgb * 0.085;
	s += texture(src_tex, uv + vec2(0.0, o.y * 0.45)).rgb * 0.085;
	s += texture(src_tex, uv - vec2(0.0, o.y * 0.45)).rgb * 0.085;

	// Outer ring: 8 taps at 1.0r, evenly spaced, each light. The angular
	// distribution (45 deg) is what fills the gaps between the axis taps so the
	// sampling pattern is isotropic 闂?a cross-only kernel ghosts along its axes.
	float a0 = 0.7853982;  // 45 degrees
	s += texture(src_tex, uv + vec2(o.x, o.y)).rgb * 0.045;
	s += texture(src_tex, uv + vec2(-o.x, o.y)).rgb * 0.045;
	s += texture(src_tex, uv + vec2(o.x, -o.y)).rgb * 0.045;
	s += texture(src_tex, uv + vec2(-o.x, -o.y)).rgb * 0.045;
	s += texture(src_tex, uv + vec2(o.x * 0.7071, 0.0)).rgb * 0.035;
	s += texture(src_tex, uv - vec2(o.x * 0.7071, 0.0)).rgb * 0.035;
	s += texture(src_tex, uv + vec2(0.0, o.y * 0.7071)).rgb * 0.035;
	s += texture(src_tex, uv - vec2(0.0, o.y * 0.7071)).rgb * 0.035;

	return s;
}

// How dark a point is beyond the bleed threshold, 0..1.
float inkness(vec3 c) {
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	return clamp((0.70 - lum) / 0.70, 0.0, 1.0);
}

void fragment() {
	// Curvature first: everything downstream samples through `uvb`.
	vec2 uvb = barrel(UV, curvature);
	// Short signal tear on stage boundaries. Keep HUD readable and sample
	// inside the original tube; the effect adds no bloom or gameplay objects.
	float field_gate = smoothstep(0.20, 0.29, uvb.y) * (1.0 - smoothstep(0.80, 0.89, uvb.y));
	float band = floor(uvb.y * 42.0);
	float tick = floor(transition_phase * 22.0);
	float band_noise = rnd(vec2(band, tick));
	float tear = step(0.68, band_noise) * (band_noise - 0.68) * 2.8;
	float inside_x = step(0.0, uvb.x) * step(uvb.x, 1.0);
	uvb.x = mix(uvb.x, clamp(uvb.x + (tear - 0.12) * transition_glitch * field_gate * 0.025, 0.0, 1.0), inside_x);

	// Outside the tube after warping: fill with the bezel colour. This is the
	// ONLY place the bezel appears now.
	//
	// The old version also painted a fixed `bezel_thick` band just inside the
	// UV edge. That band bypassed the entire chain 闂?blur, bleed, bloom, chroma,
	// grain 闂?and landed as a hard flat strip, which is why the frame edge looked
	// dirty and refused to go out of focus. Removed: the frame line already
	// exists as art in backdrop.gd, so it now goes through the same optics as
	// everything else and softens with the rest of the rim.
	vec3 col;
	if (uvb.x < 0.0 || uvb.x > 1.0 || uvb.y < 0.0 || uvb.y > 1.0) {
		COLOR = bezel;
	} else {
		vec2 px = 1.0 / src_size;

		// ---- 1. Focused base sample. This is the top of the chain.
		col = sample_src(uvb, px);

		// ---- 2. Ink bleed, two passes.
		// Pass A: a 16-tap ring at inner radius gathers the near-field ink 闂?		//        this is what gives thin strokes a soft, wet halo.
		// Pass B: an 8-tap ring at outer radius adds the far glow that makes a
		//        dense mass (the moon, a boss) feel like it is pressing through
		//        the paper.
		// Weighted by 1/(1+d) so the halo falls off with distance instead of
		// being a flat stamped outline. The old single-pass max() was flat and
		// read as a grey plaque around everything.
		vec2 o1 = px * bleed_radius;
		float in1 = 0.0;
		for (int i = 0; i < 16; i++) {
			float a = 6.2831853 * float(i) / 16.0;
			vec2 d = vec2(cos(a), sin(a)) * o1;
			in1 += inkness(texture(src_tex, uvb + d).rgb) * 0.0625;
		}
		vec2 o2 = px * (bleed_radius * 2.6);
		float in2 = 0.0;
		for (int i = 0; i < 8; i++) {
			float a = 6.2831853 * float(i) / 8.0 + 0.4;
			vec2 d = vec2(cos(a), sin(a)) * o2;
			in2 += inkness(texture(src_tex, uvb + d).rgb) * 0.125;
		}

		float near_ink = clamp((in1 - bleed_cut) / (1.0 - bleed_cut), 0.0, 1.0);
		float far_ink = clamp((in2 - bleed_cut) / (1.0 - bleed_cut), 0.0, 1.0);

		// Square the near term: a tight, confident halo rather than a wide wash.
		col -= col * near_ink * near_ink * bleed;
		col -= col * far_ink * far_ink * bleed * 0.42;

		// Edge emphasis: where the bleed gradient is steep, the paper lifts
		// slightly, which is what a real halftone print looks like under glass.
		float rim = clamp(near_ink - far_ink, 0.0, 1.0);
		col += vec3(1.0) * rim * bleed * 0.055;

		// ---- 3. Optical bloom, supplied by the external bloom chain.
		//
		// The extracted glow is the same texture on every ground, so HOW it is
		// combined decides what a highlight looks like 闂?and this palette has
		// exactly two grounds, which is where the old plain add failed:
		//
		//   paper  0.908  an add crosses 1.0 a few pixels out and clips flat,
		//                 so the halo loses its falloff and reads as a smudge.
		//   ink    0.230  nothing clips, so the whole add lands as a bright
		//                 grey plaque painted onto a surface that was never lit.
		//                 On the scenery moon that plaque also swallows the
		//                 halftone dots around every bullet 闂?which is exactly
		//                 the "highlight goes wrong on the planet layer" report.
		//
		// The missing idea is that a halo is REFLECTED light: it scales with
		// the albedo of the surface it lands on. Cream paper reflects almost
		// all of it, charcoal ink reflects a quarter. `bloom_surface` applies
		// that term, so the same highlight produces a full halo on the field
		// and a restrained one on the disc 闂?no clipping on either, and the
		// dots survive underneath.
		vec3 bl = texture(bloom_tex, uvb).rgb * bloom_tint.rgb;
		float ground = dot(clamp(col, 0.0, 1.0), vec3(0.299, 0.587, 0.114));
		float albedo = 1.0 - bloom_surface * (1.0 - ground);
		col += bl * bloom_strength * 0.5 * albedo;

		// ---- 4. Radial chromatic aberration.
		// Radial chromatic aberration.
		// Three gates in series, because any one of them alone looked wrong:
		//   radial    闂?rises smoothly from the centre, no dead zone
		//   lit       闂?weighted by luminance, so black ink stays neutral
		//   amplitude 闂?a fraction of a source pixel, so it reads as glass not as
		//               a broken channel
		if (chroma > 0.0) {
			vec2 cc = (uvb - vec2(0.5)) * 2.0;
			float rr = length(cc);

			// SMOOTH radial falloff, no dead zone.
			//
			// The previous form was `clamp((rr - 0.55) / knee)` squared, i.e.
			// exactly zero everywhere inside rr = 0.55 and ramping out beyond
			// it. The zero is fine, but the DERIVATIVE JUMP at that radius is
			// not: it draws a perfect concentric circle through the picture
			// where the fringe switches on, and on the scenery moon that circle
			// cut across the disc as a hard arc 闂?the "visible dividing line".
			// It was never the moon's shape or the edge gate; it was this.
			//
			// `pow(rr, chroma_knee)` starts at zero with zero slope at the
			// centre and climbs continuously, so there is no radius at which
			// anything changes abruptly. The knee now only sets how fast the
			// split grows toward the rim.
			float radial = pow(clamp(rr, 0.0, 1.4142) / 1.4142, chroma_knee);

			// ---- luminance validity -------------------------------------------------
			// Two ends only, no midtone window.
			//
			// Earlier versions weighted by a band peaked at mid-grey, to keep
			// white-hot cores neutral. On this palette that band is wrong at
			// BOTH ends: cream paper sits at ~0.93, so the window returned ~0
			// for the entire field, and combined with the local-contrast gate
			// below it meant every region of the frame was excluded by one gate
			// or the other. Raising `chroma` therefore did nothing anywhere 闂?
			// the amplitude was always being multiplied by zero somewhere.
			//
			// What actually matters is not "midtone" but "is there light to
			// split": black ink has none, a blown-out core has no headroom.
			// So gate only those two extremes and let the middle through at
			// full strength. Flat paper then passes the gate too, but a flat
			// area has identical neighbours, so a lateral displacement changes
			// nothing 闂?the effect can only appear where structure exists,
			// which is exactly where a lens would show it.
			float lu = dot(col, vec3(0.299, 0.587, 0.114));
			float floor_gate = clamp(lu / 0.12, 0.0, 1.0);
			float ceil_gate = 1.0 - clamp((lu - 0.96) / 0.04, 0.0, 1.0);
			float lit_gate = floor_gate * ceil_gate;

			// NOTE: the old `edge_gate` is gone, deliberately.
			//
			// It measured the luminance swing across a HORIZONTAL probe and
			// used it to protect hairlines. That measurement depends on the
			// local orientation of the structure, so it varied along a single
			// curve: the flat top of the scenery moon scored 1.0 (no horizontal
			// swing) while its steep flanks scored 0.5 (the probe crosses the
			// silhouette). The result was an abrupt "coloured here, neutral
			// there" seam running along one arc 闂?the hard dividing line that
			// made the effect read as an outline rather than as a fringe.
			//
			// Orientation-independent softness is what the reference look
			// actually needs; see the tap spread below.

			// The printed frame is art, not optics.
			//
			// The frame lives at the very rim, where the radial term peaks, and
			// its rules are 1px against cream 鈥?raising `chroma` makes the
			// border fringe while the field stays neutral, landing the effect
			// on the one element that must not be reinterpreted.
			//
			// Masked by DISTANCE IN SOURCE PIXELS, not by normalised extent.
			// The frame is drawn 8..15 px inside the raster, which is 0.037 of
			// the height but only 0.023 of the width 鈥?so one normalised band
			// masked the horizontal rules strongly and the vertical rules
			// weakly, leaving a doubled edge on two sides only. Distance in
			// pixels is identical on all four sides, which is what a border
			// actually is.
			//
			// Chroma's exemption: the frame rule ONLY, and only just around it.
			//
			// History, because the number moved twice for the wrong reasons:
			//
			//   * a 20..30 px band was set when the frame was THREE rules plus
			//     two hatched plates reaching 47 px from the edge. Clearing that
			//     decoration needed a wide band.
			//   * the plates are now gone and the rules are one 2 px line, so
			//     the wide band protected nothing and instead wiped the fringe off
			//     the whole top-left corner — which is exactly where the HUD
			//     lives. "K" and the hearts sat at 10..20 px from the edge and
			//     got no aberration at all, making the panel the only element on
			//     the plate that looked like it belonged to a different display.
			//
			// So the band now covers the rule itself (0..4 px) and feathers out
			// by 10 px. Everything past 10 px — HUD, gauge, ticks, corner
			// brackets — fringes with the rest of the picture.
			//
			// A SECOND, GENTLER gate then applies to the HUD specifically, and it
			// exists for a size reason rather than an art reason: a 7x7 glyph at
			// 2x has 2 px stems, and a 1.6 px lateral split moves each stem by
			// almost its own width, so the digit pair reads as two doubled
			// outlines instead of two digits. The field, the moon and the craft
			// are all large shapes and can take the full split; the readouts
			// cannot. They still fringe — just at roughly half amplitude, which
			// is what keeps the panel looking like it belongs to the same
			// display without turning the numbers illegible.
			float art_gate = 1.0 - smoothstep(4.0, 10.0, border_dist(uvb));

			// HUD zone: the top-left corner block plus the bottom readout strip.
			// Both are expressed in source pixels so they match game.gd's
			// rail_based layout without sharing a constant.
			vec2 sp = uvb * src_size;
			float hud_top = 1.0 - smoothstep(0.0, 2.0, max(0.0, sp.y - 46.0))
				* smoothstep(0.0, 2.0, max(0.0, sp.x - 62.0));
			float hud_bottom = 1.0 - smoothstep(0.0, 2.0, max(0.0, sp.x - 200.0))
				* smoothstep(0.0, 2.0, max(0.0, 188.0 - sp.y));
			float hud_gate = clamp(max(hud_top, hud_bottom), 0.0, 1.0);
			// 0.55 = roughly half the split over the readouts, never zero.
			art_gate = max(art_gate, hud_gate * 0.45);

			float amt = chroma * px.x * radial * lit_gate * (1.0 - art_gate);
			if (amt > 0.00001) {
				// ---- tapered, multi-tap split ------------------------------------
				// The reference look is an ANAGLYPH: each channel is offset, but
				// the separation ramps in over a distance instead of switching
				// on at an edge. A single displaced sample per channel gives one
				// crisp doubled line 闂?which is what made the earlier version
				// read as an outline, and what produced the hard dividing seam
				// across the moon's top.
				//
				// Three taps per channel, weighted 1/4 2/4 1/4, months apart:
				// the outer channel therefore bleeds in gradually, and the
				// visible fringe is a smooth ramp rather than a step. This is
				// also the cheapest honest way to fake a lens: a real one does
				// not sample a single ray.
				vec2 st = vec2(amt, 0.0);
				float r = 0.0;
				float g = 0.0;
				// ---- red / green pair -------------------------------------
				// Red is displaced right, green left, blue not at all.
				//
				// A red/blue pair (the classic red-cyan anaglyph) separates
				// warm from cold, and on this cream-and-charcoal palette the
				// cold side lands as CYAN 闁?a hue that appears nowhere else in
				// the art, so it read as a colour cast rather than as glass.
				// Pulling green the other way keeps the two visible fringes
				// inside the palette's own range: one shoulder goes warm, the
				// other goes olive. Blue stays put so the luminance story does
				// not change and the dark ink keeps its weight.
				r += texture(src_lin, uvb + st * 0.5).r * 0.25;
				r += texture(src_lin, uvb + st * 1.0).r * 0.50;
				r += texture(src_lin, uvb + st * 1.5).r * 0.25;
				g += texture(src_lin, uvb - st * 0.5).g * 0.25;
				g += texture(src_lin, uvb - st * 1.0).g * 0.50;
				g += texture(src_lin, uvb - st * 1.5).g * 0.25;
				vec3 cb3 = texture(src_lin, uvb).rgb;

				// ---- desaturate before mixing ------------------------------------
				// Two knobs, and they are NOT the same thing:
				//
				//   saturation 閳?how far the split channel is allowed to travel
				//                from the original pixel's own luminance. Pulling
				//                each displaced channel back toward grey keeps the
				//                fringe in the palette; without it the fringe sits
				//                at full chroma and reads as magenta/cyan ink
				//                printed on top of the art rather than as a shift
				//                in the glass.
				//   opacity    閳?how much of that (already quiet) fringe is
				//                admitted at all, via `wmix` below.
				//
				// Doing only the second would keep the fringe as loud but rarer;
				// doing only the first would keep it everywhere but muddy. The
				// reference look is quiet AND thin, so both move.
				vec3 base_lum = vec3(dot(cb3, vec3(0.299, 0.587, 0.114)));
				r = mix(base_lum.r, r, chroma_saturation);
				g = mix(base_lum.r, g, chroma_saturation);

				// How much of the ramp is admitted. Weighted by the luminance
				// validity term only: an orientation-free gate cannot create a
				// seam, whereas the old swing gate did exactly that.
				float wmix = chroma_opacity * lit_gate * (1.0 - art_gate);
				col.r = mix(col.r, r, wmix);
				col.g = mix(col.g, g, wmix);
				col.b = mix(col.b, cb3.b, wmix * 0.90);
			}
			if (chroma_dbg > 0.5) {
				col = vec3(clamp(radial, 0.0, 1.0), 0.0, 0.0);
			}
		}

		// ---- 5. Scanlines, one band per source pixel row.
		float row = uvb.y * src_size.y;
		float sl = 0.5 + 0.5 * sin(row * 6.2831853);
		col *= 1.0 - scanline * (1.0 - sl);

		// ---- 6. Animated grain.
		// Re-seeded `grain_rate` times a second, on a lattice aligned to source
		// pixels so the specks stay 1px and never average into grey haze. The
		// luminance offset is symmetric around zero, so grain does not change
		// the overall brightness 闂?only its variance.
		vec2 cell = floor(uvb * src_size);
		vec2 phase = vec2(floor(TIME * grain_rate), floor(TIME * grain_rate * 0.61));
		float n = rnd(cell + phase * 37.0);
		// Triangle-shaped distribution instead of uniform: fewer outliers, so
		// the field twinkles without the occasional hard speck.
		float tri = (n + rnd(cell * 1.7 + phase * 91.0)) * 0.5 - 0.5;
		col += tri * grain;

		// ---- 7. Slow lamp shimmer, whole-frame.
		// Two incommensurate sine terms: no audible beat, no visible strobe.
		float lamp = sin(TIME * 1.7) * 0.6 + sin(TIME * 4.3) * 0.4;
		col *= 1.0 + shimmer * lamp;
		// A very small fast component on top, which is what a CRT actually does.
		col *= 1.0 + flicker * sin(TIME * 43.0);

		vec2 c = (uvb - vec2(0.5)) * 2.0;
		float d = length(c) * 0.74;
		col *= 1.0 - vignette * pow(clamp(d, 0.0, 1.0), 3.2);

		// ---- 8. Overall exposure.
		//
		// Three separate knobs, because "make it brighter" has three different
		// meanings on this palette and they must not be solved with one
		// multiply:
		//
		//   exposure 闂?a plain gain on everything. Applied first so the ink
		//              lifts with the paper instead of the paper clipping first.
		//   lift     闂?the floor. Mixed additively toward mid-grey so the deep
		//              ink stops being a hole. Without this, raising exposure
		//              only stretches the highlights and the scene reads as
		//              washed rather than lit.
		//   gamma    闂?shaped so midtones move more than either end. This is
		//              what actually makes the field feel brighter: most of this
		//              frame is paper, and paper sits near the top, so a pure
		//              gain would clip it. A gamma below 1 lifts the middle
		//              without touching the ceiling.
		col = pow(clamp(col, 0.0, 1.0), vec3(gamma));
		col *= exposure;
		col = col * (1.0 - lift) + lift * lift_target;
		col *= tint.rgb;

		// Re-map luminance into the current paper/ink pair. Saturation stays
		// restrained, while near-white cores keep their original highlight.
		float tone_lum = dot(clamp(col, 0.0, 1.0), vec3(0.299, 0.587, 0.114));
		vec3 tone = mix(palette_dark.rgb, palette_light.rgb, smoothstep(0.03, 0.98, tone_lum));
		float preserve_core = smoothstep(0.84, 1.0, tone_lum);
		tone = mix(tone, col, preserve_core * 0.82);
		col = mix(col, tone, palette_strength);
		float dropout = step(0.91, band_noise) * transition_glitch * field_gate;
		float tracking = 1.0 - smoothstep(0.0, 0.009, abs(uvb.y - mix(0.24, 0.82, transition_phase)));
		col *= 1.0 - dropout * 0.22;
		col += vec3(0.045) * tracking * transition_glitch * field_gate;
		// Final signal noise treats lettering, logo, artwork and field identically.
		vec2 noise_cell = floor(uvb * src_size);
		float noise_tick = floor(TIME * 18.0);
		float signal_noise = rnd(noise_cell + vec2(noise_tick * 31.0, noise_tick * 17.0));
		col += vec3((signal_noise - 0.5) * unified_noise);
	}

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
