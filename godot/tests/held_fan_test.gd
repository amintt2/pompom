extends Node
## Test de l'eventail "main de cartes" (HeldFan) : ouverture au survol avec N objets (dont la lettre),
## correspondance carte <-> objet, clics, apercu des images (dans l'ecran), retrait, glisser dehors, fermeture.
## Lancer : powershell -File godot/tests/run_held_fan_test.ps1  (fenetres hors de l'ecran : ne derange pas)
## Captures : %APPDATA%/Pompom/held_fan_*.png (composees sur un faux fond de bureau).
## Ne touche jamais au presse-papiers (ClipboardKeeper.dry_run).

var stage: PetStage
var emotes: EmoteLayer
var hud: GameHud
var keeper: ClipboardKeeper
var layer: HeldItemsLayer
var fan: HeldFan
var passed := 0
var failed := 0
var fails: Array[String] = []
var sc := 1.5
var W := 260
var H := 300
var screen := Rect2()  # faux ecran (px) autour de la fenetre du compagnon
var finished := false
var copied: Array = []
var mails := 0
var shots_only := false


func check(cond: bool, name: String) -> void:
	if cond:
		passed += 1
		print("PASS ", name)
	else:
		failed += 1
		fails.append(name)
		print("FAIL ", name)


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scale="):
			sc = float(a.get_slice("=", 1))
		if a == "--onscreen":
			shots_only = true
	W = int(260 * sc)
	H = int(300 * sc)
	GameState.no_save = true
	GameState.settings["clipboard"] = false
	GameState.settings["screenshots"] = false
	GameState.settings["talk"] = false
	var w := get_window()
	w.always_on_top = false
	w.size = Vector2i(W, H)
	# hors de tous les ecrans (ne derange pas le joueur) ; --onscreen pour regarder
	var all := Rect2()
	for i in DisplayServer.get_screen_count():
		var r := Rect2(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i))
		all = r if i == 0 else all.merge(r)
	var p := Vector2(all.end.x + 1500, all.position.y + 1200) if not shots_only else Vector2(all.position.x + 900, all.position.y + 700)
	w.position = Vector2i(p)
	get_viewport().transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
	stage = PetStage.new()
	add_child(stage)
	stage.build_from_state()
	stage.frame(Vector2(W, H), 100.0 * sc, 14.0 * sc)
	stage.pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.8)
	var cl := CanvasLayer.new()
	cl.layer = 5
	add_child(cl)
	emotes = EmoteLayer.new()
	emotes.stage = stage
	cl.add_child(emotes)
	emotes.bind_pet(stage.pet)
	emotes.talk_enabled = false
	hud = GameHud.new()
	hud.stage = stage
	cl.add_child(hud)
	keeper = ClipboardKeeper.new()
	keeper.name = "Clipboard"
	add_child(keeper)
	keeper.use_helper = false
	keeper.dry_run = true
	keeper.sim_mouse = true
	keeper.talk = false
	keeper.setup(stage, emotes)
	keeper.enabled = true  # sans surveillance du presse-papiers (mode "off")
	layer = keeper.layer
	layer.sim_mouse_pos = Vector2(-9999, -9999)
	fan = keeper.fan
	fan.sim_mouse = Vector2(-99999, -99999)
	screen = Rect2(Vector2(w.position) + Vector2(W * 0.5 - 900, H - 1000), Vector2(1800, 1000))
	fan.usable_override = screen
	keeper.item_copied.connect(func(it): copied.append(it))
	keeper.mail_requested.connect(func(): mails += 1)
	get_tree().create_timer(60.0).timeout.connect(func():
		print("=== WATCHDOG: test took too long ===")
		_finish())
	_run.call_deferred()


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func wait_settled(max_sec := 2.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not fan.settled() and Time.get_ticks_msec() - t0 < max_sec * 1000.0:
		await frames(1)
	return fan.settled()


func wait_pet_idle() -> void:
	var t := 0
	while stage.pet.busy and t < 200:
		await get_tree().process_frame
		t += 1


func key_of(kind: String) -> String:
	for k in fan.card_keys():
		if str(fan._cards[k]["entry"]["kind"]) == kind:
			return k
	return ""


func click_global(g: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.position = fan._to_local(g)
	e.pressed = true
	fan.handle_view_input(e)
	var e2 := e.duplicate() as InputEventMouseButton
	e2.pressed = false
	fan.handle_view_input(e2)


func hover(g: Vector2) -> void:
	fan.sim_mouse = g


## Chaque coin de chaque carte (et son ombre proche) est dans la zone visible / cliquable de la fenetre.
func region_covers_cards() -> bool:
	var poly := fan.mouse_passthrough_polygon
	for k in fan.card_keys():
		var xf: Transform2D = fan._xf(fan._cards[k])
		for q in [Vector2(-HeldFan.CARD.x * 0.5 - 4, -HeldFan.CARD.y - 4), Vector2(HeldFan.CARD.x * 0.5 + 4, -HeldFan.CARD.y - 4),
				Vector2(HeldFan.CARD.x * 0.5 + 4, 4), Vector2(-HeldFan.CARD.x * 0.5 - 4, 4)]:
			if not Geometry2D.is_point_in_polygon((xf * q) * fan._f, poly):
				print("  hors zone : carte ", k, " coin ", (xf * q) * fan._f, " fenetre ", fan.size, " zone ", poly)
				return false
	return true


static func test_image(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / h
		var sky := Color("8fd3ff").lerp(Color("ffd6ea"), t)
		for x in w:
			var c := sky
			var hill := h * (0.68 + 0.08 * sin(x * 0.02 * 640.0 / w))
			var hill2 := h * (0.78 + 0.06 * sin(x * 0.013 * 640.0 / w + 2.0))
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
	# petit texte simule (lignes fines) pour juger la nettete
	for i in 6:
		var yy := int(h * 0.08) + i * maxi(3, h / 60)
		for x in range(int(w * 0.06), int(w * (0.22 + 0.05 * (i % 3)))):
			img.set_pixel(x, yy, Color("3b2d3f"))
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


# =========================================================================== captures
## Compose la fenetre du compagnon et celle de l'eventail sur un faux fond de bureau (alpha premultiplie).
func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var main_img := get_viewport().get_texture().get_image()
	var fan_img: Image = fan.get_texture().get_image() if fan.visible else null
	var mw := get_window()
	var r := Rect2(Vector2(mw.position), Vector2(mw.size))
	if fan_img:
		r = r.merge(Rect2(Vector2(fan.position), Vector2(fan.size)))
	r = r.grow(20)
	var out := Image.create(int(r.size.x), int(r.size.y), false, Image.FORMAT_RGBA8)
	var wall_a := Color("cfe3f7")
	var wall_b := Color("f3dcea")
	for y in out.get_height():
		var c := wall_a.lerp(wall_b, float(y) / out.get_height())
		out.fill_rect(Rect2i(0, y, out.get_width(), 1), c)
	# barre des taches sous le compagnon
	var tb_y := int(mw.position.y + H - 14 * sc - r.position.y)
	out.fill_rect(Rect2i(0, tb_y, out.get_width(), out.get_height() - tb_y), Color("2b2733"))
	_composite(out, main_img, Vector2i(Vector2(mw.position) - r.position))
	if fan_img:
		_composite(out, fan_img, Vector2i(Vector2(fan.position) - r.position))
	var path := "user://held_fan_%s.png" % name
	out.save_png(path)
	print("SHOT ", ProjectSettings.globalize_path(path))
	await frames(2)  # (la composition est longue : les minuteries suivantes partent d'une image normale)


func _composite(dst: Image, src: Image, at: Vector2i) -> void:
	src.convert(Image.FORMAT_RGBA8)
	var sw := src.get_width()
	var sh := src.get_height()
	var dw := dst.get_width()
	var sd := src.get_data()
	var dd := dst.get_data()
	for y in sh:
		var dy := y + at.y
		if dy < 0 or dy >= dst.get_height():
			continue
		for x in sw:
			var si := (y * sw + x) * 4
			var a := sd[si + 3]
			if a == 0:
				continue
			var dx := x + at.x
			if dx < 0 or dx >= dw:
				continue
			var di := (dy * dw + dx) * 4
			var ia := 255 - a
			for ch in 3:
				dd[di + ch] = mini(255, sd[si + ch] + (dd[di + ch] * ia) / 255)
	dst.set_data(dst.get_width(), dst.get_height(), false, Image.FORMAT_RGBA8, dd)


# =========================================================================== scenario
func _run() -> void:
	await frames(5)
	print("INFO fenetre test : ", get_window().position, " dpi fan : ", fan._scale())
	var photo := test_image(1280, 800)
	var f_text := keeper.ingest_text("Penser à acheter des croquettes pour Mochi demain matin, et appeler mamie pour son anniversaire !")
	var f_file := keeper.ingest_files(PackedStringArray([ProjectSettings.globalize_path("res://project.godot")]))
	var f_img := keeper.ingest_image(photo)
	f_img["shot"] = true
	f_img["time"] = Time.get_unix_time_from_system() - 125.0
	hud.mail_count = 2
	await wait(1.0)
	await wait_pet_idle()
	await frames(3)
	check(keeper.head_items().size() == 3, "3 objets sur sa tete")
	var trig := fan.trigger_rect_global()
	check(trig.has_area(), "zone de survol (pile + enveloppe) non vide")
	check(not fan.is_shown(), "eventail ferme au repos")

	# ------------------------------------------------------------------ 1. ouverture au survol
	hover(trig.get_center() + Vector2(0, -8))
	await wait(0.05)
	check(not fan.is_shown(), "pas d'ouverture immediate (delai anti-clignotement)")
	var t_open := Time.get_ticks_usec()
	while not fan.is_shown() and Time.get_ticks_usec() - t_open < 1_000_000:
		await frames(1)
	var open_ms := (Time.get_ticks_usec() - t_open) / 1000.0
	check(fan.is_open(), "survol de sa tete : l'eventail s'ouvre")
	check(fan.visible, "fenetre de l'eventail visible")
	check(fan.unfocusable and fan.transient and fan.borderless and fan.transparent, "fenetre sans bordure, transparente, transitoire, jamais active")
	check(fan.msaa_2d == Viewport.MSAA_4X and get_viewport().msaa_2d == Viewport.MSAA_DISABLED, "MSAA 2D 4x seulement sur l'eventail")
	var keys := fan.card_keys()
	check(keys.size() == 4, "4 cartes (lettre + image + texte + fichier) : %d" % keys.size())
	check(keys.size() > 0 and keys[0] == "mail", "la lettre est la premiere carte")
	var ok_settle := await wait_settled()
	check(ok_settle, "les cartes se posent en eventail")
	await frames(3)
	check(layer.fan_hidden and hud.mail_hidden, "la pile et l'enveloppe sur sa tete sont cachees (elles sont dans l'eventail)")
	print("INFO ouverture (delai compris) : %.0f ms" % open_ms)
	var fr := Rect2(Vector2(fan.position), Vector2(fan.size))
	check(screen.encloses(fr), "fenetre de l'eventail dans l'ecran")

	# ------------------------------------------------------------------ 2. correspondance carte <-> objet
	var map_ok := true
	for k in keys:
		var g := fan.card_center_global(k)
		if fan.key_at_global(g) != k:
			map_ok = false
			print("  carte ", k, " -> ", fan.key_at_global(g))
	check(map_ok, "chaque carte : le test de clic donne la bonne carte")
	check(fan._cards[key_of("image")]["entry"]["item"] == f_img and fan._cards[key_of("text")]["entry"]["item"] == f_text \
		and fan._cards[key_of("file")]["entry"]["item"] == f_file, "chaque carte porte le bon objet")
	var xs := []
	for k in keys:
		xs.append(fan.card_center_global(k).x)
	var sorted_ok := true
	for i in range(1, xs.size()):
		sorted_ok = sorted_ok and xs[i] > xs[i - 1]
	check(sorted_ok, "cartes ecartees de gauche a droite")
	check(region_covers_cards(), "zone visible / cliquable de la fenetre : couvre toutes les cartes")
	check(fan.contains_global(trig.get_center()) and keeper.is_over(trig.get_center() - Vector2(get_window().position)), "survol de l'eventail : pas une caresse (is_over)")
	await shot("1_fan")

	# ------------------------------------------------------------------ 3. survol d'une carte : soulevee ; apercu des images
	var ki := key_of("image")
	hover(fan.card_center_global(ki))
	await wait(0.6)
	check(fan.hovered_key() == ki, "survol de l'image : carte survolee")
	check(float(fan._cards[ki]["scl"]) > 1.05, "la carte survolee grandit et se souleve")
	check(fan.preview_visible(), "apercu en grand de l'image")
	var pr := fan.preview_rect_global()
	check(screen.encloses(pr), "apercu dans l'ecran")
	check(Rect2(Vector2(fan.position), Vector2(fan.size)).encloses(pr), "apercu dans la fenetre de l'eventail")
	var poly := fan.mouse_passthrough_polygon
	var lpr := Rect2(pr.position - Vector2(fan.position), pr.size)
	check(Geometry2D.is_point_in_polygon(lpr.position, poly) and Geometry2D.is_point_in_polygon(lpr.end, poly) 		and region_covers_cards(), "zone visible : couvre l'apercu et les cartes")
	var img_r: Rect2 = fan._prev_img
	check(img_r.size.x <= HeldFan.PREVIEW_MAX.x + 0.5 and img_r.size.x >= 300.0, "apercu large (%.0f px logiques)" % img_r.size.x)
	check(absf(img_r.size.x / img_r.size.y - 1.6) < 0.02, "proportions de l'image gardees")
	await wait(0.4)
	var hd: Dictionary = fan._hd.get(int(f_img["id"]), {})
	check(not hd.is_empty() and hd["tex"] != null and Vector2i((img_r.size * fan._f).round()) == hd["size"],
		"apercu net : image d'origine reduite a la taille exacte (%s)" % str(hd.get("size", "")))
	await shot("2_preview")
	# texte : pas d'apercu
	var kt := key_of("text")
	hover(fan.card_center_global(kt))
	await wait(0.5)
	check(fan.hovered_key() == kt and not fan.preview_visible(), "survol du texte : pas d'apercu (images seulement)")
	await shot("3_hover_text")

	# ------------------------------------------------------------------ 4. clics : chaque carte fait son action
	copied.clear()
	click_global(fan.card_center_global(kt))
	await frames(2)
	check(copied.size() == 1 and copied[0] == f_text, "clic sur le texte : texte recopie")
	check(not fan._pills.is_empty(), "retour 'Copié !' dans l'eventail")
	await wait(0.25)
	await shot("4_copied")
	click_global(fan.card_center_global(ki))
	await frames(2)
	check(copied.size() == 2 and copied[1] == f_img, "clic sur l'image : image recopiee")
	var kf := key_of("file")
	click_global(fan.card_center_global(kf))
	await frames(2)
	check(copied.size() == 3 and copied[2] == f_file, "clic sur le fichier : fichier recopie")
	# clic sur l'apercu = recopier l'image
	hover(fan.card_center_global(ki))
	await wait(0.5)
	click_global(fan.preview_rect_global().get_center())
	await frames(2)
	check(copied.size() == 4 and copied[3] == f_img, "clic sur l'apercu : image recopiee")
	# lettre : signal, fermeture
	click_global(fan.card_center_global("mail"))
	await frames(2)
	check(mails == 1, "clic sur la lettre : mail_requested")
	check(not fan.is_open(), "la lettre ferme l'eventail")
	hud.mail_count = 0  # (DesktopController._read_mail le fait)
	await wait(0.8)
	check(not fan.is_shown() and not fan.visible, "eventail referme (fenetre cachee)")
	check(not layer.fan_hidden and not hud.mail_hidden, "la pile revient sur sa tete")
	await wait(0.4)
	check(not fan.is_shown(), "pas de reouverture tant que la souris reste sur sa tete")

	# ------------------------------------------------------------------ 5. fermeture apres le depart de la souris
	hover(Vector2(-99999, -99999))
	await frames(2)
	hover(fan.trigger_rect_global().get_center())
	await wait(0.5)
	check(fan.is_open() and fan.card_keys().size() == 3, "reouverture : 3 cartes (sans lettre)")
	await wait_settled()
	hover(fan.card_center_global(key_of("file")) + Vector2(0, -80) * fan._f)  # juste au-dessus : dans la zone
	await wait(0.6)
	check(fan.is_open(), "souris pres des cartes : reste ouvert (hysteresis)")
	hover(fan.trigger_rect_global().get_center() + Vector2(700, 0))
	await wait(0.2)
	check(fan.is_open(), "souris partie depuis 0,2 s : encore ouvert")
	await wait(0.9)
	check(not fan.is_shown(), "souris partie : l'eventail se referme")

	# ------------------------------------------------------------------ 6. clic droit -> Retirer
	hover(fan.trigger_rect_global().get_center())
	await wait(0.5)
	await wait_settled()
	kt = key_of("text")
	hover(fan.card_center_global(kt))
	await wait(0.3)
	click_global(fan.card_center_global(kt), MOUSE_BUTTON_RIGHT)
	await wait(0.25)
	check(fan._ctx == kt and fan._ctx_r.has_area(), "clic droit : bouton 'Retirer'")
	await shot("5_retirer")
	click_global(fan._to_global(fan._ctx_r.get_center()))
	await frames(3)
	check(not keeper.items.has(f_text), "Retirer : l'objet est oublie")
	await wait(0.5)
	check(fan.card_keys().size() == 2, "il reste 2 cartes")

	# ------------------------------------------------------------------ 7. glisser une carte hors de l'eventail
	kf = key_of("file")
	var c0 := fan.card_center_global(kf)
	hover(c0)
	await wait(0.3)
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = true
	e.position = fan._to_local(c0)
	fan.handle_view_input(e)
	var target := c0 + Vector2(-260, -140) * fan._f
	for i in 10:
		var mm := InputEventMouseMotion.new()
		mm.position = fan._to_local(c0.lerp(target, (i + 1) / 10.0))
		fan.handle_view_input(mm)
		hover(c0.lerp(target, (i + 1) / 10.0))
		await frames(1)
	check(fan._drag, "glisser une carte")
	await wait(0.15)
	await shot("6_drag")
	copied.clear()
	var e2 := e.duplicate() as InputEventMouseButton
	e2.pressed = false
	e2.position = fan._to_local(target)
	fan.handle_view_input(e2)
	await frames(3)
	check(copied.size() == 1 and copied[0] == f_file, "lacher hors de l'eventail : objet depose (copie)")
	check(keeper.feet_items().has(f_file), "lacher dehors : il est pose a ses pieds")

	# ------------------------------------------------------------------ 8. une image seule suffit a ouvrir ; tout en haut de l'ecran
	hover(Vector2(-99999, -99999))
	await wait(0.8)
	check(not fan.is_shown(), "referme")
	check(keeper.head_items().size() == 1 and keeper.head_items()[0] == f_img, "il ne porte plus que l'image")
	# faux ecran dont le haut est juste au-dessus de sa tete : l'apercu passe sur le cote
	var hs := Vector2(get_window().position) + layer.head_pos()
	fan.usable_override = Rect2(Vector2(hs.x - 700, hs.y - 330), Vector2(1100, 330 + H))
	hover(fan.trigger_rect_global().get_center())
	await wait(0.5)
	check(fan.is_open() and fan.card_keys().size() == 1, "une image seule : l'eventail s'ouvre (pour l'apercu)")
	await wait_settled()
	hover(fan.card_center_global(fan.card_keys()[0]))
	await wait(0.6)
	check(fan.preview_visible(), "apercu en haut de l'ecran")
	check(fan.usable_override.encloses(fan.preview_rect_global()), "apercu dans l'ecran (pres du bord haut)")
	check(fan._prev_mode != "above", "apercu sur le cote quand il n'y a pas de place au-dessus (%s)" % fan._prev_mode)
	check(fan.usable_override.encloses(Rect2(Vector2(fan.position), Vector2(fan.size))), "fenetre dans l'ecran (bord haut) win=%s usable=%s" % [Rect2(Vector2(fan.position), Vector2(fan.size)), fan.usable_override])
	await shot("7_top_edge")
	fan.usable_override = screen

	# ------------------------------------------------------------------ 9. on le porte : l'eventail disparait
	stage.pet.carried = true
	await frames(3)
	check(not fan.is_shown() and not fan.visible, "on porte le compagnon : l'eventail disparait")
	await wait(0.4)
	check(not fan.is_shown(), "pas d'eventail pendant qu'on le porte")
	stage.pet.carried = false
	await frames(2)

	# ------------------------------------------------------------------ 10. perf : une image d'eventail ouvert
	hover(Vector2(-99999, -99999))
	await frames(2)
	keeper.ingest_text("Le rendez-vous est à 14 h 30, salle B")
	hud.mail_count = 1
	await wait(0.8)
	hover(fan.trigger_rect_global().get_center())
	await wait(0.5)
	await wait_settled()
	# main pleine : 5 objets + la lettre
	keeper.ingest_image(test_image(300, 420))
	keeper.ingest_text("https://example.com/recettes/cookies-moelleux")
	keeper.ingest_files(PackedStringArray([ProjectSettings.globalize_path("res://project.godot"), ProjectSettings.globalize_path("res://icon.svg"),
		ProjectSettings.globalize_path("res://main.tscn")]), 3)
	await wait(0.6)
	await wait_settled()
	check(fan.card_keys().size() == 6, "main pleine : 6 cartes (%d)" % fan.card_keys().size())
	var six_ok := true
	for k in fan.card_keys():
		six_ok = six_ok and fan.key_at_global(fan.card_center_global(k)) == k
	check(six_ok and region_covers_cards(), "6 cartes : chacune reste cliquable")
	var kp := ""
	for k in fan.card_keys():
		var it: Dictionary = fan._cards[k]["entry"]["item"]
		if it.get("kind", "") == "image" and (it["image"] as Image).get_height() == 420:
			kp = k
	hover(fan.card_center_global(kp))
	await wait(0.7)
	check(fan.preview_visible() and screen.encloses(fan.preview_rect_global()), "apercu d'une image en hauteur")
	await shot("8_six")
	var t0 := Time.get_ticks_usec()
	for i in 30:
		fan._process(1.0 / 120.0)
	var per := (Time.get_ticks_usec() - t0) / 30.0
	print("INFO cout CPU de l'eventail par image : %.0f us" % per)
	check(per < 1500.0, "eventail leger (< 1,5 ms CPU par image : %.0f us)" % per)
	_finish()


func _finish() -> void:
	if finished:
		return
	finished = true
	for f in fails:
		print("  - FAILED: ", f)
	print("HELD FAN TEST RESULT: %d passed, %d failed" % [passed, failed])
	fan.close_now()
	keeper.enabled = false
	get_tree().quit(0 if failed == 0 else 1)
