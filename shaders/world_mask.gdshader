shader_type canvas_item;
render_mode unshaded;

void fragment() {
	vec2 p = floor(SCREEN_UV * vec2(384.0, 216.0));
	float edge = min(min(p.x - 14.0, 370.0 - p.x), min(p.y - 14.0, 202.0 - p.y));
	float visibility = smoothstep(0.0, 5.0, edge);
	if (p.x >= 14.0 && p.x < 112.0 && p.y >= 14.0 && p.y < 84.0) {
		visibility = 0.0;
	}
	COLOR.a *= visibility;
}
