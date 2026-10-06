class_name PetStage
extends Node3D
## Scene 3D minimale : camera, lumieres, environnement et le compagnon.
## Utilisee par la fenetre du bureau, l'aperçu de la boutique et le mode mobile.

var camera: Camera3D
var pet: Pet
var key_light: DirectionalLight3D
var fill_light: DirectionalLight3D
var world_env: WorldEnvironment
var catcher: MeshInstance3D
var ppu := 100.0  # pixels par unite monde
const WALL_OFFSET := 0.62  # distance entre le centre du compagnon et le "mur" (l'ecran)


func _init() -> void:
	camera = Camera3D.new()
	camera.fov = 24.0
	camera.near = 0.1
	camera.far = 100.0
	add_child(camera)

	key_light = DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-41.3, -45.0, 0)
	key_light.light_energy = 1.05
	key_light.light_color = Color(1.0, 0.97, 0.93)
	key_light.light_specular = 0.9
	key_light.shadow_enabled = true
	key_light.shadow_blur = 2.5
	key_light.shadow_bias = 0.03
	key_light.shadow_normal_bias = 1.5
	key_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key_light.directional_shadow_max_distance = 12.0
	add_child(key_light)

	fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-15, 150, 0)
	fill_light.light_energy = 0.45
	fill_light.light_color = Color(0.85, 0.9, 1.0)
	fill_light.light_specular = 0.4
	add_child(fill_light)

	world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.9, 0.88, 0.95)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	world_env.environment = env
	add_child(world_env)

	pet = Pet.new()
	pet.name = "Pet"
	add_child(pet)

	# mur invisible = l'ecran derriere : ne montre que l'ombre portee du compagnon
	catcher = MeshInstance3D.new()
	catcher.name = "catcher"
	var q := QuadMesh.new()
	q.size = Vector2(14, 14)
	catcher.mesh = q
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/shadow_catcher.gdshader")
	catcher.material_override = m
	catcher.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	catcher.position = Vector3(0, 3, -WALL_OFFSET)
	add_child(catcher)


## Cadre la camera pour que `ppu` pixels = 1 unite, avec le sol a `ground_margin` px du bas.
func frame(view_size: Vector2, p_ppu: float, ground_margin: float) -> void:
	ppu = p_ppu
	var vis_h := view_size.y / ppu
	var dist := (vis_h * 0.5) / tan(deg_to_rad(camera.fov * 0.5))
	var cy := (view_size.y * 0.5 - ground_margin) / ppu
	camera.position = Vector3(0, cy, dist)
	camera.rotation = Vector3.ZERO
	pet.set_wall_depth(-dist - WALL_OFFSET)


## Construit le compagnon selon l'etat sauvegarde.
func build_from_state(shells := -1) -> void:
	if shells < 0:
		shells = int(GameState.settings.get("fur_quality", 16))
	pet.build(GameState.species, GameState.current_fur_color(), GameState.material,
		GameState.current_eye_style(), GameState.mouth_style, GameState.current_iris(), shells)
	for slot in Data.SLOTS:
		var id: String = GameState.equipped.get(slot, "")
		pet.set_item(slot, id, GameState.colors_for(id) if id != "" else {}, false)


## Adapte l'eclairage a la couleur moyenne de l'ecran autour (avg).
func match_screen_light(avg: Color) -> void:
	var lum := avg.get_luminance()
	var env := world_env.environment
	env.ambient_light_color = Color(0.9, 0.88, 0.95).lerp(avg.lightened(0.25), 0.55)
	env.ambient_light_energy = lerpf(0.3, 0.55, lum)
	key_light.light_energy = lerpf(0.85, 1.1, lum)
	fill_light.light_color = Color(0.85, 0.9, 1.0).lerp(avg, 0.6)
	fill_light.light_energy = lerpf(0.3, 0.6, lum)
