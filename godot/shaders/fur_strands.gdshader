// Fourrure a brins geometriques (facon HairWorks / RTX Hair, sans ray tracing) :
// chaque poil est une petite courbe dont les segments sont elargis face a la camera dans le vertex shader,
// puis ombres comme un TUBE ROND (normale qui tourne en travers du poil, comme une "swept sphere").
// Eclairage : matcap Cycles (eclairage global) + lobes de cheveux type Marschner :
//   R   : reflet blanc, decale vers la racine
//   TRT : reflet colore, decale vers la pointe
//   TT  : lumiere de l'ecran qui traverse les poils du bord
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, unshaded, shadows_disabled, skip_vertex_transform;
#include "res://shaders/env.gdshaderinc"
#include "res://shaders/occlusion.gdshaderinc"

uniform vec3 root_color : source_color = vec3(0.85, 0.45, 0.6);
uniform vec3 tip_color : source_color = vec3(1.0, 0.8, 0.88);
uniform vec3 base_color : source_color = vec3(0.9, 0.6, 0.7);
uniform sampler2D fur_matcap : source_color, filter_linear_mipmap, repeat_disable;
uniform float matcap_gain = 1.2;
uniform float shadow_saturation = 0.3;
uniform float sheen_whiten = 0.4;
uniform float strand_width = 0.0022;   // demi-largeur a la racine (unites monde)
uniform float gravity = 0.12;
uniform vec3 wind = vec3(0.0);
uniform vec3 key_dir = vec3(-0.53, 0.66, 0.53);
uniform float spec_r = 0.18;
uniform float spec_trt = 0.12;
uniform float trans = 0.3;            // TT : lumiere de l'ecran a travers les poils
uniform float env_tint = 0.15;
uniform float rim_glow = 0.45;      // halo lumineux de la silhouette (fibres traversees par la lumiere)
uniform float scatter = 0.24;       // diffusion de la lumiere entre les poils (tons moyens doux)
uniform float ground_y = -100.0;
uniform vec3 blush_l = vec3(100.0);
uniform vec3 blush_r = vec3(100.0);
uniform float blush_amount = 0.0;
uniform float blush_radius = 0.11;
uniform vec3 blush_color : source_color = vec3(1.0, 0.42, 0.55);

varying vec3 t_view;
varying vec3 n_root;
varying vec3 obj_p;
varying float rnd;
varying float cover;
varying float along;
varying vec3 n_obj;
varying vec3 l_obj;

void vertex() {
	float side = UV.x;
	along = UV.y;
	rnd = UV2.x;
	float len = UV2.y;
	obj_p = VERTEX;
	n_obj = TANGENT.xyz;
	l_obj = normalize(inverse(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * key_dir));
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// le poil plie sous la gravite et le vent (plus a la pointe)
	wp += (vec3(0.0, -gravity, 0.0) + wind * 0.6) * len * along * along;
	wp.y = max(wp.y, ground_y + 0.002);
	vec3 vp = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;
	mat4 mv = VIEW_MATRIX * MODEL_MATRIX;
	t_view = normalize((mv * vec4(NORMAL, 0.0)).xyz + vec3(0.0, -gravity, 0.0) * along * 0.8);
	n_root = normalize((mv * vec4(TANGENT.xyz, 0.0)).xyz);
	vec3 vdir = normalize(-vp);
	vec3 sidev = cross(t_view, vdir);
	float sl = length(sidev);
	sidev = sl > 1e-4 ? sidev / sl : vec3(1.0, 0.0, 0.0);
	// largeur : effilee vers la pointe ; jamais moins d'un demi-pixel (sinon scintillement)
	float w = strand_width * (1.0 - along * 0.8) * (0.7 + 0.6 * rnd);
	float px = 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y) * (-vp.z);
	float ww = max(w, px * 0.6);
	cover = w / ww;
	vp += sidev * side * ww;
	VERTEX = vp;
	NORMAL = n_root;
}

void fragment() {
	float across = UV.x;
	// couverture : pointe qui s'estompe + poils sous-pixel a moitie transparents (alpha-to-coverage)
	float a = cover * (1.0 - smoothstep(0.75, 1.0, along)) * (1.0 - smoothstep(0.7, 1.0, abs(across)) * 0.5);
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;

	vec3 v = normalize(VIEW);
	vec3 T = normalize(t_view);
	vec3 cb = cross(T, v);
	vec3 B = dot(cb, cb) > 1e-8 ? normalize(cb) : vec3(1.0, 0.0, 0.0);
	vec3 cn = cross(B, T);
	vec3 Nf = dot(cn, cn) > 1e-8 ? normalize(cn) : v;
	float ac = clamp(across, -0.99, 0.99);
	vec3 N = normalize(B * ac + Nf * sqrt(1.0 - ac * ac));  // normale du tube

	vec3 col = mix(root_color, tip_color, smoothstep(0.0, 1.0, along)) * (0.96 + 0.08 * rnd);
	float bd = min(length(obj_p - blush_l), length(obj_p - blush_r));
	col = mix(col, blush_color, (1.0 - smoothstep(blush_radius * 0.35, blush_radius, bd)) * blush_amount);

	// eclairage global (matcap Cycles) sur la normale de la peau
	vec3 nr = normalize(n_root);
	vec3 mc = texture(fur_matcap, vec2(nr.x, -nr.y) * 0.48 + 0.5).rgb * matcap_gain;
	float ml = dot(mc, vec3(0.299, 0.587, 0.114));
	vec3 deep = pow(clamp(col, vec3(0.001), vec3(1.0)), vec3(1.0 + (1.0 - clamp(ml, 0.0, 1.0)) * shadow_saturation));
	float ao = mix(0.68, 1.0, pow(along, 0.6));
	vec3 lit = deep * mc * ao;
	lit = mix(lit, mc * mix(vec3(1.0), col, 0.35), smoothstep(0.75, 1.15, ml) * sheen_whiten * along);

	// lobes de cheveux (Marschner simplifie, reflets decales le long du poil)
	vec3 L = normalize(key_dir);
	vec3 H = normalize(L + v + vec3(1e-5));
	vec3 Tr = normalize(T - N * 0.1);
	vec3 Tt = normalize(T + N * 0.14);
	float dr = dot(Tr, H);
	float dt = dot(Tt, H);
	float r_lobe = pow(sqrt(max(0.0, 1.0 - dr * dr)), 90.0) * spec_r;
	float trt_lobe = pow(sqrt(max(0.0, 1.0 - dt * dt)), 28.0) * spec_trt * (0.6 + 0.8 * rnd);
	float facing = clamp(dot(N, L) * 0.5 + 0.5, 0.0, 1.0);
	lit += (vec3(r_lobe) + col * trt_lobe) * facing * ao;

	// TT : la lumiere de l'ecran derriere traverse les poils fins du bord
	float edge = pow(1.0 - clamp(dot(nr, v), 0.0, 1.0), 1.5);
	vec3 behind = env_behind(SCREEN_UV, vec2(0.0), 2.0);
	lit += behind * mix(vec3(1.0), col, 0.6) * trans * edge * along * env_strength;
	lit += col * env_diffuse(nr) * env_tint;
	lit += col * scatter;
	lit += mix(col, vec3(1.0), 0.45) * edge * rim_glow * along;
	vec2 oc = occlusion(obj_p, normalize(n_obj), normalize(l_obj));
	lit *= oc.x * oc.y;
	if (any(isnan(lit)) || any(isinf(lit))) { lit = col * 0.8; }
	ALBEDO = lit;
}
