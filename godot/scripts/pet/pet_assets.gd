class_name PetAssets
## Chargement des modeles .glb (generes par Blender) et fabrication des materiaux.
## Chaque compagnon possede ses propres ShaderMaterial (liste `registry`) pour recevoir
## la capture d'ecran de son environnement (reflets / refraction).

const FUR_SHADER := preload("res://shaders/fur.gdshader")
const SPLAT_SHADER := preload("res://shaders/fur_splat.gdshader")
const STRAND_SHADER := preload("res://shaders/fur_strands.gdshader")
const FUR_MATCAP_PATH := "res://assets/textures/fur_matcap.png"
const SURFACE_SHADERS := {
	"plastic": preload("res://shaders/surface_plastic.gdshader"),
	"chrome": preload("res://shaders/surface_chrome.gdshader"),
	"glass": preload("res://shaders/surface_glass.gdshader"),
	"jelly": preload("res://shaders/surface_jelly.gdshader"),
	"slime": preload("res://shaders/surface_slime.gdshader"),
	"dough": preload("res://shaders/surface_dough.gdshader"),
	"wood": preload("res://shaders/surface_wood.gdshader"),
	"neon": preload("res://shaders/surface_neon.gdshader"),
	"liquid": preload("res://shaders/surface_liquid.gdshader"),
	"envmatte": preload("res://shaders/surface_envmatte.gdshader"),
}
const MODEL_FILES := {
	"bodies": "res://assets/models/bodies.glb",
	"face": "res://assets/models/face.glb",
	"accessories": "res://assets/models/accessories.glb",
	"props": "res://assets/models/props.glb",
}

static var _roots := {}
static var _glint: StandardMaterial3D
static var _studio_env: Texture2D
static var _splat_cache := {}
static var _strand_cache := {}
static var _fur_matcap: Texture2D
static var fur_matcap_gain := 1.0
static var _matcaps := {}
## Accessoires en tissu (eclairage "feutre")
const FELT_ITEMS := ["beret", "beanie", "santa", "bucket_hat", "witch", "wizard", "cap", "bandana", "scarf", "cape", "sailor", "chef", "cowboy", "pirate", "grad_cap", "backpack"]


static func _root(file: String) -> Node:
	if not _roots.has(file):
		var ps: PackedScene = load(MODEL_FILES[file])
		_roots[file] = ps.instantiate()
	return _roots[file]


static func has_node_named(file: String, node_name: String) -> bool:
	return _root(file).find_child(node_name, true, false) != null


## Copie d'un noeud (et de ses enfants) d'un .glb.
static func copy(file: String, node_name: String) -> Node3D:
	var n := _root(file).find_child(node_name, true, false)
	if n == null:
		push_warning("modele introuvable : %s/%s" % [file, node_name])
		return Node3D.new()
	var d: Node3D = n.duplicate()
	if file == "accessories" or file == "props":
		d.transform = Transform3D.IDENTITY
	return d


static func material_name(mi: MeshInstance3D) -> String:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return ""
	var m := mi.mesh.surface_get_material(0)
	if m == null:
		return ""
	return m.resource_name


## Environnement "studio" (boutique, mobile) : degrade doux clair en haut, chaud en bas.
static func studio_env() -> Texture2D:
	if _studio_env:
		return _studio_env
	var img := Image.create(64, 64, true, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var t := float(y) / 63.0
			var c := Color("f4f1ff").lerp(Color("ffe2ec"), smoothstep(0.3, 1.0, t))
			var d := Vector2(x - 32, y - 20).length() / 40.0
			c = c.lerp(Color(1, 1, 1), clampf(1.0 - d, 0.0, 1.0) * 0.6)
			c = c.darkened(smoothstep(0.75, 1.0, t) * 0.25)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	_studio_env = ImageTexture.create_from_image(img)
	return _studio_env


static func _register(m: ShaderMaterial, registry: Array) -> ShaderMaterial:
	m.set_shader_parameter("env_tex", studio_env())
	registry.append(m)
	return m


static func matcap(name_: String) -> Texture2D:
	if not _matcaps.has(name_):
		var path := "res://assets/textures/%s.png" % name_
		_matcaps[name_] = load(path) if ResourceLoader.exists(path) else null
	return _matcaps[name_]


## Matieres transparentes rendues par environment matting (cartes Cycles) : kind -> prefixe des cartes.
const ENVMATTE := {"jelly": "gelee", "slime": "slime", "liquid": "verre", "glass": "verre"}
## Matieres opaques avec matcap Cycles dedie : kind -> [texture, albedo de reference (sRGB)].
const TINT_MATCAPS := {
	"dough": ["mat_pate_matcap", Color(0.8, 0.8, 0.8)],
	"wood": ["mat_bois_matcap", Color("8a5a36")],
}


static func envmatte_material(prefix: String, color: Color, params: Dictionary, registry: Array) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADERS["envmatte"]
	for k in ["self", "trans", "refr", "scat", "aux"]:
		m.set_shader_parameter("em_" + k, matcap("mat_%s_%s" % [prefix, k]))
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("dispersion", 0.015 if prefix == "verre" else 0.0)
	m.set_shader_parameter("tint_strength", 0.35 if prefix == "verre" else 1.0)
	for k in params:
		if k in ["wobble", "pet_radius", "refr_scale", "self_gain"]:
			m.set_shader_parameter(k, params[k])
	return _register(m, registry)


static func surface_material(kind: String, color: Color, params: Dictionary, registry: Array, felt := false) -> ShaderMaterial:
	if ENVMATTE.has(kind) and matcap("mat_%s_refr" % ENVMATTE[kind]) != null:
		return envmatte_material(ENVMATTE[kind], color, params, registry)
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADERS.get(kind, SURFACE_SHADERS["plastic"])
	m.set_shader_parameter("base_color", color)
	if kind == "plastic" and matcap("gloss_black_matcap") and matcap("gloss_white_matcap"):
		m.set_shader_parameter("gloss_black", matcap("gloss_black_matcap"))
		m.set_shader_parameter("gloss_white", matcap("gloss_white_matcap"))
		m.set_shader_parameter("felt_tex", matcap("felt_matcap"))
		m.set_shader_parameter("matcap_mode", 2 if (felt and matcap("felt_matcap")) else 1)
	if TINT_MATCAPS.has(kind) and matcap(TINT_MATCAPS[kind][0]):
		var ref: Color = (TINT_MATCAPS[kind][1] as Color).srgb_to_linear()
		m.set_shader_parameter("tint_tex", matcap(TINT_MATCAPS[kind][0]))
		m.set_shader_parameter("tint_ref", Vector3(ref.r, ref.g, ref.b))
		m.set_shader_parameter("matcap_mode", 3)
		m.set_shader_parameter("coat_screen", 0.4 if kind == "wood" else 0.12)
	for k in params:
		m.set_shader_parameter(k, params[k])
	return _register(m, registry)


static func glint_material() -> StandardMaterial3D:
	if _glint == null:
		_glint = StandardMaterial3D.new()
		_glint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_glint.albedo_color = Color(1, 1, 1)
	return _glint


static func fixed_material(mname: String, registry: Array) -> Material:
	if mname == "glint":
		return glint_material()
	if mname == "clear_glass" or mname == "glass":
		# verres de lunettes : vraie transparence 3D (on voit les yeux derriere) + reflets nets
		var g := StandardMaterial3D.new()
		g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		g.albedo_color = Color(0.92, 0.96, 1.0, 0.1) if mname == "clear_glass" else Color(0.06, 0.05, 0.09, 0.82)
		g.roughness = 0.04
		g.metallic_specular = 1.0
		g.rim_enabled = true
		g.rim = 0.4
		g.cull_mode = BaseMaterial3D.CULL_DISABLED
		return g
	var fm: Dictionary = Data.FIXED_MATS.get(mname, {})
	if fm.is_empty():
		return null
	var p := {"roughness": float(fm.get("rough", 0.4))}
	if fm.has("opacity"):
		p["opacity"] = fm["opacity"]
	return surface_material(fm["kind"], Color.html(fm["color"]), p, registry)


## Coques de fourrure sur une MeshInstance3D (+ couche de splats gaussiens si splats > 0).
static func apply_fur(mi: MeshInstance3D, color: Color, fur_length: float, density: float, shells: int,
		registry: Array, sheen := 0.0, splats := 0, strands := 0) -> Array[ShaderMaterial]:
	var mats: Array[ShaderMaterial] = []
	shells = maxi(shells, 2)
	for c in mi.get_children():
		if c.name.begins_with("shell_") or c.name == "splats" or c.name == "strands":
			c.free()
	for i in shells:
		var m := ShaderMaterial.new()
		m.shader = FUR_SHADER
		m.set_shader_parameter("shell_h", float(i) / float(shells - 1))
		m.set_shader_parameter("fur_length", fur_length)
		m.set_shader_parameter("density", density)
		m.set_shader_parameter("sheen", sheen)
		_register(m, registry)
		mats.append(m)
		if i == 0:
			mi.material_override = m
		else:
			var s := MeshInstance3D.new()
			s.name = "shell_%d" % i
			s.mesh = mi.mesh
			s.material_override = m
			s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.add_child(s)
	if splats > 0:
		mats.append(_make_splats(mi, fur_length, splats, registry))
	if strands > 0:
		mats.append(_make_strands(mi, fur_length * 1.05, strands, registry))
	var mc := fur_matcap()
	for m in mats:
		m.set_shader_parameter("fur_matcap", mc)
		m.set_shader_parameter("matcap_gain", fur_matcap_gain)
	set_fur_color(mats, color)
	return mats


## Matcap de fourrure (rendu Cycles) ; a defaut, un matcap studio calcule.
static func fur_matcap() -> Texture2D:
	if _fur_matcap:
		return _fur_matcap
	if ResourceLoader.exists(FUR_MATCAP_PATH):
		_fur_matcap = load(FUR_MATCAP_PATH)
		# normalisation : la zone la plus eclairee du matcap doit valoir ~1 (sinon tout s'assombrit)
		var img := _fur_matcap.get_image()
		if img:
			if img.is_compressed():
				img.decompress()
			var lums: Array[float] = []
			var w := img.get_width()
			for i in 400:
				var x := int(w * (0.18 + 0.4 * fmod(i * 0.618, 1.0)))
				var y := int(w * (0.18 + 0.4 * fmod(i * 0.381, 1.0)))
				lums.append(img.get_pixel(x, y).srgb_to_linear().get_luminance())
			lums.sort()
			var p90 := lums[int(lums.size() * 0.9)]
			fur_matcap_gain = clampf(0.98 / maxf(p90, 0.05), 0.8, 2.5)
		return _fur_matcap
	var n := 128
	var img := Image.create(n, n, true, Image.FORMAT_RGBA8)
	var key := Vector3(-0.45, 0.6, 0.66).normalized()
	var fill := Vector3(0.7, 0.1, 0.7).normalized()
	for y in n:
		for x in n:
			var px := (x + 0.5) / n * 2.0 - 1.0
			var py := -((y + 0.5) / n * 2.0 - 1.0)
			var r2 := px * px + py * py
			var nz := sqrt(maxf(0.0, 1.0 - minf(r2, 1.0)))
			var nn := Vector3(px, py, nz)
			var d := pow(clampf(nn.dot(key) * 0.5 + 0.5, 0.0, 1.0), 1.6)
			var f := clampf(nn.dot(fill) * 0.5 + 0.5, 0.0, 1.0) * 0.25
			var rim := pow(1.0 - nz, 2.5) * 0.35
			var v := 0.22 + d * 0.85 + f + rim
			img.set_pixel(x, y, Color(v, v * 0.99, v * 1.01))
	img.generate_mipmaps()
	_fur_matcap = ImageTexture.create_from_image(img)
	return _fur_matcap


## Brins de poils geometriques (courbes de 3 segments) repartis sur la surface.
static func _make_strands(mi: MeshInstance3D, fur_length: float, count: int, registry: Array) -> ShaderMaterial:
	var key := "%d_%d_%.3f" % [mi.mesh.get_rid().get_id(), count, fur_length]
	var mesh: ArrayMesh = _strand_cache.get(key)
	if mesh == null:
		mesh = _build_strand_mesh(mi.mesh, fur_length, count)
		_strand_cache[key] = mesh
	var si := MeshInstance3D.new()
	si.name = "strands"
	si.mesh = mesh
	si.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	si.custom_aabb = mi.get_aabb().grow(fur_length * 3.0)
	var m := ShaderMaterial.new()
	m.shader = STRAND_SHADER
	_register(m, registry)
	si.material_override = m
	mi.add_child(si)
	return m


static func _build_strand_mesh(src: Mesh, fur_length: float, count: int) -> ArrayMesh:
	var samples := _sample_surface(src, count)
	const SEGS := 3
	var nv := count * (SEGS + 1) * 2
	var verts := PackedVector3Array()
	verts.resize(nv)
	var norms := PackedVector3Array()
	norms.resize(nv)
	var tans := PackedFloat32Array()
	tans.resize(nv * 4)
	var uvs := PackedVector2Array()
	uvs.resize(nv)
	var uv2s := PackedVector2Array()
	uv2s.resize(nv)
	var idx := PackedInt32Array()
	idx.resize(count * SEGS * 6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	# touffes : des centres repartis sur la surface ; chaque poil penche sa pointe vers sa touffe
	var clump_n := maxi(64, count / 14)
	var clumps := _sample_surface(src, clump_n)
	var cell := fur_length * 1.6
	var grid := {}
	for c in clump_n:
		var cp := Vector3(clumps[c * 16 + 3], clumps[c * 16 + 7], clumps[c * 16 + 11])
		var key := Vector3i((cp / cell).floor())
		if not grid.has(key):
			grid[key] = []
		grid[key].append(cp)
	var vi := 0
	var ii := 0
	for s in count:
		var o := s * 16
		var root := Vector3(samples[o + 3], samples[o + 7], samples[o + 11])
		var n := Vector3(samples[o + 12] * 2.0 - 1.0, samples[o + 13] * 2.0 - 1.0, samples[o + 14] * 2.0 - 1.0).normalized()
		var r := samples[o + 15]
		var jitter := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.75
		var d := (n + jitter - n * jitter.dot(n)).normalized()
		var length := fur_length * rng.randf_range(0.65, 1.25)
		# touffe la plus proche
		var ck := Vector3i((root / cell).floor())
		var best := root
		var bd := INF
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var lst = grid.get(ck + Vector3i(dx, dy, dz))
					if lst == null:
						continue
					for cp2 in lst:
						var dd: float = root.distance_squared_to(cp2)
						if dd < bd:
							bd = dd
							best = cp2
		var to_clump := (best - root) * 0.55
		var curl := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * 0.5
		for k in SEGS + 1:
			var t := float(k) / SEGS
			var p := root + d * length * t + (Vector3(0, -0.1, 0) + curl) * length * t * t + to_clump * t * t
			var tg := (d + (Vector3(0, -0.1, 0) + curl) * 2.0 * t + to_clump * 2.0 * t / maxf(length, 1e-4)).normalized()
			for side in [-1.0, 1.0]:
				verts[vi] = p
				norms[vi] = tg
				tans[vi * 4] = n.x
				tans[vi * 4 + 1] = n.y
				tans[vi * 4 + 2] = n.z
				tans[vi * 4 + 3] = 1.0
				uvs[vi] = Vector2(side, t)
				uv2s[vi] = Vector2(r, length)
				vi += 1
		var base := s * (SEGS + 1) * 2
		for k in SEGS:
			var a := base + k * 2
			idx[ii] = a
			idx[ii + 1] = a + 1
			idx[ii + 2] = a + 2
			idx[ii + 3] = a + 1
			idx[ii + 4] = a + 3
			idx[ii + 5] = a + 2
			ii += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TANGENT] = tans
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Splats gaussiens repartis sur la surface (ponderes par l'aire des triangles).
static func _make_splats(mi: MeshInstance3D, fur_length: float, count: int, registry: Array) -> ShaderMaterial:
	var key := "%s_%d" % [mi.mesh.resource_path + str(mi.mesh.get_rid().get_id()), count]
	var buf: PackedFloat32Array
	if _splat_cache.has(key):
		buf = _splat_cache[key]
	else:
		buf = _sample_surface(mi.mesh, count)
		_splat_cache[key] = buf
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mm.mesh = q
	mm.instance_count = count
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "splats"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = mi.get_aabb().grow(fur_length * 3.0)
	var m := ShaderMaterial.new()
	m.shader = SPLAT_SHADER
	m.set_shader_parameter("fur_length", fur_length)
	m.render_priority = 100
	_register(m, registry)
	mmi.material_override = m
	mi.add_child(mmi)
	return m


static func _sample_surface(mesh: Mesh, count: int) -> PackedFloat32Array:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(verts.size())
		for i in verts.size():
			idx[i] = i
	var tris := idx.size() / 3
	var cum := PackedFloat32Array()
	cum.resize(tris)
	var total := 0.0
	for t in tris:
		var a := verts[idx[t * 3]]
		var b := verts[idx[t * 3 + 1]]
		var c := verts[idx[t * 3 + 2]]
		total += (b - a).cross(c - a).length() * 0.5
		cum[t] = total
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var buf := PackedFloat32Array()
	buf.resize(count * 16)
	for i in count:
		var t2 := mini(cum.bsearch(rng.randf() * total), tris - 1)
		var r1 := sqrt(rng.randf())
		var r2 := rng.randf()
		var w0 := 1.0 - r1
		var w1 := r1 * (1.0 - r2)
		var w2 := r1 * r2
		var i0 := idx[t2 * 3]
		var i1 := idx[t2 * 3 + 1]
		var i2 := idx[t2 * 3 + 2]
		var p := verts[i0] * w0 + verts[i1] * w1 + verts[i2] * w2
		var n := (norms[i0] * w0 + norms[i1] * w1 + norms[i2] * w2).normalized()
		var o := i * 16
		buf[o] = 1.0
		buf[o + 3] = p.x
		buf[o + 5] = 1.0
		buf[o + 7] = p.y
		buf[o + 10] = 1.0
		buf[o + 11] = p.z
		buf[o + 12] = n.x * 0.5 + 0.5
		buf[o + 13] = n.y * 0.5 + 0.5
		buf[o + 14] = n.z * 0.5 + 0.5
		buf[o + 15] = rng.randf()
	return buf


static func set_fur_color(mats: Array, color: Color) -> void:
	# couleurs vives : racine a peine plus sombre et plus saturee, pointe a peine plus claire
	var root := Color.from_hsv(color.h, minf(1.0, color.s * 1.12), color.v * 0.9)
	var tip := Color.from_hsv(color.h, color.s * 0.9, minf(1.0, color.v * 1.06))
	for m in mats:
		m.set_shader_parameter("root_color", root)
		m.set_shader_parameter("tip_color", tip)
		m.set_shader_parameter("base_color", color)


static func set_param(mats: Array, param: String, value) -> void:
	for m in mats:
		m.set_shader_parameter(param, value)


## Accessoire colorie. colors = {"main", "accent", "detail"} (Color).
static func make_item(item_id: String, colors: Dictionary, shells: int, registry: Array) -> Node3D:
	var node := copy("accessories", item_id)
	node.name = item_id
	_colorize(node, colors, shells, registry, FELT_ITEMS.has(item_id))
	return node


static func _colorize(n: Node, colors: Dictionary, shells: int, registry: Array, felt := false) -> void:
	for c in n.get_children():
		_colorize(c, colors, shells, registry, felt)
	if not (n is MeshInstance3D):
		return
	var mi: MeshInstance3D = n
	var mname := material_name(mi)
	match mname:
		"main", "accent", "detail":
			var col: Color = colors.get(mname, Color.WHITE)
			mi.material_override = surface_material("plastic", col, {"roughness": 0.42, "clearcoat": 0.35}, registry, felt)
		"fur_main":
			apply_fur(mi, colors.get("main", Color.WHITE), 0.022, 170.0, shells, registry)
		"fur_accent":
			apply_fur(mi, colors.get("accent", Color.WHITE), 0.022, 170.0, shells, registry)
		_:
			var m := fixed_material(mname, registry)
			if m:
				mi.material_override = m


## Piece du visage (yeux, bouche...). iris = couleur des iris personnalisable.
static func make_face_part(node_name: String, iris: Color, registry: Array) -> Node3D:
	var node := copy("face", node_name)
	for mi in [node] + node.find_children("*", "MeshInstance3D", true, false):
		if mi is MeshInstance3D:
			var mname := material_name(mi)
			if mname == "iris":
				mi.material_override = surface_material("plastic", iris, {"roughness": 0.1, "clearcoat": 1.0}, registry)
			else:
				var m := fixed_material(mname, registry)
				mi.material_override = m if m else fixed_material("eye_black", registry)
	return node


static func make_prop(prop_id: String, registry: Array) -> Node3D:
	var node := copy("props", prop_id)
	_colorize(node, {"main": Color.html("f7f4ee"), "accent": Color.html("ff7eb3"), "detail": Color.html("7cc8ff")}, 4, registry)
	return node
