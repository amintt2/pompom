class_name Connect4AI
extends RefCounted
## IA du Puissance 4 : negamax + elagage alpha-beta sur bitboards (methode de Pascal Pons),
## table de transposition, coups non perdants, tri des coups (centre d'abord + menaces creees).
## Concue pour tourner dans le WorkerThreadPool : `run()` remplit `result_col`, `abort` l'interrompt.
##
## Bitboard : bit = col * 7 + ligne (ligne 0 = bas, la 7e ligne de chaque colonne reste vide).
## `cur` = pions du joueur qui doit jouer, `mask` = tous les pions.

const W := 7
const H := 6
const H1 := 7
const WIN := 10000
const ORDER := [3, 2, 4, 1, 5, 0, 6]
const EXACT := 0
const LOWER := 1
const UPPER := 2

## Niveaux : 0 = Facile (profondeur 2 + hasard), 1 = Moyen (profondeur 5), 2 = Difficile (profondeur 8+, approfondissement iteratif).
const DEPTH := [2, 5, 8]

static var BOTTOM := 0
static var BOARD := 0
static var COL_MASK: Array[int] = []
static var CENTER := 0
static var NEAR := 0
static var _pc := PackedByteArray()  # popcount sur 16 bits

# entrees de la recherche (posees avant run())
var cur := 0
var mask := 0
var moves := 0
var level := 1
var seed := 0
# sorties
var result_col := -1
var result_score := 0
var reached_depth := 0
var nodes := 0
var elapsed_ms := 0.0
var abort := false

var _tt := {}
var _deadline := 0
var _timeout := false
var _rng := RandomNumberGenerator.new()


static func init_tables() -> void:
	if not COL_MASK.is_empty():
		return
	BOTTOM = 0
	for c in W:
		BOTTOM |= 1 << (c * H1)
	BOARD = BOTTOM * ((1 << H) - 1)
	var cm: Array[int] = []
	for c in W:
		cm.append(((1 << H) - 1) << (c * H1))
	CENTER = cm[3]
	NEAR = cm[2] | cm[4]
	_pc.resize(65536)
	for i in 65536:
		var n := 0
		var v := i
		while v:
			v &= v - 1
			n += 1
		_pc[i] = n
	COL_MASK = cm


static func popcount(v: int) -> int:
	return _pc[v & 0xFFFF] + _pc[(v >> 16) & 0xFFFF] + _pc[(v >> 32) & 0xFFFF] + _pc[(v >> 48) & 0xFFFF]


## Cases vides ou `pos` alignerait 4 pions.
static func winning_cells(pos: int, msk: int) -> int:
	# vertical
	var r := (pos << 1) & (pos << 2) & (pos << 3)
	# horizontal
	var p := (pos << H1) & (pos << (2 * H1))
	r |= p & (pos << (3 * H1))
	r |= p & (pos >> H1)
	p = (pos >> H1) & (pos >> (2 * H1))
	r |= p & (pos << H1)
	r |= p & (pos >> (3 * H1))
	# diagonale 1
	p = (pos << H) & (pos << (2 * H))
	r |= p & (pos << (3 * H))
	r |= p & (pos >> H)
	p = (pos >> H) & (pos >> (2 * H))
	r |= p & (pos << H)
	r |= p & (pos >> (3 * H))
	# diagonale 2
	p = (pos << (H + 2)) & (pos << (2 * (H + 2)))
	r |= p & (pos << (3 * (H + 2)))
	r |= p & (pos >> (H + 2))
	p = (pos >> (H + 2)) & (pos >> (2 * (H + 2)))
	r |= p & (pos << (H + 2))
	r |= p & (pos >> (3 * (H + 2)))
	return r & (BOARD ^ msk)


static func possible(msk: int) -> int:
	return (msk + BOTTOM) & BOARD


static func can_play(msk: int, col: int) -> bool:
	return (possible(msk) & COL_MASK[col]) != 0


## Le coup en `col` gagne-t-il pour le joueur `pos` ?
static func wins_with(pos: int, msk: int, col: int) -> bool:
	return (winning_cells(pos, msk) & possible(msk) & COL_MASK[col]) != 0


## Construit (cur, mask) depuis une grille [col][ligne] (0 vide, 1/2 joueurs) pour le joueur `me`.
static func from_grid(grid: Array, me: int) -> Array:
	init_tables()
	var c := 0
	var m := 0
	var n := 0
	for col in W:
		for row in H:
			var v: int = grid[col][row]
			if v == 0:
				continue
			var bit := 1 << (col * H1 + row)
			m |= bit
			n += 1
			if v == me:
				c |= bit
	return [c, m, n]


## Lance la recherche avec l'etat donne (appel direct ou via WorkerThreadPool).
func setup(p_cur: int, p_mask: int, p_moves: int, p_level: int, p_seed := 0) -> void:
	init_tables()
	cur = p_cur
	mask = p_mask
	moves = p_moves
	level = clampi(p_level, 0, 2)
	seed = p_seed
	result_col = -1
	abort = false


func run() -> void:
	var t0 := Time.get_ticks_usec()
	_rng.seed = seed if seed != 0 else int(t0)
	nodes = 0
	_timeout = false
	_deadline = t0 + 4_000_000  # garde-fou : on garde le coup de la derniere profondeur complete
	result_col = _choose()
	elapsed_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _choose() -> int:
	var poss := possible(mask)
	if poss == 0:
		return -1
	var playable: Array[int] = []
	for c in W:
		if poss & COL_MASK[c]:
			playable.append(c)
	var opp := cur ^ mask
	var my_win := winning_cells(cur, mask) & poss
	var opp_win := winning_cells(opp, mask) & poss
	if level == 0:
		# Facile : rate parfois ses coups gagnants et ses parades, joue souvent au hasard
		if my_win and _rng.randf() < 0.8:
			return _col_of(my_win)
		if opp_win and _rng.randf() < 0.6:
			return _col_of(opp_win)
		if _rng.randf() < 0.3:
			return playable[_rng.randi() % playable.size()]
		return _scored_pick(DEPTH[0], 6)
	if my_win:
		return _col_of(my_win)
	if level == 1:
		return _scored_pick(DEPTH[1], 0)
	return _iterative(DEPTH[2])


func _col_of(bits: int) -> int:
	for c in ORDER:
		if bits & COL_MASK[c]:
			return c
	return -1


## Evalue chaque coup a la profondeur `depth` (fenetre complete) et choisit au hasard parmi les
## coups a moins de `slack` points du meilleur.
func _scored_pick(depth: int, slack: int) -> int:
	var poss := possible(mask)
	var scores := {}
	var best := -WIN * 2
	for c in ORDER:
		var mv := poss & COL_MASK[c]
		if mv == 0:
			continue
		var s := -_negamax(cur ^ mask, mask | mv, moves + 1, depth - 1, -WIN * 2, WIN * 2)
		scores[c] = s
		best = maxi(best, s)
	var pool: Array[int] = []
	for c in scores:
		if scores[c] >= best - slack:
			pool.append(c)
	reached_depth = depth
	result_score = best
	return pool[_rng.randi() % pool.size()]


## Approfondissement iteratif : profondeur 2..max_depth, puis un peu plus profond tant que le budget le permet.
func _iterative(max_depth: int) -> int:
	var t0 := Time.get_ticks_usec()
	var best_col := _col_of(possible(mask))
	var depth := 2
	while depth <= 42 - moves:
		if depth > max_depth:
			# bonus : on creuse encore si c'est rapide (fin de partie surtout)
			var spent := Time.get_ticks_usec() - t0
			if spent > 250_000 or depth > max_depth + 6:
				break
			_deadline = t0 + 900_000
		var r := _root(depth)
		if _timeout:
			break
		best_col = r
		reached_depth = depth
		if absi(result_score) > WIN - 100:
			break  # issue forcee trouvee
		depth += 1
	return best_col


func _root(depth: int) -> int:
	var poss := possible(mask)
	var alpha := -WIN * 2
	var beta := WIN * 2
	var best_col := -1
	var best := -WIN * 2
	var tt_best := -1
	var e = _tt.get(cur + mask)
	if e != null:
		tt_best = (int(e) >> 22) & 7
	var order := _ordered(poss, tt_best)
	for c in order:
		var mv := poss & COL_MASK[c]
		var s := -_negamax(cur ^ mask, mask | mv, moves + 1, depth - 1, -beta, -alpha)
		if _timeout:
			return best_col
		if s > best:
			best = s
			best_col = c
		alpha = maxi(alpha, s)
	result_score = best
	_tt[cur + mask] = _pack(depth, EXACT, best, best_col)
	return best_col


func _ordered(poss: int, first: int) -> Array[int]:
	# tri par nombre de menaces creees (insertion, 7 elements), le meilleur coup de la TT en tete
	var cols: Array[int] = []
	var keys: Array[int] = []
	for c in ORDER:
		var mv := poss & COL_MASK[c]
		if mv == 0:
			continue
		var k := popcount(winning_cells(cur | mv, mask | mv)) * 8 - ORDER.find(c)
		if c == first:
			k = 1 << 20
		var i := cols.size()
		cols.append(c)
		keys.append(k)
		while i > 0 and keys[i - 1] < k:
			cols[i] = cols[i - 1]
			keys[i] = keys[i - 1]
			i -= 1
		cols[i] = c
		keys[i] = k
	return cols


static func _pack(depth: int, flag: int, val: int, col: int) -> int:
	return (val + 32768) | (depth << 16) | (flag << 20) | (maxi(col, 0) << 22)


func _negamax(p: int, msk: int, mv_count: int, depth: int, alpha: int, beta: int) -> int:
	nodes += 1
	if (nodes & 1023) == 0 and (abort or Time.get_ticks_usec() > _deadline):
		_timeout = true
	if _timeout:
		return 0
	var poss := (msk + BOTTOM) & BOARD
	if poss == 0:
		return 0
	if winning_cells(p, msk) & poss:
		return WIN - mv_count - 1
	var opp := p ^ msk
	var opp_win := winning_cells(opp, msk)
	var forced := poss & opp_win
	if forced:
		if forced & (forced - 1):
			return -(WIN - mv_count - 2)
		poss = forced
	poss &= ~(opp_win >> 1)
	if poss == 0:
		return -(WIN - mv_count - 2)
	if depth <= 0:
		return _eval(p, opp, msk, opp_win)
	var key := p + msk
	var best_col := -1
	var e = _tt.get(key)
	if e != null:
		var ei: int = e
		var ed := (ei >> 16) & 15
		best_col = (ei >> 22) & 7
		if ed >= depth:
			var ev := (ei & 0xFFFF) - 32768
			var ef := (ei >> 20) & 3
			if ef == EXACT:
				return ev
			elif ef == LOWER:
				alpha = maxi(alpha, ev)
			else:
				beta = mini(beta, ev)
			if alpha >= beta:
				return ev
	var a0 := alpha
	var best := -WIN * 2
	var bc := -1
	if depth >= 3:
		# tri par menaces creees (plus couteux, reserve aux noeuds proches de la racine)
		var cols: Array[int] = []
		var keys: Array[int] = []
		for c in ORDER:
			var mv := poss & COL_MASK[c]
			if mv == 0:
				continue
			var k := popcount(winning_cells(p | mv, msk | mv)) * 8 - ORDER.find(c)
			if c == best_col:
				k = 1 << 20
			var i := cols.size()
			cols.append(c)
			keys.append(k)
			while i > 0 and keys[i - 1] < k:
				cols[i] = cols[i - 1]
				keys[i] = keys[i - 1]
				i -= 1
			cols[i] = c
			keys[i] = k
		for c in cols:
			var s := -_negamax(opp, msk | (poss & COL_MASK[c]), mv_count + 1, depth - 1, -beta, -alpha)
			if _timeout:
				return 0
			if s > best:
				best = s
				bc = c
				if s > alpha:
					alpha = s
					if alpha >= beta:
						break
	else:
		for i in 8:
			var c: int = best_col if i == 0 else ORDER[i - 1]
			if c < 0 or (i > 0 and c == best_col):
				continue
			var mv := poss & COL_MASK[c]
			if mv == 0:
				continue
			var s := -_negamax(opp, msk | mv, mv_count + 1, depth - 1, -beta, -alpha)
			if _timeout:
				return 0
			if s > best:
				best = s
				bc = c
				if s > alpha:
					alpha = s
					if alpha >= beta:
						break
	var flag := EXACT
	if best <= a0:
		flag = UPPER
	elif best >= beta:
		flag = LOWER
	if _tt.size() > 400_000:
		_tt.clear()
	_tt[key] = _pack(depth, flag, best, bc)
	return best


## Evaluation statique (point de vue du joueur `p` qui doit jouer) : menaces + controle du centre.
func _eval(p: int, opp: int, msk: int, opp_win: int) -> int:
	var my_w := winning_cells(p, msk)
	var s := 12 * (popcount(my_w) - popcount(opp_win))
	# menaces "empilees" (deux cases gagnantes l'une sur l'autre) : tres fortes
	s += 20 * (popcount(my_w & (my_w >> 1)) - popcount(opp_win & (opp_win >> 1)))
	s += 4 * (popcount(p & CENTER) - popcount(opp & CENTER))
	s += 2 * (popcount(p & NEAR) - popcount(opp & NEAR))
	return s
