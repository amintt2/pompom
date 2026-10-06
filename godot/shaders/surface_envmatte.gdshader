// Matieres transparentes "rendu Cycles" par ENVIRONMENT MATTING (Zongker et al. 1999).
// Cycles a rendu une sphere de la matiere 3 fois (fond noir, fond blanc, fond code par coordonnees) ;
// on en a tire, pour chaque normale :
//   self  : lumiere propre (reflets studio, diffusion interne)
//   trans : quantite de fond transmise (par canal)
//   refr  : ou le rayon refracte touche le fond (couche nette) + debit
//   scat  : position moyenne + etalement de la couche diffusee
//   aux   : longueur optique (pour teinter), etalement de la couche nette
// Ici on recompose ces cartes sur la VRAIE capture de l'ecran derriere le compagnon :
//   C = self + Tp * Fond(Pp) + max(trans - Tp, 0) * Fond_flou(Ps)
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded, shadows_disabled;
#include "res://shaders/env.gdshaderinc"
#include "res://shaders/contact.gdshaderinc"

uniform sampler2D em_self : source_color, filter_linear, repeat_disable;
uniform sampler2D em_trans : hint_default_white, filter_linear, repeat_disable;
uniform sampler2D em_refr : filter_linear, repeat_disable;
uniform sampler2D em_scat : filter_linear, repeat_disable;
uniform sampler2D em_aux : filter_linear, repeat_disable;

uniform vec3 base_color : source_color = vec3(1.0);
uniform float tint_strength = 1.0;     // 0 = couleur des cartes, 1 = teinte complete
uniform float pet_radius = 0.55;       // demi-epaisseur du compagnon (unites monde)
uniform float refr_scale = 1.0;
uniform float dispersion = 0.0;        // franges arc-en-ciel (verre)
uniform float self_gain = 1.0;
uniform float wobble = 0.0;
uniform float wobble_freq = 14.0;
uniform vec3 blush_l = vec3(100.0);
uniform vec3 blush_r = vec3(100.0);
uniform float blush_amount = 0.0;
uniform float blush_radius = 0.11;
uniform vec3 blush_color : source_color = vec3(1.0, 0.42, 0.55);

varying vec3 obj_pos;

void vertex() {
	obj_pos = VERTEX;
	float w = sin(TIME * wobble_freq + VERTEX.y * 17.0 + VERTEX.x * 7.0) * wobble * 0.025;
	VERTEX += NORMAL * w;
	VERTEX = apply_contact(VERTEX, MODEL_MATRIX);
}

// fond (capture de l'ecran) decale de `off` (unites de la sphere) et floute de `spread`
vec3 bg(vec2 suv, vec2 off, float spread) {
	vec2 off_uv = vec2(off.x, -off.y) * pet_radius * uv_per_unit * refr_scale;
	float blur_uv = spread * pet_radius * max(uv_per_unit.x, uv_per_unit.y);
	float lod = log2(max(blur_uv * 256.0, 1.0));
	return env_behind(suv, off_uv, lod);
}

void fragment() {
	vec3 n = normalize(NORMAL);
	vec2 muv = vec2(n.x, -n.y) * 0.5 + 0.5;
	vec4 sf = texture(em_self, muv);
	vec3 T = texture(em_trans, muv).rgb;
	vec3 rf = texture(em_refr, muv).rgb;
	vec3 sc = texture(em_scat, muv).rgb;
	vec3 ax = texture(em_aux, muv).rgb;
	vec2 S = n.xy;                      // point "tout droit" sur le plan
	vec2 Pp = rf.rg * 12.0 - 6.0;       // impact du rayon refracte (couche nette)
	float Tp = rf.b;
	vec2 Ps = sc.rg * 12.0 - 6.0;       // impact moyen (couche diffusee)
	float ss = sc.b * 4.0;
	float sp = ax.g * 2.0;
	float L = ax.r * 4.0;               // longueur optique

	// teinte : absorption de Beer-Lambert pour atteindre la couleur choisie a 1 unite d'epaisseur
	vec3 sigma = -log(clamp(base_color, vec3(0.02), vec3(1.0)));
	vec3 absorb = exp(-sigma * 0.5 * L * tint_strength);

	vec3 prim;
	if (dispersion > 0.0) {
		prim.r = bg(SCREEN_UV, (Pp - S) * (1.0 + dispersion), sp).r;
		prim.g = bg(SCREEN_UV, Pp - S, sp).g;
		prim.b = bg(SCREEN_UV, (Pp - S) * (1.0 - dispersion), sp).b;
	} else {
		prim = bg(SCREEN_UV, Pp - S, sp);
	}
	vec3 sec = bg(SCREEN_UV, Ps - S, ss);
	vec3 selfc = sf.rgb * self_gain * mix(vec3(1.0), sqrt(base_color), 0.7 * tint_strength);
	vec3 col = selfc + Tp * absorb * prim + max(T - vec3(Tp), vec3(0.0)) * absorb * sec;

	float bd = min(length(obj_pos - blush_l), length(obj_pos - blush_r));
	col = mix(col, blush_color * 0.9, (1.0 - smoothstep(blush_radius * 0.35, blush_radius, bd)) * blush_amount * 0.5);
	if (any(isnan(col)) || any(isinf(col))) {
		col = base_color * 0.5;
	}
	ALBEDO = col;
}
