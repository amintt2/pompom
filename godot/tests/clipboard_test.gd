extends Node
## Test du gardien de presse-papiers (ClipboardKeeper + HeldItemsLayer).
## Lancer : Godot --path godot res://tests/clipboard_test.tscn [-- --scale=1.5]
## Affiche "PASS ..." / "FAIL ..." / "SKIP ..." puis "CLIPBOARD TEST RESULT: x passed, y failed, z errors".
## Captures : tests/screenshots/clipboard_*.png (+ clipboard_sheet.png qui les rassemble).
## Le presse-papiers reel de l'utilisateur est sauvegarde puis restaure.

const SHOTS := "res://tests/screenshots/"

var stage: PetStage
var emotes: EmoteLayer
var keeper: ClipboardKeeper
var layer: HeldItemsLayer
var passed := 0
var failed := 0
var fails: Array[String] = []
var shots: Array[Image] = []
var shot_names: Array[String] = []
var logger: ErrLogger
var sc := 1.5
var W := 260
var H := 300
var prev_text := ""
var prev_img: Image
var os_ok := false
var finished := false


class ErrLogger extends Logger:
	var errors: Array[String] = []
	var busy := 0
	var mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var msg := "%s (%s:%d %s) %s" % [rationale if rationale != "" else code, file.get_file(), line, function, code]
		if "leaked" in msg or "still in use at exit" in msg or "PagedAllocator" in msg or "were never freed" in msg:
			return
		if "Unable to open clipboard" in msg:
			busy += 1  # presse-papiers tenu un instant par une autre appli (historique Windows...) : environnement
			return
		mutex.lock()
		errors.append(msg)
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


## EmoteLayer gere maintenant lui-meme `bubble_lift` (bulles au-dessus de la carte).
class LiftedEmotes extends EmoteLayer:
	pass


func check(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("PASS ", name)
	else:
		failed += 1
		fails.append(name)
		print("FAIL ", name)


func _ready() -> void:
	logger = ErrLogger.new()
	OS.add_logger(logger)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scale="):
			sc = float(a.get_slice("=", 1))
	W = int(260 * sc)
	H = int(300 * sc)
	GameState.no_save = true
	GameState.settings["clipboard"] = false
	GameState.settings["screenshots"] = false  # teste a part (section 10)
	GameState.settings["talk"] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))
	var w := get_window()
	w.transparent = false
	w.borderless = false
	w.always_on_top = false
	w.unfocusable = false
	w.size = Vector2i(W, H)
	w.position = Vector2i(80, 80)
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color("e8e3ef"))
	stage = PetStage.new()
	add_child(stage)
	stage.build_from_state()
	stage.frame(Vector2(W, H), 100.0 * sc, 14.0 * sc)
	stage.pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.8)
	var cl := CanvasLayer.new()
	cl.layer = 5
	add_child(cl)
	emotes = LiftedEmotes.new()
	emotes.stage = stage
	cl.add_child(emotes)
	emotes.bind_pet(stage.pet)
	keeper = ClipboardKeeper.new()
	keeper.name = "Clipboard"
	add_child(keeper)
	keeper.ignore_own_focus = false  # la fenetre de test a le focus
	keeper.accept_own_copies = true  # c'est le test qui remplit le presse-papiers
	keeper.sim_mouse = true
	keeper.save_dir = "user://clipboard_test_drop"
	keeper.setup(stage, emotes)
	layer = keeper.layer
	get_tree().create_timer(150.0).timeout.connect(func():
		print("=== WATCHDOG: test took too long ===")
		_finish())
	_run.call_deferred()


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(SHOTS + "clipboard_" + name + ".png"))
	shots.append(img)
	shot_names.append(name)
	print("SHOT ", name)


## Le presse-papiers peut etre occupe un instant (historique Windows...) : on reessaie.
func set_clip(text: String) -> bool:
	for i in 10:
		DisplayServer.clipboard_set(text)
		await frames(1)
		if DisplayServer.clipboard_get() == text:
			return true
		await wait(0.05)
	return false


func card_center() -> Vector2:
	return layer._card_xf * Vector2(0, -layer._card_size.y * 0.5)


func click(pos: Vector2, button := MOUSE_BUTTON_LEFT) -> bool:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.position = pos
	e.pressed = true
	var a := keeper.handle_input(e)
	var e2 := e.duplicate() as InputEventMouseButton
	e2.pressed = false
	var b := keeper.handle_input(e2)
	return a or b


func move(pos: Vector2) -> bool:
	var m := InputEventMouseMotion.new()
	m.position = pos
	return keeper.handle_input(m)


func wait_pet_idle() -> void:
	var t := 0
	while stage.pet.busy and t < 200:
		await get_tree().process_frame
		t += 1


static func test_image(w: int, h: int) -> Image:
	# "photo" coloree : ciel degrade, soleil, collines, petit coeur
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / h
		var sky := Color("8fd3ff").lerp(Color("ffd6ea"), t)
		for x in w:
			var c := sky
			var hill := h * (0.68 + 0.08 * sin(x * 0.02))
			var hill2 := h * (0.78 + 0.06 * sin(x * 0.013 + 2.0))
			if y > hill:
				c = Color("7ccf8a").lerp(Color("4fae6d"), (y - hill) / (h - hill))
			if y > hill2:
				c = Color("5bbf7a").lerp(Color("3c9a5c"), (y - hill2) / (h - hill2))
			var d := Vector2(x, y).distance_to(Vector2(w * 0.74, h * 0.28))
			if d < h * 0.13:
				c = Color("ffe066")
			elif d < h * 0.17:
				c = c.lerp(Color("fff2a8"), 0.5)
			img.set_pixel(x, y, c)
	# coeur
	var hc := Vector2(w * 0.3, h * 0.42)
	var hs := h * 0.13
	for y in range(int(hc.y - hs * 1.3), int(hc.y + hs * 1.3)):
		for x in range(int(hc.x - hs * 1.3), int(hc.x + hs * 1.3)):
			var px := (x - hc.x) / hs
			var py := -(y - hc.y) / hs
			var q := px * px + py * py - 1.0
			if q * q * q - px * px * py * py * py <= 0.0:
				img.set_pixel(x, y, Color("ff5d8f"))
	return img


func _run() -> void:
	await frames(5)
	# ------------------------------------------------------------------ 1. secrets
	var secrets := ["hunter2!X", "P@ssw0rd123", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "sk-proj-AbC123dEf456GhI789",
		"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc", "4532015112830366", "FR7630006000011234567890189",
		"mot de passe : chaton42", "a8f5f167f44f4964e6c998dee827110c", "xK9#mQ2$vL7&"]
	var normal := ["Bonjour, ça va ?", "https://example.com/page?id=3", "bonjour", "C:\\Users\\alice\\Documents",
		"amin@example.com", "Rendez-vous demain à 14h", "1234", "Pompom", "anticonstitutionnellement", "HelloWorld",
		"Penser à acheter des croquettes"]
	for t in secrets:
		check(ClipboardKeeper.looks_secret(t), "secret detecte : " + t.substr(0, 12))
	for t in normal:
		check(not ClipboardKeeper.looks_secret(t), "texte normal garde : " + t.substr(0, 16))

	# ------------------------------------------------------------------ 2. reglage desactive par defaut
	check(not keeper.enabled, "desactive par defaut (opt-in)")
	check(keeper.bounds() == Rect2(), "aucune zone cliquable quand desactive")
	GameState.set_setting("clipboard", true)
	check(keeper.enabled, "active par le reglage 'clipboard'")

	# ------------------------------------------------------------------ 3. vrai presse-papiers (si accessible)
	prev_text = DisplayServer.clipboard_get()
	prev_img = DisplayServer.clipboard_get_image() if DisplayServer.clipboard_has_image() else null
	var probe := "Pompom test %d" % randi()
	os_ok = await set_clip(probe)
	if not os_ok:
		print("SKIP presse-papiers du systeme inaccessible dans cet environnement (session restreinte) : tests par injection")
	else:
		# attendre le helper (ou le repli) puis copier un vrai texte
		var t0 := Time.get_ticks_msec()
		while keeper._mode == "starting" and Time.get_ticks_msec() - t0 < 9000:
			await frames(1)
		print("INFO mode de surveillance : ", keeper._mode)
		var txt := "Liste de courses : croquettes, pommes, chocolat noir et un petit bouquet de fleurs"
		await wait(0.5)
		await set_clip(txt)
		t0 = Time.get_ticks_msec()
		while (keeper.items.is_empty() or keeper.items[0]["text"] != txt) and Time.get_ticks_msec() - t0 < 4000:
			await frames(1)
		check(not keeper.items.is_empty() and keeper.items[0]["text"] == txt, "texte copie detecte (%s)" % keeper._mode)
		# secret : ignore
		await set_clip("Tr0ub4dor&3xyz")
		await wait(1.0)
		check(keeper.items.size() == 1 and keeper.last_skip_reason == "secret", "mot de passe copie ignore")
		# image via le helper
		if keeper._mode == "helper":
			var img := test_image(320, 200)
			keeper._write_cmd("img " + Marshalls.raw_to_base64(img.save_png_to_buffer()))
			t0 = Time.get_ticks_msec()
			while (keeper.items.is_empty() or keeper.items[0]["kind"] != "image") and Time.get_ticks_msec() - t0 < 5000:
				await frames(1)
			var ok_img: bool = not keeper.items.is_empty() and keeper.items[0]["kind"] == "image"
			check(ok_img, "image copiee detectee (helper)")
			if ok_img:
				var got: Image = keeper.items[0]["image"]
				check(got.get_width() == 320 and got.get_height() == 200, "image gardee en pleine resolution")
		else:
			print("SKIP image systeme : pas de helper (Godot 4.7 n'a pas clipboard_set_image)")
		# copier de nouveau un objet garde -> remis dans le presse-papiers
		var tit := {}
		for it in keeper.items:
			if it["kind"] == "text":
				tit = it
		if not tit.is_empty():
			keeper.copy_item(tit)
			var t2 := Time.get_ticks_msec()
			while DisplayServer.clipboard_get() != txt and Time.get_ticks_msec() - t2 < 3000:
				await wait(0.1)
			check(DisplayServer.clipboard_get() == txt, "clic : texte remis dans le presse-papiers")
		keeper.stop()
		GameState.set_setting("clipboard", false)
		GameState.set_setting("clipboard", true)
		check(keeper.items.is_empty(), "desactiver efface l'historique")

	# ------------------------------------------------------------------ 4. injection : objets et limites
	keeper.items.clear()
	var photo := test_image(640, 400)
	var it_img := keeper.ingest_image(photo)
	check(it_img.get("kind", "") == "image", "image ajoutee")
	check((it_img["thumb"] as Texture2D).get_width() <= ClipboardKeeper.THUMB_PX, "miniature reduite (<= 192 px)")
	check((it_img["image"] as Image).get_width() == 640, "pleine resolution gardee en memoire")
	keeper.ingest_text("Penser à acheter des croquettes pour Mochi demain matin, et appeler mamie !")
	keeper.ingest_image(test_image(200, 260))
	var dup := keeper.ingest_image(photo)
	check(keeper.items.size() == 3 and dup == keeper.items[0], "recopier le meme objet le remonte (pas de doublon)")
	var sk := keeper.ingest_text("sk-proj-AbC123dEf456GhI789xyz")
	check(sk.is_empty() and keeper.last_skip_reason == "secret", "secret injecte ignore")
	for i in 5:
		keeper.ingest_text("Note numéro %d : un petit texte" % i)
	check(keeper.items.size() == ClipboardKeeper.MAX_ITEMS, "historique limite a 5")
	keeper.items.clear()
	keeper.ingest_text("Penser à acheter des croquettes pour Mochi demain matin, et appeler mamie !")
	keeper.ingest_text("Le rendez-vous est à 14 h 30, salle B")
	keeper.ingest_image(photo)
	await wait(1.2)
	await wait_pet_idle()
	await shot("1_image")
	check(keeper.bounds().size.x > 20, "bounds() non vide avec une carte")
	var b := keeper.bounds()
	var hp := layer.head_pos()
	check(b.has_point(hp + Vector2(0, -10 * sc)), "bounds() couvre la carte au-dessus de la tete")

	# ------------------------------------------------------------------ 5. clics
	var copied := []
	keeper.item_copied.connect(func(it): copied.append(it))
	check(not keeper.handle_click(Vector2(3, 3)), "clic dans le vide : non consomme")
	check(keeper.top_item()["kind"] == "image", "la derniere copie est sur le dessus")
	check(keeper.handle_click(card_center()), "clic sur la carte image : consomme")
	if keeper._running:
		check(copied.size() == 1 and copied[0] == keeper.items[0], "clic sur l'image : recopiee via le helper")
	else:
		check(copied.is_empty() and layer._pills.size() == 1, "image sans helper : message clair, pas de faux 'Copié'")
	await wait(2.0)
	# copie d'une note
	keeper.cycle()
	await wait(0.5)
	copied.clear()
	check(keeper.handle_click(card_center()) and copied.size() == 1, "clic sur la note : texte recopie")
	await wait(0.35)
	await shot("2_copied")
	keeper.cycle()
	keeper.cycle()
	# badge +N -> objet suivant
	var top0 := keeper.top_item()
	await wait(1.6)
	check(layer._badge_c != Vector2.INF and keeper.handle_click(layer._badge_c), "clic sur le badge +N")
	check(keeper.top_item() != top0, "le badge fait passer a l'objet suivant")
	await wait(0.8)
	await shot("3_note")
	# survol : croix + aide
	layer.sim_mouse_pos = card_center()
	await wait(1.0)
	await shot("4_hover")
	var close_hit := layer.hit_test(layer._close_c)
	check(close_hit.get("zone", "") == "close", "croix visible au survol")
	var n0 := keeper.items.size()
	check(click(layer._close_c), "clic sur la croix")
	check(keeper.items.size() == n0 - 1, "la croix oublie l'objet")
	layer.sim_mouse_pos = Vector2(-100, -100)
	await wait(0.6)
	# clic droit
	keeper.ingest_text("À oublier tout de suite")
	await wait(0.6)
	n0 = keeper.items.size()
	check(click(card_center(), MOUSE_BUTTON_RIGHT), "clic droit sur la carte : consomme")
	check(keeper.items.size() == n0 - 1, "clic droit oublie l'objet")
	await wait(0.6)

	# ------------------------------------------------------------------ 6. fatigue (temps accelere)
	keeper.items.clear()
	keeper.ingest_text("Penser à acheter des croquettes pour Mochi demain matin, et appeler mamie !")
	keeper.ingest_image(photo)
	await wait(0.8)
	await wait_pet_idle()
	var top := keeper.top_item()
	check(keeper.tired_level() == 0, "frais au debut")
	keeper.time_scale = 240.0  # 1 s reelle = 4 min
	await wait(0.6)
	keeper.time_scale = 1.0
	check(float(top["hold"]) > 100.0, "time_scale accelere le temps porte (%.0f s)" % float(top["hold"]))
	top["hold"] = 130.0
	await wait_pet_idle()
	keeper._tired_cd = 0.0
	keeper.tick(0.016)
	await frames(3)
	check(keeper.tired_level() == 1, "fatigue niveau 1 apres 2 min")
	check(stage.pet.expression == "meh" or stage.pet.busy, "il montre sa fatigue (meh / action)")
	await wait(2.5)
	await wait_pet_idle()
	top["hold"] = 320.0
	keeper._tired_cd = 0.0
	keeper.tick(0.016)
	await frames(3)
	check(keeper.tired_level() == 2, "fatigue niveau 2 apres 5 min")
	check(stage.pet.expression == "sad" or stage.pet.busy, "il peine (triste / s'affaisse)")
	stage.pet.say(ClipboardKeeper.LINES_TIRED_2[0])  # pour la capture : la bulle passe au-dessus de la carte
	await wait(0.7)
	await shot("5_tired")
	await wait(2.5)
	await wait_pet_idle()
	var put := []
	keeper.item_put_down.connect(func(it): put.append(it))
	top["hold"] = 601.0
	keeper.tick(0.016)
	check(keeper.head_items().is_empty() and keeper.feet_items().size() == 2, "apres 10 min il pose tout a ses pieds")
	check(put.size() == 2 and keeper.items.size() == 2, "rien n'est perdu (historique au sol)")
	await wait(1.4)
	await shot("6_pile")
	# reprendre depuis le tas
	var pile_top: Dictionary = keeper.feet_items()[0]
	check(keeper.handle_click(layer._pile_rect.get_center()), "clic sur le tas : consomme")
	check(keeper.top_item() == pile_top and float(pile_top["hold"]) == 0.0, "le tas redonne l'objet (sur sa tete)")
	await wait(1.0)

	# ------------------------------------------------------------------ 7. glisser-deposer
	await wait_pet_idle()
	var cc := card_center()
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.position = cc
	e.pressed = true
	check(keeper.handle_input(e), "appui sur la carte : consomme")
	for i in 8:
		move(cc + Vector2(i * 9, -i * 3) * sc)
		await frames(1)
	check(keeper.is_dragging(), "glisser commence apres quelques pixels")
	await wait(0.2)
	await shot("7_drag")
	# lacher dans la fenetre (pas sur le tas) -> retour sur la tete
	var e2 := e.duplicate() as InputEventMouseButton
	e2.pressed = false
	e2.position = cc + Vector2(63, -21) * sc
	keeper.handle_input(e2)
	check(not keeper.is_dragging() and keeper.top_item() == pile_top, "lacher dans la fenetre : retour sur la tete")
	await wait(0.5)
	# glisser sur le tas -> pose
	keeper.handle_input(e)
	var pr := layer.pile_drop_rect().get_center()
	for i in 6:
		move(cc.lerp(pr, (i + 1) / 6.0))
		await frames(1)
	e2.position = pr
	keeper.handle_input(e2)
	check(keeper.feet_items().has(pile_top), "glisser sur le tas : pose a ses pieds")
	await wait(1.0)
	# glisser hors de la fenetre -> copie + image enregistree
	keeper.pick_up(keeper.feet_items()[0], false)
	await wait(0.8)
	var img_item := keeper.top_item()
	if img_item["kind"] != "image":
		keeper.cycle()
		img_item = keeper.top_item()
	cc = card_center()
	e.position = cc
	keeper.handle_input(e)
	for i in 6:
		move(cc + Vector2(-i * 25, 0) * sc)
		await frames(1)
	keeper.sim_outside = true
	e2.position = cc + Vector2(-200, 0) * sc
	copied.clear()
	keeper.handle_input(e2)
	keeper.sim_outside = false
	check(copied.size() >= 1, "lacher dehors : objet copie")
	check(keeper.feet_items().has(img_item), "lacher dehors : il est soulage (objet au sol)")
	var t1 := Time.get_ticks_msec()
	var saved := ""
	while saved == "" and Time.get_ticks_msec() - t1 < 4000:
		await frames(2)
		var d := ProjectSettings.globalize_path(keeper.save_dir)
		for f in DirAccess.get_files_at(d):
			if f.ends_with(".png"):
				saved = d.path_join(f)
	check(saved != "" and Image.load_from_file(saved).get_width() == 640, "image deposee enregistree en PNG (pleine resolution)")
	await wait(0.3)
	await shot("8_dropped")
	for f in DirAccess.get_files_at(ProjectSettings.globalize_path(keeper.save_dir)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(keeper.save_dir).path_join(f))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(keeper.save_dir))

	# ------------------------------------------------------------------ 8. fichiers
	keeper.items.clear()
	var f1 := ProjectSettings.globalize_path("res://project.godot")
	var f2 := ProjectSettings.globalize_path("res://icon.svg")
	var fi := keeper.ingest_files(PackedStringArray([f1]))
	check(fi.get("kind", "") == "file" and fi["title"] == "project.godot", "fichier copie : carte fichier")
	var fimg := keeper.ingest_files(PackedStringArray([f2]))
	check(fimg.get("kind", "") == "image", "fichier image copie : carte image")
	keeper.ingest_files(PackedStringArray([f1, f2, f1]), 3)
	await wait(1.2)
	await shot("9_files")

	# ------------------------------------------------------------------ 9. desactivation
	GameState.set_setting("clipboard", false)
	await frames(3)
	check(keeper.items.is_empty() and keeper.bounds() == Rect2() and not keeper._running, "desactiver : tout est oublie, helper arrete")

	# ------------------------------------------------------------------ 10. captures d'ecran seulement
	GameState.set_setting("screenshots", true)
	await frames(3)
	check(keeper.enabled and keeper.shots_only, "mode captures : actif seul, filtre")
	var before := keeper.items.size()
	keeper._on_clip_event({"seq": 9001, "proc": "notepad", "txt": true, "img": false, "files": []})
	keeper._on_clip_event({"seq": 9002, "proc": "chrome", "txt": false, "img": true, "files": []})
	await frames(3)
	check(keeper.items.size() == before, "mode captures : textes et images d'autres applis ignores")
	check(Data != null and keeper.SNIP_PROCS.has("snippingtool") and keeper.SNIP_PROCS.has("screenclippinghost"), "mode captures : Outil Capture d'ecran reconnu")
	GameState.set_setting("clipboard", true)
	await frames(3)
	check(keeper.enabled and not keeper.shots_only, "gardien complet : prend le dessus")
	GameState.set_setting("clipboard", false)
	GameState.set_setting("screenshots", false)
	await frames(3)
	check(not keeper.enabled and keeper.items.is_empty(), "tout desactive : rien n'est garde")
	_make_sheet()
	_finish()


func _make_sheet() -> void:
	if shots.is_empty():
		return
	var w := shots[0].get_width()
	var h := shots[0].get_height()
	var cols := mini(5, shots.size())
	var rows := int(ceil(shots.size() / float(cols)))
	var sheet := Image.create(w * cols, h * rows, false, Image.FORMAT_RGBA8)
	sheet.fill(Color("2a2730"))
	for i in shots.size():
		var im := shots[i]
		im.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(im, Rect2i(0, 0, w, h), Vector2i((i % cols) * w, (i / cols) * h))
	sheet.save_png(ProjectSettings.globalize_path(SHOTS + "clipboard_sheet.png"))


func _finish() -> void:
	if finished:
		return
	finished = true
	# restauration du presse-papiers de l'utilisateur
	if os_ok:
		if prev_img and keeper._running:
			keeper._write_cmd("img " + Marshalls.raw_to_base64(prev_img.save_png_to_buffer()))
			await wait(1.0)
		else:
			await set_clip(prev_text)
	var errs := logger.errors.duplicate()
	for e in errs:
		print("ERROR ", e)
	for f in fails:
		print("  - FAILED: ", f)
	if logger.busy > 0:
		print("INFO presse-papiers momentanement occupe par une autre appli : %d essai(s) rate(s), reessaye" % logger.busy)
	print("CLIPBOARD TEST RESULT: %d passed, %d failed, %d errors" % [passed, failed, errs.size()])
	keeper.stop()
	get_tree().quit(0 if failed == 0 and errs.is_empty() else 1)
