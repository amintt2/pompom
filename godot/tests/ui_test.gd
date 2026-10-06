extends Node
## Test automatique de l'interface (boutique + menu contextuel).
## Lancer : Godot --path godot res://tests/ui_test.tscn [-- --no-shots] [-- --keep-open]
## Affiche "PASS ..." / "FAIL ..." puis "UI TEST RESULT: x passed, y failed, z errors".

const SHOTS := "res://tests/screenshots/"

var shop: ShopWindow
var passed := 0
var failed := 0
var fails: Array[String] = []
var logger: ErrLogger
var shots := true
var base_conn := {}
var _log_file: FileAccess


func out(a = "", b = "", c = "", d = "") -> void:
	var s := str(a) + str(b) + str(c) + str(d)
	print(s)
	if _log_file == null:
		_log_file = FileAccess.open("res://tests/ui_test_log.txt", FileAccess.WRITE)
	if _log_file:
		_log_file.store_line(s)
		_log_file.flush()


class ErrLogger extends Logger:
	var errors: Array[String] = []
	var mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var msg := "%s (%s:%d %s) %s" % [rationale if rationale != "" else code, file.get_file(), line, function, code]
		# bruit connu du moteur a la fermeture (fuites de ressources), sans rapport avec l'UI
		if "leaked" in msg or "still in use at exit" in msg or "PagedAllocator" in msg or "were never freed" in msg:
			return
		mutex.lock()
		errors.append(msg)
		mutex.unlock()
		var f := FileAccess.open("res://tests/ui_test_errors.txt", FileAccess.READ_WRITE if FileAccess.file_exists("res://tests/ui_test_errors.txt") else FileAccess.WRITE)
		if f:
			f.seek_end()
			f.store_line(msg)
			f.close()

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _ready() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://tests/ui_test_errors.txt"))
	# les info-bulles sont des fenetres natives : elles peuvent se placer sous le curseur simule
	ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", 600.0)
	logger = ErrLogger.new()
	OS.add_logger(logger)
	shots = not OS.get_cmdline_user_args().has("--no-shots")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS))
	_setup_state()
	var w := get_window()
	w.transparent = false
	w.borderless = false
	w.size = Vector2i(320, 240)
	w.position = Vector2i(40, 40)
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color("40424a"))
	# garde-fou : on ne laisse jamais une instance de test ouverte
	get_tree().create_timer(240.0).timeout.connect(func():
		out("=== WATCHDOG: test took too long, quitting (passed %d, failed %d) ===" % [passed, failed])
		for f in fails:
			out("  - FAILED: ", f)
		get_tree().quit(2))
	_run.call_deferred()


func _setup_state() -> void:
	GameState.no_save = true
	GameState.coins = 50000
	GameState.species = "mochi"
	GameState.pet_name = "Mochi"
	GameState.material = "peluche"
	GameState.fur_color = ""
	GameState.eye_style = ""
	GameState.mouth_style = "smile"
	GameState.iris_color = ""
	GameState.owned_looks = {"mat:peluche": true}
	GameState.owned = {}
	GameState.item_colors = {}
	GameState.equipped = {"head": "", "face": "", "neck": "", "back": ""}
	GameState.discovered = {}
	GameState.happiness = 72.0
	GameState.energy = 64.0
	# progression : niveau 1, faim basse (barre rouge), quetes connues
	GameState.level = 1
	GameState.xp = 30
	GameState.hunger = 18.0
	GameState.fun = 55.0
	GameState.unlocked_species = {"mochi": true}
	GameState.eaten = {"count": 12, "bytes": 3500000}
	GameState.quests.clear()
	for i in [0, 2, 5]:
		var q: Dictionary = Data.QUEST_POOL[i].duplicate()
		q["progress"] = 1
		q["done"] = false
		GameState.quests.append(q)
	GameState.quest_day = Time.get_date_string_from_system()
	for k in ["clipboard", "suggestions", "ai_gpu"]:
		GameState.settings.erase(k)  # valeurs par defaut de l'interface
	GameState.settings["eat_files"] = true
	for sig in ["coins_changed", "equipment_changed", "appearance_changed", "settings_changed"]:
		base_conn[sig] = GameState.get_signal_connection_list(sig).size()


# =========================================================================== outils
func check(name: String, ok: bool, info := "") -> bool:
	if ok:
		passed += 1
		out("PASS ", name)
	else:
		failed += 1
		fails.append(name + (" : " + info if info != "" else ""))
		out("FAIL ", name, (" : " + info if info != "" else ""))
	return ok


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _win_of(c: Control) -> Window:
	return c.get_window()


## Fait defiler les ScrollContainer parents pour rendre le controle visible.
func reveal(c: Control) -> void:
	var p := c.get_parent()
	while p:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible(c)
		p = p.get_parent()
	await frames(2)

## Clic simule au centre d'un controle (via l'entree de sa fenetre), sans toucher au vrai curseur.
## Godot 4.7 n'accepte le clic d'un bouton que s'il est "survole" : on lui envoie donc
## NOTIFICATION_MOUSE_ENTER (comme le ferait le moteur), puis mouvement + appui + relachement.
var _hovered: Control


func click(c: Control, button := MOUSE_BUTTON_LEFT, double := false) -> bool:
	if not is_instance_valid(c) or not c.is_visible_in_tree():
		return false
	await reveal(c)
	if not is_instance_valid(c):
		return false
	var w := _win_of(c)
	var p := c.get_global_rect().get_center()
	if is_instance_valid(_hovered) and _hovered != c:
		_hovered.notification(Control.NOTIFICATION_MOUSE_EXIT)
	var mm := InputEventMouseMotion.new()
	mm.position = p
	mm.global_position = p
	w.push_input(mm, true)
	c.notification(Control.NOTIFICATION_MOUSE_ENTER)
	_hovered = c
	await frames(1)
	if not is_instance_valid(c):
		return false
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.double_click = double
	down.position = p
	down.global_position = p
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	w.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = p
	up.global_position = p
	w.push_input(up, true)
	await frames(2)
	return true

func key(w: Window, code: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	w.push_input(e, true)
	var e2 := e.duplicate()
	e2.pressed = false
	w.push_input(e2, true)
	await frames(2)


## Capture d'une fenetre (composee sur un fond "bureau" pour voir la transparence).
func shot(w: Window, name: String) -> void:
	if not shots or not is_instance_valid(w):
		return
	await RenderingServer.frame_post_draw
	var img := w.get_texture().get_image()
	if img == null:
		return
	img.convert(Image.FORMAT_RGBA8)
	var bg := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(0, img.get_height(), 8):
		var t := float(y) / img.get_height()
		bg.fill_rect(Rect2i(0, y, img.get_width(), 8), Color("5b6475").lerp(Color("3a4050"), t))
	bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	bg.save_png(ProjectSettings.globalize_path(SHOTS + name + ".png"))
	out("SHOT ", name)


func wait_thumbs(timeout := 12.0) -> void:
	var t0 := Time.get_ticks_msec()
	while shop.thumbs.pending() > 0 and Time.get_ticks_msec() - t0 < timeout * 1000.0:
		await frames(2)
	await frames(3)


func first_card(pred: Callable) -> ShopCard:
	var ids := shop.cards.keys()
	for id in ids:
		var c: ShopCard = shop.cards[id]
		if is_instance_valid(c) and pred.call(c):
			return c
	return null


func card_center_ok(c: Control) -> bool:
	var r := c.get_global_rect()
	var wr := Rect2(Vector2.ZERO, Vector2(shop.size) / shop.content_scale_factor)
	return wr.encloses(r)


func overflowing_controls(root: Control) -> Array:
	var bad := []
	var wr := Rect2(Vector2.ZERO, Vector2(shop.size) / shop.content_scale_factor).grow(1.0)
	for c in root.find_children("*", "Control", true, false):
		var cc := c as Control
		if not cc.is_visible_in_tree() or cc.size.x <= 0.0:
			continue
		# contenu defilant : seul le ScrollContainer compte
		var p := cc.get_parent()
		var in_scroll := false
		while p and p != root:
			if p is ScrollContainer:
				in_scroll = true
				break
			p = p.get_parent()
		if in_scroll:
			continue
		if not wr.encloses(cc.get_global_rect()):
			bad.append("%s %s" % [cc.get_class(), cc.get_global_rect()])
	return bad


# =========================================================================== scenario
func _run() -> void:
	out("=== UI TEST START ===")
	var dpi := UITheme.dpi_scale()
	shop = ShopWindow.new()
	add_child(shop)
	shop.open("head")
	await wait(0.6)
	check("open: window visible", shop.visible)
	check("open: borderless transparent", shop.borderless and shop.transparent)
	check("open: DPI scale = screen dpi / 96", is_equal_approx(shop.content_scale_factor, dpi), "%s vs %s" % [shop.content_scale_factor, dpi])
	check("open: size >= min_size", shop.size.x >= shop.min_size.x and shop.size.y >= shop.min_size.y, "%s / %s" % [shop.size, shop.min_size])
	check("open: head tab shown", shop.current_tab == "head" and shop.cards.size() > 5)
	check("open: max fps raised for animations", Engine.max_fps == 0 or Engine.max_fps >= 60)

	await _test_thumbs()
	await _test_tabs_walk()
	await _test_items()
	await _test_colors()
	await _test_other_slots()
	await _test_filter()
	await _test_look()
	await _test_progression()
	await _test_stats()
	await _test_settings()
	await _test_layout()
	await _test_window_buttons()
	await _test_reopen()
	await _test_menu()
	await _test_signals_after_close()
	_finish()


func _test_thumbs() -> void:
	await wait_thumbs()
	var n := 0
	var nonempty := 0
	for id in shop.cards:
		var c: ShopCard = shop.cards[id]
		if id == "":
			continue
		n += 1
		if c.has_thumb():
			var img := (c.get_node("Thumb") as TextureRect).texture.get_image()
			if img and img.get_used_rect().size.x > 10:
				nonempty += 1
	check("thumbs: all head cards have a rendered 3D thumbnail", n > 0 and nonempty == n, "%d / %d" % [nonempty, n])
	await shot(shop, "01_chapeaux")
	# nettete (ecrans 125 % / 150 %)
	check("crisp: shop window has 2D MSAA", shop.msaa_2d == Viewport.MSAA_4X)
	check("crisp: preview 2D MSAA + 3D supersampling", shop._sv.msaa_2d == Viewport.MSAA_4X and shop._sv.scaling_3d_scale >= 2.0)
	var f := shop.content_scale_factor
	check("crisp: thumbnails rendered at >= 2x display size", shop.thumbs.size.x >= mini(512, int(150.0 * f * 2.0)), str(shop.thumbs.size))
	var any_card: ShopCard = first_card(func(c): return c.item_id != "" and c.has_thumb())
	var timg := (any_card.get_node("Thumb") as TextureRect).texture.get_image() if any_card else null
	check("crisp: thumbnails have mipmaps", timg != null and timg.has_mipmaps())
	check("crisp: thumbnail filter uses mipmaps", any_card != null and (any_card.get_node("Thumb") as TextureRect).texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS)

func _test_tabs_walk() -> void:
	for t in ShopWindow.TABS:
		var b: Control = shop.tabs.buttons[t[0]]
		await click(b)
		await wait(0.35)
		check("tab click: %s" % t[0], shop.current_tab == t[0], "current=%s" % shop.current_tab)
	# retour rapide entre onglets : la file des miniatures ne doit pas se bloquer
	for t in ["head", "face", "look", "neck", "back", "head"]:
		shop.show_tab(t)
		await frames(1)
	await wait_thumbs()
	var ok := true
	for id in shop.cards:
		if id != "" and not shop.cards[id].has_thumb():
			ok = false
	check("thumbs: still render after fast tab switching (no stuck queue)", ok)


func _test_items() -> void:
	shop.show_tab("head")
	await wait(0.3)
	# essayer un objet non possede
	var c := first_card(func(c): return c.item_id != "" and not GameState.owned.has(c.item_id))
	var id := c.item_id
	await click(c)
	await wait(0.2)
	check("items: click card tries it on preview", shop.preview.pet.slot_items.get("head", "") == id, str(shop.preview.pet.slot_items))
	check("items: card selected", c.button_pressed)
	check("items: preference discovered", GameState.discovered_level(id) != null)
	check("items: card shows preference badge", c.pref != null)
	check("items: detail has buy button", shop.detail_buttons.has("buy"))
	await shot(shop, "02_essai_objet")
	# annuler l'achat
	var coins0 := GameState.coins
	await click(shop.detail_buttons["buy"])
	await wait(0.4)
	check("buy: confirm dialog opens", is_instance_valid(shop.dialog) and shop.dialog.is_visible_in_tree())
	await shot(shop, "03_confirmation")
	await click(shop.dialog.cancel_button)
	await wait(0.3)
	check("buy: cancel keeps coins & not owned", GameState.coins == coins0 and not GameState.owned.has(id))
	check("buy: dialog closed after cancel", not is_instance_valid(shop.dialog) or shop.dialog._done)
	# Echap ferme aussi
	await click(shop.detail_buttons["buy"])
	await wait(0.3)
	await key(shop, KEY_ESCAPE)
	await wait(0.3)
	check("buy: Escape closes dialog", not is_instance_valid(shop.dialog) or shop.dialog._done)
	# acheter
	await click(shop.detail_buttons["buy"])
	await wait(0.3)
	await click(shop.dialog.ok_button)
	await wait(0.5)
	var price := int(Data.ITEMS[id]["price"])
	check("buy: item owned", GameState.owned.has(id))
	check("buy: coins decreased by price", GameState.coins == coins0 - price, "%d -> %d (prix %d)" % [coins0, GameState.coins, price])
	check("buy: item equipped", GameState.equipped["head"] == id)
	check("buy: card updated in place (Porté badge)", is_instance_valid(c) and c.equipped and c.owned)
	check("buy: detail now shows Retirer", shop.detail_buttons.has("remove"))
	check("buy: toast shown", shop.toast.visible and "à toi" in shop.toast.text())
	check("buy: confetti", shop.confetti.active())
	check("buy: outfit chip updated", shop.outfit_chips["head"].item_id == id)
	await shot(shop, "04_achat_celebration")
	await wait(1.0)
	check("buy: coin counter tween reached value", shop.coin_pill.shown_text() == UIKit.fmt(GameState.coins), shop.coin_pill.shown_text())
	# retirer / porter
	await click(shop.detail_buttons["remove"])
	await wait(0.2)
	check("unequip: Retirer", GameState.equipped["head"] == "")
	check("unequip: preview cleared", shop.preview.pet.slot_items.get("head", "") == "")
	await click(shop.cards[id])
	await wait(0.2)
	check("equip: detail shows Porter", shop.detail_buttons.has("wear"))
	await click(shop.detail_buttons["wear"])
	await wait(0.2)
	check("equip: Porter", GameState.equipped["head"] == id)
	# carte "Aucun"
	await click(shop.cards[""])
	await wait(0.2)
	check("none card: unequips slot", GameState.equipped["head"] == "")
	await click(shop.cards[id])
	await click(shop.detail_buttons["wear"])
	await wait(0.2)
	check("equip again", GameState.equipped["head"] == id)
	# objet trop cher
	GameState.coins = 10
	await wait(0.1)
	var exp := first_card(func(c): return c.item_id != "" and not GameState.owned.has(c.item_id))
	await click(exp)
	await wait(0.2)
	check("locked: card shows locked state", not exp.affordable)
	check("locked: buy button disabled", shop.detail_buttons.has("buy") and shop.detail_buttons["buy"].disabled)
	await shot(shop, "05_objet_verrouille")
	await click(shop.detail_buttons["buy"])
	await wait(0.2)
	check("locked: no dialog when unaffordable", not is_instance_valid(shop.dialog) or shop.dialog._done)
	GameState.add_coins(50000)
	await wait(0.2)
	check("coins: refresh unlocks card", exp.affordable and not shop.detail_buttons["buy"].disabled)


func _test_colors() -> void:
	shop.show_tab("head")
	await wait(0.2)
	var id: String = GameState.equipped["head"]
	await click(shop.cards[id])
	await wait(0.2)
	for i in ShopWindow.COLOR_SLOTS.size():
		var which: String = ShopWindow.COLOR_SLOTS[i][0]
		await click(shop.color_seg.button(i))
		await wait(0.1)
		var sw: Array = shop.detail_swatches.swatches()
		var target: UIKit.Swatch = sw[(i * 3 + 2) % sw.size()]
		await click(target)
		await wait(0.15)
		var got := GameState.colors_for(id)[which] as Color
		check("color %s: swatch saved for owned item" % which, got.is_equal_approx(target.color), "%s vs %s" % [got.to_html(), target.color.to_html()])
		check("color %s: swatch marked selected" % which, target.selected)
	# couleur personnalisee (selecteur)
	await click(shop.detail_swatches.custom)
	await wait(0.4)
	var pop: UIKit.ColorPop = shop.detail_swatches.pop
	check("custom color: picker popup opens", is_instance_valid(pop) and pop.visible)
	if is_instance_valid(pop):
		await shot(pop, "06_selecteur_couleur")
		pop.picker.color = Color("12ab34")
		pop.picker.color_changed.emit(Color("12ab34"))
		await frames(2)
		pop.hide()
		await wait(0.3)
	var detail_col := GameState.colors_for(id)["detail"] as Color
	check("custom color: committed on close", detail_col.is_equal_approx(Color("12ab34")), detail_col.to_html())
	# la miniature est re-rendue avec les nouvelles couleurs
	await wait_thumbs()
	check("color: thumbnail re-rendered with new colours", Thumbs.cache.has(Thumbs.key_for("item", id)))
	# essayage de couleur sur un objet non possede : ne doit rien sauvegarder
	var other := first_card(func(c): return c.item_id != "" and not GameState.owned.has(c.item_id))
	await click(other)
	await wait(0.2)
	await click(shop.color_seg.button(0))
	await click(shop.detail_swatches.swatches()[5])
	await wait(0.1)
	check("color: try-on colour on unowned item not saved", not GameState.item_colors.has(other.item_id))
	await shot(shop, "07_couleurs_objet")


func _test_other_slots() -> void:
	for slot in ["face", "neck", "back"]:
		await click(shop.tabs.buttons[slot])
		await wait(0.3)
		var c := first_card(func(c): return c.item_id != "" and not GameState.owned.has(c.item_id))
		await click(c)
		await click(shop.detail_buttons["buy"])
		await wait(0.3)
		await click(shop.dialog.ok_button)
		await wait(0.4)
		check("%s: buy + equip" % slot, GameState.equipped[slot] == c.item_id and GameState.owned.has(c.item_id))
		check("%s: preview wears it" % slot, shop.preview.pet.slot_items.get(slot, "") == c.item_id)
		await wait_thumbs()
		await shot(shop, "08_%s" % slot)
	# l'apercu garde toute la tenue en changeant d'onglet
	await click(shop.tabs.buttons["head"])
	await wait(0.3)
	var all_ok := true
	for slot in Data.SLOTS:
		if shop.preview.pet.slot_items.get(slot, "") != GameState.equipped[slot]:
			all_ok = false
	check("preview: full outfit kept across tabs", all_ok, str(shop.preview.pet.slot_items))
	# un essai non achete est retire en quittant l'onglet
	var t := first_card(func(c): return c.item_id != "" and not GameState.owned.has(c.item_id))
	await click(t)
	await click(shop.tabs.buttons["face"])
	await wait(0.3)
	check("preview: unbought try-on reverted when leaving tab", shop.preview.pet.slot_items.get("head", "") == GameState.equipped["head"])
	# pastille de tenue -> onglet
	await click(shop.outfit_chips["neck"])
	await wait(0.3)
	check("outfit chip opens its tab", shop.current_tab == "neck")


func _test_filter() -> void:
	await click(shop.tabs.buttons["head"])
	await wait(0.3)
	var all_n := shop.cards.size()
	await click(shop.filter_seg.button(1))
	await wait(0.3)
	var owned_n := 0
	for id in Data.ITEMS:
		if Data.ITEMS[id]["slot"] == "head" and GameState.owned.has(id):
			owned_n += 1
	check("filter: À moi shows only owned (+Aucun)", shop.cards.size() == owned_n + 1, "%d vs %d" % [shop.cards.size(), owned_n + 1])
	await click(shop.filter_seg.button(0))
	await wait(0.3)
	check("filter: Tout shows all again", shop.cards.size() == all_n)


func _test_look() -> void:
	await click(shop.tabs.buttons["look"])
	await wait(0.4)
	await wait_thumbs()
	await shot(shop, "09_apparence_compagnon")
	# especes
	for sp in Data.SPECIES:
		if sp == GameState.species:
			continue
		var unlocked := GameState.species_unlocked(sp)
		await click(shop.cards[sp])
		await wait(0.3)
		if unlocked:
			check("species: switch to %s" % sp, GameState.species == sp)
		else:
			check("species locked: %s not selectable" % sp, GameState.species == "mochi")
			check("species locked: %s card shows level" % sp, shop.cards[sp].locked_text == "Niveau %d" % int(Data.SPECIES_LEVEL[sp]))
			check("species locked: %s detail shows disabled 'Niveau requis'" % sp, shop.detail_buttons.has("locked") and shop.detail_buttons["locked"].disabled)
		check("species: preview shows %s" % sp, shop.preview.pet.species_id == sp)
		if sp == "nuage":
			await shot(shop, "18_espece_verrouillee")
	await click(shop.cards["mochi"])
	await wait(0.3)
	check("species: back to mochi", GameState.species == "mochi" and GameState.pet_name == "Mochi")
	# matiere / yeux / bouche : achat avec confirmation
	for sec in [["mat", 1], ["eye", 3], ["mouth", 4]]:
		await click(shop.look_nav.button(sec[1]))
		await wait(0.35)
		check("look nav: %s" % sec[0], shop.look_section == sec[0])
		await wait_thumbs()
		var c := first_card(func(c): return not GameState.owns_look("%s:%s" % [sec[0], c.item_id]))
		if c == null:
			check("look %s: has something to buy" % sec[0], false)
			continue
		var key: String = "%s:%s" % [sec[0], c.item_id]
		var coins0 := GameState.coins
		await click(c)
		await wait(0.3)
		check("look %s: unowned click previews only" % sec[0], not GameState.owns_look(key) and shop._previewing_look)
		if sec[0] == "mat":
			check("look mat: preview shows material", shop.preview.pet.material_id == c.item_id)
		await shot(shop, "10_apparence_%s" % sec[0])
		await click(shop.detail_buttons["buy"])
		await wait(0.3)
		check("look %s: confirm dialog" % sec[0], is_instance_valid(shop.dialog) and not shop.dialog._done)
		await click(shop.dialog.cancel_button)
		await wait(0.3)
		check("look %s: cancel reverts preview" % sec[0], not shop._previewing_look and not GameState.owns_look(key))
		await click(c)
		await click(shop.detail_buttons["buy"])
		await wait(0.3)
		await click(shop.dialog.ok_button)
		await wait(0.4)
		check("look %s: bought" % sec[0], GameState.owns_look(key) and GameState.coins == coins0 - GameState.look_price(key))
		var cur: String = {"mat": GameState.material, "eye": GameState.current_eye_style(), "mouth": GameState.mouth_style}[sec[0]]
		check("look %s: applied" % sec[0], cur == c.item_id)
		check("look %s: card shows Actuel" % sec[0], c.equipped)
		# revenir a une option possedee (gratuite)
		var free := first_card(func(x): return x.item_id != c.item_id and GameState.owns_look("%s:%s" % [sec[0], x.item_id]))
		if free:
			await click(free)
			await wait(0.3)
			var cur2: String = {"mat": GameState.material, "eye": GameState.current_eye_style(), "mouth": GameState.mouth_style}[sec[0]]
			check("look %s: owned option applies on click" % sec[0], cur2 == free.item_id)
	# couleurs
	await click(shop.look_nav.button(2))
	await wait(0.35)
	check("look nav: colors", shop.look_section == "colors" and shop.fur_swatches != null)
	var sw: UIKit.Swatch = shop.fur_swatches.swatches()[2]
	await click(sw)
	await wait(0.3)
	check("fur colour: saved", GameState.current_fur_color().is_equal_approx(sw.color))
	check("fur colour: swatches still valid after appearance change", is_instance_valid(sw) and sw.selected)
	var iw: UIKit.Swatch = shop.iris_swatches.swatches()[9]
	await click(iw)
	await wait(0.3)
	check("iris colour: saved", GameState.current_iris().is_equal_approx(iw.color))
	await click(shop.detail_buttons["fur_reset"])
	await wait(0.3)
	check("fur colour: reset to species colour", GameState.current_fur_color().is_equal_approx(Color.html(Data.SPECIES["mochi"]["fur"])))
	await shot(shop, "11_apparence_couleurs")


func _test_progression() -> void:
	# colonne de gauche : niveau, XP, besoins
	check("level row: label", shop._level_label.text == "Niveau 1", shop._level_label.text)
	check("level row: xp text", shop._xp_label.text == "30 / %d XP" % Data.xp_for_next(1), shop._xp_label.text)
	check("needs: hunger low shown in red", shop._hunger_bar.color == UITheme.BAD)
	check("needs: fun %", shop._fun_pct.text.begins_with("55"), shop._fun_pct.text)
	GameState.change_hunger(50.0)
	GameState.change_fun(-15.0)
	await wait(0.7)
	check("needs: live update (hunger)", shop._hunger_pct.text.begins_with("68") and shop._hunger_bar.color != UITheme.BAD, shop._hunger_pct.text)
	check("needs: live update (fun)", shop._fun_pct.text.begins_with("40"), shop._fun_pct.text)
	# onglet quetes
	await click(shop.tabs.buttons["quests"])
	await wait(0.5)
	check("quests tab: shown", shop.current_tab == "quests")
	check("quests: 3 cards", shop.quest_cards.size() == 3, str(shop.quest_cards.size()))
	check("quests: food prefs for species", shop.food_rows.size() == Data.FOODS.size() and shop.food_rows.get("fruit") == Data.food_pref("mochi", "fruit"))
	check("quests: level card", shop.level_card_label.text == "Niveau 1")
	var eaten: Label = shop._page.find_child("EatenLabel", true, false)
	check("quests: files eaten shown", eaten != null and "12" in eaten.text and "Mo" in eaten.text, eaten.text if eaten else "")
	await shot(shop, "19_quetes")
	await reveal(eaten)
	await wait(0.2)
	await shot(shop, "19b_nourriture")
	# progression d'une quete en direct
	var q0: Dictionary = GameState.quests[0]
	GameState.quest_event(q0["kind"], 1)
	await wait(1.3)
	var cnt: Label = shop._quest_refs[0]["count"]
	check("quests: live progress", cnt.text.begins_with("2 /"), cnt.text)
	# terminer une quete
	var coins0 := GameState.coins
	var q1: Dictionary = GameState.quests[1]
	GameState.quest_event(q1["kind"], int(q1["goal"]))
	await wait(0.4)
	check("quest complete: card done", bool(shop.quest_cards[1].get_meta("done", false)))
	check("quest complete: reward coins", GameState.coins == coins0 + int(q1["coins"]))
	check("quest complete: toast", "Quête terminée" in shop.toast.text(), shop.toast.text())
	await wait(0.6)
	await shot(shop, "20_quete_terminee")
	# passage de niveau
	GameState.add_xp(Data.xp_for_next(GameState.level) - GameState.xp + 5)
	await wait(0.5)
	check("level up: level 2", GameState.level == 2)
	check("level up: toast", "Niveau 2" in shop.toast.text(), shop.toast.text())
	check("level up: left badge + card", shop._level_label.text == "Niveau 2" and shop.level_card_label.text == "Niveau 2")
	check("level up: pico unlocked", GameState.species_unlocked("pico"))
	await wait(0.4)
	await shot(shop, "21_niveau_superieur")
	# l'espece debloquee devient selectionnable
	await click(shop.tabs.buttons["look"])
	await wait(0.3)
	await click(shop.look_nav.button(0))
	await wait(0.4)
	check("unlock: pico card unlocked", shop.cards["pico"].locked_text == "")
	await click(shop.cards["pico"])
	await wait(0.3)
	check("unlock: pico selectable", GameState.species == "pico")
	check("unlock: kiwi still locked", shop.cards["kiwi"].locked_text == "Niveau 3")
	await click(shop.cards["mochi"])
	await wait(0.3)
	check("unlock: back to mochi", GameState.species == "mochi")
	# nourriture desactivee : message
	GameState.set_setting("eat_files", false)
	shop.show_tab("quests")
	await wait(0.3)
	check("quests: eat_files off note", _has_label(shop._page, "Désactivé dans les Réglages"))
	GameState.set_setting("eat_files", true)


func _has_label(root: Node, part: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if part in (l as Label).text:
			return true
	return false


func _test_stats() -> void:
	await click(shop.tabs.buttons["stats"])
	await wait(1.2)
	var ok := shop.stat_labels.size() == 8
	for k in shop.stat_labels:
		ok = ok and shop.stat_labels[k].text != "" and shop.stat_labels[k].text != "—"
	check("stats: all tiles filled", ok, str(shop.stat_labels.keys()))
	GameState.stats["pets"] = 42
	await wait(1.2)
	check("stats: live refresh", shop.stat_labels["pets"].text == "42")
	await shot(shop, "12_stats")


func _test_settings() -> void:
	await click(shop.tabs.buttons["settings"])
	await wait(0.4)
	await shot(shop, "13_reglages")
	await reveal(shop.settings_ctrls["ai_gpu"])
	await wait(0.2)
	await shot(shop, "13b_reglages_assistant")
	for key in ["eat_files", "clipboard", "suggestions", "ai_gpu"]:
		var t0: UIKit.Toggle = shop.settings_ctrls.get(key)
		check("toggle %s: exists with default %s" % [key, ShopWindow.SETTING_DEFAULTS[key]], t0 != null and t0.button_pressed == ShopWindow.SETTING_DEFAULTS[key])
	for key in ["reflections", "wander", "discreet", "talk", "hide_fullscreen", "autostart", "eat_files", "clipboard", "suggestions", "ai_gpu"]:
		var t: UIKit.Toggle = shop.settings_ctrls[key]
		var before := ShopWindow.setting_on(key)
		await click(t)
		await wait(0.1)
		check("toggle %s: flips" % key, bool(GameState.settings[key]) == not before)
		await click(t)
		await wait(0.1)
		check("toggle %s: flips back" % key, bool(GameState.settings[key]) == before)
	for key in ShopWindow.SETTING_OPTIONS:
		var seg: UIKit.Segmented = shop.settings_ctrls[key]
		var opts: Array = ShopWindow.SETTING_OPTIONS[key]
		var orig: int = seg.selected
		for i in opts.size():
			await click(seg.button(i))
			await wait(0.05)
			check("option %s = %s" % [key, opts[i][0]], is_equal_approx(float(GameState.settings[key]), float(opts[i][1])))
		await click(seg.button(orig))
	# mise a jour externe (le compagnon change home_x en atterrissant) : pas de reconstruction
	var page := shop._page
	GameState.set_setting("home_x", 123.0)
	GameState.set_setting("talk", false)
	await frames(2)
	check("settings: external change updates in place", shop._page == page and not shop.settings_ctrls["talk"].button_pressed)
	GameState.set_setting("talk", true)
	await click(shop.settings_ctrls["reset_position"])
	await wait(0.1)
	check("settings: reset position", float(GameState.settings["home_x"]) == -1.0)


func _test_layout() -> void:
	var f := shop.content_scale_factor
	var orig := shop.size
	# taille minimale
	shop.size = shop.min_size
	await wait(0.5)
	for t in ["head", "look", "stats", "settings"]:
		shop.show_tab(t)
		await wait(0.4)
		var bad := overflowing_controls(shop._frame)
		check("layout min size (%s): nothing outside window" % t, bad.is_empty(), str(bad.slice(0, 4)))
	shop.show_tab("head")
	await wait(0.4)
	check("layout min size: tabs compact", shop.tabs.compact)
	check("layout min size: grid >= 3 columns", shop._grid.columns >= 3, str(shop._grid.columns))
	await wait_thumbs()
	await shot(shop, "14_taille_min")
	# grande taille
	var usable := DisplayServer.screen_get_usable_rect(shop.current_screen)
	shop.size = Vector2i(mini(usable.size.x - 40, int(1500 * f)), mini(usable.size.y - 40, int(900 * f)))
	await wait(0.5)
	check("layout large: more grid columns", shop._grid.columns >= 5, str(shop._grid.columns))
	check("layout large: tabs not compact", not shop.tabs.compact)
	var bad2 := overflowing_controls(shop._frame)
	check("layout large: nothing outside window", bad2.is_empty(), str(bad2.slice(0, 4)))
	# trop petit : la taille minimale est respectee
	shop.size = Vector2i(300, 200)
	await wait(0.2)
	check("layout: min_size enforced", shop.size.x >= shop.min_size.x and shop.size.y >= shop.min_size.y, str(shop.size))
	# autre DPI (simulation 150 %)
	shop._apply_scale(1.5, false)
	await wait(0.5)
	check("dpi 150%: content scale applied", is_equal_approx(shop.content_scale_factor, 1.5))
	var bad3 := overflowing_controls(shop._frame)
	check("dpi 150%: nothing outside window", bad3.is_empty(), str(bad3.slice(0, 4)))
	check("dpi 150%: preview renders at physical resolution", shop._sv.size.y >= int(shop.preview_view.size.y * 1.5) - 2, "%s vs %s" % [shop._sv.size, shop.preview_view.size])
	shop._apply_scale(f, false)
	shop.size = orig
	await wait(0.4)
	check("dpi restore", is_equal_approx(shop.content_scale_factor, f))


func _test_window_buttons() -> void:
	await click(shop.min_button)
	await wait(0.4)
	check("minimise button", shop.mode == Window.MODE_MINIMIZED)
	shop.show_tab("stats")
	await wait(0.4)
	check("show_tab restores minimised window", shop.mode == Window.MODE_WINDOWED and shop.current_tab == "stats")
	# preview: rotation par glisser + double clic
	shop.show_tab("head")
	await wait(0.3)
	var pv := shop.preview_view
	var p := pv.get_global_rect().get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = p
	shop.push_input(down, true)
	var mm := InputEventMouseMotion.new()
	mm.position = p + Vector2(60, 0)
	mm.relative = Vector2(60, 0)
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	shop.push_input(mm, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = p + Vector2(60, 0)
	shop.push_input(up, true)
	await frames(2)
	check("preview: drag rotates pet", absf(shop.preview.pet.rotation.y) > 0.3, str(shop.preview.pet.rotation.y))
	await wait(1.5)


func _test_reopen() -> void:
	var old := shop
	var hit := await click(shop.close_button)
	out("close click delivered=%s closing=%s mode=%s" % [hit, old._closing if is_instance_valid(old) else "freed", old.mode if is_instance_valid(old) else -1])
	await wait(0.5)
	check("close button frees shop", not is_instance_valid(old))
	check("close: fps restored", Engine.max_fps == ProjectSettings.get_setting("application/run/max_fps"))
	var n_ok := true
	for sig in base_conn:
		if GameState.get_signal_connection_list(sig).size() != base_conn[sig]:
			n_ok = false
	check("close: no dangling GameState connections", n_ok)
	shop = ShopWindow.new()
	add_child(shop)
	shop.open("look")
	await wait(0.6)
	check("reopen on look tab", shop.current_tab == "look" and shop.visible)
	shop.open("settings")
	await wait(0.3)
	check("open() twice just switches tab", shop.current_tab == "settings")
	var n2 := true
	for sig in base_conn:
		if GameState.get_signal_connection_list(sig).size() != base_conn[sig] + 1:
			n2 = false
	check("signals connected exactly once", n2, str(GameState.get_signal_connection_list("coins_changed").size()))
	shop.show_tab("head")
	await wait(0.5)
	await wait_thumbs()
	await shot(shop, "15_reouverture")
	# bulle de dialogue sur l'apercu
	shop.preview_emotes.say("Coucou ! Tu me trouves comment ?", 4.0)
	await wait(0.5)
	await shot(shop, "16_bulle")


func _test_menu() -> void:
	var got := []
	var pos := Vector2i(DisplayServer.screen_get_usable_rect().end) - Vector2i(300, 40)
	var m := PetMenu.open_at(pos, PetMenu.default_items(false), func(id): got.append(id), self)
	await wait(0.5)
	check("menu: opens", is_instance_valid(m) and m.visible)
	check("crisp: menu window has 2D MSAA", is_instance_valid(m) and m.msaa_2d == Viewport.MSAA_4X)
	check("menu: flips up near taskbar (inside screen)", m.position.y + m.size.y <= DisplayServer.screen_get_usable_rect().end.y + int(PetMenu.MARGIN * 2 * m.content_scale_factor))
	# survol puis clic sur "Statistiques"
	var r := m.row_rect(3)
	var mm := InputEventMouseMotion.new()
	mm.position = r.get_center()
	m.push_input(mm, true)
	await wait(0.3)
	# (le survol reel depend du curseur systeme : on montre la surbrillance explicitement pour la capture)
	m._body.set_hover(2)
	await wait(0.25)
	await shot(m, "17_menu")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = r.get_center()
	m.push_input(down, true)
	await wait(0.3)
	check("menu: click item calls on_pick with id", got == [3], str(got))
	check("menu: closes after pick", not is_instance_valid(m) or not m.visible)
	# Echap
	var m2 := PetMenu.open_at(pos, PetMenu.default_items(true), func(id): got.append(id), self)
	await wait(0.3)
	await key(m2, KEY_DOWN)
	await key(m2, KEY_DOWN)
	check("menu: keyboard moves highlight", is_instance_valid(m2) and m2._body.hover == 1)
	await key(m2, KEY_ESCAPE)
	await wait(0.3)
	check("menu: Escape closes", not is_instance_valid(m2) or not m2.visible)
	check("menu: Escape picks nothing", got == [3])
	# clavier : Entree
	var m3 := PetMenu.open_at(pos, PetMenu.default_items(true), func(id): got.append(id), self)
	await wait(0.3)
	await key(m3, KEY_DOWN)
	await key(m3, KEY_ENTER)
	await wait(0.3)
	check("menu: Enter picks highlighted", got == [3, 1], str(got))
	# un seul menu a la fois
	var m4 := PetMenu.open_at(pos, PetMenu.default_items(), Callable(), self)
	await wait(0.2)
	var m5 := PetMenu.open_at(pos + Vector2i(-50, 0), PetMenu.default_items(), Callable(), self)
	await wait(0.3)
	check("menu: opening a second menu closes the first", not is_instance_valid(m4) or not m4.visible)
	# clic exterieur (vrai clic OS sur notre propre fenetre de test)
	if OS.get_cmdline_user_args().has("--os-click"):
		# vrai clic systeme sur notre fenetre de test (deplace le curseur : option)
		await _os_click_outside(m5)
	else:
		# perte de focus (ce que provoque un clic a l'exterieur) ; apres le delai de grace d'ouverture (300 ms)
		await wait(0.4)
		m5.notification(Window.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
		await wait(0.3)
		check("menu: focus loss (click outside) closes it", not is_instance_valid(m5) or not m5.visible)
	if is_instance_valid(m5) and m5.visible:
		m5.hide()


func _os_click_outside(m: PetMenu) -> void:
	var w := get_window()
	var target := w.position + w.size / 2
	out("os click at ", target)
	await os_mouse(target, true)
	await wait(0.4)
	if is_instance_valid(m) and m.visible:
		out("menu still open after first OS click, retrying")
		await os_mouse(target, true)
		await wait(0.4)
	check("menu: click outside closes it", not is_instance_valid(m) or not m.visible)
	if is_instance_valid(m) and m.visible:
		m.hide()


## Vrai deplacement (et clic optionnel) du curseur systeme via user32 (coordonnees ecran physiques).
func os_mouse(target: Vector2i, do_click: bool) -> void:
	var ps := "Add-Type -Namespace W -Name U -MemberDefinition '[DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y); [DllImport(\"user32.dll\")] public static extern void mouse_event(int f,int x,int y,int d,int e); [DllImport(\"user32.dll\")] public static extern bool SetProcessDPIAware();'\n"
	ps += "[W.U]::SetProcessDPIAware() | Out-Null\n[W.U]::SetCursorPos(%d,%d) | Out-Null\nStart-Sleep -Milliseconds 60\n" % [target.x, target.y]
	ps += "[W.U]::mouse_event(1,2,0,0,0)\nStart-Sleep -Milliseconds 40\n[W.U]::mouse_event(1,-2,0,0,0)\nStart-Sleep -Milliseconds 80\n"
	if do_click:
		ps += "[W.U]::mouse_event(2,0,0,0,0)\nStart-Sleep -Milliseconds 30\n[W.U]::mouse_event(4,0,0,0,0)\nStart-Sleep -Milliseconds 80\n"
	var script_path := OS.get_environment("TEMP").path_join("pompom_os_mouse.ps1")
	var fw := FileAccess.open(script_path, FileAccess.WRITE)
	fw.store_string(ps)
	fw.close()
	# processus separe (non bloquant) : Godot continue de traiter ses messages pendant l'action
	var pid := OS.create_process("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script_path])
	var t0 := Time.get_ticks_msec()
	while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < 8000:
		await frames(2)
	await frames(3)

func _test_signals_after_close() -> void:
	await click(shop.close_button)
	await wait(0.5)
	# emettre les signaux apres fermeture ne doit provoquer aucune erreur
	GameState.add_coins(5)
	GameState.equipment_changed.emit()
	GameState.appearance_changed.emit()
	GameState.settings_changed.emit()
	await frames(3)
	check("signals after close: no errors", true)


func _finish() -> void:
	await wait(0.3)
	var errs := logger.errors.duplicate()
	for e in errs:
		out("ERROR LOGGED: ", e)
	check("no engine/script errors during the whole run", errs.is_empty(), "%d errors" % errs.size())
	out("=== UI TEST RESULT: %d passed, %d failed, %d errors ===" % [passed, failed, errs.size()])
	for f in fails:
		out("  - FAILED: ", f)
	if OS.get_cmdline_user_args().has("--keep-open"):
		return
	get_tree().quit(0 if failed == 0 else 1)

