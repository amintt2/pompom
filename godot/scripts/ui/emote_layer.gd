class_name EmoteLayer
extends Control
## Petites emotions dessinees au-dessus du compagnon (coeurs, Zzz, notes...) + bulle de dialogue.

var stage: PetStage
var talk_enabled := true
var bubble_scale := 1.0  # taille de la bulle (l'apercu de la boutique la reduit)

var _parts := []  # {kind, pos, vel, life, max, size, rot}
var _bubble_text := ""
var _bubble_time := 0.0
var _bubble_alpha := 0.0
var _coin_pops := []  # {text, life, pos}
var _bounds := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func bind_pet(p: Pet) -> void:
	if not p.emote.is_connected(emit_emote):
		p.emote.connect(emit_emote)
		p.said.connect(say)


var bubble_lift := 0.0  # px : hauteur de ce qu'il porte sur la tete (ClipboardKeeper)


func head_pos() -> Vector2:
	if stage == null or stage.pet.root_node == null:
		return size * 0.5
	return stage.camera.unproject_position(stage.pet.head_top_global()) - Vector2(0, bubble_lift)


## Boite aux lettres : si `say_filter` renvoie true, la bulle est mise de cote au lieu d'etre affichee.
var say_filter: Callable
## En visio : aucune emotion animee.
var mute_emotes := false


func emit_emote(kind: String, count := 1) -> void:
	if mute_emotes:
		return
	var s := stage.ppu / 100.0 if stage else 1.0
	for i in count:
		var p := {
			"kind": kind, "pos": Vector2(randf_range(-22, 22), randf_range(-6, 6)) * s,
			"vel": Vector2(randf_range(-18, 18), randf_range(-55, -35)) * s,
			"life": 0.0, "max": randf_range(1.2, 1.8), "size": randf_range(9, 13) * s, "rot": randf_range(-0.3, 0.3),
			"delay": i * 0.12,
		}
		if kind == "zzz":
			p["pos"] = Vector2(18, 0) * s
			p["vel"] = Vector2(14, -28) * s
			p["max"] = 2.4
		elif kind in ["anger", "exclaim", "question", "sweat"]:
			p["pos"] = Vector2(26 if kind != "sweat" else -24, 8) * s
			p["vel"] = Vector2(0, -6) * s
			p["max"] = 1.6
			p["size"] = 13 * s
		elif kind == "star":
			p["pos"] = Vector2(cos(i * TAU / 3.0), sin(i * TAU / 3.0) * 0.3) * 26 * s
			p["vel"] = Vector2.ZERO
			p["max"] = 2.0
		_parts.append(p)


func say(text: String, duration := 3.2) -> void:
	if say_filter.is_valid() and bool(say_filter.call(text)):
		return
	if not talk_enabled or text == "":
		return
	_bubble_text = text
	_bubble_time = duration


func coin_pop(amount: int) -> void:
	_coin_pops.append({"text": "+%d" % amount, "life": 0.0})


func is_busy() -> bool:
	return not _parts.is_empty() or _bubble_alpha > 0.01 or not _coin_pops.is_empty()


## Rectangle (pixels) couvert par les dessins actuels.
func bounds() -> Rect2:
	return _bounds


func _process(delta: float) -> void:
	var vs := get_viewport_rect().size
	if size != vs:
		size = vs
	for p in _parts:
		if p["delay"] > 0.0:
			p["delay"] -= delta
			continue
		p["life"] += delta
		p["pos"] += p["vel"] * delta
		if p["kind"] == "star":
			var a: float = p["life"] * 4.0 + p["rot"] * 10.0
			p["pos"] = Vector2(cos(a), sin(a) * 0.35) * 26.0 * (stage.ppu / 100.0 if stage else 1.0)
	_parts = _parts.filter(func(p): return p["life"] < p["max"])
	for c in _coin_pops:
		c["life"] += delta
	_coin_pops = _coin_pops.filter(func(c): return c["life"] < 1.6)
	if _bubble_time > 0.0:
		_bubble_time -= delta
		_bubble_alpha = minf(1.0, _bubble_alpha + delta * 6.0)
	else:
		_bubble_alpha = maxf(0.0, _bubble_alpha - delta * 4.0)
	queue_redraw()


func _draw() -> void:
	var head := head_pos()
	var s := stage.ppu / 100.0 if stage else 1.0
	var bmin := Vector2(INF, INF)
	var bmax := Vector2(-INF, -INF)
	for p in _parts:
		if p["delay"] > 0.0:
			continue
		var t: float = p["life"] / p["max"]
		var a := clampf(minf(t * 6.0, (1.0 - t) * 3.0), 0.0, 1.0)
		var pos: Vector2 = head + p["pos"]
		var sz: float = p["size"] * (0.7 + 0.3 * minf(1.0, t * 5.0))
		_draw_icon(p["kind"], pos, sz, a, p["rot"])
		bmin = bmin.min(pos - Vector2(sz, sz) * 1.6)
		bmax = bmax.max(pos + Vector2(sz, sz) * 1.6)
	for c in _coin_pops:
		var t2: float = c["life"] / 1.6
		var a2 := clampf((1.0 - t2) * 2.5, 0.0, 1.0)
		var cp := head + Vector2(-30 * s, -10 * s - t2 * 26.0 * s)
		_draw_coin(cp, 8.0 * s, a2)
		draw_string(UITheme.font(650), cp + Vector2(11 * s, 5 * s), c["text"], HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(14 * s), Color(UITheme.GOLD.darkened(0.25), a2))
		bmin = bmin.min(cp - Vector2(12, 14) * s)
		bmax = bmax.max(cp + Vector2(44, 10) * s)
	if _bubble_alpha > 0.01:
		var r := _draw_bubble(head + Vector2(0, -8 * s), _bubble_text, _bubble_alpha, s)
		bmin = bmin.min(r.position)
		bmax = bmax.max(r.end)
	_bounds = Rect2(bmin, bmax - bmin) if bmin.x < INF else Rect2()


func _draw_bubble(anchor: Vector2, text: String, a: float, s: float) -> Rect2:
	s *= bubble_scale
	var f := UITheme.font(650)
	var fs := maxi(10, int(14 * s))
	var max_w := minf(size.x - 12.0, 200.0 * s)
	var ts := f.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, max_w - 24 * s, fs)
	var w := ts.x + 26 * s
	var h := ts.y + 16 * s
	var x := clampf(anchor.x - w * 0.5, 4.0, size.x - w - 4.0)
	var y := maxf(4.0, anchor.y - h - 10 * s)
	var rect := Rect2(x, y, w, h)
	var tail_x := clampf(anchor.x, x + 16 * s, x + w - 16 * s)
	var tip := Vector2(tail_x, y + h + 8 * s)
	# petit "pop" a l'apparition, centre sur la pointe de la bulle
	var k := 0.86 + 0.14 * a
	draw_set_transform(tip * (1.0 - k), 0.0, Vector2(k, k))
	var border := Color(Color("f3c6da"), a)
	var bw := maxf(1.0, 1.6 * s)
	var box := UITheme.box(Color(1, 1, 1, 0.98 * a), int(14 * s), border, int(round(bw)), 0)
	box.shadow_color = Color(0.45, 0.15, 0.35, 0.16 * a)
	box.shadow_size = int(7 * s)
	box.shadow_offset = Vector2(0, 2 * s)
	draw_style_box(box, rect)
	# queue de la bulle : contour puis remplissage qui masque le bord de la boite
	var tw := 7.5 * s
	UIIcons.fill_aa(self, PackedVector2Array([Vector2(tail_x - tw - bw, y + h - bw), Vector2(tail_x + tw + bw, y + h - bw),
		tip + Vector2(0, bw * 1.2)]), border)
	UIIcons.fill_aa(self, PackedVector2Array([Vector2(tail_x - tw, y + h - bw * 1.6), Vector2(tail_x + tw, y + h - bw * 1.6), tip]),
		Color(1, 1, 1, 0.98 * a))
	draw_multiline_string(f, Vector2(x + 13 * s, y + 8 * s + f.get_ascent(fs)), text, HORIZONTAL_ALIGNMENT_CENTER,
		w - 26 * s, fs, -1, Color(UITheme.INK, a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return Rect2(x - 7 * s, y - 7 * s, w + 14 * s, h + 20 * s)

func _draw_coin(c: Vector2, r: float, a: float) -> void:
	draw_circle(c, r, Color(UITheme.GOLD.darkened(0.2), a), true, -1.0, true)
	draw_circle(c, r * 0.82, Color(UITheme.GOLD, a), true, -1.0, true)
	draw_circle(c + Vector2(-r * 0.3, -r * 0.3), r * 0.25, Color(1, 1, 1, 0.6 * a), true, -1.0, true)


func _heart_points(c: Vector2, sz: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 32:
		var t := TAU * i / 32.0
		var x := 16.0 * pow(sin(t), 3)
		var y := -(13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t))
		pts.append(c + Vector2(x, y) * sz / 16.0)
	return pts


func _draw_icon(kind: String, pos: Vector2, sz: float, a: float, rot: float) -> void:
	match kind:
		"heart":
			UIIcons.fill_aa(self, _heart_points(pos, sz), Color(1.0, 0.35, 0.55, a))
			draw_circle(pos + Vector2(-sz * 0.35, -sz * 0.3), sz * 0.18, Color(1, 1, 1, 0.55 * a), true, -1.0, true)
		"zzz":
			draw_string(UITheme.font(650), pos, "z", HORIZONTAL_ALIGNMENT_LEFT, -1, int(sz * 1.6), Color(0.45, 0.5, 0.85, a))
		"note":
			var col := Color(0.55, 0.45, 0.95, a)
			draw_circle(pos, sz * 0.38, col, true, -1.0, true)
			draw_line(pos + Vector2(sz * 0.33, 0), pos + Vector2(sz * 0.33, -sz * 1.1), col, maxf(2.0, sz * 0.15), true)
			draw_line(pos + Vector2(sz * 0.33, -sz * 1.1), pos + Vector2(sz * 0.8, -sz * 0.8), col, maxf(2.0, sz * 0.15), true)
		"sparkle", "star":
			var col2 := Color(1.0, 0.82, 0.25, a)
			var pts := PackedVector2Array()
			for i in 8:
				var ang := rot + PI * i / 4.0
				var r := sz if i % 2 == 0 else sz * 0.32
				pts.append(pos + Vector2(cos(ang), sin(ang)) * r)
			UIIcons.fill_aa(self, pts, col2)
		"anger":
			var col3 := Color(0.93, 0.25, 0.3, a)
			for i in 4:
				var ang2 := PI * 0.5 * i + PI * 0.25
				var d := Vector2(cos(ang2), sin(ang2))
				draw_arc(pos + d * sz * 0.75, sz * 0.45, ang2 + PI * 0.6, ang2 + PI * 1.4, 8, col3, maxf(2.0, sz * 0.2))
		"exclaim":
			draw_string(UITheme.font(650), pos, "!", HORIZONTAL_ALIGNMENT_LEFT, -1, int(sz * 2.0), Color(1.0, 0.45, 0.3, a))
		"question":
			draw_string(UITheme.font(650), pos, "?", HORIZONTAL_ALIGNMENT_LEFT, -1, int(sz * 2.0), Color(0.45, 0.55, 0.95, a))
		"sweat":
			var col4 := Color(0.45, 0.75, 1.0, a)
			draw_circle(pos, sz * 0.45, col4, true, -1.0, true)
			UIIcons.fill_aa(self, PackedVector2Array([pos + Vector2(-sz * 0.42, -sz * 0.1), pos + Vector2(sz * 0.42, -sz * 0.1),
				pos + Vector2(0, -sz * 1.05)]), col4)
