class_name UITheme
## Design system "cosy pastel" de Pompom : couleurs, polices, styles, theme global.
## Grille de 8 px, Fredoka (titres en gras), cartes "verre" arrondies avec ombre douce.

# --------------------------------------------------------------------------- couleurs
const BG := Color("fff8f3")          # creme (haut de la fenetre)
const BG_2 := Color("fbeef6")        # rose-lavande (bas de la fenetre)
const CARD := Color("ffffff")
const GLASS := Color(1, 1, 1, 0.82)  # cartes "verre" posees sur le degrade
const INK := Color("3b2d3f")         # titres / texte principal (prune profond)
const BODY := Color("5b4b5f")        # texte courant
const MUTED := Color("8e7d92")       # texte secondaire (contraste >= 4:1 sur blanc)
const FAINT := Color("c4b6c6")
const LINE := Color("f0e2e9")
const LINE_2 := Color("e6d3de")
const ACCENT := Color("ff6fa8")
const ACCENT_DARK := Color("e2508c")
const ACCENT_SOFT := Color("ffe5ef")
const LAVENDER := Color("9b8aff")
const LAVENDER_SOFT := Color("eeeaff")
const MINT := Color("37b98a")
const MINT_SOFT := Color("dcf5ea")
const SKY := Color("63aef5")
const SKY_SOFT := Color("e2f0ff")
const PEACH := Color("ff9f6b")
const PEACH_SOFT := Color("ffeadd")
const GOOD := MINT
const BAD := Color("e5484d")
const BAD_SOFT := Color("fde4e5")
const GOLD := Color("f6b93b")
const GOLD_DARK := Color("b9790c")
const GOLD_SOFT := Color("fff1d3")
const SHADOW := Color(0.35, 0.18, 0.35, 0.10)

# --------------------------------------------------------------------------- tailles (px logiques)
const R_WIN := 24
const R_CARD := 20
const R_BTN := 14
const FS_TITLE := 22
const FS_H2 := 18
const FS_BODY := 15
const FS_SMALL := 13
const FS_TINY := 12

static var _fonts := {}
static var _theme: Theme


## Fredoka a la graisse demandee (300..700). Les graisses >= 600 servent aux titres.
static func font(weight := 500) -> Font:
	var w := 650 if weight >= 600 else (500 if weight >= 450 else 400)
	if weight >= 680:
		w = 700
	if not _fonts.has(w):
		var base: FontFile = load("res://assets/fonts/Fredoka.ttf")
		var v := FontVariation.new()
		v.base_font = base
		var ts := TextServerManager.get_primary_interface()
		v.variation_opentype = {ts.name_to_tag("wght"): w}
		_fonts[w] = v
	return _fonts[w]


static func box(bg: Color, radius := 16, border := Color.TRANSPARENT, bw := 0, pad := 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.corner_detail = 10
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	s.set_content_margin_all(pad)
	s.anti_aliasing = true
	return s


## Carte "verre" : blanc translucide, liseré clair, ombre douce.
static func glass(radius := R_CARD, pad := 16, alpha := 0.82, shadow := 12) -> StyleBoxFlat:
	var s := box(Color(1, 1, 1, alpha), radius, Color(1, 1, 1, 0.95), 1, pad)
	s.shadow_color = SHADOW
	s.shadow_size = shadow
	s.shadow_offset = Vector2(0, 3)
	return s


static func pill(bg: Color, pad_h := 10, pad_v := 4) -> StyleBoxFlat:
	var s := box(bg, 99, Color.TRANSPARENT, 0, 0)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	return s


static func label(text: String, size := FS_BODY, color := BODY, weight := 500) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if weight != 500:
		l.add_theme_font_override("font", font(weight))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func dpi_scale(screen := -1) -> float:
	if screen < 0:
		screen = DisplayServer.window_get_current_screen()
	return clampf(float(DisplayServer.screen_get_dpi(screen)) / 96.0, 1.0, 3.0)


static func theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = FS_BODY
	for type in ["Label", "Button", "LineEdit", "CheckButton", "OptionButton", "PopupMenu", "TooltipLabel", "RichTextLabel"]:
		t.set_color("font_color", type, INK)

	# Boutons secondaires
	t.set_stylebox("normal", "Button", box(CARD, R_BTN, LINE_2, 1, 10))
	t.set_stylebox("hover", "Button", box(ACCENT_SOFT, R_BTN, ACCENT, 1, 10))
	t.set_stylebox("pressed", "Button", box(ACCENT_SOFT, R_BTN, ACCENT_DARK, 2, 10))
	t.set_stylebox("hover_pressed", "Button", box(ACCENT_SOFT, R_BTN, ACCENT_DARK, 2, 10))
	t.set_stylebox("disabled", "Button", box(Color("f6f0f3"), R_BTN, LINE, 1, 10))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_hover_color", "Button", ACCENT_DARK)
	t.set_color("font_pressed_color", "Button", ACCENT_DARK)
	t.set_color("font_hover_pressed_color", "Button", ACCENT_DARK)
	t.set_color("font_focus_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", FAINT)
	t.set_font("font", "Button", font(650))

	# Bouton principal (rose plein)
	t.set_type_variation("PrimaryButton", "Button")
	var pn := box(ACCENT, R_BTN, Color(1, 1, 1, 0.35), 1, 12)
	pn.shadow_color = Color(ACCENT_DARK, 0.30)
	pn.shadow_size = 8
	pn.shadow_offset = Vector2(0, 3)
	t.set_stylebox("normal", "PrimaryButton", pn)
	var ph: StyleBoxFlat = pn.duplicate()
	ph.bg_color = ACCENT.lightened(0.08)
	ph.shadow_size = 12
	t.set_stylebox("hover", "PrimaryButton", ph)
	var pp: StyleBoxFlat = pn.duplicate()
	pp.bg_color = ACCENT_DARK
	pp.shadow_size = 3
	t.set_stylebox("pressed", "PrimaryButton", pp)
	t.set_stylebox("hover_pressed", "PrimaryButton", pp)
	t.set_stylebox("disabled", "PrimaryButton", box(Color("efe6eb"), R_BTN, Color.TRANSPARENT, 0, 12))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "PrimaryButton", Color.WHITE)
	t.set_color("font_disabled_color", "PrimaryButton", MUTED)

	# Bouton "fantome" (sans fond)
	t.set_type_variation("GhostButton", "Button")
	t.set_stylebox("normal", "GhostButton", box(Color(1, 1, 1, 0), R_BTN, Color.TRANSPARENT, 0, 8))
	t.set_stylebox("hover", "GhostButton", box(Color(1, 1, 1, 0.7), R_BTN, Color.TRANSPARENT, 0, 8))
	t.set_stylebox("pressed", "GhostButton", box(ACCENT_SOFT, R_BTN, Color.TRANSPARENT, 0, 8))
	t.set_stylebox("hover_pressed", "GhostButton", box(ACCENT_SOFT, R_BTN, Color.TRANSPARENT, 0, 8))
	t.set_color("font_color", "GhostButton", BODY)

	# Panneaux
	t.set_stylebox("panel", "PanelContainer", glass())
	t.set_stylebox("panel", "Panel", box(BG, 0))
	t.set_stylebox("panel", "PopupPanel", _popup_box())
	t.set_stylebox("panel", "TooltipPanel", box(INK, 10, Color.TRANSPARENT, 0, 8))
	t.set_color("font_color", "TooltipLabel", Color.WHITE)
	t.set_font_size("font_size", "TooltipLabel", FS_SMALL)

	# Champs
	t.set_stylebox("normal", "LineEdit", box(Color(1, 1, 1, 0), 12, Color.TRANSPARENT, 0, 6))
	t.set_stylebox("focus", "LineEdit", box(Color(1, 1, 1, 0.9), 12, ACCENT, 2, 6))
	t.set_stylebox("read_only", "LineEdit", box(Color(1, 1, 1, 0), 12, Color.TRANSPARENT, 0, 6))
	t.set_color("caret_color", "LineEdit", ACCENT_DARK)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.3))
	t.set_color("font_placeholder_color", "LineEdit", FAINT)

	# Barres
	t.set_stylebox("background", "ProgressBar", box(Color("f3e8ee"), 8, Color.TRANSPARENT, 0, 0))
	t.set_stylebox("fill", "ProgressBar", box(ACCENT, 8, Color.TRANSPARENT, 0, 0))

	# Menus (encore utilises par le menu natif de la barre des taches)
	t.set_stylebox("panel", "PopupMenu", _popup_box())
	t.set_stylebox("hover", "PopupMenu", box(ACCENT_SOFT, 10, Color.TRANSPARENT, 0, 4))
	t.set_color("font_hover_color", "PopupMenu", ACCENT_DARK)
	t.set_constant("v_separation", "PopupMenu", 10)
	t.set_font_size("font_size", "PopupMenu", FS_BODY)
	t.set_stylebox("separator", "PopupMenu", _sep())

	# Defilement : fin et discret
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("grabber", sb, box(Color(INK, 0.16), 6, Color.TRANSPARENT, 0, 0))
		t.set_stylebox("grabber_highlight", sb, box(Color(ACCENT, 0.7), 6, Color.TRANSPARENT, 0, 0))
		t.set_stylebox("grabber_pressed", sb, box(ACCENT_DARK, 6, Color.TRANSPARENT, 0, 0))
		var tr := box(Color(0, 0, 0, 0), 6, Color.TRANSPARENT, 0, 0)
		tr.content_margin_left = 3
		tr.content_margin_right = 3
		t.set_stylebox("scroll", sb, tr)
		t.set_stylebox("scroll_focus", sb, tr)
	t.set_constant("scrollbar_h_separation", "ScrollContainer", 6)
	t.set_constant("scrollbar_v_separation", "ScrollContainer", 6)
	_theme = t
	return t


static func _popup_box() -> StyleBoxFlat:
	var s := box(CARD, 18, LINE_2, 1, 12)
	s.shadow_color = Color(0.3, 0.15, 0.3, 0.18)
	s.shadow_size = 10
	return s


static func _sep() -> StyleBoxLine:
	var l := StyleBoxLine.new()
	l.color = LINE
	l.thickness = 1
	l.grow_begin = -8
	l.grow_end = -8
	return l
