// Ombre de contact gaussienne, dessinee sur le "mur" juste sous le point d'appui
// (donc sur la barre des taches quand il est assis dessus).
shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, shadows_disabled;

uniform float strength = 0.4;

void fragment() {
	vec2 p = (UV - vec2(0.5, 0.35)) * vec2(2.0, 2.6);
	float g = exp(-dot(p, p) * 2.2);
	// fondu jusqu'a zero sur les bords du quad (sinon un rectangle se voit sur les fonds clairs)
	float edge = smoothstep(0.0, 0.3, UV.x) * smoothstep(1.0, 0.7, UV.x) * smoothstep(0.0, 0.35, UV.y) * smoothstep(1.0, 0.65, UV.y);
	// plus dense juste sous la ligne de contact
	float a = g * edge * strength;
	ALBEDO = vec3(0.0);
	ALPHA = a;
}
