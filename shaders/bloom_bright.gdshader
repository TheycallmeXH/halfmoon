// Bloom pass 1 — luminance extraction with SOFT weights, not a hard gate.
//
// Why the previous version read as "a halo following the bullet":
// it took a hard threshold, kept only the pixels above it, and blurred them.
// That produces a ring whose size is fixed by the blur radius and whose
// brightness is independent of the source — the light looks pasted around the
// object rather than emitted by it. The halo "follows" because it is a copy.
//
// What real light does: a bright source contributes strongly, a dimmer surface
// still contributes, and the sum decays continuously with distance. So this
// pass now weights EVERY pixel by a smooth curve of its luminance, with no
// binary cut at all. Faint paper contributes a tiny amount (which is correct:
// it is a lit surface), and that faint contribution is what makes the glow
// blend into the field instead of stamping a ring on top of it.
//
// Two separate controls, because they solve different problems:
//   bias  — shifts when the curve starts rising (how much dim stuff counts)
//   power — shapes the knee (how hard the falloff is above that)
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D src : filter_linear, repeat_disable;

// Luminance where the weight reaches zero. Paper is ~0.92, so this must sit
// ABOVE it or the entire field glows and the screen washes out — that is what
// happened at 0.30 and at 0.87. 0.93 keeps paper at exactly zero while real
// white cores (0.99) sit near the top of the curve.
uniform float floor_lum : hint_range(0.0, 1.0) = 0.93;
// Exponent on the normalised luminance. Higher = highlights dominate more
// sharply; lower = a broader, milkier glow.
uniform float power : hint_range(1.0, 6.0) = 2.0;
// Overall strength of the extracted buffer. Small: the tiers add up.
uniform float gain : hint_range(0.1, 8.0) = 3.0;

uniform float dbg : hint_range(0.0, 1.0) = 0.0;

float lum(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	// Read exact centers of the source 2x2 block. Cross-shaped half-pixel
	// offsets still bilinearly mixed a white pixel with its dark neighbour,
	// losing isolated cores before MAX had a chance to preserve them.
	vec2 source_size = vec2(textureSize(src, 0));
	vec2 base = floor(UV * source_size * 0.5) * 2.0;
	vec3 a = texture(src, (base + vec2(0.5, 0.5)) / source_size).rgb;
	vec3 b = texture(src, (base + vec2(1.5, 0.5)) / source_size).rgb;
	vec3 c = texture(src, (base + vec2(0.5, 1.5)) / source_size).rgb;
	vec3 d = texture(src, (base + vec2(1.5, 1.5)) / source_size).rgb;

	// MAX, not average: downsampling a 1px white core by averaging loses ~94%
	// of its energy, which is how an earlier build produced a pure black
	// buffer. For the *luminance* term max is right; for the *colour* term we
	// take the brightest tap so a tinted flash blooms in its own hue.
	float la = lum(a);
	float lb = lum(b);
	float lc = lum(c);
	float ld = lum(d);
	float l = max(max(la, lb), max(lc, ld));

	vec3 col = a;
	if (lb >= la && lb >= lc && lb >= ld) { col = b; }
	else if (lc >= la && lc >= lb && lc >= ld) { col = c; }
	else if (ld >= la && ld >= lb && ld >= lc) { col = d; }

	// Continuous weight: no branch, no threshold, no ring.
	float t = clamp((l - floor_lum) / max(1.0 - floor_lum, 0.0001), 0.0, 1.0);
	float w = pow(t, power);

	vec3 out_c = col * w * gain;
	if (dbg > 0.5) {
		out_c = vec3(1.0, 0.0, 0.0);
	}
	COLOR = vec4(out_c, 1.0);
}
