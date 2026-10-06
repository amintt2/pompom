// Environnement du compagnon, facon raytracing :
//  - derriere lui : l'ecran reel (capture), vu comme un plan vertical situe a `wall_z_view` ;
//    les rayons qui partent vers l'arriere sont intersectes avec ce plan (reflets et refraction exacts).
//  - devant lui : une "piece" virtuelle (plafond, bureau, panneaux lumineux) eclairee par la
//    couleur moyenne de l'ecran, comme un vrai moniteur eclaire la piece.
uniform sampler2D env_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 env_rect = vec4(0.0, 0.0, 1.0, 1.0);  // fenetre dans la capture (uv) : xy coin, zw taille
uniform vec2 env_center = vec2(0.5, 0.5);          // centre du compagnon dans la capture (uv)
uniform float env_spread = 0.3;                    // (lumiere diffuse) portee en uv
uniform float env_strength = 1.0;
uniform float env_lods = 7.0;
uniform vec2 uv_per_unit = vec2(0.25, 0.25);       // uv de capture par unite monde
uniform float wall_z_view = -9.0;                  // profondeur (espace vue) du plan de l'ecran
uniform vec3 screen_avg = vec3(0.25, 0.25, 0.3);   // couleur moyenne de l'ecran autour
uniform float room_light = 1.0;

// ---------------------------------------------------------------- piece virtuelle (devant)
float softbox(vec3 d, vec3 axis, vec2 half_size, float soft) {
	vec3 a = normalize(axis);
	float c = dot(d, a);
	if (c <= 0.0) {
		return 0.0;
	}
	vec3 up = abs(a.y) > 0.95 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 tx = normalize(cross(up, a));
	vec3 ty = cross(a, tx);
	vec2 q = vec2(dot(d, tx), dot(d, ty)) / c;
	vec2 e = smoothstep(half_size + soft, half_size - soft * 0.3, abs(q));
	return e.x * e.y;
}

vec3 room(vec3 d, float rough) {
	float s = 0.02 + rough * 0.35;
	vec3 glow = screen_avg * 0.3;
	// plafond clair -> horizon lumineux -> bureau sombre : le contraste typique du chrome
	float y = d.y;
	vec3 sky = mix(vec3(0.5, 0.52, 0.56), vec3(0.78, 0.8, 0.84), smoothstep(0.0, 0.9, y));
	vec3 desk = mix(vec3(0.2, 0.17, 0.15), vec3(0.09, 0.08, 0.075), smoothstep(0.0, -0.7, y));
	float hb = mix(0.06, 0.25, rough);
	vec3 c = mix(desk, sky, smoothstep(-hb, hb, y));
	c += vec3(0.35) * exp(-abs(y) * mix(40.0, 6.0, rough));  // bande d'horizon
	c += glow;
	c += vec3(2.6, 2.5, 2.35) * softbox(d, vec3(-0.5, 0.62, 0.6), vec2(0.32, 0.2), s);   // lampe
	c += vec3(1.3, 1.35, 1.45) * softbox(d, vec3(0.9, 0.25, 0.35), vec2(0.06, 0.45), s); // liseré
	c += vec3(0.8) * softbox(d, vec3(0.15, 0.2, 1.0), vec2(0.45, 0.1), s * 2.0);          // fenetre
	return c * room_light;
}

// ---------------------------------------------------------------- ecran (derriere)
vec2 screen_uv_of(vec2 suv) {
	return env_rect.xy + suv * env_rect.zw;
}

// rayon (p = position vue, d = direction vue avec d.z < 0) -> couleur de l'ecran touche
vec3 screen_hit(vec2 suv, vec3 p, vec3 d, float lod) {
	float t = (wall_z_view - p.z) / min(d.z, -0.02);
	vec2 off = d.xy * t;
	vec2 uv = screen_uv_of(suv) + vec2(off.x, -off.y) * uv_per_unit;
	return textureLod(env_tex, clamp(uv, vec2(0.003), vec2(0.997)), lod).rgb;
}

// reflet complet dans une direction (rough 0..1)
vec3 env_reflect(vec2 suv, vec3 p, vec3 d, float rough) {
	float lod = rough * env_lods;
	vec3 back = screen_hit(suv, p, d, lod);
	vec3 front = room(d, rough);
	float w = smoothstep(0.12, -0.18, d.z);
	return mix(front, back, w) * env_strength;
}

// ---------------------------------------------------------------- compatibilite (lumiere diffuse)
vec3 env_dir(vec3 d, float lod) {
	vec2 uv = env_center + vec2(d.x, -d.y) * env_spread;
	vec3 c = textureLod(env_tex, clamp(uv, vec2(0.003), vec2(0.997)), lod).rgb;
	float w = smoothstep(0.6, -0.2, d.z);
	return mix(room(d, 1.0) * 0.6, c, w);
}

vec3 env_behind(vec2 suv, vec2 off, float lod) {
	vec2 uv = screen_uv_of(suv) + off;
	return textureLod(env_tex, clamp(uv, vec2(0.003), vec2(0.997)), lod).rgb;
}

float fresnel_s(float f0, vec3 n, vec3 v) {
	return f0 + (1.0 - f0) * pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 5.0);
}

vec3 env_diffuse(vec3 n) {
	vec3 c = env_dir(n, env_lods - 1.0);
	float edge = 1.0 - clamp(n.z, 0.0, 1.0) * 0.45;
	return c * edge * env_strength;
}
