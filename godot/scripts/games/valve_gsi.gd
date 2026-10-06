class_name ValveGsiLink
extends Node
## « Game State Integration » officielle de Valve pour Counter-Strike 2 et Dota 2 : le jeu envoie
## lui-meme des requetes HTTP POST (JSON) a une adresse locale declaree dans un fichier
## gamestate_integration_*.cfg. On ecoute donc sur 127.0.0.1:<port> avec un tout petit serveur HTTP.
## Aucune lecture memoire, aucune injection : c'est le mecanisme prevu par Valve (utilise par les HUD de
## tournoi, Overwolf...). Voir docs/game_events.md.
##
## Configuration du jeu (A FAIRE APRES ACCORD DE L'UTILISATEUR) : install_config("cs2") / ("dota2").
## Le jeu doit etre redemarre ; Dota 2 demande EN PLUS l'option de lancement Steam -gamestateintegration
## (Pompom ne la modifie pas : l'utilisateur l'ajoute dans Steam > Dota 2 > Proprietes).
##
## Signal unique : game_event(game, kind, mine, data) avec game = "cs2" | "dota2" et kind dans
##   kill, death, assist, multikill, round_won, round_lost, match_won, match_lost, match_started
## Mort : CS2 = sante du joueur local qui tombe a 0 (ou compteur deaths) ; Dota 2 = hero.alive -> false
## (ou compteur deaths) ; une seule "death" par mort.
## Seuls les evenements du joueur LOCAL sont signales (quand il est mort et regarde un coequipier, le bloc
## "player" decrit ce coequipier : on le reconnait a son steamid different de provider.steamid).

signal game_event(game: String, kind: String, mine: bool, data: Dictionary)
signal connected_changed(ok: bool)  ## au moins un message recu recemment

const DEFAULT_PORT := 47326
const CFG_NAME := "gamestate_integration_pompom.cfg"
const APPID_CS2 := 730
const APPID_DOTA := 570
const MAX_REQ := 2 * 1024 * 1024
const IDLE_CLOSE_SEC := 60.0
const ALIVE_SEC := 45.0  # sans message pendant ce temps (heartbeat 10 s) -> "deconnecte"

var port := DEFAULT_PORT
var token := ""  ## jeton attendu (lu dans le .cfg installe) ; "" = pas de verification
var listening := false
var connected := false

var _server: TCPServer
var _conns: Array = []  # {peer: StreamPeerTCP, buf: PackedByteArray, t: float}
var _poll_t := 0.0
var _last_msg := -1000.0
# etat par jeu
var _cs := {}
var _dota := {}
var _kill_times: Array = []


func _exit_tree() -> void:
	stop()


## Demarre l'ecoute (sans effet si deja en cours). Retourne false si le port est pris.
func start() -> bool:
	if listening:
		return true
	_server = TCPServer.new()
	if _server.listen(port, "127.0.0.1") != OK:
		_server = null
		return false
	listening = true
	if token == "":
		token = read_installed_token()
	return true


func stop() -> void:
	for c in _conns:
		c["peer"].disconnect_from_host()
	_conns.clear()
	if _server:
		_server.stop()
	_server = null
	listening = false
	if connected:
		connected = false
		connected_changed.emit(false)


func _process(delta: float) -> void:
	if not listening:
		return
	_poll_t += delta
	if _poll_t < 0.1:
		return
	_poll_t = 0.0
	var now := _now()
	while _server.is_connection_available():
		var p := _server.take_connection()
		if p:
			_conns.append({"peer": p, "buf": PackedByteArray(), "t": now})
	for c in _conns.duplicate():
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or now - float(c["t"]) > IDLE_CLOSE_SEC:
			peer.disconnect_from_host()
			_conns.erase(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var r := peer.get_partial_data(n)
			if r[0] == OK:
				c["buf"] = c["buf"] + r[1]
				c["t"] = now
		if c["buf"].size() > MAX_REQ:
			peer.disconnect_from_host()
			_conns.erase(c)
			continue
		while true:
			var body = _take_request(c)
			if body == null:
				break
			peer.put_data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n".to_ascii_buffer())
			handle_body(body)
	if connected and now - _last_msg > ALIVE_SEC:
		connected = false
		connected_changed.emit(false)


## Extrait une requete HTTP complete du tampon (corps en texte) ou null.
static func _parse_request(buf: PackedByteArray) -> Dictionary:
	# cherche \r\n\r\n
	var n := buf.size()
	var hdr_end := -1
	for i in range(0, n - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			hdr_end = i
			break
	if hdr_end < 0:
		return {}
	var head := buf.slice(0, hdr_end).get_string_from_ascii()
	var length := 0
	for line in head.split("\r\n"):
		var l := line.to_lower()
		if l.begins_with("content-length:"):
			length = int(l.substr(15).strip_edges())
	var start := hdr_end + 4
	if n - start < length:
		return {}
	return {"body": buf.slice(start, start + length).get_string_from_utf8(), "used": start + length,
		"post": head.begins_with("POST")}


func _take_request(c: Dictionary):
	var req := _parse_request(c["buf"])
	if req.is_empty():
		return null
	c["buf"] = (c["buf"] as PackedByteArray).slice(int(req["used"]))
	return req["body"] if req["post"] else ""


## Traite le JSON envoye par le jeu (public pour les tests).
func handle_body(body: String) -> void:
	if body == "":
		return
	var d = JSON.parse_string(body)
	if typeof(d) != TYPE_DICTIONARY:
		return
	if token != "":
		var a = d.get("auth", {})
		if typeof(a) != TYPE_DICTIONARY or str(a.get("token", "")) != token:
			return
	_last_msg = _now()
	if not connected:
		connected = true
		connected_changed.emit(true)
	var prov = d.get("provider", {})
	var appid := int(prov.get("appid", 0)) if typeof(prov) == TYPE_DICTIONARY else 0
	if appid == APPID_CS2:
		_handle_cs(d)
	elif appid == APPID_DOTA:
		_handle_dota(d)


# ------------------------------------------------------------------ Counter-Strike 2
func _handle_cs(d: Dictionary) -> void:
	var prov: Dictionary = d.get("provider", {})
	var me := str(prov.get("steamid", ""))
	var mp = d.get("map", {})
	var rnd = d.get("round", {})
	var pl = d.get("player", {})
	if typeof(mp) != TYPE_DICTIONARY:
		mp = {}
	if typeof(rnd) != TYPE_DICTIONARY:
		rnd = {}
	var map_key := str(mp.get("name", "")) + "|" + str(mp.get("mode", ""))
	var phase := str(mp.get("phase", ""))
	if _cs.get("map_key", "") != map_key or (phase == "warmup" and _cs.get("phase", "") != "warmup"):
		var had := _cs.has("map_key") and map_key != "|"
		_cs = {"map_key": map_key}
		if had and phase != "":
			game_event.emit("cs2", "match_started", true, {"map": str(mp.get("name", ""))})
	_cs["phase"] = phase
	# joueur local uniquement
	if typeof(pl) == TYPE_DICTIONARY and str(pl.get("steamid", "")) == me and me != "":
		if pl.has("team"):
			_cs["team"] = str(pl.get("team", ""))
		var ms = pl.get("match_stats", {})
		if typeof(ms) == TYPE_DICTIONARY and not ms.is_empty():
			var st = pl.get("state", {})
			var rk := int(st.get("round_kills", 0)) if typeof(st) == TYPE_DICTIONARY else 0
			_stat_delta("cs2", _cs, "kills", int(ms.get("kills", 0)), "kill", {"round_kills": rk})
			# mort : sante qui tombe a 0 (immediat) OU compteur de morts qui monte (filet), sans doublon
			if typeof(st) == TYPE_DICTIONARY and st.has("health"):
				var hp := int(st.get("health", 0))
				if int(_cs.get("hp", -1)) > 0 and hp == 0:
					if _death("cs2", _cs, {"via": "health"}):
						_cs["seen_dead"] = true  # le compteur "deaths" montera plus tard : deja signale
				_cs["hp"] = hp
			var dn := int(ms.get("deaths", 0))
			if _cs.has("deaths") and dn > int(_cs["deaths"]):
				if _cs.get("seen_dead", false):
					_cs["seen_dead"] = false
				else:
					_death("cs2", _cs, {"via": "stats", "total": dn})
			_cs["deaths"] = dn
			_stat_delta("cs2", _cs, "assists", int(ms.get("assists", 0)), "assist", {})
			if rk < int(_cs.get("mk_reported", 0)):
				_cs["mk_reported"] = 0  # nouvelle manche
			if rk >= 3 and rk > int(_cs.get("mk_reported", 0)):
				_cs["mk_reported"] = rk
				game_event.emit("cs2", "multikill", true, {"n": rk})
	# fin de manche
	var rphase := str(rnd.get("phase", ""))
	if rphase == "over" and _cs.get("round_phase", "") != "over":
		var win := str(rnd.get("win_team", ""))
		var team := str(_cs.get("team", ""))
		if win != "" and team != "":
			var mine := win == team
			game_event.emit("cs2", "round_won" if mine else "round_lost", mine,
				{"round": int(mp.get("round", 0)), "win_team": win})
	_cs["round_phase"] = rphase
	# fin de partie
	if phase == "gameover" and not _cs.get("over", false):
		_cs["over"] = true
		var team := str(_cs.get("team", ""))
		var ct := int((mp.get("team_ct", {}) as Dictionary).get("score", 0)) if typeof(mp.get("team_ct")) == TYPE_DICTIONARY else 0
		var t := int((mp.get("team_t", {}) as Dictionary).get("score", 0)) if typeof(mp.get("team_t")) == TYPE_DICTIONARY else 0
		if team != "" and ct != t:
			var won := (ct > t) == (team == "CT")
			game_event.emit("cs2", "match_won" if won else "match_lost", won, {"ct": ct, "t": t})


## Compare une statistique cumulee a la valeur precedente ; la premiere valeur sert de reference.
func _stat_delta(game: String, st: Dictionary, key: String, val: int, kind: String, extra: Dictionary) -> void:
	if not st.has(key):
		st[key] = val
		return
	var prev := int(st[key])
	st[key] = val
	if val > prev:
		var data := extra.duplicate()
		data["count"] = val - prev
		data["total"] = val
		game_event.emit(game, kind, true, data)
		if kind == "kill" and game == "dota2":
			_track_multikill(game, val - prev)


# ------------------------------------------------------------------ Dota 2
func _handle_dota(d: Dictionary) -> void:
	var mp = d.get("map", {})
	var pl = d.get("player", {})
	if typeof(mp) != TYPE_DICTIONARY:
		mp = {}
	var match_id := str(mp.get("matchid", ""))
	if _dota.get("match", "") != match_id:
		var had := _dota.has("match") and match_id != ""
		_dota = {"match": match_id}
		_kill_times.clear()
		if had:
			game_event.emit("dota2", "match_started", true, {})
	# heros (traite avant le compteur) : "alive" passe a false = mort
	var hero = d.get("hero", {})
	if typeof(hero) == TYPE_DICTIONARY and hero.has("alive"):
		var alive := bool(hero.get("alive", true))
		if _dota.has("alive") and bool(_dota["alive"]) and not alive:
			if _death("dota2", _dota, {"via": "hero", "respawn": int(hero.get("respawn_seconds", 0))}):
				_dota["seen_dead"] = true
		_dota["alive"] = alive
	# joueur local : un dictionnaire avec "kills" (en spectateur, "player" contient team2/team3)
	if typeof(pl) == TYPE_DICTIONARY and pl.has("kills"):
		var tn := str(pl.get("team_name", ""))
		if tn != "":
			_dota["team"] = tn
		_stat_delta("dota2", _dota, "kills", int(pl.get("kills", 0)), "kill", {"streak": int(pl.get("kill_streak", 0))})
		var dn := int(pl.get("deaths", 0))
		if _dota.has("deaths") and dn > int(_dota["deaths"]):
			if _dota.get("seen_dead", false):
				_dota["seen_dead"] = false
			else:
				_death("dota2", _dota, {"via": "stats", "total": dn})
		_dota["deaths"] = dn
		_stat_delta("dota2", _dota, "assists", int(pl.get("assists", 0)), "assist", {})
	var gs := str(mp.get("game_state", ""))
	var win := str(mp.get("win_team", "none"))
	if gs == "DOTA_GAMERULES_STATE_POST_GAME" and win in ["radiant", "dire"] and not _dota.get("over", false):
		_dota["over"] = true
		var team := str(_dota.get("team", ""))
		if team != "":
			var won := win == team
			game_event.emit("dota2", "match_won" if won else "match_lost", won, {"win_team": win})


## Une seule mort signalee meme si sante, heros et compteur la voient tous (fenetre de 4 s).
func _death(game: String, st: Dictionary, data: Dictionary) -> bool:
	var now := _now()
	if now - float(st.get("death_t", -100.0)) < 4.0:
		return false
	st["death_t"] = now
	game_event.emit(game, "death", true, data)
	return true


func _track_multikill(game: String, n: int) -> void:
	var now := _now()
	for i in n:
		_kill_times.append(now)
	while not _kill_times.is_empty() and now - float(_kill_times[0]) > 18.0:
		_kill_times.pop_front()
	if _kill_times.size() >= 2:
		game_event.emit(game, "multikill", true, {"n": _kill_times.size()})


var time_offset := 0.0  ## tests : avance l'horloge


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0 + time_offset


# ------------------------------------------------------------------ fichiers de configuration du jeu
## Dossier ou deposer le .cfg ("" si le jeu est introuvable).
static func cfg_dir(game: String) -> String:
	if game == "cs2":
		var d := GamePaths.steam_app_dir("Counter-Strike Global Offensive")
		return d + "/game/csgo/cfg" if d != "" and DirAccess.dir_exists_absolute(d + "/game/csgo/cfg") else ""
	if game == "dota2":
		var d := GamePaths.steam_app_dir("dota 2 beta")
		return d + "/game/dota/cfg/gamestate_integration" if d != "" and DirAccess.dir_exists_absolute(d + "/game/dota/cfg") else ""
	return ""


## Etat (lecture seule) : {found, path, installed}
static func config_status(game: String) -> Dictionary:
	var d := cfg_dir(game)
	var p := d + "/" + CFG_NAME if d != "" else ""
	return {"found": d != "", "path": p, "installed": p != "" and FileAccess.file_exists(p)}


## Contenu du .cfg (format KeyValues de Valve).
static func cfg_text(game: String, p_port: int, p_token: String) -> String:
	var data := ""
	if game == "cs2":
		data = "\t\t\"provider\"            \"1\"\n\t\t\"map\"                 \"1\"\n\t\t\"round\"               \"1\"\n" \
			+ "\t\t\"player_id\"           \"1\"\n\t\t\"player_state\"        \"1\"\n\t\t\"player_match_stats\"  \"1\"\n"
	else:
		data = "\t\t\"provider\"   \"1\"\n\t\t\"map\"        \"1\"\n\t\t\"player\"     \"1\"\n\t\t\"hero\"       \"1\"\n"
	return "\"Pompom\"\n{\n" \
		+ "\t\"uri\"        \"http://127.0.0.1:%d/\"\n" % p_port \
		+ "\t\"timeout\"    \"1.0\"\n\t\"buffer\"     \"0.2\"\n\t\"throttle\"   \"0.5\"\n\t\"heartbeat\"  \"10.0\"\n" \
		+ "\t\"auth\"\n\t{\n\t\t\"token\"    \"%s\"\n\t}\n" % p_token \
		+ "\t\"data\"\n\t{\n" + data + "\t}\n}\n"


## Installe le .cfg (A APPELER UNIQUEMENT APRES ACCORD). Idempotent (reecrit le meme fichier, cree le
## dossier gamestate_integration de Dota 2 si besoin). Retourne "" si OK, sinon un message.
## Le jeu doit etre redemarre ; pour Dota 2 il faut aussi l'option de lancement -gamestateintegration.
static func install_config(game: String, p_port := DEFAULT_PORT) -> String:
	var d := cfg_dir(game)
	if d == "":
		return "Jeu introuvable dans les bibliothèques Steam."
	if not DirAccess.dir_exists_absolute(d) and DirAccess.make_dir_recursive_absolute(d) != OK:
		return "Impossible de créer " + d
	var p := d + "/" + CFG_NAME
	var tok := _token_in(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else ""
	if tok == "":
		tok = read_installed_token()  # meme jeton pour CS2 et Dota 2
	if tok == "":
		tok = "pompom-%08x%08x" % [randi(), randi()]
	return GamePaths.write_text_checked(p, cfg_text(game, p_port, tok))


static func uninstall_config(game: String) -> String:
	var st := config_status(game)
	if not st["installed"]:
		return ""
	return "" if DirAccess.remove_absolute(st["path"]) == OK else "Impossible de supprimer " + str(st["path"])


## Jeton du premier .cfg Pompom installe (CS2 puis Dota 2), "" sinon.
static func read_installed_token() -> String:
	for g in ["cs2", "dota2"]:
		var st := config_status(g)
		if st["installed"]:
			var t := _token_in(FileAccess.get_file_as_string(st["path"]))
			if t != "":
				return t
	return ""


static func _token_in(txt: String) -> String:
	var m := RegEx.create_from_string("\"token\"\\s+\"([^\"]*)\"").search(txt)
	return m.get_string(1) if m else ""
