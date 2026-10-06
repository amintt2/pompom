extends Node
## Test de bout en bout du SuggestClient : demarre le service local, envoie un faux champ + des textes
## copies, verifie la suggestion, une decision generique, puis l'arret (service + llama-server).
##
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path godot res://tests/suggest_test.tscn [-- --cpu] [-- --no-llm]
## Code de sortie 0 = OK.

var client: SuggestClient
var fails := 0
var got := {}


func _ready() -> void:
	GameState.no_save = true
	var args := OS.get_cmdline_user_args()
	client = SuggestClient.new()
	client.respect_setting = false
	client.use_gpu = not args.has("--cpu")
	client.min_confidence = 0.0
	add_child(client)
	client.suggestion.connect(func(t: String, i: int, k: String): got = {"text": t, "index": i, "kind": k})
	var t0 := Time.get_ticks_msec()
	_check(client.start(), "start() -> %s" % client.last_error)
	while client.state == "starting":
		await get_tree().process_frame
	print("service pret en %d ms (etat %s)" % [Time.get_ticks_msec() - t0, client.state])
	_check(client.state == "ready", "service pret")

	# 1) champ email evident : regles seules, meme si le modele charge encore
	var email_field := {"control_type": "edit", "name": "Adresse e-mail", "process": "chrome.exe",
		"window_title": "Inscription - Club", "is_password": false}
	await _suggest(email_field, ["on se voit demain ?", "lea.martin@gmail.com", "06 12 34 56 78"])
	_check(got.get("index", -1) == 1 and got.get("kind", "") == "email", "email -> %s" % [got])
	_check(str(got.get("text", "")) == "Coller ton email ?", "libelle FR")

	# 2) mot de passe : jamais de suggestion
	got = {}
	await _suggest({"skip": "password"}, ["hunter2", "lea.martin@gmail.com"])
	_check(got.is_empty() and int(client.last_result.get("index", 0)) == -1, "mot de passe ignore")

	if not OS.get_cmdline_user_args().has("--no-llm"):
		var t1 := Time.get_ticks_msec()
		while client.llm_state != "ready" and client.llm_state != "error" and Time.get_ticks_msec() - t1 < 90000:
			await get_tree().create_timer(0.2).timeout
		print("modele : %s (%s) apres %d ms" % [client.llm_state, client.backend, Time.get_ticks_msec() - t0])
		_check(client.llm_state == "ready", "modele charge")
		# 3) cas ambigu : recherche sur une carte -> l'adresse plutot que la phrase (le modele tranche)
		got = {}
		var t2 := Time.get_ticks_msec()
		await _suggest({"control_type": "edit", "name": "Chercher", "process": "chrome.exe",
			"window_title": "Plans - OpenStreetMap", "is_password": false},
			["vélo électrique occasion", "8 place Bellecour 69002 Lyon"])
		print("recherche carte -> %s en %d ms (source %s)" % [got, Time.get_ticks_msec() - t2, client.last_result.get("pick_source", "")])
		_check(got.get("index", -1) == 1 and got.get("kind", "") == "search", "recherche carte -> adresse")
		# 4) decision de jeu generique
		var res := {}
		var id := client.decide("Le compagnon a très faim et sa gamelle est pleine. Que fait-il ?", ["manger", "dormir", "jouer"])
		var t3 := Time.get_ticks_msec()
		while res.is_empty() and Time.get_ticks_msec() - t3 < 5000:
			var r = await client.decided
			if r[0] == id:
				res = {"answer": r[1], "conf": r[2]}
		print("decide -> %s en %d ms" % [res, Time.get_ticks_msec() - t3])
		_check(res.get("answer", "") in ["manger", "dormir", "jouer"], "decision generique")

	# 5) arret : plus aucun processus
	var pid := client._pid
	client.stop()
	await get_tree().create_timer(2.5).timeout
	_check(not OS.is_process_running(pid), "service arrete")
	var out := []
	OS.execute("tasklist", ["/FI", "IMAGENAME eq llama-server.exe", "/NH"], out)
	_check(not str(out).contains("llama-server.exe"), "llama-server arrete")
	print("SUGGEST TEST: ", "OK" if fails == 0 else "%d ECHEC(S)" % fails)
	get_tree().quit(0 if fails == 0 else 1)


func _suggest(field: Dictionary, items: Array) -> void:
	var before := client.last_result
	_check(client.request_suggestion(field, items), "requete envoyee")
	var t := Time.get_ticks_msec()
	while client.last_result == before and Time.get_ticks_msec() - t < 5000:
		await get_tree().process_frame
	await get_tree().process_frame


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1
