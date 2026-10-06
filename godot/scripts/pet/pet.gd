class_name Pet
extends Node3D
## Le compagnon : corps (fourrure ou matiere lisse), visage expressif, accessoires,
## physique "molle" a ressorts (selon la matiere) et animations procedurales.
## Les actions act_* sont des coroutines interruptibles : une nouvelle action annule la precedente.

signal emote(kind: String, count: int)
signal said(text: String)

# --- pose (animee par des Tween) ---
var hop := 0.0
var squash := 0.0
var lean := 0.0
var yaw := 0.0
var pitch := 0.0
var spin := 0.0
var shake := 0.0
var breath_amp := 1.0
var look := Vector2.ZERO  # cible du regard (-1..1)

# --- identite ---
var species_id := ""
var material_id := "peluche"
var eye_style := "dot"
var mouth_style := "smile"
var anchors := {}
var height := 1.0
var width := 1.0
var skin := 0.05  # epaisseur de la fourrure (0.01 pour les matieres lisses)
var shells := 16
var sleeping := false
var busy := false
var carried := false  # tenu par la souris
var airborne := false  # en l'air (porte / en chute) : pas de contact avec le sol
var ground_level := 0.0  # hauteur du sol (espace monde)
var expression := "neutral"
var base_expression := "neutral"

# --- noeuds ---
var root_node: Node3D
var squash_node: Node3D
var body: MeshInstance3D
var contact: MeshInstance3D  # ombre de contact gaussienne
var body_mats: Array = []
var slot_nodes := {}
var slot_items := {}
var props := {}

# --- physique (ressorts) ---
var phys := {}
var _sq := 0.0
var _sq_v := 0.0
var _sh := Vector2.ZERO
var _sh_v := Vector2.ZERO
var _sw := 0.0
var _sw_v := 0.0
var _plastic := 0.0
var _ripple := 0.0

# --- materiaux qui recoivent l'environnement ---
var _env_base: Array = []
var _env_slots := {}  # slot -> Array
var _env_props: Array = []
var _env_state := {}

var _eyes := []
var _brows: Array[Node3D] = []
var _mouth := {}
var _mouth_root: Node3D
var _pupil_range := Vector2(0.03, 0.025)
var _eye_sy := 1.0
var _look_cur := Vector2.ZERO
var _blink_t := 2.5
var _blink := 0.0
var _expr_timer := 0.0
var _blush := 0.35
var _blush_target := 0.35
var _act := 0
var _tweens: Array[Tween] = []
var _t := 0.0
var _last_hop := 0.0
var _anim_parts := []  # [{node, kind, base: Basis, sign}]
var _happy_spin := 5.0

const EXPR := {
	"neutral": {"eyes": "open", "sy": 1.0, "brows": "", "mouth": "smile", "ms": 1.0, "blush": 0.35},
	"happy": {"eyes": "happy", "sy": 1.0, "brows": "", "mouth": "smile", "ms": 1.3, "blush": 0.75},
	"love": {"eyes": "happy", "sy": 1.0, "brows": "", "mouth": "smile", "ms": 1.45, "blush": 1.0},
	"sleep": {"eyes": "closed", "sy": 1.0, "brows": "", "mouth": "flat", "ms": 0.7, "blush": 0.3},
	"angry": {"eyes": "open", "sy": 0.75, "brows": "angry", "mouth": "frown", "ms": 1.0, "blush": 0.0},
	"sad": {"eyes": "open", "sy": 0.9, "brows": "sad", "mouth": "frown", "ms": 0.9, "blush": 0.15},
	"surprised": {"eyes": "open", "sy": 1.25, "brows": "", "mouth": "o", "ms": 1.0, "blush": 0.3},
	"focused": {"eyes": "open", "sy": 0.68, "brows": "", "mouth": "flat", "ms": 0.8, "blush": 0.25},
	"meh": {"eyes": "open", "sy": 0.55, "brows": "", "mouth": "flat", "ms": 0.9, "blush": 0.15},
	"dizzy": {"eyes": "closed", "sy": 1.0, "brows": "sad", "mouth": "o", "ms": 0.8, "blush": 0.2},
}


# =========================================================================== construction
## Construit (ou reconstruit) tout le compagnon.
func build(p_species: String, color: Color, p_material := "peluche", p_eyes := "", p_mouth := "smile",
		iris := Color("6fb1f2"), p_shells := 16) -> void:
	species_id = p_species
	material_id = p_material if Data.MATERIALS.has(p_material) else "peluche"
	shells = p_shells
	anchors = Data.anchors(species_id)
	var sp: Dictionary = Data.SPECIES[species_id]
	var mat: Dictionary = Data.MATERIALS[material_id]
	phys = mat["phys"]
	height = float(anchors.get("height", 1.0))
	width = float(anchors.get("width", 1.0))
	eye_style = p_eyes if p_eyes != "" else str(anchors.get("eye_style", "dot"))
	mouth_style = p_mouth

	for c in get_children():
		c.free()
	_eyes.clear()
	_brows.clear()
	_mouth.clear()
	slot_nodes.clear()
	slot_items.clear()
	props.clear()
	_anim_parts.clear()
	_env_base.clear()
	_env_slots.clear()
	_env_props.clear()

	root_node = Node3D.new()
	root_node.name = "Root"
	add_child(root_node)
	squash_node = Node3D.new()
	squash_node.name = "Squash"
	root_node.add_child(squash_node)

	body = PetAssets.copy("bodies", "body_" + species_id) as MeshInstance3D
	body.transform = Transform3D.IDENTITY
	squash_node.add_child(body)
	if mat["kind"] == "fur":
		skin = float(sp.get("fur_length", 0.05)) * float(mat.get("fur_scale", 1.0))
		# sous-poil en couches + vrais brins pour la fibre et la silhouette
		var strands := 16000 if shells < 10 else (34000 if shells < 14 else (56000 if shells < 24 else 80000))
		strands = int(strands * float(mat.get("fur_scale", 1.0)) ** 0.5)
		var under_shells := maxi(6, int(shells * 0.6))
		body_mats = PetAssets.apply_fur(body, color, skin * 0.6, float(sp.get("density", 70.0)) * 0.9 * float(mat.get("density_scale", 1.0)),
			under_shells, _env_base, float(mat.get("sheen", 0.0)), 0, strands)
	else:
		skin = 0.012
		body_mats = [PetAssets.surface_material(mat["kind"], color, mat.get("params", {}), _env_base)]
		body.material_override = body_mats[0]
		PetAssets.set_param(body_mats, "pet_radius", width * 0.5)
	PetAssets.set_param(body_mats, "blush_l", _v3(anchors["blush_l"]))
	PetAssets.set_param(body_mats, "blush_r", _v3(anchors["blush_r"]))
	PetAssets.set_param(body_mats, "blush_radius", 0.09 * height + 0.02)

	_build_face(iris)
	for slot in Data.SLOTS:
		var n := Node3D.new()
		n.name = "slot_" + slot
		squash_node.add_child(n)
		slot_nodes[slot] = n
		_env_slots[slot] = []

	# ombre de contact : tache gaussienne sur le "mur" (l'ecran) juste sous le point d'appui
	contact = MeshInstance3D.new()
	contact.name = "contact"
	var qm := QuadMesh.new()
	qm.size = Vector2(width * 1.35, 0.34)
	contact.mesh = qm
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/shadow.gdshader")
	contact.material_override = sm
	contact.position = Vector3(0, -0.03, -float(anchors.get("depth", 1.0)) * 0.5 - 0.02)
	contact.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(contact)
	set_expression(base_expression)
	if not _env_state.is_empty():
		_apply_env(_all_env())
	_queue_occluders()


func set_body_color(c: Color) -> void:
	PetAssets.set_fur_color(body_mats, c)
	PetAssets.set_param(body_mats, "base_color", c)


static func _lin3(c: Color) -> Vector3:
	var l := c.srgb_to_linear()
	return Vector3(l.r, l.g, l.b)


static func _v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func basis_facing(n: Vector3) -> Basis:
	var z := n.normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x.length() < 0.01:
		x = Vector3.RIGHT
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


static func basis_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var x := y.cross(Vector3(0, 0, 1)).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


func _part(names: Array, iris: Color) -> Node3D:
	for n in names:
		if PetAssets.has_node_named("face", n):
			return PetAssets.make_face_part(n, iris, _env_base)
	return Node3D.new()


func _build_face(iris: Color) -> void:
	var style := eye_style
	if not PetAssets.has_node_named("face", "eye_" + style):
		style = "dot"
	var info: Dictionary = Data.EYES.get(style, {})
	var pr = info.get("pupil_range", [0.03, 0.025])
	_pupil_range = Vector2(float(pr[0]), float(pr[1]))
	var esc := float(info.get("scale", 1.0))
	var big := style == "googly"
	for side in ["l", "r"]:
		var a_pos := _v3(anchors["eye_" + side])
		var a_n := _v3(anchors["eye_" + side + "_n"])
		var n := (a_n + Vector3(0, 0, 1.3)).normalized()
		var e := Node3D.new()
		e.name = "eye_" + side
		e.position = a_pos + n * (skin * 0.5 + 0.004)
		e.basis = basis_facing(n)
		squash_node.add_child(e)
		var open := Node3D.new()
		e.add_child(open)
		var part := _part(["eye_" + style, "eye_dot"], iris)
		part.scale *= esc
		var mirrored: bool = side == "l" and bool(info.get("mirror", false))
		if mirrored:
			part.scale.x *= -1.0  # miroir pour les styles asymetriques (cils...)
		open.add_child(part)
		var pupil: Node3D = part.find_child("eye_%s_pupil" % style, true, false)
		var arc := _part(["eye_arc"], iris)
		arc.scale *= 1.6 if big else 1.0
		arc.visible = false
		e.add_child(arc)
		_eyes.append({"root": e, "open": open, "arc": arc, "pupil": pupil,
			"pupil_base": pupil.position if pupil else Vector3.ZERO, "mx": -1.0 if mirrored else 1.0})
		var brow := _part(["brow"], iris)
		brow.position = Vector3(0, 0.16 if big else 0.11, 0.01)
		brow.visible = false
		e.add_child(brow)
		_brows.append(brow)

	var m_pos := _v3(anchors["mouth"])
	var m_n := (_v3(anchors["mouth_n"]) + Vector3(0, 0, 1.0)).normalized()
	_mouth_root = Node3D.new()
	_mouth_root.name = "mouth"
	_mouth_root.position = m_pos + m_n * (skin * 0.5 + 0.004)
	_mouth_root.basis = basis_facing(m_n)
	squash_node.add_child(_mouth_root)
	_mouth["smile"] = _part(["mouth_" + mouth_style, "mouth_smile", "mouth_arc"], iris)
	_mouth["o"] = _part(["mouth_o"], iris)
	if PetAssets.has_node_named("face", "mouth_flat"):
		_mouth["flat"] = _part(["mouth_flat"], iris)
	else:
		_mouth["flat"] = _part(["brow"], iris)
		_mouth["flat"].scale *= 0.7
	if PetAssets.has_node_named("face", "mouth_frown"):
		_mouth["frown"] = _part(["mouth_frown"], iris)
	else:
		_mouth["frown"] = _part(["mouth_arc"], iris)
		_mouth["frown"].rotation.z = PI
	for k in _mouth:
		_mouth_root.add_child(_mouth[k])


# =========================================================================== environnement
## tex : capture autour du compagnon ; rect : fenetre dans la capture (uv) ; center : centre du compagnon (uv).
func set_env(tex: Texture2D, rect: Vector4, center: Vector2, spread: float, strength := 1.0,
		uv_per_unit := Vector2(0.25, 0.25), avg := Color(0.3, 0.3, 0.35)) -> void:
	var keep_wall = _env_state.get("wall", null)
	_env_state = {"tex": tex, "rect": rect, "center": center, "spread": spread, "strength": strength,
		"uvu": uv_per_unit, "avg": _lin3(avg)}
	if keep_wall != null:
		_env_state["wall"] = keep_wall
	_apply_env(_all_env())


## Profondeur (espace vue) du plan de l'ecran derriere le compagnon.
func set_wall_depth(z_view: float) -> void:
	_env_state["wall"] = z_view
	_apply_env(_all_env())


func _all_env() -> Array:
	var all := _env_base.duplicate()
	for s in _env_slots:
		all.append_array(_env_slots[s])
	all.append_array(_env_props)
	return all


func _apply_env(mats: Array) -> void:
	if not _env_state.has("tex"):
		return
	for m in mats:
		m.set_shader_parameter("env_tex", _env_state["tex"])
		m.set_shader_parameter("env_rect", _env_state["rect"])
		m.set_shader_parameter("env_center", _env_state["center"])
		m.set_shader_parameter("env_spread", _env_state["spread"])
		m.set_shader_parameter("env_strength", _env_state["strength"])
		if _env_state.has("uvu"):
			m.set_shader_parameter("uv_per_unit", _env_state["uvu"])
			m.set_shader_parameter("screen_avg", _env_state["avg"])
		if _env_state.has("wall"):
			m.set_shader_parameter("wall_z_view", _env_state["wall"])


# =========================================================================== expressions
func set_expression(e: String, duration := 0.0) -> void:
	if not EXPR.has(e):
		e = "neutral"
	expression = e
	_expr_timer = duration
	var d: Dictionary = EXPR[e]
	_eye_sy = float(d["sy"])
	_blush_target = float(d["blush"])
	for eye in _eyes:
		var mode: String = d["eyes"]
		eye["open"].visible = mode == "open"
		eye["arc"].visible = mode != "open"
		eye["arc"].rotation.z = 0.0 if mode == "happy" else PI
	var big := eye_style == "googly"
	for i in _brows.size():
		var b := _brows[i]
		var s := -1.0 if i == 0 else 1.0
		match d["brows"]:
			"angry":
				b.visible = true
				b.rotation.z = -0.45 * s
				b.position.y = 0.13 if big else 0.09
			"sad":
				b.visible = true
				b.rotation.z = 0.35 * s
				b.position.y = 0.17 if big else 0.12
			_:
				b.visible = false
	for k in _mouth:
		_mouth[k].visible = k == d["mouth"]
	_mouth_root.scale = Vector3.ONE * float(d["ms"])


func set_base_expression(e: String) -> void:
	base_expression = e
	if _expr_timer <= 0.0:
		set_expression(e)


# =========================================================================== physique molle
## Acceleration de la fenetre / du corps (unites monde / s^2, y vers le haut).
func push_accel(a: Vector2, delta: float) -> void:
	var rigid := float(phys.get("rigid", 0.0))
	_sh_v.x -= a.x * 0.25 * delta
	_sq_v -= a.y * 0.12 * delta * (1.0 - rigid)
	_sw_v -= a.x * (0.12 + 0.3 * rigid) * delta


## Impact au sol a `speed` (unites/s). Renvoie la vitesse de rebond.
func land(speed: float) -> float:
	var rigid := float(phys.get("rigid", 0.0))
	speed = absf(speed)
	_sq_v -= speed * 1.7
	_sh_v += Vector2(randf_range(-1, 1), randf_range(-1, 1)) * speed * 0.15
	_sw_v += randf_range(-1, 1) * speed * 0.6 * rigid
	var pl := float(phys.get("plastic", 0.0))
	if pl > 0.0:
		_plastic = clampf(_plastic - speed * 0.09 * pl, -0.45, 0.0)
	_ripple = minf(1.0, _ripple + speed * 0.35 * float(phys.get("ripple", 0.0)))
	return speed * float(phys.get("bounce", 0.2))


func _physics_springs(delta: float) -> void:
	var k := float(phys.get("k", 160.0))
	var c := float(phys.get("c", 9.0))
	var rigid := float(phys.get("rigid", 0.0))
	var rest := float(phys.get("stretch", 0.1)) if carried else 0.0
	var ks := 30.0 if rigid > 0.5 else 70.0
	var cs := 2.5 if rigid > 0.5 else 7.0
	var h := delta / 6.0
	for i in 6:
		_sq_v += (-k * (_sq - rest) - c * _sq_v) * h
		_sq += _sq_v * h
		_sh_v += (-k * _sh - c * _sh_v) * h
		_sh += _sh_v * h
		_sw_v += (-ks * _sw - cs * _sw_v) * h
		_sw += _sw_v * h
	_sq = clampf(_sq, -0.6, 1.4)
	_sh = _sh.limit_length(0.6)
	_sw = clampf(_sw, -1.2, 1.2)
	_plastic = move_toward(_plastic, 0.0, delta * 0.07)
	_ripple = move_toward(_ripple, 0.0, delta * 0.6)


# =========================================================================== boucle
func _process(delta: float) -> void:
	if root_node == null:
		return
	_t += delta
	delta = minf(delta, 0.05)
	_physics_springs(delta)
	var rigid := float(phys.get("rigid", 0.0))
	var soft := 1.0 - 0.9 * rigid
	var speed := 1.3 if sleeping else 2.4
	var b := sin(_t * speed) * 0.022 * breath_amp * soft
	var sy := maxf(0.3, 1.0 + squash * (0.4 + 0.6 * soft) + (_sq + _plastic) * soft + b)
	var sxz := 1.0 / sqrt(sy)
	var sh := _sh * soft
	squash_node.basis = Basis(Vector3(sxz, 0, 0), Vector3(sh.x, sy, sh.y), Vector3(0, 0, sxz))
	_look_cur = _look_cur.lerp(look, minf(1.0, delta * 6.0))
	# assise : il s'enfonce un peu par son poids, le shader aplatit ce qui passe sous le sol
	var sink := 0.0 if (airborne or carried) else height * (0.012 + 0.055 * soft) * clampf(1.0 - hop * 8.0, 0.0, 1.0)
	root_node.position.y = hop - sink
	root_node.rotation = Vector3(
		pitch - _look_cur.y * 0.12,
		yaw + spin + _look_cur.x * 0.32,
		lean + _sw * (0.25 + 0.75 * rigid) + sin(_t * 38.0) * shake)
	var gy := -100.0 if (airborne or carried) else global_position.y + ground_level
	var bc := root_node.global_position + Vector3(0, height * 0.4, 0)
	PetAssets.set_param(body_mats, "ground_y", gy)
	PetAssets.set_param(body_mats, "body_center", bc)
	PetAssets.set_param(body_mats, "contact_bulge", 0.55 * soft + 0.05)
	if contact:
		var k := 0.0 if (airborne or carried) else clampf(1.0 - hop * 4.0, 0.0, 1.0)
		contact.material_override.set_shader_parameter("strength", 0.42 * k)

	var vy := (hop - _last_hop) / maxf(delta, 0.001)
	_last_hop = hop
	PetAssets.set_param(body_mats, "wind", Vector3(-sin(lean + _sw) * 0.6 - _sh.x * 2.0, clampf(-vy * 0.25 - _sq_v * 0.3, -0.8, 0.8), 0))
	PetAssets.set_param(body_mats, "wobble", _ripple)

	# clignement
	if expression != "sleep":
		_blink_t -= delta
		if _blink_t <= 0.0:
			_blink = 0.16
			_blink_t = randf_range(2.0, 5.5)
	var bf := 1.0
	if _blink > 0.0:
		_blink -= delta
		bf = clampf(absf(_blink - 0.08) / 0.08, 0.08, 1.0)
	for eye in _eyes:
		var open: Node3D = eye["open"]
		open.scale = Vector3(1.0, _eye_sy * bf, 1.0)
		var pupil: Node3D = eye["pupil"]
		if pupil:
			pupil.position = eye["pupil_base"] + Vector3(_look_cur.x * _pupil_range.x * eye["mx"], _look_cur.y * _pupil_range.y, 0)
		else:
			open.position = Vector3(_look_cur.x * 0.018, _look_cur.y * 0.014, 0.0)

	_blush = lerpf(_blush, _blush_target, minf(1.0, delta * 4.0))
	PetAssets.set_param(body_mats, "blush_amount", _blush)

	if _expr_timer > 0.0:
		_expr_timer -= delta
		if _expr_timer <= 0.0:
			set_expression(base_expression)

	# pieces animees des accessoires
	var happy := expression in ["happy", "love"]
	_happy_spin = lerpf(_happy_spin, 18.0 if happy else 5.0, delta * 2.0)
	for p in _anim_parts:
		var node: Node3D = p["node"]
		if not is_instance_valid(node):
			continue
		var base: Basis = p["base"]
		match p["kind"]:
			"spin":
				p["angle"] = float(p.get("angle", 0.0)) + _happy_spin * delta
				node.basis = base * Basis(Vector3.UP, p["angle"])
			"wing":
				var f := 9.0 if (happy or carried) else 2.5
				var amp := 0.55 if (happy or carried) else 0.18
				node.basis = base * Basis(Vector3.UP, sin(_t * f) * amp * float(p["sign"]))
			"sway":
				node.basis = base * Basis(Vector3.RIGHT, sin(_t * 3.0) * 0.18 - _sh.x * 2.0 - _sw)


# =========================================================================== accessoires
func set_item(slot: String, item_id: String, colors: Dictionary, animate := true) -> void:
	var holder: Node3D = slot_nodes.get(slot)
	if holder == null:
		return
	for c in holder.get_children():
		c.free()
	_anim_parts = _anim_parts.filter(func(p): return is_instance_valid(p["node"]))
	_env_slots[slot] = []
	slot_items[slot] = item_id
	if item_id == "" or not Data.ITEMS.has(item_id):
		return
	var item: Dictionary = Data.ITEMS[item_id]
	var node := PetAssets.make_item(item_id, colors, maxi(4, shells / 2), _env_slots[slot])
	_apply_env(_env_slots[slot])
	var fit: String = item.get("fit", "hat")
	var hat := _v3(anchors["hat"])
	var hat_n := _v3(anchors["hat_n"])
	var googly := eye_style == "googly"
	match fit:
		"hat":
			var up := (hat_n * 0.6 + Vector3.UP * 0.4).normalized()
			holder.transform = Transform3D(basis_up(up).scaled(Vector3.ONE * float(anchors["hat_width"]) / 0.6),
				hat + up * skin * 0.4 - up * 0.02)
		"headphones":
			var s := (float(anchors["ear_width"]) * 0.5 + skin + 0.03) / 0.38
			holder.transform = Transform3D(Basis().scaled(Vector3.ONE * s), hat + Vector3.UP * skin * 0.5)
		"eyes":
			var el := _v3(anchors["eye_l"])
			var er := _v3(anchors["eye_r"])
			var s2 := minf((er.x - el.x) / 0.32 * (1.15 if googly else 1.0), 1.25)
			holder.transform = Transform3D(Basis().scaled(Vector3.ONE * s2),
				(el + er) * 0.5 + Vector3(0, 0, skin + (0.13 if googly else 0.05)))
		"mouth":
			holder.transform = Transform3D(Basis(), _v3(anchors["mouth"]) + Vector3(0, 0, skin * 0.6 + 0.01))
		"neck":
			var nn := (_v3(anchors["neck_n"]) + Vector3(0, 0, 1)).normalized()
			holder.transform = Transform3D(basis_facing(nn), _v3(anchors["neck"]) + nn * (skin + 0.02))
		"scarf":
			var r := float(anchors["neck_radius"]) + skin * 0.8
			var rx := float(anchors.get("neck_rx", r - skin * 0.8)) + skin * 0.8
			var rz := float(anchors.get("neck_rz", r - skin * 0.8)) + skin * 0.8
			holder.transform = Transform3D(Basis().scaled(Vector3(rx, r * 0.9, rz)), _v3(anchors["neck_center"]))
		"back":
			var bn := (_v3(anchors.get("back_n", [0, 0, -1])) + Vector3(0, 0, -1)).normalized()
			holder.transform = Transform3D(Basis(), _v3(anchors.get("back", [0, height * 0.45, -0.4])) + bn * (skin + 0.02))
	holder.add_child(node)
	# pieces animees
	for child in node.find_children("*", "Node3D", true, false):
		var nm: String = child.name
		if nm.ends_with("_spin"):
			_anim_parts.append({"node": child, "kind": "spin", "base": child.basis})
		elif nm.ends_with("_wing_l") or nm.ends_with("_wing_r"):
			_anim_parts.append({"node": child, "kind": "wing", "base": child.basis, "sign": 1.0 if nm.ends_with("_l") else -1.0})
		elif nm.ends_with("_sway"):
			_anim_parts.append({"node": child, "kind": "sway", "base": child.basis})
	if animate:
		node.scale = Vector3.ONE * 0.01
		var t := create_tween()
		t.tween_property(node, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_sq_v -= 1.2  # petit "boing" quand on lui met quelque chose
	_queue_occluders()


## Spheres d'occlusion (accessoires + yeux) pour les ombres douces sur la fourrure.
var _occ_pending := false


func _queue_occluders() -> void:
	if _occ_pending or not is_inside_tree():
		return
	_occ_pending = true
	await get_tree().create_timer(0.45).timeout
	_occ_pending = false
	_update_occluders()


func _update_occluders() -> void:
	if squash_node == null or not is_inside_tree():
		return
	var to_local := squash_node.global_transform.affine_inverse()
	var occ := PackedVector4Array()
	for slot in Data.SLOTS:
		var holder: Node3D = slot_nodes.get(slot)
		if holder == null or holder.get_child_count() == 0:
			continue
		var aabb := AABB()
		var first := true
		for mi in holder.find_children("*", "MeshInstance3D", true, false):
			if mi.name.begins_with("shell_"):
				continue
			var b: AABB = (to_local * mi.global_transform) * mi.get_aabb()
			aabb = b if first else aabb.merge(b)
			first = false
		if first:
			continue
		var hs := aabb.size * 0.5
		# lunettes / moustaches : objets fins et larges -> petite sphere (sinon tout le visage s'assombrit)
		var r := (hs.x + hs.y + hs.z) / 3.0 * (0.45 if slot == "face" else 0.85)
		occ.append(Vector4(aabb.get_center().x, aabb.get_center().y, aabb.get_center().z, r))
	var er := 0.11 if eye_style == "googly" else 0.065
	for eye in _eyes:
		var e: Node3D = eye["root"]
		var c := e.position + e.basis.z * 0.025
		occ.append(Vector4(c.x, c.y, c.z, er))
	while occ.size() > 8:
		occ.remove_at(occ.size() - 1)
	var count := occ.size()
	while occ.size() < 8:
		occ.append(Vector4(0, -100, 0, 0))
	PetAssets.set_param(body_mats, "occ", occ)
	PetAssets.set_param(body_mats, "occ_count", count)


func show_prop(id: String) -> void:
	if props.has(id):
		return
	var p := PetAssets.make_prop(id, _env_props)
	_apply_env(_env_props)
	match id:
		"laptop":
			p.position = Vector3(width * 0.5 + 0.22, 0.0, 0.18)
			p.rotation.y = -0.95
		"gamepad":
			p.position = Vector3(0, height * 0.28, float(anchors.get("depth", 1.0)) * 0.5 + 0.14)
			p.rotation.x = 0.9
		"mug":
			p.position = Vector3(-width * 0.5 - 0.12, 0.0, 0.15)
		"popcorn":
			p.position = Vector3(-width * 0.5 - 0.06, 0.0, 0.12)
			p.scale = Vector3.ONE * 1.25
		"phone":
			# tenu devant lui, ecran tourne vers lui : on voit la coque et la camera
			p.position = Vector3(0.1, height * 0.3, float(anchors.get("depth", 1.0)) * 0.5 + 0.1)
			p.rotation = Vector3(-0.35, PI + 0.35, 0.12)
			p.scale = Vector3.ONE * 1.45
	add_child(p)
	props[id] = p
	var target_scale := p.scale
	p.scale = Vector3.ONE * 0.01
	var t := create_tween()
	t.tween_property(p, "scale", target_scale, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func hide_prop(id: String) -> void:
	if not props.has(id):
		return
	var p: Node3D = props[id]
	props.erase(id)
	var t := create_tween()
	t.tween_property(p, "scale", Vector3.ONE * 0.01, 0.2)
	t.tween_callback(p.queue_free)


func hide_all_props() -> void:
	for id in props.keys():
		hide_prop(id)


# =========================================================================== position ecran
## Points (pixels du viewport) englobant le compagnon, pour la zone cliquable de la fenetre.
func screen_points(cam: Camera3D) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for gi in find_children("*", "GeometryInstance3D", true, false):
		if not gi.is_visible_in_tree() or gi.name.begins_with("shell_"):
			continue
		var aabb: AABB = (gi.global_transform * gi.get_aabb()).grow(skin + 0.02)
		for i in 8:
			var c := aabb.get_endpoint(i)
			if not cam.is_position_behind(c):
				pts.append(cam.unproject_position(c))
	return pts


func head_top_global() -> Vector3:
	var top := height + 0.05
	var hat: Node3D = slot_nodes.get("head")
	if hat and hat.get_child_count() > 0:
		top += 0.35 * float(anchors.get("hat_width", 0.6)) / 0.6
	return root_node.to_global(Vector3(0, top * squash_node.basis.y.y, 0))


func mouth_global() -> Vector3:
	if _mouth_root:
		return _mouth_root.global_position
	return center_global()


func center_global() -> Vector3:
	return root_node.to_global(Vector3(0, height * 0.5 * squash_node.basis.y.y, 0))


# =========================================================================== actions
func _tw() -> Tween:
	var t := create_tween()
	_tweens.append(t)
	return t


func _begin() -> int:
	_act += 1
	var id := _act
	for t in _tweens:
		if t.is_valid():
			t.kill()
	_tweens.clear()
	busy = true
	spin = fposmod(spin, TAU)
	if spin > PI:
		spin -= TAU
	if absf(hop) + absf(squash) + absf(lean) + absf(pitch) + absf(shake) + absf(spin) > 0.01:
		var t := _tw().set_parallel(true)
		for p in ["hop", "squash", "lean", "pitch", "spin", "shake"]:
			t.tween_property(self, p, 0.0, 0.14)
		await t.finished
	return id


func _end(id: int) -> void:
	if id == _act:
		busy = false


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func stop_action() -> void:
	var id: int = await _begin()
	_end(id)


func act_hop(n := 1, h := 0.16) -> void:
	var id: int = await _begin()
	for i in n:
		if id != _act:
			return
		await _hop_once(h)
	_end(id)


func _hop_once(h := 0.16, dur := 0.42) -> void:
	var t := _tw()
	t.tween_property(self, "squash", -0.14, dur * 0.22).set_trans(Tween.TRANS_SINE)
	t.tween_property(self, "squash", 0.12, dur * 0.15)
	t.parallel().tween_property(self, "hop", h, dur * 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(self, "squash", 0.0, dur * 0.2)
	t.parallel().tween_property(self, "hop", 0.0, dur * 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await t.finished
	land(h * 7.0)
	await _wait(dur * 0.35)


func act_spin() -> void:
	var id: int = await _begin()
	set_expression("happy", 1.4)
	var t := _tw()
	t.tween_property(self, "squash", -0.15, 0.12)
	t.tween_property(self, "hop", 0.22, 0.2).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(self, "squash", 0.1, 0.2)
	t.parallel().tween_property(self, "spin", TAU, 0.45).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(self, "hop", 0.0, 0.18).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(self, "squash", 0.0, 0.18)
	await t.finished
	spin = 0.0
	land(1.6)
	emote.emit("sparkle", 3)
	_end(id)


func act_wiggle(dur := 2.0) -> void:
	var id: int = await _begin()
	var t := _tw()
	var steps := int(dur / 0.25)
	for i in steps:
		var s := 1.0 if i % 2 == 0 else -1.0
		t.tween_property(self, "lean", 0.16 * s, 0.25).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(self, "squash", 0.06 if i % 2 == 0 else -0.04, 0.25)
	t.tween_property(self, "lean", 0.0, 0.2)
	t.parallel().tween_property(self, "squash", 0.0, 0.2)
	await t.finished
	_end(id)


func act_dance(dur := 4.0) -> void:
	var id: int = await _begin()
	set_expression("happy", dur)
	var beats := int(dur / 0.5)
	for i in beats:
		if id != _act:
			return
		if i % 2 == 0:
			emote.emit("note", 1)
		var s := 1.0 if i % 2 == 0 else -1.0
		var t := _tw()
		t.tween_property(self, "lean", 0.22 * s, 0.12)
		t.parallel().tween_property(self, "hop", 0.08, 0.12).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(self, "squash", 0.08, 0.12)
		t.tween_property(self, "hop", 0.0, 0.13).set_ease(Tween.EASE_IN)
		t.parallel().tween_property(self, "squash", 0.0, 0.13)
		await t.finished
		land(0.6)
		await _wait(0.25)
	var t2 := _tw()
	t2.tween_property(self, "lean", 0.0, 0.2)
	await t2.finished
	_end(id)


func act_look_around() -> void:
	var id: int = await _begin()
	for target in [Vector2(-0.9, 0.1), Vector2(0.9, 0.2), Vector2(0.0, 0.5), Vector2.ZERO]:
		if id != _act:
			return
		look = target
		await _wait(randf_range(0.6, 1.1))
	_end(id)


func act_stretch() -> void:
	var id: int = await _begin()
	set_expression("happy", 1.6)
	var t := _tw()
	t.tween_property(self, "squash", -0.12, 0.3).set_trans(Tween.TRANS_SINE)
	t.tween_property(self, "squash", 0.32, 0.6).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(self, "lean", 0.1, 0.6)
	t.tween_interval(0.4)
	t.tween_property(self, "lean", -0.1, 0.4)
	t.tween_property(self, "squash", 0.0, 0.25)
	t.parallel().tween_property(self, "lean", 0.0, 0.25)
	await t.finished
	land(1.0)
	_end(id)


func act_yawn() -> void:
	var id: int = await _begin()
	set_expression("surprised", 1.3)
	_eye_sy = 0.35
	var t := _tw()
	t.tween_property(self, "squash", 0.18, 0.7).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(self, "pitch", -0.15, 0.7)
	t.tween_interval(0.5)
	t.tween_property(self, "squash", 0.0, 0.5)
	t.parallel().tween_property(self, "pitch", 0.0, 0.5)
	await t.finished
	_end(id)


func act_nod() -> void:
	var id: int = await _begin()
	var t := _tw()
	for i in 2:
		t.tween_property(self, "pitch", 0.22, 0.13)
		t.tween_property(self, "pitch", -0.05, 0.13)
	t.tween_property(self, "pitch", 0.0, 0.1)
	await t.finished
	_end(id)


func act_shake_no() -> void:
	var id: int = await _begin()
	var base := yaw
	var t := _tw()
	for i in 3:
		t.tween_property(self, "yaw", base + 0.45, 0.1)
		t.tween_property(self, "yaw", base - 0.45, 0.1)
	t.tween_property(self, "yaw", base, 0.1)
	await t.finished
	_end(id)


func act_love() -> void:
	var id: int = await _begin()
	set_expression("love", 2.5)
	emote.emit("heart", 5)
	for i in 2:
		if id != _act:
			return
		await _hop_once(0.18, 0.4)
	_end(id)


func act_angry() -> void:
	var id: int = await _begin()
	set_expression("angry", 2.6)
	emote.emit("anger", 1)
	var t := _tw()
	t.tween_property(self, "squash", -0.12, 0.15)
	t.tween_property(self, "shake", 0.05, 0.1)
	t.tween_interval(0.6)
	t.tween_property(self, "shake", 0.0, 0.1)
	t.tween_property(self, "squash", 0.0, 0.2)
	await t.finished
	if id == _act:
		await act_shake_no()
	_end(id)


func act_surprised() -> void:
	var id: int = await _begin()
	set_expression("surprised", 1.0)
	emote.emit("exclaim", 1)
	var t := _tw()
	t.tween_property(self, "squash", -0.2, 0.06)
	t.tween_property(self, "hop", 0.2, 0.15).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(self, "squash", 0.15, 0.12)
	t.tween_property(self, "hop", 0.0, 0.15).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(self, "squash", 0.0, 0.15)
	await t.finished
	land(1.4)
	_end(id)


func act_petted() -> void:
	var id: int = await _begin()
	set_expression("love", 1.8)
	emote.emit("heart", 2)
	_sq_v -= 0.8
	var t := _tw()
	t.tween_property(self, "squash", -0.1, 0.2).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(self, "lean", 0.12, 0.2)
	t.tween_property(self, "lean", -0.12, 0.3).set_trans(Tween.TRANS_SINE)
	t.tween_property(self, "lean", 0.0, 0.25)
	t.parallel().tween_property(self, "squash", 0.0, 0.3)
	await t.finished
	_end(id)


func act_meh() -> void:
	var id: int = await _begin()
	set_expression("meh", 2.0)
	look = Vector2(0.0, 0.8)
	var t := _tw()
	t.tween_property(self, "lean", 0.15, 0.4).set_trans(Tween.TRANS_SINE)
	t.tween_interval(0.6)
	t.tween_property(self, "lean", 0.0, 0.4)
	await t.finished
	look = Vector2.ZERO
	_end(id)


func act_sad() -> void:
	var id: int = await _begin()
	set_expression("sad", 3.0)
	emote.emit("sweat", 1)
	var t := _tw()
	t.tween_property(self, "squash", -0.1, 0.6).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(self, "pitch", 0.12, 0.6)
	t.tween_interval(1.4)
	t.tween_property(self, "squash", 0.0, 0.5)
	t.parallel().tween_property(self, "pitch", 0.0, 0.5)
	await t.finished
	_end(id)


func act_dizzy() -> void:
	var id: int = await _begin()
	set_expression("dizzy", 2.0)
	emote.emit("star", 3)
	var t := _tw()
	for i in 4:
		t.tween_property(self, "lean", 0.12, 0.2)
		t.tween_property(self, "lean", -0.12, 0.2)
	t.tween_property(self, "lean", 0.0, 0.2)
	await t.finished
	_end(id)


## Tape sur le petit ordinateur pendant `dur` secondes.
func act_typing(dur := 20.0) -> void:
	var id: int = await _begin()
	show_prop("laptop")
	var t0 := _tw()
	t0.tween_property(self, "yaw", 0.55, 0.4).set_trans(Tween.TRANS_SINE)
	await t0.finished
	set_base_expression("focused")
	look = Vector2(0.5, -0.5)
	var end_time := Time.get_ticks_msec() + int(dur * 1000.0)
	while Time.get_ticks_msec() < end_time:
		if id != _act:
			return
		if randf() < 0.12:
			look = Vector2(0.1, 0.1)
			await _wait(randf_range(0.8, 1.6))
			look = Vector2(0.5, -0.5)
			continue
		var t := _tw()
		for i in 6:
			t.tween_property(self, "squash", -0.035, 0.07)
			t.parallel().tween_property(self, "pitch", 0.06, 0.07)
			t.tween_property(self, "squash", 0.0, 0.07)
			t.parallel().tween_property(self, "pitch", 0.0, 0.07)
		await t.finished
	set_base_expression("neutral")
	look = Vector2.ZERO
	hide_prop("laptop")
	var t1 := _tw()
	t1.tween_property(self, "yaw", 0.0, 0.4)
	await t1.finished
	_end(id)


## Joue a la manette pendant `dur` secondes.
## Si une vraie manette est branchee, il IMITE le joueur (facon Bongo Cat) : il se penche avec le stick
## et sursaute a chaque bouton.
const MIRROR_BUTTONS := [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y,
	JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN,
	JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]
var _mirror_presses := 0.0


func act_gaming(dur := 20.0) -> void:
	var id: int = await _begin()
	show_prop("gamepad")
	set_base_expression("focused")
	look = Vector2(0.0, -0.7)
	var end_time := Time.get_ticks_msec() + int(dur * 1000.0)
	var was_down := {}
	while Time.get_ticks_msec() < end_time:
		if id != _act:
			return
		var pads := Input.get_connected_joypads()
		if not pads.is_empty():
			# miroir de la vraie manette
			var j: int = pads[0]
			var lx := Input.get_joy_axis(j, JOY_AXIS_LEFT_X)
			var ly := Input.get_joy_axis(j, JOY_AXIS_LEFT_Y)
			var rt := Input.get_joy_axis(j, JOY_AXIS_TRIGGER_RIGHT)
			lean = lerpf(lean, -lx * 0.28, 0.35)
			pitch = lerpf(pitch, ly * 0.12, 0.35)
			var pressed := false
			for b in MIRROR_BUTTONS:
				var down := Input.is_joy_button_pressed(j, b)
				if down and not was_down.get(b, false):
					pressed = true
				was_down[b] = down
			if pressed or rt > 0.6:
				_sq_v -= 0.9
				_mirror_presses += 1.0
				if _mirror_presses > 25.0 and randf() < 0.05:
					emote.emit("sweat", 1)  # tu spammes !
			_mirror_presses = maxf(0.0, _mirror_presses - 0.04)
			await get_tree().process_frame
			continue
		var t := _tw()
		if randf() < 0.15:
			set_expression("happy", 1.0)
			emote.emit("sparkle", 2)
			t.tween_property(self, "hop", 0.12, 0.15).set_ease(Tween.EASE_OUT)
			t.tween_property(self, "hop", 0.0, 0.15).set_ease(Tween.EASE_IN)
			t.tween_callback(land.bind(0.9))
		else:
			var s := 1.0 if randf() < 0.5 else -1.0
			t.tween_property(self, "lean", 0.18 * s, 0.18).set_trans(Tween.TRANS_SINE)
			t.parallel().tween_property(self, "squash", -0.04, 0.09)
			t.tween_property(self, "lean", 0.0, 0.25)
			t.parallel().tween_property(self, "squash", 0.0, 0.25)
		await t.finished
	set_base_expression("neutral")
	look = Vector2.ZERO
	hide_prop("gamepad")
	_end(id)


## Joue avec son petit telephone pendant `dur` secondes.
func act_phone(dur := 15.0) -> void:
	var id: int = await _begin()
	show_prop("phone")
	set_base_expression("focused")
	look = Vector2(0.15, -0.55)
	var end_time := Time.get_ticks_msec() + int(dur * 1000.0)
	while Time.get_ticks_msec() < end_time:
		if id != _act:
			return
		var r := randf()
		var ph: Node3D = props.get("phone")
		if r < 0.12:
			# il rigole devant une video
			set_expression("happy", 1.4)
			emote.emit("note" if randf() < 0.5 else "heart", 1)
			var t := _tw()
			for i in 3:
				t.tween_property(self, "squash", -0.06, 0.09)
				t.tween_property(self, "squash", 0.03, 0.09)
			t.tween_property(self, "squash", 0.0, 0.1)
			await t.finished
		elif r < 0.18:
			set_expression("surprised", 1.0)
			emote.emit("exclaim", 1)
			await _wait(1.0)
		elif r < 0.26:
			# leve les yeux vers toi, puis retourne a son ecran
			look = Vector2(0.0, 0.2)
			await _wait(randf_range(0.8, 1.4))
			look = Vector2(0.15, -0.55)
		else:
			# defile du pouce : le telephone bouge un peu
			if ph:
				var t2 := _tw()
				t2.tween_property(ph, "position:y", height * 0.3 + 0.012, 0.18).set_trans(Tween.TRANS_SINE)
				t2.tween_property(ph, "position:y", height * 0.3, 0.22).set_trans(Tween.TRANS_SINE)
				await t2.finished
			await _wait(randf_range(0.3, 0.9))
	set_base_expression("neutral")
	look = Vector2.ZERO
	hide_prop("phone")
	_end(id)


## Mange un aliment (pref : 2 adore, 1 aime, 0 neutre, -1 n'aime pas).
## Bouche ouverte -> l'aliment arrive -> il mache -> reaction.
func act_eat(pref := 0) -> void:
	var id: int = await _begin()
	set_expression("surprised", 0.6)  # bouche grande ouverte
	look = Vector2(0.0, 0.2)
	var t := _tw()
	t.tween_property(self, "pitch", -0.12, 0.18)
	t.parallel().tween_property(self, "squash", 0.1, 0.18)
	await t.finished
	if id != _act:
		return
	# il croque
	set_expression("happy", 1.5)
	var t2 := _tw()
	t2.tween_property(self, "pitch", 0.06, 0.08)
	t2.parallel().tween_property(self, "squash", -0.12, 0.08)
	for i in 3:
		t2.tween_property(self, "squash", -0.05, 0.11)
		t2.tween_property(self, "squash", -0.14, 0.11)
	t2.tween_property(self, "squash", 0.0, 0.15)
	t2.parallel().tween_property(self, "pitch", 0.0, 0.15)
	await t2.finished
	land(0.8)
	look = Vector2.ZERO
	if id != _act:
		return
	match pref:
		2:
			set_expression("love", 1.8)
			emote.emit("heart", 3)
		1:
			set_expression("happy", 1.2)
			emote.emit("sparkle", 2)
		-1:
			set_expression("meh", 1.5)
			emote.emit("sweat", 1)
		_:
			set_expression("happy", 1.0)
	_end(id)


## Regarde une video avec du pop-corn, tourne vers l'ecran (dos a toi).
func act_popcorn(dur := 25.0) -> void:
	var id: int = await _begin()
	show_prop("popcorn")
	var t0 := _tw()
	t0.tween_property(self, "yaw", PI * 0.82, 0.6).set_trans(Tween.TRANS_SINE)
	await t0.finished
	set_base_expression("happy")
	var end_time := Time.get_ticks_msec() + int(dur * 1000.0)
	while Time.get_ticks_msec() < end_time:
		if id != _act:
			return
		await _wait(randf_range(1.4, 3.0))
		if id != _act:
			return
		# il pioche et croque
		var t := _tw()
		t.tween_property(self, "pitch", 0.14, 0.15)
		t.tween_property(self, "pitch", -0.04, 0.15)
		t.tween_property(self, "squash", -0.06, 0.08)
		t.tween_property(self, "squash", 0.0, 0.12)
		t.tween_property(self, "pitch", 0.0, 0.2)
		await t.finished
		if randf() < 0.12:
			emote.emit("sparkle", 1)
	set_base_expression("neutral")
	hide_prop("popcorn")
	var t1 := _tw()
	t1.tween_property(self, "yaw", 0.0, 0.5)
	await t1.finished
	_end(id)


func act_drink() -> void:
	var id: int = await _begin()
	show_prop("mug")
	var t := _tw()
	t.tween_property(self, "yaw", -0.5, 0.4)
	t.tween_interval(0.4)
	t.tween_property(self, "pitch", -0.2, 0.4)
	t.tween_interval(1.0)
	t.tween_property(self, "pitch", 0.0, 0.3)
	t.tween_property(self, "yaw", 0.0, 0.4)
	await t.finished
	set_expression("happy", 1.2)
	await _wait(1.0)
	hide_prop("mug")
	_end(id)


## S'endort (reste endormi jusqu'a wake_up()).
func act_sleep() -> void:
	var id: int = await _begin()
	sleeping = true
	hide_all_props()
	set_base_expression("sleep")
	set_expression("sleep")
	breath_amp = 2.2
	var t := _tw()
	t.tween_property(self, "squash", -0.1, 1.2).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(self, "lean", 0.07, 1.2)
	await t.finished
	while id == _act and sleeping:
		emote.emit("zzz", 1)
		await _wait(1.8)


func wake_up() -> void:
	if not sleeping:
		return
	sleeping = false
	breath_amp = 1.0
	set_base_expression("neutral")
	set_expression("neutral")
	await act_stretch()


## Reaction a un accessoire (niveau -2..2).
func react_to_item(level: int) -> void:
	match level:
		Data.LOVE:
			await act_love()
		Data.LIKE:
			set_expression("happy", 2.0)
			emote.emit("sparkle", 2)
			await act_hop(1, 0.12)
		Data.NEUTRAL:
			look = Vector2(0.0, 0.9)
			emote.emit("question", 1)
			await act_nod()
			look = Vector2.ZERO
		Data.DISLIKE:
			await act_meh()
		Data.HATE:
			await act_angry()


func say(text: String) -> void:
	said.emit(text)
