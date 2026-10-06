// Matieres lisses du compagnon et des accessoires. Le mode est choisi par un #define
// dans le .gdshader qui inclut ce fichier (PLASTIC, CHROME, GLASS, JELLY, SLIME, DOUGH, WOOD, NEON).
#include "res://shaders/env.gdshaderinc"
#include "res://shaders/contact.gdshaderinc"

uniform vec3 base_color : source_color = vec3(0.9, 0.5, 0.65);
uniform float roughness = 0.3;
uniform float clearcoat = 0.8;
uniform float opacity = 0.6;      // verre/gelee : part de lumiere qui traverse
uniform float refraction = 0.05;  // (ancien parametre, garde pour compatibilite)
uniform float ior = 1.45;         // indice de refraction
uniform float dispersion = 0.02;  // ecart d'indice entre rouge et bleu (arc-en-ciel)
uniform float thickness = 0.9;    // epaisseur optique relative (absorption)
uniform float wobble = 0.0;
uniform float wobble_freq = 14.0;
uniform float emit = 0.0;
uniform float lens = 0.22;        // verre liquide : deformation sur les bords (unites monde)
uniform float frost = 0.6;        // verre liquide : depoli
uniform float glass_glow = 0.12;  // verre liquide : lueur propre (visible sur fond sombre)
// eclairage studio rendu dans Cycles (matcaps) : 0 = aucun, 1 = plastique brillant, 2 = feutre
uniform int matcap_mode = 0;
uniform sampler2D gloss_black : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D gloss_white : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D felt_tex : source_color, filter_linear_mipmap, repeat_disable;
// mode 3 : matcap Cycles de la matiere elle-meme (pate, bois, plastique), teinte par la couleur choisie
uniform sampler2D tint_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint_ref = vec3(0.8);   // albedo (lineaire) utilise pour le rendu du matcap
uniform float coat_screen = 0.25;    // reflet de l'ecran dans le vernis
uniform vec3 blush_l = vec3(100.0);
uniform vec3 blush_r = vec3(100.0);
uniform float blush_amount = 0.0;
uniform float blush_radius = 0.11;
uniform vec3 blush_color : source_color = vec3(1.0, 0.42, 0.55);

varying vec3 obj_pos;

float h31(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vn(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h31(i), h31(i + vec3(1, 0, 0)), f.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), f.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	obj_pos = VERTEX;
	float w = sin(TIME * wobble_freq + VERTEX.y * 17.0 + VERTEX.x * 7.0) * wobble * 0.025;
	VERTEX += NORMAL * w;
	VERTEX = apply_contact(VERTEX, MODEL_MATRIX);
}

// rayon refracte a travers un corps epais (entree + sortie approchee) -> couleur de l'ecran derriere
vec3 refract_screen(vec2 suv, vec3 p, vec3 n, vec3 v, float eta_ior, float lod) {
	vec3 t1 = refract(-v, n, 1.0 / eta_ior);
	if (dot(t1, t1) < 1e-4) {
		t1 = reflect(-v, n);
	}
	// face de sortie : normale ~ miroir de l'entree a travers le plan du corps (corps arrondi)
	vec3 n2 = normalize(vec3(n.x, n.y, -n.z));
	vec3 t2 = refract(t1, -n2, eta_ior);
	if (dot(t2, t2) < 1e-4) {
		t2 = t1;  // reflexion totale interne
	}
	vec3 exit_p = p + t1 * thickness * 0.6 * (0.35 + dot(n, v));
	return screen_hit(suv, exit_p, normalize(t2), lod);
}

void fragment() {
	vec3 n = normalize(NORMAL);
	vec3 v = normalize(VIEW);
	vec3 p = VERTEX;
	vec3 r = reflect(-v, n);
	vec3 base = base_color;

#if defined(DOUGH)
	float bump = vn(obj_pos * 22.0) * 0.6 + vn(obj_pos * 55.0) * 0.4;
	n = normalize(n + vec3(bump - 0.5) * 0.1);
	// farine : quelques zones legeres (le matcap Cycles porte deja l'essentiel du rendu)
	float flour = smoothstep(0.7, 0.9, vn(obj_pos * 6.0 + 3.1)) * 0.22 + smoothstep(0.8, 0.95, vn(obj_pos * 40.0)) * 0.08;
	base = mix(base, vec3(1.0, 0.98, 0.94), flour);
#endif

#if defined(WOOD)
	float ring = length(obj_pos.xz * vec2(1.0, 1.4) + vec2(0.13, 0.07)) * 26.0 + vn(obj_pos * vec3(3.0, 0.8, 3.0)) * 5.0;
	float grain = smoothstep(0.25, 0.75, fract(ring)) * 0.55 + vn(obj_pos * vec3(60.0, 4.0, 60.0)) * 0.25;
	base = mix(base * 0.62, base * 1.12, grain);
#endif

	float bd = min(length(obj_pos - blush_l), length(obj_pos - blush_r));
	base = mix(base, blush_color, (1.0 - smoothstep(blush_radius * 0.35, blush_radius, bd)) * blush_amount * 0.8);

	float ndv = clamp(dot(n, v), 0.0, 1.0);

#if defined(CHROME)
	vec3 refl = env_reflect(SCREEN_UV, p, r, roughness);
	vec3 tint = mix(base, vec3(1.0), 0.35 + 0.65 * pow(1.0 - ndv, 3.0));
	ALBEDO = vec3(0.0);
	METALLIC = 1.0;
	ROUGHNESS = roughness;
	SPECULAR = 0.0;
	EMISSION = refl * tint;
#elif defined(GLASS) || defined(JELLY) || defined(SLIME)
	float blur = roughness * 4.0;
#if defined(SLIME)
	blur += 1.6;
#endif
	vec3 behind;
	behind.r = refract_screen(SCREEN_UV, p, n, v, ior - dispersion, blur).r;
	behind.g = refract_screen(SCREEN_UV, p, n, v, ior, blur).g;
	behind.b = refract_screen(SCREEN_UV, p, n, v, ior + dispersion, blur).b;
	float path = thickness * (0.4 + 0.9 * ndv);
	vec3 absorb = exp(-(vec3(1.0) - base) * path * 2.2);
	vec3 trans = behind * absorb * opacity;
	vec3 scatter = base * (screen_avg * 0.4 + room(n, 1.0) * 0.35 + 0.08) * (1.0 - opacity * 0.6) * 1.5;
	float fr = fresnel_s(0.04, n, v);
	vec3 refl = env_reflect(SCREEN_UV, p, r, roughness * 0.6);
	vec3 inner = env_reflect(SCREEN_UV, p, reflect(refract(-v, n, 1.0 / ior), -n), 0.3) * base * 0.35;
	ALBEDO = vec3(0.0);
	ROUGHNESS = roughness;
	SPECULAR = 0.6;
	EMISSION = mix(trans + scatter + inner * (1.0 - ndv), refl, fr);
#elif defined(LIQUID)
	// "Liquid Glass" : centre net, bords qui courbent fortement l'arriere-plan vers l'interieur,
	// aberration chromatique, liseré lumineux, lueur adaptative pour rester lisible sur fond sombre.
	float rim = 1.0 - ndv;
	vec2 dir2 = n.xy / max(length(n.xy), 1e-4);
	float bend = pow(rim, 2.2) * lens;
	vec2 off = -vec2(dir2.x, -dir2.y) * bend * uv_per_unit;
	float lod = frost * (0.3 + 2.2 * rim);
	vec3 bg;
	bg.r = env_behind(SCREEN_UV, off * 1.08, lod).r;
	bg.g = env_behind(SCREEN_UV, off, lod).g;
	bg.b = env_behind(SCREEN_UV, off * 0.92, lod).b;
	float lum = dot(bg, vec3(0.299, 0.587, 0.114));
	bg = max(mix(vec3(lum), bg, 1.3), vec3(0.0));  // vibrance
	float bg_avg = dot(screen_avg, vec3(0.299, 0.587, 0.114));
	vec3 tint = mix(vec3(1.0), base, 0.35);
	// lueur adaptative : plus forte quand le fond est sombre
	float lift = glass_glow * (0.45 + 1.4 * (1.0 - bg_avg));
	vec3 body_col = bg * tint * (1.0 + 0.25 * (1.0 - bg_avg)) + tint * lift * (0.4 + 0.6 * rim);
	// liseré speculaire : fin trait le long du contour, fort en haut a gauche, rebond en bas a droite
	float edge_line = smoothstep(0.62, 0.9, rim) * (1.0 - smoothstep(0.93, 1.0, rim));
	float key_side = pow(clamp(dot(dir2, normalize(vec2(-0.6, 0.8))), 0.0, 1.0), 2.0);
	float back_side = pow(clamp(dot(dir2, normalize(vec2(0.7, -0.7))), 0.0, 1.0), 3.0);
	vec3 rim_light = vec3(1.0) * edge_line * (0.25 + 1.1 * key_side + 0.45 * back_side);
	// grand reflet doux de la piece + petit point brillant
	float fr3 = fresnel_s(0.04, n, v);
	vec3 refl3 = env_reflect(SCREEN_UV, p, r, 0.08) * fr3 * 0.7;
	float spot = pow(clamp(dot(r, normalize(vec3(-0.45, 0.65, 0.6))), 0.0, 1.0), 220.0) * 1.2;
	ALBEDO = vec3(0.0);
	ROUGHNESS = 0.05;
	SPECULAR = 0.3;
	EMISSION = body_col + rim_light * mix(vec3(1.0), tint, 0.3) + refl3 + vec3(spot);
#elif defined(NEON)
	ALBEDO = base * 0.25;
	ROUGHNESS = 0.4;
	float rim = pow(1.0 - ndv, 2.0);
	EMISSION = base * (1.3 + emit) * (0.65 + 0.6 * rim) + env_reflect(SCREEN_UV, p, r, 0.3) * fresnel_s(0.04, n, v) * 0.6;
#else
	if (matcap_mode > 0) {
		// "rendu Blender" : la lumiere vient des matcaps Cycles ; l'ecran ajoute ses reflets
		vec2 muv = vec2(n.x, -n.y) * 0.5 + 0.5;
		vec3 outc;
		if (matcap_mode == 3) {
			// lumiere Cycles (diffusion sous la surface, vernis...) normalisee puis teintee
			vec3 mc = texture(tint_tex, muv).rgb;
			outc = mc / max(tint_ref, vec3(0.02)) * base;
		} else if (matcap_mode == 2) {
			vec3 felt = texture(felt_tex, muv).rgb;
			outc = base * felt * 1.35;
		} else {
			vec3 mb = texture(gloss_black, muv).rgb;
			vec3 mw = texture(gloss_white, muv).rgb;
			outc = base * max(mw - mb, vec3(0.0)) + mb;
		}
		float frm = fresnel_s(0.04, n, v);
		vec3 scr = env_reflect(SCREEN_UV, p, r, max(roughness, 0.1));
		outc += scr * frm * (matcap_mode == 2 ? 0.08 : (matcap_mode == 3 ? coat_screen : 0.35)) * env_strength;
		outc += env_diffuse(n) * base * 0.12;
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		EMISSION = outc + base * emit;
	} else {
	ALBEDO = base;
	ROUGHNESS = max(roughness, 0.35);
	SPECULAR = 0.35;
	float fr2 = fresnel_s(0.04, n, v);
	vec3 coat = env_reflect(SCREEN_UV, p, r, roughness);
	EMISSION = env_diffuse(n) * base * 0.4 + coat * fr2 * clearcoat * 1.4 + base * emit;
	}
#endif

#if defined(DOUGH) || defined(PLASTIC) || defined(WOOD)
	NORMAL = n;
#endif
}
