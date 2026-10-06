class_name TicTacToeGame
extends MiniGameBase
## Morpion contre Pompom. Joueur = croix bleue, Pompom = rond rose a oreilles.
## IA : minimax complet (instantane) ; Facile rate souvent, Moyen se trompe parfois, Difficile est parfait.

const USER_COL := Color("63aef5")
const USER_DARK := Color("3d8ad6")
const POM_COL := Color("ff7eb0")
const POM_DARK := Color("e2508c")
const LINES := [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

var cells := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
var state := "idle"  # user | pompom | over
var cursor := 4
var hover := -1
var win_line: Array = []

var _born := PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
var _t := 0.0
var _think_left := 0.0
var _ai_cell := -1
var _over_t := 0.0
var _key_cursor := false


func game_id() -> String:
	return "tictactoe"


func start_game(p_difficulty: int, p_user_starts: bool) -> void:
	super(p_difficulty, p_user_starts)
	cells = PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	win_line = []
	_over_t = 0.0
	cursor = 4
	if user_starts:
		_user_turn()
	else:
		_pompom_turn()
	queue_redraw()


func _user_turn() -> void:
	state = "user"
	status_changed.emit("À toi de jouer !", "user")


func _pompom_turn() -> void:
	state = "pompom"
	_set_thinking(true)
	status_changed.emit("%s réfléchit..." % pet_name, "pompom")
	pompom_event.emit("think")
	_think_left = _think_time()
	_ai_cell = choose_move(cells, difficulty, _rng)


func user_play(i: int) -> bool:
	if state != "user" or i < 0 or i > 8 or cells[i] != 0:
		return false
	_put(i, USER)
	return true


func _put(i: int, who: int) -> void:
	var threat_before := _threats(cells, POMPOM if who == USER else USER)
	cells[i] = who
	_born[i] = _t
	moves_played += 1
	var w := winner_line(cells)
	if not w.is_empty():
		win_line = w
		state = "over"
		if who == USER:
			status_changed.emit("Bravo, tu as gagné !", "user")
			_finish("win")
		else:
			status_changed.emit("%s a gagné !" % pet_name, "pompom")
			_finish("lose")
		return
	if not cells.has(0):
		state = "over"
		status_changed.emit("Match nul !", "")
		_finish("draw")
		return
	var blocked := threat_before > 0 and _threats(cells, POMPOM if who == USER else USER) < threat_before
	if who == USER:
		if _threats(cells, USER) > 0:
			pompom_event.emit("worried")
		elif blocked:
			pompom_event.emit("user_blocked")
		else:
			pompom_event.emit("user_move")
		_pompom_turn()
	else:
		if blocked:
			pompom_event.emit("blocked")
		elif _threats(cells, POMPOM) > 1:
			pompom_event.emit("sure_win")
		elif _threats(cells, POMPOM) > 0:
			pompom_event.emit("threat")
		else:
			pompom_event.emit("play")
		_user_turn()


# ------------------------------------------------------------------ IA
static func winner_line(b: PackedInt32Array) -> Array:
	for l in LINES:
		if b[l[0]] != 0 and b[l[0]] == b[l[1]] and b[l[1]] == b[l[2]]:
			return l
	return []


## Nombre de lignes ou `who` gagne au prochain coup.
static func _threats(b: PackedInt32Array, who: int) -> int:
	var n := 0
	for l in LINES:
		var mine := 0
		var empty := 0
		for i in l:
			if b[i] == who:
				mine += 1
			elif b[i] == 0:
				empty += 1
		if mine == 2 and empty == 1:
			n += 1
	return n


static var _memo := {}


## Score minimax (memorise : 3^9 positions au plus). Victoire rapide = meilleur score.
static func _minimax(b: PackedInt32Array, who: int) -> int:
	var key := 0
	var filled := 0
	for i in 9:
		key = key * 3 + b[i]
		filled += 1 if b[i] != 0 else 0
	key = key * 3 + who
	if _memo.has(key):
		return _memo[key]
	var w := winner_line(b)
	var res := 0
	if not w.is_empty():
		res = (10 - filled) * (1 if b[w[0]] == POMPOM else -1)
	elif filled < 9:
		res = -100 if who == POMPOM else 100
		for i in 9:
			if b[i] != 0:
				continue
			b[i] = who
			var s := _minimax(b, USER if who == POMPOM else POMPOM)
			b[i] = 0
			res = maxi(res, s) if who == POMPOM else mini(res, s)
	_memo[key] = res
	return res


static func _win_or_block(b: PackedInt32Array, who: int) -> int:
	for l in LINES:
		var mine := 0
		var empty := -1
		for i in l:
			if b[i] == who:
				mine += 1
			elif b[i] == 0:
				empty = i
		if mine == 2 and empty >= 0:
			return empty
	return -1


## Coup de Pompom (case 0..8).
static func choose_move(board: PackedInt32Array, level: int, rng: RandomNumberGenerator) -> int:
	var b := board.duplicate()
	var free: Array[int] = []
	for i in 9:
		if b[i] == 0:
			free.append(i)
	if free.is_empty():
		return -1
	if level <= 0:
		var win := _win_or_block(b, POMPOM)
		if win >= 0 and rng.randf() < 0.7:
			return win
		var block := _win_or_block(b, USER)
		if block >= 0 and rng.randf() < 0.45:
			return block
		return free[rng.randi() % free.size()]
	if level == 1 and rng.randf() < 0.25:
		var win2 := _win_or_block(b, POMPOM)
		if win2 >= 0:
			return win2
		return free[rng.randi() % free.size()]
	var best := -1000
	var pool: Array[int] = []
	for i in free:
		b[i] = POMPOM
		var s := _minimax(b, USER)
		b[i] = 0
		if s > best:
			best = s
			pool = [i]
		elif s == best:
			pool.append(i)
	return pool[rng.randi() % pool.size()]


# ------------------------------------------------------------------ boucle / entree
func _process(delta: float) -> void:
	_t += delta
	if state == "over":
		_over_t += delta
	if state == "pompom":
		_think_left -= delta
		if _think_left <= 0.0 and _ai_cell >= 0:
			_set_thinking(false)
			var c := _ai_cell
			_ai_cell = -1
			_put(c, POMPOM)
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		hover = _cell_at(ev.position)
		_key_cursor = false
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var c := _cell_at(ev.position)
		if c >= 0:
			user_play(c)
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hover = -1


func key_input(ev: InputEventKey) -> bool:
	var k := ev.keycode
	if k >= KEY_1 and k <= KEY_9:
		user_play(k - KEY_1)
		return true
	if k >= KEY_KP_1 and k <= KEY_KP_9:
		# pave numerique : 7 8 9 en haut
		var n := k - KEY_KP_1
		user_play((2 - n / 3) * 3 + n % 3)
		return true
	var d := Vector2i.ZERO
	match k:
		KEY_LEFT, KEY_A, KEY_Q:
			d = Vector2i(-1, 0)
		KEY_RIGHT, KEY_D:
			d = Vector2i(1, 0)
		KEY_UP, KEY_W, KEY_Z:
			d = Vector2i(0, -1)
		KEY_DOWN, KEY_S:
			d = Vector2i(0, 1)
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			user_play(cursor)
			return true
		_:
			return false
	_key_cursor = true
	cursor = clampi(cursor % 3 + d.x, 0, 2) + clampi(cursor / 3 + d.y, 0, 2) * 3
	return true


func _geometry() -> Rect2:
	var s := minf(size.x, size.y) * 0.92
	s = minf(s, 470.0)
	return Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s))


func _cell_rect(i: int) -> Rect2:
	var g := _geometry()
	var gap := g.size.x * 0.035
	var cs := (g.size.x - gap * 2.0) / 3.0
	return Rect2(g.position + Vector2((i % 3) * (cs + gap), (i / 3) * (cs + gap)), Vector2(cs, cs))


func _cell_at(p: Vector2) -> int:
	for i in 9:
		if _cell_rect(i).has_point(p):
			return i
	return -1


# ------------------------------------------------------------------ dessin
func _draw() -> void:
	var g := _geometry()
	var back := UITheme.box(Color("f3e9f8"), int(g.size.x * 0.07), Color(1, 1, 1, 0.9), 2, 0)
	back.shadow_color = Color(0.35, 0.15, 0.32, 0.12)
	back.shadow_size = 14
	back.shadow_offset = Vector2(0, 5)
	draw_style_box(back, g.grow(g.size.x * 0.04))
	for i in 9:
		var r := _cell_rect(i)
		var hl := state == "user" and cells[i] == 0 and (i == hover or (_key_cursor and i == cursor))
		var bg := Color("fffdfb") if not hl else Color("fff3f8")
		if win_line.has(i):
			var wc := USER_COL if cells[i] == USER else POM_COL
			bg = Color("fffdfb").lerp(wc, 0.16 + 0.06 * sin(_over_t * 5.0))
		var st := UITheme.box(bg, int(r.size.x * 0.16),
			Color(UITheme.ACCENT, 0.6) if hl else Color(1, 1, 1, 0.0), 2 if hl else 0, 0)
		st.shadow_color = Color(0.35, 0.15, 0.32, 0.10)
		st.shadow_size = 6
		st.shadow_offset = Vector2(0, 3)
		draw_style_box(st, r)
		if hl:
			_mark(r.get_center(), r.size.x * 0.3, USER, 1.0, 0.25)
		if cells[i] != 0:
			var k := clampf((_t - _born[i]) / 0.35, 0.0, 1.0)
			_mark(r.get_center(), r.size.x * 0.3, cells[i], k, 1.0)
	if not win_line.is_empty():
		var a := _cell_rect(win_line[0]).get_center()
		var b := _cell_rect(win_line[2]).get_center()
		var dir := (b - a).normalized()
		a -= dir * g.size.x * 0.08
		b += dir * g.size.x * 0.08
		var k := clampf(_over_t / 0.35, 0.0, 1.0)
		var col := USER_DARK if cells[win_line[0]] == USER else POM_DARK
		var w := g.size.x * 0.022
		draw_line(a, a.lerp(b, k), Color(col, 0.55), w, true)
		draw_circle(a, w * 0.5, Color(col, 0.55), true, -1.0, true)
		draw_circle(a.lerp(b, k), w * 0.5, Color(col, 0.55), true, -1.0, true)
		for i in win_line:
			var r2 := _cell_rect(i)
			var bump := 1.0 + 0.06 * maxf(0.0, sin(_over_t * 5.0 - i * 0.6))
			_mark(r2.get_center(), r2.size.x * 0.3 * bump, cells[i], 1.0, 1.0)


func _mark(c: Vector2, r: float, who: int, k: float, alpha: float) -> void:
	var w := r * 0.34
	if who == USER:
		var col := Color(USER_COL, alpha)
		var dk := Color(USER_DARK, alpha)
		var k1 := clampf(k * 2.0, 0.0, 1.0)
		var k2 := clampf(k * 2.0 - 1.0, 0.0, 1.0)
		var a0 := c + Vector2(-r, -r) * 0.78
		var a1 := c + Vector2(r, r) * 0.78
		var b0 := c + Vector2(r, -r) * 0.78
		var b1 := c + Vector2(-r, r) * 0.78
		for pass_i in 2:
			var off := Vector2(0, r * 0.08) if pass_i == 0 else Vector2.ZERO
			var cc := dk if pass_i == 0 else col
			if k1 > 0.0:
				draw_line(a0 + off, a0.lerp(a1, k1) + off, cc, w, true)
				draw_circle(a0 + off, w * 0.5, cc, true, -1.0, true)
				draw_circle(a0.lerp(a1, k1) + off, w * 0.5, cc, true, -1.0, true)
			if k2 > 0.0:
				draw_line(b0 + off, b0.lerp(b1, k2) + off, cc, w, true)
				draw_circle(b0 + off, w * 0.5, cc, true, -1.0, true)
				draw_circle(b0.lerp(b1, k2) + off, w * 0.5, cc, true, -1.0, true)
		if k >= 1.0 and alpha >= 1.0:
			draw_line(a0 + Vector2(w * 0.15, -w * 0.05), a0.lerp(a1, 0.3), Color(1, 1, 1, 0.45), w * 0.25, true)
	else:
		var col := Color(POM_COL, alpha)
		var dk := Color(POM_DARK, alpha)
		var s := MiniGameBase.ease_out_back(k)
		var rr := r * 0.8 * s
		if rr <= 1.0:
			return
		# oreilles
		for sg: float in [-1.0, 1.0]:
			draw_circle(c + Vector2(sg * rr * 0.68, -rr * 0.78), rr * 0.3, dk, true, -1.0, true)
			draw_circle(c + Vector2(sg * rr * 0.68, -rr * 0.78), rr * 0.15, col.lightened(0.3), true, -1.0, true)
		draw_arc(c + Vector2(0, r * 0.08), rr, 0, TAU, 48, dk, w, true)
		draw_arc(c, rr, 0, TAU, 48, col, w, true)
		draw_arc(c, rr, PI * 1.1, PI * 1.4, 12, Color(1, 1, 1, 0.5 * alpha), w * 0.3, true)
		if k >= 1.0:
			tiny_face(c, rr * 0.62, Color(UITheme.INK, alpha), "happy" if state == "over" and result == "lose" else "smile")
