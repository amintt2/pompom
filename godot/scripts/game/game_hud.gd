class_name GameHud
extends Control
## Petit affichage de jeu dessine au-dessus du compagnon :
##  - la nourriture qui vole jusqu'a sa bouche quand il mange un fichier
##  - les jauges de besoins (faim, amusement, energie) quand on le survole
##  - la banniere de montee de niveau

var stage: PetStage

var _foods := []  # {kind, from, t, dur}
var _needs_alpha := 0.0
var _needs_target := 0.0
var _banner := ""
var _banner_sub := ""
var _banner_t := 0.0
var _bounds := Rect2()

const NEED_COLORS := {
	"faim": Color("ff8a5c"), "fun": Color("ffcf3f"), "energie": Color("8e7dff"),
}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _sc() -> float:
	return stage.ppu / 100.0 if stage else 1.0


func mouth_pos() -> Vector2:
	if stage == null or stage.pet.root_node == null:
		return size * 0.5
	return stage.camera.unproject_position(stage.pet.mouth_global())


func head_pos() -> Vector2:
	if stage == null or stage.pet.root_node == null:
		return size * 0.5
	return stage.camera.unproject_position(stage.pet.head_top_global())


## Fait voler un aliment de `from` (pixels de la fenetre) jusqu'a la bouche.
func fly_food(kind: String, from: Vector2, dur := 0.5) -> void:
	_foods.append({"kind": kind, "from": from, "t": 0.0, "dur": dur})


func show_needs(on: bool) -> void:
	_needs_target = 1.0 if on else 0.0


func banner(title: String, sub := "", dur := 3.5) -> void:
	_banner = title
	_banner_sub = sub
	_banner_t = dur


func is_busy() -> bool:
	return not _foods.is_empty() or _needs_alpha > 0.01 or _banner_t > 0.0


func bounds() -> Rect2:
	return _bounds


func _process(delta: float) -> void:
	var vs := get_viewport_rect().size
	if size != vs:
		size = vs
	for f in _foods:
		f["t"] += delta
	_foods = _foods.filter(func(f): return f["t"] < f["dur"])
	_needs_alpha = move_toward(_needs_alpha, _needs_target, delta * 4.0)
	_banner_t = maxf(0.0, _banner_t - delta)
	queue_redraw()


func _draw() -> void:
	var s := _sc()
	var bmin := Vector2(INF, INF)
	var bmax := Vector2(-INF, -INF)
	# nourriture en vol (arc de parabole jusqu'a la bouche, retrecit en entrant)
	var mouth := mouth_pos()
	for f in _foods:
		var t: float = f["t"] / f["dur"]
		var from: Vector2 = f["from"]
		var p := from.lerp(mouth, t) + Vector2(0, -60.0 * s * 4.0 * t * (1.0 - t))
		var sz := 13.0 * s * (1.0 - 0.6 * t * t)
		_draw_food(f["kind"], p, sz, t * 6.0)
		bmin = bmin.min(p - Vector2(sz, sz) * 1.5)
		bmax = bmax.max(p + Vector2(sz, sz) * 1.5)
	# jauges de besoins
	if _needs_alpha > 0.01:
		var head := head_pos()
		var vals := {"faim": GameState.hunger, "fun": GameState.fun, "energie": GameState.energy}
		var w := 64.0 * s
		var h := 9.0 * s
		var y := head.y - 14.0 * s - (h + 7.0 * s) * 3.0
		var x := head.x - w * 0.5 + 9.0 * s
		var panel := Rect2(x - 22.0 * s, y - 7.0 * s, w + 30.0 * s, (h + 7.0 * s) * 3.0 + 8.0 * s)
		var box := UITheme.box(Color(1, 1, 1, 0.94 * _needs_alpha), int(12 * s), Color(UITheme.LINE, _needs_alpha), int(1.5 * s), 0)
		box.shadow_color = Color(0, 0, 0, 0.12 * _needs_alpha)
		box.shadow_size = int(4 * s)
		draw_style_box(box, panel)
		for k in ["faim", "fun", "energie"]:
			var col: Color = NEED_COLORS[k]
			_draw_need_icon(k, Vector2(x - 11.0 * s, y + h * 0.5), 6.0 * s, Color(col.darkened(0.15), _needs_alpha))
			draw_style_box(UITheme.box(Color(0.94, 0.9, 0.9, _needs_alpha), int(h * 0.5), Color.TRANSPARENT, 0, 0), Rect2(x, y, w, h))
			var v: float = clampf(float(vals[k]) / 100.0, 0.0, 1.0)
			var fill := col if v > 0.25 else UITheme.BAD
			if v > 0.02:
				draw_style_box(UITheme.box(Color(fill, _needs_alpha), int(h * 0.5), Color.TRANSPARENT, 0, 0), Rect2(x, y, w * v, h))
			y += h + 7.0 * s
		bmin = bmin.min(panel.position - Vector2(4, 4))
		bmax = bmax.max(panel.end + Vector2(4, 4))
		# niveau
		var lv := "Niv. %d" % GameState.level
		draw_string(UITheme.font(650), Vector2(panel.position.x, panel.position.y - 5.0 * s), lv,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(12 * s), Color(UITheme.LAVENDER.darkened(0.2), _needs_alpha))
		bmin = bmin.min(panel.position - Vector2(4, 20.0 * s))
	# banniere de niveau
	if _banner_t > 0.0:
		var a := clampf(minf(_banner_t * 2.5, (3.5 - _banner_t) * 6.0 + 0.3), 0.0, 1.0)
		var f := UITheme.font(650)
		var fs := int(18 * s)
		var tw := f.get_string_size(_banner, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var sw := f.get_string_size(_banner_sub, HORIZONTAL_ALIGNMENT_LEFT, -1, int(12 * s)).x
		var bw := maxf(tw, sw) + 34.0 * s
		var bh := (52.0 if _banner_sub != "" else 34.0) * s
		var head2 := head_pos()
		var r := Rect2(clampf(head2.x - bw * 0.5, 4.0, size.x - bw - 4.0), maxf(4.0, head2.y - bh - 30.0 * s), bw, bh)
		var bb := UITheme.box(Color(UITheme.ACCENT, a), int(16 * s), Color(1, 1, 1, a), int(2 * s), 0)
		bb.shadow_color = Color(UITheme.ACCENT_DARK, 0.35 * a)
		bb.shadow_size = int(8 * s)
		draw_style_box(bb, r)
		draw_string(f, Vector2(r.position.x + (bw - tw) * 0.5, r.position.y + 25.0 * s), _banner,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, a))
		if _banner_sub != "":
			draw_string(UITheme.font(), Vector2(r.position.x + (bw - sw) * 0.5, r.position.y + 43.0 * s), _banner_sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, int(12 * s), Color(1, 1, 1, 0.92 * a))
		bmin = bmin.min(r.position - Vector2(10, 10))
		bmax = bmax.max(r.end + Vector2(10, 10))
	_bounds = Rect2(bmin, bmax - bmin) if bmin.x < INF else Rect2()


func _draw_need_icon(kind: String, c: Vector2, r: float, col: Color) -> void:
	match kind:
		"faim":  # pomme
			draw_circle(c + Vector2(0, r * 0.15), r * 0.85, col)
			draw_line(c + Vector2(0, -r * 0.6), c + Vector2(r * 0.25, -r * 1.05), col.darkened(0.3), maxf(1.5, r * 0.22))
		"fun":  # etoile
			var pts := PackedVector2Array()
			for i in 10:
				var ang := -PI / 2 + PI * i / 5.0
				pts.append(c + Vector2(cos(ang), sin(ang)) * (r if i % 2 == 0 else r * 0.45))
			draw_colored_polygon(pts, col)
		"energie":  # eclair
			draw_colored_polygon(PackedVector2Array([c + Vector2(r * 0.15, -r), c + Vector2(-r * 0.55, r * 0.15),
				c + Vector2(-r * 0.05, r * 0.15), c + Vector2(-r * 0.2, r), c + Vector2(r * 0.55, -r * 0.2),
				c + Vector2(r * 0.05, -r * 0.2)]), col)


func _draw_food(kind: String, c: Vector2, r: float, spin: float) -> void:
	var rot := Transform2D(spin * 0.4, c)
	draw_set_transform_matrix(rot)
	var o := Vector2.ZERO
	match kind:
		"fruit":  # pomme rouge brillante
			draw_circle(o, r, Color("ef4a5a"))
			draw_circle(o + Vector2(-r * 0.35, -r * 0.35), r * 0.28, Color(1, 1, 1, 0.55))
			draw_line(o + Vector2(0, -r * 0.9), o + Vector2(r * 0.15, -r * 1.35), Color("7a4a2b"), maxf(2.0, r * 0.18))
			draw_colored_polygon(PackedVector2Array([o + Vector2(r * 0.15, -r * 1.2), o + Vector2(r * 0.8, -r * 1.45),
				o + Vector2(r * 0.45, -r * 0.95)]), Color("5cc46b"))
		"pain":  # tranche de pain
			draw_style_box(UITheme.box(Color("e9b15f"), int(r * 0.5), Color("b9782f"), int(maxf(1.0, r * 0.15)), 0),
				Rect2(o - Vector2(r, r * 0.8), Vector2(r * 2.0, r * 1.6)))
			draw_style_box(UITheme.box(Color("fbe3b0"), int(r * 0.35), Color.TRANSPARENT, 0, 0),
				Rect2(o - Vector2(r * 0.7, r * 0.5), Vector2(r * 1.4, r * 1.1)))
		"bonbon":  # bonbon emballe
			draw_colored_polygon(PackedVector2Array([o + Vector2(-r * 0.6, 0), o + Vector2(-r * 1.4, -r * 0.6), o + Vector2(-r * 1.4, r * 0.6)]), Color("ff7eb3"))
			draw_colored_polygon(PackedVector2Array([o + Vector2(r * 0.6, 0), o + Vector2(r * 1.4, -r * 0.6), o + Vector2(r * 1.4, r * 0.6)]), Color("ff7eb3"))
			draw_circle(o, r * 0.75, Color("ff4f86"))
			draw_arc(o, r * 0.45, 0.4, 2.6, 8, Color(1, 1, 1, 0.8), maxf(1.5, r * 0.15))
		"burger":
			draw_style_box(UITheme.box(Color("e9a44a"), int(r * 0.7), Color.TRANSPARENT, 0, 0), Rect2(o + Vector2(-r, -r), Vector2(r * 2.0, r * 0.9)))
			draw_rect(Rect2(o + Vector2(-r * 1.05, -r * 0.15), Vector2(r * 2.1, r * 0.3)), Color("5cc46b"))
			draw_rect(Rect2(o + Vector2(-r, r * 0.1), Vector2(r * 2.0, r * 0.35)), Color("7a3b22"))
			draw_style_box(UITheme.box(Color("e9a44a"), int(r * 0.3), Color.TRANSPARENT, 0, 0), Rect2(o + Vector2(-r, r * 0.42), Vector2(r * 2.0, r * 0.5)))
		"gateau":  # part de gateau rose
			draw_colored_polygon(PackedVector2Array([o + Vector2(-r, r * 0.8), o + Vector2(r, r * 0.8), o + Vector2(r, -r * 0.2), o + Vector2(-r * 0.2, -r * 0.8)]), Color("ffd7e6"))
			draw_colored_polygon(PackedVector2Array([o + Vector2(-r * 0.2, -r * 0.8), o + Vector2(r, -r * 0.2), o + Vector2(r, -r * 0.45), o + Vector2(-r * 0.25, -r * 1.05)]), Color("ff7eb3"))
			draw_circle(o + Vector2(r * 0.3, -r * 0.95), r * 0.25, Color("e5484d"))
		_:  # biscuit
			draw_circle(o, r, Color("d9a066"))
			for d in [Vector2(-0.4, -0.3), Vector2(0.35, -0.1), Vector2(-0.1, 0.4), Vector2(0.3, 0.45)]:
				draw_circle(o + d * r, r * 0.14, Color("6b3e26"))
	draw_set_transform_matrix(Transform2D.IDENTITY)
