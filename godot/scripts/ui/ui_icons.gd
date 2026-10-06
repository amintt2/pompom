class_name UIIcons
## Jeu d'icones vectorielles dessinees en code (grille 24 x 24, trait arrondi).
## UIIcons.draw(canvas_item, "hat", rect, couleur)
## Icônes : hat glasses bowtie wings palette chart gear coin heart lock check close minus
##          smile meh frown angry love bolt moon sun bag taskbar power pencil rotate sparkle
##          star none body drop eye mouth clock briefcase gamepad info plus pref_<-2..2>

const NAMES := ["hat", "glasses", "bowtie", "wings", "palette", "chart", "gear", "coin", "heart", "lock",
	"check", "close", "minus", "smile", "meh", "frown", "angry", "love", "bolt", "moon", "sun", "bag",
	"taskbar", "power", "pencil", "rotate", "sparkle", "star", "none", "body", "drop", "eye", "mouth",
	"clock", "briefcase", "gamepad", "info", "plus"]


static func draw(ci: CanvasItem, icon: String, rect: Rect2, col: Color, weight := 1.0) -> void:
	var s := minf(rect.size.x, rect.size.y) / 24.0
	var o := rect.get_center() - Vector2(12, 12) * s
	var w := maxf(1.3, 2.0 * s * weight)
	if icon.begins_with("pref_"):
		icon = {"pref_2": "love", "pref_1": "smile", "pref_0": "meh", "pref_-1": "frown", "pref_-2": "angry"}.get(icon, "meh")
	match icon:
		"hat":
			_rrect(ci, o, s, Rect2(7, 4, 10, 12.5), 2.0, col, w)
			_line(ci, o, s, [3.5, 17.5, 20.5, 17.5], col, w * 1.15)
			_line(ci, o, s, [7.5, 12.5, 16.5, 12.5], col, w)
		"glasses":
			ci.draw_arc(_p(o, s, 7, 13.5), 4.3 * s, 0, TAU, 28, col, w, true)
			ci.draw_arc(_p(o, s, 17, 13.5), 4.3 * s, 0, TAU, 28, col, w, true)
			ci.draw_arc(_p(o, s, 12, 13.2), 1.8 * s, PI * 1.1, PI * 1.9, 10, col, w, true)
			_line(ci, o, s, [2.8, 12.6, 1.6, 9.8], col, w)
			_line(ci, o, s, [21.2, 12.6, 22.4, 9.8], col, w)
		"bowtie":
			_poly(ci, o, s, [10.2, 10.6, 4.2, 6.8, 2.6, 8.2, 2.6, 15.8, 4.2, 17.2, 10.2, 13.4], col, w)
			_poly(ci, o, s, [13.8, 10.6, 19.8, 6.8, 21.4, 8.2, 21.4, 15.8, 19.8, 17.2, 13.8, 13.4], col, w)
			_rrect(ci, o, s, Rect2(10, 9.6, 4, 4.8), 1.2, col, w, true)
		"wings":
			var lw := [10.5, 8.5, 7.0, 4.8, 3.2, 4.6, 2.2, 7.8, 3.6, 10.8, 2.2, 13.0, 4.6, 15.6, 4.0, 18.0, 7.4, 18.8, 10.5, 15.5]
			_poly(ci, o, s, lw, col, w)
			var rw := []
			for i in range(0, lw.size(), 2):
				rw.append(24.0 - float(lw[i]))
				rw.append(lw[i + 1])
			_poly(ci, o, s, rw, col, w)
		"palette":
			var pts := PackedVector2Array()
			for i in 33:
				var a := -PI * 0.5 + TAU * i / 32.0
				var r := 9.4
				pts.append(_p(o, s, 12 + cos(a) * r, 12 + sin(a) * r * 0.92))
			# encoche du pouce
			pts[22] = _p(o, s, 7.5, 14.2)
			pts[23] = _p(o, s, 9.6, 16.6)
			ci.draw_polyline(pts, col, w, true)
			ci.draw_circle(_p(o, s, 8.6, 9.0), 1.7 * s, Color("ff6fa8") if col.v > 0.9 and col.s < 0.1 else col)
			ci.draw_circle(_p(o, s, 13.0, 7.2), 1.7 * s, Color("ffc94a") if col.v > 0.9 and col.s < 0.1 else col)
			ci.draw_circle(_p(o, s, 16.8, 10.6), 1.7 * s, Color("63aef5") if col.v > 0.9 and col.s < 0.1 else col)
			ci.draw_circle(_p(o, s, 15.6, 15.4), 1.7 * s, Color("5fd3a4") if col.v > 0.9 and col.s < 0.1 else col)
		"chart":
			_line(ci, o, s, [5.5, 19.5, 5.5, 13.5], col, w * 1.5)
			_line(ci, o, s, [12, 19.5, 12, 8.5], col, w * 1.5)
			_line(ci, o, s, [18.5, 19.5, 18.5, 4.5], col, w * 1.5)
		"gear":
			var g := PackedVector2Array()
			for k in 8:
				var a0 := TAU * k / 8.0
				for pa in [[7.6, -0.40], [10.2, -0.22], [10.2, 0.22], [7.6, 0.40]]:
					g.append(_p(o, s, 12 + cos(a0 + pa[1]) * pa[0], 12 + sin(a0 + pa[1]) * pa[0]))
			g.append(g[0])
			ci.draw_polyline(g, col, w, true)
			ci.draw_arc(_p(o, s, 12, 12), 3.0 * s, 0, TAU, 20, col, w, true)
		"coin":
			coin(ci, rect.get_center(), minf(rect.size.x, rect.size.y) * 0.46)
		"heart":
			ci.draw_colored_polygon(heart_points(_p(o, s, 12, 12.6), 9.2 * s), col)
		"lock":
			_rrect(ci, o, s, Rect2(5, 10.5, 14, 10.5), 2.5, col, w, true)
			ci.draw_arc(_p(o, s, 12, 10.5), 4.2 * s, PI, TAU, 16, col, w * 1.1, true)
			_line(ci, o, s, [7.8, 10.5, 7.8, 9.8], col, w * 1.1)
			_line(ci, o, s, [16.2, 10.5, 16.2, 9.8], col, w * 1.1)
		"check":
			_line(ci, o, s, [5, 12.5, 10, 17.5, 19, 7], col, w * 1.2)
		"close":
			_line(ci, o, s, [6.5, 6.5, 17.5, 17.5], col, w)
			_line(ci, o, s, [17.5, 6.5, 6.5, 17.5], col, w)
		"minus":
			_line(ci, o, s, [6, 12, 18, 12], col, w)
		"plus":
			_line(ci, o, s, [6, 12, 18, 12], col, w)
			_line(ci, o, s, [12, 6, 12, 18], col, w)
		"smile", "meh", "frown", "angry", "love":
			ci.draw_arc(_p(o, s, 12, 12), 9.2 * s, 0, TAU, 36, col, w, true)
			match icon:
				"love":
					ci.draw_colored_polygon(heart_points(_p(o, s, 8.6, 10.2), 2.6 * s), col)
					ci.draw_colored_polygon(heart_points(_p(o, s, 15.4, 10.2), 2.6 * s), col)
				"angry":
					_line(ci, o, s, [7, 8, 10.4, 9.6], col, w * 0.9)
					_line(ci, o, s, [17, 8, 13.6, 9.6], col, w * 0.9)
					ci.draw_circle(_p(o, s, 9, 11.4), 1.25 * s, col)
					ci.draw_circle(_p(o, s, 15, 11.4), 1.25 * s, col)
				_:
					ci.draw_circle(_p(o, s, 9, 10), 1.3 * s, col)
					ci.draw_circle(_p(o, s, 15, 10), 1.3 * s, col)
			match icon:
				"smile", "love":
					ci.draw_arc(_p(o, s, 12, 12.4), 4.4 * s, PI * 0.18, PI * 0.82, 14, col, w, true)
				"meh":
					_line(ci, o, s, [8.6, 15.4, 15.4, 15.4], col, w)
				"frown", "angry":
					ci.draw_arc(_p(o, s, 12, 19.6), 4.0 * s, PI * 1.22, PI * 1.78, 12, col, w, true)
		"bolt":
			_fill(ci, o, s, [13.5, 2.2, 4.8, 13.6, 11.2, 13.6, 10.2, 21.8, 19.2, 10.0, 12.8, 10.0, 13.5, 2.2], col)
		"moon":
			ci.draw_colored_polygon(moon_points(o, s), col)
		"sun":
			ci.draw_arc(_p(o, s, 12, 12), 4.2 * s, 0, TAU, 24, col, w, true)
			for k in 8:
				var a2 := TAU * k / 8.0
				ci.draw_line(_p(o, s, 12 + cos(a2) * 7.4, 12 + sin(a2) * 7.4), _p(o, s, 12 + cos(a2) * 9.8, 12 + sin(a2) * 9.8), col, w, true)
		"bag":
			_poly(ci, o, s, [5.2, 8.5, 18.8, 8.5, 19.8, 20.5, 4.2, 20.5], col, w)
			ci.draw_arc(_p(o, s, 12, 8.5), 3.6 * s, PI, TAU, 14, col, w, true)
			ci.draw_circle(_p(o, s, 8.6, 11.6), 1.0 * s, col)
			ci.draw_circle(_p(o, s, 15.4, 11.6), 1.0 * s, col)
		"taskbar":
			_line(ci, o, s, [3.5, 20, 20.5, 20], col, w * 1.3)
			_line(ci, o, s, [12, 3.5, 12, 14.5], col, w)
			_line(ci, o, s, [7.5, 10.5, 12, 15, 16.5, 10.5], col, w)
		"power":
			ci.draw_arc(_p(o, s, 12, 13), 8.0 * s, -PI * 0.28, PI * 1.28, 28, col, w, true)
			_line(ci, o, s, [12, 3, 12, 11.5], col, w)
		"pencil":
			_poly(ci, o, s, [4.2, 19.8, 5.2, 15.2, 15.8, 4.6, 19.4, 8.2, 8.8, 18.8], col, w)
			_line(ci, o, s, [13.4, 7.0, 17.0, 10.6], col, w)
		"rotate":
			ci.draw_arc(_p(o, s, 12, 12.5), 7.5 * s, -PI * 0.15, PI * 1.45, 28, col, w, true)
			_line(ci, o, s, [18.9, 5.0, 19.4, 10.4, 14.2, 9.6], col, w)
		"sparkle":
			var sp := PackedVector2Array()
			for k in 4:
				for i in 9:
					# branches concaves (etincelle) : courbe entre deux pointes
					var a := PI * 0.5 * k + PI * 0.5 * i / 8.0
					var t := absf(i / 8.0 - 0.5) * 2.0
					var rad := lerpf(3.0, 9.5, pow(t, 2.2))
					sp.append(_p(o, s, 11 + cos(a) * rad, 13 + sin(a) * rad))
			ci.draw_colored_polygon(sp, col)
			ci.draw_circle(_p(o, s, 19.5, 4.5), 1.9 * s, col)
		"star":
			var st := []
			for k in 10:
				var a3 := -PI * 0.5 + PI * k / 5.0
				var r3 := 9.8 if k % 2 == 0 else 4.4
				st.append(12 + cos(a3) * r3)
				st.append(12.8 + sin(a3) * r3)
			_fill(ci, o, s, st, col)
		"none":
			ci.draw_arc(_p(o, s, 12, 12), 8.6 * s, 0, TAU, 32, col, w, true)
			_line(ci, o, s, [6, 18, 18, 6], col, w)
		"body":
			ci.draw_arc(_p(o, s, 12, 13.5), 8.2 * s, 0, TAU, 32, col, w, true)
			ci.draw_arc(_p(o, s, 6.8, 6.6), 2.4 * s, PI * 0.9, PI * 1.95, 10, col, w, true)
			ci.draw_arc(_p(o, s, 17.2, 6.6), 2.4 * s, PI * 1.05, PI * 2.1, 10, col, w, true)
			ci.draw_circle(_p(o, s, 9.4, 13.4), 1.3 * s, col)
			ci.draw_circle(_p(o, s, 14.6, 13.4), 1.3 * s, col)
		"drop":
			var d := PackedVector2Array()
			d.append(_p(o, s, 12, 2.8))
			for i in 21:
				var a4 := -PI * 0.18 + (PI * 1.36) * i / 20.0
				d.append(_p(o, s, 12 + cos(a4) * 6.6, 14.6 + sin(a4) * 6.6))
			d.append(_p(o, s, 12, 2.8))
			ci.draw_polyline(d, col, w, true)
			ci.draw_arc(_p(o, s, 12, 14.6), 3.6 * s, PI * 0.55, PI * 0.95, 8, col, w * 0.8, true)
		"eye":
			ci.draw_arc(_p(o, s, 12, 20.5), 12.0 * s, PI * 1.22, PI * 1.78, 20, col, w, true)
			ci.draw_arc(_p(o, s, 12, 3.5), 12.0 * s, PI * 0.22, PI * 0.78, 20, col, w, true)
			ci.draw_circle(_p(o, s, 12, 12), 3.2 * s, col)
		"mouth":
			ci.draw_arc(_p(o, s, 12, 8.0), 8.0 * s, PI * 0.12, PI * 0.88, 20, col, w, true)
			_line(ci, o, s, [4.4, 10.6, 19.6, 10.6], col, w)
			ci.draw_arc(_p(o, s, 12, 16.0), 2.2 * s, 0, PI, 8, col, w * 0.8, true)
		"clock":
			ci.draw_arc(_p(o, s, 12, 12), 9.2 * s, 0, TAU, 36, col, w, true)
			_line(ci, o, s, [12, 6.8, 12, 12, 15.6, 14.2], col, w)
		"briefcase":
			_rrect(ci, o, s, Rect2(3.2, 7.8, 17.6, 12.4), 2.4, col, w)
			_line(ci, o, s, [9, 7.8, 9, 5, 15, 5, 15, 7.8], col, w)
			_line(ci, o, s, [3.4, 13, 20.6, 13], col, w * 0.9)
		"gamepad":
			_rrect(ci, o, s, Rect2(2.4, 7.2, 19.2, 11.2), 5.2, col, w)
			_line(ci, o, s, [7.4, 10.4, 7.4, 15.2], col, w)
			_line(ci, o, s, [5.0, 12.8, 9.8, 12.8], col, w)
			ci.draw_circle(_p(o, s, 15.6, 11.4), 1.3 * s, col)
			ci.draw_circle(_p(o, s, 18.0, 14.0), 1.3 * s, col)
		"info":
			ci.draw_arc(_p(o, s, 12, 12), 9.2 * s, 0, TAU, 36, col, w, true)
			_line(ci, o, s, [12, 11, 12, 16.5], col, w)
			ci.draw_circle(_p(o, s, 12, 7.8), 1.3 * s, col)
		"apple":
			ci.draw_arc(_p(o, s, 9.4, 14.2), 6.2 * s, PI * 0.45, PI * 1.62, 18, col, w, true)
			ci.draw_arc(_p(o, s, 14.6, 14.2), 6.2 * s, -PI * 0.62, PI * 0.55, 18, col, w, true)
			ci.draw_arc(_p(o, s, 12, 19.6), 2.2 * s, PI * 0.15, PI * 0.85, 6, col, w, true)
			_line(ci, o, s, [12, 8.6, 12.8, 4.2], col, w)
			_fill(ci, o, s, [13.4, 6.2, 15.6, 3.6, 18.6, 3.8, 16.6, 6.4], col)
		"flag":
			_line(ci, o, s, [5.5, 3, 5.5, 21], col, w)
			_poly(ci, o, s, [5.5, 4, 18.5, 4, 15.5, 8.5, 18.5, 13, 5.5, 13], col, w)
		"bread":
			var b := PackedVector2Array()
			b.append(_p(o, s, 4.5, 19.5))
			for i in 17:
				var a5 := PI + PI * i / 16.0
				b.append(_p(o, s, 12 + cos(a5) * 7.5, 11.5 + sin(a5) * 6.0))
			b.append(_p(o, s, 19.5, 19.5))
			b.append(b[0])
			ci.draw_polyline(b, col, w, true)
			_line(ci, o, s, [8.5, 9.5, 10, 12.5], col, w * 0.9)
			_line(ci, o, s, [12.5, 8.5, 14, 11.5], col, w * 0.9)
		"candy":
			ci.draw_arc(_p(o, s, 12, 12), 4.6 * s, 0, TAU, 20, col, w, true)
			_poly(ci, o, s, [7.6, 12, 3, 8, 3, 16], col, w)
			_poly(ci, o, s, [16.4, 12, 21, 8, 21, 16], col, w)
			_line(ci, o, s, [10.4, 9, 13.6, 15], col, w * 0.8)
		"burger":
			var bu := PackedVector2Array()
			for i in 17:
				var a6 := PI + PI * i / 16.0
				bu.append(_p(o, s, 12 + cos(a6) * 8.0, 11 + sin(a6) * 6.0))
			bu.append(bu[0])
			ci.draw_polyline(bu, col, w, true)
			_line(ci, o, s, [4, 14.5, 20, 14.5], col, w * 1.2)
			_rrect(ci, o, s, Rect2(4, 17, 16, 3.8), 1.8, col, w)
			ci.draw_circle(_p(o, s, 9.5, 8), 0.9 * s, col)
			ci.draw_circle(_p(o, s, 13.5, 7), 0.9 * s, col)
		"cake":
			_rrect(ci, o, s, Rect2(4, 11, 16, 9.5), 2.0, col, w)
			ci.draw_polyline(_pts(o, s, [4, 14.5, 6.5, 16, 9.2, 14.5, 12, 16, 14.8, 14.5, 17.5, 16, 20, 14.5]), col, w * 0.9, true)
			_line(ci, o, s, [12, 6.5, 12, 11], col, w)
			ci.draw_circle(_p(o, s, 12, 4), 1.5 * s, col)
		"cookie":
			ci.draw_arc(_p(o, s, 12, 12), 8.6 * s, 0, TAU, 32, col, w, true)
			for d in [[9, 9], [14.5, 8.5], [8.5, 14.5], [14, 14], [12, 11.5]]:
				ci.draw_circle(_p(o, s, d[0], d[1]), 1.15 * s, col)
		_:
			ci.draw_arc(_p(o, s, 12, 12), 6.0 * s, 0, TAU, 24, col, w, true)


## Piece d'or (toujours doree, quelle que soit la couleur demandee).
static func coin(ci: CanvasItem, c: Vector2, r: float, a := 1.0) -> void:
	ci.draw_circle(c + Vector2(0, r * 0.12), r, Color(UITheme.GOLD_DARK, 0.55 * a))
	ci.draw_circle(c, r, Color(UITheme.GOLD.darkened(0.12), a))
	ci.draw_circle(c, r * 0.80, Color(UITheme.GOLD, a))
	ci.draw_arc(c, r * 0.58, 0, TAU, 20, Color(UITheme.GOLD_DARK, 0.45 * a), maxf(1.0, r * 0.12), true)
	ci.draw_circle(c + Vector2(-r * 0.32, -r * 0.34), r * 0.2, Color(1, 1, 1, 0.75 * a))


static func heart_points(c: Vector2, sz: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 36:
		var t := TAU * i / 36.0
		var x := 16.0 * pow(sin(t), 3)
		var y := -(13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t))
		pts.append(c + Vector2(x, y + 1.5) * sz / 17.0)
	return pts


static func moon_points(o: Vector2, s: float) -> PackedVector2Array:
	var c1 := Vector2(12, 12.5)
	var r1 := 8.6
	var c2 := Vector2(16.4, 8.6)
	var r2 := 7.0
	var pts := PackedVector2Array()
	var start := (c2 - c1).angle()
	var outer: Array[Vector2] = []
	for i in 64:
		var a := start + TAU * i / 64.0
		var p := c1 + Vector2(cos(a), sin(a)) * r1
		if p.distance_to(c2) > r2:
			outer.append(p)
	var inner: Array[Vector2] = []
	var start2 := (c1 - c2).angle() + PI
	for i in 64:
		var a2 := start2 + TAU * i / 64.0
		var p2 := c2 + Vector2(cos(a2), sin(a2)) * r2
		if p2.distance_to(c1) < r1:
			inner.append(p2)
	if outer.is_empty():
		return pts
	if not inner.is_empty() and outer[outer.size() - 1].distance_to(inner[0]) > outer[outer.size() - 1].distance_to(inner[inner.size() - 1]):
		inner.reverse()
	for p3 in outer:
		pts.append(o + p3 * s)
	for p4 in inner:
		pts.append(o + p4 * s)
	return pts


static func _p(o: Vector2, s: float, x: float, y: float) -> Vector2:
	return o + Vector2(x, y) * s


static func _pts(o: Vector2, s: float, a: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(0, a.size() - 1, 2):
		pts.append(o + Vector2(float(a[i]), float(a[i + 1])) * s)
	return pts


static func _line(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color, w: float) -> void:
	var pts := _pts(o, s, a)
	ci.draw_polyline(pts, col, w, true)
	# bouts arrondis
	ci.draw_circle(pts[0], w * 0.5, col)
	ci.draw_circle(pts[pts.size() - 1], w * 0.5, col)
	for i in range(1, pts.size() - 1):
		ci.draw_circle(pts[i], w * 0.5, col)


static func _poly(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color, w: float) -> void:
	var pts := _pts(o, s, a)
	pts.append(pts[0])
	ci.draw_polyline(pts, col, w, true)
	for p in pts:
		ci.draw_circle(p, w * 0.5, col)


static func _fill(ci: CanvasItem, o: Vector2, s: float, a: Array, col: Color) -> void:
	var pts := _pts(o, s, a)
	if pts.size() > 3 and pts[0].is_equal_approx(pts[pts.size() - 1]):
		pts.remove_at(pts.size() - 1)
	ci.draw_colored_polygon(pts, col)


static func _rrect(ci: CanvasItem, o: Vector2, s: float, r: Rect2, rad: float, col: Color, w: float, fill := false) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(int(round(rad * s)))
	sb.corner_detail = 6
	sb.anti_aliasing = true
	if fill:
		sb.bg_color = col
	else:
		sb.bg_color = Color(col, 0.0)
		sb.draw_center = false
		sb.border_color = col
		sb.set_border_width_all(int(round(maxf(1.0, w))))
	ci.draw_style_box(sb, Rect2(o + r.position * s, r.size * s))
