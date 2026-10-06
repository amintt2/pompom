class_name MiniGameAvatar
extends Control
## Petit Pompom dessine en 2D dans la fenetre des mini-jeux : boule de poils a la couleur du
## compagnon, expressions, clignements, bouche qui parle, bulle de dialogue et bulle "je reflechis".
## API : say(text, duration), set_mood(mood, duration), set_thinking(on), bounce().
## Humeurs : idle happy love think smug sad surprised pout focus.

var fur := Color("f59ab8")
var mood := "idle"
var thinking := false
## true : le vrai compagnon 3D est assis dans la carte ; on ne dessine plus que ses bulles (pensee, paroles).
var external := false

var _base_mood := "idle"
var _mood_t := 0.0
var _t := 0.0
var _blink := 0.0
var _next_blink := 2.0
var _text := ""
var _text_t := 0.0
var _bubble_a := 0.0
var _bubble_s := 0.0
var _think_a := 0.0
var _jump := 0.0
var _jump_v := 0.0
var _look := Vector2.ZERO
var _look_target := Vector2.ZERO
var _look_t := 0.0
var _fluff := PackedFloat32Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(220, 200)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 26:
		_fluff.append(rng.randf_range(0.8, 1.15))


func _ready() -> void:
	fur = GameState.current_fur_color()


func say(text: String, duration := 2.6) -> void:
	_text = text
	_text_t = maxf(duration, 1.2 + text.length() * 0.035)
	_bubble_s = 0.0
	queue_redraw()


func is_talking() -> bool:
	return _text_t > 0.0


func set_mood(m: String, duration := 0.0) -> void:
	if duration <= 0.0:
		_base_mood = m
		if _mood_t <= 0.0:
			mood = m
	else:
		mood = m
		_mood_t = duration


## Point ou se posent les pieds du compagnon (coordonnees locales).
func floor_point() -> Vector2:
	var s := minf(size.x / 220.0, size.y / 200.0)
	return Vector2(size.x * 0.5, size.y - 18.0 * s)


func set_thinking(on: bool) -> void:
	thinking = on


## Petit saut de joie / de surprise.
func bounce(strength := 1.0) -> void:
	_jump_v = -260.0 * strength


func _process(delta: float) -> void:
	_t += delta
	if _mood_t > 0.0:
		_mood_t -= delta
		if _mood_t <= 0.0:
			mood = _base_mood
	# clignement
	_next_blink -= delta
	if _next_blink <= 0.0:
		_blink = 0.16
		_next_blink = randf_range(2.0, 4.5)
	_blink = maxf(0.0, _blink - delta)
	# regard : vers le haut quand il reflechit, sinon il regarde un peu partout
	_look_t -= delta
	if thinking:
		_look_target = Vector2(0.55 * sin(_t * 1.7), -0.8)
	elif _look_t <= 0.0:
		_look_t = randf_range(0.8, 2.2)
		_look_target = Vector2(randf_range(-0.6, 0.6), randf_range(-0.3, 0.4)) if randf() < 0.7 else Vector2.ZERO
	_look = _look.lerp(_look_target, 1.0 - exp(-delta * 9.0))
	# saut
	if _jump < 0.0 or _jump_v != 0.0:
		_jump_v += 1500.0 * delta
		_jump += _jump_v * delta
		if _jump >= 0.0:
			_jump = 0.0
			_jump_v = 0.0 if absf(_jump_v) < 120.0 else -_jump_v * 0.3
	# bulles
	if _text_t > 0.0:
		_text_t -= delta
		_bubble_a = minf(1.0, _bubble_a + delta * 8.0)
		_bubble_s = minf(1.0, _bubble_s + delta * 5.0)
	else:
		_bubble_a = maxf(0.0, _bubble_a - delta * 5.0)
	var want_think := 1.0 if thinking and _text_t <= 0.0 else 0.0
	_think_a = move_toward(_think_a, want_think, delta * 6.0)
	queue_redraw()


func _draw() -> void:
	var s := minf(size.x / 220.0, size.y / 200.0)
	var r := 46.0 * s
	var base := Vector2(size.x * 0.5, size.y - 18.0 * s)
	var breathe := sin(_t * 2.4) * 0.025
	var sq := Vector2(1.0 + breathe - _jump_v * 0.00012, 1.0 - breathe + _jump_v * 0.00012)
	var c := base + Vector2(0, -r * sq.y + _jump)
	if external:
		# le vrai compagnon est la : ses bulles partent du haut de sa tete (un peu plus grand que le dessin)
		c = base + Vector2(0, -r * 1.25)
		r *= 1.25
	else:
		# ombre au sol
		var shrink := clampf(1.0 + _jump / 160.0, 0.5, 1.0)
		draw_set_transform(base + Vector2(0, -2), 0.0, Vector2(1.0, 0.22))
		draw_circle(Vector2.ZERO, r * 0.95 * shrink, Color(0.35, 0.12, 0.3, 0.14), true, -1.0, true)
		draw_circle(Vector2.ZERO, r * 0.7 * shrink, Color(0.35, 0.12, 0.3, 0.1), true, -1.0, true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		_draw_body(c, r, sq)
		_draw_face(c, r, sq)
	if _think_a > 0.01:
		_draw_think(c + Vector2(r * 0.95, -r * 1.05), s, _think_a)
	if _bubble_a > 0.01 and _text != "":
		_draw_bubble(Vector2(size.x * 0.5, c.y - r * sq.y - 12.0 * s), s)


func _draw_body(c: Vector2, r: float, sq: Vector2) -> void:
	var dark := fur.darkened(0.08)
	var light := fur.lightened(0.18)
	draw_set_transform(c, 0.0, sq)
	# oreilles
	for side: float in [-1.0, 1.0]:
		var ep := Vector2(side * r * 0.6, -r * 0.96)
		draw_circle(ep, r * 0.33, dark, true, -1.0, true)
		draw_circle(ep, r * 0.27, fur, true, -1.0, true)
		draw_circle(ep + Vector2(0, r * 0.03), r * 0.15, fur.lerp(Color("ff8fb6"), 0.5).lightened(0.2), true, -1.0, true)
	# fourrure : petites touffes en couronne
	var n := _fluff.size()
	for i in n:
		var a := TAU * i / n + sin(_t * 1.3 + i) * 0.01
		var rr := r * (0.9 + 0.06 * _fluff[i])
		draw_circle(Vector2(cos(a), sin(a)) * rr, r * 0.2 * _fluff[i], dark, true, -1.0, true)
	draw_circle(Vector2.ZERO, r, fur, true, -1.0, true)
	for i in n:
		var a := TAU * (i + 0.5) / n
		draw_circle(Vector2(cos(a), sin(a)) * r * 0.86, r * 0.17 * _fluff[(i + 3) % n], fur, true, -1.0, true)
	# volume : reflet doux en haut, ombre en bas
	draw_circle(Vector2(-r * 0.22, -r * 0.3), r * 0.55, Color(light, 0.35), true, -1.0, true)
	draw_circle(Vector2(-r * 0.3, -r * 0.45), r * 0.22, Color(1, 1, 1, 0.22), true, -1.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_face(c: Vector2, r: float, sq: Vector2) -> void:
	var ink := UITheme.INK
	var m := mood
	if thinking and m == "idle":
		m = "think"
	draw_set_transform(c + Vector2(0, r * 0.08), 0.0, sq)
	var ex := r * 0.36
	var ey := -r * 0.05
	var er := r * 0.13
	var look := _look * r * 0.05
	var lw := maxf(1.6, r * 0.065)
	var blink := _blink > 0.0
	# joues
	var blush := 0.55 if m in ["happy", "love", "smug"] else 0.35
	for side: float in [-1.0, 1.0]:
		draw_circle(Vector2(side * ex * 1.45, r * 0.2), r * 0.15, Color(1, 0.42, 0.58, blush * 0.6), true, -1.0, true)
	# yeux
	for side: float in [-1.0, 1.0]:
		var p := Vector2(side * ex, ey) + look
		match m:
			"happy", "love":
				draw_arc(p + Vector2(0, er * 0.5), er * 1.15, PI * 1.12, PI * 1.88, 10, ink, lw, true)
			"smug":
				draw_circle(p + Vector2(0, er * 0.15), er * 0.95, ink, true, -1.0, true)
				draw_rect(Rect2(p + Vector2(-er * 1.3, -er * 1.4), Vector2(er * 2.6, er * 1.25)), fur)
				draw_line(p + Vector2(-er * 1.15, -er * 0.15), p + Vector2(er * 1.15, -er * 0.15), ink, lw, true)
			"focus":
				if blink:
					draw_line(p + Vector2(-er, 0), p + Vector2(er, 0), ink, lw, true)
				else:
					draw_circle(p, er * 0.95, ink, true, -1.0, true)
					draw_rect(Rect2(p + Vector2(-er * 1.3, -er * 1.6), Vector2(er * 2.6, er * 1.05)), fur)
					draw_circle(p + Vector2(er * 0.3, -er * 0.05), er * 0.3, Color(1, 1, 1, 0.9), true, -1.0, true)
			_:
				if blink:
					draw_arc(p + Vector2(0, -er * 0.4), er, PI * 0.15, PI * 0.85, 8, ink, lw, true)
				else:
					var big := 1.25 if m == "surprised" else 1.0
					draw_circle(p, er * big, ink, true, -1.0, true)
					draw_circle(p + Vector2(er * 0.35, -er * 0.38) * big, er * 0.4 * big, Color(1, 1, 1, 0.95), true, -1.0, true)
					draw_circle(p + Vector2(-er * 0.3, er * 0.35) * big, er * 0.17 * big, Color(1, 1, 1, 0.7), true, -1.0, true)
		# sourcils
		if m == "sad":
			# bout interieur releve
			draw_line(p + Vector2(-side * er * 1.1, -er * 2.4), p + Vector2(side * er * 1.0, -er * 1.75), ink, lw * 0.85, true)
		elif m == "think":
			if side > 0:
				draw_arc(p + Vector2(0, -er * 1.6), er * 1.1, PI * 1.2, PI * 1.8, 8, ink, lw * 0.85, true)
			else:
				draw_line(p + Vector2(-er * 1.0, -er * 1.9), p + Vector2(er * 1.0, -er * 1.9), ink, lw * 0.85, true)
		elif m == "pout":
			draw_line(p + Vector2(-side * er * 1.3, -er * 2.2), p + Vector2(side * er * 0.9, -er * 1.5), ink, lw * 0.9, true)
	if m == "love":
		for side: float in [-1.0, 1.0]:
			_heart(Vector2(side * ex * 1.9, -r * 0.55), r * 0.13, Color(UITheme.ACCENT, 0.9))
	# bouche
	var mp := Vector2(0, r * 0.2) + look * 0.5
	var talking := _text_t > 0.25
	var open := 0.0
	if talking:
		open = maxf(0.0, sin(_t * 17.0)) * 0.8 + 0.2
	match m:
		"sad":
			draw_arc(mp + Vector2(0, r * 0.1), r * 0.12, PI * 1.2, PI * 1.8, 10, ink, lw, true)
		"surprised":
			draw_circle(mp + Vector2(0, r * 0.03), r * 0.08 + open * r * 0.02, ink, true, -1.0, true)
		"think":
			draw_line(mp + Vector2(-r * 0.07, r * 0.03), mp + Vector2(r * 0.08, -r * 0.01), ink, lw, true)
		"pout":
			var pts := PackedVector2Array()
			for i in 9:
				var x := -r * 0.12 + r * 0.24 * i / 8.0
				pts.append(mp + Vector2(x, r * 0.04 + sin(i * PI / 2.0) * r * 0.025))
			draw_polyline(pts, ink, lw, true)
		"smug":
			draw_arc(mp + Vector2(r * 0.03, -r * 0.03), r * 0.12, PI * 0.1, PI * 0.7, 10, ink, lw, true)
		_:
			if open > 0.05:
				var h := r * (0.05 + open * 0.09)
				var pts2 := UIKit.rounded_poly(Rect2(mp + Vector2(-r * 0.1, -h * 0.3), Vector2(r * 0.2, h)), h * 0.5, 4)
				draw_colored_polygon(pts2, ink)
				draw_circle(mp + Vector2(0, h * 0.55), r * 0.05, Color("ff7a9a"), true, -1.0, true)
			else:
				var wide := 1.25 if m in ["happy", "love"] else 1.0
				draw_arc(mp + Vector2(-r * 0.06 * wide, -r * 0.02), r * 0.065 * wide, PI * 0.05, PI * 0.95, 8, ink, lw, true)
				draw_arc(mp + Vector2(r * 0.06 * wide, -r * 0.02), r * 0.065 * wide, PI * 0.05, PI * 0.95, 8, ink, lw, true)
	if m == "sad":
		var ty := fmod(_t * 0.8, 1.0)
		draw_circle(Vector2(-ex - er * 0.2, ey + er * 1.4 + ty * r * 0.3), r * 0.05, Color(UITheme.SKY, 0.8 * (1.0 - ty)), true, -1.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _heart(c: Vector2, sz: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var t := TAU * i / 24.0
		pts.append(c + Vector2(16.0 * pow(sin(t), 3), -(13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t))) * sz / 16.0)
	draw_colored_polygon(pts, col)


func _draw_think(p: Vector2, s: float, a: float) -> void:
	var st := UITheme.box(Color(1, 1, 1, 0.97 * a), 99, Color(UITheme.LINE_2, a), 1, 0)
	st.shadow_color = Color(0.35, 0.15, 0.32, 0.12 * a)
	st.shadow_size = 6
	st.shadow_offset = Vector2(0, 2)
	var w := 54.0 * s
	var h := 26.0 * s
	var r := Rect2(p + Vector2(-w * 0.2, -h * 1.2), Vector2(w, h))
	draw_circle(p + Vector2(-8, 10) * s, 3.0 * s, Color(1, 1, 1, 0.95 * a), true, -1.0, true)
	draw_circle(p + Vector2(-3, 3) * s, 5.0 * s, Color(1, 1, 1, 0.95 * a), true, -1.0, true)
	draw_style_box(st, r)
	for i in 3:
		var k := sin(_t * 7.0 - i * 0.9)
		var dc := r.get_center() + Vector2((i - 1) * 13.0 * s, -maxf(0.0, k) * 4.0 * s)
		draw_circle(dc, 3.6 * s, Color(UITheme.MUTED.lerp(UITheme.ACCENT, maxf(0.0, k)), a), true, -1.0, true)


func _draw_bubble(anchor: Vector2, s: float) -> void:
	var f := UITheme.font(650)
	var fs := int(round(15 * s))
	var maxw := size.x - 20.0 * s
	var tsz := f.get_multiline_string_size(_text, HORIZONTAL_ALIGNMENT_CENTER, maxw - 28.0 * s, fs)
	var bw := minf(maxw, tsz.x + 28.0 * s)
	var bh := tsz.y + 16.0 * s
	var k := MiniGameBase.ease_out_back(_bubble_s)
	var a := _bubble_a
	var pivot := anchor
	draw_set_transform(pivot, 0.0, Vector2.ONE * lerpf(0.6, 1.0, k))
	var r := Rect2(Vector2(-bw * 0.5, -bh - 10.0 * s), Vector2(bw, bh))
	r.position.y = maxf(r.position.y, -pivot.y + 2.0)
	var st := UITheme.box(Color(1, 1, 1, a), 14, Color(UITheme.LINE_2, a), 1, 0)
	st.shadow_color = Color(0.35, 0.15, 0.32, 0.14 * a)
	st.shadow_size = 8
	st.shadow_offset = Vector2(0, 3)
	draw_style_box(st, r)
	var tail := PackedVector2Array([Vector2(-8 * s, r.end.y - 1), Vector2(8 * s, r.end.y - 1), Vector2(0, r.end.y + 9 * s)])
	draw_colored_polygon(tail, Color(1, 1, 1, a))
	draw_line(Vector2(-8 * s, r.end.y), Vector2(0, r.end.y + 9 * s), Color(UITheme.LINE_2, a), 1.0, true)
	draw_line(Vector2(8 * s, r.end.y), Vector2(0, r.end.y + 9 * s), Color(UITheme.LINE_2, a), 1.0, true)
	draw_multiline_string(f, Vector2(r.position.x + 14.0 * s, r.position.y + 8.0 * s + f.get_ascent(fs)), _text,
		HORIZONTAL_ALIGNMENT_CENTER, bw - 28.0 * s, fs, -1, Color(UITheme.INK, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
