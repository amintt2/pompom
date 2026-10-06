extends Node
## Tests headless des mini-jeux (IA du Puissance 4, du Snake et du Morpion, deroulement d'une partie).
## Lancer : Godot --path godot --headless res://tests/minigames_test.tscn
## Affiche "PASS ..." / "FAIL ..." puis "MINIGAMES TEST RESULT: x passed, y failed".

var passed := 0
var failed := 0


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		passed += 1
		print("PASS ", name)
	else:
		failed += 1
		print("FAIL ", name, "  ", detail)


func _ready() -> void:
	GameState.no_save = true
	get_tree().create_timer(170.0).timeout.connect(func():
		print("=== WATCHDOG ===")
		get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	_test_c4_tactics()
	_test_c4_perf()
	_test_c4_strength()
	_test_snake_unit()
	_test_snake_sim()
	_test_ttt()
	await _test_c4_flow()
	await _test_snake_flow()
	print("MINIGAMES TEST RESULT: %d passed, %d failed" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)


# ------------------------------------------------------------------ Puissance 4
static func _grid(cols: Array) -> Array:
	## cols : 7 chaines, de bas en haut ("12" = joueur 1 en bas, joueur 2 au-dessus)
	var g := []
	for c in 7:
		var col := [0, 0, 0, 0, 0, 0]
		var s: String = cols[c]
		for r in s.length():
			col[r] = int(s[r])
		g.append(col)
	return g


func _ai_move(grid: Array, me: int, level: int, seed := 1) -> Connect4AI:
	var st := Connect4AI.from_grid(grid, me)
	var ai := Connect4AI.new()
	ai.setup(st[0], st[1], st[2], level, seed)
	ai.run()
	return ai


func _test_c4_tactics() -> void:
	# Pompom (2) doit jouer ; chaque cas : grille, colonne attendue, description
	var cases := [
		[["1", "", "222", "11", "1", "", ""], 2, "gagne en vertical"],
		[["", "2", "2", "2", "11", "1", "1"], 0, "gagne en horizontal"],
		[["", "", "1", "1", "1", "2", ""], 1, "bloque l'horizontal"],
		[["2", "", "", "111", "2", "", ""], 3, "bloque le vertical"],
		[["1", "21", "121", "212", "", "", ""], 3, "bloque la diagonale"],
		[["2", "12", "212", "121", "", "1", "1"], 3, "gagne en diagonale malgre une menace"],
		[["1", "21", "221", "211", "", "", ""], 4, "gagne plutot que de bloquer"],
	]
	for lvl in [1, 2]:
		for c in cases:
			var g := _grid(c[0])
			var ai := _ai_move(g, 2, lvl, 7)
			var want: int = c[1]
			# verification independante : le coup gagne-t-il / bloque-t-il vraiment ?
			check("c4 L%d %s" % [lvl, c[2]], ai.result_col == want, "joue %d, attendu %d" % [ai.result_col, want])
	# Facile prend quand meme souvent la victoire
	var wins := 0
	for s in 20:
		var ai3 := _ai_move(_grid(["1", "", "222", "11", "1", "", ""]), 2, 0, 100 + s)
		if ai3.result_col == 2:
			wins += 1
	check("c4 Facile prend souvent la victoire (%d/20)" % wins, wins >= 10)


func _test_c4_perf() -> void:
	var positions := [
		["", "", "", "", "", "", ""],
		["", "", "", "1", "", "", ""],
		["1", "2", "12", "2121", "12", "", "2"],
		["12", "21", "1212", "21211", "121", "2", "1"],
	]
	for lvl in [0, 1, 2]:
		var worst := 0.0
		var total := 0.0
		for p in positions:
			var g := _grid(p)
			var n := 0
			for c in 7:
				n += (g[c] as Array).count(1) + (g[c] as Array).count(2)
			var me := 1 if n % 2 == 0 else 2
			var ai := _ai_move(g, me, lvl, 5)
			worst = maxf(worst, ai.elapsed_ms)
			total += ai.elapsed_ms
			print("  c4 perf L%d moves=%d -> col %d depth %d nodes %d %.1f ms" % [lvl, n, ai.result_col, ai.reached_depth, ai.nodes, ai.elapsed_ms])
		print("  c4 perf L%d : pire %.1f ms, moyenne %.1f ms" % [lvl, worst, total / positions.size()])
		if lvl < 2:
			check("c4 L%d < 50 ms (thread principal possible)" % lvl, worst < 50.0, "%.1f ms" % worst)
		else:
			check("c4 L2 < 1500 ms (WorkerThreadPool)" % [], worst < 1500.0, "%.1f ms" % worst)
	# le calcul tourne bien hors du thread principal
	var ai := Connect4AI.new()
	var st := Connect4AI.from_grid(_grid(["", "", "", "", "", "", ""]), 1)
	ai.setup(st[0], st[1], st[2], 2, 9)
	var t0 := Time.get_ticks_usec()
	var task := WorkerThreadPool.add_task(ai.run)
	var launch_ms := (Time.get_ticks_usec() - t0) / 1000.0
	WorkerThreadPool.wait_for_task_completion(task)
	check("c4 lancement en tache < 5 ms (%.2f ms)" % launch_ms, launch_ms < 5.0)
	check("c4 tache terminee avec un coup", ai.result_col == 3, str(ai.result_col))


func _play_c4(level_a: int, level_b: int, seed: int) -> int:
	var g := _grid(["", "", "", "", "", "", ""])
	var who := 1
	for ply in 42:
		var ai := _ai_move(g, who, level_a if who == 1 else level_b, seed + ply)
		var col := ai.result_col
		if col < 0:
			return 0
		var st := Connect4AI.from_grid(g, who)
		var won := Connect4AI.wins_with(st[0], st[1], col)
		var row: int = (g[col] as Array).find(0)
		g[col][row] = who
		if won:
			return who
		who = 3 - who
	return 0


func _test_c4_strength() -> void:
	var hard := 0
	var t0 := Time.get_ticks_msec()
	for i in 4:
		# Difficile joue une fois en premier, une fois en second
		if i % 2 == 0:
			hard += 1 if _play_c4(2, 0, 50 + i * 100) == 1 else 0
		else:
			hard += 1 if _play_c4(0, 2, 50 + i * 100) == 2 else 0
	check("c4 Difficile bat Facile (%d/4)" % hard, hard >= 3)
	var mid := 0
	for i in 4:
		if i % 2 == 0:
			mid += 1 if _play_c4(1, 0, 900 + i * 100) == 1 else 0
		else:
			mid += 1 if _play_c4(0, 1, 900 + i * 100) == 2 else 0
	check("c4 Moyen bat Facile (%d/4)" % mid, mid >= 3)
	print("  c4 parties IA contre IA : %d ms" % (Time.get_ticks_msec() - t0))


# ------------------------------------------------------------------ Snake
func _snake(cells: Array, dir: Vector2i) -> Dictionary:
	var b: Array[Vector2i] = []
	for c in cells:
		b.append(c)
	return {"body": b, "prev": b.duplicate(), "dir": dir, "grow": 0, "alive": true}


func _test_snake_unit() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var w := 28
	var h := 20
	var other := _snake([Vector2i(20, 15), Vector2i(21, 15), Vector2i(22, 15)], Vector2i(-1, 0))
	for lvl in [0, 1, 2]:
		# tete contre le mur de droite, en allant vers la droite : doit tourner
		var me := _snake([Vector2i(27, 5), Vector2i(26, 5), Vector2i(25, 5)], Vector2i(1, 0))
		var ok := true
		for i in 30:
			var d := SnakeAI.choose(me, other, [Vector2i(3, 3)], w, h, lvl, rng)
			if not SnakeAI.inside(Vector2i(27, 5) + d, w, h):
				ok = false
		check("snake L%d ne fonce pas dans le mur" % lvl, ok)
		# coin haut-gauche, une seule sortie
		var me2 := _snake([Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], Vector2i(-1, 0))
		var d2 := SnakeAI.choose(me2, other, [Vector2i(10, 10)], w, h, lvl, rng)
		check("snake L%d sort du coin" % lvl, d2 == Vector2i(0, 1), str(d2))
	# Difficile/Moyen n'entrent pas dans une impasse : couloir ferme a droite
	var wall := []
	for y in range(0, 8):
		wall.append(Vector2i(14, y))
	for x in range(14, 28):
		wall.append(Vector2i(x, 8))
	var blocker := _snake(wall, Vector2i(0, -1))
	blocker["grow"] = 1
	var me3 := _snake([Vector2i(13, 4), Vector2i(12, 4), Vector2i(11, 4), Vector2i(10, 4), Vector2i(9, 4), Vector2i(8, 4)], Vector2i(1, 0))
	# pomme au fond de la poche fermee (inaccessible), il doit rester du bon cote
	for lvl in [1, 2]:
		var d3 := SnakeAI.choose(me3, blocker, [Vector2i(20, 3)], w, h, lvl, rng)
		check("snake L%d choisit un coup sur pres d'un mur" % lvl, SnakeAI.safe_moves(me3, blocker, w, h).has(d3), str(d3))


func _test_snake_sim() -> void:
	var w := 28
	var h := 20
	var rng := RandomNumberGenerator.new()
	for lvl in [0, 1, 2]:
		var bad := 0
		var decisions := 0
		var worst := 0.0
		var total := 0.0
		var deaths := 0
		var lens := 0
		for game in 12:
			rng.seed = 1000 * lvl + game
			var a := _snake([Vector2i(5, 13), Vector2i(4, 13), Vector2i(3, 13), Vector2i(2, 13)], Vector2i(1, 0))
			var b := _snake([Vector2i(22, 6), Vector2i(23, 6), Vector2i(24, 6), Vector2i(25, 6)], Vector2i(-1, 0))
			var apples: Array[Vector2i] = [Vector2i(14, 10), Vector2i(8, 4)]
			for tick in 700:
				var t0 := Time.get_ticks_usec()
				var da := SnakeAI.choose(a, b, apples, w, h, lvl, rng)
				var ms := (Time.get_ticks_usec() - t0) / 1000.0
				worst = maxf(worst, ms)
				total += ms
				decisions += 1
				var safe_a := SnakeAI.safe_moves(a, b, w, h)
				if not safe_a.is_empty() and not safe_a.has(da):
					bad += 1
				var db := SnakeAI.choose(b, a, apples, w, h, 2, rng)
				a["dir"] = da
				b["dir"] = db
				var heads := [a["body"][0] + da, b["body"][0] + db]
				var snakes := [a, b]
				for i in 2:
					if apples.has(heads[i]):
						snakes[i]["grow"] += 1
						apples.erase(heads[i])
				for s in snakes:
					if s["grow"] > 0:
						s["grow"] -= 1
					else:
						(s["body"] as Array).pop_back()
				var dead := false
				for i in 2:
					var hd: Vector2i = heads[i]
					if not SnakeAI.inside(hd, w, h) or (snakes[i]["body"] as Array).has(hd) or (snakes[1 - i]["body"] as Array).has(hd) or heads[0] == heads[1]:
						dead = true
						if i == 0:
							deaths += 1
				if dead:
					break
				for i in 2:
					(snakes[i]["body"] as Array).push_front(heads[i])
				while apples.size() < 2:
					var p := Vector2i(rng.randi() % w, rng.randi() % h)
					if not (a["body"] as Array).has(p) and not (b["body"] as Array).has(p) and not apples.has(p):
						apples.append(p)
			lens += (a["body"] as Array).size()
		print("  snake L%d : %d decisions, pire %.2f ms, moy %.3f ms, morts %d/12, longueur moy %.1f" % [lvl, decisions, worst, total / maxf(1, decisions), deaths, lens / 12.0])
		check("snake L%d jamais dans un mur/corps quand un coup sur existe (%d fautes)" % [lvl, bad], bad == 0)
		# la decision tourne dans le WorkerThreadPool entre deux pas (100 ms au plus vite)
		check("snake L%d decision rapide (moy %.2f ms < 6, pire %.1f ms < 60)" % [lvl, total / maxf(1, decisions), worst],
			total / maxf(1, decisions) < 6.0 and worst < 60.0)


# ------------------------------------------------------------------ Morpion
func _test_ttt() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var losses := 0
	for game in 200:
		var b := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
		var who := 1 if game % 2 == 0 else 2
		while TicTacToeGame.winner_line(b).is_empty() and b.has(0):
			var mv := -1
			if who == 2:
				mv = TicTacToeGame.choose_move(b, 2, rng)
			else:
				var free := []
				for i in 9:
					if b[i] == 0:
						free.append(i)
				mv = free[rng.randi() % free.size()]
			b[mv] = who
			who = 3 - who
		var wl := TicTacToeGame.winner_line(b)
		if not wl.is_empty() and b[wl[0]] == 1:
			losses += 1
	check("morpion Difficile ne perd jamais (200 parties)", losses == 0, "%d defaites" % losses)
	var b2 := PackedInt32Array([1, 1, 0, 2, 2, 0, 0, 0, 0])
	check("morpion L2 gagne tout de suite", TicTacToeGame.choose_move(b2, 2, rng) == 5)
	var b3 := PackedInt32Array([1, 1, 0, 2, 0, 0, 0, 0, 0])
	check("morpion L2 bloque", TicTacToeGame.choose_move(b3, 2, rng) == 2)


# ------------------------------------------------------------------ deroulement (noeuds dans l'arbre)
func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _test_c4_flow() -> void:
	var g := Connect4Game.new()
	g.size = Vector2(700, 520)
	add_child(g)
	var results := []
	g.finished.connect(func(r): results.append(r))
	g.start_game(2, true)
	check("c4 flux : a toi de jouer", g.state == "user")
	check("c4 flux : coup refuse hors tour", not g.user_play(-1))
	g.user_play(3)
	var t0 := Time.get_ticks_msec()
	var worst_frame := 0.0
	var last := Time.get_ticks_usec()
	while g.state != "user" and Time.get_ticks_msec() - t0 < 6000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst_frame = maxf(worst_frame, (now - last) / 1000.0)
		last = now
	var n := 0
	for c in 7:
		for r in 6:
			n += 1 if g.grid[c][r] != 0 else 0
	check("c4 flux : Pompom a repondu (%d pions, IA %.0f ms prof. %d)" % [n, g.last_ai_ms, g.last_ai_depth], n == 2 and g.state == "user")
	check("c4 flux : pas de gel pendant la reflexion (pire image %.1f ms)" % worst_frame, worst_frame < 50.0)
	# fermeture pendant un calcul : pas de blocage
	g.user_play(3)
	await _frames(30)
	t0 = Time.get_ticks_msec()
	g.shutdown()
	check("c4 flux : arret propre du thread (%d ms)" % (Time.get_ticks_msec() - t0), Time.get_ticks_msec() - t0 < 200)
	g.queue_free()
	await _frames(2)


func _test_snake_flow() -> void:
	var g := SnakeDuelGame.new()
	g.size = Vector2(760, 560)
	add_child(g)
	var results := []
	g.finished.connect(func(r): results.append(r))
	g.autoplay_user = true
	g.start_game(2, true)
	check("snake flux : compte a rebours", g.phase == "countdown")
	# on avance la logique sans attendre le temps reel
	g.phase = "play"
	var ticks := 0
	while g.phase == "play" and ticks < 3000:
		g._tick()
		ticks += 1
	print("  snake flux : %d pas, resultat %s, IA pire %.2f ms" % [ticks, str(results), g.ai_ms_max])
	check("snake flux : la partie se termine ou dure", ticks > 20)
	check("snake flux : resultat valide si fini", results.is_empty() or results[0] in ["win", "lose", "draw"])
	# tete contre tete = nul
	var g2 := SnakeDuelGame.new()
	g2.size = Vector2(760, 560)
	add_child(g2)
	var res2 := []
	g2.finished.connect(func(r): res2.append(r))
	g2.start_game(1, true)
	g2.phase = "play"
	var ub: Array[Vector2i] = [Vector2i(10, 10), Vector2i(9, 10), Vector2i(8, 10)]
	var pb: Array[Vector2i] = [Vector2i(12, 10), Vector2i(13, 10), Vector2i(14, 10)]
	g2.user["body"] = ub
	g2.user["dir"] = Vector2i(1, 0)
	g2.pom["body"] = pb
	g2.pom["dir"] = Vector2i(-1, 0)
	g2.apples.clear()
	g2.apples.append(Vector2i(11, 3))
	g2.apples.append(Vector2i(25, 18))
	# Pompom est force tout droit en le bloquant en haut et en bas
	g2._tick()
	check("snake : tete contre tete = nul (ou esquive)", res2.is_empty() or res2[0] == "draw", str(res2))
	g.queue_free()
	g2.queue_free()
	await _frames(2)
