class_name Connect4Game
extends MiniGameBase
## Puissance 4 contre Pompom : grille 7 x 6, pions dodus qui tombent avec un petit rebond,
## alignement gagnant mis en valeur. L'IA (Connect4AI) tourne dans le WorkerThreadPool.
## Joueur = pions dores a etoile, Pompom = pions roses a frimousse.

const COLS := 7
const ROWS := 6
const USER_COL := Color("ffc94a")
const USER_DARK := Color("e59a12")
const POM_COL := Color("ff7eb0")
const POM_DARK := Color("e2508c")
const PLATE := Color("ab9dfb")
const PLATE_TOP := Color("c3b9ff")
const PLATE_BOTTOM := Color("9585f2")

var grid := []  # [col][row] 0 vide, 1 joueur, 2 Pompom (row 0 = bas)
var state := "idle"  # idle | user | drop | pompom | over
var hover_col := 3
var last_col := -1
var win_cells: Array[Vector2i] = []
var last_ai_ms := 0.0  # duree de calcul du dernier coup de l'IA (tests)
var last_ai_depth := 0

var _ai: Connect4AI
var _task := -1
var _think_left := 0.0
var _wander_t := 0.0
var _hover_x := 3.0
var _hover_target := 3.0
var _drop := {}  # {col,row,who,y,vy,bounces}
var _squash := {}  # Vector2i -> temps restant
var _t := 0.0
var _win_t := 0.0
var _mouse_in := false
var _ai_col := -1
var _ready_to_drop := 0.0
var _threat_before := 0  # menaces jouables de l'adversaire avant le coup
var _geo := {}
var _plate_cache := []  # [[PackedVector2Array, PackedColorArray], ...]
var _cache_size := Vector2.ZERO


func game_id() -> String:
	return "connect4"


func _init() -> void:
	super()
	_ai = Connect4AI.new()
	Connect4AI.init_tables()
	mouse_exited.connect(func(): _mouse_in = false)
	mouse_entered.connect(func(): _mouse_in = true)
	_reset_grid()


func _reset_grid() -> void:
	grid.clear()
	for c in COLS:
		var col := []
		col.resize(ROWS)
		col.fill(0)
		grid.append(col)


func start_game(p_difficulty: int, p_user_starts: bool) -> void:
	shutdown()
	super(p_difficulty, p_user_starts)
	_reset_grid()
	_ai = Connect4AI.new()
	win_cells.clear()
	_drop = {}
	_squash.clear()
	_win_t = 0.0
	last_col = -1
	hover_col = 3
	_hover_x = 3.0
	_hover_target = 3.0
	if user_starts:
		_user_turn()
	else:
		state = "pompom"
		_ready_to_drop = 0.0
		_pompom_turn(0.35)
	queue_redraw()


func shutdown() -> void:
	if _task >= 0:
		_ai.abort = true
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


# ------------------------------------------------------------------ tours
func _user_turn() -> void:
	state = "user"
	_set_thinking(false)
	status_changed.emit("À toi de jouer !", "user")


func _pompom_turn(extra_delay := 0.0) -> void:
	state = "pompom"
	_set_thinking(true)
	status_changed.emit("%s réfléchit..." % pet_name, "pompom")
	pompom_event.emit("think")
	_think_left = _think_time() + extra_delay
	_wander_t = 0.2
	_ai_col = -1
	var st := Connect4AI.from_grid(grid, POMPOM)
	_ai.setup(st[0], st[1], st[2], difficulty, _rng.randi())
	_task = WorkerThreadPool.add_task(_ai.run, false, "Pompom Puissance 4")


func playable(col: int) -> bool:
	return col >= 0 and col < COLS and grid[col][ROWS - 1] == 0


func _row_for(col: int) -> int:
	for r in ROWS:
		if grid[col][r] == 0:
			return r
	return -1


## Coup du joueur (souris, clavier ou tests). Renvoie false si refuse.
func user_play(col: int) -> bool:
	if state != "user" or not playable(col):
		return false
	_threat_before = _playable_threats(POMPOM)
	_place(col, USER)
	return true


func _place(col: int, who: int) -> void:
	var row := _row_for(col)
	grid[col][row] = who
	last_col = col
	moves_played += 1
	state = "drop"
	var g := _geometry()
	_drop = {"col": col, "row": row, "who": who, "y": g["hover_y"], "vy": 0.0, "bounces": 0}


func _landed(d: Dictionary) -> void:
	var col: int = d["col"]
	var row: int = d["row"]
	var who: int = d["who"]
	_squash[Vector2i(col, row)] = 0.22
	_drop = {}
	var cells := _find_win(col, row, who)
	if not cells.is_empty():
		win_cells = cells
		_win_t = 0.0
		state = "over"
		if who == USER:
			status_changed.emit("Bravo, tu as gagné !", "user")
			_finish("win")
		else:
			status_changed.emit("%s a gagné !" % pet_name, "pompom")
			_finish("lose")
		return
	if moves_played >= COLS * ROWS:
		state = "over"
		status_changed.emit("Match nul !", "")
		_finish("draw")
		return
	if who == USER:
		var threats := _playable_threats(USER)
		if threats > 0:
			pompom_event.emit("worried")
		elif _threat_before > 0 and _playable_threats(POMPOM) < _threat_before:
			pompom_event.emit("user_blocked")
		else:
			pompom_event.emit("user_move")
		_pompom_turn()
	else:
		if _threat_before > 0 and _playable_threats(USER) < _threat_before:
			pompom_event.emit("blocked")
		elif _ai.result_score > Connect4AI.WIN - 100 and difficulty > 0:
			pompom_event.emit("sure_win")
		elif _playable_threats(POMPOM) > 0:
			pompom_event.emit("threat")
		else:
			pompom_event.emit("play")
		_user_turn()


## Nombre de cases ou `who` gagnerait au prochain coup.
func _playable_threats(who: int) -> int:
	var n := 0
	for c in COLS:
		var r := _row_for(c)
		if r < 0:
			continue
		grid[c][r] = who
		if not _find_win(c, r, who).is_empty():
			n += 1
		grid[c][r] = 0
	return n


func _find_win(col: int, row: int, who: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
		var line: Array[Vector2i] = [Vector2i(col, row)]
		for sgn: int in [1, -1]:
			var p := Vector2i(col, row) + d * sgn
			while p.x >= 0 and p.x < COLS and p.y >= 0 and p.y < ROWS and grid[p.x][p.y] == who:
				line.append(p)
				p += d * sgn
		if line.size() >= 4:
			for c in line:
				if not out.has(c):
					out.append(c)
	return out


# ------------------------------------------------------------------ boucle
func _process(delta: float) -> void:
	_t += delta
	if not _squash.is_empty():
		for k in _squash.keys():
			_squash[k] -= delta
			if _squash[k] <= 0.0:
				_squash.erase(k)
	if state == "over":
		_win_t += delta
	# chute
	if not _drop.is_empty():
		var g := _geometry()
		var target: float = _cell_center(_drop["col"], _drop["row"]).y
		var cell: float = g["cell"]
		_drop["vy"] += cell * 95.0 * delta
		_drop["y"] += _drop["vy"] * delta
		if _drop["y"] >= target:
			_drop["y"] = target
			if _drop["bounces"] < 1 and _drop["vy"] > cell * 5.0:
				_drop["vy"] = -_drop["vy"] * 0.22
				_drop["bounces"] += 1
			else:
				_landed(_drop)
	# Pompom reflechit
	if state == "pompom":
		_think_left -= delta
		if _ai_col < 0:
			_wander_t -= delta
			if _wander_t <= 0.0:
				_wander_t = _rng.randf_range(0.25, 0.5)
				var opts := []
				for c in COLS:
					if playable(c):
						opts.append(c)
				if not opts.is_empty():
					_hover_target = float(opts[_rng.randi() % opts.size()])
			if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
				WorkerThreadPool.wait_for_task_completion(_task)
				_task = -1
				last_ai_ms = _ai.elapsed_ms
				last_ai_depth = _ai.reached_depth
				_ai_col = _ai.result_col
				if not playable(_ai_col):
					for c in Connect4AI.ORDER:
						if playable(c):
							_ai_col = c
							break
		if _ai_col >= 0 and _think_left <= 0.0:
			_hover_target = float(_ai_col)
			if absf(_hover_x - _hover_target) < 0.04:
				_ready_to_drop += delta
				if _ready_to_drop > 0.12:
					_ready_to_drop = 0.0
					_set_thinking(false)
					_threat_before = _playable_threats(USER)
					_hover_x = _hover_target
					_place(_ai_col, POMPOM)
	elif state == "user":
		_hover_target = float(hover_col)
	_hover_x = lerpf(_hover_x, _hover_target, 1.0 - exp(-delta * (14.0 if state == "user" else 9.0)))
	if absf(_hover_x - _hover_target) < 0.01:
		_hover_x = _hover_target
	queue_redraw()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_mouse_in = true
		var c := _col_at(ev.position)
		if c >= 0 and state == "user":
			hover_col = c
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var c := _col_at(ev.position)
		if c >= 0:
			hover_col = c
			user_play(c)
		accept_event()


func key_input(ev: InputEventKey) -> bool:
	if state != "user":
		return ev.keycode in [KEY_LEFT, KEY_RIGHT, KEY_SPACE, KEY_ENTER, KEY_DOWN]
	match ev.keycode:
		KEY_LEFT, KEY_A, KEY_Q:
			hover_col = wrapi(hover_col - 1, 0, COLS)
			return true
		KEY_RIGHT, KEY_D:
			hover_col = wrapi(hover_col + 1, 0, COLS)
			return true
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_DOWN, KEY_S:
			user_play(hover_col)
			return true
	if ev.keycode >= KEY_1 and ev.keycode <= KEY_7:
		hover_col = ev.keycode - KEY_1
		user_play(hover_col)
		return true
	if ev.keycode >= KEY_KP_1 and ev.keycode <= KEY_KP_7:
		hover_col = ev.keycode - KEY_KP_1
		user_play(hover_col)
		return true
	return false


# ------------------------------------------------------------------ geometrie
func _geometry() -> Dictionary:
	if _geo.get("size", Vector2.ZERO) == size:
		return _geo
	var cell := minf(size.x / (COLS + 0.9), size.y / (ROWS + 2.1))
	var pad := cell * 0.3
	var bw := cell * COLS + pad * 2.0
	var bh := cell * ROWS + pad * 2.0
	var top := cell * 1.15
	var total_h := top + bh + cell * 0.25
	var ox := (size.x - bw) * 0.5
	var oy := (size.y - total_h) * 0.5 + top
	_geo = {"size": size, "cell": cell, "pad": pad, "board": Rect2(ox, oy, bw, bh),
		"grid": Rect2(ox + pad, oy + pad, cell * COLS, cell * ROWS), "hover_y": oy - cell * 0.62,
		"hole": cell * 0.39, "token": cell * 0.355}
	_plate_cache.clear()
	return _geo


func _cell_center(col: int, row: int) -> Vector2:
	var g := _geometry()
	var gr: Rect2 = g["grid"]
	var cell: float = g["cell"]
	return gr.position + Vector2((col + 0.5) * cell, (ROWS - row - 0.5) * cell)


func _col_at(p: Vector2) -> int:
	var g := _geometry()
	var gr: Rect2 = g["grid"]
	var b: Rect2 = g["board"]
	if p.x < gr.position.x or p.x >= gr.end.x or p.y > b.end.y + 10:
		return -1
	return clampi(int((p.x - gr.position.x) / g["cell"]), 0, COLS - 1)


# ------------------------------------------------------------------ dessin
func _draw() -> void:
	var g := _geometry()
	var b: Rect2 = g["board"]
	var gr: Rect2 = g["grid"]
	var cell: float = g["cell"]
	var tr: float = g["token"]
	# ombre portee + pieds
	for side: float in [0.16, 0.84]:
		var fx := b.position.x + b.size.x * side
		var foot := Rect2(fx - cell * 0.42, b.end.y - cell * 0.2, cell * 0.84, cell * 0.42)
		draw_style_box(UITheme.box(PLATE_BOTTOM.darkened(0.12), int(cell * 0.18), Color.TRANSPARENT, 0, 0), foot)
	var sh := UITheme.box(Color(0, 0, 0, 0), int(cell * 0.32), Color.TRANSPARENT, 0, 0)
	sh.shadow_color = Color(0.3, 0.15, 0.45, 0.22)
	sh.shadow_size = int(cell * 0.25)
	sh.shadow_offset = Vector2(0, cell * 0.08)
	sh.bg_color = PLATE_BOTTOM
	draw_style_box(sh, b)
	# fond des trous (interieur du plateau)
	draw_rect(gr.grow(-1), PLATE_BOTTOM.darkened(0.2))
	for c in COLS:
		var x := gr.position.x + (c + 0.5) * cell
		draw_rect(Rect2(x - cell * 0.5, gr.position.y, cell, gr.size.y), Color(1, 1, 1, 0.025 * (c % 2)))
	# colonne survolee (fond)
	if state == "user":
		var hx := gr.position.x + (_hover_x + 0.5) * cell
		draw_rect(Rect2(hx - cell * 0.5, gr.position.y, cell, gr.size.y), Color(1, 1, 1, 0.10))
	# pions poses
	for c in COLS:
		for r in ROWS:
			var who: int = grid[c][r]
			if who == 0:
				continue
			if not _drop.is_empty() and _drop["col"] == c and _drop["row"] == r:
				continue
			var sq := 0.0
			var k := Vector2i(c, r)
			if _squash.has(k):
				sq = sin((1.0 - _squash[k] / 0.22) * PI) * 0.12
			_token(_cell_center(c, r), tr, who, 1.0, sq)
	# pion qui tombe
	if not _drop.is_empty():
		var p := Vector2(_cell_center(_drop["col"], 0).x, _drop["y"])
		_token(p, tr, _drop["who"], 1.0, 0.0)
	# facade du plateau (avec les trous)
	_draw_plate(g)
	# victoire : anneaux + trait
	if not win_cells.is_empty():
		var pulse := 0.5 + 0.5 * sin(_win_t * 6.0)
		var who: int = grid[win_cells[0].x][win_cells[0].y]
		var col := USER_COL if who == USER else POM_COL
		var sorted := win_cells.duplicate()
		sorted.sort_custom(func(a, bb): return a.x * 10 + a.y < bb.x * 10 + bb.y)
		var k := clampf(_win_t / 0.4, 0.0, 1.0)
		var a0 := _cell_center(sorted[0].x, sorted[0].y)
		var a1 := _cell_center(sorted[sorted.size() - 1].x, sorted[sorted.size() - 1].y)
		if win_cells.size() == 4 or _collinear(sorted):
			draw_line(a0, a0.lerp(a1, k), Color(1, 1, 1, 0.55), cell * 0.16, true)
		for wc in win_cells:
			var p := _cell_center(wc.x, wc.y)
			draw_arc(p, tr + cell * (0.06 + 0.03 * pulse), 0, TAU, 40, Color(Color.WHITE, 0.95), cell * 0.07, true)
			draw_arc(p, tr + cell * (0.12 + 0.04 * pulse), 0, TAU, 40, Color(col, 0.55 * (1.0 - pulse * 0.5)), cell * 0.05, true)
	# pion en attente au-dessus
	if state in ["user", "pompom", "idle"]:
		var who := USER if state == "user" else POMPOM
		var hx := gr.position.x + (_hover_x + 0.5) * cell
		var bob := sin(_t * 3.2) * cell * 0.04
		var alpha := 1.0 if state == "pompom" or _mouse_in or true else 0.8
		var hp := Vector2(hx, g["hover_y"] + bob)
		_token(hp, tr, who, alpha, 0.0, true)
		if state == "user" and playable(hover_col):
			# petite fleche
			var ay := b.position.y + cell * 0.04
			var ax := gr.position.x + (_hover_x + 0.5) * cell
			var pts := PackedVector2Array([Vector2(ax - cell * 0.1, ay - cell * 0.02), Vector2(ax + cell * 0.1, ay - cell * 0.02), Vector2(ax, ay + cell * 0.09)])
			draw_colored_polygon(pts, Color(1, 1, 1, 0.9))


func _collinear(cells: Array) -> bool:
	if cells.size() < 3:
		return true
	var d: Vector2i = cells[1] - cells[0]
	for i in range(1, cells.size()):
		if cells[i] - cells[i - 1] != d:
			return false
	return true


func _draw_plate(g: Dictionary) -> void:
	if _plate_cache.is_empty() or _cache_size != size:
		_cache_size = size
		_build_plate(g)
	for item in _plate_cache:
		draw_polygon(item[0], item[1])
	var cell: float = g["cell"]
	var hr: float = g["hole"]
	var b: Rect2 = g["board"]
	# reliefs des trous : ombre interne en haut, reflet en bas
	for c in COLS:
		for r in ROWS:
			var p := _cell_center(c, r)
			draw_arc(p, hr - cell * 0.03, PI * 1.0, PI * 2.0, 20, Color(0.22, 0.12, 0.45, 0.22), cell * 0.06, true)
			draw_arc(p, hr + cell * 0.01, PI * 0.15, PI * 0.85, 18, Color(1, 1, 1, 0.45), cell * 0.03, true)
	# lisere et reflet du plateau
	var outline := UIKit.rounded_poly(b, cell * 0.3, 8)
	outline.append(outline[0])
	draw_polyline(outline, Color(1, 1, 1, 0.55), maxf(1.0, cell * 0.025), true)
	draw_line(b.position + Vector2(cell * 0.35, cell * 0.1), Vector2(b.end.x - cell * 0.35, b.position.y + cell * 0.1), Color(1, 1, 1, 0.35), cell * 0.04, true)


func _plate_color(y: float, b: Rect2) -> Color:
	var t := clampf((y - b.position.y) / b.size.y, 0.0, 1.0)
	return PLATE_TOP.lerp(PLATE, minf(1.0, t * 1.6)).lerp(PLATE_BOTTOM, maxf(0.0, t - 0.6) / 0.4)


func _add_poly(pts: PackedVector2Array, b: Rect2) -> void:
	var cols := PackedColorArray()
	for p in pts:
		cols.append(_plate_color(p.y, b))
	_plate_cache.append([pts, cols])


func _build_plate(g: Dictionary) -> void:
	_plate_cache.clear()
	var b: Rect2 = g["board"]
	var gr: Rect2 = g["grid"]
	var cell: float = g["cell"]
	var hr: float = g["hole"]
	var pad: float = g["pad"]
	var rad := pad
	var seg := 8
	# bandeau haut (coins arrondis)
	var top := PackedVector2Array()
	for i in seg + 1:
		var a := PI + PI * 0.5 * i / seg
		top.append(b.position + Vector2(rad, rad) + Vector2(cos(a), sin(a)) * rad)
	for i in seg + 1:
		var a := PI * 1.5 + PI * 0.5 * i / seg
		top.append(Vector2(b.end.x - rad, b.position.y + rad) + Vector2(cos(a), sin(a)) * rad)
	# (rayon = marge : les arcs finissent deja au ras de la grille)
	_add_poly(top, b)
	var bot := PackedVector2Array()
	for i in seg + 1:
		var a := PI * 0.5 * i / seg
		bot.append(Vector2(b.end.x - rad, b.end.y - rad) + Vector2(cos(a), sin(a)) * rad)
	for i in seg + 1:
		var a := PI * 0.5 + PI * 0.5 * i / seg
		bot.append(Vector2(b.position.x + rad, b.end.y - rad) + Vector2(cos(a), sin(a)) * rad)
	_add_poly(bot, b)
	_add_poly(PackedVector2Array([Vector2(b.position.x, gr.position.y), gr.position, Vector2(gr.position.x, gr.end.y), Vector2(b.position.x, gr.end.y)]), b)
	_add_poly(PackedVector2Array([Vector2(gr.end.x, gr.position.y), Vector2(b.end.x, gr.position.y), Vector2(b.end.x, gr.end.y), gr.end]), b)
	# chaque case : carre moins un disque, en deux moities
	var aseg := 16
	for c in COLS:
		for r in ROWS:
			var ctr := _cell_center(c, r)
			var x0 := ctr.x - cell * 0.5
			var x1 := ctr.x + cell * 0.5
			var y0 := ctr.y - cell * 0.5
			var y1 := ctr.y + cell * 0.5
			var up := PackedVector2Array([Vector2(x0, ctr.y), Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, ctr.y)])
			for i in aseg + 1:
				var a := -PI * float(i) / aseg  # 0 -> -PI par le haut
				up.append(ctr + Vector2(cos(a), sin(a)) * hr)
			_add_poly(up, b)
			var dn := PackedVector2Array([Vector2(x1, ctr.y), Vector2(x1, y1), Vector2(x0, y1), Vector2(x0, ctr.y)])
			for i in aseg + 1:
				var a := PI - PI * float(i) / aseg  # PI -> 0 par le bas
				dn.append(ctr + Vector2(cos(a), sin(a)) * hr)
			_add_poly(dn, b)


## Pion dodu : bord fonce, face claire bombee, reflet, embleme (etoile / frimousse).
func _token(c: Vector2, r: float, who: int, alpha := 1.0, squash := 0.0, floating := false) -> void:
	var base := USER_COL if who == USER else POM_COL
	var dark := USER_DARK if who == USER else POM_DARK
	if floating:
		soft_shadow(c + Vector2(0, r * 0.15), r * 0.9, 0.14 * alpha, 4.0)
	draw_set_transform(c, 0.0, Vector2(1.0 + squash, 1.0 - squash))
	draw_circle(Vector2(0, r * 0.07), r, Color(dark, alpha), true, -1.0, true)
	draw_circle(Vector2.ZERO, r, Color(dark.lerp(base, 0.45), alpha), true, -1.0, true)
	draw_circle(Vector2(0, -r * 0.04), r * 0.8, Color(base, alpha), true, -1.0, true)
	draw_arc(Vector2(0, -r * 0.04), r * 0.8, 0, TAU, 40, Color(dark, 0.35 * alpha), maxf(1.0, r * 0.05), true)
	draw_circle(Vector2(0, -r * 0.08), r * 0.62, Color(base.lightened(0.12), alpha), true, -1.0, true)
	# embleme
	if who == USER:
		var st := star_points(Vector2(0, -r * 0.06), r * 0.42)
		draw_colored_polygon(st, Color(dark.lerp(base, 0.25), alpha))
		var st2 := star_points(Vector2(0, -r * 0.1), r * 0.36)
		draw_colored_polygon(st2, Color(Color("fff1b8"), alpha))
	else:
		tiny_face(Vector2(0, -r * 0.04), r * 0.62, Color(UITheme.INK, alpha), "happy" if state == "over" and result == "lose" else "smile")
	# reflet
	draw_arc(Vector2.ZERO, r * 0.88, PI * 1.1, PI * 1.45, 12, Color(1, 1, 1, 0.55 * alpha), maxf(1.2, r * 0.09), true)
	draw_circle(Vector2(-r * 0.42, -r * 0.48), r * 0.07, Color(1, 1, 1, 0.7 * alpha), true, -1.0, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
