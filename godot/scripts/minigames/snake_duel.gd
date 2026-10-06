class_name SnakeDuelGame
extends MiniGameBase
## Snake 1 contre 1 face a Pompom : meme plateau, deux pommes, 2 minutes.
## On perd en touchant un mur, son corps ou l'autre serpent ; tete contre tete = match nul ;
## au bout du temps, le plus long gagne. Logique a pas fixe (8 a 10 pas/s), rendu interpole a chaque image.
## Commandes : fleches, WASD ou ZQSD.

const W := 28
const H := 20
const ROUND_TIME := 120.0
const TICKS := [8.0, 9.0, 10.0]
const APPLES := 2
const USER_COL := Color("5fd3a4")
const USER_DARK := Color("2f9e78")
const POM_COL := Color("ff7eb0")
const POM_DARK := Color("e2508c")
const CELL_A := Color("fffaf6")
const CELL_B := Color("f8eef4")

var user := {}
var pom := {}
var apples: Array[Vector2i] = []
var phase := "idle"  # idle | countdown | play | over
var time_left := ROUND_TIME
var countdown := 0.0
var crash_cells: Array[Vector2i] = []
var ticks_done := 0
var ai_ms_max := 0.0  # pire temps de decision de l'IA (tests)
var ai_ms_total := 0.0
var autoplay_user := false  # tests : le joueur est aussi pilote par l'IA
var paused := false
var ai_threaded := true  # decision de Pompom calculee dans le WorkerThreadPool entre deux pas

var _acc := 0.0
var _tick_len := 0.11
var _t := 0.0
var _over_t := 0.0
var _parts := []  # {pos, vel, life, max, col, size}
var _floats := []  # {pos, text, life, col}
var _apple_born := {}  # Vector2i -> temps
var _queue: Array[Vector2i] = []
var _geo := {}
var _lead_said := 0.0
var _resume := 0.0
var _ai_task := -1
var _ai_box := {}
var _ai_rng := RandomNumberGenerator.new()


func game_id() -> String:
	return "snake"


func start_game(p_difficulty: int, p_user_starts: bool) -> void:
	shutdown()
	super(p_difficulty, p_user_starts)
	_ai_rng.seed = _rng.randi()
	_tick_len = 1.0 / float(TICKS[difficulty])
	var uy := H / 2 + 3
	var py := H / 2 - 4
	user = _snake([Vector2i(5, uy), Vector2i(4, uy), Vector2i(3, uy), Vector2i(2, uy)], Vector2i(1, 0))
	pom = _snake([Vector2i(W - 6, py), Vector2i(W - 5, py), Vector2i(W - 4, py), Vector2i(W - 3, py)], Vector2i(-1, 0))
	apples.clear()
	_apple_born.clear()
	_parts.clear()
	_floats.clear()
	crash_cells.clear()
	_queue.clear()
	ticks_done = 0
	ai_ms_max = 0.0
	ai_ms_total = 0.0
	time_left = ROUND_TIME
	_acc = 0.0
	_over_t = 0.0
	_lead_said = 0.0
	_resume = 0.0
	paused = false
	for i in APPLES:
		_spawn_apple()
	phase = "countdown"
	countdown = 3.0
	status_changed.emit("Flèches ou ZQSD pour diriger ton serpent", "user")
	queue_redraw()


func shutdown() -> void:
	if _ai_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_ai_task)
		_ai_task = -1


## Lance le calcul du prochain coup de Pompom (etat actuel copie) dans le WorkerThreadPool.
func _launch_ai() -> void:
	shutdown()
	if not ai_threaded or phase == "over":
		return
	var me := _copy(pom)
	var ot := _copy(user)
	var ap := apples.duplicate()
	var lvl := difficulty
	var rng := _ai_rng
	var box := {"dir": pom["dir"], "ms": 0.0}
	_ai_box = box
	_ai_task = WorkerThreadPool.add_task(func():
		var t0 := Time.get_ticks_usec()
		box["dir"] = SnakeAI.choose(me, ot, ap, W, H, lvl, rng)
		box["ms"] = (Time.get_ticks_usec() - t0) / 1000.0, false, "Pompom Snake")


static func _copy(s: Dictionary) -> Dictionary:
	return {"body": (s["body"] as Array).duplicate(), "dir": s["dir"], "grow": s["grow"]}


func _snake(body: Array[Vector2i], dir: Vector2i) -> Dictionary:
	return {"body": body, "prev": body.duplicate(), "dir": dir, "grow": 0, "alive": true, "score": 0}


func _spawn_apple() -> void:
	var free: Array[Vector2i] = []
	var occ := {}
	for s in [user, pom]:
		for p in s["body"]:
			occ[p] = true
	for a in apples:
		occ[a] = true
	var heads: Array = [user["body"][0], pom["body"][0]]
	for y in H:
		for x in W:
			var p := Vector2i(x, y)
			if occ.has(p):
				continue
			var near := false
			for hd: Vector2i in heads:
				if absi(hd.x - p.x) + absi(hd.y - p.y) < 3:
					near = true
			if not near:
				free.append(p)
	if free.is_empty():
		return
	var a := free[_rng.randi() % free.size()]
	apples.append(a)
	_apple_born[a] = _t


# ------------------------------------------------------------------ entree
func key_input(ev: InputEventKey) -> bool:
	var d := Vector2i.ZERO
	match ev.keycode:
		KEY_UP, KEY_W, KEY_Z:
			d = Vector2i(0, -1)
		KEY_DOWN, KEY_S:
			d = Vector2i(0, 1)
		KEY_LEFT, KEY_A, KEY_Q:
			d = Vector2i(-1, 0)
		KEY_RIGHT, KEY_D:
			d = Vector2i(1, 0)
	if d == Vector2i.ZERO:
		return false
	steer(d)
	return true


## Pause (fenetre sans focus) : reprise avec un petit "Pret ?".
func set_paused(p: bool) -> void:
	if p == paused or phase == "over":
		return
	paused = p
	if not p:
		_resume = 0.9
	queue_redraw()


## Change la direction du joueur (file de 3 virages max, pas de demi-tour).
func steer(d: Vector2i) -> void:
	if phase == "over" or user.is_empty():
		return
	var last: Vector2i = _queue.back() if not _queue.is_empty() else user["dir"]
	if d == last or d == -last or _queue.size() >= 3:
		return
	_queue.append(d)


# ------------------------------------------------------------------ boucle
func _process(delta: float) -> void:
	_t += delta
	if paused:
		queue_redraw()
		return
	if _resume > 0.0:
		_resume -= delta
		queue_redraw()
		return
	match phase:
		"countdown":
			countdown -= delta
			if countdown <= 0.0:
				phase = "play"
				_launch_ai()
				status_changed.emit("Mange les pommes, évite les murs !", "")
				pompom_event.emit("go")
		"play":
			time_left -= delta
			_acc += delta
			var guard := 0
			while _acc >= _tick_len and phase == "play" and guard < 4:
				_acc -= _tick_len
				guard += 1
				_tick()
			if phase == "play" and time_left <= 0.0:
				time_left = 0.0
				_time_up()
		"over":
			_over_t += delta
	for p in _parts:
		p["life"] += delta
		p["vel"] *= pow(0.12, delta)
		p["pos"] += p["vel"] * delta
	_parts = _parts.filter(func(p): return p["life"] < p["max"])
	for f in _floats:
		f["life"] += delta
	_floats = _floats.filter(func(f): return f["life"] < 1.0)
	queue_redraw()


## Avance d'un pas (public pour les tests).
func _tick() -> void:
	ticks_done += 1
	user["prev"] = (user["body"] as Array).duplicate()
	pom["prev"] = (pom["body"] as Array).duplicate()
	var pd: Vector2i
	var ms := 0.0
	if _ai_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_ai_task)
		_ai_task = -1
		pd = _ai_box["dir"]
		ms = _ai_box["ms"]
	else:
		var t0 := Time.get_ticks_usec()
		pd = SnakeAI.choose(pom, user, apples, W, H, difficulty, _ai_rng)
		ms = (Time.get_ticks_usec() - t0) / 1000.0
	ai_ms_max = maxf(ai_ms_max, ms)
	ai_ms_total += ms
	if autoplay_user:
		user["dir"] = SnakeAI.choose(user, pom, apples, W, H, 2, _rng)
	elif not _queue.is_empty():
		user["dir"] = _queue.pop_front()
	pom["dir"] = pd
	var snakes := [user, pom]
	var heads: Array[Vector2i] = [user["body"][0] + user["dir"], pom["body"][0] + pom["dir"]]
	var ate := [false, false]
	for i in 2:
		if apples.has(heads[i]):
			ate[i] = true
			snakes[i]["grow"] += 1
	for s in snakes:
		if s["grow"] > 0:
			s["grow"] -= 1
		else:
			(s["body"] as Array).pop_back()
	var dead := [false, false]
	for i in 2:
		var h := heads[i]
		if not SnakeAI.inside(h, W, H) or (snakes[i]["body"] as Array).has(h) or (snakes[1 - i]["body"] as Array).has(h):
			dead[i] = true
	if heads[0] == heads[1]:
		dead = [true, true]
	if heads[0] == pom["prev"][0] and heads[1] == user["prev"][0]:
		dead = [true, true]
	for i in 2:
		var s: Dictionary = snakes[i]
		if dead[i]:
			s["body"] = (s["prev"] as Array).duplicate()
			s["alive"] = false
			crash_cells.append(heads[i])
			_burst(_cell_px(s["body"][0]).lerp(_cell_px(heads[i]), 0.5), USER_COL if i == 0 else POM_COL, 16)
		else:
			(s["body"] as Array).push_front(heads[i])
	for i in 2:
		if ate[i] and not dead[i]:
			apples.erase(heads[i])
			_apple_born.erase(heads[i])
			snakes[i]["score"] += 1
			var col := USER_COL if i == 0 else POM_COL
			_burst(_cell_px(heads[i]), Color("ff5a6e"), 10)
			_floats.append({"pos": _cell_px(heads[i]), "text": "+1", "life": 0.0, "col": col.darkened(0.25)})
			pompom_event.emit("user_eat" if i == 0 else "eat")
	while apples.size() < APPLES:
		var n := apples.size()
		_spawn_apple()
		if apples.size() == n:
			break
	if not (dead[0] or dead[1]):
		_launch_ai()
	if dead[0] and dead[1]:
		_end("draw", "Boum ! Match nul !")
	elif dead[0]:
		_end("lose", "Aïe ! %s gagne la manche." % pet_name)
	elif dead[1]:
		_end("win", "%s s'est cogné : tu gagnes !" % pet_name)
	else:
		var lu: int = (user["body"] as Array).size()
		var lp: int = (pom["body"] as Array).size()
		if _t - _lead_said > 12.0 and lp >= lu + 3:
			_lead_said = _t
			pompom_event.emit("lead")
		elif _t - _lead_said > 12.0 and lu >= lp + 3:
			_lead_said = _t
			pompom_event.emit("behind")


func _time_up() -> void:
	var lu: int = (user["body"] as Array).size()
	var lp: int = (pom["body"] as Array).size()
	_acc = 0.0
	user["prev"] = (user["body"] as Array).duplicate()
	pom["prev"] = (pom["body"] as Array).duplicate()
	if lu > lp:
		_end("win", "Temps écoulé : ton serpent est le plus long !")
	elif lp > lu:
		_end("lose", "Temps écoulé : le serpent de %s est plus long." % pet_name)
	else:
		_end("draw", "Temps écoulé : égalité parfaite !")


func _end(r: String, text: String) -> void:
	phase = "over"
	_acc = _tick_len
	status_changed.emit(text, "user" if r == "win" else ("pompom" if r == "lose" else ""))
	_finish(r)


func _burst(at: Vector2, col: Color, n: int) -> void:
	var g := _geometry()
	var cs: float = g["cs"]
	for i in n:
		var a := _rng.randf() * TAU
		_parts.append({"pos": at, "vel": Vector2(cos(a), sin(a)) * _rng.randf_range(2.0, 7.0) * cs, "life": 0.0,
			"max": _rng.randf_range(0.35, 0.7), "col": col.lerp(Color.WHITE, _rng.randf() * 0.4), "size": _rng.randf_range(0.08, 0.16) * cs})


# ------------------------------------------------------------------ geometrie
func _geometry() -> Dictionary:
	if _geo.get("size", Vector2.ZERO) == size:
		return _geo
	var hud := 44.0
	var cs := floorf(minf((size.x - 8.0) / W, (size.y - hud - 8.0) / H) * 2.0) / 2.0
	cs = maxf(cs, 4.0)
	var bw := cs * W
	var bh := cs * H
	var ox := (size.x - bw) * 0.5
	var oy := hud + (size.y - hud - bh) * 0.5
	_geo = {"size": size, "cs": cs, "board": Rect2(ox, oy, bw, bh), "hud": hud}
	return _geo


func _cell_px(c) -> Vector2:
	var g := _geometry()
	var b: Rect2 = g["board"]
	return b.position + (Vector2(c) + Vector2(0.5, 0.5)) * float(g["cs"])


# ------------------------------------------------------------------ dessin
func _draw() -> void:
	var g := _geometry()
	var b: Rect2 = g["board"]
	var cs: float = g["cs"]
	_draw_hud(g)
	# plateau
	var frame := UITheme.box(Color("fdf3f7"), int(cs * 0.7), Color(1, 1, 1, 0.95), 2, 0)
	frame.shadow_color = Color(0.35, 0.15, 0.32, 0.13)
	frame.shadow_size = 12
	frame.shadow_offset = Vector2(0, 4)
	draw_style_box(frame, b.grow(cs * 0.35))
	draw_style_box(UITheme.box(CELL_A, int(cs * 0.45), Color.TRANSPARENT, 0, 0), b)
	for y in H:
		for x in W:
			if (x + y) % 2 == 1:
				var r := Rect2(b.position + Vector2(x, y) * cs, Vector2(cs, cs))
				if (x == 0 or x == W - 1) and (y == 0 or y == H - 1):
					continue  # coins arrondis du plateau
				draw_rect(r, CELL_B)
	if user.is_empty():
		return
	var k := clampf(_acc / _tick_len, 0.0, 1.0) if phase == "play" else 1.0
	# pommes
	for a in apples:
		var born: float = _apple_born.get(a, -10.0)
		var pop := clampf((_t - born) / 0.35, 0.0, 1.0)
		var s := MiniGameBase.ease_out_back(pop) * (1.0 + sin(_t * 4.0 + a.x) * 0.05)
		_apple(_cell_px(a), cs * 0.46 * s)
	# serpents (le perdant en dessous)
	var order := [pom, user] if user["alive"] else [user, pom]
	for s in order:
		var is_user: bool = is_same(s, user)
		_snake_draw(s, k, cs, USER_COL if is_user else POM_COL, USER_DARK if is_user else POM_DARK, is_user)
	# chocs
	for c in crash_cells:
		var p := _cell_px(c)
		var a := clampf(1.0 - _over_t * 0.6, 0.35, 1.0)
		_star_burst(p, cs * (0.45 + 0.08 * sin(_t * 10.0)), Color(UITheme.GOLD, a))
	for p in _parts:
		var t: float = p["life"] / p["max"]
		draw_circle(p["pos"], p["size"] * (1.0 - t * 0.5), Color(p["col"], 1.0 - t), true, -1.0, true)
	for f in _floats:
		var t: float = f["life"]
		text_center(f["pos"] + Vector2(0, -cs * (0.8 + t * 1.2)), f["text"], int(cs * 0.8), Color(f["col"], 1.0 - t * t))
	# compte a rebours
	if phase == "countdown":
		var n := ceili(countdown)
		var frac := countdown - floorf(countdown)
		var sc := 1.0 + (frac) * 0.5
		var col := Color(UITheme.INK, clampf(frac * 2.0 + 0.2, 0.0, 1.0))
		var c := b.get_center()
		draw_circle(c, cs * 2.6, Color(1, 1, 1, 0.82), true, -1.0, true)
		draw_arc(c, cs * 2.6, -PI * 0.5, -PI * 0.5 + TAU * frac, 48, UITheme.ACCENT, cs * 0.22, true)
		draw_set_transform(c, 0.0, Vector2.ONE * sc)
		text_center(Vector2.ZERO, str(n), int(cs * 2.4), col, 700)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if paused or _resume > 0.0:
		var c2 := b.get_center()
		var msg := "Pause" if paused else "Prêt ?"
		var st := UITheme.box(Color(1, 1, 1, 0.92), 99, Color(UITheme.ACCENT, 0.5), 2, 0)
		st.shadow_color = Color(0.35, 0.15, 0.32, 0.15)
		st.shadow_size = 12
		var fw := UITheme.font(700).get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, int(cs * 1.3)).x
		draw_style_box(st, Rect2(c2 - Vector2(fw * 0.5 + cs, cs * 1.2), Vector2(fw + cs * 2.0, cs * 2.4)))
		text_center(c2, msg, int(cs * 1.3), UITheme.ACCENT_DARK, 700)
		if paused:
			text_center(c2 + Vector2(0, cs * 2.1), "Clique sur la fenêtre pour reprendre", int(cs * 0.6), UITheme.MUTED, 650)
	elif phase == "play" and time_left > ROUND_TIME - 0.6:
		var t := (ROUND_TIME - time_left) / 0.6
		draw_set_transform(b.get_center(), 0.0, Vector2.ONE * (1.0 + t * 0.6))
		text_center(Vector2.ZERO, "Partez !", int(cs * 1.6), Color(UITheme.ACCENT_DARK, 1.0 - t), 700)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_hud(g: Dictionary) -> void:
	var b: Rect2 = g["board"]
	var y := 4.0
	var hh := 34.0
	var f := UITheme.font(650)
	var lu: int = (user["body"] as Array).size() if not user.is_empty() else 4
	var lp: int = (pom["body"] as Array).size() if not pom.is_empty() else 4
	# joueur (gauche)
	var lt := "Toi  ·  %d" % lu
	var lw := f.get_string_size(lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 50.0
	var lr := Rect2(b.position.x, y, lw, hh)
	draw_style_box(UITheme.pill(Color(USER_COL, 0.2)), lr)
	_mini_head(lr.position + Vector2(18, hh * 0.5), 9.0, USER_COL, USER_DARK, false)
	draw_string(f, lr.position + Vector2(34, hh * 0.5 + f.get_ascent(15) * 0.5 - 2), lt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, USER_DARK.darkened(0.25))
	# Pompom (droite)
	var rt := "%s  ·  %d" % [pet_name, lp]
	var rw := f.get_string_size(rt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 50.0
	var rr := Rect2(b.end.x - rw, y, rw, hh)
	draw_style_box(UITheme.pill(Color(POM_COL, 0.2)), rr)
	_mini_head(rr.position + Vector2(18, hh * 0.5), 9.0, POM_COL, POM_DARK, true)
	draw_string(f, rr.position + Vector2(34, hh * 0.5 + f.get_ascent(15) * 0.5 - 2), rt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, POM_DARK.darkened(0.2))
	# chrono
	var secs := ceili(maxf(0.0, time_left))
	var tt := "%d:%02d" % [secs / 60, secs % 60]
	var tw := f.get_string_size(tt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 46.0
	var tr := Rect2(b.get_center().x - tw * 0.5, y, tw, hh)
	var hurry := phase == "play" and time_left < 15.0
	draw_style_box(UITheme.pill(UITheme.BAD_SOFT if hurry else Color(1, 1, 1, 0.85)), tr)
	UIIcons.draw(self, "clock", Rect2(tr.position + Vector2(10, hh * 0.5 - 9), Vector2(18, 18)), UITheme.BAD if hurry else UITheme.MUTED, 1.0)
	draw_string(f, tr.position + Vector2(32, hh * 0.5 + f.get_ascent(16) * 0.5 - 2), tt, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, UITheme.BAD if hurry else UITheme.INK)


## Points du corps a l'instant k (0..1 entre deux pas).
func _render_points(s: Dictionary, k: float) -> PackedVector2Array:
	var body: Array = s["body"]
	var prev: Array = s["prev"]
	var pts := PackedVector2Array()
	if body.is_empty():
		return pts
	var moved: bool = prev.size() > 0 and prev[0] != body[0]
	if not moved:
		for c in body:
			pts.append(_cell_px(c))
		return pts
	pts.append(_cell_px(Vector2(prev[0]).lerp(Vector2(body[0]), k)))
	var grew := body.size() > prev.size()
	var n := body.size()
	if grew:
		for i in range(1, n):
			pts.append(_cell_px(body[i]))
	else:
		# la queue glisse de son ancienne case vers la case suivante (sans couper le dernier virage)
		for i in range(1, n):
			pts.append(_cell_px(body[i]))
		pts.append(_cell_px(Vector2(prev[prev.size() - 1]).lerp(Vector2(body[n - 1]), k)))
	return pts


func _snake_draw(s: Dictionary, k: float, cs: float, col: Color, dark: Color, is_user: bool) -> void:
	var pts := _render_points(s, k)
	if pts.is_empty():
		return
	var alive: bool = s["alive"]
	if not alive:
		var fade := clampf(_over_t * 1.5, 0.0, 1.0)
		col = col.lerp(Color("c9bccb"), fade * 0.7)
		dark = dark.lerp(Color("a597a8"), fade * 0.7)
	var n := pts.size()
	var w0 := cs * 0.88
	# ombre
	for i in n:
		var w := w0 * lerpf(1.0, 0.68, float(i) / maxf(1.0, n - 1))
		draw_circle(pts[i] + Vector2(0, cs * 0.14), w * 0.5, Color(0.35, 0.12, 0.3, 0.10), true, -1.0, true)
		if i > 0:
			draw_line(pts[i - 1] + Vector2(0, cs * 0.14), pts[i] + Vector2(0, cs * 0.14), Color(0.35, 0.12, 0.3, 0.10), w, true)
	# corps : contour fonce puis remplissage, du bout de la queue vers la tete
	for pass_i in 2:
		for j in n:
			var i := n - 1 - j
			var t := float(i) / maxf(1.0, n - 1)
			var w := w0 * lerpf(1.0, 0.68, t) - (0.0 if pass_i == 0 else cs * 0.1)
			var c := dark if pass_i == 0 else col.lerp(col.lightened(0.22), t)
			draw_circle(pts[i], w * 0.5, c, true, -1.0, true)
			if i < n - 1:
				draw_line(pts[i], pts[i + 1], c, w, true)
	# taches sur le dos : elles glissent avec le corps (interpolees case par case)
	var body: Array = s["body"]
	var prev: Array = s["prev"]
	var moved: bool = not prev.is_empty() and prev[0] != body[0]
	for i in range(2, body.size() - 1, 2):
		var c := Vector2(body[i])
		if moved and i < prev.size():
			c = Vector2(prev[i]).lerp(c, k)
		var t := float(i) / maxf(1.0, body.size() - 1)
		draw_circle(_cell_px(c) + Vector2(0, -cs * 0.06), cs * 0.12 * lerpf(1.0, 0.6, t), Color(1, 1, 1, 0.35), true, -1.0, true)
	# tete
	var dir := Vector2(s["dir"])
	if n > 1 and pts[0].distance_to(pts[1]) > 0.5:
		dir = (pts[0] - pts[1]).normalized()
	var hp := pts[0]
	if not alive:
		hp += dir * cs * 0.12 * maxf(0.0, sin(_over_t * 30.0)) * maxf(0.0, 1.0 - _over_t * 2.0)
	_head(hp, dir, cs, col, dark, not is_user, alive)


func _head(p: Vector2, dir: Vector2, cs: float, col: Color, dark: Color, pompom: bool, alive: bool) -> void:
	var r := cs * 0.5
	var side := Vector2(-dir.y, dir.x)
	if pompom:
		for sg: float in [-1.0, 1.0]:
			var ep := p - dir * r * 0.35 + side * sg * r * 0.72
			draw_circle(ep, r * 0.36, dark, true, -1.0, true)
			draw_circle(ep, r * 0.2, col.lightened(0.25), true, -1.0, true)
	draw_circle(p, r, dark, true, -1.0, true)
	draw_circle(p, r - cs * 0.06, col, true, -1.0, true)
	draw_circle(p - dir * r * 0.15 + Vector2(-r * 0.15, -r * 0.25), r * 0.35, Color(1, 1, 1, 0.25), true, -1.0, true)
	var ink := UITheme.INK
	for sg: float in [-1.0, 1.0]:
		var e := p + dir * r * 0.22 + side * sg * r * 0.42
		if alive:
			draw_circle(e, r * 0.27, Color.WHITE, true, -1.0, true)
			draw_circle(e + dir * r * 0.08, r * 0.17, ink, true, -1.0, true)
			draw_circle(e + dir * r * 0.02 + Vector2(-0.4, -0.6) * r * 0.1, r * 0.06, Color.WHITE, true, -1.0, true)
		else:
			var a := side * r * 0.14
			var bb := dir * r * 0.14
			draw_line(e - a - bb, e + a + bb, ink, maxf(1.2, cs * 0.07), true)
			draw_line(e - a + bb, e + a - bb, ink, maxf(1.2, cs * 0.07), true)
	if pompom:
		for sg: float in [-1.0, 1.0]:
			draw_circle(p + side * sg * r * 0.62 - dir * r * 0.1, r * 0.13, Color(1, 0.4, 0.55, 0.45), true, -1.0, true)
	elif alive and fmod(_t, 2.4) < 0.25:
		# petite langue
		var tp := p + dir * r * 1.05
		draw_line(p + dir * r * 0.8, tp, Color("ff6f8e"), maxf(1.2, cs * 0.07), true)
		draw_line(tp, tp + (dir + side * 0.6).normalized() * r * 0.22, Color("ff6f8e"), maxf(1.0, cs * 0.05), true)
		draw_line(tp, tp + (dir - side * 0.6).normalized() * r * 0.22, Color("ff6f8e"), maxf(1.0, cs * 0.05), true)


func _mini_head(p: Vector2, r: float, col: Color, dark: Color, pompom: bool) -> void:
	if pompom:
		draw_circle(p + Vector2(-r * 0.7, -r * 0.65), r * 0.38, dark, true, -1.0, true)
		draw_circle(p + Vector2(r * 0.7, -r * 0.65), r * 0.38, dark, true, -1.0, true)
	draw_circle(p, r, dark, true, -1.0, true)
	draw_circle(p, r - 1.5, col, true, -1.0, true)
	draw_circle(p + Vector2(-r * 0.38, -r * 0.05), r * 0.17, UITheme.INK, true, -1.0, true)
	draw_circle(p + Vector2(r * 0.38, -r * 0.05), r * 0.17, UITheme.INK, true, -1.0, true)


func _apple(c: Vector2, r: float) -> void:
	if r <= 0.5:
		return
	soft_shadow(c + Vector2(0, r * 0.25), r * 0.85, 0.12, 2.0)
	var red := Color("ff5a6e")
	draw_circle(c + Vector2(-r * 0.32, r * 0.05), r * 0.78, red.darkened(0.08), true, -1.0, true)
	draw_circle(c + Vector2(r * 0.32, r * 0.05), r * 0.78, red.darkened(0.08), true, -1.0, true)
	draw_circle(c + Vector2(-r * 0.3, 0), r * 0.72, red, true, -1.0, true)
	draw_circle(c + Vector2(r * 0.3, 0), r * 0.72, red, true, -1.0, true)
	draw_circle(c + Vector2(-r * 0.42, -r * 0.25), r * 0.22, Color(1, 1, 1, 0.55), true, -1.0, true)
	draw_line(c + Vector2(0, -r * 0.55), c + Vector2(r * 0.12, -r * 1.0), Color("8a5a3c"), maxf(1.2, r * 0.16), true)
	var leaf := PackedVector2Array()
	for i in 9:
		var t := float(i) / 8.0
		leaf.append(c + Vector2(r * 0.15, -r * 0.85) + Vector2(t * r * 0.7, -sin(t * PI) * r * 0.28 - t * r * 0.15))
	for i in 9:
		var t := 1.0 - float(i) / 8.0
		leaf.append(c + Vector2(r * 0.15, -r * 0.85) + Vector2(t * r * 0.7, sin(t * PI) * r * 0.12 - t * r * 0.15))
	draw_colored_polygon(leaf, Color("5cc98d"))


func _star_burst(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := i * PI / 8.0 + _over_t
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.55))
	draw_colored_polygon(pts, col)
	draw_circle(c, r * 0.32, Color(1, 1, 1, col.a), true, -1.0, true)
