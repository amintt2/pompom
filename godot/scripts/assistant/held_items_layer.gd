class_name HeldItemsLayer
extends Control
## Dessine ce que le compagnon garde du presse-papiers : la carte en equilibre sur sa tete (image a coins
## arrondis et bord blanc, petite note en papier, ou fichier), la pile des plus anciennes derriere avec un
## badge "+N", le petit tas a ses pieds, et toutes les animations (arrivee, balancement, fatigue, depot, poof).
## Cree et pilote par ClipboardKeeper ; `bounds()` donne la zone a rendre cliquable.

var stage: PetStage
var keeper: ClipboardKeeper
## Couche des bulles (EmoteLayer) : si elle expose `bubble_lift`, on lui indique la hauteur de la carte
## pour que les bulles de dialogue passent au-dessus au lieu de la cacher.
var emotes: Control

const CARD_IMG := 64.0  # plus grand cote de l'image (px a l'echelle 1)
const BORDER := 4.0
const NOTE_SIZE := Vector2(88, 64)
const FILE_SIZE := Vector2(76, 62)
const MINI := 0.48  # echelle des cartes du tas
const NOTE_BG := Color("fff6cc")
const NOTE_LINE := Color(0.45, 0.62, 0.95, 0.22)
const TAPE := Color(1.0, 0.6, 0.76, 0.72)

var _t := 0.0
var _bounds := Rect2()
var _tilt := 0.0
var _tilt_v := 0.0
var _prev_hs := Vector2.INF
var _prev_v := Vector2.ZERO
var _pop := {}  # id -> age
var _flyers: Array = []  # {item, kind: down|up|poof, t, dur, from, to, rot0}
var _pills: Array = []  # {text, color, life}
var _hover := ""
var _hover_t := 0.0
var _hover_a := 0.0
var _close_a := 0.0
var _strain := 0.0
var _bump := 0.0
var _drag_item := {}
var _drag_pos := Vector2.ZERO
var _drag_vel := Vector2.ZERO
var _drag_outside := false
var _drag_end_pos := Vector2.INF
var _drag_end_ms := 0
var _back := {}  # {item, from, t} : retour sur la tete apres un glisser annule
var _was_drawn := false
var _lift := 0.0
var sim_mouse_pos := Vector2.INF  # tests : position de souris simulee (survol)
## Les cartes de sa tete sont montrees en eventail (HeldFan) : on ne les dessine plus ici
## (la geometrie reste calculee pour head_zone() / head_anchor()).
var fan_hidden := false
var _head_zone := Rect2()

# geometrie du dernier dessin (tests de clic)
var _card_xf := Transform2D()
var _card_size := Vector2.ZERO
var _card_item := {}
var _close_c := Vector2.INF
var _badge_c := Vector2.INF
var _pile_rect := Rect2()
var _pile_base := Vector2.ZERO
var _anchor := Vector2.ZERO
var _card_top := Vector2.ZERO

var _sb := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func bounds() -> Rect2:
	return _bounds


func _sc() -> float:
	return stage.ppu / 100.0 if stage else 1.0


func _ready_to_draw() -> bool:
	return stage != null and stage.pet != null and stage.pet.root_node != null and keeper != null and keeper.enabled


func head_pos() -> Vector2:
	if stage == null or stage.pet.root_node == null:
		return size * 0.5
	return stage.camera.unproject_position(stage.pet.head_top_global())


## Zone (pixels de la fenetre) occupee par la pile sur sa tete ; vide s'il ne porte rien.
func head_zone() -> Rect2:
	return _head_zone if _ready_to_draw() and not keeper.head_items().is_empty() else Rect2()


## Point (milieu du bas de la carte du dessus) ou la pile est posee sur sa tete.
func head_anchor() -> Vector2:
	return _anchor if _anchor != Vector2.ZERO else head_pos()


## Taille (px de la fenetre) de la carte de cet objet quand elle est posee sur sa tete.
func card_px(it: Dictionary) -> Vector2:
	return _card_px(it)


# =========================================================================== evenements (appeles par le keeper)
func on_item_added(it: Dictionary) -> void:
	_pop[it["id"]] = 0.0


func strain(level: int) -> void:
	_strain = 1.0 if level >= 2 else 0.6


func press_bump() -> void:
	_bump = 1.0


func pill(text: String, color: Color, _it: Dictionary) -> void:
	_pills = _pills.filter(func(p): return p["life"] < 0.25)  # une seule a la fois, lisible
	_pills.append({"text": text, "color": color, "life": 0.0, "max": 1.9})


func play_forget(it: Dictionary) -> void:
	var from := _item_pos(it)
	_flyers.append({"item": it, "kind": "poof", "t": 0.0, "dur": 0.45, "from": from, "to": from,
		"scale": MINI if it.get("place", "") == "feet" else 1.0})


func play_put_down(list: Array) -> void:
	var i := 0
	for it in list:
		var from := _anchor
		if _drag_end_pos != Vector2.INF and Time.get_ticks_msec() - _drag_end_ms < 300:
			from = Vector2(clampf(_drag_end_pos.x, 0.0, size.x), clampf(_drag_end_pos.y, 0.0, size.y))
		_flyers.append({"item": it, "kind": "down", "t": -0.12 * i, "dur": 0.75, "from": from, "to": _pile_base,
			"scale": 1.0})
		i += 1


func play_pick_up(it: Dictionary) -> void:
	_flyers.append({"item": it, "kind": "up", "t": 0.0, "dur": 0.55, "from": _pile_base, "to": _anchor, "scale": MINI})
	_pop.erase(it["id"])


func begin_drag(it: Dictionary, at: Vector2) -> void:
	_drag_item = it
	_drag_pos = at
	_drag_vel = Vector2.ZERO
	_drag_outside = false


func drag_to(at: Vector2, outside: bool) -> void:
	_drag_vel = _drag_vel.lerp((at - _drag_pos) * 30.0, 0.5)
	_drag_pos = at
	_drag_outside = outside


func end_drag(consumed: bool) -> void:
	if _drag_item.is_empty():
		return
	_drag_end_pos = _drag_pos
	_drag_end_ms = Time.get_ticks_msec()
	if not consumed:
		_back = {"item": _drag_item, "from": _drag_pos, "t": 0.0}
	_drag_item = {}


## Efface les animations en cours (desactivation).
func reset() -> void:
	_flyers.clear()
	_pills.clear()
	_pop.clear()
	_back = {}
	_drag_item = {}
	_card_item = {}
	_lift = 0.0
	_set_bubble_lift(0.0)
	queue_redraw()


func _set_bubble_lift(v: float) -> void:
	if emotes and "bubble_lift" in emotes:
		emotes.set("bubble_lift", v)


## Zone ou lacher une carte pour la poser a ses pieds.
func pile_drop_rect() -> Rect2:
	var s := _sc()
	return Rect2(_pile_base - Vector2(34, 46) * s, Vector2(68, 56) * s)


# =========================================================================== tests de clic
func hit_test(pos: Vector2) -> Dictionary:
	if not _ready_to_draw() or not _drag_item.is_empty():
		return {}
	var s := _sc()
	if not _card_item.is_empty() and keeper.items.has(_card_item):
		if _close_a > 0.3 and pos.distance_to(_close_c) <= 10.0 * s:
			return {"zone": "close", "item": _card_item}
		if _badge_c != Vector2.INF and pos.distance_to(_badge_c) <= 10.0 * s:
			return {"zone": "badge", "item": _card_item}
		var lp: Vector2 = _card_xf.affine_inverse() * pos
		if Rect2(-_card_size.x * 0.5, -_card_size.y, _card_size.x, _card_size.y).grow(3.0 * s).has_point(lp):
			return {"zone": "card", "item": _card_item}
	var feet := keeper.feet_items()
	if not feet.is_empty() and _pile_rect.grow(4.0 * s).has_point(pos):
		return {"zone": "pile", "item": feet[0]}
	return {}


# =========================================================================== boucle
func _process(delta: float) -> void:
	var vs := get_viewport_rect().size
	if size != vs:
		size = vs
	if not _ready_to_draw():
		if _was_drawn:
			_was_drawn = false
			_bounds = Rect2()
			reset()
		return
	var idle := keeper.items.is_empty() and _flyers.is_empty() and _pills.is_empty() and _back.is_empty()
	if idle and not _was_drawn:
		return
	_t += delta
	var s := _sc()
	# inertie : la carte balance quand sa tete (ou la fenetre) accelere
	var hs := head_pos() + Vector2(get_window().position)
	if _prev_hs == Vector2.INF:
		_prev_hs = hs
	var v := (hs - _prev_hs) / maxf(delta, 0.001)
	var acc := ((v - _prev_v) / maxf(delta, 0.001)).limit_length(60000.0 * s)
	_prev_hs = hs
	_prev_v = v
	_tilt_v += -acc.x / s * 0.000045
	_tilt_v += (-70.0 * _tilt - 5.5 * _tilt_v) * delta
	_tilt = clampf(_tilt + _tilt_v * delta, -0.75, 0.75)
	for k in _pop.keys():
		_pop[k] = float(_pop[k]) + delta
		if _pop[k] > 1.0:
			_pop.erase(k)
	for f in _flyers:
		f["t"] += delta
	_flyers = _flyers.filter(func(f): return f["t"] < f["dur"])
	for p in _pills:
		p["life"] += delta
	_pills = _pills.filter(func(p): return p["life"] < p["max"])
	if not _back.is_empty():
		_back["t"] += delta
		if _back["t"] >= 0.32:
			_back = {}
	_strain = maxf(0.0, _strain - delta * 0.9)
	_bump = maxf(0.0, _bump - delta * 5.0)
	# survol
	var m := Vector2(DisplayServer.mouse_get_position() - get_window().position) if sim_mouse_pos == Vector2.INF else sim_mouse_pos
	var hit := hit_test(m) if Rect2(Vector2.ZERO, size).has_point(m) else {}
	var hz: String = hit.get("zone", "")
	if hz == "close" or hz == "badge":
		hz = "card"
	if hz != _hover:
		_hover = hz
		_hover_t = 0.0
	_hover_t += delta
	_hover_a = move_toward(_hover_a, 1.0 if _hover == "card" else 0.0, delta * 8.0)
	_close_a = move_toward(_close_a, 1.0 if _hover == "card" else 0.0, delta * 6.0)
	_was_drawn = true
	# les bulles de dialogue passent au-dessus de la carte
	var lift := 0.0
	if not _card_item.is_empty():
		lift = maxf(0.0, head_pos().y - _card_top.y - 4.0 * s)
	_lift = lerpf(_lift, lift, minf(1.0, delta * 8.0))
	_set_bubble_lift(_lift)
	queue_redraw()


# =========================================================================== dessin
func _draw() -> void:
	_card_item = {}
	_badge_c = Vector2.INF
	_close_c = Vector2.INF
	_pile_rect = Rect2()
	if not _ready_to_draw():
		_bounds = Rect2()
		return
	var s := _sc()
	var pet := stage.pet
	var head := head_pos()
	var center := stage.camera.unproject_position(pet.center_global())
	var roll := (head - center).angle() + PI * 0.5
	var feet_pt := stage.camera.unproject_position(pet.global_position + Vector3(pet.width * 0.5 + 0.2, pet.ground_level, 0.25))
	_pile_base = Vector2(clampf(feet_pt.x, 26.0 * s, size.x - 26.0 * s), minf(feet_pt.y, size.y - 6.0 * s))
	var fat := keeper.fatigue()
	var lvl := keeper.tired_level()
	var bmin := Vector2(INF, INF)
	var bmax := Vector2(-INF, -INF)
	var flying := {}
	for f in _flyers:
		flying[f["item"]["id"]] = true
	if not _back.is_empty():
		flying[_back["item"]["id"]] = true
	if not _drag_item.is_empty():
		flying[_drag_item["id"]] = true

	# ---------------------------------------------------------------- tas a ses pieds
	var feet := keeper.feet_items().filter(func(it): return not flying.has(it["id"]))
	if not feet.is_empty():
		var pr := _draw_pile(feet, s)
		_pile_rect = pr
		bmin = bmin.min(pr.position)
		bmax = bmax.max(pr.end)

	# ---------------------------------------------------------------- carte(s) sur la tete
	var head_list := keeper.head_items()
	var dip := _strain * 3.0 * s + fat * 2.0 * s
	_anchor = head + Vector2(0, 3.0 * s + dip)
	var wob := sin(_t * 1.6) * (0.025 + 0.06 * fat) + sin(_t * 2.7 + 1.3) * (0.012 + 0.035 * fat)
	if lvl >= 2:
		wob += sin(_t * 31.0) * 0.012
	wob += sin(_t * 13.0) * _strain * 0.06
	var ang := roll * 0.85 + _tilt + wob
	var top: Dictionary = {}
	for it in head_list:
		if not flying.has(it["id"]):
			top = it
			break
	if not top.is_empty() and fan_hidden:
		# les cartes sont dans l'eventail : seulement la geometrie (zone de survol)
		var hc := _card_px(top)
		var hxf := Transform2D(ang, Vector2.ONE, 0.0, _anchor)
		var zmin := Vector2(INF, INF)
		var zmax := Vector2(-INF, -INF)
		for c in [hxf * Vector2(-hc.x * 0.5, -hc.y), hxf * Vector2(hc.x * 0.5, -hc.y), hxf * Vector2(hc.x * 0.5, 0), hxf * Vector2(-hc.x * 0.5, 0)]:
			zmin = zmin.min(c - Vector2(8, 8) * s)
			zmax = zmax.max(c + Vector2(8, 6) * s)
		_head_zone = Rect2(zmin, zmax - zmin)
		_card_top = head + Vector2(0, -10.0 * s)
	elif not top.is_empty():
		# pile derriere (2 max)
		var behind := head_list.filter(func(it): return it != top and not flying.has(it["id"]))
		var nb := mini(2, behind.size())
		for k in range(nb, 0, -1):
			var it2: Dictionary = behind[k - 1]
			var side := 1.0 if k % 2 == 1 else -1.0
			var xf2 := Transform2D(ang + side * 0.13 * k, Vector2.ONE * (1.0 - 0.06 * k), 0.0, _anchor + Vector2(side * 6.0 * k * s, 0).rotated(ang))
			_draw_card_at(it2, xf2, 1.0, Color(0.9, 0.87, 0.92), false)
		# contact (petite ombre sur le haut de sa tete)
		var csz := _card_px(top)
		draw_set_transform(_anchor + Vector2(0, -1.0 * s), ang, Vector2(1.0, 0.28))
		draw_circle(Vector2.ZERO, csz.x * 0.42, Color(0.25, 0.1, 0.25, 0.10))
		draw_set_transform_matrix(Transform2D())
		# carte du dessus
		var pop_s := 1.0
		var pop_y := 0.0
		var alpha := 1.0
		if _pop.has(top["id"]):
			var a: float = _pop[top["id"]]
			var e := _ease_out_back(clampf(a / 0.5, 0.0, 1.0))
			pop_s = lerpf(0.35, 1.0, e)
			pop_y = -(1.0 - clampf(a / 0.35, 0.0, 1.0)) * 34.0 * s
			alpha = clampf(a * 6.0, 0.0, 1.0)
		var hov := 1.0 + 0.06 * _hover_a - 0.08 * _bump
		var xf := Transform2D(ang, Vector2(pop_s * hov, pop_s * (hov - 0.04 * _bump)), 0.0, _anchor + Vector2(0, pop_y))
		_draw_card_at(top, xf, alpha, Color.WHITE, _hover_a > 0.01)
		_card_xf = xf
		_card_size = csz
		_card_item = top
		_card_top = xf * Vector2(0, -csz.y)
		var corners := [xf * Vector2(-csz.x * 0.5, -csz.y), xf * Vector2(csz.x * 0.5, -csz.y), xf * Vector2(csz.x * 0.5, 0), xf * Vector2(-csz.x * 0.5, 0)]
		var zmin2 := Vector2(INF, INF)
		var zmax2 := Vector2(-INF, -INF)
		for c in corners:
			bmin = bmin.min(c - Vector2(10, 10) * s)
			bmax = bmax.max(c + Vector2(10, 12) * s)
			zmin2 = zmin2.min(c - Vector2(8, 8) * s)
			zmax2 = zmax2.max(c + Vector2(8, 6) * s)
		_head_zone = Rect2(zmin2, zmax2 - zmin2)
		# badge "+N"
		if head_list.size() > 1:
			_badge_c = xf * Vector2(-csz.x * 0.5 + 3.0 * s, -csz.y + 3.0 * s)
			_draw_badge(_badge_c, "+%d" % (head_list.size() - 1), UITheme.ACCENT, s, alpha)
		# petite croix (survol)
		if _close_a > 0.01:
			_close_c = xf * Vector2(csz.x * 0.5 - 2.0 * s, -csz.y + 2.0 * s)
			_draw_close(_close_c, s, _close_a * alpha)
		# traits d'effort
		if lvl >= 1:
			_draw_effort(_anchor, csz, ang, s, lvl)
	else:
		_card_top = head + Vector2(0, -10.0 * s)
		_head_zone = Rect2()

	# ---------------------------------------------------------------- animations
	for f in _flyers:
		var r := _draw_flyer(f, s)
		if r.size != Vector2.ZERO:
			bmin = bmin.min(r.position)
			bmax = bmax.max(r.end)
	if not _back.is_empty():
		var bt := _ease_out_back(clampf(_back["t"] / 0.32, 0.0, 1.0))
		var it3: Dictionary = _back["item"]
		var c3 := _card_px(it3)
		var p0: Vector2 = _back["from"] + Vector2(0, c3.y * 0.5)
		var p := p0.lerp(_anchor, bt)
		_draw_card_at(it3, Transform2D(ang * bt, Vector2.ONE, 0.0, p), 1.0, Color.WHITE, false)
	if not _drag_item.is_empty():
		var c4 := _card_px(_drag_item)
		var sc4 := 1.08 if _drag_item["place"] == "head" else 0.8
		var dxf := Transform2D(clampf(_drag_vel.x * 0.0005, -0.35, 0.35), Vector2.ONE * sc4, 0.0, _drag_pos + Vector2(0, c4.y * 0.5 * sc4))
		_draw_card_at(_drag_item, dxf, 0.96, Color.WHITE, true)
		var dr := Rect2(_drag_pos - c4 * 0.6, c4 * 1.2).intersection(Rect2(Vector2.ZERO, size))
		if dr.size != Vector2.ZERO:
			bmin = bmin.min(dr.position)
			bmax = bmax.max(dr.end)
		var over_pile := pile_drop_rect().has_point(_drag_pos)
		if _drag_item["place"] == "head" and over_pile:
			var pr2 := pile_drop_rect()
			draw_style_box(_box("drop", Color(UITheme.LAVENDER_SOFT, 0.7), 10.0 * s, Color(UITheme.LAVENDER, 0.9), 2.0 * s), pr2)

	# ---------------------------------------------------------------- bulles d'aide / retours
	var hint := ""
	if not _drag_item.is_empty():
		if _drag_item["place"] == "head" and pile_drop_rect().has_point(_drag_pos):
			hint = "Poser à mes pieds"
		elif _drag_item["place"] == "feet":
			hint = "Remets-le sur ma tête"
		else:
			hint = "Lâche-le dehors : je le copie !"
	elif _hover == "card" and _hover_t > 0.7 and _pills.is_empty():
		hint = "Clic : copier · Glisser : déposer"
	elif _hover == "pile" and _hover_t > 0.5 and _pills.is_empty():
		hint = "Clic : je te le redonne"
	var pill_y := _card_top.y - 8.0 * s
	if hint != "":
		var hr := _draw_pill(Vector2(head.x, pill_y), hint, Color(1, 1, 1, 0.96), UITheme.BODY, s, 1.0, false)
		bmin = bmin.min(hr.position)
		bmax = bmax.max(hr.end)
		pill_y -= 25.0 * s
	for p in _pills:
		var t: float = p["life"] / p["max"]
		var a2 := clampf(minf(t * 8.0, (1.0 - t) * 4.0), 0.0, 1.0)
		var rise := _ease_out(clampf(t * 2.0, 0.0, 1.0)) * 14.0 * s
		var pr := _draw_pill(Vector2(head.x, pill_y - rise), p["text"], p["color"], Color.WHITE, s, a2, true)
		bmin = bmin.min(pr.position)
		bmax = bmax.max(pr.end)
	_bounds = Rect2(bmin, bmax - bmin).intersection(Rect2(Vector2.ZERO, size)) if bmin.x < INF else Rect2()


func _item_pos(it: Dictionary) -> Vector2:
	if it.get("place", "") == "feet":
		return _pile_base
	return _anchor


# --------------------------------------------------------------------------- cartes
## Taille (px) de la carte d'un objet a l'echelle 1 de la carte.
func _card_px(it: Dictionary) -> Vector2:
	var s := _sc()
	match it["kind"]:
		"image":
			var tex: Texture2D = it["thumb"]
			var ts := tex.get_size()
			var k := CARD_IMG / maxf(ts.x, ts.y)
			var iw := maxf(ts.x * k, 26.0)
			var ih := maxf(ts.y * k, 26.0)
			return (Vector2(iw, ih) + Vector2.ONE * BORDER * 2.0) * s
		"file":
			return FILE_SIZE * s
	return NOTE_SIZE * s


## Dessine la carte avec l'origine au milieu du bas, transformee par xf.
func _draw_card_at(it: Dictionary, xf: Transform2D, alpha: float, tint: Color, glow: bool) -> void:
	var s := _sc()
	var csz := _card_px(it)
	draw_set_transform_matrix(xf)
	var r := Rect2(-csz.x * 0.5, -csz.y, csz.x, csz.y)
	var rad := 7.0 * s
	if glow:
		draw_style_box(_box("glow", Color(0, 0, 0, 0), rad + 3.0 * s, Color(UITheme.ACCENT, 0.55 * _hover_a * alpha), 2.0 * s), r.grow(3.0 * s))
	match it["kind"]:
		"image":
			var sb := _box("img", Color(Color.WHITE * tint, alpha), rad, Color(UITheme.LINE_2, alpha), maxf(1.0, s))
			sb.shadow_color = Color(0.3, 0.12, 0.3, 0.22 * alpha)
			sb.shadow_size = int(6 * s)
			sb.shadow_offset = Vector2(0, 2.0 * s)
			draw_style_box(sb, r)
			var inner := r.grow(-BORDER * s)
			draw_texture_rect(it["thumb"], inner, false, Color(tint, alpha))
			# reflet doux
			draw_colored_polygon(PackedVector2Array([inner.position + Vector2(inner.size.x * 0.55, 0), inner.position + Vector2(inner.size.x * 0.8, 0),
				inner.position + Vector2(inner.size.x * 0.45, inner.size.y * 0.55), inner.position + Vector2(inner.size.x * 0.2, inner.size.y * 0.55)]),
				Color(1, 1, 1, 0.10 * alpha))
		"file":
			var sb2 := _box("file", Color(UITheme.LAVENDER_SOFT * tint, alpha), rad, Color(UITheme.LAVENDER.lightened(0.45), alpha), maxf(1.0, s))
			sb2.shadow_color = Color(0.3, 0.12, 0.3, 0.2 * alpha)
			sb2.shadow_size = int(6 * s)
			sb2.shadow_offset = Vector2(0, 2.0 * s)
			draw_style_box(sb2, r)
			_draw_doc_icon(Vector2(0, r.position.y + 6.0 * s), s, alpha, int(it.get("count", 1)))
			var f := UITheme.font(600)
			var fs := int(round(9.5 * s))
			var title := _ellipsize(str(it["title"]), f, fs, csz.x - 10.0 * s)
			draw_string(f, Vector2(r.position.x + 5.0 * s, r.end.y - 8.0 * s), title, HORIZONTAL_ALIGNMENT_CENTER, csz.x - 10.0 * s,
				fs, Color(UITheme.INK, alpha))
		_:
			_draw_note(it, r, s, alpha, tint)
	draw_set_transform_matrix(Transform2D())


func _draw_note(it: Dictionary, r: Rect2, s: float, alpha: float, tint: Color) -> void:
	var rad := 5.0 * s
	var sb := _box("note", Color(NOTE_BG * tint, alpha), rad, Color(Color("f3e2a6"), alpha), maxf(1.0, s))
	sb.shadow_color = Color(0.35, 0.22, 0.1, 0.2 * alpha)
	sb.shadow_size = int(6 * s)
	sb.shadow_offset = Vector2(0, 2.0 * s)
	draw_style_box(sb, r)
	# lignes
	var y := r.position.y + 17.0 * s
	while y < r.end.y - 5.0 * s:
		draw_line(Vector2(r.position.x + 4.0 * s, y), Vector2(r.end.x - 4.0 * s, y), Color(NOTE_LINE, NOTE_LINE.a * alpha), maxf(1.0, 0.8 * s))
		y += 11.0 * s
	draw_line(Vector2(r.position.x + 9.0 * s, r.position.y + 3.0 * s), Vector2(r.position.x + 9.0 * s, r.end.y - 3.0 * s),
		Color(1.0, 0.55, 0.65, 0.28 * alpha), maxf(1.0, 0.8 * s))
	# coin replie
	var fold := 10.0 * s
	var br := r.end
	draw_colored_polygon(PackedVector2Array([br + Vector2(-fold, 0), br + Vector2(0, -fold), br]), Color(UITheme.BG_2.darkened(0.02), alpha))
	draw_colored_polygon(PackedVector2Array([br + Vector2(-fold, 0), br + Vector2(0, -fold), br + Vector2(-fold, -fold)]),
		Color(Color("f1dc93"), alpha))
	# texte : les premiers mots
	var f := UITheme.font(500)
	var fs := int(round(10.0 * s))
	var text := str(it["title"])
	var lines := _wrap(text, f, fs, r.size.x - 18.0 * s, 4)
	var ty := r.position.y + 15.0 * s
	for ln in lines:
		draw_string(f, Vector2(r.position.x + 12.0 * s, ty), ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(UITheme.INK, alpha))
		ty += 11.0 * s
	# ruban adhesif
	var tape_c := Vector2(r.position.x + r.size.x * 0.5, r.position.y + 1.0 * s)
	var tw := 24.0 * s
	var th := 8.0 * s
	var tp := PackedVector2Array([Vector2(-tw * 0.5, -th * 0.5), Vector2(tw * 0.5, -th * 0.5), Vector2(tw * 0.5, th * 0.5), Vector2(-tw * 0.5, th * 0.5)])
	var rot := Transform2D(-0.09, tape_c)
	for i in tp.size():
		tp[i] = rot * tp[i]
	draw_colored_polygon(tp, Color(TAPE, TAPE.a * alpha))


func _draw_doc_icon(top_c: Vector2, s: float, alpha: float, count: int) -> void:
	var w := 22.0 * s
	var h := 27.0 * s
	if count > 1:
		var r0 := Rect2(top_c + Vector2(-w * 0.5 + 5.0 * s, -2.0 * s), Vector2(w, h))
		draw_style_box(_box("doc2", Color(Color("dcd5ff"), alpha), 3.0 * s, Color(0, 0, 0, 0), 0.0), r0)
	var p := top_c + Vector2(-w * 0.5, 0)
	var fold := 7.0 * s
	draw_colored_polygon(PackedVector2Array([p, p + Vector2(w - fold, 0), p + Vector2(w, fold), p + Vector2(w, h), p + Vector2(0, h)]), Color(1, 1, 1, alpha))
	draw_colored_polygon(PackedVector2Array([p + Vector2(w - fold, 0), p + Vector2(w, fold), p + Vector2(w - fold, fold)]), Color(UITheme.LAVENDER.lightened(0.35), alpha))
	for i in 3:
		var yy := p.y + fold + 5.0 * s + i * 4.5 * s
		draw_line(Vector2(p.x + 4.0 * s, yy), Vector2(p.x + w - (4.0 + 4.0 * float(i == 2)) * s, yy), Color(UITheme.LAVENDER, 0.7 * alpha), maxf(1.0, 1.4 * s))


func _draw_pile(feet: Array, s: float) -> Rect2:
	var base := _pile_base
	var lift := 1.0 + (0.08 if _hover == "pile" else 0.0)
	# ombre au sol
	draw_set_transform(base + Vector2(0, -1.0 * s), 0.0, Vector2(1.0, 0.3))
	draw_circle(Vector2.ZERO, 20.0 * s, Color(0.2, 0.08, 0.2, 0.13))
	draw_set_transform_matrix(Transform2D())
	var n := mini(3, feet.size())
	var bmin := Vector2(INF, INF)
	var bmax := Vector2(-INF, -INF)
	for k in range(n - 1, -1, -1):
		var it: Dictionary = feet[k]
		var c := _card_px(it) * MINI * lift
		var rot: float = [-0.05, 0.16, -0.2][k]
		var ox: float = [0.0, 5.0, -5.0][k]
		var off := Vector2(ox * s, -k * 4.0 * s)
		var xf := Transform2D(rot, Vector2.ONE * MINI * lift, 0.0, base + off)
		_draw_card_at(it, xf, 1.0, Color.WHITE if k == 0 else Color(0.92, 0.9, 0.94), false)
		bmin = bmin.min(base + off - Vector2(c.x * 0.6, c.y * 1.1))
		bmax = bmax.max(base + off + Vector2(c.x * 0.6, 2.0 * s))
	if feet.size() > 1:
		var cpos := Vector2(bmax.x - 2.0 * s, bmin.y + 3.0 * s)
		_draw_badge(cpos, str(feet.size()), UITheme.LAVENDER, s * 0.85, 1.0)
		bmin = bmin.min(cpos - Vector2(9, 9) * s)
		bmax = bmax.max(cpos + Vector2(9, 9) * s)
	return Rect2(bmin, bmax - bmin)


func _draw_flyer(f: Dictionary, s: float) -> Rect2:
	var t: float = maxf(0.0, f["t"]) / f["dur"]
	var it: Dictionary = f["item"]
	var c := _card_px(it)
	match f["kind"]:
		"poof":
			var e := _ease_out(t)
			var sc: float = f["scale"] * (1.0 + 0.25 * e)
			var a := 1.0 - t
			var pos: Vector2 = f["from"]
			_draw_card_at(it, Transform2D(0.0, Vector2.ONE * sc, 0.0, pos), a * a, Color.WHITE, false)
			var center := pos + Vector2(0, -c.y * 0.5 * sc)
			for i in 7:
				var ang := TAU * i / 7.0 + 0.4
				var d: float = (14.0 + 22.0 * e) * s * float(f["scale"])
				var pr := (3.0 + 4.0 * (1.0 - t)) * s
				draw_circle(center + Vector2(cos(ang), sin(ang)) * d, pr, Color(1, 1, 1, 0.9 * a))
				draw_arc(center + Vector2(cos(ang), sin(ang)) * d, pr, 0, TAU, 12, Color(UITheme.LINE_2, a), maxf(1.0, s))
			return Rect2(center - c * sc - Vector2(30, 30) * s, c * sc * 2.0 + Vector2(60, 60) * s)
		_:
			var e2 := _ease_in_out(t)
			var from: Vector2 = f["from"]
			var to: Vector2 = f["to"]
			var mid := (from + to) * 0.5 + Vector2(0, -40.0 * s)
			var pos2 := from.lerp(mid, e2).lerp(mid.lerp(to, e2), e2)
			var sc2 := lerpf(1.0, MINI, e2) if f["kind"] == "down" else lerpf(MINI, 1.0, e2)
			var rot := sin(t * PI) * (0.6 if f["kind"] == "down" else -0.4)
			_draw_card_at(it, Transform2D(rot, Vector2.ONE * sc2, 0.0, pos2), 1.0, Color.WHITE, false)
			return Rect2(pos2 - Vector2(c.x * 0.6, c.y * 1.1) * sc2, Vector2(c.x * 1.2, c.y * 1.2) * sc2)


func _draw_effort(anchor: Vector2, csz: Vector2, ang: float, s: float, lvl: int) -> void:
	# petits traits "d'effort" en eventail de chaque cote de la carte
	var pulse := 0.5 + 0.5 * sin(_t * (6.0 if lvl >= 2 else 3.5))
	var a := (0.6 + 0.4 * pulse) if lvl >= 2 else 0.25 + 0.5 * pulse
	var col := Color(0.42, 0.52, 0.9, a)
	var w := maxf(1.3, 1.7 * s)
	for side in [-1.0, 1.0]:
		var c := anchor + Vector2(side * (csz.x * 0.5 + 3.0 * s), -csz.y * 0.45).rotated(ang)
		for i in 3:
			var da := (float(i) - 1.0) * 0.5
			var dir := Vector2(side, 0).rotated(ang + side * da)
			var r0 := (3.0 + 1.5 * pulse) * s
			var l := (4.5 if i == 1 else 3.5) * s * (1.0 + 0.25 * pulse)
			draw_line(c + dir * r0, c + dir * (r0 + l), col, w, true)


func _draw_badge(c: Vector2, text: String, col: Color, s: float, alpha: float) -> void:
	var f := UITheme.font(700)
	var fs := int(round(10.0 * s))
	var w := maxf(17.0 * s, f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 9.0 * s)
	var r := Rect2(c - Vector2(w * 0.5, 8.5 * s), Vector2(w, 17.0 * s))
	var sb := _box("badge", Color(col, alpha), 9.0 * s, Color(1, 1, 1, alpha), maxf(1.0, 1.5 * s))
	sb.shadow_color = Color(0.3, 0.1, 0.3, 0.2 * alpha)
	sb.shadow_size = int(3 * s)
	draw_style_box(sb, r)
	draw_string(f, Vector2(r.position.x, c.y + f.get_ascent(fs) * 0.5 - 1.0 * s), text, HORIZONTAL_ALIGNMENT_CENTER, w, fs, Color(1, 1, 1, alpha))


func _draw_close(c: Vector2, s: float, alpha: float) -> void:
	var r := 8.0 * s
	draw_circle(c + Vector2(0, 1.0 * s), r + 1.0 * s, Color(0.3, 0.1, 0.3, 0.18 * alpha))
	draw_circle(c, r, Color(1, 1, 1, alpha))
	draw_arc(c, r, 0, TAU, 20, Color(UITheme.LINE_2, alpha), maxf(1.0, s), true)
	var d := 3.2 * s
	var col := Color(UITheme.ACCENT_DARK, alpha)
	draw_line(c + Vector2(-d, -d), c + Vector2(d, d), col, maxf(1.5, 2.0 * s), true)
	draw_line(c + Vector2(-d, d), c + Vector2(d, -d), col, maxf(1.5, 2.0 * s), true)


## Petite etiquette arrondie centree en x sur `bottom_c` (bas de l'etiquette).
func _draw_pill(bottom_c: Vector2, text: String, bg: Color, fg: Color, s: float, alpha: float, check: bool) -> Rect2:
	var f := UITheme.font(600)
	var fs := int(round(11.0 * s))
	var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var icon := 12.0 * s if check and bg == UITheme.MINT else 0.0
	var w := tw + 16.0 * s + icon
	var h := 20.0 * s
	var x := clampf(bottom_c.x - w * 0.5, 3.0, size.x - w - 3.0)
	var y := maxf(3.0, bottom_c.y - h)
	var r := Rect2(x, y, w, h)
	var sb := _box("pill", Color(bg, bg.a * alpha), h * 0.5, Color(1, 1, 1, 0.9 * alpha) if bg.v < 0.99 else Color(UITheme.LINE_2, alpha), maxf(1.0, 1.2 * s))
	sb.shadow_color = Color(0.3, 0.1, 0.3, 0.16 * alpha)
	sb.shadow_size = int(4 * s)
	sb.shadow_offset = Vector2(0, 1.5 * s)
	draw_style_box(sb, r)
	var tx := x + 8.0 * s
	if icon > 0.0:
		var cc := Vector2(tx + 4.5 * s, y + h * 0.5)
		draw_polyline(PackedVector2Array([cc + Vector2(-3.5, 0) * s, cc + Vector2(-1, 2.6) * s, cc + Vector2(4, -3) * s]), Color(1, 1, 1, alpha), maxf(1.5, 2.0 * s), true)
		tx += icon
	draw_string(f, Vector2(tx, y + h * 0.5 + f.get_ascent(fs) * 0.5 - 1.5 * s), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(fg, alpha))
	return r.grow(5.0 * s)


# --------------------------------------------------------------------------- utilitaires
func _box(key: String, bg: Color, radius: float, border: Color, bw: float) -> StyleBoxFlat:
	var sb: StyleBoxFlat = _sb.get(key)
	if sb == null:
		sb = StyleBoxFlat.new()
		sb.anti_aliasing = true
		sb.corner_detail = 8
		_sb[key] = sb
	sb.bg_color = bg
	sb.set_corner_radius_all(int(round(radius)))
	sb.border_color = border
	sb.set_border_width_all(int(round(bw)))
	sb.shadow_size = 0
	sb.shadow_offset = Vector2.ZERO
	return sb


func _wrap(text: String, f: Font, fs: int, max_w: float, max_lines: int) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var words := text.split(" ", false)
	var i := 0
	while i < words.size():
		var w: String = words[i]
		var cand := w if cur == "" else cur + " " + w
		if f.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
			cur = cand
			i += 1
			continue
		if cur == "":
			# mot trop long : on le coupe
			var cut := w.length()
			while cut > 1 and f.get_string_size(w.substr(0, cut), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
				cut -= 1
			cur = w.substr(0, cut)
			words[i] = w.substr(cut)
		out.append(cur)
		cur = ""
		if out.size() >= max_lines:
			break
	if cur != "" and out.size() < max_lines:
		out.append(cur)
		cur = ""
	if (i < words.size() or cur != "") and out.size() > 0:
		out[out.size() - 1] = _ellipsize(out[out.size() - 1] + "…", f, fs, max_w)
	return out


func _ellipsize(text: String, f: Font, fs: int, max_w: float) -> String:
	if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return text
	var t := text.trim_suffix("…")
	while t.length() > 1 and f.get_string_size(t + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		t = t.substr(0, t.length() - 1)
	return t.strip_edges() + "…"


static func _ease_out_back(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3) + c1 * pow(t - 1.0, 2)


static func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - t, 3)


static func _ease_in_out(t: float) -> float:
	return 3.0 * t * t - 2.0 * t * t * t
