// Bloom pass — separable Gaussian blur, one axis per draw.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D src : filter_linear, repeat_disable;
uniform float axis : hint_range(0.0, 1.0) = 0.0;
uniform float radius : hint_range(0.5, 12.0) = 2.0;

void fragment() {
	vec2 px = vec2(1.0, 1.0) / vec2(textureSize(src, 0));
	vec2 dir = (axis > 0.5) ? vec2(0.0, px.y) : vec2(px.x, 0.0);
	vec2 st = dir * radius;

	vec3 c = texture(src, UV).rgb * 0.375;
	c += texture(src, UV + st).rgb * 0.25;
	c += texture(src, UV - st).rgb * 0.25;
	c += texture(src, UV + st * 2.0).rgb * 0.0625;
	c += texture(src, UV - st * 2.0).rgb * 0.0625;

	COLOR = vec4(c, 1.0);
}
