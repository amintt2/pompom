// Contact avec le sol : tout ce qui passe sous le sol est ecrase a plat et s'etale (corps qui "s'assoit").
uniform float ground_y = -100.0;        // hauteur du sol (espace monde)
uniform vec3 body_center = vec3(0.0);   // centre du corps (espace monde)
uniform float contact_bulge = 0.55;     // etalement de la matiere ecrasee

vec3 apply_contact(vec3 v_obj, mat4 model) {
	vec3 w = (model * vec4(v_obj, 1.0)).xyz;
	float pen = ground_y - w.y;
	if (pen > 0.0) {
		w.y = ground_y + pen * 0.04;
		vec2 d = w.xz - body_center.xz;
		float l = length(d);
		w.xz += (l > 1e-4 ? d / l : vec2(0.0)) * pen * contact_bulge;
		return (inverse(model) * vec4(w, 1.0)).xyz;
	}
	return v_obj;
}
