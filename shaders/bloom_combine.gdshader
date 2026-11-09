// Bloom combine — sum the three blur tiers plus the anamorphic streak.
//
// Three tiers, not two, because one blur can only produce one falloff shape:
//
//   narrow  → the light sitting ON the source (tight, bright)
//   wide    → the visible skirt (medium reach)
//   far     → the field being lit (very wide, very dim)
//
// The tiers are weighted in decreasing strength but increasing radius, which is
// what turns a halo into ambient light. With only narrow + wide the result reads
// as a ring pasted onto the bullet: it has a definite edge and a constant
// brightness relative to the source. The far tier is what removes that edge.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D tex_narrow : filter_linear, repeat_disable;
uniform sampler2D tex_wide : filter_linear, repeat_disable;
uniform sampler2D tex_far : filter_linear, repeat_disable;
uniform sampler2D tex_streak : filter_linear, repeat_disable;

uniform float w_narrow : hint_range(0.0, 3.0) = 1.15;
uniform float w_wide : hint_range(0.0, 3.0) = 0.80;
uniform float w_far : hint_range(0.0, 3.0) = 0.55;
uniform float w_streak : hint_range(0.0, 3.0) = 0.70;

// The reference look skews cool: the flare reads blue-white against night.
// Applies to the streak only, so the round tiers keep the source colour.
uniform vec4 streak_tint : source_color = vec4(0.72, 0.84, 1.0, 1.0);

void fragment() {
	vec3 n = texture(tex_narrow, UV).rgb;
	vec3 w = texture(tex_wide, UV).rgb;
	vec3 f = texture(tex_far, UV).rgb;
	vec3 s = texture(tex_streak, UV).rgb * streak_tint.rgb;

	// Additive light, no tone map: the CRT pass owns the final clamp. Clipping
	// early would rob the core of its hot white centre.
	COLOR = vec4(n * w_narrow + w * w_wide + f * w_far + s * w_streak, 1.0);
}
