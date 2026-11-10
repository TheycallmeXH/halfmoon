shader_type canvas_item;
render_mode unshaded;
uniform sampler2D src : filter_linear, repeat_disable;
uniform float clock = 0.0;
uniform float proximity = 0.0;
uniform float impact = 0.0;

float hash(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float ink_at(vec2 uv) {
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return 0.0;
	}
	return 1.0 - dot(texture(src, uv).rgb, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	// Short signal losses, separated by long clean holds.
	float phase = mod(clock, 4.6);
	float burst = step(1.10, phase) * (1.0 - step(1.42, phase));
	burst += step(1.60, phase) * (1.0 - step(1.68, phase));
	burst = max(burst, impact);
	float tick = floor(clock * 24.0);
	float row = floor(UV.y * 36.0);
	float band = step(0.68, hash(row + tick * 7.0));
	float shift = (hash(row * 3.0 + tick) - 0.5) * 0.075 * band * burst;
	vec2 sample_uv = UV + vec2(shift, 0.0);
	float ink = ink_at(sample_uv);
	float echo = ink_at(sample_uv + vec2(0.022, 0.0));
	ink = max(ink, echo * 0.24 * band * burst);
	float dropout = step(0.91, hash(floor(UV.y * 110.0) + tick * 11.0));
	ink *= 1.0 - dropout * burst * 0.7;
	vec3 paper = vec3(0.925, 0.910, 0.851);
	vec3 pigment = vec3(0.129, 0.129, 0.118);
	float scan = 1.0 - smoothstep(0.004, 0.016, abs(UV.y - fract(clock * 0.38)));
	vec3 color = mix(paper, pigment, ink);
	color = mix(color, paper, scan * proximity * 0.48 * ink);
	float alpha = texture(src, sample_uv).a;
	alpha = max(alpha, texture(src, sample_uv + vec2(0.022, 0.0)).a * 0.24 * band * burst);
	// A narrow printed contour keeps black hair legible against the night field.
	vec2 edge_step = vec2(3.0) / vec2(textureSize(src, 0));
	float edge = max(texture(src, sample_uv + vec2(edge_step.x, 0.0)).a,
		texture(src, sample_uv - vec2(edge_step.x, 0.0)).a);
	edge = max(edge, texture(src, sample_uv + vec2(0.0, edge_step.y)).a);
	edge = max(edge, texture(src, sample_uv - vec2(0.0, edge_step.y)).a);
	float outline = max(0.0, edge - alpha) * 0.65;
	color = mix(color, paper, outline);
	alpha = max(alpha, outline);
	COLOR = vec4(color, alpha);
}
