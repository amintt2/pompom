class_name HeldFan
extends Window
## "Main de cartes" : quand la souris survole ce que le compagnon porte sur la tete (copies du presse-papiers,
## enveloppe du courrier), les cartes s'ecartent en eventail au-dessus de lui comme une main de cartes.
##   survol   : la carte se souleve ; une image s'affiche en grand au-dessus de l'eventail
##   clic     : son action (recopier l'objet / lire le courrier)
##   glisser  : hors de l'eventail = la deposer (comme glisser la carte hors de la fenetre du compagnon)
##   clic droit : petit bouton "Retirer"
## La souris qui s'en va referme l'eventail apres un court delai (hysteresis : pas de clignotement).
##
## Petite fenetre a part : sans bordure, transparente, jamais active (ne vole pas le focus), transitoire de la
## fenetre du compagnon (donc toujours au-dessus d'elle, sans bouton dans la barre des taches). La fenetre du
## compagnon est trop petite pour l'eventail et l'apercu. La zone cliquable (et visible) est l'enveloppe convexe
## de ce qui est dessine : ailleurs, les clics la traversent. Echelle DPI comme les menus, MSAA 2D 4x sur cette
## fenetre seulement. Creee et pilotee par ClipboardKeeper (voir clipboard_keeper.gd).

signal card_activated(entry: Dictionary)  # clic gauche sur une carte (ou sur l'apercu)
signal card_removed(entry: Dictionary)  # bouton "Retirer" (clic droit)
signal card_dropped_out(entry: Dictionary)  # carte glissee hors de l'eventail
signal opened
signal closed

const CARD := Vector2(104, 136)  # carte (px logiques), origine au milieu du bas
const CONTENT_H := 82.0
const RADIUS := 14.0
const GAP := 2.0  # entre le haut de sa tete et le bas de l'eventail
const ARC_R := 560.0  # rayon de l'arc de la main
const LIFT := 22.0
const HOVER_SCALE := 1.1
const PUSH := 0.06  # radians : les voisines s'ecartent de la carte survolee
const OPEN_DELAY := 0.14
const CLOSE_DELAY := 0.4
const PREVIEW_DELAY := 0.08
const PREVIEW_MAX := Vector2(420, 300)
const FRAME_PAD := 8.0
const CAPTION_H := 44.0
const PAD := 28.0  # marge transparente (ombres)
const DRAG_PX := 6.0
const STAGGER := 0.035
const SPRING_K := 300.0
const SPRING_D := 23.0
const NOTE_BG := Color("fff6cc")
const NOTE_LINE := Color(0.45, 0.62, 0.95, 0.20)
const TAPE := Color(1.0, 0.6, 0.76, 0.72)

enum State { CLOSED, OPEN, CLOSING }

var keeper: ClipboardKeeper
var layer: HeldItemsLayer
var hud: GameHud
var main_win: Window

# tests
var sim_mouse := Vector2.INF  # position globale (ecran) simulee de la souris
var scale_override := 0.0
var usable_override := Rect2()
## Nombre d'objets a partir duquel l'eventail s'ouvre (une image seule suffit : son apercu).
var min_items := 2

var state := State.CLOSED
var _f := 1.0
var _arm := 0.0
var _leave := 0.0
var _need_leave := false  # apres une fermeture forcee : il faut d'abord quitter sa tete
var _cards := {}  # cle -> etat de la carte
var _order: Array[String] = []
var _hover := ""
var _hover_t := 0.0
var _press := ""
var _press_pos := Vector2.ZERO
var _drag := false
var _drag_pos := Vector2.ZERO
var _drag_off := Vector2.ZERO
var _drag_vel := Vector2.ZERO
var _ctx := ""
var _ctx_a := 0.0
var _ctx_r := Rect2()
var _pills: Array = []
var _poofs: Array = []  # {pos, t}
var _win_off := Vector2.ZERO  # coin de la fenetre - tete (px logiques ecran)
var _head := Vector2.ZERO  # haut de sa tete, dans la fenetre
var _fan_c := Vector2.ZERO  # milieu du bas de l'eventail
var _fb := Rect2()  # cartes au repos (survol compris)
var _prev_key := ""
var _prev_a := 0.0
var _prev_rect := Rect2()
var _prev_img := Rect2()
var _prev_mode := "above"
var _hd := {}  # id -> {size, tex, task, job, want}
var _region := PackedVector2Array()
var _hide_frames := 0
var _laid_n := 0  # nombre de cartes pour lequel la fenetre a ete dimensionnee
var _close_t := 0.0
var _t := 0.0
var _view: View
var _sb := {}


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	unfocusable = true
	unresizable = true
	transient = true  # fenetre possedee par celle du compagnon : au-dessus d'elle, pas dans la barre des taches
	wrap_controls = false
	title = "Pompom"
	theme = UITheme.theme()
	msaa_2d = Viewport.MSAA_4X  # (jamais au niveau du projet : casse la transparence de la fenetre principale)
	screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_view = View.new()
	_view.fan = self
	add_child(_view)


func _exit_tree() -> void:
	for id in _hd:
		var h: Dictionary = _hd[id]
		if int(h.get("task", -1)) >= 0:
			WorkerThreadPool.wait_for_task_completion(int(h["task"]))
			h["task"] = -1


# =========================================================================== API
func is_open() -> bool:
	return state == State.OPEN


func is_shown() -> bool:
	return state != State.CLOSED


## Ce que l'eventail montre, dans l'ordre (lettre d'abord, puis les copies de la plus recente a la plus ancienne).
## {key, kind: image|text|file|mail, item: Dictionary (objet du ClipboardKeeper), count (lettres)}
func entries() -> Array:
	var out := []
	if hud and hud.mail_count > 0:
		out.append({"key": "mail", "kind": "mail", "item": {}, "count": hud.mail_count})
	if keeper and keeper.enabled:
		for it in keeper.head_items():
			out.append({"key": "it%d" % int(it["id"]), "kind": str(it["kind"]), "item": it})
	return out


## Ouvre l'eventail tout de suite (sinon : survol de sa tete).
func open() -> void:
	if state == State.OPEN or main_win == null or layer == null:
		return
	var es := entries()
	if es.is_empty():
		return
	if state == State.CLOSING:
		state = State.OPEN
		_leave = 0.0
		_hide_frames = 1
		return
	_f = _scale()
	content_scale_factor = _f
	exclude_from_capture = main_win.exclude_from_capture  # comme le compagnon (reglage "visible en partage d'ecran")
	state = State.OPEN
	_leave = 0.0
	_arm = 0.0
	_hover = ""
	_hover_t = 0.0
	_press = ""
	_drag = false
	_ctx = ""
	_pills.clear()
	_poofs.clear()
	_prev_key = ""
	_prev_a = 0.0
	_cards.clear()
	_order.clear()
	_layout_window(es.size())
	_sync(es, true)
	_layout_targets()
	_prefetch()
	_region = PackedVector2Array()
	_update_region()
	visible = true
	_hide_frames = 2  # la pile reste visible le temps que la fenetre apparaisse
	opened.emit()


## Referme l'eventail (les cartes retournent sur sa tete). forced : il faudra quitter sa tete avant qu'il se rouvre.
func close(forced := false) -> void:
	_need_leave = _need_leave or forced
	if state != State.OPEN:
		return
	state = State.CLOSING
	_close_t = 0.0
	_press = ""
	_drag = false
	_ctx = ""
	_hover = ""
	_set_head_hidden(false)


## Ferme sans animation.
func close_now() -> void:
	if state == State.CLOSED:
		return
	state = State.CLOSING
	_finish_close()


## Petite etiquette (retour d'action) au-dessus de la carte de cet objet.
func pill(text: String, color: Color, it: Dictionary) -> void:
	var key := _key_of(it)
	if not _cards.has(key):
		key = _hover
	_pills = _pills.filter(func(p): return p["life"] < 0.25)
	_pills.append({"text": text, "color": color, "key": key, "life": 0.0, "max": 1.7, "at": _card_top_pos(key)})


## L'objet est oublie : sa carte part en fumee.
func poof(it: Dictionary) -> void:
	var key := _key_of(it)
	if _cards.has(key):
		_cards[key]["poof"] = true


## Le point (ecran) est-il dans l'eventail ouvert (cartes, apercu, sa tete) ?
func contains_global(p: Vector2) -> bool:
	return state != State.CLOSED and _zone_global().has_point(p)


## Cle de la carte sous ce point (ecran), "" sinon.
func key_at_global(p: Vector2) -> String:
	if state != State.OPEN:
		return ""
	return _card_at(_to_local(p))


## Centre (ecran) d'une carte a son etat actuel.
func card_center_global(key: String) -> Vector2:
	if not _cards.has(key):
		return Vector2.INF
	var c: Dictionary = _cards[key]
	return _to_global(_xf(c) * Vector2(0, -CARD.y * 0.5))


func card_keys() -> Array[String]:
	return _live_keys()


func hovered_key() -> String:
	return _hover


func preview_visible() -> bool:
	return _prev_key != "" and _prev_a > 0.5


## Cadre de l'apercu (ecran).
func preview_rect_global() -> Rect2:
	return Rect2(Vector2(position) + _prev_rect.position * _f, _prev_rect.size * _f)


## Zone qui ouvre l'eventail au survol (ecran) : la pile sur sa tete et l'enveloppe.
func trigger_rect_global() -> Rect2:
	return _trigger_global()


## Les cartes ont-elles fini de s'ouvrir ?
func settled() -> bool:
	if state != State.OPEN:
		return false
	for k in _live_keys():
		var c: Dictionary = _cards[k]
		if float(c["age"]) < 0.0 or (c["pos"] as Vector2).distance_to(c["tpos"]) > 1.5 or absf(float(c["scl"]) - float(c["tscl"])) > 0.01:
			return false
	return true


## Evenement souris dans la fenetre (positions en px logiques de la fenetre). Appele par la vue ; utilisable en test.
func handle_view_input(ev: InputEvent) -> void:
	if state != State.OPEN:
		return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		var p := mb.position
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _ctx != "":
					var key := _ctx
					var on_btn := _ctx_r.has_point(p)
					_ctx = ""
					if on_btn:
						_remove(key)
					return
				var k := _card_at(p)
				if k == "" and _prev_a > 0.3 and _prev_rect.has_point(p):
					k = _prev_key
				if k != "":
					_press = k
					_press_pos = p
					_drag = false
			elif _press != "":
				_release(p)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _press != "":
				return
			var k2 := _card_at(p)
			if k2 != "" and str(_cards[k2]["entry"]["kind"]) != "mail":
				_ctx = "" if _ctx == k2 else k2
				_ctx_a = 0.0
			else:
				_ctx = ""
	elif ev is InputEventMouseMotion and _press != "":
		var p2 := (ev as InputEventMouseMotion).position
		if not _drag and p2.distance_to(_press_pos) > DRAG_PX and _cards.has(_press) \
				and str(_cards[_press]["entry"]["kind"]) != "mail":
			_drag = true
			var c: Dictionary = _cards[_press]
			var on_card := _card_hit(c, p2, false)
			_drag_off = (c["pos"] as Vector2) - _press_pos if on_card else Vector2(0, CARD.y * 0.55)
			_drag_pos = p2
			_drag_vel = Vector2.ZERO
			_hover = _press
		if _drag:
			_drag_vel = _drag_vel.lerp((p2 - _drag_pos) * 60.0, 0.5)
			_drag_pos = p2


# =========================================================================== boucle
func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	_t += delta
	var es := entries()
	var can := _can_show() and not es.is_empty()
	var m := _mouse()
	var trig := _trigger_global()
	var in_trig := trig.has_area() and trig.has_point(m)
	if not in_trig:
		_need_leave = false
	match state:
		State.CLOSED:
			if can and _wants(es) and in_trig and not _need_leave:
				_arm += delta
				if _arm >= OPEN_DELAY:
					open()
			else:
				_arm = 0.0
			if state == State.CLOSED:
				if visible:
					visible = false
				return
		State.OPEN:
			if not can:
				close(true)
			else:
				var inside := in_trig or _drag or _press != "" or _ctx != "" or _zone_global().has_point(m)
				_leave = 0.0 if inside else _leave + delta
				if _leave >= CLOSE_DELAY:
					close()
		State.CLOSING:
			if can and _wants(es) and in_trig and not _need_leave:
				open()
	_poll_hd()
	if not can and state == State.CLOSING and not _can_show():
		_finish_close()  # porte, menu... : on disparait tout de suite
		return
	_sync(es, false)
	if state == State.OPEN and _live_keys().size() > _laid_n:
		_relayout(_live_keys().size())  # de nouvelles cartes arrivent : la fenetre s'elargit
	_follow()
	if state == State.OPEN and _press != "" and sim_mouse == Vector2.INF \
			and (DisplayServer.mouse_get_button_state() & MOUSE_BUTTON_MASK_LEFT) == 0:
		_release(_to_local(m))  # relachement perdu (hors de la fenetre)
	_update_hover(m, delta)
	_layout_targets()
	_update_preview(delta)
	_animate(delta)
	if _hide_frames > 0:
		_hide_frames -= 1
		if _hide_frames == 0 and state == State.OPEN:
			_set_head_hidden(true)
	_update_region()
	_view.queue_redraw()
	if state == State.CLOSING:
		_close_t += delta
		var done := _close_t > 0.6
		if not done:
			done = true
			for k in _cards:
				if float(_cards[k]["alpha"]) > 0.02:
					done = false
					break
		if done:
			_finish_close()


func _finish_close() -> void:
	state = State.CLOSED
	_set_head_hidden(false)
	_cards.clear()
	_order.clear()
	_pills.clear()
	_poofs.clear()
	_press = ""
	_drag = false
	_ctx = ""
	_hover = ""
	_prev_key = ""
	_prev_a = 0.0
	visible = false
	closed.emit()


func _set_head_hidden(on: bool) -> void:
	if layer:
		layer.fan_hidden = on
	if hud:
		hud.mail_hidden = on


func _can_show() -> bool:
	if main_win == null or layer == null or layer.stage == null or not main_win.visible:
		return false
	var pet := layer.stage.pet
	if pet == null or pet.root_node == null or pet.carried or pet.airborne:
		return false
	if keeper and keeper.is_dragging():
		return false
	if PetMenu.current() != null:
		return false
	return true


func _wants(es: Array) -> bool:
	if es.size() >= min_items:
		return true
	for e in es:
		if e["kind"] == "image":
			return true
	return false


func _mouse() -> Vector2:
	return sim_mouse if sim_mouse != Vector2.INF else Vector2(DisplayServer.mouse_get_position())


func _scale() -> float:
	if scale_override > 0.0:
		return scale_override
	return UITheme.dpi_scale(DisplayServer.window_get_current_screen(main_win.get_window_id()))


func _usable() -> Rect2:
	if usable_override.has_area():
		return usable_override
	return Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(main_win.get_window_id())))


func _pet_s() -> float:
	return layer.stage.ppu / 100.0 if layer and layer.stage else 1.0


func _to_local(g: Vector2) -> Vector2:
	return (g - Vector2(position)) / _f


func _to_global(l: Vector2) -> Vector2:
	return Vector2(position) + l * _f


func _main_to_local(p: Vector2) -> Vector2:
	return _to_local(p + Vector2(main_win.position))


func _key_of(it: Dictionary) -> String:
	if it.is_empty():
		return ""
	return "it%d" % int(it.get("id", -1))


func _trigger_global() -> Rect2:
	if main_win == null or layer == null:
		return Rect2()
	var r := Rect2()
	if keeper and keeper.enabled:
		r = layer.head_zone()
	if hud and hud.mail_count > 0:
		var mr := hud.mail_rect()
		if mr.has_area():
			r = mr if not r.has_area() else r.merge(mr)
	if not r.has_area():
		return Rect2()
	return Rect2(r.position + Vector2(main_win.position), r.size)


func _zone_global() -> Rect2:
	var r := _fb.grow(16.0)
	if _prev_key != "" and _prev_a > 0.05:
		r = r.merge(_prev_rect.grow(8.0))
	if _ctx != "":
		r = r.merge(_ctx_r.grow(6.0))
	var g := Rect2(Vector2(position) + r.position * _f, r.size * _f)
	var t := _trigger_global()
	return g.merge(t) if t.has_area() else g


# =========================================================================== mise en page
static func _step(n: int) -> float:
	return 0.0 if n <= 1 else minf(0.15, 0.62 / (n - 1))


## Largeur de l'eventail (cartes penchees aux bouts et ecartement du survol compris).
static func _span(n: int) -> float:
	var a_max := _step(n) * (n - 1) * 0.5 + (PUSH if n > 1 else 0.0)
	return (n - 1) * _step(n) * ARC_R + CARD.x * HOVER_SCALE + 2.0 * PUSH * ARC_R * float(n > 1) + 2.0 * CARD.y * sin(a_max)


## Redimensionne la fenetre sans que rien ne saute a l'ecran.
func _relayout(n: int) -> void:
	var old := Vector2(position)
	_layout_window(n)
	var d := (old - Vector2(position)) / _f
	for k in _cards:
		var c: Dictionary = _cards[k]
		c["pos"] = (c["pos"] as Vector2) + d
		c["tpos"] = (c["tpos"] as Vector2) + d
	for p in _pills:
		p["at"] = (p["at"] as Vector2) + d
	for pf in _poofs:
		pf["pos"] = (pf["pos"] as Vector2) + d
	_prev_rect.position += d
	_prev_img.position += d
	_drag_pos += d
	_press_pos += d
	_region = PackedVector2Array()


func _layout_window(n: int) -> void:
	_laid_n = n
	var u := _usable()
	var ul := Rect2(u.position / _f, u.size / _f)
	var head := (Vector2(main_win.position) + layer.head_pos()) / _f
	var fw := _span(n) + PAD * 2.0
	var drop := ARC_R * (1.0 - cos(_step(n) * (n - 1) * 0.5))
	var fh := CARD.y * HOVER_SCALE + LIFT + drop + PAD * 2.0
	var fan_r := Rect2(-fw * 0.5, -GAP - fh + PAD, fw, fh + 30.0)
	var pz := Vector2(PREVIEW_MAX.x + FRAME_PAD * 2.0, PREVIEW_MAX.y + FRAME_PAD * 2.0 + CAPTION_H) + Vector2(PAD, PAD) * 2.0
	var room_up := head.y + fan_r.position.y - ul.position.y
	var zone: Rect2
	if room_up >= pz.y * 0.7:
		var h := minf(pz.y, room_up + PAD)
		zone = Rect2(-pz.x * 0.5, fan_r.position.y - h + PAD, pz.x, h)
	else:
		# pas de place au-dessus (il est en haut de l'ecran) : l'apercu ira sur le cote le plus libre
		var right := ul.end.x - (head.x + fan_r.end.x)
		var left := head.x + fan_r.position.x - ul.position.x
		var w := minf(pz.x, maxf(right, left) + PAD)
		var x := fan_r.end.x - PAD if right >= left else fan_r.position.x - w + PAD
		zone = Rect2(x, fan_r.get_center().y - pz.y * 0.5, w, pz.y)
	var wr := fan_r.merge(zone)
	wr.size = wr.size.min(ul.size)
	_win_off = wr.position
	var p := (head + wr.position).clamp(ul.position, ul.end - wr.size)
	size = Vector2i((wr.size * _f).ceil())
	position = Vector2i((p * _f).round())
	_head = _to_local(Vector2(main_win.position) + layer.head_pos())


## La fenetre suit sa tete (il marche, la fenetre bouge...).
func _follow() -> void:
	var u := _usable()
	var ul := Rect2(u.position / _f, u.size / _f)
	var hs := Vector2(main_win.position) + layer.head_pos()
	var ws := Vector2(size) / _f
	var p := Vector2i(((hs / _f + _win_off).clamp(ul.position, ul.end - ws) * _f).round())
	if p != position:
		position = p
	_head = _to_local(hs)


func _live_keys() -> Array[String]:
	var out: Array[String] = []
	for k in _order:
		if _cards.has(k) and not bool(_cards[k]["dying"]):
			out.append(k)
	return out


func _layout_targets() -> void:
	var live := _live_keys()
	var n := live.size()
	var wl := Vector2(size) / _f
	var st := _step(n)
	var half := _span(n) * 0.5
	var min_bottom := PAD + CARD.y * HOVER_SCALE + LIFT
	_fan_c.x = clampf(_head.x, PAD + half, wl.x - PAD - half) if wl.x - 2.0 * PAD >= 2.0 * half else wl.x * 0.5
	_fan_c.y = clampf(_head.y - GAP, min_bottom, maxf(min_bottom, wl.y - PAD))
	var pivot := _fan_c + Vector2(0, ARC_R)
	var hi := live.find(_hover)
	var bmin := Vector2(INF, INF)
	var bmax := Vector2(-INF, -INF)
	for i in n:
		var c: Dictionary = _cards[live[i]]
		var a := (i - (n - 1) * 0.5) * st
		if hi >= 0 and i != hi:
			a += signf(i - hi) * PUSH * (1.0 if absi(i - hi) == 1 else 0.75)
		var dir := Vector2(sin(a), -cos(a))
		var p := pivot + dir * ARC_R
		var r := a * 0.9
		var k := 1.0
		if i == hi:
			p += dir * LIFT
			r *= 0.3
			k = HOVER_SCALE
		c["tpos"] = p
		c["trot"] = r
		c["tscl"] = k
		var xf := Transform2D(r, Vector2(k, k), 0.0, p)
		for q in [Vector2(-CARD.x * 0.5, -CARD.y), Vector2(CARD.x * 0.5, -CARD.y), Vector2(CARD.x * 0.5, 0), Vector2(-CARD.x * 0.5, 0)]:
			var w: Vector2 = xf * q
			bmin = bmin.min(w)
			bmax = bmax.max(w)
	if n > 0:
		# le haut tient compte d'une carte survolee (soulevee) quelle qu'elle soit
		bmin.y = minf(bmin.y, _fan_c.y - CARD.y * HOVER_SCALE - LIFT - 4.0)
		_fb = Rect2(bmin, bmax - bmin)


## Ajoute les cartes des nouveaux objets, marque celles des objets disparus.
func _sync(es: Array, opening: bool) -> void:
	var keys: Array[String] = []
	for e in es:
		keys.append(str(e["key"]))
	for k in _cards:
		var c: Dictionary = _cards[k]
		if not keys.has(k) and not bool(c["dying"]):
			c["dying"] = true
			c["die_t"] = 0.0
			if bool(c.get("poof", false)):
				_poofs.append({"pos": _xf(c) * Vector2(0, -CARD.y * 0.5), "t": 0.0})
			if _hover == k:
				_hover = ""
			if _ctx == k:
				_ctx = ""
	if state == State.CLOSING and not opening:
		_order = _order.filter(func(k): return _cards.has(k) and float(_cards[k]["die_t"]) < 0.3)
		return
	for i in es.size():
		var e: Dictionary = es[i]
		var k: String = e["key"]
		if _cards.has(k):
			var c2: Dictionary = _cards[k]
			c2["entry"] = e
			if bool(c2["dying"]) and not bool(c2.get("poof", false)) and not bool(c2.get("out", false)):
				c2["dying"] = false
				c2["alpha"] = 1.0
			continue
		var st := _start_of(e)
		_cards[k] = {"key": k, "entry": e, "pos": st["pos"], "vel": Vector2.ZERO, "rot": st["rot"], "rv": 0.0,
			"scl": st["scl"], "sv": 0.0, "alpha": 0.0, "lift": 0.0, "bump": 0.0,
			"age": -STAGGER * i if opening else 0.0, "dying": false, "die_t": 0.0, "tpos": st["pos"], "trot": 0.0, "tscl": 1.0}
	var dying: Array[String] = []
	for k in _cards:
		if bool(_cards[k]["dying"]) and float(_cards[k]["die_t"]) < 0.3:
			dying.append(k)
	for k in _cards.keys():
		if bool(_cards[k]["dying"]) and float(_cards[k]["die_t"]) >= 0.3:
			_cards.erase(k)
	_order = dying
	_order.append_array(keys)


## Ou la carte part (et revient) : la pile sur sa tete, ou l'enveloppe.
func _start_of(e: Dictionary) -> Dictionary:
	var s := _pet_s()
	if e["kind"] == "mail" and hud:
		var r := hud.mail_rect()
		var p := _main_to_local(Vector2(r.get_center().x, r.end.y - 4.0 * s))
		return {"pos": p, "rot": 0.0, "scl": clampf(30.0 * s / (CARD.x * 0.62 * _f), 0.25, 0.9)}
	var it: Dictionary = e["item"]
	var px := layer.card_px(it) if not it.is_empty() else Vector2(70, 60) * s
	return {"pos": _main_to_local(layer.head_anchor()), "rot": 0.0, "scl": clampf(px.x / (CARD.x * _f), 0.25, 1.0)}


func _xf(c: Dictionary) -> Transform2D:
	var k: float = float(c["scl"]) * (1.0 - 0.06 * float(c["bump"]))
	return Transform2D(float(c["rot"]), Vector2(k, k), 0.0, c["pos"])


func _card_hit(c: Dictionary, p: Vector2, hovered: bool) -> bool:
	var lp: Vector2 = _xf(c).affine_inverse() * p
	var r := Rect2(-CARD.x * 0.5, -CARD.y, CARD.x, CARD.y)
	if hovered:
		r.size.y += LIFT + 10.0  # la carte soulevee garde le survol jusqu'a sa place de depart
	return r.has_point(lp)


func _draw_keys() -> Array[String]:
	var out: Array[String] = []
	for k in _order:
		if _cards.has(k) and k != _hover and not (_drag and k == _press):
			out.append(k)
	if _hover != "" and _cards.has(_hover) and not (_drag and _hover == _press):
		out.append(_hover)
	if _drag and _cards.has(_press):
		out.append(_press)
	return out


func _card_at(p: Vector2) -> String:
	var ks := _draw_keys()
	for i in range(ks.size() - 1, -1, -1):
		var c: Dictionary = _cards[ks[i]]
		if bool(c["dying"]) or float(c["alpha"]) < 0.3:
			continue
		if _card_hit(c, p, ks[i] == _hover):
			return ks[i]
	return ""


func _card_top_pos(key: String) -> Vector2:
	if not _cards.has(key):
		return Vector2(_fan_c.x, _fb.position.y)
	var c: Dictionary = _cards[key]
	var tp: Vector2 = c["tpos"]
	var xf := Transform2D(float(c["trot"]), Vector2.ONE * float(c["tscl"]), 0.0, tp)
	return xf * Vector2(0, -CARD.y)


# =========================================================================== survol, actions
func _update_hover(m: Vector2, delta: float) -> void:
	var k := _hover
	if state == State.OPEN and not _drag:
		var lp := _to_local(m)
		if _prev_key != "" and _prev_a > 0.3 and _prev_rect.has_point(lp) and _cards.has(_prev_key):
			k = _prev_key  # sur l'apercu : on garde la carte
		else:
			k = _card_at(lp)
			if k == "" and _press != "":
				k = _press
	elif state != State.OPEN:
		k = ""
	if k != _hover:
		_hover = k
		_hover_t = 0.0
	_hover_t += delta


func _release(p: Vector2) -> void:
	var k := _press
	var was_drag := _drag
	_press = ""
	_drag = false
	if not _cards.has(k):
		return
	if not was_drag:
		_activate(k)
		return
	var g := _to_global(p)
	var home := Rect2(Vector2(position) + _fb.position * _f, _fb.size * _f).grow(10.0 * _f)
	var t := _trigger_global()
	if t.has_area():
		home = home.merge(t)
	if not home.has_point(g):
		var c: Dictionary = _cards[k]
		c["out"] = true
		c["pos"] = _drag_pos + _drag_off
		card_dropped_out.emit(c["entry"])


func _activate(k: String) -> void:
	var c: Dictionary = _cards[k]
	c["bump"] = 1.0
	card_activated.emit(c["entry"])


func _remove(k: String) -> void:
	if not _cards.has(k):
		return
	var c: Dictionary = _cards[k]
	c["poof"] = true
	card_removed.emit(c["entry"])


# =========================================================================== animation
func _animate(delta: float) -> void:
	var sub := maxi(1, ceili(delta * 120.0))
	var dt := delta / sub
	for k in _cards:
		var c: Dictionary = _cards[k]
		c["age"] = float(c["age"]) + delta
		c["bump"] = maxf(0.0, float(c["bump"]) - delta * 5.0)
		c["lift"] = move_toward(float(c["lift"]), 1.0 if (k == _hover and state == State.OPEN) else 0.0, delta * 7.0)
		if bool(c["dying"]):
			c["die_t"] = float(c["die_t"]) + delta
			var dt2 := float(c["die_t"]) / 0.26
			c["alpha"] = clampf(1.0 - dt2, 0.0, 1.0)
			if not bool(c.get("out", false)):
				c["scl"] = float(c["scl"]) * (1.0 + delta * (1.6 if bool(c.get("poof", false)) else -1.2))
				c["pos"] = (c["pos"] as Vector2) + Vector2(0, -60.0 * delta)
			continue
		if _drag and k == _press:
			var wl := Vector2(size) / _f
			var mg := Vector2(CARD.x * 0.62 + 12.0, 16.0)  # la carte (penchee, et son ombre) reste dans la fenetre
			var dp := (_drag_pos + _drag_off).clamp(Vector2(mg.x, CARD.y * 1.08 + mg.y), wl - mg)
			c["pos"] = (c["pos"] as Vector2).lerp(dp, minf(1.0, delta * 30.0))
			c["rot"] = lerpf(float(c["rot"]), clampf(_drag_vel.x * 0.0006, -0.35, 0.35), minf(1.0, delta * 14.0))
			c["scl"] = lerpf(float(c["scl"]), 1.06, minf(1.0, delta * 14.0))
			c["alpha"] = 1.0
			continue
		var tp: Vector2 = c["tpos"]
		var tr: float = c["trot"]
		var ts: float = c["tscl"]
		var home := state == State.CLOSING or float(c["age"]) < 0.0
		if home:
			var st := _start_of(c["entry"])
			tp = st["pos"]
			tr = 0.0
			ts = st["scl"]
		var p: Vector2 = c["pos"]
		var v: Vector2 = c["vel"]
		var r: float = c["rot"]
		var rv: float = c["rv"]
		var s: float = c["scl"]
		var sv: float = c["sv"]
		for _i in sub:
			v += (SPRING_K * (tp - p) - SPRING_D * v) * dt
			p += v * dt
			rv += (SPRING_K * (tr - r) - SPRING_D * rv) * dt
			r += rv * dt
			sv += (SPRING_K * (ts - s) - SPRING_D * sv) * dt
			s += sv * dt
		c["pos"] = p
		c["vel"] = v
		c["rot"] = r
		c["rv"] = rv
		c["scl"] = maxf(0.05, s)
		c["sv"] = sv
		if state == State.CLOSING:
			# elles se fondent dans la pile qui reapparait sur sa tete
			c["alpha"] = minf(float(c["alpha"]), clampf(p.distance_to(tp) / 46.0, 0.0, 1.0))
		else:
			c["alpha"] = minf(1.0, float(c["alpha"]) + delta * 12.0)
	for p2 in _pills:
		p2["life"] = float(p2["life"]) + delta
	_pills = _pills.filter(func(x): return x["life"] < x["max"])
	for pf in _poofs:
		pf["t"] = float(pf["t"]) + delta
	_poofs = _poofs.filter(func(x): return x["t"] < 0.45)
	_ctx_a = move_toward(_ctx_a, 1.0 if _ctx != "" else 0.0, delta * 9.0)
	if _ctx == "":
		_ctx_r = Rect2()


# =========================================================================== apercu des images
func _update_preview(delta: float) -> void:
	var want := ""
	if state == State.OPEN and not _drag and _ctx == "" and _hover != "" and _cards.has(_hover):
		if str(_cards[_hover]["entry"]["kind"]) == "image" and _hover_t >= PREVIEW_DELAY:
			want = _hover
	if want != "" and want != _prev_key:
		var snap := _prev_key == "" or _prev_a < 0.05
		_prev_key = want
		_prev_a = minf(_prev_a, 0.35)
		_place_preview(snap)
	if want == "":
		_prev_a = move_toward(_prev_a, 0.0, delta * 9.0)
		if _prev_a <= 0.0:
			_prev_key = ""
	else:
		_prev_a = move_toward(_prev_a, 1.0, delta * 6.5)
	if _prev_key != "" and _cards.has(_prev_key):
		_place_preview(false, delta)


## Taille et place de l'apercu : au-dessus de l'eventail si possible, sinon sur le cote le plus libre.
func _preview_geom(key: String) -> Dictionary:
	if not _cards.has(key):
		return {}
	var it: Dictionary = _cards[key]["entry"]["item"]
	var img: Image = it.get("image")
	if img == null:
		return {}
	var isz := Vector2(img.get_width(), img.get_height()) / _f
	var wl := Vector2(size) / _f
	var fb := _fb
	var spaces := {
		"above": Rect2(PAD, PAD, wl.x - PAD * 2.0, fb.position.y - 10.0 - PAD),
		"right": Rect2(fb.end.x + 10.0, PAD, wl.x - PAD - fb.end.x - 10.0, wl.y - PAD * 2.0),
		"left": Rect2(PAD, PAD, fb.position.x - 10.0 - PAD, wl.y - PAD * 2.0),
	}
	var max_up := maxf(2.0, 160.0 / maxf(isz.x, 1.0))
	var best := ""
	var best_k := -1.0
	var ks := {}
	for mode in spaces:
		var sp: Rect2 = spaces[mode]
		var k := minf(minf(PREVIEW_MAX.x / isz.x, PREVIEW_MAX.y / isz.y), max_up)
		k = minf(k, minf((sp.size.x - FRAME_PAD * 2.0) / isz.x, (sp.size.y - FRAME_PAD * 2.0 - CAPTION_H) / isz.y))
		ks[mode] = k
		if k > best_k:
			best_k = k
			best = mode
	if float(ks["above"]) >= best_k * 0.85:
		best = "above"
	var k2: float = ks[best]
	if k2 <= 0.02:
		return {}
	var img_sz := ((isz * k2) * _f).round() / _f
	img_sz = img_sz.max(Vector2.ONE * 8.0 / _f)
	var sp2: Rect2 = spaces[best]
	var sub_w := UITheme.font(500).get_string_size(_preview_sub(it), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 30.0
	var fw := maxf(img_sz.x + FRAME_PAD * 2.0, minf(maxf(236.0, sub_w), sp2.size.x))
	var frame_sz := Vector2(fw, img_sz.y + FRAME_PAD * 2.0 + CAPTION_H)
	var c: Dictionary = _cards[key]
	var cx: float = (c["tpos"] as Vector2).x
	var pos := Vector2.ZERO
	match best:
		"above":
			pos = Vector2(clampf(cx - frame_sz.x * 0.5, PAD, wl.x - PAD - frame_sz.x), sp2.end.y - frame_sz.y)
		"right":
			pos = Vector2(sp2.position.x, clampf(_fb.get_center().y - frame_sz.y * 0.5, PAD, wl.y - PAD - frame_sz.y))
		_:
			pos = Vector2(sp2.end.x - frame_sz.x, clampf(_fb.get_center().y - frame_sz.y * 0.5, PAD, wl.y - PAD - frame_sz.y))
	pos = (pos * _f).round() / _f
	var img_r := Rect2(pos + Vector2((frame_sz.x - img_sz.x) * 0.5, FRAME_PAD), img_sz)
	img_r.position = (img_r.position * _f).round() / _f
	return {"mode": best, "frame": Rect2(pos, frame_sz), "img": img_r, "px": Vector2i((img_sz * _f).round())}


func _place_preview(snap: bool, delta := 0.0) -> void:
	var g := _preview_geom(_prev_key)
	if g.is_empty():
		return
	_prev_mode = g["mode"]
	var fr: Rect2 = g["frame"]
	var ir: Rect2 = g["img"]
	if snap or not _prev_rect.has_area() or _prev_rect.size != fr.size:
		_prev_rect = fr
		_prev_img = ir
	else:
		var k := minf(1.0, delta * 16.0)
		var np := _prev_rect.position.lerp(fr.position, k)
		if np.distance_to(fr.position) < 0.5 / _f:
			np = fr.position
		_prev_img.position += np - _prev_rect.position
		_prev_rect.position = np
	var it: Dictionary = _cards[_prev_key]["entry"]["item"]
	_hd_tex(it, g["px"])


## Lance a l'avance la version nette des images (l'apercu est net des la premiere image).
func _prefetch() -> void:
	for k in _live_keys():
		if str(_cards[k]["entry"]["kind"]) == "image":
			var g := _preview_geom(k)
			if not g.is_empty():
				_hd_tex(_cards[k]["entry"]["item"], g["px"])


## Texture nette a la taille exacte de l'apercu (reduction Lanczos de l'image d'origine dans un fil secondaire) ;
## en attendant : la miniature.
func _hd_tex(it: Dictionary, px: Vector2i) -> Texture2D:
	var id := int(it.get("id", -1))
	var img: Image = it.get("image")
	var h: Dictionary = _hd.get(id, {})
	if not h.is_empty() and h["src"] != img:
		h = {}  # image remplacee (reduite par le budget memoire)
	if h.is_empty():
		h = {"size": Vector2i.ZERO, "tex": null, "task": -1, "job": {}, "want": px, "src": img}
		_hd[id] = h
	h["want"] = px
	if h["size"] != px and int(h["task"]) < 0 and img != null:
		var job := {"img": null, "size": px}
		var src := img
		h["job"] = job
		h["task"] = WorkerThreadPool.add_task(func():
			var im := src.duplicate() as Image
			if im.is_compressed():
				im.decompress()
			if im.get_format() != Image.FORMAT_RGBA8:
				im.convert(Image.FORMAT_RGBA8)
			im.resize(maxi(1, px.x), maxi(1, px.y), Image.INTERPOLATE_LANCZOS)
			im.generate_mipmaps()
			job["img"] = im, false, "pompom apercu")
	# menage : images qui ne sont plus portees
	if _hd.size() > 8:
		for k in _hd.keys():
			if k != id and int(_hd[k]["task"]) < 0:
				_hd.erase(k)
				break
	return h["tex"] if h["tex"] != null else it.get("thumb")


func _poll_hd() -> void:
	for id in _hd:
		var h: Dictionary = _hd[id]
		var task := int(h["task"])
		if task < 0 or not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		h["task"] = -1
		var job: Dictionary = h["job"]
		if job.get("img") != null:
			h["tex"] = ImageTexture.create_from_image(job["img"])
			h["size"] = job["size"]
		h["job"] = {}


func _preview_tex(it: Dictionary) -> Texture2D:
	var h: Dictionary = _hd.get(int(it.get("id", -1)), {})
	if not h.is_empty() and h["tex"] != null and h["src"] == it.get("image"):
		return h["tex"]
	return it.get("thumb")


# =========================================================================== zone cliquable / visible
func _update_region() -> void:
	var pts := PackedVector2Array()
	var wl := Vector2(size) / _f
	if _drag:
		pts = PackedVector2Array([Vector2.ZERO, Vector2(wl.x, 0), wl, Vector2(0, wl.y)])
	else:
		var m := 20.0  # ombres
		for k in _cards:
			var c: Dictionary = _cards[k]
			if float(c["alpha"]) <= 0.005 and float(c["age"]) >= 0.0:
				continue
			var xf := _xf(c)
			for q in [Vector2(-CARD.x * 0.5 - m, -CARD.y - m), Vector2(CARD.x * 0.5 + m, -CARD.y - m),
					Vector2(CARD.x * 0.5 + m, m + 4.0), Vector2(-CARD.x * 0.5 - m, m + 4.0)]:
				pts.append(xf * q)
		if _prev_key != "" and _prev_a > 0.0:
			var pr := _prev_rect.grow(30.0)
			pts.append_array(PackedVector2Array([pr.position, Vector2(pr.end.x, pr.position.y), pr.end, Vector2(pr.position.x, pr.end.y)]))
		for p in _pills:
			var at: Vector2 = p["at"]
			pts.append_array(PackedVector2Array([at + Vector2(-140, -60), at + Vector2(140, -60), at + Vector2(140, 6), at + Vector2(-140, 6)]))
		for pf in _poofs:
			var c2: Vector2 = pf["pos"]
			pts.append_array(PackedVector2Array([c2 + Vector2(-80, -90), c2 + Vector2(80, -90), c2 + Vector2(80, 80), c2 + Vector2(-80, 80)]))
		if _ctx != "" and _ctx_r.has_area():
			var cr := _ctx_r.grow(12.0)
			pts.append_array(PackedVector2Array([cr.position, Vector2(cr.end.x, cr.position.y), cr.end, Vector2(cr.position.x, cr.end.y)]))
	var poly := PackedVector2Array()
	if pts.size() >= 3:
		var hull := Geometry2D.convex_hull(pts)
		for p in hull:
			poly.append((p * _f).clamp(Vector2.ZERO, Vector2(size)).round())
	if poly.size() < 3:
		poly = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)])
	if poly.size() == _region.size():
		var same := true
		for i in poly.size():
			if poly[i].distance_squared_to(_region[i]) > 2.0:
				same = false
				break
		if same:
			return
	_region = poly
	mouse_passthrough_polygon = poly


# =========================================================================== dessin
func _draw_view(ci: CanvasItem) -> void:
	if state == State.CLOSED:
		return
	# apercu (derriere les cartes : il est au-dessus de l'eventail, il ne les touche pas)
	if _prev_key != "" and _prev_a > 0.0 and _cards.has(_prev_key):
		_draw_preview(ci)
	for k in _draw_keys():
		_draw_card(ci, _cards[k])
	for pf in _poofs:
		_draw_poof(ci, pf)
	# aide au survol / pendant le glisser
	var hint := ""
	var hint_key := ""
	if _drag and _cards.has(_press):
		var g := _to_global(_drag_pos)
		var home := Rect2(Vector2(position) + _fb.position * _f, _fb.size * _f).grow(10.0 * _f)
		hint = "Glisse-la dehors pour la déposer" if home.has_point(g) else "Lâche : je la dépose !"
		hint_key = _press
	elif state == State.OPEN and _hover != "" and _cards.has(_hover) and _ctx == "" and _pills.is_empty() and _hover_t > 0.45:
		var kind := str(_cards[_hover]["entry"]["kind"])
		if kind == "mail":
			hint = "Clic : je te lis mon message" if int(_cards[_hover]["entry"].get("count", 1)) <= 1 else "Clic : je te lis mes messages"
		elif kind != "image" or _prev_a < 0.5:
			hint = "Clic : copier · Clic droit : retirer"
		hint_key = _hover
	if hint != "":
		var at := _card_top_pos(hint_key) if not _drag else (_cards[_press]["pos"] as Vector2) - Vector2(0, CARD.y * 1.06)
		_draw_pill(ci, at + Vector2(0, -8.0), hint, Color(1, 1, 1, 0.97), UITheme.BODY, 1.0, false)
	# retours d'action ("Copie !")
	for p in _pills:
		var t: float = float(p["life"]) / float(p["max"])
		var a := clampf(minf(t * 8.0, (1.0 - t) * 4.0), 0.0, 1.0)
		var rise := (1.0 - pow(1.0 - clampf(t * 2.0, 0.0, 1.0), 3.0)) * 14.0
		var at2: Vector2 = p["at"]
		_draw_pill(ci, at2 + Vector2(0, -10.0 - rise), p["text"], p["color"], Color.WHITE, a, true)
	# bouton "Retirer" (clic droit)
	if _ctx != "" and _cards.has(_ctx):
		var top := _xf(_cards[_ctx]) * Vector2(0, -CARD.y)
		var e := 1.0 - pow(1.0 - _ctx_a, 3.0)
		_ctx_r = _draw_ctx(ci, top + Vector2(0, -6.0 - 6.0 * e), e)


func _draw_card(ci: CanvasItem, c: Dictionary) -> void:
	var a: float = c["alpha"]
	if a <= 0.005:
		return
	var e: Dictionary = c["entry"]
	var lift: float = c["lift"]
	ci.draw_set_transform_matrix(_xf(c))
	var r := Rect2(-CARD.x * 0.5, -CARD.y, CARD.x, CARD.y)
	var sb := _box("card", Color(1, 1, 1, a), RADIUS, Color(UITheme.LINE_2.lerp(UITheme.ACCENT, lift * 0.75), a), 1)
	sb.shadow_color = Color(0.32, 0.1, 0.3, (0.14 + 0.10 * lift) * a)
	sb.shadow_size = int(round(7.0 + 9.0 * lift))
	sb.shadow_offset = Vector2(0, 3.0 + 4.0 * lift)
	ci.draw_style_box(sb, r)
	if lift > 0.01:
		ci.draw_style_box(_box("glow", Color(0, 0, 0, 0), RADIUS + 3.0, Color(UITheme.ACCENT, 0.45 * lift * a), 2), r.grow(3.0))
	var cr := Rect2(r.position + Vector2(6, 6), Vector2(CARD.x - 12.0, CONTENT_H))
	var it: Dictionary = e["item"]
	match str(e["kind"]):
		"image":
			_draw_image_content(ci, it, cr, a)
		"text":
			_draw_text_content(ci, it, cr, a)
		"file":
			_draw_file_content(ci, it, cr, a)
		"mail":
			_draw_mail_content(ci, int(e.get("count", 1)), cr, a)
	_draw_badge(ci, Vector2(r.position.x + 7.0, cr.end.y + 7.0), e, a)
	var f := UITheme.font(500)
	var cap := _ellipsize(_caption(e), f, 11, CARD.x - 16.0)
	ci.draw_string(f, Vector2(r.position.x + 8.0, r.end.y - 9.0), cap, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(UITheme.MUTED, a))
	ci.draw_set_transform_matrix(Transform2D())


func _caption(e: Dictionary) -> String:
	var it: Dictionary = e["item"]
	match str(e["kind"]):
		"image":
			var files: PackedStringArray = it.get("files", PackedStringArray())
			if not files.is_empty():
				return files[0].get_file()
			var img: Image = it.get("image")
			return "%d × %d" % [img.get_width(), img.get_height()] if img else ""
		"text":
			var n := str(it.get("text", "")).split(" ", false).size()
			return "%d mot%s" % [n, "s" if n > 1 else ""] if n > 1 else "%d caractères" % str(it.get("text", "")).length()
		"file":
			return str(it.get("title", ""))
		"mail":
			var m := int(e.get("count", 1))
			return "%d message%s" % [m, "s" if m > 1 else ""]
	return ""


func _draw_image_content(ci: CanvasItem, it: Dictionary, r: Rect2, a: float) -> void:
	var tex: Texture2D = it.get("thumb")
	if tex == null:
		return
	var ts := tex.get_size()
	var ta := ts.x / maxf(ts.y, 1.0)
	var ra := r.size.x / r.size.y
	var src := Rect2(0, 0, 1, 1)
	if ta > ra:
		src.size.x = ra / ta
		src.position.x = (1.0 - src.size.x) * 0.5
	else:
		src.size.y = ta / ra
		src.position.y = (1.0 - src.size.y) * 0.5
	ci.draw_style_box(_box("imgbg", Color(UITheme.SKY_SOFT, a), 9.0, Color(0, 0, 0, 0), 0), r)
	_draw_rounded_tex(ci, tex, r, 9.0, src, Color(1, 1, 1, a))
	ci.draw_style_box(_box("imgline", Color(0, 0, 0, 0), 9.0, Color(0.2, 0.1, 0.25, 0.08 * a), 1), r)


func _draw_rounded_tex(ci: CanvasItem, tex: Texture2D, r: Rect2, rad: float, src: Rect2, col: Color) -> void:
	var pts := UIKit.rounded_poly(r, rad, 6)
	var uvs := PackedVector2Array()
	for p in pts:
		uvs.append(src.position + (p - r.position) / r.size * src.size)
	ci.draw_polygon(pts, PackedColorArray([col]), uvs, tex)


func _draw_text_content(ci: CanvasItem, it: Dictionary, r: Rect2, a: float) -> void:
	ci.draw_style_box(_box("note", Color(NOTE_BG, a), 9.0, Color(Color("f3e2a6"), a), 1), r)
	var y := r.position.y + 21.0
	while y < r.end.y - 4.0:
		ci.draw_line(Vector2(r.position.x + 5.0, y), Vector2(r.end.x - 5.0, y), Color(NOTE_LINE, NOTE_LINE.a * a), 1.0)
		y += 13.0
	ci.draw_line(Vector2(r.position.x + 11.0, r.position.y + 4.0), Vector2(r.position.x + 11.0, r.end.y - 4.0), Color(1.0, 0.55, 0.65, 0.28 * a), 1.0)
	var f := UITheme.font(500)
	var lines := _wrap(str(it.get("title", "")), f, 11, r.size.x - 20.0, 5)
	var ty := r.position.y + 18.0
	for ln in lines:
		ci.draw_string(f, Vector2(r.position.x + 15.0, ty), ln, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(UITheme.INK, a))
		ty += 13.0
	# ruban adhesif
	var tc := Vector2(r.get_center().x, r.position.y + 1.0)
	var tp := PackedVector2Array()
	for q in [Vector2(-13, -4.5), Vector2(13, -4.5), Vector2(13, 4.5), Vector2(-13, 4.5)]:
		tp.append(Transform2D(-0.08, tc) * q)
	ci.draw_colored_polygon(tp, Color(TAPE, TAPE.a * a))


func _draw_file_content(ci: CanvasItem, it: Dictionary, r: Rect2, a: float) -> void:
	ci.draw_style_box(_box("filebg", Color(UITheme.LAVENDER_SOFT, a), 9.0, Color(0, 0, 0, 0), 0), r)
	var count := int(it.get("count", 1))
	var w := 34.0
	var h := 42.0
	var top := Vector2(r.get_center().x - w * 0.5, r.position.y + 12.0)
	if count > 1:
		ci.draw_style_box(_box("doc2", Color(Color("dcd5ff"), a), 4.0, Color(0, 0, 0, 0), 0), Rect2(top + Vector2(7, -5), Vector2(w, h)))
	var fold := 10.0
	var p := top
	var body := PackedVector2Array([p, p + Vector2(w - fold, 0), p + Vector2(w, fold), p + Vector2(w, h), p + Vector2(0, h)])
	ci.draw_colored_polygon(body, Color(1, 1, 1, a))
	body.append(p)
	ci.draw_polyline(body, Color(UITheme.LAVENDER.lightened(0.35), a), 1.2, true)
	ci.draw_colored_polygon(PackedVector2Array([p + Vector2(w - fold, 0), p + Vector2(w, fold), p + Vector2(w - fold, fold)]), Color(UITheme.LAVENDER.lightened(0.3), a))
	for i in 3:
		var yy := p.y + fold + 6.0 + i * 6.0
		ci.draw_line(Vector2(p.x + 6.0, yy), Vector2(p.x + w - (6.0 + 6.0 * float(i == 2)), yy), Color(UITheme.LAVENDER, 0.65 * a), 2.0, true)
	# extension
	var files: PackedStringArray = it.get("files", PackedStringArray())
	var ext := files[0].get_extension().to_upper() if not files.is_empty() else ""
	if count > 1:
		ext = "×%d" % count
	if ext != "":
		var f := UITheme.font(700)
		ext = ext.substr(0, 6)
		var tw := f.get_string_size(ext, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x + 10.0
		var er := Rect2(Vector2(r.get_center().x - tw * 0.5, top.y + h - 9.0), Vector2(tw, 15.0))
		ci.draw_style_box(_box("ext", Color(UITheme.LAVENDER, a), 7.5, Color(1, 1, 1, a), 1), er)
		ci.draw_string(f, Vector2(er.position.x, er.position.y + 11.0), ext, HORIZONTAL_ALIGNMENT_CENTER, er.size.x, 10, Color(1, 1, 1, a))


func _draw_mail_content(ci: CanvasItem, count: int, r: Rect2, a: float) -> void:
	ci.draw_style_box(_box("mailbg", Color(UITheme.ACCENT_SOFT, a), 9.0, Color(0, 0, 0, 0), 0), r)
	# petites etincelles
	for sp in [Vector2(0.16, 0.22), Vector2(0.86, 0.78), Vector2(0.12, 0.8)]:
		var c0: Vector2 = r.position + r.size * sp
		var k := 3.0 + 1.0 * sin(_t * 3.0 + sp.x * 9.0)
		ci.draw_colored_polygon(PackedVector2Array([c0 + Vector2(0, -k), c0 + Vector2(k * 0.3, -k * 0.3), c0 + Vector2(k, 0), c0 + Vector2(k * 0.3, k * 0.3),
			c0 + Vector2(0, k), c0 + Vector2(-k * 0.3, k * 0.3), c0 + Vector2(-k, 0), c0 + Vector2(-k * 0.3, -k * 0.3)]), Color(1, 1, 1, 0.9 * a))
	var ew := 58.0
	var eh := 38.0
	var bob := sin(_t * 2.6) * 1.5
	var er := Rect2(Vector2(r.get_center().x - ew * 0.5, r.get_center().y - eh * 0.5 + 2.0 + bob), Vector2(ew, eh))
	var sb := _box("env", Color(1, 1, 1, a), 5.0, Color(UITheme.ACCENT, a), 2)
	sb.shadow_color = Color(UITheme.ACCENT_DARK, 0.18 * a)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(0, 2)
	ci.draw_style_box(sb, er)
	var tip := er.position + Vector2(ew * 0.5, eh * 0.56)
	ci.draw_colored_polygon(PackedVector2Array([er.position + Vector2(2, 2), Vector2(er.end.x - 2, er.position.y + 2), tip]), Color(UITheme.ACCENT_SOFT.lerp(Color.WHITE, 0.3), a))
	ci.draw_polyline(PackedVector2Array([er.position + Vector2(1, 1), tip, Vector2(er.end.x - 1, er.position.y + 1)]), Color(UITheme.ACCENT, a), 2.0, true)
	ci.draw_line(Vector2(er.position.x + 2, er.end.y - 2), er.position + Vector2(ew * 0.38, eh * 0.5), Color(UITheme.ACCENT, 0.35 * a), 1.2, true)
	ci.draw_line(Vector2(er.end.x - 2, er.end.y - 2), er.position + Vector2(ew * 0.62, eh * 0.5), Color(UITheme.ACCENT, 0.35 * a), 1.2, true)
	_draw_heart(ci, tip + Vector2(0, 1), 5.5, Color(UITheme.ACCENT_DARK, a))
	# nombre de messages
	var bc := Vector2(er.end.x - 1.0, er.position.y + 1.0)
	ci.draw_circle(bc + Vector2(0, 1), 10.0, Color(UITheme.ACCENT_DARK, 0.25 * a), true, -1.0, true)
	ci.draw_circle(bc, 9.5, Color(UITheme.ACCENT_DARK, a), true, -1.0, true)
	ci.draw_arc(bc, 9.5, 0, TAU, 24, Color(1, 1, 1, a), 1.5, true)
	var f := UITheme.font(700)
	ci.draw_string(f, Vector2(bc.x - 10.0, bc.y + 4.5), str(count), HORIZONTAL_ALIGNMENT_CENTER, 20, 12, Color(1, 1, 1, a))


func _draw_heart(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 24:
		var t := TAU * i / 24.0
		var x := 16.0 * pow(sin(t), 3)
		var y := -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))
		pts.append(c + Vector2(x, y) * r / 16.0)
	ci.draw_colored_polygon(pts, col)


const KINDS := {
	"image": ["Image", "image"], "text": ["Texte", "text"], "file": ["Fichier", "file"], "mail": ["Lettre", "mail"],
}


func _kind_colors(kind: String) -> Array:
	match kind:
		"image":
			return [UITheme.SKY_SOFT, UITheme.SKY.darkened(0.18)]
		"text":
			return [UITheme.GOLD_SOFT, UITheme.GOLD_DARK]
		"file":
			return [UITheme.LAVENDER_SOFT, UITheme.LAVENDER.darkened(0.12)]
	return [UITheme.ACCENT_SOFT, UITheme.ACCENT_DARK]


func _draw_badge(ci: CanvasItem, at: Vector2, e: Dictionary, a: float) -> void:
	var kind := str(e["kind"])
	var label: String = KINDS.get(kind, ["?"])[0]
	if kind == "image" and bool(e["item"].get("shot", false)):
		label = "Capture"
	elif kind == "file" and int(e["item"].get("count", 1)) > 1:
		label = "Fichiers"
	var cols := _kind_colors(kind)
	var f := UITheme.font(650)
	var tw := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var r := Rect2(at, Vector2(tw + 27.0, 18.0))
	ci.draw_style_box(_box("badge_" + kind, Color(cols[0], a), 9.0, Color(0, 0, 0, 0), 0), r)
	_draw_kind_icon(ci, kind, Rect2(at + Vector2(5, 3), Vector2(12, 12)), Color(cols[1], a))
	ci.draw_string(f, Vector2(at.x + 20.0, at.y + 13.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(cols[1], a))


func _draw_kind_icon(ci: CanvasItem, kind: String, r: Rect2, col: Color) -> void:
	var w := 1.4
	match kind:
		"image":
			ci.draw_rect(Rect2(r.position + Vector2(0.5, 1.5), r.size - Vector2(1, 3)), col, false, w, true)
			ci.draw_polyline(PackedVector2Array([r.position + Vector2(1.5, 9.5), r.position + Vector2(5, 6), r.position + Vector2(7.5, 8.5),
				r.position + Vector2(9, 7), r.position + Vector2(11, 9)]), col, w, true)
			ci.draw_circle(r.position + Vector2(8.6, 4.3), 1.3, col, true, -1.0, true)
		"text":
			for i in 3:
				ci.draw_line(r.position + Vector2(1, 2.5 + i * 3.6), r.position + Vector2(11.0 - (3.5 if i == 2 else 0.0), 2.5 + i * 3.6), col, w, true)
		"file":
			var p := r.position + Vector2(2, 0.5)
			ci.draw_polyline(PackedVector2Array([p, p + Vector2(5, 0), p + Vector2(8, 3), p + Vector2(8, 11), p + Vector2(0, 11), p]), col, w, true)
			ci.draw_polyline(PackedVector2Array([p + Vector2(5, 0), p + Vector2(5, 3), p + Vector2(8, 3)]), col, w * 0.8, true)
		_:
			ci.draw_rect(Rect2(r.position + Vector2(0.5, 2), Vector2(11, 8.5)), col, false, w, true)
			ci.draw_polyline(PackedVector2Array([r.position + Vector2(0.8, 2.4), r.position + Vector2(6, 6.8), r.position + Vector2(11.2, 2.4)]), col, w, true)


func _draw_preview(ci: CanvasItem) -> void:
	var c: Dictionary = _cards[_prev_key]
	var it: Dictionary = c["entry"]["item"]
	var e := clampf(_prev_a, 0.0, 1.0)
	var k := lerpf(0.9, 1.0, _ease_out_back(e))
	var a := clampf(e * 1.8, 0.0, 1.0)
	var fr := _prev_rect
	var pivot := Vector2(fr.get_center().x, fr.end.y)
	if _prev_mode == "right":
		pivot = Vector2(fr.position.x, fr.get_center().y)
	elif _prev_mode == "left":
		pivot = Vector2(fr.end.x, fr.get_center().y)
	ci.draw_set_transform(pivot * (1.0 - k), 0.0, Vector2(k, k))
	var sb := _box("frame", Color(1, 1, 1, a), 18.0, Color(UITheme.LINE_2, a), 1)
	sb.shadow_color = Color(0.3, 0.08, 0.28, 0.20 * a)
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 6)
	ci.draw_style_box(sb, fr)
	var ir := _prev_img
	ci.draw_style_box(_box("pv_bg", Color(UITheme.BG_2, a), 11.0, Color(0, 0, 0, 0), 0), ir)
	var tex := _preview_tex(it)
	if tex:
		_draw_rounded_tex(ci, tex, ir, 11.0, Rect2(0, 0, 1, 1), Color(1, 1, 1, a))
	ci.draw_style_box(_box("pv_line", Color(0, 0, 0, 0), 11.0, Color(0.2, 0.1, 0.25, 0.08 * a), 1), ir)
	# legende
	var f := UITheme.font(650)
	var fr2 := UITheme.font(500)
	var x0 := fr.position.x + 14.0
	var y1 := ir.end.y + 21.0
	var y2 := ir.end.y + 37.0
	var files: PackedStringArray = it.get("files", PackedStringArray())
	var title := "Capture d'écran" if bool(it.get("shot", false)) else (files[0].get_file() if not files.is_empty() else "Image copiée")
	var img: Image = it.get("image")
	var dims := "%d × %d" % [img.get_width(), img.get_height()] if img else ""
	var dw := fr2.get_string_size(dims, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	_draw_kind_icon(ci, "image", Rect2(Vector2(x0, y1 - 11.0), Vector2(13, 13)), Color(UITheme.SKY.darkened(0.18), a))
	ci.draw_string(f, Vector2(x0 + 19.0, y1), _ellipsize(title, f, 14, fr.size.x - 50.0 - dw), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(UITheme.INK, a))
	ci.draw_string(fr2, Vector2(fr.end.x - 14.0 - dw, y1), dims, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(UITheme.MUTED, a))
	ci.draw_string(fr2, Vector2(x0, y2), _ellipsize(_preview_sub(it), fr2, 12, fr.size.x - 28.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(UITheme.MUTED, a))
	ci.draw_set_transform_matrix(Transform2D())


static func _preview_sub(it: Dictionary) -> String:
	return "%s · Clic : copier · Glisser dehors : déposer" % _ago(float(it.get("time", 0.0)))


static func _ago(t: float) -> String:
	if t <= 0.0:
		return "Gardée pour toi"
	var d := Time.get_unix_time_from_system() - t
	if d < 60.0:
		return "À l'instant"
	if d < 3600.0:
		return "Il y a %d min" % int(d / 60.0)
	if d < 86400.0:
		return "Il y a %d h" % int(d / 3600.0)
	return "Il y a %d j" % int(d / 86400.0)


func _draw_poof(ci: CanvasItem, pf: Dictionary) -> void:
	var t: float = float(pf["t"]) / 0.45
	var e := 1.0 - pow(1.0 - t, 3.0)
	var a := 1.0 - t
	var c: Vector2 = pf["pos"]
	for i in 8:
		var ang := TAU * i / 8.0 + 0.3
		var d := 22.0 + 34.0 * e
		var pr := 4.0 + 5.0 * (1.0 - t)
		var p := c + Vector2(cos(ang), sin(ang)) * d
		ci.draw_circle(p, pr, Color(1, 1, 1, 0.95 * a), true, -1.0, true)
		ci.draw_arc(p, pr, 0, TAU, 14, Color(UITheme.LINE_2, a), 1.0, true)


func _draw_ctx(ci: CanvasItem, bottom_c: Vector2, e: float) -> Rect2:
	var f := UITheme.font(650)
	var text := "Retirer"
	var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var w := tw + 40.0
	var h := 28.0
	var r := Rect2(bottom_c - Vector2(w * 0.5, h), Vector2(w, h))
	var k := lerpf(0.85, 1.0, e)
	r = Rect2(r.get_center() - r.size * k * 0.5, r.size * k)
	var hov := r.has_point(_to_local(_mouse()))
	var sb := _box("ctx", Color(UITheme.BAD_SOFT if hov else Color.WHITE, e), h * 0.5, Color(UITheme.BAD.lightened(0.5) if hov else UITheme.LINE_2, e), 1)
	sb.shadow_color = Color(0.3, 0.1, 0.3, 0.2 * e)
	sb.shadow_size = 8
	sb.shadow_offset = Vector2(0, 2)
	ci.draw_style_box(sb, r)
	var ic := r.position + Vector2(16, r.size.y * 0.5)
	ci.draw_circle(ic, 7.5, Color(UITheme.BAD, e), true, -1.0, true)
	var d := 2.6
	ci.draw_line(ic + Vector2(-d, -d), ic + Vector2(d, d), Color(1, 1, 1, e), 1.6, true)
	ci.draw_line(ic + Vector2(-d, d), ic + Vector2(d, -d), Color(1, 1, 1, e), 1.6, true)
	ci.draw_string(f, Vector2(r.position.x + 28.0, r.get_center().y + 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(UITheme.BAD, e))
	return r


## Petite etiquette arrondie, centree en x sur `bottom_c` (bas de l'etiquette).
func _draw_pill(ci: CanvasItem, bottom_c: Vector2, text: String, bg: Color, fg: Color, alpha: float, check: bool) -> Rect2:
	var f := UITheme.font(600)
	var fs := 12
	var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var icon := 14.0 if check and bg == UITheme.MINT else 0.0
	var w := tw + 20.0 + icon
	var h := 24.0
	var wl := Vector2(size) / _f
	var x := clampf(bottom_c.x - w * 0.5, 4.0, wl.x - w - 4.0)
	var y := maxf(4.0, bottom_c.y - h)
	var r := Rect2(x, y, w, h)
	var sb := _box("pill", Color(bg, bg.a * alpha), h * 0.5, Color(1, 1, 1, 0.9 * alpha) if bg.v < 0.99 else Color(UITheme.LINE_2, alpha), 1)
	sb.shadow_color = Color(0.3, 0.1, 0.3, 0.16 * alpha)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 2)
	ci.draw_style_box(sb, r)
	var tx := x + 10.0
	if icon > 0.0:
		var cc := Vector2(tx + 5.0, y + h * 0.5)
		ci.draw_polyline(PackedVector2Array([cc + Vector2(-4, 0), cc + Vector2(-1.2, 3), cc + Vector2(4.5, -3.4)]), Color(1, 1, 1, alpha), 2.2, true)
		tx += icon
	ci.draw_string(f, Vector2(tx, y + h * 0.5 + f.get_ascent(fs) * 0.5 - 1.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(fg, alpha))
	return r


# --------------------------------------------------------------------------- utilitaires
func _box(key: String, bg: Color, radius: float, border: Color, bw: int) -> StyleBoxFlat:
	var sb: StyleBoxFlat = _sb.get(key)
	if sb == null:
		sb = StyleBoxFlat.new()
		sb.anti_aliasing = true
		sb.corner_detail = 10
		_sb[key] = sb
	sb.bg_color = bg
	sb.set_corner_radius_all(int(round(radius)))
	sb.border_color = border
	sb.set_border_width_all(bw)
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


# =========================================================================== vue
class View extends Control:
	var fan: HeldFan

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	func _gui_input(ev: InputEvent) -> void:
		fan.handle_view_input(ev)
		accept_event()

	func _draw() -> void:
		fan._draw_view(self)
