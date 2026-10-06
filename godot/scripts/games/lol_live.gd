class_name LolLiveLink
extends Node
## League of Legends : « Live Client Data API » officielle de Riot, servie par le client de jeu lui-meme
## sur https://127.0.0.1:2999 pendant une partie (certificat auto-signe Riot -> on accepte le certificat
## UNIQUEMENT pour 127.0.0.1). Rien a configurer, rien a ecrire sur le disque. Voir docs/game_events.md.
##
## Interrogation : 1 fois/s seulement quand League of Legends tourne (`game_present`, pilote par
## GameEvents), 1 fois / 5 s tant que le client ne repond pas. Requetes :
##   /liveclientdata/activeplayername  (une fois) -> "Pseudo#TAG"
##   /liveclientdata/playerlist        (une fois puis toutes les 60 s) -> equipe ORDER/CHAOS, alias
##   /liveclientdata/gamestats         (une fois) -> gameMode ("CLASSIC", "ARAM", "TFT"...)
##   /liveclientdata/eventdata         (chaque seconde) -> Events[] (EventID croissant)
## A la premiere lecture des evenements (connexion en cours de partie), on ne rejoue pas l'historique.
##
## Signal : game_event("lol", kind, mine, data), kinds : kill, death, assist, multikill, first_blood,
## ace, objective, match_won, match_lost, match_started.

signal game_event(game: String, kind: String, mine: bool, data: Dictionary)
signal connected_changed(ok: bool)
signal mode_known(mode: String)  ## gameMode de la partie ("TFT" -> jeu de strategie)

const BASE := "https://127.0.0.1:2999/liveclientdata/"
const POLL_OK := 1.0
const POLL_FAIL := 5.0

var game_present := false
var connected := false
var active_name := ""
var my_team := ""  ## "ORDER" | "CHAOS"
var game_mode := ""

var _aliases := {}  # noms (minuscules) designant l'utilisateur
var _team_of := {}  # alias (minuscules) -> equipe
var _req: HTTPRequest
var _busy := false
var _t := 0.0
var _wait := POLL_OK
var _last_id := -1
var _primed := false
var _plist_t := -1000.0
var _fails := 0


func _ready() -> void:
	_req = HTTPRequest.new()
	_req.timeout = 2.0
	_req.use_threads = false
	_req.set_tls_options(TLSOptions.client_unsafe())  # cert auto-signe, et seulement vers 127.0.0.1
	add_child(_req)
	_req.request_completed.connect(_on_done)


func _process(delta: float) -> void:
	if not game_present and not connected:
		return
	_t += delta
	if _busy or _t < _wait:
		return
	_t = 0.0
	if not game_present and connected:
		_set_connected(false)
		return
	var path := "eventdata"
	if active_name == "":
		path = "activeplayername"
	elif game_mode == "":
		path = "gamestats"
	elif _now() - _plist_t > 60.0:
		path = "playerlist"
	_busy = true
	if _req.request(BASE + path) != OK:
		_busy = false
	else:
		_req.set_meta("path", path)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	var path := str(_req.get_meta("path", ""))
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fails += 1
		if _fails >= 2:
			_wait = POLL_FAIL
			if connected:
				_set_connected(false)
				_reset()
		return
	_fails = 0
	_wait = POLL_OK
	if not connected:
		_set_connected(true)
	handle_response(path, body.get_string_from_utf8())


## Traite une reponse (public pour les tests).
func handle_response(path: String, text: String) -> void:
	var d = JSON.parse_string(text)
	match path:
		"activeplayername":
			if typeof(d) == TYPE_STRING and d != "":
				set_active_name(d)
		"gamestats":
			if typeof(d) == TYPE_DICTIONARY:
				game_mode = str(d.get("gameMode", "?"))
				mode_known.emit(game_mode)
		"playerlist":
			_plist_t = _now()
			if typeof(d) == TYPE_ARRAY:
				set_player_list(d)
		"eventdata":
			if typeof(d) == TYPE_DICTIONARY and typeof(d.get("Events")) == TYPE_ARRAY:
				handle_events(d["Events"])


func set_active_name(n: String) -> void:
	active_name = n
	_aliases.clear()
	_add_alias(n)
	if n.contains("#"):
		_add_alias(n.substr(0, n.find("#")))


func set_player_list(list: Array) -> void:
	for p in list:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var names := [str(p.get("riotId", "")), str(p.get("riotIdGameName", "")), str(p.get("summonerName", ""))]
		var team := str(p.get("team", ""))
		var is_me := false
		for n in names:
			if n != "":
				_team_of[n.to_lower()] = team
				if _aliases.has(n.to_lower()):
					is_me = true
		if is_me:
			my_team = team
			for n in names:
				_add_alias(n)


func _add_alias(n: String) -> void:
	if n.strip_edges() != "":
		_aliases[n.strip_edges().to_lower()] = true


func is_me(n: String) -> bool:
	return _aliases.has(n.strip_edges().to_lower())


func _is_ally(n: String) -> int:  # 1 allie, 0 ennemi, -1 inconnu (sbire, tourelle...)
	var t := str(_team_of.get(n.strip_edges().to_lower(), ""))
	if t == "" or my_team == "":
		return -1
	return 1 if t == my_team else 0


func handle_events(events: Array) -> void:
	var max_id := _last_id
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id := int(e.get("EventID", -1))
		max_id = maxi(max_id, id)
		if not _primed or id <= _last_id:
			continue
		_handle_event(e)
	_last_id = max_id
	_primed = true


func _handle_event(e: Dictionary) -> void:
	var ev := str(e.get("EventName", ""))
	var killer := str(e.get("KillerName", ""))
	match ev:
		"GameStart":
			game_event.emit("lol", "match_started", true, {})
		"ChampionKill":
			var victim := str(e.get("VictimName", ""))
			if is_me(killer):
				game_event.emit("lol", "kill", true, {"victim": victim})
			elif is_me(victim):
				game_event.emit("lol", "death", true, {"killer": killer})
			else:
				for a in e.get("Assisters", []):
					if is_me(str(a)):
						game_event.emit("lol", "assist", true, {"victim": victim})
						break
		"Multikill":
			if is_me(killer):
				game_event.emit("lol", "multikill", true, {"n": int(e.get("KillStreak", 2))})
		"FirstBlood":
			var rec := str(e.get("Recipient", killer))
			if is_me(rec):
				game_event.emit("lol", "first_blood", true, {})
		"Ace":
			var team := str(e.get("AcingTeam", ""))
			if team != "" and my_team != "":
				game_event.emit("lol", "ace", team == my_team, {})
		"DragonKill", "BaronKill", "HeraldKill", "TurretKilled", "InhibKilled", "HordeKill", "AtakhanKill":
			var side := _is_ally(killer)
			if side >= 0:
				game_event.emit("lol", "objective", side == 1, {"what": ev, "killer": killer})
		"GameEnd":
			var res := str(e.get("Result", ""))
			if res == "Win":
				game_event.emit("lol", "match_won", true, {})
			elif res == "Lose":
				game_event.emit("lol", "match_lost", false, {})


func _set_connected(ok: bool) -> void:
	connected = ok
	connected_changed.emit(ok)


func _reset() -> void:
	active_name = ""
	my_team = ""
	game_mode = ""
	_aliases.clear()
	_team_of.clear()
	_last_id = -1
	_primed = false
	_plist_t = -1000.0


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
