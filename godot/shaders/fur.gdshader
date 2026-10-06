// Fourrure "shell" a brins individuels.
// La mesh est dessinee N fois, poussee le long de la normale. Sur chaque coque on ne garde que les
// pixels proches d'un brin (bruit cellulaire), qui s'affine et s'arrete a sa propre longueur.
// Eclairage : sous-poil sombre, reflet anisotrope Kajiya-Kay, lumiere de l'ecran qui "deborde" sur les bords.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded, shadows_disabled;
#include "res://shaders/env.gdshaderinc"
#include "res://shaders/contact.gdshaderinc"
#include "res://shaders/occlusion.gdshaderinc"

uniform float shell_h = 0.0;            // 0 = sous-poil, 1 = pointe
uniform float fur_length = 0.05;
uniform float density = 45.0;           // brins par unite
uniform vec3 root_color : source_color = vec3(0.85, 0.45, 0.6);
uniform vec3 tip_color : source_color = vec3(1.0, 0.8, 0.88);
uniform vec3 base_color : source_color = vec3(0.9, 0.6, 0.7);
uniform float gravity = 0.6;
uniform vec3 wind = vec3(0.0);
uniform float curl = 0.6;
uniform float thickness = 0.62;
uniform float length_var = 0.45;
uniform float rim_strength = 0.35;
uniform float sheen = 0.0;
uniform vec3 key_dir = vec3(-0.53, 0.66, 0.53);  // vers la lumiere principale (espace vue)
uniform float spec_strength = 0.22;
uniform float wrap = 0.3;                       // lumiere de l'ecran sur les bords
uniform vec3 blush_l = vec3(100.0);
uniform vec3 blush_r = vec3(100.0);
uniform float blush_amount = 0.0;
uniform float blush_radius = 0.11;
uniform vec3 blush_color : source_color = vec3(1.0, 0.42, 0.55);
// eclairage "rendu Blender" : matcap de fourrure blanche rendu dans Cycles (lumiere studio)
uniform sampler2D fur_matcap : source_color, filter_linear_mipmap, repeat_disable;
uniform float matcap_gain = 1.2;
uniform float shadow_saturation = 0.3;  // les zones sombres d'une fourrure coloree sont plus saturees
uniform float sheen_whiten = 0.4;      // le reflet satine tire vers le blanc
uniform float env_tint = 0.15;
uniform float rim_glow = 0.45;      // halo lumineux de la silhouette (fibres traversees par la lumiere)
uniform float scatter = 0.24;       // diffusion de la lumiere entre les poils (tons moyens doux)
//          // part de la couleur de l'ecran dans l'eclairage

varying vec3 base_pos;
varying vec3 obj_n;
varying vec3 l_obj;

vec3 hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

// renvoie (couverture du brin, valeur aleatoire du brin)
vec2 strands(vec2 p, float h, float seed, float fw) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 best = vec2(0.0, 0.5);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec3 r = hash32(i + o + seed * 37.1);
			float len = 1.0 - r.z * length_var;
			if (h > len) {
				continue;
			}
			vec2 pt = o + 0.15 + r.xy * 0.7 + (r.yx - 0.5) * curl * h;
			float rad = thickness * pow(1.0 - h / len, 0.6) * (0.75 + 0.5 * r.y);
			float d = length(f - pt);
			// bord du brin adouci selon la taille du pixel (anti-crenelage analytique)
			float soft_edge = max(rad * 0.25, fw * 0.75);
			float c = 1.0 - smoothstep(rad - soft_edge, rad + soft_edge, d);
			// brin plus fin qu'un pixel : on garde sa couverture moyenne au lieu de scintiller
			c *= clamp(rad / max(fw, 1e-4), 0.35, 1.0);
			if (c > best.x) {
				best = vec2(c, r.x);
			}
		}
	}
	return best;
}

void vertex() {
	base_pos = VERTEX;
	obj_n = NORMAL;
	float h = shell_h;
	mat3 inv = inverse(mat3(MODEL_MATRIX));
	vec3 g = inv * vec3(0.0, -1.0, 0.0);
	l_obj = normalize(inv * (mat3(INV_VIEW_MATRIX) * key_dir));
	vec3 w = inv * wind;
	// meches : petites variations de direction a basse frequence
	vec3 comb = (vec3(vnoise(VERTEX * 7.0), vnoise(VERTEX * 7.0 + 11.0), vnoise(VERTEX * 7.0 + 23.0)) - 0.5) * 0.6;
	VERTEX += NORMAL * fur_length * h;
	VERTEX += (g * gravity + w + comb) * fur_length * h * h;
	VERTEX = apply_contact(VERTEX, MODEL_MATRIX);
}

void fragment() {
	float h = shell_h;
	vec3 an = abs(normalize(obj_n));
	vec2 p2;
	float seed;
	if (an.x > an.y && an.x > an.z) {
		p2 = base_pos.yz;
		seed = 1.0;
	} else if (an.y > an.z) {
		p2 = base_pos.xz;
		seed = 2.0;
	} else {
		p2 = base_pos.xy;
		seed = 3.0;
	}
	p2 *= density;
	float fw = length(fwidth(p2));
	vec2 s1 = strands(p2, h, seed, fw);
	vec2 s2 = strands(p2 * 1.63 + 5.7, h * 1.15, seed + 4.0, fw * 1.63);
	vec2 s = s1.x >= s2.x ? s1 : s2;
	// sous-poil dense pres de la peau
	float under = (1.0 - smoothstep(0.08, 0.3, h)) * smoothstep(0.25, 0.5, vnoise(base_pos * density * 1.3));
	float cov = h > 0.001 ? max(s.x, under) : 1.0;
	// alpha-to-coverage : les bords des poils sont lisses par le MSAA au lieu d'etre "tout ou rien"
	ALPHA = cov;
	ALPHA_SCISSOR_THRESHOLD = 0.5;

	float ao = mix(0.62, 1.0, pow(h, 0.7));
	vec3 col = mix(root_color, tip_color, smoothstep(0.0, 1.0, h)) * ao;
	col *= 0.94 + 0.12 * s.y;  // chaque brin a sa teinte (legere, sinon ca "grene")
	col *= 0.95 + 0.1 * vnoise(base_pos * 4.0);
	float dl = length(base_pos - blush_l);
	float dr = length(base_pos - blush_r);
	float b = (1.0 - smoothstep(blush_radius * 0.35, blush_radius, min(dl, dr))) * blush_amount;
	col = mix(col, blush_color * mix(0.8, 1.0, h), b);
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	// eclairage = matcap Cycles (lumiere de studio douce, satine, assombrissement rasant)
	vec2 muv = vec2(n.x, -n.y) * 0.48 + 0.5;
	vec3 mc = texture(fur_matcap, muv).rgb * matcap_gain;
	float ml = dot(mc, vec3(0.299, 0.587, 0.114));
	// couleur profonde dans l'ombre, plus pale dans le satine
	vec3 deep = pow(clamp(col, vec3(0.001), vec3(1.0)), vec3(1.0 + (1.0 - clamp(ml, 0.0, 1.0)) * shadow_saturation));
	vec3 lit = deep * mc;
	lit = mix(lit, mc * mix(vec3(1.0), col, 0.35), smoothstep(0.75, 1.15, ml) * sheen_whiten);
	// integration : lumiere de l'ecran (couleur ambiante + debord sur les bords)
	float edge = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 2.0);
	vec3 behind = env_behind(SCREEN_UV, vec2(0.0), 2.5);
	lit += col * env_diffuse(n) * env_tint;
	lit += behind * edge * wrap * (0.2 + 0.6 * h) * env_strength;
	// diffusion, halo de silhouette, occlusion/ombres des accessoires
	lit += col * scatter;
	float rim_e = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 2.5);
	lit += mix(col, vec3(1.0), 0.45) * rim_e * rim_glow * h;
	vec2 oc = occlusion(base_pos, normalize(obj_n), normalize(l_obj));
	lit *= oc.x * oc.y;
	if (any(isnan(lit)) || any(isinf(lit))) { lit = col * 0.8; }
	ALBEDO = lit;
}
