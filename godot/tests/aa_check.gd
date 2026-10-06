extends Node
## Captures "pixels natifs" (texture de la fenetre = pixels physiques) de zones de l'interface,
## agrandies 2x en plus-proche-voisin, pour verifier l'anticrenelage a 125 % et 150 %.
## Lancer : Godot --path godot res://tests/aa_check.tscn -- --tag=after
## Sortie : tests/screenshots/aa/<tag>_<echelle>_<zone>.png

const OUT := "res://tests/screenshots/aa/"
var tag := "after"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			tag = a.trim_prefix("--tag=")
	GameState.no_save = true
	GameState.coins = 5000
	GameState.level = 3
	GameState.xp = 40
	GameState.owned = {"crown": true}
	GameState.equipped["head"] = "crown"
	ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", 600.0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	get_tree().create_timer(120.0).timeout.connect(func(): get_tree().quit(2))
	var w := get_window()
	w.transparent = false
	w.borderless = false
	w.size = Vector2i(200, 150)
	w.position = Vector2i(20, 20)
	get_viewport().transparent_bg = false
	_run.call_deferred()


func _run() -> void:
	for f in [1.25, 1.5]:
		await _capture(f)
	print("AA CHECK DONE")
	get_tree().quit()


func _capture(f: float) -> void:
	var shop := ShopWindow.new()
	add_child(shop)
	shop.open("head")
	shop._apply_scale(f, true)
	await _wait(1.0)
	await _wait_thumbs(shop)
	var sc := "%d" % int(round(f * 100))
	print("scale ", sc, " msaa_2d=", shop.msaa_2d, " size=", shop.size)
	var img := await _grab(shop)
	_crop(img, shop, shop.tabs, "%s_tabs" % sc, Vector2(560, 60))
	_crop(img, shop, shop.cards[""], "%s_card_aucun" % sc, Vector2(0, 0), 8.0)
	_crop(img, shop, shop.cards["crown"], "%s_card_crown" % sc, Vector2(0, 0), 8.0)
	_crop(img, shop, shop._level_badge.get_parent().get_parent(), "%s_needs" % sc, Vector2(0, 0), 4.0)
	_crop(img, shop, shop.coin_pill.get_parent(), "%s_titlebar" % sc, Vector2(0, 0))
	_crop(img, shop, shop.preview_view, "%s_preview" % sc, Vector2(0, 0))
	# bulle + dialogue
	shop.preview_emotes.say("Coucou ! Tu me trouves comment ?", 6.0)
	for id in Data.ITEMS:
		if Data.ITEMS[id]["slot"] == "head" and not GameState.owned.has(id):
			shop._ask_buy_item("head", id)
			break
	await _wait(0.8)
	img = await _grab(shop)
	_crop(img, shop, shop.preview_view, "%s_bubble" % sc, Vector2(0, 0))
	if is_instance_valid(shop.dialog):
		_crop(img, shop, shop.dialog.card, "%s_dialog" % sc, Vector2(0, 0), 10.0)
		shop.dialog.close(false)
	await _wait(0.3)
	shop.toast.show_msg("Couronne est à toi !", "sparkle", UITheme.ACCENT)
	await _wait(0.6)
	img = await _grab(shop)
	_crop(img, shop, shop.toast, "%s_toast" % sc, Vector2(0, 0), 12.0)
	shop.queue_free()
	await _wait(0.4)
	# menu
	var pos := Vector2i(DisplayServer.screen_get_usable_rect().end) - Vector2i(400, 60)
	var m := PetMenu.open_at(pos, PetMenu.default_items(false), Callable(), self)
	m.content_scale_factor = f
	m.size = Vector2i((Vector2(PetMenu.W, m._content_h()) + Vector2(PetMenu.MARGIN, PetMenu.MARGIN) * 2.0) * f)
	await _wait(0.6)
	m._body.set_hover(2)
	await _wait(0.3)
	await RenderingServer.frame_post_draw
	var mi := m.get_texture().get_image()
	print("menu msaa_2d=", m.msaa_2d)
	_save_zoom(mi, Rect2i(Vector2i.ZERO, mi.get_size()), "%s_menu" % sc)
	m.hide()
	await _wait(0.4)


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _wait_thumbs(shop: ShopWindow) -> void:
	var t0 := Time.get_ticks_msec()
	while shop.thumbs.pending() > 0 and Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
	await _wait(0.5)


func _grab(w: Window) -> Image:
	await RenderingServer.frame_post_draw
	var img := w.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	# fond "bureau" sous la transparence
	var bg := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	bg.fill(Color("4b5262"))
	bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	return bg


func _crop(img: Image, w: Window, c: Control, name: String, max_logical: Vector2, grow := 6.0) -> void:
	if not is_instance_valid(c):
		return
	var r := c.get_global_rect().grow(grow)
	if max_logical.x > 0:
		r.size.x = minf(r.size.x, max_logical.x)
	if max_logical.y > 0:
		r.size.y = minf(r.size.y, max_logical.y)
	var f := w.content_scale_factor
	var pr := Rect2i(Vector2i((r.position * f).floor()), Vector2i((r.size * f).ceil()))
	pr = pr.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	_save_zoom(img, pr, name)


func _save_zoom(img: Image, pr: Rect2i, name: String) -> void:
	var sub := img.get_region(pr)
	sub.convert(Image.FORMAT_RGBA8)
	var maxw := 900
	var z := 2 if sub.get_width() * 2 <= maxw * 2 else 1
	sub.resize(sub.get_width() * z, sub.get_height() * z, Image.INTERPOLATE_NEAREST)
	sub.save_png(ProjectSettings.globalize_path(OUT + "%s_%s.png" % [tag, name]))
	print("AA SHOT ", name, " ", pr.size)
