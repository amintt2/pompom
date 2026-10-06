class_name PetMenu
extends Popup
## Menu contextuel "carte" du compagnon (remplace le PopupMenu natif).
## Petite fenetre sans bordure, transparente, toujours devant ; se ferme au clic a l'exterieur,
## a la perte de focus, avec Echap, ou quand on choisit une entree. Navigation au clavier (haut / bas / Entree).
##
##   PetMenu.open_at(DisplayServer.mouse_get_position(), PetMenu.default_items(pet.sleeping), _on_menu, self)
##
## Entrees : {id, label, icon, tint?: Color, hint?: String, danger?: bool, disabled?: bool}
##           ou {separator = true}
## on_pick(id) est appele (en differe) apres la fermeture du menu.

signal picked(id)

const W := 308.0
const MARGIN := 14.0  # marge transparente pour l'ombre
const PAD := 8.0
const ROW_H := 40.0
const SEP_H := 11.0
const HEADER_H := 66.0

static var _current: PetMenu
static var _pool: PetMenu  # une seule fenetre, reutilisee : l'ouverture est instantanee

var items: Array = []
var on_pick := Callable()
var opts := {}  # header (bool, defaut true), title, subtitle
var _body: Body
var _f := 1.0
var _picked := false
var _opened_at := 0
var _armed := false  # le bouton qui a ouvert le menu a ete relache


static func open_at(screen_pos: Vector2i, p_items: Array, p_on_pick := Callable(), parent: Node = null, p_opts := {}) -> PetMenu:
	if is_instance_valid(_current):
		_current._dismiss()
	var host: Node = parent
	if host == null:
		host = (Engine.get_main_loop() as SceneTree).root
	var m: PetMenu = _pool if is_instance_valid(_pool) and not _pool.is_queued_for_deletion() else null
	if m == null:
		m = PetMenu.new()
		_pool = m
	if m.get_parent() == null:
		host.add_child(m)
	m.items = p_items
	m.on_pick = p_on_pick
	m.opts = p_opts
	m._picked = false
	m._open(screen_pos)
	_current = m
	return m


## Cree la fenetre du menu a l'avance (cachee) pour que le premier clic droit soit instantane.
static func prewarm(parent: Node) -> void:
	if is_instance_valid(_pool):
		return
	_pool = PetMenu.new()
	parent.add_child(_pool)


## Menu propose pour le compagnon de bureau (ids = ceux de DesktopController._on_menu).
static func default_items(sleeping := false) -> Array:
	return [
		{"id": 1, "label": "Boutique", "icon": "bag", "tint": UITheme.ACCENT, "hint": "Double-clic"},
		{"id": 2, "label": "Apparence", "icon": "palette", "tint": UITheme.LAVENDER},
		{"id": 3, "label": "Statistiques", "icon": "chart", "tint": UITheme.SKY},
		{"separator": true},
		{"id": 4, "label": "Faire un câlin", "icon": "heart", "tint": UITheme.ACCENT},
		{"id": 5, "label": "Réveiller" if sleeping else "Faire dodo", "icon": "sun" if sleeping else "moon", "tint": UITheme.GOLD if sleeping else UITheme.LAVENDER},
		{"id": 6, "label": "Remettre sur la barre des tâches", "icon": "taskbar", "tint": UITheme.MINT},
		{"separator": true},
		{"id": 7, "label": "Réglages", "icon": "gear", "tint": UITheme.MINT},
		{"id": 9, "label": "Quitter Pompom", "icon": "power", "tint": UITheme.BAD, "danger": true},
	]


static func current() -> PetMenu:
	return _current if is_instance_valid(_current) else null


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	unresizable = true  # transient (au-dessus de sa fenetre parente) : pas de 'always_on_top', interdit par Windows
	wrap_controls = false
	theme = UITheme.theme()
	msaa_2d = Viewport.MSAA_4X  # (le MSAA 2D du projet ne vaut que pour la fenetre principale)
	popup_hide.connect(_on_hide)


func _open(screen_pos: Vector2i) -> void:
	var sc := _screen_at(screen_pos)
	_f = UITheme.dpi_scale(sc)
	content_scale_factor = _f
	if _body == null:
		_body = Body.new()
		_body.menu = self
		_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_body)
	_body.reset()
	var logical := Vector2(W, _content_h()) + Vector2(MARGIN, MARGIN) * 2.0
	var sz := Vector2i((logical * _f).ceil())
	var usable := DisplayServer.screen_get_usable_rect(sc)
	var m := int(MARGIN * _f)
	var p := screen_pos - Vector2i(m, m)
	var flip_x := false
	var flip_y := false
	if p.x + sz.x > usable.end.x:
		p.x = screen_pos.x - sz.x + m
		flip_x = true
	if p.y + sz.y > usable.end.y:
		p.y = screen_pos.y - sz.y + m
		flip_y = true
	p.x = clampi(p.x, usable.position.x - m, usable.end.x - sz.x + m)
	p.y = clampi(p.y, usable.position.y - m, usable.end.y - sz.y + m)
	_body.anchor_corner = Vector2(1.0 if flip_x else 0.0, 1.0 if flip_y else 0.0)
	_opened_at = Time.get_ticks_msec()
	_armed = false
	popup(Rect2i(p, sz))
	_body.appear()


static func _screen_at(p: Vector2i) -> int:
	for i in DisplayServer.get_screen_count():
		if Rect2i(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)).has_point(p):
			return i
	return DisplayServer.window_get_current_screen()


func _has_header() -> bool:
	return bool(opts.get("header", true))


func _content_h() -> float:
	var h := PAD * 2.0
	if _has_header():
		h += HEADER_H
	for it in items:
		h += SEP_H if it.get("separator", false) else ROW_H
	return h


## Rectangle (coordonnees du menu) de l'entree `id`, pour les tests.
func row_rect(id) -> Rect2:
	if _body == null:
		return Rect2()
	for r in _body.rows:
		if r["id"] == id:
			return r["rect"]
	return Rect2()


## Choisit une entree (comme un clic).
func pick(id) -> void:
	if _picked:
		return
	for it in items:
		if not it.get("separator", false) and it.get("id") == id and not it.get("disabled", false):
			_picked = true
			hide()
			picked.emit(id)
			if on_pick.is_valid():
				on_pick.call_deferred(id)
			return


func _dismiss() -> void:
	if visible:
		hide()
	else:
		_on_hide()


func _on_hide() -> void:
	if _current == self:
		_current = null
	# la fenetre est gardee pour la prochaine ouverture (sauf si ce n'est pas celle du pool)
	if _pool != self and not is_queued_for_deletion():
		queue_free.call_deferred()


## Clic n'importe ou ailleurs (gauche ou droit, meme dans une autre appli) : le menu se ferme.
## (Windows ne previent pas toujours la perte de focus d'une fenetre ouverte depuis le compagnon.)
func _process(_delta: float) -> void:
	if not visible or _picked:
		return
	var buttons := DisplayServer.mouse_get_button_state()
	if buttons == 0:
		_armed = true
		return
	if not _armed or Time.get_ticks_msec() - _opened_at < 150:
		return
	var card := Rect2(Vector2(position) + Vector2(MARGIN, MARGIN) * _f, Vector2(size) - Vector2(MARGIN, MARGIN) * 2.0 * _f)
	if not card.has_point(Vector2(DisplayServer.mouse_get_position())):
		hide()


func _notification(what: int) -> void:
	# filet de securite : la fenetre du compagnon n'a jamais le focus, on ferme donc des que le menu le perd
	# (on ignore les pertes de focus juste apres l'ouverture : le systeme peut basculer le focus a ce moment-la)
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and visible and not _picked and Time.get_ticks_msec() - _opened_at > 300:
		hide.call_deferred()


func _input(ev: InputEvent) -> void:
	if not visible or _body == null:
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_ESCAPE:
				hide()
				set_input_as_handled()
			KEY_DOWN:
				_body.move_hover(1)
				set_input_as_handled()
			KEY_UP:
				_body.move_hover(-1)
				set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				if _body.hover >= 0:
					pick(_body.rows[_body.hover]["id"])
				set_input_as_handled()


# =========================================================================== dessin
class Body extends Control:
	var menu: PetMenu
	var rows: Array = []  # {id, rect, item}
	var seps: Array = []  # y
	var hover := -1
	var anchor_corner := Vector2.ZERO
	var _hl := Rect2()
	var _hl_a := 0.0
	var _tw: Tween
	var _appear_tw: Tween
	var _card := Rect2()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		_layout()
		resized.connect(_layout)

	func _layout() -> void:
		var m := PetMenu.MARGIN
		_card = Rect2(Vector2(m, m), Vector2(PetMenu.W, menu._content_h()))
		rows.clear()
		seps.clear()
		var y := _card.position.y + PetMenu.PAD
		if menu._has_header():
			y += PetMenu.HEADER_H
		for it in menu.items:
			if it.get("separator", false):
				seps.append(y + PetMenu.SEP_H * 0.5)
				y += PetMenu.SEP_H
				continue
			rows.append({"id": it.get("id"), "rect": Rect2(_card.position.x + PetMenu.PAD, y, PetMenu.W - PetMenu.PAD * 2.0, PetMenu.ROW_H), "item": it})
			y += PetMenu.ROW_H
		pivot_offset = Vector2(lerpf(_card.position.x, _card.end.x, anchor_corner.x), lerpf(_card.position.y, _card.end.y, anchor_corner.y))

	func reset() -> void:
		if _tw:
			_tw.kill()
		hover = -1
		_hl_a = 0.0
		_layout()
		queue_redraw()

	func appear() -> void:
		_layout()
		if _appear_tw:
			_appear_tw.kill()
		modulate.a = 0.0
		scale = Vector2.ONE * 0.94
		_appear_tw = create_tween().set_parallel()
		_appear_tw.tween_property(self, "modulate:a", 1.0, 0.07)
		_appear_tw.tween_property(self, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _row_at(p: Vector2) -> int:
		for i in rows.size():
			if rows[i]["rect"].has_point(p) and not rows[i]["item"].get("disabled", false):
				return i
		return -1

	func set_hover(i: int) -> void:
		if i == hover:
			return
		var from := _hl
		hover = i
		if _tw:
			_tw.kill()
		if i < 0:
			_tw = create_tween()
			_tw.tween_method(func(x: float):
				_hl_a = x
				queue_redraw(), _hl_a, 0.0, 0.12)
			return
		var target: Rect2 = rows[i]["rect"]
		if _hl_a < 0.05:
			from = target
		_tw = create_tween().set_parallel()
		_tw.tween_method(func(x: float):
			_hl = Rect2(from.position.lerp(target.position, x), from.size.lerp(target.size, x))
			queue_redraw(), 0.0, 1.0, 0.14).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tw.tween_method(func(x: float): _hl_a = x, _hl_a, 1.0, 0.1)

	func move_hover(d: int) -> void:
		if rows.is_empty():
			return
		var i := hover
		for _k in rows.size():
			i = wrapi(i + d, 0, rows.size()) if i >= 0 else (0 if d > 0 else rows.size() - 1)
			if not rows[i]["item"].get("disabled", false):
				break
		set_hover(i)

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseMotion:
			set_hover(_row_at(ev.position))
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			var i := _row_at(ev.position)
			if i >= 0:
				menu.pick(rows[i]["id"])
			elif not _card.has_point(ev.position):
				menu.hide()
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			set_hover(-1)

	func _draw() -> void:
		# carte
		var st := UITheme.box(Color.WHITE, 20, UITheme.LINE, 1, 0)
		st.shadow_color = Color(0.25, 0.08, 0.22, 0.22)
		st.shadow_size = 12
		st.shadow_offset = Vector2(0, 3)
		draw_style_box(st, _card)
		var f := UITheme.font(650)
		var fr := UITheme.font(500)
		# en-tete : avatar, nom, humeur, pieces
		if menu._has_header():
			var hr := Rect2(_card.position + Vector2(PetMenu.PAD, PetMenu.PAD), Vector2(PetMenu.W - PetMenu.PAD * 2.0, PetMenu.HEADER_H - 8.0))
			var pts := UIKit.rounded_poly(hr, 14, 6)
			var cols := PackedColorArray()
			var fur := GameState.current_fur_color()
			for p in pts:
				cols.append(fur.lerp(Color.WHITE, 0.80).lerp(UITheme.LAVENDER_SOFT, clampf((p.x - hr.position.x) / hr.size.x, 0.0, 1.0) * 0.6))
			draw_polygon(pts, cols)
			var ac := hr.position + Vector2(28, hr.size.y * 0.5)
			draw_circle(ac + Vector2(0, 1.5), 18, Color(fur.darkened(0.4), 0.25), true, -1.0, true)
			draw_circle(ac, 18, fur, true, -1.0, true)
			draw_circle(ac + Vector2(-5.5, -1), 2.4, UITheme.INK, true, -1.0, true)
			draw_circle(ac + Vector2(5.5, -1), 2.4, UITheme.INK, true, -1.0, true)
			draw_arc(ac + Vector2(0, 3), 3.2, PI * 0.2, PI * 0.8, 8, UITheme.INK, 1.5, true)
			draw_circle(ac + Vector2(-6, -7), 3.0, Color(1, 1, 1, 0.45), true, -1.0, true)
			var title: String = menu.opts.get("title", GameState.pet_name)
			var nx := ac.x + 28
			draw_string(f, Vector2(nx, hr.position.y + 25), title, HORIZONTAL_ALIGNMENT_LEFT, 120, 17, UITheme.INK)
			# humeur
			var mood := GameState.happiness
			var mood_txt: String = menu.opts.get("subtitle", "Heureux" if mood >= 60 else ("Ça va" if mood >= 30 else "Un peu triste"))
			var my := hr.position.y + 44
			UIIcons.draw(self, "heart", Rect2(nx, my - 11, 13, 13), UITheme.ACCENT, 1.0)
			draw_string(fr, Vector2(nx + 17, my), mood_txt, HORIZONTAL_ALIGNMENT_LEFT, 90, 13, UITheme.BODY)
			# pieces
			var ct := UIKit.fmt(GameState.coins)
			var cw := f.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 36
			var cr := Rect2(hr.end.x - cw - 8, hr.position.y + (hr.size.y - 26) * 0.5, cw, 26)
			draw_style_box(UITheme.box(Color(1, 1, 1, 0.85), 99, Color.TRANSPARENT, 0, 0), cr)
			UIIcons.coin(self, cr.position + Vector2(14, 13), 8)
			draw_string(f, cr.position + Vector2(26, 18), ct, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("8a5a00"))
		# separateurs
		for y in seps:
			draw_line(Vector2(_card.position.x + 18, y), Vector2(_card.end.x - 18, y), UITheme.LINE, 1.0, true)
		# surbrillance glissante
		if _hl_a > 0.01 and hover >= 0:
			var danger: bool = rows[hover]["item"].get("danger", false)
			draw_style_box(UITheme.box(Color(UITheme.BAD_SOFT if danger else UITheme.ACCENT_SOFT, _hl_a), 12, Color.TRANSPARENT, 0, 0), _hl)
		# entrees
		for i in rows.size():
			var r: Rect2 = rows[i]["rect"]
			var it: Dictionary = rows[i]["item"]
			var dis: bool = it.get("disabled", false)
			var danger2: bool = it.get("danger", false)
			var tint: Color = it.get("tint", UITheme.ACCENT)
			var on := i == hover
			var ic := r.position + Vector2(20, r.size.y * 0.5)
			var rad := 14.0 + (1.0 if on else 0.0)
			draw_circle(ic, rad, tint if on else tint.lerp(Color.WHITE, 0.80), true, -1.0, true)
			UIIcons.draw(self, str(it.get("icon", "")), Rect2(ic - Vector2(9, 9), Vector2(18, 18)),
				Color.WHITE if on else tint.darkened(0.15), 1.0)
			var col := UITheme.FAINT if dis else (UITheme.BAD if danger2 else (UITheme.ACCENT_DARK if on else UITheme.INK))
			var fy := r.position.y + r.size.y * 0.5 + f.get_ascent(15) * 0.5 - 2
			var hint := str(it.get("hint", ""))
			var hw := fr.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x if hint != "" else 0.0
			draw_string(f if on else fr, Vector2(r.position.x + 44, fy), str(it.get("label", "")), HORIZONTAL_ALIGNMENT_LEFT,
				r.size.x - 52 - hw, 15, col)
			if hint != "":
				draw_string(fr, Vector2(r.end.x - hw - 10, fy - 1), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UITheme.FAINT)
