extends Node
## Tests sans jeu des autres integrations : Valve GSI (CS2 / Dota 2, y compris une vraie requete HTTP
## POST sur le petit serveur local), LoL Live Client Data, HudWatcher (images de synthese), catalogue,
## et le hub GameEvents (dedoublonnage, game_changed).
##
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --path godot --headless res://tests/game_events_test.tscn
## Code de sortie 0 = OK. N'ecrit AUCUN fichier de jeu.

var fails := 0
var ev: Array = []


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
	print("== Catalogue")
	_test_catalog()
	print("== Counter-Strike 2 (GSI)")
	_test_cs2()
	print("== Dota 2 (GSI)")
	_test_dota()
	print("== Serveur HTTP local (vraie requete POST)")
	await _test_http()
	print("== League of Legends (Live Client Data)")
	_test_lol()
	print("== HudWatcher (Valorant / Fortnite, images de synthese)")
	_test_hud()
	print("== Hub GameEvents")
	await _test_hub()
	if DisplayServer.get_name() != "headless":
		print("== HudWatcher : vraies captures (Valorant puis Fortnite, ecran actuel)")
		await _bench_hud("valorant")
		await _bench_hud("fortnite")
	print("== Etat reel sur ce PC (lecture seule)")
	print("  CS2 : ", ValveGsiLink.config_status("cs2"), "  Dota 2 : ", ValveGsiLink.config_status("dota2"))
	print("RESULTAT : ", "OK" if fails == 0 else "%d ECHEC(S)" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _test_catalog() -> void:
	_check(GameCatalog.GAMES.size() >= 150, "%d jeux au catalogue" % GameCatalog.GAMES.size())
	_check(GameCatalog.lookup("CivilizationVI.exe", "")["genre"] == "strategy", "Civilization VI -> strategy")
	_check(GameCatalog.lookup("rocketleague", "")["genre"] == "sports", "Rocket League -> sports")
	_check(GameCatalog.lookup("chrome", "Play Chess Online - Chess.com - Google Chrome")["genre"] == "strategy", "chess.com dans Chrome -> strategy")
	_check(GameCatalog.lookup("javaw", "Minecraft* 1.21.4")["genre"] == "sandbox", "Minecraft Java (javaw + titre)")
	_check(GameCatalog.lookup("chrome", "YouTube").is_empty() and GameCatalog.lookup("notepad", "").is_empty(), "rien pour YouTube / Notepad")
	_check(GameCatalog.is_thinking_genre("card") and not GameCatalog.is_thinking_genre("fps"), "genres pensifs")


func _collect(sig: Signal) -> void:
	ev.clear()
	sig.connect(func(g: String, k: String, m: bool, d: Dictionary): ev.append([g, k, m, d]))


func _kinds() -> Array:
	return ev.map(func(e): return [e[1], e[2]])


func _cs(me: String, who: String, team: String, kills: int, deaths: int, rk: int, rphase := "live",
		win := "", mphase := "live", ct := 0, t := 0, hp := 100) -> String:
	return JSON.stringify({
		"provider": {"name": "Counter-Strike 2", "appid": 730, "version": 14000, "steamid": me, "timestamp": 1},
		"map": {"mode": "competitive", "name": "de_dust2", "phase": mphase, "round": 3,
			"team_ct": {"score": ct}, "team_t": {"score": t}},
		"round": {"phase": rphase, "win_team": win} if win != "" else {"phase": rphase},
		"player": {"steamid": who, "name": "x", "team": team, "activity": "playing",
			"state": {"health": hp, "round_kills": rk},
			"match_stats": {"kills": kills, "assists": 0, "deaths": deaths, "mvps": 0, "score": 0}}})


func _test_cs2() -> void:
	var v := ValveGsiLink.new()
	add_child(v)
	_collect(v.game_event)
	var me := "7656119800000001"
	v.handle_body(_cs(me, me, "CT", 0, 0, 0))
	v.handle_body(_cs(me, me, "CT", 1, 0, 1))
	v.handle_body(_cs(me, me, "CT", 2, 0, 2))
	v.handle_body(_cs(me, me, "CT", 3, 0, 3))
	v.handle_body(_cs(me, me, "CT", 3, 0, 3))
	_check(_kinds() == [["kill", true], ["kill", true], ["kill", true], ["multikill", true]], "3 kills + multikill(3) une seule fois : %s" % [_kinds()])
	ev.clear()
	v.handle_body(_cs(me, me, "CT", 3, 1, 3))
	v.handle_body(_cs(me, "7656119899999999", "CT", 9, 0, 2))  # mort : on regarde un coequipier
	_check(_kinds() == [["death", true]], "mort comptee, stats du coequipier observe ignorees : %s" % [_kinds()])
	ev.clear()
	v.handle_body(_cs(me, "7656119899999999", "CT", 9, 0, 2, "over", "CT"))
	v.handle_body(_cs(me, "7656119899999999", "CT", 9, 0, 2, "over", "CT"))
	v.handle_body(_cs(me, me, "CT", 3, 1, 0, "freezetime"))
	v.handle_body(_cs(me, me, "CT", 3, 1, 0, "over", "T"))
	_check(_kinds() == [["round_won", true], ["round_lost", false]], "manche gagnee puis perdue : %s" % [_kinds()])
	ev.clear()
	v.handle_body(_cs(me, me, "T", 3, 1, 0, "over", "T", "gameover", 13, 9))  # changement de camp a la mi-temps
	_check(_kinds() == [["match_lost", false]], "fin de partie perdue (13-9 pour CT, je suis T) : %s" % [_kinds()])
	# mort detectee par la sante (immediat), puis compteur "deaths" a la manche suivante : un seul evenement
	v.time_offset += 30.0
	ev.clear()
	v.handle_body(_cs(me, me, "T", 3, 1, 0, "live", "", "live", 0, 0, 40))
	v.handle_body(_cs(me, me, "T", 3, 1, 0, "live", "", "live", 0, 0, 0))
	v.handle_body(_cs(me, "7656119899999999", "T", 7, 0, 1))  # on observe un coequipier
	v.handle_body(_cs(me, me, "T", 3, 2, 0, "freezetime"))  # manche suivante : deaths 1 -> 2
	_check(_kinds() == [["death", true]] and ev[0][3].get("via") == "health", "mort par la sante, pas de doublon ensuite : %s" % [_kinds()])
	# jeton
	v.token = "secret"
	ev.clear()
	v.handle_body(_cs(me, me, "T", 5, 1, 0))
	_check(ev.is_empty(), "jeton absent -> message ignore")
	v.queue_free()
	# fichier cfg genere
	var txt := ValveGsiLink.cfg_text("cs2", 47326, "tok123")
	_check(txt.contains("\"uri\"        \"http://127.0.0.1:47326/\"") and txt.contains("\"player_match_stats\"") and ValveGsiLink._token_in(txt) == "tok123",
		"cfg CS2 : uri, donnees, jeton")


func _test_dota() -> void:
	var v := ValveGsiLink.new()
	add_child(v)
	_collect(v.game_event)
	var mk := func(kills: int, deaths: int, assists: int, gs := "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS", win := "none", alive := true) -> String:
		return JSON.stringify({"provider": {"name": "Dota 2", "appid": 570, "version": 47, "timestamp": 1},
			"hero": {"id": 1, "name": "npc_dota_hero_axe", "alive": alive, "respawn_seconds": 0 if alive else 12},
			"map": {"name": "start", "matchid": "777", "game_time": 600, "game_state": gs, "win_team": win,
				"radiant_score": 5, "dire_score": 3},
			"player": {"steamid": "1", "name": "moi", "activity": "playing", "kills": kills, "deaths": deaths,
				"assists": assists, "kill_streak": kills, "team_name": "dire"}})
	v.handle_body(mk.call(0, 0, 0))
	v.handle_body(mk.call(1, 0, 0))
	v.handle_body(mk.call(2, 0, 1))
	v.handle_body(mk.call(2, 1, 1))
	_check(_kinds() == [["kill", true], ["kill", true], ["multikill", true], ["assist", true], ["death", true]],
		"kill, double kill rapide, assist, mort : %s" % [_kinds()])
	ev.clear()
	v.time_offset += 30.0
	v.handle_body(mk.call(2, 1, 1, "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS", "none", false))  # heros mort...
	v.handle_body(mk.call(2, 2, 1, "DOTA_GAMERULES_STATE_GAME_IN_PROGRESS", "none", false))  # ...puis compteur
	v.handle_body(mk.call(2, 2, 1))
	_check(_kinds() == [["death", true]] and ev[0][3].get("via") == "hero", "Dota : hero.alive -> false = une mort : %s" % [_kinds()])
	ev.clear()
	v.handle_body(mk.call(2, 1, 1, "DOTA_GAMERULES_STATE_POST_GAME", "dire"))
	v.handle_body(mk.call(2, 1, 1, "DOTA_GAMERULES_STATE_POST_GAME", "dire"))
	_check(_kinds() == [["match_won", true]], "victoire (dire) une seule fois : %s" % [_kinds()])
	ev.clear()
	v.handle_body(JSON.stringify({"provider": {"appid": 570}, "map": {"matchid": "777"},
		"player": {"team2": {"player0": {"kills": 9}}}}))
	_check(ev.is_empty(), "mode spectateur (team2/team3) ignore")
	v.queue_free()


func _test_http() -> void:
	var v := ValveGsiLink.new()
	v.port = 47399
	add_child(v)
	_collect(v.game_event)
	_check(v.start(), "ecoute sur 127.0.0.1:47399")
	var me := "1"
	var bodies := [_cs(me, me, "CT", 0, 0, 0), _cs(me, me, "CT", 1, 0, 1)]
	var c := StreamPeerTCP.new()
	c.connect_to_host("127.0.0.1", 47399)
	var t0 := Time.get_ticks_msec()
	while c.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 2000:
		c.poll()
		await get_tree().process_frame
	# deux requetes keep-alive envoyees d'un coup, la 2e coupee en deux paquets
	var raw := ""
	for b in bodies:
		var u: PackedByteArray = b.to_utf8_buffer()
		raw += "POST / HTTP/1.1\r\nHost: 127.0.0.1:47399\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s" % [u.size(), b]
	var rb := raw.to_utf8_buffer()
	c.put_data(rb.slice(0, rb.size() - 40))
	for i in 10:
		await get_tree().process_frame
	c.put_data(rb.slice(rb.size() - 40))
	var replies := ""
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2000 and replies.count("200 OK") < 2:
		await get_tree().process_frame
		c.poll()
		var n := c.get_available_bytes()
		if n > 0:
			replies += c.get_utf8_string(n)
	_check(replies.count("HTTP/1.1 200 OK") == 2, "deux reponses 200")
	_check(_kinds() == [["kill", true]], "kill recu via HTTP : %s" % [_kinds()])
	c.disconnect_from_host()
	v.stop()
	v.queue_free()


func _test_lol() -> void:
	var l := LolLiveLink.new()
	add_child(l)
	_collect(l.game_event)
	l.handle_response("activeplayername", "\"Amin#EUW\"")
	l.handle_response("playerlist", JSON.stringify([
		{"championName": "Annie", "riotId": "Amin#EUW", "riotIdGameName": "Amin", "summonerName": "Amin", "team": "ORDER"},
		{"championName": "Garen", "riotId": "Ally#EUW", "riotIdGameName": "Ally", "summonerName": "Ally", "team": "ORDER"},
		{"championName": "Zed", "riotId": "Foe#EUW", "riotIdGameName": "Foe", "summonerName": "Foe", "team": "CHAOS"}]))
	_check(l.my_team == "ORDER", "equipe ORDER")
	# premiere lecture : historique ignore
	l.handle_response("eventdata", JSON.stringify({"Events": [{"EventID": 0, "EventName": "GameStart", "EventTime": 0.0},
		{"EventID": 1, "EventName": "ChampionKill", "KillerName": "Amin", "VictimName": "Foe", "Assisters": []}]}))
	_check(ev.is_empty(), "historique a la connexion non rejoue")
	var evs := [{"EventID": 0, "EventName": "GameStart"},
		{"EventID": 1, "EventName": "ChampionKill", "KillerName": "Amin", "VictimName": "Foe", "Assisters": []},
		{"EventID": 2, "EventName": "ChampionKill", "KillerName": "Amin", "VictimName": "Foe", "Assisters": []},
		{"EventID": 3, "EventName": "Multikill", "KillerName": "Amin", "KillStreak": 2},
		{"EventID": 4, "EventName": "ChampionKill", "KillerName": "Foe", "VictimName": "Amin", "Assisters": []},
		{"EventID": 5, "EventName": "ChampionKill", "KillerName": "Ally", "VictimName": "Foe", "Assisters": ["Amin"]},
		{"EventID": 6, "EventName": "DragonKill", "KillerName": "Foe", "DragonType": "Fire", "Stolen": "False", "Assisters": []},
		{"EventID": 7, "EventName": "TurretKilled", "KillerName": "Minion_T100L0S20N0001", "TurretKilled": "Turret_T2_L_03_A", "Assisters": []},
		{"EventID": 8, "EventName": "Ace", "Acer": "Ally", "AcingTeam": "ORDER"},
		{"EventID": 9, "EventName": "GameEnd", "Result": "Win"}]
	l.handle_response("eventdata", JSON.stringify({"Events": evs}))
	_check(_kinds() == [["kill", true], ["multikill", true], ["death", true], ["assist", true], ["objective", false], ["ace", true], ["match_won", true]],
		"nouveaux evenements seulement, du point de vue de l'utilisateur : %s" % [_kinds()])
	ev.clear()
	l.handle_response("eventdata", JSON.stringify({"Events": evs}))
	_check(ev.is_empty(), "pas de doublon au sondage suivant")
	l.queue_free()


## Image "ecran" avec, eventuellement, un bandeau Valorant / compteur Fortnite dessine aux zones.
func _screen_img(g: String, scr: Rect2i, key: String, draw: int) -> Image:
	var h := HudWatcher.new()
	var rects := h.screen_rects(g, scr)
	h.free()
	var r: Rect2i = rects[key]
	var img := Image.create(r.size.x, r.size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.25, 0.3, 0.35))
	if draw > 0:
		# motif blanc different selon `draw` (chevrons du bandeau / chiffres du compteur)
		for i in draw:
			img.fill_rect(Rect2i(r.size.x * (i + 1) / (draw + 2), r.size.y / 5, maxi(2, r.size.x / 8), r.size.y * 3 / 5), Color.WHITE)
	return img


func _test_hud() -> void:
	_check(HudWatcher.profile_for("VALORANT-Win64-Shipping") == "valorant" and HudWatcher.profile_for("cs2") == "", "profils par processus")
	# ancrage : ultra-large -> boite 16:9 centree ; 16:10 -> largeur de l'ecran
	var uw := HudWatcher.rel_to_screen([0.5, 0.5, 0.1, 0.1], "center", Rect2i(0, 0, 3440, 1440))
	_check(absi(uw.position.x - (3440 - 2560) / 2 - 1280) <= 1, "21:9 : zone centree dans une boite 16:9 (%s)" % uw)
	var rt := HudWatcher.rel_to_screen([0.9, 0.1, 0.05, 0.05], "right", Rect2i(1920, 0, 3440, 1440))
	_check(rt.position.x == 1920 + 880 + 2304, "21:9 ancre a droite, 2e ecran (%s)" % rt)
	var w := HudWatcher.new()
	add_child(w)
	_collect(w.hud_event)
	w.set_game("valorant")
	var scr := Rect2i(0, 0, 1920, 1080)
	var t := 0.0
	var probe_i := 0
	var seq := [0, 0, 1, 1, 1, 0, 0, 1, 2, 2, 2, 0, 0]  # rien, kill, fin, kill, 2e kill enchaine, fin
	for d in seq:
		t += 0.33
		probe_i += 1
		var probe := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		probe.fill(Color(randf(), 0.5, 0.5))
		var r := HudWatcher.analyze_all("valorant", {"kill_banner": _screen_img("valorant", scr, "kill_banner", d * 2), "_probe": probe})
		w.ingest(r, t)
	_check(_kinds() == [["kill", true], ["kill", true], ["kill", true]], "Valorant : 3 eliminations (dont 1 enchainee) : %s" % [_kinds()])
	_check(w.capture_status == "ok", "capture ok")
	# image noire -> statut "black"
	for i in 8:
		t += 0.33
		var black := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		w.ingest({"_probe": HudWatcher.analyze_all("valorant", {"_probe": black})["_probe"]}, t)
	_check(w.capture_status == "black" and w.status_hint().contains("plein écran fenêtré"), "capture noire -> conseil plein ecran fenetre")
	# Valorant : bandeau de mort (rouge) -> une seule "death" meme s'il reste affiche
	w.set_game("valorant")
	ev.clear()
	for d in [0, 0, 1, 1, 1, 1, 0, 0]:
		t += 0.33
		var probe := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		probe.fill(Color(randf(), 0.5, 0.5))
		var dimg := _screen_img("valorant", scr, "death_banner", 0)
		if d == 1:
			dimg.fill_rect(Rect2i(dimg.get_width() / 4, dimg.get_height() / 4, dimg.get_width() / 3, dimg.get_height() / 2), Color(0.9, 0.2, 0.25))
		w.ingest(HudWatcher.analyze_all("valorant", {"death_banner": dimg,
			"kill_banner": _screen_img("valorant", scr, "kill_banner", 0), "_probe": probe}), t)
	_check(_kinds() == [["death", true]], "Valorant : bandeau « tué par » -> 1 mort : %s" % [_kinds()])
	# zone experimentale « image desaturee » : coupee par defaut, activable
	_check(not w.screen_rects("valorant", scr).has("grey_view"), "zone grise experimentale coupee par defaut")
	w.enabled_extra["grey_view"] = true
	ev.clear()
	t += 10.0
	for sat in [0.8, 0.8, 0.0, 0.0, 0.0]:
		t += 0.33
		var probe := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		probe.fill(Color(randf(), 0.5, 0.5))
		var g := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		g.fill(Color(0.5, 0.5, 0.5).lerp(Color(0.9, 0.3, 0.1), sat))
		w.ingest(HudWatcher.analyze_all("valorant", {"grey_view": g, "_probe": probe}), t)
	_check(_kinds() == [["death", true]], "image qui devient grise -> mort (experimental) : %s" % [_kinds()])
	w.enabled_extra.clear()
	# Fortnite : compteur qui change
	w.set_game("fortnite")
	ev.clear()
	for d in [1, 1, 1, 2, 2, 2, 3, 3]:
		t += 0.33
		var probe := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		probe.fill(Color(randf(), 0.5, 0.5))
		w.ingest(HudWatcher.analyze_all("fortnite", {"elims": _screen_img("fortnite", scr, "elims", d),
			"elim_text": _screen_img("fortnite", scr, "elim_text", 0), "_probe": probe}), t)
	_check(_kinds() == [["kill", true], ["kill", true]], "Fortnite : compteur 1->2->3 = 2 eliminations : %s" % [_kinds()])
	ev.clear()
	for d in [0, 0, 3, 3, 3, 0]:
		t += 0.33
		var probe := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		probe.fill(Color(randf(), 0.5, 0.5))
		w.ingest(HudWatcher.analyze_all("fortnite", {"spectate_banner": _screen_img("fortnite", scr, "spectate_banner", d),
			"elims": _screen_img("fortnite", scr, "elims", 3), "_probe": probe}), t)
	_check(_kinds() == [["death", true]], "Fortnite : « éliminé par » / observation -> 1 mort : %s" % [_kinds()])
	# cout d'analyse (sans capture)
	var imgs := {"elims": _screen_img("fortnite", Rect2i(0, 0, 3840, 2160), "elims", 2),
		"elim_text": _screen_img("fortnite", Rect2i(0, 0, 3840, 2160), "elim_text", 0)}
	var t0 := Time.get_ticks_usec()
	for i in 50:
		HudWatcher.analyze_all("fortnite", imgs)
	print("  analyse Fortnite 4K (2 zones) : %.3f ms" % ((Time.get_ticks_usec() - t0) / 50000.0))
	w.queue_free()


func _test_hub() -> void:
	var hub := GameEvents.new()
	add_child(hub)
	var got: Array = []
	var changes: Array = []
	hub.event.connect(func(k: String, m: bool, d: Dictionary): got.append([k, m, d.get("game", ""), d.get("source", "")]))
	hub.game_changed.connect(func(p: String, g: String): changes.append([p, g]))
	hub.proc_override = "civilizationvi"
	var t0 := Time.get_ticks_msec()
	while changes.is_empty() and Time.get_ticks_msec() - t0 < 4000:
		await get_tree().process_frame
	_check(changes == [["civilizationvi", "strategy"]], "game_changed(civilizationvi, strategy) : %s" % [changes])
	# un but vu par l'API puis par l'ecran -> un seul evenement
	hub.rl.force_color = "orange"
	hub.rl.handle_event("UpdateState", {"Players": [], "Game": {"Teams": [{"TeamNum": 0, "Score": 0}, {"TeamNum": 1, "Score": 0}]}})
	hub.rl.handle_event("GoalScored", {"Scorer": {"Name": "Moi", "TeamNum": 1}})
	hub.scoreboard.goal.emit(true, "orange", 1, 0)
	_check(got.size() == 1 and got[0] == ["goal", true, "rocket_league", "api"], "but API + ecran dedoublonne : %s" % [got])
	hub.lol.game_event.emit("lol", "kill", true, {})
	_check(got.size() == 2 and got[1] == ["kill", true, "lol", "api"], "kill LoL relaye : %s" % [got.back()])
	hub.queue_free()


func _bench_hud(g: String) -> void:
	var w := HudWatcher.new()
	add_child(w)
	w.set_game(g)
	w.interval = 0.0
	w.active = true
	var costs: Array = []
	var worst := 0
	var last := Time.get_ticks_usec()
	var frames := 0
	while costs.size() < 20 and frames < 3000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxi(worst, now - last)
		last = now
		frames += 1
		if w.last_cost_usec > 0 and (costs.is_empty() or costs.back() != w.last_cost_usec):
			costs.append(w.last_cost_usec)
	w.active = false
	costs.sort()
	if costs.size() > 0:
		var n := w.screen_rects(g, Rect2i(DisplayServer.screen_get_position(0), DisplayServer.screen_get_size(0))).size()
		print("  %s : %d petites captures + analyse par echantillon : mediane %.2f ms, max %.2f ms (thread de travail) ; statut %s ; pire image principale %.2f ms"
			% [g, n, costs[costs.size() / 2] / 1000.0, costs.back() / 1000.0, w.capture_status, worst / 1000.0])
	_check(costs.size() >= 10, "%s : echantillons mesures" % g)
	w.queue_free()
