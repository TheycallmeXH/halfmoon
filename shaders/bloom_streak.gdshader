// Bloom pass 3 — anamorphic horizontal streak.
//
// This is the signature in the reference images: those tall lights bleed a
// HORIZONTAL bar of light across the frame, not a round halo. It comes from
// an anamorphic lens element, and it is what separates "nice glow" from "that
// looks like a night photograph".
//
// Implementation: a wide horizontal-only blur of the already-extracted
// highlights, stretched far beyond the round bloom, then combined at low
// weight. Vertical darkening is deliberate — the bar must read as a line.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D src : filter_linear, repeat_disable;
// Width of the streak in target pixels. Large, because this must span the frame.
uniform float stretch : hint_range(1.0, 64.0) = 18.0;
// Falloff exponent: higher = tighter bar with a longer thin tail.
uniform float falloff : hint_range(0.5, 4.0) = 1.6;

void fragment() {
	vec2 px = vec2(1.0, 1.0) / vec2(textureSize(src, 0));
	vec2 dir = vec2(px.x, 0.0) * stretch;

	// 33 taps along the horizontal, weighted by distance so the tail thins out
	// instead of ending in a hard cut.
	//
	// Tap COUNT is set by the spacing, not by taste: at stretch 26 in a 192px
	// buffer, 9 taps sit ~6.5px apart, so each one lands as a separate blob and
	// the "streak" reads as a row of dashes stacked around the source — which
	// is what made highlights on the dark disc look torn. 33 taps put them
	// ~0.8px apart, below the buffer's own pixel, so the bar is continuous.
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int i = -16; i <= 16; i++) {
		float f = float(i) / 16.0;
		float w = pow(1.0 - abs(f), falloff);
		// Slight vertical wobble per tap: a perfect line looks synthetic, and
		// real anamorphic streaks are not mathematically flat. Kept small — at
		// a full pixel per tap the bar visibly splits into two bands.
		vec2 off = dir * f + vec2(0.0, px.y * float(i) * 0.03);
		acc += texture(src, UV + off).rgb * w;
		wsum += w;
	}
	COLOR = vec4(acc / max(wsum, 0.001), 1.0);
}
