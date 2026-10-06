extends Node
## Tests sans jeu de RocketLeagueLink (decoupage du flux TCP, buts de mon equipe / adverses, fin de
## match, configuration ini) et de ScoreboardWatcher (images de synthese).
##
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --path godot --headless res://tests/rocket_league_test.tscn
## Code de sortie 0 = OK. Avec une vraie fenetre (sans --headless) on mesure aussi le cout d'une vraie
## capture d'ecran (thread principal et WorkerThreadPool).
## Ne touche a AUCUN fichier de Rocket League : les tests d'ecriture ini travaillent sur des copies
## dans user://rl_test/.

var fails := 0
var goals: Array = []
var unknown: Array = []
var ended: Array = []
var started := 0
var scores: Array = []


func _ready() -> void:
	var gs := get_node_or_null("/root/GameState")
	if gs:
		gs.no_save = true
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _run() -> void:
	print("== RocketLeagueLink : flux")
	_test_stream()
	print("== RocketLeagueLink : equipe inconnue / reglages")
	_test_team_logic()
	print("== RocketLeagueLink : performance du decodage")
	_test_perf()
	print("== RocketLeagueLink : fichiers ini (copies de test)")
	_test_ini()
	print("== ScoreboardWatcher : images de synthese")
	_test_scoreboard()
	if DisplayServer.get_name() != "headless":
		print("== ScoreboardWatcher : vraie capture d'ecran")
		await _bench_capture()
	print("== Etat reel de la Stats API sur ce PC (lecture seule)")
	var st := RocketLeagueLink.stats_api_status()
	print("  ", JSON.stringify(st))
	print("RESULTAT : ", "OK" if fails == 0 else "%d ECHEC(S)" % fails)
	get_tree().quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------ messages de synthese
func _player(pname: String, team: int, goals_n := 0, with_boost := false) -> Dictionary:
	var p := {"Name": pname, "PrimaryId": "Epic|%d|0" % pname.hash(), "Shortcut": 1, "TeamNum": team,
		"Score": 100, "Goals": goals_n, "Shots": 1, "Assists": 0, "Saves": 0, "Touches": 5, "CarTouches": 1,
		"Demos": 0, "Loadout": ["body_octane", "None"]}
	if with_boost:
		p["Boost"] = 33
		p["Speed"] = 1200.0
	return p


func _update(blue: int, orange: int, target := "Amîn ✓", target_team := 1, replay := false, players := []) -> Dictionary:
	if players.is_empty():
		players = [_player("Bob", 0), _player("Amîn ✓", 1), _player("Zoé", 1), _player("Max", 0)]
	return {"MatchGuid": "ABC", "Players": players, "Game": {
		"Teams": [{"Name": "Blue", "TeamNum": 0, "Score": blue, "ColorPrimary": "1873FF"},
			{"Name": "Orange", "TeamNum": 1, "Score": orange, "ColorPrimary": "C26418"}],
		"TimeSeconds": 200, "bOvertime": false, "Ball": {"Speed": 0.0, "TeamNum": 255}, "bReplay": replay,
		"bHasWinner": false, "Winner": "", "Arena": "Stadium_P", "bHasTarget": target != "",
		"Target": {"Name": target, "Shortcut": 2, "TeamNum": target_team}}}


func _goal(pname: String, team: int) -> Dictionary:
	return {"MatchGuid": "ABC", "GoalSpeed": 87.3, "GoalTime": 12.0, "ImpactLocation": {"X": 0, "Y": 5120, "Z": 320},
		"Scorer": {"Name": pname, "Shortcut": 1, "TeamNum": team},
		"BallLastTouch": {"Player": {"Name": pname, "Shortcut": 1, "TeamNum": team}, "Speed": 99.0}}


## Format reel (TCP) : Data = chaine JSON.
func _msg(ev: String, data: Dictionary) -> String:
	# ordre reel des cles : Event puis Data (JSON.stringify trie les cles, donc on assemble a la main)
	return "{\"Event\":%s,\"Data\":%s}" % [JSON.stringify(ev), JSON.stringify(JSON.stringify(data))]


func _new_link() -> RocketLeagueLink:
	var l := RocketLeagueLink.new()
	l.update_min_interval = 0.0
	add_child(l)
	goals.clear()
	unknown.clear()
	ended.clear()
	scores.clear()
	started = 0
	l.goal.connect(func(m: bool, s: String, a: int, b: int): goals.append([m, s, a, b]))
	l.goal_unknown.connect(func(s: String, t: int): unknown.append([s, t]))
	l.match_ended.connect(func(w: bool): ended.append(w))
	l.match_started.connect(func(): started += 1)
	l.score_changed.connect(func(a: int, b: int): scores.append([a, b]))
	return l


## Envoie le texte en morceaux de tailles variees (coupe au milieu des messages et des caracteres UTF-8).
func _feed_chunked(l: RocketLeagueLink, text: String, seed: int) -> void:
	var b := text.to_utf8_buffer()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var i := 0
	while i < b.size():
		var n := rng.randi_range(1, 700)
		l.feed(b.slice(i, mini(b.size(), i + n)))
		i += n


func _test_stream() -> void:
	var l := _new_link()
	var s := ""
	s += _msg("MatchCreated", {"MatchGuid": "ABC"})
	s += _msg("MatchInitialized", {"MatchGuid": "ABC"})
	s += _msg("UpdateState", _update(0, 0))
	s += _msg("UpdateState", _update(0, 0))
	s += _msg("GoalScored", _goal("Amîn ✓", 1))  # mon equipe (orange)
	s += _msg("UpdateState", _update(0, 1, "Amîn ✓", 1, true))
	s += _msg("UpdateState", _update(0, 1, "Bob", 0, true))  # replay qui suit Bob : ne doit rien changer
	s += _msg("GoalScored", _goal("Bob", 0))  # adversaire
	s += _msg("UpdateState", _update(1, 1))
	_feed_chunked(l, s, 7)
	_check(started == 1, "match_started emis une fois")
	_check(l.my_team == 1 and l.my_name == "Amîn ✓", "equipe deduite de la cible camera (orange, nom UTF-8 coupe) : %d %s" % [l.my_team, l.my_name])
	_check(goals.size() == 2, "deux buts (pas de doublon avec UpdateState) : %s" % [goals])
	if goals.size() == 2:
		_check(goals[0] == [true, "Amîn ✓", 1, 0], "but de mon equipe -> my_team=true, 1-0")
		_check(goals[1] == [false, "Bob", 1, 1], "but adverse -> my_team=false, 1-1")
	_check(scores.size() > 0 and scores[scores.size() - 1] == [1, 1], "score_changed final 1-1 : %s" % [scores])
	# plusieurs messages dans une seule lecture + score qui monte sans GoalScored (repli)
	l.feed((_msg("UpdateState", _update(1, 2)) + _msg("UpdateState", _update(1, 2))).to_utf8_buffer())
	_check(goals.size() == 2, "pas de but avant le delai de repli")
	l.flush_pending_for_tests()
	_check(goals.size() == 3 and goals[2] == [true, "", 2, 1], "but deduit du score (repli) : %s" % [goals.back()])
	# format publie (Data objet) + mise en forme avec espaces/retours (chemin generique)
	var pretty := JSON.stringify({"Data": _goal("Zoé", 1), "Event": "GoalScored"}, "  ")
	_feed_chunked(l, pretty + "\n" + JSON.stringify({"Event": "MatchEnded", "Data": {"WinnerTeamNum": 1}}, " "), 3)
	_check(goals.size() == 4 and goals[3][0] == true and goals[3][2] == 3, "Data objet + JSON indente : %s" % [goals.back()])
	_check(ended == [true], "match_ended(won=true)")
	# reconnexion en cours de match : pas de but rejoue
	var l2 := _new_link()
	l2.feed_text(_msg("UpdateState", _update(3, 2)))
	l2.feed_text(_msg("UpdateState", _update(3, 2)))
	l2.flush_pending_for_tests()
	_check(goals.is_empty() and l2.scores == [3, 2], "connexion en plein match : score repris sans but fantome")
	# dechets puis resynchronisation
	l2.feed_text("xx}garbage{\"Ev" + "ent\":\"GoalScored\",\"Data\":\"" + JSON.stringify(_goal("Max", 0)).c_escape() + "\"}")
	_check(goals.size() == 1 and goals[0][0] == false, "resynchronisation apres dechets, but adverse : %s" % [goals])
	l.queue_free()
	l2.queue_free()


func _test_team_logic() -> void:
	# spectateur / aucune cible : equipe inconnue -> goal_unknown
	var l := _new_link()
	var pl := [_player("A", 0, 0, true), _player("B", 1, 0, true)]
	l.feed_text(_msg("UpdateState", _update(0, 0, "", 0, false, pl)))
	l.feed_text(_msg("GoalScored", _goal("A", 0)))
	_check(goals.is_empty() and unknown == [["A", 0]], "equipe inconnue -> goal_unknown")
	# couleur forcee
	l.force_color = "blue"
	l.feed_text(_msg("UpdateState", _update(1, 0, "", 0, false, pl)))
	l.feed_text(_msg("GoalScored", _goal("B", 1)))
	_check(goals.size() == 1 and goals[0][0] == false, "couleur forcee bleu, but orange -> adverse")
	# pseudo impose prioritaire sur la cible camera
	var l2 := _new_link()
	l2.player_name = "Zoé"
	l2.feed_text(_msg("UpdateState", _update(0, 0, "Bob", 0)))
	_check(l2.my_team == 1, "pseudo impose (Zoé, orange) > cible camera (Bob)")
	# indice faible : Boost visible pour une seule equipe
	var l3 := _new_link()
	var pl3 := [_player("A", 0, 0, true), _player("B", 0, 0, true), _player("C", 1), _player("D", 1)]
	l3.feed_text(_msg("UpdateState", _update(0, 0, "", 0, false, pl3)))
	_check(l3.my_team == 0, "indice Boost -> equipe bleue")
	l.queue_free()
	l2.queue_free()
	l3.queue_free()


func _test_perf() -> void:
	var l := _new_link()
	var pl := []
	for i in 6:
		pl.append(_player("Joueur%d" % i, i % 2, 0, true))
	var one := _msg("UpdateState", _update(0, 0, "Joueur1", 1, false, pl))
	var s := ""
	for i in 300:
		s += one
	var b := s.to_utf8_buffer()
	var t0 := Time.get_ticks_usec()
	var i := 0
	while i < b.size():
		l.feed(b.slice(i, mini(b.size(), i + 4096)))
		i += 4096
	var us := Time.get_ticks_usec() - t0
	print("  300 UpdateState (%d octets chacun), tous decodes : %.1f us / message" % [one.length(), float(us) / 300.0])
	_check(l.packets == 300, "300 messages decodes (%d)" % l.packets)
	l.update_min_interval = 0.4  # reglage reel : la plupart des UpdateState sont sautes sans decodage
	t0 = Time.get_ticks_usec()
	i = 0
	while i < b.size():
		l.feed(b.slice(i, mini(b.size(), i + 4096)))
		i += 4096
	print("  meme flux avec le filtrage reel (2,5 UpdateState/s decodes) : %.1f us / message" % (float(Time.get_ticks_usec() - t0) / 300.0))
	l.queue_free()


func _test_ini() -> void:
	var dir := "user://rl_test"
	DirAccess.make_dir_recursive_absolute(dir)
	var orig := "[TAGame.MatchStatsExporter_TA]\r\n\r\n; commentaire\r\nPort=49123\r\n\r\nWebPort=49124\r\n\r\n; How many\r\nPacketSendRate=0"
	var p1 := ProjectSettings.globalize_path(dir + "/DefaultStatsAPI.ini")
	var p2 := ProjectSettings.globalize_path(dir + "/TAStatsAPI.ini")
	for p in [p1, p2, p1 + ".pompom.bak", p2 + ".pompom.bak"]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	var f := FileAccess.open(p1, FileAccess.WRITE)
	f.store_string(orig)
	f.close()
	f = FileAccess.open(p2, FileAccess.WRITE)
	f.store_string("[TAGame.MatchStatsExporter_TA]\r\nPort=49123\r\nWebPort=49124\r\n\r\n[IniVersion]\r\n0=1786011018.000000\r\n")
	f.close()
	var patched := RocketLeagueLink.patch_ini_text(orig, 5)
	_check(patched.contains("PacketSendRate=5") and patched.contains("\r\n; commentaire\r\n") and patched.contains("WebPort=49124"),
		"patch : valeur remplacee, CRLF et commentaires conserves")
	_check(RocketLeagueLink.read_section(patched)["PacketSendRate"] == "5", "relecture de la section")
	var err := RocketLeagueLink.enable_in_files(PackedStringArray([p2, p1, dir + "/absent.ini"]), 5)
	_check(err == "", "activation sur copies : '%s'" % err)
	var t2 := FileAccess.get_file_as_string(p2)
	_check(RocketLeagueLink.read_section(t2).get("PacketSendRate", "") == "5" and t2.contains("[IniVersion]"),
		"TAStatsAPI.ini : cle ajoutee dans la bonne section, [IniVersion] garde")
	_check(FileAccess.file_exists(p1 + ".pompom.bak") and FileAccess.get_file_as_string(p1 + ".pompom.bak") == orig, "sauvegarde .pompom.bak = original")
	var mod1 := FileAccess.get_modified_time(p1)
	err = RocketLeagueLink.enable_in_files(PackedStringArray([p1, p2]), 5)
	_check(err == "" and FileAccess.get_modified_time(p1) == mod1, "idempotent : deja actif -> rien n'est reecrit")
	err = RocketLeagueLink.enable_in_files(PackedStringArray([p1, p2]), 0)
	_check(RocketLeagueLink.read_section(FileAccess.get_file_as_string(p1))["PacketSendRate"] == "0"
		and FileAccess.get_file_as_string(p1 + ".pompom.bak") == orig, "desactivation, sauvegarde d'origine intacte")


# ------------------------------------------------------------------ tableau des scores
## 7 segments : a b c d e f g
const SEG := {0: "abcdef", 1: "bc", 2: "abdeg", 3: "abcdg", 4: "bcfg", 5: "acdfg", 6: "acdefg", 7: "abc", 8: "abcdefg", 9: "abcdfg"}


func _digit(img: Image, x: int, y: int, w: int, h: int, d: int) -> void:
	var t := maxi(2, w / 5)
	var white := Color(1, 1, 1)
	var segs: String = SEG[d]
	var hh := h / 2
	if segs.contains("a"): img.fill_rect(Rect2i(x, y, w, t), white)
	if segs.contains("b"): img.fill_rect(Rect2i(x + w - t, y, t, hh), white)
	if segs.contains("c"): img.fill_rect(Rect2i(x + w - t, y + hh, t, hh), white)
	if segs.contains("d"): img.fill_rect(Rect2i(x, y + h - t, w, t), white)
	if segs.contains("e"): img.fill_rect(Rect2i(x, y + hh, t, hh), white)
	if segs.contains("f"): img.fill_rect(Rect2i(x, y, t, hh), white)
	if segs.contains("g"): img.fill_rect(Rect2i(x, y + hh - t / 2, w, t), white)


## Image de la zone capturee (24 % x 9 % d'un ecran w x h) avec le tableau dessine.
func _board(sw: int, sh: int, blue: int, orange: int, show := true, clock := 0) -> Image:
	var w := int(sw * 0.24)
	var h := int(sh * 0.09)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# decor : ciel/arene avec un degrade bleute et des lumieres orangees (pieges a couleur)
	for y in h:
		img.fill_rect(Rect2i(0, y, w, 1), Color(0.10, 0.14, 0.30 + 0.2 * y / h))
	img.fill_rect(Rect2i(int(w * 0.02), int(h * 0.1), int(w * 0.03), int(h * 0.2)), Color(1.0, 0.55, 0.1))
	if not show:
		return img
	var bw := int(w * 0.17)
	var bh := int(h * 0.62)
	var by := int(h * 0.12)
	var cx := w / 2
	img.fill_rect(Rect2i(cx - int(w * 0.13), by, int(w * 0.26), bh), Color(0.12, 0.12, 0.14))  # horloge
	_digit(img, cx - bh / 4, by + bh / 6, bh / 3, bh * 2 / 3, clock % 10)
	var bx := cx - int(w * 0.13) - bw
	img.fill_rect(Rect2i(bx, by, bw, bh), Color(0.09, 0.45, 1.0))
	_digits_in(img, bx, by, bw, bh, blue)
	var ox := cx + int(w * 0.13)
	img.fill_rect(Rect2i(ox, by, bw, bh), Color(0.95, 0.45, 0.08))
	_digits_in(img, ox, by, bw, bh, orange)
	return img


func _digits_in(img: Image, x: int, y: int, w: int, h: int, n: int) -> void:
	var s := str(n)
	var dw := int(h * 0.32)
	var dh := int(h * 0.62)
	var total := s.length() * dw + (s.length() - 1) * dw / 3
	var px := x + (w - total) / 2
	for ch in s:
		_digit(img, px, y + (h - dh) / 2, dw, dh, int(ch))
		px += dw + dw / 3


func _test_scoreboard() -> void:
	var r := ScoreboardWatcher.analyze(_board(1920, 1080, 0, 0))
	_check(r["boxes"][0] != null and r["boxes"][1] != null, "boites bleue et orange trouvees (1080p)")
	_check(ScoreboardWatcher.analyze(_board(1920, 1080, 0, 0, false))["boxes"] == [null, null], "pas de tableau -> rien (malgre decor bleu/orange)")
	for res in [Vector2i(1280, 720), Vector2i(2560, 1440), Vector2i(3840, 2160)]:
		var a := ScoreboardWatcher.analyze(_board(res.x, res.y, 2, 3))
		var b := ScoreboardWatcher.analyze(_board(res.x, res.y, 3, 3))
		_check(a["boxes"][0] != null and a["boxes"][1] != null and ScoreboardWatcher.differs(a["boxes"][0], b["boxes"][0])
			and not ScoreboardWatcher.differs(a["boxes"][1], b["boxes"][1]), "%dx%d : 2->3 detecte cote bleu seulement" % [res.x, res.y])
	# tous les passages n -> n+1 distinguables
	var ok := true
	for n in 12:
		var a = ScoreboardWatcher.analyze(_board(1920, 1080, n, 0))["boxes"][0]
		var b = ScoreboardWatcher.analyze(_board(1920, 1080, n + 1, 0))["boxes"][0]
		if a == null or b == null or not ScoreboardWatcher.differs(a, b):
			ok = false
			print("    indistinguable : %d -> %d" % [n, n + 1])
	_check(ok, "0->1->...->12 : chaque changement de chiffre est vu")
	# l'horloge qui tourne ne doit jamais declencher
	var c1 := ScoreboardWatcher.analyze(_board(1920, 1080, 1, 1, true, 3))
	var c2 := ScoreboardWatcher.analyze(_board(1920, 1080, 1, 1, true, 8))
	_check(not ScoreboardWatcher.differs(c1["boxes"][0], c2["boxes"][0]) and not ScoreboardWatcher.differs(c1["boxes"][1], c2["boxes"][1]),
		"l'horloge n'influence pas les boites")
	# cout de l'analyse
	for res in [Vector2i(1920, 1080), Vector2i(3840, 2160)]:
		var img := _board(res.x, res.y, 4, 2)
		var t0 := Time.get_ticks_usec()
		for i in 20:
			ScoreboardWatcher.analyze(img)
		print("  analyse %dx%d (zone %dx%d) : %.2f ms" % [res.x, res.y, img.get_width(), img.get_height(), (Time.get_ticks_usec() - t0) / 20000.0])
	# machine a etats
	var w := ScoreboardWatcher.new()
	add_child(w)
	var got: Array = []
	var unk: Array = []
	w.goal.connect(func(m: bool, c: String, a: int, b: int): got.append([m, c, a, b]))
	w.goal_unknown.connect(func(c: String, t: int): unk.append(c))
	w.my_color = "orange"
	var tt := [0.0]  # tableau : les lambdas capturent les variables locales par valeur
	var feed := func(blue: int, orange: int, n: int, show := true):
		for i in n:
			tt[0] += 0.5
			w.ingest(ScoreboardWatcher.analyze(_board(1920, 1080, blue, orange, show, int(tt[0]) % 10)), tt[0])
	feed.call(0, 0, 4)
	feed.call(1, 0, 1)  # image parasite (animation) : 1 seule capture
	feed.call(0, 0, 3)
	_check(got.is_empty(), "changement fugace ignore (stabilite 3 captures)")
	feed.call(0, 1, 4)
	_check(got.size() == 1 and got[0] == [true, "orange", 1, 0], "but orange avec my_color=orange -> mon equipe : %s" % [got])
	feed.call(1, 1, 4)
	_check(got.size() == 2 and got[1] == [false, "blue", 1, 1], "but bleu -> adverse : %s" % [got])
	feed.call(1, 1, 6, false)  # replay / transition 3 s sans tableau
	feed.call(1, 2, 4)
	_check(got.size() == 3 and got[2][0] == true, "but pendant une courte disparition du tableau : detecte")
	feed.call(1, 2, 24, false)  # 12 s sans tableau -> on oublie
	feed.call(0, 0, 4)
	_check(got.size() == 3, "longue absence puis nouveau tableau : pas de faux but")
	feed.call(1, 1, 4)
	_check(got.size() == 3, "les deux boites changent ensemble : pas de but")
	w.my_color = "auto"
	feed.call(1, 2, 4)
	_check(got.size() == 3 and unk == ["orange"], "my_color auto sans equipe connue -> goal_unknown")
	feed.call(1, 2, 8)
	w.known_team = 1
	feed.call(1, 3, 12)
	_check(got.size() == 4 and got[3][0] == true, "auto + equipe apprise par l'API -> but de mon equipe")
	w.queue_free()


func _bench_capture() -> void:
	var w := ScoreboardWatcher.new()
	add_child(w)
	var rect := w.capture_rect()
	var t0 := Time.get_ticks_usec()
	var img := DisplayServer.screen_get_image_rect(rect)
	var t_main := Time.get_ticks_usec() - t0
	_check(img != null and not img.is_empty(), "capture reelle %s -> %s" % [rect, img.get_size() if img else Vector2i()])
	print("  capture sur le thread principal : %.2f ms" % (t_main / 1000.0))
	w.active = true
	w.interval = 0.0
	var costs: Array = []
	var capt: Array = []
	var frames := 0
	var worst_frame := 0
	var last := Time.get_ticks_usec()
	while costs.size() < 20 and frames < 2000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst_frame = maxi(worst_frame, now - last)
		last = now
		frames += 1
		if w.last_cost_usec > 0 and (costs.is_empty() or w.last_cost_usec != costs.back()):
			costs.append(w.last_cost_usec)
			capt.append(w.last_capture_usec)
	w.active = false
	costs.sort()
	capt.sort()
	if costs.size() > 0:
		print("  WorkerThreadPool : capture+analyse mediane %.2f ms (capture seule %.2f ms), max %.2f ms sur %d echantillons"
			% [costs[costs.size() / 2] / 1000.0, capt[capt.size() / 2] / 1000.0, costs.back() / 1000.0, costs.size()])
		print("  pire image du thread principal pendant ce temps : %.2f ms" % (worst_frame / 1000.0))
	_check(costs.size() >= 10, "captures dans le thread de travail")
	w.queue_free()
