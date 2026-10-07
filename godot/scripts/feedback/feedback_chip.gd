class_name FeedbackChip
extends Window
## Petite pastille « Il s'est trompé ? » qui apparait a cote du compagnon quelques secondes (apres un clic
## pendant un comportement automatique, ou juste apres un evenement de jeu). Un clic dessus -> `pressed`.
## Fenetre a part, sans bordure, transparente, toujours devant, qui ne prend jamais le focus (le jeu ou
## l'appli en cours le garde). Le minuteur s'arrete tant que la souris est dessus.
##
##   var chip := FeedbackChip.new()
##   add_child(chip)
##   chip.pressed.connect(func(): ...)
##   chip.show_near(Rect2i(win.position, win.size))      # rectangle ECRAN de la fenetre du compagnon
##   chip.dismiss()

signal pressed
signal expired

const TEXT := "Il s'est trompé ?"
const MARGIN := 10.0  # marge transparente pour l'ombre
const H := 36.0
const FS := 14

var duration := 4.0
var _f := 1.0
var _left := 0.0
var _a := 0.0
var _hover := false
var _tw: Tween
var _body: Body


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	unfocusable = true
	always_on_top = true
	transient = false
	unresizable = true
	wrap_controls = false
	title = "Pompom"
	msaa_2d = Viewport.MSAA_4X
	theme = UITheme.theme()


func _ready() -> void:
	_body = Body.new()
	_body.chip = self
	_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_body)
	set_process(false)


func pill_width() -> float:
	return UITheme.font(650).get_string_size(TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, FS).x + 30.0 + 26.0


## Affiche la pastille a gauche (ou a droite si pas la place) du rectangle `anchor` (coordonnees ecran).
func show_near(anchor: Rect2i) -> void:
	var sc := DisplayServer.get_screen_from_rect(Rect2(anchor))
	_f = UITheme.dpi_scale(maxi(sc, 0))
	content_scale_factor = _f
	var logical := Vector2(pill_width(), H) + Vector2(MARGIN, MARGIN) * 2.0
	var sz := Vector2i((logical * _f).ceil())
	var usable := DisplayServer.screen_get_usable_rect(maxi(sc, 0))
	# a hauteur de sa tete (environ 40 % de la fenetre du compagnon), cote gauche par defaut
	var y := anchor.position.y + int(anchor.size.y * 0.38) - sz.y / 2
	var x := anchor.position.x + int(anchor.size.x * 0.22) - sz.x
	if x < usable.position.x:
		x = anchor.position.x + int(anchor.size.x * 0.78)
	x = clampi(x, usable.position.x, usable.end.x - sz.x)
	y = clampi(y, usable.position.y, usable.end.y - sz.y)
	size = sz
	position = Vector2i(x, y)
	var m := MARGIN * _f
	mouse_passthrough_polygon = PackedVector2Array([Vector2(m, m), Vector2(sz.x - m, m), Vector2(sz.x - m, sz.y - m),
		Vector2(m, sz.y - m)])
	_left = duration
	_hover = false
	if not visible:
		show()
		_a = 0.0
	_fade(1.0, 0.16)
	set_process(true)


func is_showing() -> bool:
	return visible and _left > 0.0


func dismiss() -> void:
	_left = 0.0
	set_process(false)
	if visible:
		_fade(0.0, 0.14, true)


func _fade(to: float, dur: float, hide_after := false) -> void:
	if _tw:
		_tw.kill()
	_tw = create_tween()
	_tw.tween_method(func(x: float):
		_a = x
		if _body:
			_body.queue_redraw(), _a, to, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if hide_after:
		_tw.tween_callback(hide)


func _process(delta: float) -> void:
	if _hover:
		return
	_left -= delta
	if _left <= 0.0:
		dismiss()
		expired.emit()


func _click() -> void:
	if _left <= 0.0:
		return
	_left = 0.0
	set_process(false)
	hide()  # tout de suite : il ne doit pas apparaitre sur la capture de l'ecran qui suit
	pressed.emit()


class Body extends Control:
	var chip: FeedbackChip

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			chip._click()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			chip._hover = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			chip._hover = false
			queue_redraw()

	func _draw() -> void:
		var a := chip._a
		if a <= 0.01:
			return
		var m := FeedbackChip.MARGIN
		var r := Rect2(Vector2(m, m) + Vector2(0, (1.0 - a) * 4.0), Vector2(chip.pill_width(), FeedbackChip.H))
		var st := UITheme.box(Color(1, 1, 1, 0.97 * a), 99, Color(UITheme.ACCENT, 0.35 * a), 1, 0)
		st.shadow_color = Color(0.3, 0.1, 0.25, 0.20 * a)
		st.shadow_size = 8
		st.shadow_offset = Vector2(0, 2)
		if chip._hover:
			st.bg_color = Color(UITheme.ACCENT_SOFT, a)
			st.border_color = Color(UITheme.ACCENT, 0.8 * a)
		draw_style_box(st, r)
		var c := r.position + Vector2(20, r.size.y * 0.5)
		draw_circle(c, 12.0, Color(UITheme.ACCENT, a), true, -1.0, true)
		UIIcons.draw(self, "pencil", Rect2(c - Vector2(7.5, 7.5), Vector2(15, 15)), Color(1, 1, 1, a), 1.0)
		var f := UITheme.font(650)
		draw_string(f, Vector2(r.position.x + 38, r.get_center().y + f.get_ascent(FeedbackChip.FS) * 0.5 - 2),
			FeedbackChip.TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, FeedbackChip.FS,
			Color(UITheme.ACCENT_DARK if chip._hover else UITheme.INK, a))
