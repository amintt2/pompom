class_name ShopCard
extends Button
## Carte d'objet de la boutique : grande miniature 3D, nom, pastille de prix / statut,
## badges (porte, preference decouverte), etat verrouille, animations (survol, apparition).

const W := 136.0
const H := 176.0

var kind := "item"  # item | species | mat | eye | mouth | none
var item_id := ""
var title := ""
var price := 0
var owned := false
var equipped := false  # porte / actuel
var affordable := true
var pref = null  # niveau de preference decouvert (int) ou null
var tint := UITheme.ACCENT_SOFT
var icon_name := ""  # icone a la place d'une miniature (carte "Aucun")
var status_text := ""  # remplace la pastille (ex. "Gratuit")
var locked_text := ""  # verrou de progression (ex. "Niveau 5") : carte grisee + cadenas

var _thumb: TextureRect
var _hover := 0.0
var _sel := 0.0
var _tw_h: Tween
var _thumb_alpha := 0.0


func _init() -> void:
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(W, H)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIKit.clear_styles(self)
	_thumb = TextureRect.new()
	_thumb.name = "Thumb"
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_thumb.modulate.a = 0.0
	add_child(_thumb)
	mouse_entered.connect(_set_hover.bind(1.0))
	mouse_exited.connect(_set_hover.bind(0.0))
	toggled.connect(func(_on: bool): _anim_sel())
	resized.connect(_layout)
	button_down.connect(func():
		var t := create_tween()
		t.tween_property(self, "scale", Vector2.ONE * 0.96, 0.06))
	button_up.connect(func():
		var t := create_tween()
		t.tween_property(self, "scale", Vector2.ONE * (1.0 + 0.03 * _hover), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))


func _ready() -> void:
	set_process(icon_name == "" and _thumb.texture == null)


## Animation de chargement (points) tant que la miniature n'est pas prete.
func _process(_delta: float) -> void:
	queue_redraw()


func setup(p_kind: String, id: String, p_title: String) -> ShopCard:
	kind = p_kind
	item_id = id
	title = p_title
	tooltip_text = p_title
	return self


func set_state(p_price: int, p_owned: bool, p_equipped: bool, p_affordable: bool, p_pref = null) -> void:
	price = p_price
	owned = p_owned
	equipped = p_equipped
	affordable = p_affordable
	pref = p_pref
	queue_redraw()


func has_thumb() -> bool:
	return _thumb.texture != null


## Rappel des miniatures (Thumbs) : invalide automatiquement si la carte est liberee.
func set_thumb(tex: Texture2D) -> void:
	var first := _thumb.texture == null
	_thumb.texture = tex
	set_process(false)
	if first and is_inside_tree():
		var t := create_tween()
		t.tween_property(_thumb, "modulate:a", 1.0, 0.25)
	else:
		_thumb.modulate.a = 1.0


func pop_in(delay: float) -> void:
	modulate.a = 0.0
	scale = Vector2.ONE * 0.9
	var t := create_tween().set_parallel()
	t.tween_property(self, "modulate:a", 1.0, 0.2).set_delay(delay)
	t.tween_property(self, "scale", Vector2.ONE, 0.32).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _layout() -> void:
	pivot_offset = size * 0.5
	var th := _thumb_rect()
	_thumb.position = th.position + Vector2(8, 6)
	_thumb.size = th.size - Vector2(16, 10)


func _thumb_rect() -> Rect2:
	return Rect2(8, 8, size.x - 16, size.y - 80)


func _set_hover(v: float) -> void:
	if _tw_h:
		_tw_h.kill()
	_tw_h = create_tween().set_parallel()
	_tw_h.tween_method(func(x: float):
		_hover = x
		queue_redraw(), _hover, v, 0.14)
	_tw_h.tween_property(self, "scale", Vector2.ONE * (1.0 + 0.03 * v), 0.16).set_trans(Tween.TRANS_SINE)


func _anim_sel() -> void:
	var target := 1.0 if button_pressed else 0.0
	create_tween().tween_method(func(x: float):
		_sel = x
		queue_redraw(), _sel, target, 0.16)


func refresh_selected() -> void:
	_sel = 1.0 if button_pressed else 0.0
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var locked := (not owned and price > 0 and not affordable) or locked_text != ""
	# ombre + fond "verre"
	var st := UITheme.box(Color(1, 1, 1, 0.92).lerp(UITheme.ACCENT_SOFT.lightened(0.4), _sel), UITheme.R_CARD,
		UITheme.ACCENT.lerp(UITheme.ACCENT_DARK, _sel) if (_sel > 0.01 or _hover > 0.01) else Color(1, 1, 1, 1),
		1, 0)
	if _sel > 0.01 or _hover > 0.01:
		st.border_color = Color(UITheme.ACCENT, maxf(_hover * 0.7, _sel))
		st.set_border_width_all(int(round(1.0 + 1.5 * _sel)))
	st.shadow_color = Color(0.4, 0.15, 0.35, 0.07 + 0.08 * _hover)
	st.shadow_size = int(8 + 8 * _hover)
	st.shadow_offset = Vector2(0, 2 + 3 * _hover)
	draw_style_box(st, r)
	# tuile de la miniature
	var th := _thumb_rect()
	var tile := tint.lerp(Color.WHITE, 0.35)
	if locked:
		tile = Color("f4eef2")
	draw_style_box(UITheme.box(tile, 16, Color.TRANSPARENT, 0, 0), th)
	draw_circle(th.get_center() + Vector2(0, 4), th.size.y * 0.36, Color(1, 1, 1, 0.55), true, -1.0, true)
	if icon_name != "":
		var isz := 40.0
		UIIcons.draw(self, icon_name, Rect2(th.get_center() - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), UITheme.FAINT, 1.0)
	elif _thumb.texture == null:
		# chargement : trois points doux
		var t := Time.get_ticks_msec() / 1000.0
		for i in 3:
			var a := 0.35 + 0.35 * sin(t * 5.0 - i * 0.8)
			draw_circle(th.get_center() + Vector2((i - 1) * 12, 0), 3.5, Color(UITheme.ACCENT, a), true, -1.0, true)
	_thumb.self_modulate = Color(0.95, 0.93, 0.96, 0.6) if locked else Color.WHITE
	# nom (une ou deux lignes)
	var f := UITheme.font(650)
	var foot := Rect2(0, size.y - 36, size.x, 26)
	var lines := _wrap(f, title, size.x - 18)
	var fs: int = lines[0]
	var n := lines.size() - 1
	var block_top := th.end.y
	var block_h := foot.position.y - block_top
	var lh := f.get_height(fs) - 1.0
	var y0 := block_top + (block_h - lh * n) * 0.5 + f.get_ascent(fs) - 1.0
	for i in range(1, lines.size()):
		draw_string(f, Vector2(9, y0 + (i - 1) * lh), lines[i], HORIZONTAL_ALIGNMENT_CENTER, size.x - 18, fs, UITheme.INK)
	# pastille du bas
	_draw_footer(foot, locked)
	# badges
	if equipped:
		var bc := Vector2(size.x - 18, 18)
		draw_circle(bc + Vector2(0, 1), 11, Color(0, 0.3, 0.2, 0.15), true, -1.0, true)
		draw_circle(bc, 11, UITheme.MINT, true, -1.0, true)
		UIIcons.draw(self, "check", Rect2(bc - Vector2(7, 7), Vector2(14, 14)), Color.WHITE, 1.2)
	if pref != null:
		var pc := Vector2(18, 18)
		var pcol := _pref_color(int(pref))
		draw_circle(pc + Vector2(0, 1), 11, Color(0.3, 0.1, 0.2, 0.12), true, -1.0, true)
		draw_circle(pc, 11, Color.WHITE, true, -1.0, true)
		UIIcons.draw(self, "pref_%d" % int(pref), Rect2(pc - Vector2(8, 8), Vector2(16, 16)), pcol, 0.9)


func _draw_footer(r: Rect2, locked: bool) -> void:
	var f := UITheme.font(650)
	var fs := 13
	var txt := ""
	var bg := Color.TRANSPARENT
	var fg := UITheme.MUTED
	var ic := ""
	if locked_text != "":
		txt = locked_text
		bg = Color("f3edf1")
		ic = "lock"
	elif status_text != "" and not equipped:
		txt = status_text
		bg = Color("f5eef2")
	elif equipped:
		txt = "Porté" if kind == "item" else "Actuel"
		bg = UITheme.MINT_SOFT
		fg = UITheme.MINT.darkened(0.25)
		ic = "check"
	elif owned or price <= 0:
		txt = "À toi" if owned else "Gratuit"
		bg = UITheme.LAVENDER_SOFT
		fg = UITheme.LAVENDER.darkened(0.3)
	else:
		txt = UIKit.fmt(price)
		bg = UITheme.GOLD_SOFT if not locked else Color("f3edf1")
		fg = Color("8a5a00") if not locked else UITheme.MUTED
		ic = "coin" if not locked else "lock"
	var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var iw := 16.0 if ic != "" else 0.0
	var gap := 5.0 if ic != "" else 0.0
	var pw := tw + iw + gap + 20.0
	var pr := Rect2(r.position.x + (r.size.x - pw) * 0.5, r.position.y, pw, r.size.y)
	draw_style_box(UITheme.box(bg, 99, Color.TRANSPARENT, 0, 0), pr)
	var x := pr.position.x + 10.0
	if ic != "":
		UIIcons.draw(self, ic, Rect2(x, pr.get_center().y - 8, 16, 16), fg if ic != "coin" else Color.WHITE, 1.0)
		x += iw + gap
	draw_string(f, Vector2(x, pr.get_center().y + f.get_ascent(fs) * 0.5 - 1.5), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, fg)


static func _pref_color(level: int) -> Color:
	match level:
		2: return UITheme.ACCENT
		1: return UITheme.MINT
		-1: return UITheme.PEACH
		-2: return UITheme.BAD
	return UITheme.MUTED


## [taille_police, ligne1, (ligne2)] : reduit la police puis coupe en deux lignes si besoin.
func _wrap(f: Font, s: String, w: float) -> Array:
	for fs in [14, 13]:
		if f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
			return [fs, s]
	var words := s.split(" ")
	var best := -1
	var best_d := INF
	for i in range(1, words.size()):
		var a := " ".join(words.slice(0, i))
		var b := " ".join(words.slice(i))
		var wa := f.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var wb := f.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		if wa <= w and wb <= w and absf(wa - wb) < best_d:
			best_d = absf(wa - wb)
			best = i
	if best > 0:
		return [13, " ".join(words.slice(0, best)), " ".join(words.slice(best))]
	return [13, _fit(f, s, 13, w)]


func _fit(f: Font, s: String, fs: int, w: float) -> String:
	if f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
		return s
	var t := s
	while t.length() > 1 and f.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w:
		t = t.substr(0, t.length() - 1)
	return t.strip_edges() + "…"
