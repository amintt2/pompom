class_name SnakeAI
extends RefCounted
## IA du serpent de Pompom : BFS vers la pomme, remplissage (flood-fill) pour ne pas s'enfermer,
## suivi de la queue quand aucun chemin n'est sur. Une decision coute < 2 ms (grille 28 x 20).
## Serpent = {"body": Array[Vector2i] (tete en premier), "dir": Vector2i, "grow": int}.
## Niveaux : 0 Facile (glouton, reactions lentes, ne voit pas les pieges), 1 Moyen (BFS + espace,
## petites distractions), 2 Difficile (simulation du chemin, evite les face-a-face, dispute les pommes).

const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]


## Grille d'occupation (1 = bloque). Les queues qui vont avancer ce tour-ci sont liberees.
static func occupancy(me: Dictionary, other: Dictionary, w: int, h: int, free_other_tail := true) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(w * h)
	for s in [me, other]:
		if s.is_empty():
			continue
		for p: Vector2i in s["body"]:
			if p.x >= 0 and p.y >= 0 and p.x < w and p.y < h:
				g[p.y * w + p.x] = 1
	var mb: Array = me["body"]
	if int(me.get("grow", 0)) == 0 and mb.size() > 1:
		var t: Vector2i = mb[mb.size() - 1]
		g[t.y * w + t.x] = 0
	if free_other_tail and not other.is_empty() and int(other.get("grow", 0)) == 0:
		var ob: Array = other["body"]
		if ob.size() > 1:
			var t2: Vector2i = ob[ob.size() - 1]
			g[t2.y * w + t2.x] = 0
	return g


static func inside(p: Vector2i, w: int, h: int) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < w and p.y < h


## Coups immediatement surs (pas de mur, pas de corps), sans demi-tour.
static func safe_moves(me: Dictionary, other: Dictionary, w: int, h: int) -> Array[Vector2i]:
	var g := occupancy(me, other, w, h)
	var out: Array[Vector2i] = []
	var head: Vector2i = me["body"][0]
	var back: Vector2i = -me["dir"]
	for d in DIRS:
		if d == back:
			continue
		var n := head + d
		if inside(n, w, h) and g[n.y * w + n.x] == 0:
			out.append(d)
	return out


## Distances BFS depuis `start` (-1 = inaccessible). `start` peut etre bloque (c'est une tete).
## La case supplementaire dist[w * h] contient le nombre de cases atteintes (hors depart).
static func bfs(g: PackedByteArray, start: Vector2i, w: int, h: int) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(w * h + 1)
	dist.fill(-1)
	var q := PackedInt32Array()
	q.resize(w * h)
	var qh := 0
	var qt := 0
	var si := start.y * w + start.x
	dist[si] = 0
	q[qt] = si
	qt += 1
	while qh < qt:
		var i := q[qh]
		qh += 1
		var x := i % w
		var y := i / w
		var dn := dist[i] + 1
		if x + 1 < w and g[i + 1] == 0 and dist[i + 1] < 0:
			dist[i + 1] = dn
			q[qt] = i + 1
			qt += 1
		if x > 0 and g[i - 1] == 0 and dist[i - 1] < 0:
			dist[i - 1] = dn
			q[qt] = i - 1
			qt += 1
		if y + 1 < h and g[i + w] == 0 and dist[i + w] < 0:
			dist[i + w] = dn
			q[qt] = i + w
			qt += 1
		if y > 0 and g[i - w] == 0 and dist[i - w] < 0:
			dist[i - w] = dn
			q[qt] = i - w
			qt += 1
	dist[w * h] = qt - 1
	return dist


## Nombre de cases accessibles depuis `start`.
static func flood(g: PackedByteArray, start: Vector2i, w: int, h: int) -> int:
	return bfs(g, start, w, h)[w * h]


static func choose(me: Dictionary, other: Dictionary, apples: Array, w: int, h: int, level: int,
		rng: RandomNumberGenerator) -> Vector2i:
	var body: Array = me["body"]
	var head: Vector2i = body[0]
	var cur_dir: Vector2i = me["dir"]
	var g := occupancy(me, other, w, h, level < 2 or not _other_may_eat(other, apples))
	var safe: Array[Vector2i] = []
	for d in DIRS:
		if d == -cur_dir:
			continue
		var n := head + d
		if inside(n, w, h) and g[n.y * w + n.x] == 0:
			safe.append(d)
	if safe.is_empty():
		return cur_dir  # perdu de toute facon
	if safe.size() == 1:
		return safe[0]

	if level <= 0:
		return _easy(head, cur_dir, safe, apples, rng)

	# petites distractions (Moyen) : un coup sur au hasard, sans verifier l'espace
	if level == 1 and rng.randf() < 0.03:
		return safe[rng.randi() % safe.size()]

	var length := body.size()
	var tail: Vector2i = body[length - 1]
	var other_head := Vector2i(-99, -99)
	if not other.is_empty() and not (other["body"] as Array).is_empty():
		other_head = other["body"][0]
	# pommes visees : en Difficile, celles ou il arrive avant l'autre
	var targets := apples.duplicate()
	if level >= 2 and other_head.x > -50:
		var od := bfs(g, other_head, w, h)
		var md := bfs(g, head, w, h)
		var mine: Array = []
		for a: Vector2i in apples:
			var ai := a.y * w + a.x
			if md[ai] >= 0 and (od[ai] < 0 or md[ai] < od[ai] or (md[ai] == od[ai] and length > (other["body"] as Array).size() + 1)):
				mine.append(a)
		if not mine.is_empty():
			targets = mine

	var cands := []
	for d in safe:
		var n := head + d
		var g2 := g.duplicate()
		g2[n.y * w + n.x] = 1
		var dist := bfs(g2, n, w, h)
		var space := dist[w * h]
		var tail_ok := int(me.get("grow", 0)) == 0 and _near_reached(dist, tail, w, h)
		var ad := 99999
		for a: Vector2i in targets:
			var v := dist[a.y * w + a.x]
			if a == n:
				v = 0
			if v >= 0 and v < ad:
				ad = v
		var danger := false
		if level >= 2 and other_head.x > -50:
			danger = absi(n.x - other_head.x) + absi(n.y - other_head.y) == 1
		cands.append({"d": d, "n": n, "space": space, "tail": tail_ok, "apple": ad, "danger": danger,
			"roomy": space >= length + 2 or tail_ok})

	var pool := cands.filter(func(c): return c["roomy"])
	if pool.is_empty():
		# coince : le plus d'espace possible, en suivant la queue si on peut
		cands.sort_custom(func(a, b): return a["space"] * 2 + int(a["tail"]) > b["space"] * 2 + int(b["tail"]))
		return cands[0]["d"]
	if level >= 2:
		var calm := pool.filter(func(c): return not c["danger"])
		if not calm.is_empty():
			pool = calm
	pool.sort_custom(func(a, b):
		if a["apple"] != b["apple"]:
			return a["apple"] < b["apple"]
		if a["space"] != b["space"]:
			return a["space"] > b["space"]
		return a["d"] == cur_dir)
	var best: Dictionary = pool[0]
	if level >= 2 and best["apple"] < 99999 and not _path_is_safe(me, other, best["d"], targets, w, h):
		# le chemin vers la pomme l'enfermerait : on suit sa queue / on garde de l'espace
		var alt := pool.filter(func(c): return c["tail"])
		if alt.is_empty():
			alt = pool
		alt.sort_custom(func(a, b): return a["space"] > b["space"])
		return alt[0]["d"]
	return best["d"]


static func _easy(head: Vector2i, cur_dir: Vector2i, safe: Array[Vector2i], apples: Array, rng: RandomNumberGenerator) -> Vector2i:
	# reaction lente : continue tout droit tant que c'est possible, une fois sur quatre
	if safe.has(cur_dir) and rng.randf() < 0.25:
		return cur_dir
	if rng.randf() < 0.05:
		return safe[rng.randi() % safe.size()]
	var best := safe[0]
	var bd := 1 << 30
	for d in safe:
		var n := head + d
		var dd := 1 << 20
		for a: Vector2i in apples:
			dd = mini(dd, absi(a.x - n.x) + absi(a.y - n.y))
		if dd < bd or (dd == bd and d == cur_dir):
			bd = dd
			best = d
	return best


static func _other_may_eat(other: Dictionary, apples: Array) -> bool:
	if other.is_empty():
		return false
	var oh: Vector2i = other["body"][0]
	for a: Vector2i in apples:
		if absi(a.x - oh.x) + absi(a.y - oh.y) == 1:
			return true
	return false


static func _near_reached(dist: PackedInt32Array, cell: Vector2i, w: int, h: int) -> bool:
	if dist[cell.y * w + cell.x] >= 0:
		return true
	for d in DIRS:
		var n := cell + d
		if inside(n, w, h) and dist[n.y * w + n.x] >= 0:
			return true
	return false


## Simule le trajet BFS jusqu'a la pomme la plus proche : une fois arrive, peut-il encore rejoindre sa queue ?
static func _path_is_safe(me: Dictionary, other: Dictionary, first: Vector2i, targets: Array, w: int, h: int) -> bool:
	var body: Array = (me["body"] as Array).duplicate()
	var grow := int(me.get("grow", 0))
	var g := occupancy(me, other, w, h)
	var head: Vector2i = body[0]
	var n := head + first
	# chemin BFS depuis la case suivante
	var g2 := g.duplicate()
	g2[n.y * w + n.x] = 1
	var dist := bfs(g2, n, w, h)
	var goal := Vector2i(-1, -1)
	var gd := 1 << 30
	for a: Vector2i in targets:
		var v := 0 if a == n else dist[a.y * w + a.x]
		if v >= 0 and v < gd:
			gd = v
			goal = a
	if goal.x < 0:
		return true
	# remonte le chemin goal -> n
	var path: Array[Vector2i] = [goal]
	var c := goal
	var guard := 0
	while c != n and guard < w * h:
		guard += 1
		var cd := dist[c.y * w + c.x]
		var moved := false
		for d in DIRS:
			var p := c + d
			if inside(p, w, h) and dist[p.y * w + p.x] == cd - 1:
				c = p
				path.push_front(c)
				moved = true
				break
		if not moved:
			return true
	# deplace le serpent virtuel le long du chemin (l'autre serpent est fige)
	for p in path:
		body.push_front(p)
		if p == goal:
			grow += 1
		if grow > 0:
			grow -= 1
		else:
			body.pop_back()
	var virt := {"body": body, "dir": first, "grow": 0}
	var og := occupancy(virt, other, w, h)
	var vh: Vector2i = body[0]
	og[vh.y * w + vh.x] = 1
	var vd := bfs(og, vh, w, h)
	var vt: Vector2i = body[body.size() - 1]
	if _near_reached(vd, vt, w, h):
		return true
	return vd[w * h] >= body.size() * 2
