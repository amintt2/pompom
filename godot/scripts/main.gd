extends Node
## Point d'entree : mode bureau (PC) ou mode chambre (mobile, ou PC avec --room).

var stage: PetStage
var emotes: EmoteLayer


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var room := OS.has_feature("mobile") or args.has("--room")
	for a in args:
		if a.begins_with("--lookdev="):
			_lookdev(a.trim_prefix("--lookdev="))
			return
	_debug_overrides(args)
	stage = PetStage.new()
	add_child(stage)
	stage.build_from_state()
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	emotes = EmoteLayer.new()
	emotes.stage = stage
	layer.add_child(emotes)
	emotes.bind_pet(stage.pet)
	if room:
		var rc := RoomController.new()
		add_child(rc)
		rc.setup(stage, emotes)
	else:
		var dc := DesktopController.new()
		dc.name = "Desktop"
		add_child(dc)
		dc.setup(stage, emotes)


## Options de test (ne sont pas sauvegardees) :
##   --species=kiwi --material=gelee --eyes=shiny --mouth=cat --equip=crown,bow_tie --coins=999
##   --snap  : enregistre des images du rendu dans le dossier utilisateur (snap_*.png)
##   --quit-after-snap
func _debug_overrides(args: PackedStringArray) -> void:
	var debug := false
	for a in args:
		var kv := a.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		debug = true
		match kv[0]:
			"species": GameState.species = kv[1]
			"material":
				GameState.material = kv[1]
				var def: String = Data.MATERIALS.get(kv[1], {}).get("color", "")
				GameState.fur_color = def
			"eyes": GameState.eye_style = kv[1]
			"mouth": GameState.mouth_style = kv[1]
			"coins": GameState.coins = int(kv[1])
			"color": GameState.fur_color = kv[1]
			"reflect": GameState.settings["reflections"] = kv[1] == "1"
			"size": GameState.settings["size"] = float(kv[1])
			"quality": GameState.settings["fur_quality"] = int(kv[1])
			"equip":
				for id in kv[1].split(","):
					if Data.ITEMS.has(id):
						GameState.owned[id] = true
						GameState.equipped[Data.ITEMS[id]["slot"]] = id
	if debug:
		GameState.no_save = true
	if args.has("--snap"):
		_snap_loop(args.has("--quit-after-snap"))
	if args.has("--drop-test"):
		_drop_test()
	if args.has("--feed-test"):
		_feed_test()
	if args.has("--modes-test"):
		_modes_test()
	if args.has("--plat-test"):
		_plat_test()
	if args.has("--phone"):
		get_tree().create_timer(2.5).timeout.connect(func(): stage.pet.act_phone(30.0))


## Test : saute sur la premiere fenetre disponible.
func _plat_test() -> void:
	await get_tree().create_timer(3.0).timeout
	var dc := get_node_or_null("Desktop")
	if OS.get_cmdline_user_args().has("--sim-windows"):
		# fenetre simulee (le helper est mis en pause pour ne pas l'ecraser)
		Activity.set_process(false)
		Activity.windows = [{"id": 4242, "rect": Rect2(900, 700, 1000, 500), "max": false}]
	var plats: Array = dc._platforms()
	print("PLATFORMS ", plats.size(), " ", plats)
	for p in plats:
		if int(p["id"]) != 0:
			dc._jump_to(p)
			break
	if not OS.get_cmdline_user_args().has("--sim-windows"):
		return
	await get_tree().create_timer(2.0).timeout
	print("AFTER JUMP state=", dc.state, " plat=", dc.plat["id"], " foot=", dc._foot_y(), " cx=", dc._center_x())
	Activity.windows = [{"id": 4242, "rect": Rect2(500, 500, 1000, 500), "max": false}]
	await get_tree().create_timer(1.0).timeout
	print("AFTER MOVE state=", dc.state, " plat=", dc.plat["id"], " foot=", dc._foot_y(), " cx=", dc._center_x())
	Activity.windows = []
	await get_tree().create_timer(2.5).timeout
	print("AFTER CLOSE state=", dc.state, " plat=", dc.plat["id"], " foot=", dc._foot_y(), " taskbar=", dc._usable().end.y)
	get_tree().quit()


## Test : lui donne a manger les fichiers listes dans la variable d'environnement POMPOM_FEED_TEST (separes par ;).
func _feed_test() -> void:
	await get_tree().create_timer(3.0).timeout
	var dc := get_node_or_null("Desktop")
	GameState.settings["eat_confirmed"] = true
	GameState.hunger = 35.0
	var files := PackedStringArray(OS.get_environment("POMPOM_FEED_TEST").split(";", false))
	print("FEED before hunger=", GameState.hunger, " xp=", GameState.xp, " files=", files)
	dc.hud.show_needs(true)
	dc._on_files_dropped(files)
	var frames: Array[Image] = []
	for i in 8:
		await get_tree().create_timer(0.17).timeout
		frames.append(get_viewport().get_texture().get_image())
	var w := frames[0].get_width()
	var h := frames[0].get_height()
	var sheet := Image.create(w * frames.size(), h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.95, 0.93, 0.97))
	for i in frames.size():
		var f: Image = frames[i]
		f.convert(Image.FORMAT_RGBA8)
		sheet.blend_rect(f, Rect2i(0, 0, w, h), Vector2i(i * w, 0))
	sheet.save_png(ProjectSettings.globalize_path("user://feed.png"))
	await get_tree().create_timer(2.5).timeout
	print("FEED after hunger=", GameState.hunger, " xp=", GameState.xp, " level=", GameState.level, " eaten=", GameState.eaten)
	for f in files:
		print("FEED exists_after ", f, " ", FileAccess.file_exists(f))
	get_tree().quit()


## Comparaison avec les rendus Cycles de reference (blender/previews/mat_ref_<matiere>.png) :
## meme camera, meme image de fond (backdrop.png) qui sert aussi d'"ecran" refracte.
func _lookdev(mat_id: String) -> void:
	GameState.no_save = true
	var win := get_window()
	win.transparent = false
	win.borderless = false
	win.always_on_top = false
	win.size = Vector2i(600, 600)
	get_viewport().transparent_bg = false
	GameState.species = "mochi"
	GameState.material = mat_id
	GameState.fur_color = {"gelee": "ff4f86", "slime": "8ef25c"}.get(mat_id, str(Data.MATERIALS[mat_id].get("color", "")))
	GameState.eye_style = "dot"
	GameState.mouth_style = "smile"
	for slot in GameState.equipped:
		GameState.equipped[slot] = ""
	stage = PetStage.new()
	add_child(stage)
	stage.build_from_state(16)
	stage.catcher.visible = false
	stage.camera.fov = 24.0
	stage.camera.keep_aspect = Camera3D.KEEP_HEIGHT
	stage.camera.position = Vector3(0, 0.55, 6.0)
	stage.camera.rotation = Vector3.ZERO
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://../blender/previews/backdrop.png"))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(6, 6)
	quad.mesh = qm
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_texture = tex
	quad.material_override = sm
	quad.position = Vector3(0, 0.55, -0.62)
	stage.add_child(quad)
	var span := 2.0 * 6.62 * tan(deg_to_rad(12.0)) / 6.0
	stage.pet.set_wall_depth(-6.62)
	stage.pet.set_env(tex, Vector4(0.5 - span * 0.5, 0.5 - span * 0.5, span, span), Vector2(0.5, 0.5 - 0.0),
		0.3, 1.0, Vector2(1.0 / 6.0, 1.0 / 6.0), Color(0.5, 0.5, 0.55))
	stage.pet.set_process(false)
	stage.pet.set_expression("neutral")
	await get_tree().create_timer(2.5).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("user://lookdev_%s.png" % mat_id))
	print("LOOKDEV saved ", mat_id)
	get_tree().quit()


## Test des modes de vie et de la physique des fenetres (situations simulees).
func _modes_test() -> void:
	await get_tree().create_timer(3.0).timeout
	var dc := get_node_or_null("Desktop")
	Activity.set_process(false)
	var res := {"ok": 0, "ko": 0}
	var check := func(c: bool, what: String):
		if c:
			res["ok"] += 1
		else:
			res["ko"] += 1
			print("MODES FAIL ", what)
	print("MODES screens=", DisplayServer.get_screen_count())
	# 1) en jeu : les bulles vont dans la boite aux lettres
	Activity.category = "game"
	Activity.proc_name = "hades"
	Activity.game_name = "Hades"
	Activity.fullscreen = false
	dc._update_mode()
	check.call(dc.mode == "game" and dc._quiet(), "mode jeu silencieux")
	dc._say("Bravo !")
	check.call(dc._mail.size() == 1, "bulle mise dans la boite aux lettres")
	dc._session["start"] = Time.get_ticks_msec() / 1000.0 - 25.0 * 60.0
	# 2) plein ecran
	Activity.fullscreen = true
	dc._update_mode()
	await get_tree().create_timer(1.0).timeout
	if DisplayServer.get_screen_count() == 1:
		check.call(dc.state == "peek" and dc._pet_scale_target < 0.7, "periscope en plein ecran")
	# 3) fin du jeu : recap + courrier livre
	Activity.category = "work"
	Activity.fullscreen = false
	dc._update_mode()
	await get_tree().create_timer(2.5).timeout
	check.call(dc.hud.mail_count >= 2, "courrier livre (%d) avec recap" % dc.hud.mail_count)
	print("MODES mail=", dc._mail)
	check.call(dc.state in ["ground", "walk"], "retour sur la barre des taches (" + dc.state + ")")
	# 4) visio
	Activity.meeting = true
	dc._update_mode()
	await get_tree().create_timer(1.0).timeout
	check.call(dc.mode == "meeting" and dc.emotes.mute_emotes and dc._pet_scale_target < 0.7, "visio : petit et muet")
	Activity.meeting = false
	dc._update_mode()
	# 5) jeu competitif : cache
	Activity.category = "game"
	Activity.proc_name = "valorant"
	dc._update_mode()
	await get_tree().create_timer(0.8).timeout
	check.call(dc.state == "hidden", "competitif : cache")
	Activity.category = "work"
	Activity.proc_name = "code"
	dc._update_mode()
	await get_tree().create_timer(3.0).timeout
	# 6) fenetre : secousse, retrecissement, maximisation, fermeture
	Activity.windows = [{"id": 77, "rect": Rect2(800, 700, 900, 400), "max": false}]
	var plats: Array = dc._platforms()
	for pl in plats:
		if int(pl["id"]) == 77:
			dc.plat = pl.duplicate()
			dc.pos = Vector2(1200 - dc.W * 0.5, 700 - dc.H + dc.margin)
			dc.state = "ground"
			dc.pet.airborne = false
	await get_tree().create_timer(0.5).timeout
	check.call(int(dc.plat["id"]) == 77, "pose sur la fenetre")
	# retrecissement : le bord droit passe sous lui
	Activity.windows = [{"id": 77, "rect": Rect2(800, 700, 360, 400), "max": false}]
	await get_tree().create_timer(0.3).timeout
	check.call(int(dc.plat["id"]) == 77 and dc._center_x() <= 1160.0, "pousse par le bord (cx=%d)" % dc._center_x())
	Activity.windows = [{"id": 77, "rect": Rect2(800, 700, 900, 400), "max": false}]
	await get_tree().create_timer(0.3).timeout
	# secousse
	for i in 6:
		Activity.windows = [{"id": 77, "rect": Rect2(800 + (80 if i % 2 == 0 else -80), 700, 900, 400), "max": false}]
		await get_tree().create_timer(0.12).timeout
	await get_tree().create_timer(1.2).timeout
	check.call(dc.state in ["fall", "ground", "hang"], "secousse : vertige (%s)" % dc.state)
	# maximisation : ascenseur
	await get_tree().create_timer(2.0).timeout
	Activity.windows = [{"id": 78, "rect": Rect2(900, 600, 900, 400), "max": false}]
	for pl in dc._platforms():
		if int(pl["id"]) == 78:
			dc.plat = pl.duplicate()
			dc.pos = Vector2(1300 - dc.W * 0.5, 600 - dc.H + dc.margin)
			dc.state = "ground"
	await get_tree().create_timer(0.3).timeout
	Activity.windows = [{"id": 78, "rect": Rect2(0, 0, 2560, 1380), "max": true}]
	await get_tree().create_timer(0.1).timeout
	check.call(dc.state == "fall" and dc.vel.y < 0.0, "maximisee : ascenseur")
	await get_tree().create_timer(3.0).timeout
	# fermeture : suspendu puis chute
	Activity.windows = [{"id": 79, "rect": Rect2(900, 600, 900, 400), "max": false}]
	for pl in dc._platforms():
		if int(pl["id"]) == 79:
			dc.plat = pl.duplicate()
			dc.pos = Vector2(1300 - dc.W * 0.5, 600 - dc.H + dc.margin)
			dc.state = "ground"
	await get_tree().create_timer(0.3).timeout
	print("MODES avant fermeture state=", dc.state, " plat=", dc.plat["id"])
	Activity.windows = []
	await get_tree().create_timer(0.1).timeout
	print("MODES apres fermeture state=", dc.state)
	check.call(dc.state == "hang", "fermee : suspendu en l'air")
	await get_tree().create_timer(0.8).timeout
	check.call(dc.state in ["fall", "ground"], "puis il tombe")
	print("MODES TEST: %d ok, %d ko" % [res["ok"], res["ko"]])
	get_tree().quit()


func _drop_test() -> void:
	await get_tree().create_timer(2.0).timeout
	var dc := get_node_or_null("Desktop")
	dc.pos.y -= 350.0 * dc.s
	dc.vel = Vector2.ZERO
	dc.state = "fall"
	var frames: Array[Image] = []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1900:
		await RenderingServer.frame_post_draw
		if dc.state != "fall" or dc.pos.y > dc._ground_y() - 120.0 * dc.s:
			frames.append(get_viewport().get_texture().get_image())
	# planche : 8 images reparties
	var n := mini(8, frames.size())
	var w := frames[0].get_width()
	var h := frames[0].get_height()
	var sheet := Image.create(w * n, h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.16, 0.16, 0.19))
	for i in n:
		var f: Image = frames[int(float(i) / n * frames.size())]
		f.convert(Image.FORMAT_RGBA8)
		sheet.blend_rect(f, Rect2i(0, 0, w, h), Vector2i(i * w, 0))
	sheet.save_png(ProjectSettings.globalize_path("user://drop.png"))
	get_tree().quit()


func _snap_loop(quit_after: bool) -> void:
	for i in 4:
		await get_tree().create_timer(2.5 if i == 0 else 1.6).timeout
		var img := get_viewport().get_texture().get_image()
		var path := ProjectSettings.globalize_path("user://snap_%d.png" % i)
		img.save_png(path)
		var w := get_window()
		var bg := DisplayServer.screen_get_image_rect(Rect2i(w.position, w.size))
		if bg:
			bg.save_png(ProjectSettings.globalize_path("user://snap_bg_%d.png" % i))
		print("SNAP ", path)
		if i == 1:
			stage.pet.act_love()
		if i == 2:
			stage.pet.land(4.0)
	var dc := get_node_or_null("Desktop")
	if dc and dc.capture.texture:
		dc.capture.texture.get_image().save_png(ProjectSettings.globalize_path("user://snap_env.png"))
	print("ACTIVITY available=", Activity.available, " cat=", Activity.category, " proc=", Activity.proc_name, " idle=", Activity.idle_sec)
	if quit_after:
		get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		GameState.save_game()
		Activity.stop()
