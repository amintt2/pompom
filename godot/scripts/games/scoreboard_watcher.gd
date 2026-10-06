class_name ScoreboardWatcher
extends Node
## Repli quand la Stats API de Rocket League est indisponible : surveille le tableau des scores en haut
## au centre de l'ecran du jeu (boite BLEUE a gauche de l'horloge, boite ORANGE a droite) et detecte
## quand les chiffres d'une boite changent. Pas d'OCR : on compare une petite « empreinte » binaire des
## pixels blancs (les chiffres) dans chaque boite.
##
## Performances : 2 captures par seconde d'une petite zone (~24 % x 9 % de l'ecran) via
## DisplayServer.screen_get_image_rect (GDI), le tout dans WorkerThreadPool : le thread principal ne fait
## que lancer la tache et lire le resultat. Mesures dans docs/rocket_league.md.
## OPT-IN (capture d'ecran) : actif seulement si `active` est vrai (GameEvents le met quand Rocket League
## est au premier plan, que l'API n'est pas connectee et que le reglage "rl_screen_watch" est actif).
##
## Equipe de l'utilisateur : le tableau de Rocket League met TOUJOURS le bleu a gauche et l'orange a
## droite, quelle que soit l'equipe du joueur ; rien a l'ecran ne dit de facon fiable de quel cote on est.
## Donc `my_color` = "blue" | "orange" | "auto". En "auto", on utilise `known_team` (fourni par GameEvents
## quand la Stats API l'a appris) ; sinon le but est signale par `goal_unknown(color, team_num)`.
##
## Anti faux positifs : une empreinte doit etre identique sur `stable_samples` captures (1,5 s) avant
## d'etre acceptee ; animation du but, explosion, transition du replay sont ainsi ignorees. Si une boite
## disparait (menu, replay plein ecran) moins de `lost_reset_sec`, on compare a sa reapparition (but
## pendant la transition = detecte) ; au-dela, on repart de zero sans rien signaler. Si les deux boites
## changent en meme temps (nouveau match, tableau remis a 0), aucun but n'est signale.

signal goal(my_team: bool, scorer: String, score_mine: int, score_theirs: int)
signal goal_unknown(scorer: String, team_num: int)
signal scoreboard_seen(ok: bool)  ## le tableau vient d'apparaitre / de disparaitre

const BLUE := 0
const ORANGE := 1
const WORK_W := 180  ## largeur de travail apres reduction
const GRID_X := 8
const GRID_Y := 7  # 8 x 7 = 56 bits (tient dans un int)

var active := false:
	set(v):
		active = v
		if not v:
			_t = 0.0
var interval := 0.5
var my_color := "auto"  ## "auto" | "blue" | "orange"
var known_team := -1  ## equipe connue par ailleurs (Stats API), 0 bleu / 1 orange
var screen := -1  ## ecran a surveiller (-1 = celui de la fenetre au premier plan, sinon principal)
var region := Rect2(0.38, 0.0, 0.24, 0.09)  ## zone relative a l'ecran (x, y, largeur, hauteur)
var stable_samples := 3
var lost_reset_sec := 8.0
var cooldown_sec := 4.0  # deux buts ne peuvent pas etre si proches (engagement + compte a rebours)

var seen := false  ## tableau visible a la derniere capture
var capture_ok := true  ## faux si la capture est noire (plein ecran exclusif)
var goals := [0, 0]  ## buts vus depuis l'apparition du tableau (relatif, pas d'OCR)
var last_cost_usec := 0  ## cout de la derniere capture+analyse (thread de travail)
var last_capture_usec := 0
var last_analyze_usec := 0

var _t := 0.0
var _task := -1
var _result := {}
var _base: Array = [null, null]  # empreinte acceptee {sig, white}
var _cand: Array = [null, null]  # empreinte candidate
var _cand_n := [0, 0]
var _lost_since := [-1.0, -1.0]
var _last_goal := [-100.0, -100.0]


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _process(delta: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		ingest(_result, _now())
	if not active:
		return
	_t += delta
	if _t < interval:
		return
	_t = 0.0
	var rect := capture_rect()
	if rect.size.x < 8 or rect.size.y < 4:
		return
	_task = WorkerThreadPool.add_task(_work.bind(rect), false, "pompom scoreboard")


## Zone a capturer en coordonnees ecran Godot.
func capture_rect() -> Rect2i:
	var s := _pick_screen()
	var pos := DisplayServer.screen_get_position(s)
	var size := DisplayServer.screen_get_size(s)
	return Rect2i(pos.x + int(size.x * region.position.x), pos.y + int(size.y * region.position.y),
		int(size.x * region.size.x), int(size.y * region.size.y))


func _pick_screen() -> int:
	if screen >= 0 and screen < DisplayServer.get_screen_count():
		return screen
	var act := get_node_or_null("/root/Activity")
	if act and act.fg_hwnd != 0:
		for w in act.windows:
			if int(w.get("id", 0)) == int(act.fg_hwnd):
				var c: Vector2 = (w["rect"] as Rect2).get_center()
				for i in DisplayServer.get_screen_count():
					if Rect2(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)).has_point(c):
						return i
	return DisplayServer.get_primary_screen()


func _work(rect: Rect2i) -> void:
	var t0 := Time.get_ticks_usec()
	var img := DisplayServer.screen_get_image_rect(rect)
	var t1 := Time.get_ticks_usec()
	var r := analyze(img) if img else {"blank": true}
	var t2 := Time.get_ticks_usec()
	r["capture_usec"] = t1 - t0
	r["analyze_usec"] = t2 - t1
	_result = r


## Analyse une capture de la zone du tableau. Statique et sans etat : testable sur des images de synthese.
## Retour : {blank, boxes: [box_bleue_ou_null, box_orange_ou_null]} ; box = {rect: Rect2i, sig: int, white: int}
static func analyze(src: Image) -> Dictionary:
	if src == null or src.is_empty():
		return {"blank": true, "boxes": [null, null]}
	var img := src
	if img.get_format() != Image.FORMAT_RGB8 or img.get_width() != WORK_W:
		img = src.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGB8)
		while img.get_width() >= WORK_W * 2 and img.get_height() >= 16:
			img.shrink_x2()  # moyenne 2x2 : garde les traits fins des chiffres (bilineaire seul les perd)
		if img.get_width() != WORK_W:
			var h := maxi(8, roundi(float(img.get_height()) * WORK_W / img.get_width()))
			img.resize(WORK_W, h, Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	# classes : 0 rien, 1 bleu, 2 orange, 3 blanc
	var cls := PackedByteArray()
	cls.resize(w * h)
	var lum := 0
	var i := 0
	for p in w * h:
		var r := data[i]
		var g := data[i + 1]
		var b := data[i + 2]
		i += 3
		lum += r + g + b
		if r >= 185 and g >= 185 and b >= 185:
			cls[p] = 3
		elif b >= 110 and b > r + 50 and b > g + 15:
			cls[p] = 1
		elif r >= 170 and r > b + 90 and g >= 50 and g <= 190 and r > g + 40:
			cls[p] = 2
	if lum < w * h * 3 * 3:
		return {"blank": true, "boxes": [null, null]}
	var half := w / 2
	return {"blank": false, "boxes": [
		_find_box(cls, w, h, 0, half, 1), _find_box(cls, w, h, half, w, 2)]}


## Cherche la boite de couleur `c` entre les colonnes [x0, x1) par projections.
static func _find_box(cls: PackedByteArray, w: int, h: int, x0: int, x1: int, c: int):
	var col := PackedInt32Array()
	col.resize(x1 - x0)
	var maxc := 0
	for x in range(x0, x1):
		var n := 0
		var p := x
		for y in h:
			if cls[p] == c:
				n += 1
			p += w
		col[x - x0] = n
		maxc = maxi(maxc, n)
	if maxc < 4:
		return null
	# plus longue suite de colonnes riches en couleur (trous d'une colonne toleres)
	var thr := maxi(3, maxc / 2)
	var best := Vector2i(-1, -1)
	var run_start := -1
	var gap := 0
	for x in range(0, x1 - x0 + 1):
		var ok := x < x1 - x0 and col[x] >= thr
		if ok:
			if run_start < 0:
				run_start = x
			gap = 0
		elif run_start >= 0:
			gap += 1
			if gap > 1 or x >= x1 - x0:
				var e := x - gap
				if e - run_start > best.y - best.x:
					best = Vector2i(run_start, e)
				run_start = -1
				gap = 0
	if best.x < 0 or best.y - best.x + 1 < 4:
		return null
	var bx0 := x0 + best.x
	var bx1 := x0 + best.y  # inclus
	var bw := bx1 - bx0 + 1
	# lignes : couleur + blanc (les chiffres) sur une bonne partie de la largeur
	var y0 := -1
	var y1 := -1
	for y in h:
		var n := 0
		var p := y * w + bx0
		for x in bw:
			var v := cls[p + x]
			if v == c or v == 3:
				n += 1
		if n >= bw * 0.6:
			if y0 < 0:
				y0 = y
			y1 = y
		elif y0 >= 0 and y - y1 > 1:
			break
	if y0 < 0 or y1 - y0 + 1 < 4:
		return null
	var bh := y1 - y0 + 1
	# validation : boite pleine (couleur + chiffres) et forme plausible
	var colored := 0
	var white := 0
	for y in range(y0, y1 + 1):
		var p := y * w + bx0
		for x in bw:
			var v := cls[p + x]
			if v == c:
				colored += 1
			elif v == 3:
				white += 1
	var area := bw * bh
	if float(colored + white) / area < 0.7 or float(colored) / area < 0.35:
		return null
	if bw > (x1 - x0) * 0.9 or float(bw) / bh > 5.0 or float(bh) / bw > 3.0:
		return null
	# empreinte des chiffres : grille GRID_X x GRID_Y posee sur le cadre des pixels blancs (les chiffres),
	# pas sur toute la boite -> bien plus de details par chiffre ; bit = case assez blanche
	var wx0 := bx0 + bw
	var wx1 := -1
	var wy0 := y0 + bh
	var wy1 := -1
	for y in range(y0, y1 + 1):
		var p := y * w + bx0
		for x in bw:
			if cls[p + x] == 3:
				wx0 = mini(wx0, bx0 + x)
				wx1 = maxi(wx1, bx0 + x)
				wy0 = mini(wy0, y)
				wy1 = maxi(wy1, y)
	var sig := 0
	if wx1 < 0:
		return {"rect": Rect2i(bx0, y0, bw, bh), "sig": 0, "white": 0, "dw": 0}
	var dw := wx1 - wx0 + 1
	var dh := wy1 - wy0 + 1
	for gy in GRID_Y:
		var cy0 := wy0 + gy * dh / GRID_Y
		var cy1 := maxi(cy0 + 1, wy0 + (gy + 1) * dh / GRID_Y)
		for gx in GRID_X:
			var cx0 := wx0 + gx * dw / GRID_X
			var cx1 := maxi(cx0 + 1, wx0 + (gx + 1) * dw / GRID_X)
			var n := 0
			var tot := 0
			for yy in range(cy0, cy1):
				for xx in range(cx0, cx1):
					tot += 1
					if cls[yy * w + xx] == 3:
						n += 1
			if tot > 0 and float(n) / tot >= 0.3:
				sig |= 1 << (gy * GRID_X + gx)
	return {"rect": Rect2i(bx0, y0, bw, bh), "sig": sig, "white": white, "dw": dw}


static func differs(a: Dictionary, b: Dictionary) -> bool:
	var x: int = int(a["sig"]) ^ int(b["sig"])
	var bits := 0
	while x != 0:
		x &= x - 1
		bits += 1
	if bits >= 3:
		return true
	if absi(int(a.get("dw", 0)) - int(b.get("dw", 0))) >= 2:
		return true  # largeur des chiffres differente (ex. 9 -> 10, 1 -> 2)
	var wa := int(a["white"])
	var wb := int(b["white"])
	return absi(wa - wb) > maxi(3, int(maxi(wa, wb) * 0.2))


## Integre un resultat d'analyse (public pour les tests : `now` en secondes).
func ingest(r: Dictionary, now: float) -> void:
	last_capture_usec = int(r.get("capture_usec", 0))
	last_analyze_usec = int(r.get("analyze_usec", 0))
	last_cost_usec = last_capture_usec + last_analyze_usec
	capture_ok = not bool(r.get("blank", false))
	var boxes: Array = r.get("boxes", [null, null])
	var now_seen := boxes[0] != null and boxes[1] != null
	if now_seen != seen:
		seen = now_seen
		scoreboard_seen.emit(seen)
	var changed := [false, false]
	var newsig: Array = [null, null]
	for t in 2:
		var b = boxes[t]
		if b == null:
			if _lost_since[t] < 0.0:
				_lost_since[t] = now
			elif now - _lost_since[t] > lost_reset_sec:
				_base[t] = null
				_cand[t] = null
				_cand_n[t] = 0
			continue
		_lost_since[t] = -1.0
		if _cand[t] != null and not differs(_cand[t], b):
			_cand_n[t] += 1
		else:
			_cand[t] = b
			_cand_n[t] = 1
		if _cand_n[t] < stable_samples:
			continue
		if _base[t] == null:
			_base[t] = _cand[t]
			continue
		if differs(_base[t], _cand[t]):
			changed[t] = true
			newsig[t] = _cand[t]
	if changed[0] and changed[1]:
		# les deux a la fois : nouveau match / tableau remis a zero -> on repart sans rien signaler
		_base = newsig
		goals = [0, 0]
		return
	for t in 2:
		if not changed[t]:
			continue
		_base[t] = newsig[t]
		if now - _last_goal[t] < cooldown_sec:
			continue
		_last_goal[t] = now
		goals[t] += 1
		_emit(t)


func _emit(t: int) -> void:
	var color := "blue" if t == BLUE else "orange"
	var mine := my_team_index()
	if mine < 0:
		goal_unknown.emit(color, t)
		return
	goal.emit(t == mine, color, goals[mine], goals[1 - mine])


func my_team_index() -> int:
	if my_color == "blue":
		return BLUE
	if my_color == "orange":
		return ORANGE
	return known_team


## Oublie tout (changement de jeu).
func reset() -> void:
	_base = [null, null]
	_cand = [null, null]
	_cand_n = [0, 0]
	_lost_since = [-1.0, -1.0]
	goals = [0, 0]
	seen = false


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
