// "Splats" gaussiens de poils : des milliers de petites taches allongees et semi-transparentes,
// orientees comme les poils. Elles adoucissent la silhouette pour qu'elle se fonde dans le bureau
// (la fenetre etant transparente, on voit reellement l'ecran a travers les bords).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, skip_vertex_transform, diffuse_lambert_wrap, specular_disabled, shadows_disabled;
#include "res://shaders/env.gdshaderinc"

uniform vec3 root_color : source_color = vec3(0.85, 0.45, 0.6);
uniform vec3 tip_color : source_color = vec3(1.0, 0.8, 0.88);
uniform vec3 base_color : source_color = vec3(0.9, 0.6, 0.7);
uniform float fur_length = 0.05;
uniform float splat_len = 1.25;
uniform float splat_width = 0.04;
uniform float gravity = 0.65;
uniform vec3 wind = vec3(0.0);
uniform float opacity = 0.22;
uniform float wrap = 0.6;
uniform float ground_y = -100.0;

varying float rnd;

void vertex() {
	vec3 n_obj = INSTANCE_CUSTOM.xyz * 2.0 - 1.0;
	rnd = INSTANCE_CUSTOM.w;
	vec3 c_view = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 n_view = normalize((MODELVIEW_MATRIX * vec4(n_obj, 0.0)).xyz);
	vec3 wind_view = (VIEW_MATRIX * vec4(wind, 0.0)).xyz;
	vec3 d = normalize(n_view + vec3(0.0, -gravity * 0.7, 0.0) + wind_view * 0.5 + (vec3(rnd, fract(rnd * 7.3), 0.0) - 0.5) * 0.5);
	float len = fur_length * splat_len * (0.65 + 0.7 * fract(rnd * 3.7));
	vec2 al = d.xy;
	float l2 = length(al);
	al = l2 > 0.05 ? al / l2 : vec2(0.0, 1.0);
	vec2 pp = vec2(-al.y, al.x);
	float vis = len * max(l2, 0.3);
	float along = VERTEX.y + 0.5;
	vec3 pos = c_view + d * len * 0.1 + vec3(al * along * vis + pp * VERTEX.x * splat_width * (0.7 + 0.6 * rnd), 0.0);
	// pas sous le sol
	float gy_view = (VIEW_MATRIX * vec4(0.0, ground_y, 0.0, 1.0)).y;
	pos.y = max(pos.y, gy_view);
	VERTEX = pos;
	NORMAL = n_view;
}

void fragment() {
	float across = (UV.x - 0.5) * 2.0;
	float t = 1.0 - UV.y;  // 0 racine -> 1 pointe
	float g = exp(-across * across * 2.6) * smoothstep(1.0, 0.55, t) * smoothstep(0.0, 0.12, t);
	vec3 col = mix(root_color, tip_color, 0.4 + 0.6 * t) * (0.85 + 0.3 * rnd);
	ALBEDO = col;
	vec3 n = normalize(NORMAL);
	float edge = pow(1.0 - clamp(abs(dot(n, normalize(VIEW))), 0.0, 1.0), 1.5);
	vec3 behind = env_behind(SCREEN_UV, vec2(0.0), 2.0);
	EMISSION = col * env_diffuse(n) * 0.45 + behind * wrap * (0.3 + edge) * env_strength;
	ALPHA = g * opacity;
}
