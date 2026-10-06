class_name Thumbs
extends SubViewport
## Rend des miniatures 3D (accessoires, especes, matieres, yeux, bouches) une par une, a la demande.
## - pilote par _process (pas de coroutine qui peut mourir si une carte est liberee)
## - les demandes dont le destinataire a ete libere sont ignorees
## - une seule demande en attente par destinataire (la plus recente gagne)
## - le cache tient compte des couleurs de l'objet et du contexte (espece, matiere...)
## - le viewport ne rend rien quand il n'y a pas de travail

const CACHE_MAX := 320

static var cache := {}
static var _px := 192  # taille de rendu courante (fait partie de la cle du cache)
static var _used_px := {192: true}

var _queue: Array = []  # [{key, kind, id, cb}]
var _job := {}
var _frames := 0
var _cam: Camera3D
var _holder: Node3D
var _reg: Array = []
var rendered := 0  # compteur (tests)


func _init() -> void:
	size = Vector2i(192, 192)
	transparent_bg = true
	own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	msaa_3d = Viewport.MSAA_4X
	scaling_3d_scale = 1.0  # la sur-resolution vient deja de la taille (2x l'affichage)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	add_child(_cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -30, 0)
	key.light_energy = 1.1
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, 150, 0)
	fill.light_energy = 0.45
	add_child(fill)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.88, 0.95)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	we.environment = env
	add_child(we)
	_holder = Node3D.new()
	add_child(_holder)


func _ready() -> void:
	set_process(not _queue.is_empty())


## kind : item | species | material | eye | mouth
func request(kind: String, id: String, cb: Callable) -> void:
	var key := key_for(kind, id)
	if cache.has(key):
		cb.call(cache[key])
		return
	var target := cb.get_object()
	if target:
		_queue = _queue.filter(func(j): return j["cb"].get_object() != target)
	_queue.append({"key": key, "kind": kind, "id": id, "cb": cb})
	set_process(true)


## Rend les miniatures a ~2x leur taille d'affichage en pixels physiques (nettes a 125 % / 150 %).
func set_display_scale(f: float) -> void:
	_px = clampi(int(ceil(150.0 * f * 2.0 / 16.0)) * 16, 256, 512)
	_used_px[_px] = true
	if _job.is_empty():
		size = Vector2i(_px, _px)


## Meilleure miniature deja rendue (taille courante, sinon n'importe quelle taille), ou null.
static func best(kind: String, id: String) -> Texture2D:
	var key := key_for(kind, id)
	if cache.has(key):
		return cache[key]
	var tail := key.substr(key.find(":"))
	for px in _used_px:
		var k2 := str(px) + tail
		if cache.has(k2):
			return cache[k2]
	return null


func pending() -> int:
	return _queue.size() + (0 if _job.is_empty() else 1)


static func key_for(kind: String, id: String) -> String:
	match kind:
		"item":
			var c := GameState.colors_for(id)
			return "%d:item:%s:%s%s%s" % [_px, id, c["main"].to_html(false), c["accent"].to_html(false), c["detail"].to_html(false)]
		"species":
			return "%d:species:%s" % [_px, id]
	return "%d:%s:%s:%s|%s|%s|%s|%s|%s" % [_px, kind, id, GameState.species, GameState.material, GameState.fur_color,
		GameState.current_eye_style(), GameState.mouth_style, GameState.current_iris().to_html(false)]


func _process(_delta: float) -> void:
	if _job.is_empty():
		while not _queue.is_empty():
			var j: Dictionary = _queue.pop_front()
			if not j["cb"].is_valid():
				continue
			if cache.has(j["key"]):
				j["cb"].call(cache[j["key"]])
				continue
			_job = j
			if size.x != _px:
				size = Vector2i(_px, _px)
			_build(j["kind"], j["id"])
			render_target_update_mode = SubViewport.UPDATE_ALWAYS
			_frames = 0
			break
		if _job.is_empty():
			render_target_update_mode = SubViewport.UPDATE_DISABLED
			_clear()
			set_process(false)
		return
	_frames += 1
	if _frames < 3:
		return
	var img := get_texture().get_image()
	# bords alpha propres + mipmaps : reduction nette et sans franges sombres
	img.fix_alpha_edges()
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_store(_job["key"], tex)
	rendered += 1
	if _job["cb"].is_valid():
		_job["cb"].call(tex)
	_job = {}


static func _store(key: String, tex: Texture2D) -> void:
	if cache.size() >= CACHE_MAX:
		var keys := cache.keys()
		for i in mini(64, keys.size()):
			cache.erase(keys[i])
	cache[key] = tex


func _clear() -> void:
	for c in _holder.get_children():
		c.free()
	_reg.clear()


func _build(kind: String, id: String) -> void:
	_clear()
	match kind:
		"item":
			var colors := GameState.colors_for(id)
			var node := PetAssets.make_item(id, colors, 8, _reg)
			_holder.add_child(node)
			_frame_node(node, Vector3(0.45, 0.32, 1.0))
		"species":
			var p := _pet(id, Color.html(Data.SPECIES[id]["fur"]), "peluche", "", "smile")
			_frame_box(Vector3(0, p.height * 0.5, 0), p.height * 1.25, Vector3(0.0, 0.1, 1.0))
		"material":
			var mat: Dictionary = Data.MATERIALS[id]
			var col := GameState.current_fur_color()
			if str(mat.get("color", "")) != "":
				col = Color.html(mat["color"])
			var p2 := _pet(GameState.species, col, id, GameState.current_eye_style(), GameState.mouth_style)
			_frame_box(Vector3(0, p2.height * 0.5, 0), p2.height * 1.25, Vector3(0.25, 0.15, 1.0))
		"eye":
			var p3 := _pet(GameState.species, GameState.current_fur_color(), GameState.material, id, GameState.mouth_style)
			var a := Data.anchors(GameState.species)
			var c := (Pet._v3(a["eye_l"]) + Pet._v3(a["eye_r"])) * 0.5
			_frame_box(c, 0.5, Vector3(0, 0, 1))
			p3.set_expression("neutral")
		"mouth":
			var p4 := _pet(GameState.species, GameState.current_fur_color(), GameState.material, GameState.current_eye_style(), id)
			var a2 := Data.anchors(GameState.species)
			_frame_box(Pet._v3(a2["mouth"]) + Vector3(0, 0.05, 0), 0.42, Vector3(0, 0, 1))
			p4.set_expression("neutral")
	var studio := PetAssets.studio_env()
	for m in _reg:
		m.set_shader_parameter("env_tex", studio)


func _pet(species: String, color: Color, material: String, eyes: String, mouth: String) -> Pet:
	var p := Pet.new()
	_holder.add_child(p)
	p.build(species, color, material, eyes, mouth, GameState.current_iris(), 10)
	p.set_process(false)
	p.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.8)
	return p


func _frame_node(node: Node3D, dir: Vector3) -> void:
	var aabb := AABB()
	var first := true
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		if gi.name.begins_with("shell_"):
			continue
		var b: AABB = gi.global_transform * gi.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	if first:
		aabb = AABB(Vector3(-0.3, 0, -0.3), Vector3(0.6, 0.6, 0.6))
	_frame_box(aabb.get_center(), aabb.size.length(), dir)


func _frame_box(center: Vector3, extent: float, dir: Vector3) -> void:
	var dist := (extent * 0.5) / tan(deg_to_rad(_cam.fov * 0.5)) * 1.05
	_cam.position = center + dir.normalized() * dist
	_cam.look_at(center, Vector3.UP)
