class_name FeedbackIcons
## Icones supplementaires de la carte « Il s'est trompé » (meme style que UIIcons : grille 24 x 24, trait
## arrondi). Les noms inconnus sont transmis a UIIcons.
##   FeedbackIcons.draw(canvas_item, "note", rect, couleur)

const NAMES := ["play", "note", "code", "mail", "doc", "grid", "chat", "social", "book", "globe", "camera", "dots",
	"ball", "target", "skull", "trophy", "cup_down", "phone", "home", "link", "search", "person", "hash", "calendar",
	"at", "user"]


static func draw(ci: CanvasItem, icon: String, rect: Rect2, col: Color, weight := 1.0) -> void:
	var s := minf(rect.size.x, rect.size.y) / 24.0
	var o := rect.get_center() - Vector2(12, 12) * s
	var w := maxf(1.3, 2.0 * s * weight)
	match icon:
		"play":
			_rr(ci, o, s, Rect2(2.5, 4.5, 19, 15), 3.0, col, w)
			_fill(ci, o, s, [10, 8.6, 15.6, 12, 10, 15.4], col)
		"note":
			_l(ci, o, s, [9, 17.5, 9, 4.5, 19, 2.8, 19, 15.5], col, w)
			ci.draw_circle(_p(o, s, 6.6, 17.6), 2.6 * s, col, true, -1.0, true)
			ci.draw_circle(_p(o, s, 16.6, 15.6), 2.6 * s, col, true, -1.0, true)
		"code":
			_l(ci, o, s, [8, 6.5, 2.8, 12, 8, 17.5], col, w)
			_l(ci, o, s, [16, 6.5, 21.2, 12, 16, 17.5], col, w)
			_l(ci, o, s, [13.6, 4.8, 10.4, 19.2], col, w * 0.9)
		"mail":
			_rr(ci, o, s, Rect2(2.8, 5.5, 18.4, 13), 2.4, col, w)
			_l(ci, o, s, [3.6, 6.8, 12, 13, 20.4, 6.8], col, w)
		"doc":
			_poly(ci, o, s, [5.5, 2.8, 14, 2.8, 18.5, 7.3, 18.5, 21.2, 5.5, 21.2], col, w)
			_l(ci, o, s, [8.8, 11.5, 15.2, 11.5], col, w * 0.85)
			_l(ci, o, s, [8.8, 15.5, 15.2, 15.5], col, w * 0.85)
		"grid":
			_rr(ci, o, s, Rect2(3, 4, 18, 16), 2.4, col, w)
			_l(ci, o, s, [3.4, 9.5, 20.6, 9.5], col, w * 0.85)
			_l(ci, o, s, [3.4, 14.8, 20.6, 14.8], col, w * 0.85)
			_l(ci, o, s, [9.5, 4.4, 9.5, 19.6], col, w * 0.85)
		"chat":
			_rr(ci, o, s, Rect2(2.8, 4, 18.4, 12.6), 4.0, col, w)
			_fill(ci, o, s, [6.6, 15.8, 6.2, 20.6, 11.4, 16.0], col)
			for x in [8.0, 12.0, 16.0]:
				ci.draw_circle(_p(o, s, x, 10.3), 1.2 * s, col, true, -1.0, true)
		"social":
			for c in [Vector2(6, 12), Vector2(17.5, 6), Vector2(17.5, 18)]:
				ci.draw_arc(_p(o, s, c.x, c.y), 2.8 * s, 0, TAU, 18, col, w, true)
			_l(ci, o, s, [8.4, 10.7, 15, 7.3], col, w * 0.9)
			_l(ci, o, s, [8.4, 13.3, 15, 16.7], col, w * 0.9)
		"book":
			_poly(ci, o, s, [12, 6.2, 7.5, 4.2, 2.8, 4.6, 2.8, 18.6, 7.5, 18.2, 12, 20.2], col, w)
			_poly(ci, o, s, [12, 6.2, 16.5, 4.2, 21.2, 4.6, 21.2, 18.6, 16.5, 18.2, 12, 20.2], col, w)
		"globe":
			ci.draw_arc(_p(o, s, 12, 12), 9.0 * s, 0, TAU, 36, col, w, true)
			_l(ci, o, s, [3.4, 12, 20.6, 12], col, w * 0.85)
			var e := PackedVector2Array()
			for i in 25:
				var a := PI * 0.5 + PI * i / 24.0
				e.append(_p(o, s, 12 + cos(a) * 4.2, 12 - sin(a) * 9.0))
			ci.draw_polyline(e, col, w * 0.85, true)
			var e2 := PackedVector2Array()
			for p in e:
				e2.append(Vector2(2.0 * _p(o, s, 12, 0).x - p.x, p.y))
			ci.draw_polyline(e2, col, w * 0.85, true)
		"camera":
			_rr(ci, o, s, Rect2(2.6, 6.5, 13.4, 11), 2.6, col, w)
			_poly(ci, o, s, [16, 10.6, 21.4, 7.4, 21.4, 16.6, 16, 13.4], col, w)
		"dots":
			for x in [6.0, 12.0, 18.0]:
				ci.draw_circle(_p(o, s, x, 12), 2.0 * s, col, true, -1.0, true)
		"ball":
			ci.draw_arc(_p(o, s, 12, 12), 9.0 * s, 0, TAU, 36, col, w, true)
			var pent := []
			for k in 5:
				var a2 := -PI * 0.5 + TAU * k / 5.0
				pent.append_array([12 + cos(a2) * 3.6, 12 + sin(a2) * 3.6])
			_fill(ci, o, s, pent, col)
			for k in 5:
				var a3 := -PI * 0.5 + TAU * k / 5.0
				_l(ci, o, s, [12 + cos(a3) * 3.6, 12 + sin(a3) * 3.6, 12 + cos(a3) * 8.6, 12 + sin(a3) * 8.6], col, w * 0.8)
		"target":
			ci.draw_arc(_p(o, s, 12, 12), 8.0 * s, 0, TAU, 32, col, w, true)
			ci.draw_circle(_p(o, s, 12, 12), 2.0 * s, col, true, -1.0, true)
			for seg in [[12, 1.8, 12, 6.4], [12, 17.6, 12, 22.2], [1.8, 12, 6.4, 12], [17.6, 12, 22.2, 12]]:
				_l(ci, o, s, seg, col, w)
		"skull":
			var top := PackedVector2Array()
			for i in 25:
				var a4 := PI + PI * i / 24.0
				top.append(_p(o, s, 12 + cos(a4) * 8.0, 11 + sin(a4) * 8.0))
			for q in [[20, 14], [17, 16.2], [17, 20], [7, 20], [7, 16.2], [4, 14], [4, 11]]:
				top.append(_p(o, s, q[0], q[1]))
			ci.draw_polyline(top, col, w, true)
			ci.draw_circle(_p(o, s, 8.8, 12.2), 2.1 * s, col, true, -1.0, true)
			ci.draw_circle(_p(o, s, 15.2, 12.2), 2.1 * s, col, true, -1.0, true)
			_l(ci, o, s, [10.5, 17, 10.5, 19.5], col, w * 0.7)
			_l(ci, o, s, [13.5, 17, 13.5, 19.5], col, w * 0.7)
		"trophy":
			_poly(ci, o, s, [6.5, 3.5, 17.5, 3.5, 17, 10, 12, 14, 7, 10], col, w)
			ci.draw_arc(_p(o, s, 5.8, 7.2), 2.8 * s, PI * 0.5, PI * 1.5, 10, col, w, true)
			ci.draw_arc(_p(o, s, 18.2, 7.2), 2.8 * s, -PI * 0.5, PI * 0.5, 10, col, w, true)
			_l(ci, o, s, [12, 14, 12, 18], col, w)
			_l(ci, o, s, [7.5, 20.5, 16.5, 20.5], col, w * 1.1)
		"cup_down":
			_poly(ci, o, s, [6.5, 20.5, 17.5, 20.5, 17, 14, 12, 10, 7, 14], col, w)
			_l(ci, o, s, [12, 10, 12, 6], col, w)
			_l(ci, o, s, [7.5, 3.5, 16.5, 3.5], col, w * 1.1)
		"phone":
			_rr(ci, o, s, Rect2(6.8, 2.6, 10.4, 18.8), 2.6, col, w)
			_l(ci, o, s, [10.6, 18, 13.4, 18], col, w)
		"home":
			_poly(ci, o, s, [3.4, 11, 12, 3.6, 20.6, 11, 18.4, 11, 18.4, 20.4, 5.6, 20.4, 5.6, 11], col, w)
			_rr(ci, o, s, Rect2(10, 14, 4, 6.4), 1.0, col, w * 0.8)
		"link":
			_rr(ci, o, s, Rect2(2.6, 8.6, 10.8, 6.8), 3.4, col, w)
			_rr(ci, o, s, Rect2(10.6, 8.6, 10.8, 6.8), 3.4, col, w)
		"search":
			ci.draw_arc(_p(o, s, 10.4, 10.4), 6.4 * s, 0, TAU, 28, col, w, true)
			_l(ci, o, s, [15.2, 15.2, 20.6, 20.6], col, w * 1.15)
		"person", "user":
			ci.draw_arc(_p(o, s, 12, 8), 4.2 * s, 0, TAU, 22, col, w, true)
			ci.draw_arc(_p(o, s, 12, 22.5), 8.4 * s, PI * 1.08, PI * 1.92, 20, col, w, true)
		"hash":
			_l(ci, o, s, [9.6, 3.6, 7.6, 20.4], col, w)
			_l(ci, o, s, [16.4, 3.6, 14.4, 20.4], col, w)
			_l(ci, o, s, [4.4, 9, 20.4, 9], col, w)
			_l(ci, o, s, [3.6, 15, 19.6, 15], col, w)
		"calendar":
			_rr(ci, o, s, Rect2(3, 5, 18, 16), 2.6, col, w)
			_l(ci, o, s, [3.4, 10, 20.6, 10], col, w * 0.85)
			_l(ci, o, s, [8, 3, 8, 6.6], col, w)
			_l(ci, o, s, [16, 3, 16, 6.6], col, w)
		"at":
			ci.draw_arc(_p(o, s, 12, 12), 3.6 * s, 0, TAU, 20, col, w, true)
			ci.draw_arc(_p(o, s, 12, 12), 8.6 * s, -PI * 0.05, PI * 1.72, 32, col, w, true)
			_l(ci, o, s, [15.6, 9, 15.6, 13.6, 17.4, 15.4, 19.6, 14.6, 20.6, 12], col, w)
		_:
			UIIcons.draw(ci, icon, rect, col, weight)


static func _p(o: Vector2, s: float, x: float, y: float) -> Vector2:
	return o + Vector2(x, y) * s


static func _pts(o: Vector2, s: float, a: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(0, a.size() - 1, 2):
		pts.append(o + Vector2(float(a[i]), float(a[i + 1])) * s)
	return pts


static func _l(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color, w: float) -> void:
	var pts := _pts(o, s, a)
	ci.draw_polyline(pts, col, w, true)
	for p in pts:
		ci.draw_circle(p, w * 0.5, col, true, -1.0, true)


static func _poly(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color, w: float) -> void:
	var pts := _pts(o, s, a)
	pts.append(pts[0])
	ci.draw_polyline(pts, col, w, true)
	for p in pts:
		ci.draw_circle(p, w * 0.5, col, true, -1.0, true)


static func _fill(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color) -> void:
	UIIcons.fill_aa(ci, _pts(o, s, a), col)


static func _rr(ci: CanvasItem, o: Vector2, s: float, r: Rect2, rad: float, col: Color, w: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(round(rad * s)))
	sb.corner_detail = 6
	sb.anti_aliasing = true
	sb.draw_center = false
	sb.bg_color = Color(col, 0.0)
	sb.border_color = col
	sb.set_border_width_all(int(round(maxf(1.0, w))))
	ci.draw_style_box(sb, Rect2(o + r.position * s, r.size * s))
