// Ombre de contact gaussienne, dessinee sur le "mur" juste sous le point d'appui
// (donc sur la barre des taches quand il est assis dessus).
shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, shadows_disabled;

uniform float strength = 0.4;

void fragment() {
	vec2 p = (UV - vec2(0.5, 0.35)) * vec2(2.0, 2.6);
	float g = exp(-dot(p, p) * 2.2);
	// plus dense juste sous la ligne de contact
	float a = g * strength;
	ALBEDO = vec3(0.0);
	ALPHA = a;
}
