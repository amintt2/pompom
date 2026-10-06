// Mur invisible derriere le compagnon : n'affiche que l'ombre portee (sur le bureau / la barre des taches).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, shadow_to_opacity, specular_disabled;

uniform float strength = 0.45;

void fragment() {
	ALBEDO = vec3(0.02, 0.015, 0.03);
	ALPHA = strength;
}
