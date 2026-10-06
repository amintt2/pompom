class_name UIKit
## Petits composants d'interface dessines en code (toggle, segments, pastilles de couleur,
## barre d'humeur, compteur de pieces, dialogue, toast, confettis, onglets).


static func clear_styles(c: Control) -> void:
	var e := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus", "hover_mirrored", "normal_mirrored", "pressed_mirrored"]:
		c.add_theme_stylebox_override(st, e)


static func icon(n: String, sz := 20.0, c := UITheme.INK) -> Icon:
	return Icon.new(n, sz, c)


## Titre de section : icone dans une pastille + titre + sous-titre optionnel.
static func header(text: String, icon_name := "", sub := "", tint := UITheme.ACCENT) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon_name != "":
		var b := IconBubble.new(icon_name, 32.0, tint)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(b)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	v.add_child(UITheme.label(text, UITheme.FS_H2, UITheme.INK, 650))
	if sub != "":
		var s := UITheme.label(sub, UITheme.FS_SMALL, UITheme.MUTED)
		s.name = "Sub"
		v.add_child(s)
	return h


## Format francais : 12 345 (espace insecable).
static func fmt(n: int) -> String:
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = " " + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out


static func rounded_poly(r: Rect2, rad: float, seg := 8) -> PackedVector2Array:
	var pts := PackedVector2Array()
	rad = minf(rad, minf(r.size.x, r.size.y) * 0.5)
	var cs := [r.position + Vector2(r.size.x - rad, rad), r.position + Vector2(r.size.x - rad, r.size.y - rad),
		r.position + Vector2(rad, r.size.y - rad), r.position + Vector2(rad, rad)]
	var a0 := -PI * 0.5
	for k in 4:
		for i in seg + 1:
			var a: float = a0 + k * PI * 0.5 + PI * 0.5 * i / seg
			pts.append(cs[k] + Vector2(cos(a), sin(a)) * rad)
	return pts


# =========================================================================== icone
class Icon extends Control:
	var icon := ""
	var color := UITheme.INK
	var weight := 1.0

	func _init(n := "", sz := 20.0, c := UITheme.INK) -> void:
		icon = n
		color = c
		custom_minimum_size = Vector2(sz, sz)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_icon(n: String, c = null) -> void:
		icon = n
		if c != null:
			color = c
		queue_redraw()

	func _draw() -> void:
		if icon != "":
			UIIcons.draw(self, icon, Rect2(Vector2.ZERO, size), color, weight)


## Icone dans une pastille ronde teintee.
class IconBubble extends Control:
	var icon := ""
	var tint := UITheme.ACCENT
	var solid := false

	func _init(n := "", sz := 32.0, t := UITheme.ACCENT, p_solid := false) -> void:
		icon = n
		tint = t
		solid = p_solid
		custom_minimum_size = Vector2(sz, sz)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := minf(size.x, size.y) * 0.5
		var c := size * 0.5
		draw_circle(c, r, tint if solid else tint.lerp(Color.WHITE, 0.82), true, -1.0, true)
		var ir := r * 1.05
		UIIcons.draw(self, icon, Rect2(c - Vector2(ir, ir) * 0.5, Vector2(ir, ir)), Color.WHITE if solid else tint.darkened(0.12), 1.0)


# =========================================================================== interrupteur
class Toggle extends Button:
	var _t := 0.0
	var _tw: Tween

	func _init() -> void:
		toggle_mode = true
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(52, 32)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		toggled.connect(_on_toggled)
		mouse_entered.connect(queue_redraw)
		mouse_exited.connect(queue_redraw)

	func set_on(v: bool) -> void:
		set_pressed_no_signal(v)
		_t = 1.0 if v else 0.0
		queue_redraw()

	func _on_toggled(on: bool) -> void:
		if _tw:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_method(func(x: float):
			_t = x
			queue_redraw(), _t, 1.0 if on else 0.0, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var h := 28.0
		var w := 48.0
		var r := Rect2(Vector2(size.x - w, (size.y - h) * 0.5), Vector2(w, h))
		var hov := is_hovered()
		var track := Color("eadde5").lerp(UITheme.ACCENT, _t)
		if hov:
			track = track.darkened(0.05)
		draw_style_box(UITheme.box(track, 99, Color.TRANSPARENT, 0, 0), r)
		var kx := lerpf(r.position.x + h * 0.5, r.end.x - h * 0.5, _t)
		var kc := Vector2(kx, r.get_center().y)
		draw_circle(kc + Vector2(0, 1.5), h * 0.5 - 3.0, Color(0.3, 0.1, 0.2, 0.18), true, -1.0, true)
		draw_circle(kc, h * 0.5 - 3.5, Color.WHITE, true, -1.0, true)
		if _t > 0.5:
			UIIcons.draw(self, "check", Rect2(kc - Vector2(6, 6), Vector2(12, 12)), Color(UITheme.ACCENT, (_t - 0.5) * 2.0), 1.1)


# =========================================================================== segments
class Segmented extends PanelContainer:
	signal changed(index: int)
	var selected := 0
	var _btns: Array[Button] = []
	var _box: HBoxContainer
	var _from := Rect2()
	var _k := 1.0
	var _tw: Tween
	var _last := Rect2()

	func _init(options: Array, sel := 0) -> void:
		add_theme_stylebox_override("panel", UITheme.box(Color("f5ebf1"), 14, Color.TRANSPARENT, 0, 3))
		_box = HBoxContainer.new()
		_box.add_theme_constant_override("separation", 2)
		add_child(_box)
		for i in options.size():
			var b := Button.new()
			b.text = str(options[i])
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size = Vector2(0, 32)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			UIKit.clear_styles(b)
			var pad := StyleBoxEmpty.new()
			pad.content_margin_left = 12
			pad.content_margin_right = 12
			for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
				b.add_theme_stylebox_override(st, pad)
			b.add_theme_font_size_override("font_size", UITheme.FS_SMALL + 1)
			b.add_theme_constant_override("h_separation", 0)
			b.pressed.connect(select.bind(i, true))
			b.item_rect_changed.connect(queue_redraw)
			b.mouse_entered.connect(_paint)
			b.mouse_exited.connect(_paint)
			_box.add_child(b)
			_btns.append(b)
		selected = clampi(sel, 0, options.size() - 1)
		_paint()

	func button(i: int) -> Button:
		return _btns[i]

	func select(i: int, emit := false) -> void:
		if i < 0 or i >= _btns.size():
			return
		var changed_sel := i != selected
		_from = _last
		selected = i
		_k = 0.0 if _from.size.x > 0 else 1.0
		if _tw:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_method(func(x: float):
			_k = x
			queue_redraw(), _k, 1.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_paint()
		if emit and changed_sel:
			changed.emit(i)

	func _paint() -> void:
		for i in _btns.size():
			var b := _btns[i]
			var on := i == selected
			var c := UITheme.INK if on else (UITheme.ACCENT_DARK if b.is_hovered() else UITheme.MUTED)
			for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
				b.add_theme_color_override(k, c)
			b.add_theme_font_override("font", UITheme.font(650 if on else 500))
		queue_redraw()

	func _draw() -> void:
		if _btns.is_empty():
			return
		var b := _btns[selected]
		var target := Rect2(b.position + _box.position, b.size)
		var r := target
		if _k < 1.0 and _from.size.x > 0:
			var e := _k
			r = Rect2(_from.position.lerp(target.position, e), _from.size.lerp(target.size, e))
		_last = r
		var st := UITheme.box(Color.WHITE, 11, Color.TRANSPARENT, 0, 0)
		st.shadow_color = Color(0.35, 0.15, 0.3, 0.14)
		st.shadow_size = 5
		st.shadow_offset = Vector2(0, 1.5)
		draw_style_box(st, r)


# =========================================================================== pastilles de couleur
class Swatch extends Button:
	var color := Color.WHITE
	var selected := false
	var _h := 0.0

	func _init(c: Color, nm: String) -> void:
		color = c
		tooltip_text = nm.capitalize()
		custom_minimum_size = Vector2(26, 26)
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.12)

	func _draw() -> void:
		var c := size * 0.5
		var r := 9.0 + _h * 1.2
		if selected:
			draw_arc(c, 12.0, 0, TAU, 32, UITheme.INK, 2.0, true)
		elif _h > 0.01:
			draw_arc(c, 12.0, 0, TAU, 32, Color(UITheme.ACCENT, _h * 0.8), 2.0, true)
		draw_circle(c + Vector2(0, 1), r, Color(0.2, 0.1, 0.2, 0.12), true, -1.0, true)
		draw_circle(c, r, color, true, -1.0, true)
		draw_arc(c, r - 0.5, 0, TAU, 32, color.darkened(0.18), 1.0, true)
		draw_circle(c + Vector2(-r * 0.35, -r * 0.38), r * 0.22, Color(1, 1, 1, 0.45), true, -1.0, true)
		if selected:
			var ink := Color.WHITE if color.get_luminance() < 0.6 else UITheme.INK
			UIIcons.draw(self, "check", Rect2(c - Vector2(6, 6), Vector2(12, 12)), ink, 1.0)


## Bouton "couleur perso" : anneau arc-en-ciel.
class CustomSwatch extends Button:
	var color := Color.WHITE
	var selected := false
	var _h := 0.0

	func _init() -> void:
		tooltip_text = "Couleur personnalisée"
		custom_minimum_size = Vector2(26, 26)
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		mouse_entered.connect(func():
			_h = 1.0
			queue_redraw())
		mouse_exited.connect(func():
			_h = 0.0
			queue_redraw())

	func _draw() -> void:
		var c := size * 0.5
		var segs := 36
		for i in segs:
			var a0 := TAU * i / segs
			var a1 := TAU * (i + 1.05) / segs
			draw_arc(c, 9.0 + _h, a0, a1, 3, Color.from_hsv(float(i) / segs, 0.6, 1.0), 4.0, true)
		if selected:
			draw_circle(c, 6.5, color, true, -1.0, true)
			draw_arc(c, 12.0, 0, TAU, 32, UITheme.INK, 2.0, true)
		else:
			draw_circle(c, 6.5, Color.WHITE, true, -1.0, true)
			UIIcons.draw(self, "plus", Rect2(c - Vector2(5.5, 5.5), Vector2(11, 11)), UITheme.MUTED, 1.0)


## Popover avec un selecteur de couleur compact.
class ColorPop extends PopupPanel:
	signal changed(c: Color)
	signal committed(c: Color)
	var picker: ColorPicker
	var _start := Color.WHITE

	func _init() -> void:
		theme = UITheme.theme()
		transparent = true
		transparent_bg = true
		msaa_2d = Viewport.MSAA_4X
		picker = ColorPicker.new()
		picker.edit_alpha = false
		picker.picker_shape = ColorPicker.SHAPE_OKHSL_CIRCLE
		picker.presets_visible = false
		picker.sampler_visible = false
		picker.color_modes_visible = false
		picker.sliders_visible = false
		picker.hex_visible = true
		picker.can_add_swatches = false
		add_child(picker)
		picker.color_changed.connect(func(c: Color): changed.emit(c))
		popup_hide.connect(_on_hide)

	func open_near(ctrl: Control, c: Color) -> void:
		_start = c
		picker.color = c
		var host := ctrl.get_window()
		var f := host.content_scale_factor
		content_scale_factor = f
		var sz := Vector2i((Vector2(picker.get_combined_minimum_size()) + Vector2(28, 28)) * f)
		var gr := ctrl.get_global_rect()
		var p := host.position + Vector2i((gr.position + Vector2(gr.size.x * 0.5, gr.size.y + 6)) * f) - Vector2i(sz.x / 2, 0)
		var scr := DisplayServer.screen_get_usable_rect(host.current_screen)
		if p.y + sz.y > scr.end.y:
			p.y = host.position.y + int(gr.position.y * f) - sz.y - int(6 * f)
		p.x = clampi(p.x, scr.position.x, scr.end.x - sz.x)
		popup(Rect2i(p, sz))

	func _on_hide() -> void:
		committed.emit(picker.color)
		queue_free.call_deferred()


class Swatches extends HFlowContainer:
	signal picked(color: Color, final: bool)
	var current := Color.WHITE
	var custom: CustomSwatch
	var pop: ColorPop
	var _sw: Array[Swatch] = []

	func _init(palette: Dictionary, cur: Color, with_custom := true) -> void:
		add_theme_constant_override("h_separation", 3)
		add_theme_constant_override("v_separation", 3)
		for k in palette:
			var sw := Swatch.new(Color.html(palette[k]), k)
			sw.pressed.connect(_pick.bind(sw))
			add_child(sw)
			_sw.append(sw)
		if with_custom:
			custom = CustomSwatch.new()
			custom.pressed.connect(_open_custom)
			add_child(custom)
		set_current(cur)

	func swatches() -> Array[Swatch]:
		return _sw

	func _pick(sw: Swatch) -> void:
		set_current(sw.color)
		picked.emit(sw.color, true)

	func _open_custom() -> void:
		if pop and is_instance_valid(pop):
			return
		pop = ColorPop.new()
		add_child(pop)
		pop.changed.connect(func(c: Color):
			set_current(c)
			picked.emit(c, false))
		pop.committed.connect(func(c: Color):
			if is_instance_valid(self):
				picked.emit(c, true))
		pop.open_near(custom, current)

	func set_current(c: Color) -> void:
		current = c
		var any := false
		for sw in _sw:
			var d := Vector3(sw.color.r - c.r, sw.color.g - c.g, sw.color.b - c.b).length()
			sw.selected = d < 0.02 and not any
			any = any or sw.selected
			sw.queue_redraw()
		if custom:
			custom.selected = not any
			custom.color = c
			custom.queue_redraw()


# =========================================================================== barre
class Bar extends Control:
	var value := 0.0
	var color := UITheme.ACCENT
	var _tw: Tween

	func _init(c := UITheme.ACCENT) -> void:
		color = c
		custom_minimum_size = Vector2(40, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_value(v: float, animate := true) -> void:
		v = clampf(v, 0.0, 100.0)
		if absf(v - value) < 0.05:
			return
		if _tw:
			_tw.kill()
		if not animate or not is_inside_tree():
			value = v
			queue_redraw()
			return
		_tw = create_tween()
		_tw.tween_method(func(x: float):
			value = x
			queue_redraw(), value, v, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var h := minf(size.y, 10.0)
		var r := Rect2(0, (size.y - h) * 0.5, size.x, h)
		draw_style_box(UITheme.box(Color("f2e6ec"), 99, Color.TRANSPARENT, 0, 0), r)
		var fw := maxf(h, r.size.x * value / 100.0)
		if value <= 0.5:
			return
		var fr := Rect2(r.position, Vector2(fw, h))
		draw_style_box(UITheme.box(color, 99, Color.TRANSPARENT, 0, 0), fr)
		draw_style_box(UITheme.box(Color(1, 1, 1, 0.35), 99, Color.TRANSPARENT, 0, 0),
			Rect2(fr.position + Vector2(h * 0.4, 1.5), Vector2(maxf(0.0, fw - h * 0.8), h * 0.32)))


# =========================================================================== compteur de pieces
class CoinPill extends PanelContainer:
	var value := 0
	var _shown := 0.0
	var _label: Label
	var _tw: Tween
	var _floats := []  # {text, color, t}

	func _init(v := 0) -> void:
		var st := UITheme.pill(UITheme.GOLD_SOFT, 14, 5)
		st.border_color = Color(UITheme.GOLD, 0.45)
		st.set_border_width_all(1)
		add_theme_stylebox_override("panel", st)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(h)
		var ic := UIKit.icon("coin", 22.0)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		_label = UITheme.label("", 17, Color("8a5a00"), 650)
		h.add_child(_label)
		value = v
		_shown = v
		_label.text = UIKit.fmt(v)
		resized.connect(func(): pivot_offset = size * 0.5)

	func shown_text() -> String:
		return _label.text

	func set_value(v: int, animate := true) -> void:
		if v == value:
			return
		var d := v - value
		value = v
		if _tw:
			_tw.kill()
		if not animate or not is_inside_tree():
			_shown = v
			_label.text = UIKit.fmt(v)
			return
		_tw = create_tween()
		_tw.tween_method(func(x: float):
			_shown = x
			_label.text = UIKit.fmt(int(round(x))), _shown, float(v), 0.7).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		var b := create_tween()
		b.tween_property(self, "scale", Vector2.ONE * 1.12, 0.1).set_trans(Tween.TRANS_SINE)
		b.tween_property(self, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_floats.append({"text": ("+" if d > 0 else "") + UIKit.fmt(d), "color": UITheme.MINT if d > 0 else UITheme.ACCENT_DARK, "t": 0.0})
		set_process(true)

	func _ready() -> void:
		set_process(false)

	func _process(delta: float) -> void:
		for f in _floats:
			f["t"] += delta
		_floats = _floats.filter(func(f): return f["t"] < 1.3)
		queue_redraw()
		if _floats.is_empty():
			set_process(false)

	func _draw() -> void:
		var fnt := UITheme.font(650)
		for f in _floats:
			var t: float = f["t"] / 1.3
			var a := clampf(minf(t * 8.0, (1.0 - t) * 2.5), 0.0, 1.0)
			var p := Vector2(size.x * 0.5 - 14, size.y + 16 + t * 14.0)
			draw_string(fnt, p, f["text"], HORIZONTAL_ALIGNMENT_CENTER, 40, 15, Color(f["color"], a))


# =========================================================================== dialogue
class Dialog extends Control:
	signal closed(ok: bool)
	var ok_button: Button
	var cancel_button: Button
	var card: PanelContainer
	var _a := 0.0
	var _done := false

	## icon : Texture2D ou nom d'icone.
	func _init(title: String, body: String, ok_text: String, cancel_text := "Annuler", icon = "bag", price := -1, after := -1) -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		var cc := CenterContainer.new()
		cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(cc)
		card = PanelContainer.new()
		var st := UITheme.glass(26, 28, 1.0, 26)
		st.shadow_color = Color(0.25, 0.1, 0.25, 0.22)
		card.add_theme_stylebox_override("panel", st)
		card.custom_minimum_size = Vector2(380, 0)
		cc.add_child(card)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 12)
		card.add_child(v)
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", UITheme.box(UITheme.ACCENT_SOFT, 28, Color.TRANSPARENT, 0, 6))
		tile.custom_minimum_size = Vector2(104, 104)
		tile.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		v.add_child(tile)
		if icon is Texture2D:
			var tr := TextureRect.new()
			tr.texture = icon
			tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tile.add_child(tr)
		else:
			var ic := UIKit.icon(str(icon), 48.0, UITheme.ACCENT_DARK)
			ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			tile.add_child(ic)
		var t := UITheme.label(title, UITheme.FS_TITLE, UITheme.INK, 650)
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(t)
		var b := UITheme.label(body, UITheme.FS_BODY, UITheme.MUTED)
		b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size.x = 320
		v.add_child(b)
		if price >= 0:
			var pr := HBoxContainer.new()
			pr.alignment = BoxContainer.ALIGNMENT_CENTER
			pr.add_theme_constant_override("separation", 6)
			var ci := UIKit.icon("coin", 18.0)
			ci.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			pr.add_child(ci)
			pr.add_child(UITheme.label(UIKit.fmt(price), UITheme.FS_BODY, Color("8a5a00"), 650))
			if after >= 0:
				pr.add_child(UITheme.label("·  il te restera %s pièces" % UIKit.fmt(after), UITheme.FS_SMALL, UITheme.MUTED))
			v.add_child(pr)
		var sp := Control.new()
		sp.custom_minimum_size.y = 4
		v.add_child(sp)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		v.add_child(row)
		cancel_button = Button.new()
		cancel_button.text = cancel_text
		cancel_button.custom_minimum_size = Vector2(0, 46)
		cancel_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cancel_button.focus_mode = Control.FOCUS_NONE
		cancel_button.pressed.connect(close.bind(false))
		row.add_child(cancel_button)
		ok_button = Button.new()
		ok_button.text = ok_text
		ok_button.theme_type_variation = "PrimaryButton"
		ok_button.custom_minimum_size = Vector2(0, 46)
		ok_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ok_button.focus_mode = Control.FOCUS_NONE
		ok_button.pressed.connect(close.bind(true))
		row.add_child(ok_button)

	func _ready() -> void:
		card.resized.connect(func(): card.pivot_offset = card.size * 0.5)
		card.scale = Vector2.ONE * 0.9
		card.modulate.a = 0.0
		var t := create_tween().set_parallel()
		t.tween_method(func(x: float):
			_a = x
			queue_redraw(), 0.0, 1.0, 0.18)
		t.tween_property(card, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(card, "modulate:a", 1.0, 0.16)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(UITheme.INK, 0.30 * _a))

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			if not card.get_global_rect().has_point(get_global_transform() * ev.position):
				close(false)
			accept_event()

	func _input(ev: InputEvent) -> void:
		if _done or not is_visible_in_tree():
			return
		if ev is InputEventKey and ev.pressed and not ev.echo:
			if ev.keycode == KEY_ESCAPE:
				close(false)
				get_viewport().set_input_as_handled()
			elif ev.keycode == KEY_ENTER or ev.keycode == KEY_KP_ENTER:
				close(true)
				get_viewport().set_input_as_handled()

	func close(ok: bool) -> void:
		if _done:
			return
		_done = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		closed.emit(ok)
		var t := create_tween().set_parallel()
		t.tween_method(func(x: float):
			_a = x
			queue_redraw(), _a, 0.0, 0.14)
		t.tween_property(card, "modulate:a", 0.0, 0.12)
		t.tween_property(card, "scale", Vector2.ONE * 0.95, 0.12)
		t.chain().tween_callback(queue_free)


# =========================================================================== toast
class Toast extends PanelContainer:
	var _label: Label
	var _icon: IconBubble
	var _tw: Tween

	func _init() -> void:
		var st := UITheme.glass(99, 0, 0.97, 14)
		st.content_margin_left = 8
		st.content_margin_right = 18
		st.content_margin_top = 7
		st.content_margin_bottom = 7
		add_theme_stylebox_override("panel", st)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(h)
		_icon = IconBubble.new("check", 30.0, UITheme.MINT, true)
		h.add_child(_icon)
		_label = UITheme.label("", UITheme.FS_BODY, UITheme.INK, 650)
		_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(_label)
		modulate.a = 0.0
		visible = false

	func text() -> String:
		return _label.text

	func show_msg(msg: String, icon_name := "check", tint := UITheme.MINT) -> void:
		_label.text = msg
		_icon.icon = icon_name
		_icon.tint = tint
		_icon.queue_redraw()
		visible = true
		reset_size()
		if _tw:
			_tw.kill()
		_dy = 14.0
		modulate.a = 0.0
		_place()
		_tw = create_tween()
		_tw.set_parallel()
		_tw.tween_property(self, "_dy", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_tw.tween_property(self, "modulate:a", 1.0, 0.18)
		_tw.chain().tween_interval(2.2)
		_tw.chain().tween_property(self, "modulate:a", 0.0, 0.3)
		_tw.chain().tween_callback(func(): visible = false)

	var _dy := 0.0

	## En bas, centre (ne gene ni la barre de titre ni le compteur de pieces) ; suit les redimensionnements.
	func _place() -> void:
		var ps := get_parent_control().size if get_parent_control() else Vector2(600, 400)
		var ms := get_combined_minimum_size()
		position = Vector2((ps.x - ms.x) * 0.5, ps.y - ms.y - 34.0 + _dy)

	func _process(_delta: float) -> void:
		if visible:
			_place()

# =========================================================================== confettis
class Confetti extends Control:
	const COLORS := [Color("ff6fa8"), Color("ffc94a"), Color("63aef5"), Color("5fd3a4"), Color("9b8aff"), Color("ff9f6b")]
	var _p := []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	func _ready() -> void:
		set_process(false)

	func burst(at: Vector2, n := 56) -> void:
		for i in n:
			var a := randf_range(-PI * 0.92, -PI * 0.08)
			var sp := randf_range(260.0, 620.0)
			_p.append({"pos": at + Vector2(randf_range(-20, 20), randf_range(-10, 10)), "vel": Vector2(cos(a), sin(a)) * sp,
				"rot": randf() * TAU, "vr": randf_range(-9.0, 9.0), "col": COLORS[i % COLORS.size()],
				"sz": Vector2(randf_range(6, 10), randf_range(4, 7)), "life": 0.0, "max": randf_range(1.2, 1.9), "round": randf() < 0.3})
		set_process(true)

	func active() -> bool:
		return not _p.is_empty()

	func _process(delta: float) -> void:
		for p in _p:
			p["life"] += delta
			p["vel"] += Vector2(0, 980.0) * delta
			p["vel"] *= pow(0.25, delta)
			p["pos"] += p["vel"] * delta
			p["rot"] += p["vr"] * delta
		_p = _p.filter(func(p): return p["life"] < p["max"])
		queue_redraw()
		if _p.is_empty():
			set_process(false)

	func _draw() -> void:
		for p in _p:
			var a := clampf((p["max"] - p["life"]) * 3.0, 0.0, 1.0)
			var col: Color = p["col"]
			col.a = a
			draw_set_transform(p["pos"], p["rot"], Vector2(1.0, absf(cos(p["life"] * 7.0 + p["rot"]))))
			if p["round"]:
				draw_circle(Vector2.ZERO, p["sz"].y * 0.6, col, true, -1.0, true)
			else:
				draw_rect(Rect2(-p["sz"] * 0.5, p["sz"]), col)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# =========================================================================== onglets
class TabBtn extends Button:
	const TAB_FS := 14
	var tab_id := ""
	var label_text := ""
	var icon_name := ""
	var active := false
	var compact := false
	var _h := 0.0

	func _init(id: String, lbl: String, ic: String) -> void:
		tab_id = id
		label_text = lbl
		icon_name = ic
		tooltip_text = lbl
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		custom_minimum_size.y = 40
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))
		_update_min()

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.12)

	func set_state(p_active: bool, p_compact: bool) -> void:
		active = p_active
		compact = p_compact
		_update_min()
		queue_redraw()

	func _update_min() -> void:
		var show_label := active or not compact
		var w := 20.0 + 18.0
		if show_label:
			w += UITheme.font(650).get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, TAB_FS).x + 8.0
		custom_minimum_size.x = w

	func _draw() -> void:
		var show_label := active or not compact
		var col := Color.WHITE if active else UITheme.MUTED.lerp(UITheme.ACCENT_DARK, _h)
		if not active and _h > 0.01:
			draw_style_box(UITheme.box(Color(UITheme.ACCENT_SOFT, 0.8 * _h), 12, Color.TRANSPARENT, 0, 0), Rect2(Vector2(2, 2), size - Vector2(4, 4)))
		var f := UITheme.font(650)
		var tw := f.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, TAB_FS).x if show_label else 0.0
		var total := 20.0 + (8.0 + tw if show_label else 0.0)
		var x := (size.x - total) * 0.5
		UIIcons.draw(self, icon_name, Rect2(x, (size.y - 20) * 0.5, 20, 20), col, 1.0)
		if show_label:
			draw_string(f, Vector2(x + 28, size.y * 0.5 + f.get_ascent(TAB_FS) * 0.5 - 2), label_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, TAB_FS, col)


class Tabs extends PanelContainer:
	signal tab_selected(id: String)
	var current := ""
	var compact := false
	var buttons := {}
	var _box: HBoxContainer
	var _from := Rect2()
	var _last := Rect2()
	var _k := 1.0
	var _tw: Tween

	func _init(tabs: Array) -> void:
		add_theme_stylebox_override("panel", UITheme.glass(18, 4, 0.75, 8))
		_box = HBoxContainer.new()
		_box.add_theme_constant_override("separation", 2)
		add_child(_box)
		for t in tabs:
			var b := TabBtn.new(t[0], t[1], t[2])
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.pressed.connect(func(): tab_selected.emit(b.tab_id))
			b.item_rect_changed.connect(queue_redraw)
			_box.add_child(b)
			buttons[t[0]] = b

	func full_width() -> float:
		var w := 8.0
		for id in buttons:
			var b: TabBtn = buttons[id]
			w += 46.0 + UITheme.font(650).get_string_size(b.label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, TabBtn.TAB_FS).x + 2.0
		return w

	func set_compact(c: bool) -> void:
		if c == compact:
			return
		compact = c
		for id in buttons:
			buttons[id].set_state(id == current, compact)

	func select(id: String) -> void:
		if not buttons.has(id):
			return
		_from = _last
		current = id
		for k in buttons:
			buttons[k].set_state(k == id, compact)
		_k = 0.0 if _from.size.x > 0 else 1.0
		if _tw:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_method(func(x: float):
			_k = x
			queue_redraw(), _k, 1.0, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		if not buttons.has(current):
			return
		var b: Control = buttons[current]
		var target := Rect2(b.position + _box.position, b.size)
		var r := target
		if _k < 1.0 and _from.size.x > 0:
			r = Rect2(_from.position.lerp(target.position, _k), _from.size.lerp(target.size, _k))
		_last = r
		var st := UITheme.box(UITheme.ACCENT, 14, Color.TRANSPARENT, 0, 0)
		st.shadow_color = Color(UITheme.ACCENT_DARK, 0.35)
		st.shadow_size = 8
		st.shadow_offset = Vector2(0, 3)
		draw_style_box(st, r)
