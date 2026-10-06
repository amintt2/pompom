// Occlusion analytique : accessoires et yeux = spheres douces qui assombrissent la fourrure autour
// (occlusion ambiante) et projettent une ombre douce dans la direction de la lumiere principale.
// Pas de shadow map -> aucun grain.
uniform vec4 occ[8];        // xyz = centre (espace du corps), w = rayon
uniform int occ_count = 0;
uniform float occ_ao = 0.6;
uniform float occ_shadow = 0.55;

// p, n : position / normale (espace du corps) ; l : direction vers la lumiere (espace du corps)
vec2 occlusion(vec3 p, vec3 n, vec3 l) {
	float ao = 1.0;
	float sh = 1.0;
	for (int i = 0; i < 8; i++) {
		if (i >= occ_count) {
			break;
		}
		vec3 c = occ[i].xyz;
		float r = occ[i].w;
		vec3 d = c - p;
		float dl = length(d);
		// occlusion d'une sphere vue depuis un point de normale n
		float nd = clamp(dot(n, d / max(dl, 1e-4)), 0.0, 1.0);
		ao *= 1.0 - clamp(nd * (r * r) / max(dl * dl, 1e-4), 0.0, 1.0) * occ_ao;
		// ombre douce : distance entre le rayon lumineux et le centre, penombre qui s'elargit avec la distance
		float t = dot(d, l);
		if (t > 0.0) {
			float hdist = length(d - l * t);
			float pen = r * 0.35 + t * 0.45;
			sh *= mix(1.0, smoothstep(r - pen, r + pen, hdist), occ_shadow);
		}
	}
	return vec2(ao, sh);
}
