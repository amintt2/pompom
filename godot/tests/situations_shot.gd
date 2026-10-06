extends Node
## Planche de toutes les situations (PetSituations) : chaque situation joue ~1,7 s puis on prend une photo.
##   Godot --path godot res://tests/situations_shot.tscn [-- --species=pico --only=coding,reading --scale=2 --hold=1.7]
## Sorties (dossier utilisateur, %APPDATA%/Pompom) :
##   situations_sheet.png      cases a la taille reelle du bureau (260 x 300)
##   situations_sheet_2x.png   cases agrandies (rendu natif x2) pour verifier les details

const COLS := 8
const BG := Color("5d6b82")

var stage: PetStage
var emotes: EmoteLayer
var sit: PetSituations
var label: Label
var S := 2.0
var W := 520
var H := 600
var hold := 1.7
var species := "mochi"
var only: Array = []
var equip: Array = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--species="):
			species = a.trim_prefix("--species=")
		elif a.begins_with("--only="):
			only = Array(a.trim_prefix("--only=").split(","))
		elif a.begins_with("--scale="):
			S = float(a.trim_prefix("--scale="))
		elif a.begins_with("--hold="):
			hold = float(a.trim_prefix("--hold="))
		elif a.begins_with("--equip="):
			equip = Array(a.trim_prefix("--equip=").split(","))
	GameState.no_save = true
	GameState.species = species
	GameState.material = "peluche"
	GameState.fur_color = ""
	GameState.eye_style = ""
	for slot in GameState.equipped:
		GameState.equipped[slot] = ""
	for id in equip:
		if Data.ITEMS.has(id):
			GameState.equipped[Data.ITEMS[id]["slot"]] = id
	get_tree().create_timer(400.0).timeout.connect(func(): get_tree().quit(2))
	W = int(260 * S)
	H = int(300 * S)
	var win := get_window()
	win.transparent = false
	win.borderless = false
	win.always_on_top = false
	win.unfocusable = true
	win.size = Vector2i(W, H)
	win.position = Vector2i(40, 40)
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(BG)
	stage = PetStage.new()
	add_child(stage)
	stage.build_from_state(12)
	stage.frame(Vector2(W, H), 100.0 * S, 14.0 * S)
	stage.pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.8)
	var layer := CanvasLayer.new()
	add_child(layer)
	emotes = EmoteLayer.new()
	emotes.stage = stage
	layer.add_child(emotes)
	emotes.bind_pet(stage.pet)
	label = Label.new()
	label.position = Vector2(8, 6) * S
	label.add_theme_font_size_override("font_size", int(12 * S))
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("outline_size", int(4 * S))
	layer.add_child(label)
	sit = PetSituations.new()
	sit.name = "Situations"
	add_child(sit)
	sit.setup(stage.pet, stage)
	sit.talk_chance = 0.0
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(1.0).timeout
	var ids: Array = []
	for id in PetSituations.BEHAVIOURS:
		if only.is_empty() or only.has(id):
			ids.append(id)
	var rows := int(ceil(ids.size() / float(COLS)))
	var cols := mini(COLS, ids.size())
	var sheet := Image.create(cols * W, rows * H, false, Image.FORMAT_RGBA8)
	sheet.fill(BG)
	var i := 0
	for id in ids:
		label.text = "%s · %s" % [id, Situations.label(id)]
		# curseur "utilisateur" en haut a droite : les situations qui suivent le curseur regardent par la
		sit.set_cursor(Vector2(get_window().position) + Vector2(W * 1.6, -H * 0.4), 60.0)
		var ok := sit.play(id, 60.0, {"late": false})
		if not ok:
			print("SHOT play refuse : ", id)
		await get_tree().create_timer(hold).timeout
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, Vector2i(W, H)), Vector2i((i % COLS) * W, (i / COLS) * H))
		print("SHOT ", id, " playing=", sit.playing, " props=", sit._props.keys())
		sit.stop()
		stage.pet.stop_action()
		stage.pet.hide_all_props()
		await get_tree().create_timer(0.45).timeout
		i += 1
	var suffix := "" if species == "mochi" and equip.is_empty() else "_" + species + ("_" + "+".join(equip) if not equip.is_empty() else "")
	var p2 := ProjectSettings.globalize_path("user://situations_sheet%s_2x.png" % suffix)
	sheet.save_png(p2)
	var small := sheet.duplicate() as Image
	small.resize(int(sheet.get_width() / S), int(sheet.get_height() / S), Image.INTERPOLATE_LANCZOS)
	var p1 := ProjectSettings.globalize_path("user://situations_sheet%s.png" % suffix)
	small.save_png(p1)
	print("SHEET ", p1)
	print("SHEET ", p2)
	if only.is_empty():
		await _behaviour_checks()
	sit.queue_free()
	stage.queue_free()
	await get_tree().process_frame
	PetSituations.free_cache()
	get_tree().quit()


## Verifications du cycle de vie : fin normale, interruption par une action, stop(), changement de situation.
func _behaviour_checks() -> void:
	var pet := stage.pet
	var res := {"ok": 0, "ko": 0}
	var check := func(c: bool, what: String):
		if c:
			res["ok"] += 1
		else:
			res["ko"] += 1
			print("BEHAVIOUR FAIL ", what)
	var log := {"moves": 0, "finished": 0, "interrupted": 0}
	sit.move_started.connect(func(_s, _m): log["moves"] += 1)
	sit.finished.connect(func(_s): log["finished"] += 1)
	sit.interrupted.connect(func(_s): log["interrupted"] += 1)
	# 1) fin normale
	sit.play("reading", 3.0)
	await get_tree().create_timer(0.6).timeout
	check.call(sit.playing and pet.busy, "reading demarre (busy)")
	await get_tree().create_timer(6.5).timeout
	check.call(log["finished"] == 1 and not sit.playing and not pet.busy, "reading se termine seule")
	check.call(log["moves"] >= 1 and log["moves"] < 25, "micro-actions espacees (%d)" % log["moves"])
	await get_tree().create_timer(0.5).timeout
	check.call(sit._props.is_empty() and stage.pet.root_node.get_children().filter(func(c): return c.name == "book").is_empty(),
		"objets retires")
	# 2) interruption par une action du compagnon (poke)
	sit.play("coding", 30.0)
	await get_tree().create_timer(1.0).timeout
	pet.act_surprised()
	await get_tree().process_frame
	await get_tree().process_frame
	check.call(not sit.playing and log["interrupted"] == 1, "coding interrompu par act_surprised")
	await get_tree().create_timer(1.2).timeout
	check.call(not pet.busy, "busy libere apres l'action")
	# 3) attrape (carried)
	sit.play("music_listen", 30.0)
	await get_tree().create_timer(0.8).timeout
	pet.carried = true
	await get_tree().process_frame
	await get_tree().process_frame
	check.call(not sit.playing, "music_listen interrompu quand on le porte")
	pet.carried = false
	await get_tree().create_timer(0.5).timeout
	# 4) stop() explicite + changement de situation
	sit.play("chat", 30.0)
	await get_tree().create_timer(0.8).timeout
	sit.play("shopping", 30.0)
	await get_tree().create_timer(0.8).timeout
	check.call(sit.current == "shopping" and sit._props.has("shopping_bag") and not sit._props.has("phone"), "chat -> shopping")
	sit.stop()
	await get_tree().process_frame
	check.call(not sit.playing and not pet.busy and absf(pet.yaw) < 0.5, "stop() immediat")
	# 5) refus quand il dort
	pet.sleeping = true
	check.call(not sit.play("coding"), "refus pendant le sommeil")
	pet.sleeping = false
	# 6) accessoire respecte : il porte deja un chapeau -> pas de casque
	pet.set_item("head", "crown", GameState.colors_for("crown"), false)
	sit.play("music_listen", 30.0)
	await get_tree().create_timer(0.8).timeout
	check.call(sit._worn.is_empty(), "casque non ajoute par-dessus la couronne")
	sit.stop()
	pet.set_item("head", "", {}, false)
	await get_tree().create_timer(0.4).timeout
	print("BEHAVIOUR %d ok, %d echecs" % [res["ok"], res["ko"]])
