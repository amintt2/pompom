class_name RocketLeagueLink
extends Node
## Lien avec la « Stats API » officielle de Rocket League (Psyonix, 2026) : le jeu ouvre une socket
## TCP locale (127.0.0.1:49123 par defaut) et y diffuse des messages JSON concatenes, SANS separateur :
##   {"Event":"UpdateState","Data":"{\"Players\":[...],\"Game\":{...}}"}{"Event":"GoalScored",...}...
## "Data" est une chaine JSON sur les versions actuelles (objet dans la doc publiee) : on accepte les deux.
## Voir docs/rocket_league.md (sources, champs, limites).
##
## Cout : aucune lecture memoire, aucune injection ; une socket locale lue ~20 fois/s au plus, quelques
## dizaines de micro-secondes par message. Tant que Rocket League n'est pas vu au premier plan, on ne
## tente meme pas de se connecter.
##
## Determination de « mon equipe » (par ordre de priorite) :
##   1. reglage force `force_color` ("blue"/"orange") ;
##   2. nom de joueur indique (`player_name`) present dans Players[] ;
##   3. Game.Target hors replay : quand on joue, la camera suit sa propre voiture -> Target = soi.
##      On garde le nom le plus souvent cible pendant la session (vote), robuste aux glitchs ;
##   4. indice faible : champs "Boost" visibles seulement pour certains joueurs (non documente).
## Si l'equipe reste inconnue, on emet `goal_unknown` au lieu de `goal` (pas de fausse joie / tristesse).
##
## Utilisation : ajouter le noeud, mettre `game_present = true` quand Rocket League tourne (fait par
## GameEvents). Pour activer l'API dans le jeu : stats_api_status() puis, APRES accord de l'utilisateur,
## enable_stats_api(). Le jeu doit etre redemarre ensuite (doc officielle).

signal goal(my_team: bool, scorer: String, score_mine: int, score_theirs: int)
signal goal_unknown(scorer: String, team_num: int)  ## but marque mais equipe de l'utilisateur inconnue
signal match_started
signal match_ended(won: bool)
signal score_changed(mine: int, theirs: int)
signal connected_changed(ok: bool)
signal team_known(team_num: int)  ## 0 = bleu, 1 = orange (emis quand l'equipe devient connue / change)

const HOST := "127.0.0.1"
const DEFAULT_PORT := 49123
const SECTION := "TAGame.MatchStatsExporter_TA"
const DEFAULT_RATE := 5  ## paquets UpdateState / s : les evenements (buts...) partent de toute facon a l'instant
const RETRY_SEC := 4.0
const MAX_BUF := 512 * 1024
const FALLBACK_GOAL_DELAY := 1.5  # score monte sans GoalScored -> but deduit apres ce delai

var port := DEFAULT_PORT
var game_present := false:  ## vrai quand Rocket League tourne (pilote par GameEvents)
	set(v):
		game_present = v
		if v:
			_retry = minf(_retry, 0.3)
var force_color := "auto"  ## "auto" | "blue" | "orange"
var player_name := ""  ## optionnel : pseudo de l'utilisateur dans Rocket League
var update_min_interval := 0.4  ## UpdateState traites au plus 2,5 fois/s (0 = tous, pour les tests)

var connected := false
var my_team := -1  ## 0 bleu, 1 orange, -1 inconnu
var my_name := ""  ## nom deduit (ou impose)
var scores := [0, 0]  ## bleu, orange
var in_match := false
var packets := 0  ## messages decodes (diagnostic)
var last_update := {}  ## dernier Data d'UpdateState

var _tcp: StreamPeerTCP
var _retry := 0.0
var _poll_t := 0.0
var _buf := ""  # texte en attente de decoupage
var _carry := PackedByteArray()  # fin de caractere UTF-8 coupe entre deux lectures
var _json := JSON.new()
var _json_inner := JSON.new()
var _target_votes := {}  # nom -> nombre d'UpdateState ou il etait la cible
var _players := {}  # nom -> TeamNum (dernier UpdateState)
var _emitted := [0, 0]  # buts deja signales par equipe
var _baseline := false  # premier UpdateState recu (connexion en cours de match)
var _pending := [-1.0, -1.0]  # instant ou un score a monte sans GoalScored
var _ended := false
var _parsed_text := ""  # dernier message deja decode (evite de le decoder deux fois)
var _parsed = null
var _last_update_t := -100.0


func _ready() -> void:
	set_process(true)


func _exit_tree() -> void:
	_close()


func _process(delta: float) -> void:
	if _tcp == null:
		if not game_present:
			return
		_retry -= delta
		if _retry <= 0.0:
			_retry = RETRY_SEC
			_open()
		return
	_poll_t += delta
	if _poll_t < 0.05:  # 20 Hz suffisent largement
		return
	_poll_t = 0.0
	_tcp.poll()
	var st := _tcp.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_close()
		return
	if not connected:
		connected = true
		connected_changed.emit(true)
	var n := _tcp.get_available_bytes()
	if n > 0:
		var r := _tcp.get_partial_data(n)
		if r[0] == OK:
			feed(r[1])
	_check_pending()


func _open() -> void:
	_tcp = StreamPeerTCP.new()
	if _tcp.connect_to_host(HOST, port) != OK:
		_tcp = null


func _close() -> void:
	if _tcp:
		_tcp.disconnect_from_host()
	_tcp = null
	_buf = ""
	_carry = PackedByteArray()
	if connected:
		connected = false
		connected_changed.emit(false)


# ------------------------------------------------------------------ decoupage du flux
## Donne des octets bruts recus de la socket (morceaux de n'importe quelle taille).
func feed(bytes: PackedByteArray) -> void:
	if _carry.size() > 0:
		bytes = _carry + bytes
		_carry = PackedByteArray()
	var cut := _utf8_complete_len(bytes)
	if cut < bytes.size():
		_carry = bytes.slice(cut)
		bytes = bytes.slice(0, cut)
	feed_text(bytes.get_string_from_utf8())


## Variante texte (tests).
func feed_text(s: String) -> void:
	_buf += s
	if _buf.length() > MAX_BUF:
		_buf = _buf.substr(_buf.length() - MAX_BUF / 2)  # flux corrompu : on resynchronise
	for msg in _drain():
		_handle_message(msg)


## Longueur du prefixe ne contenant que des caracteres UTF-8 complets.
static func _utf8_complete_len(b: PackedByteArray) -> int:
	var n := b.size()
	var i := n - 1
	var back := 0
	while i >= 0 and back < 4:
		var c := b[i]
		if c & 0x80 == 0:
			return n
		if c & 0xC0 == 0xC0:  # octet de tete
			var need := 2 if c & 0xE0 == 0xC0 else (3 if c & 0xF0 == 0xE0 else 4)
			return n if n - i >= need else i
		i -= 1
		back += 1
	return n


## Extrait les objets JSON complets du tampon. Chemin rapide : chaque message commence par {"Event"
## (le "Data" imbrique est une chaine echappee, donc ce motif n'apparait qu'en tete de message).
## Sinon (format avec espaces, autre ordre de cles), scanner generique accolades/chaines.
func _drain() -> Array:
	var out: Array = []
	var start := _buf.find("{\"Event\"")
	if start >= 0:
		while true:
			var nxt := _buf.find("{\"Event\"", start + 1)
			if nxt < 0:
				break
			out.append(_buf.substr(start, nxt - start))
			start = nxt
		var last := _buf.substr(start)
		# n'essaie de decoder la fin que si elle peut etre complete (evite un parse inutile par lecture)
		if last.strip_edges(false, true).ends_with("}") and _json.parse(last) == OK:
			_parsed_text = last
			_parsed = _json.data
			out.append(last)
			_buf = ""
		else:
			_buf = last  # incomplet : on attend la suite
		return out
	return _drain_generic()


func _drain_generic() -> Array:
	var out: Array = []
	var cursor := 0
	var n := _buf.length()
	while cursor < n:
		var start := _buf.find("{", cursor)
		if start < 0:
			cursor = n
			break
		var depth := 0
		var in_str := false
		var esc := false
		var end := -1
		for i in range(start, n):
			var c := _buf.unicode_at(i)
			if esc:
				esc = false
			elif in_str:
				if c == 92:  # \
					esc = true
				elif c == 34:  # "
					in_str = false
			elif c == 34:
				in_str = true
			elif c == 123:  # {
				depth += 1
			elif c == 125:  # }
				depth -= 1
				if depth == 0:
					end = i
					break
		if end < 0:
			cursor = start
			break
		out.append(_buf.substr(start, end - start + 1))
		cursor = end + 1
	_buf = _buf.substr(cursor)
	return out


# ------------------------------------------------------------------ messages
func _handle_message(text: String) -> void:
	if update_min_interval > 0.0 and text.begins_with("{\"Event\":\"UpdateState\"") and text != _parsed_text:
		# UpdateState arrive jusqu'a PacketSendRate fois/s ; 2-3 par seconde suffisent (score, cible)
		var now := _now()
		if now - _last_update_t < update_min_interval:
			packets += 1
			return
		_last_update_t = now
	var env = null
	if text == _parsed_text:
		env = _parsed  # deja decode par _drain
	elif _json.parse(text) == OK:
		env = _json.data
	_parsed_text = ""
	_parsed = null
	if typeof(env) != TYPE_DICTIONARY:
		return
	var ev := str(env.get("Event", ""))
	if ev == "":
		return
	var data = env.get("Data", {})
	if typeof(data) == TYPE_STRING:
		# instance JSON reutilisee : nettement plus rapide que JSON.parse_string sur ce volume
		data = _json_inner.data if data != "" and _json_inner.parse(data) == OK else {}
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	packets += 1
	handle_event(ev, data)


## Point d'entree d'un evenement deja decode (public pour les tests).
func handle_event(ev: String, d: Dictionary) -> void:
	match ev:
		"UpdateState":
			_on_update(d)
		"GoalScored":
			_on_goal(d)
		"MatchCreated":
			_reset_match()
		"MatchInitialized":
			_reset_match()
			in_match = true
			match_started.emit()
		"MatchEnded":
			_on_match_ended(int(d.get("WinnerTeamNum", -1)))
		"MatchDestroyed":
			in_match = false
			_reset_match()


func _reset_match() -> void:
	scores = [0, 0]
	_emitted = [0, 0]
	_pending = [-1.0, -1.0]
	_baseline = false
	_ended = false
	_players.clear()
	my_team = -1


func _on_update(d: Dictionary) -> void:
	last_update = d
	var game: Dictionary = d.get("Game", {}) if typeof(d.get("Game")) == TYPE_DICTIONARY else {}
	# joueurs
	var pl = d.get("Players", [])
	var boost_teams := {}
	var no_boost := 0
	if typeof(pl) == TYPE_ARRAY:
		_players.clear()
		for p in pl:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			_players[str(p.get("Name", ""))] = int(p.get("TeamNum", -1))
			if p.has("Boost"):
				boost_teams[int(p.get("TeamNum", -1))] = true
			else:
				no_boost += 1
	# cible de la camera (= soi quand on joue), hors replays
	var replay := bool(game.get("bReplay", false))
	var tgt = game.get("Target", {})
	if not replay and bool(game.get("bHasTarget", false)) and typeof(tgt) == TYPE_DICTIONARY:
		var tn := str(tgt.get("Name", ""))
		if tn != "":
			_target_votes[tn] = int(_target_votes.get(tn, 0)) + 1
			if _players.is_empty():
				_players[tn] = int(tgt.get("TeamNum", -1))
	_update_my_team(boost_teams, no_boost)
	# scores
	var teams = game.get("Teams", [])
	if typeof(teams) == TYPE_ARRAY:
		var s := scores.duplicate()
		for t in teams:
			if typeof(t) == TYPE_DICTIONARY:
				var num := int(t.get("TeamNum", -1))
				if num == 0 or num == 1:
					s[num] = int(t.get("Score", 0))
		_apply_scores(s)
	if not _ended and bool(game.get("bHasWinner", false)) and str(game.get("Winner", "")) != "":
		# filet de securite si MatchEnded est manque : on retrouve l'equipe gagnante par son nom
		for t in (teams if typeof(teams) == TYPE_ARRAY else []):
			if typeof(t) == TYPE_DICTIONARY and str(t.get("Name", "")) == str(game.get("Winner", "")):
				_on_match_ended(int(t.get("TeamNum", -1)))


func _update_my_team(boost_teams: Dictionary, no_boost: int) -> void:
	var team := -1
	if force_color == "blue":
		team = 0
	elif force_color == "orange":
		team = 1
	else:
		var pname := player_name.strip_edges()
		if pname == "" or not _players.has(pname):
			pname = _best_target()
		if pname != "" and _players.has(pname):
			my_name = pname
			team = int(_players[pname])
		elif pname != "":
			my_name = pname
		if team < 0 and boost_teams.size() == 1 and no_boost > 0:
			team = int(boost_teams.keys()[0])  # indice faible (champ Boost visible pour son equipe)
	if team != -1 and team != my_team:
		my_team = team
		team_known.emit(team)
		if _baseline:
			score_changed.emit(scores[my_team], scores[1 - my_team])


func _best_target() -> String:
	var best := ""
	var bc := 0
	for k in _target_votes:
		if int(_target_votes[k]) > bc:
			bc = int(_target_votes[k])
			best = k
	return best


func _apply_scores(s: Array) -> void:
	if not _baseline:
		_baseline = true
		scores = s
		_emitted = s.duplicate()
		if my_team >= 0:
			score_changed.emit(scores[my_team], scores[1 - my_team])
		return
	var changed := s != scores
	scores = s
	for t in 2:
		if s[t] < _emitted[t]:
			_emitted[t] = s[t]  # nouveau match / remise a zero
		elif s[t] > _emitted[t] and _pending[t] < 0.0:
			_pending[t] = _now()
	if changed and my_team >= 0:
		score_changed.emit(scores[my_team], scores[1 - my_team])


func _check_pending() -> void:
	for t in 2:
		if _pending[t] >= 0.0 and _now() - _pending[t] >= FALLBACK_GOAL_DELAY:
			_pending[t] = -1.0
			if scores[t] > _emitted[t]:
				_emitted[t] = scores[t]
				_emit_goal(t, "")


func _on_goal(d: Dictionary) -> void:
	var sc = d.get("Scorer", {})
	var scorer := ""
	var team := -1
	if typeof(sc) == TYPE_DICTIONARY:
		scorer = str(sc.get("Name", ""))
		team = int(sc.get("TeamNum", -1))
	if team != 0 and team != 1:
		var blt = d.get("BallLastTouch", {})
		if typeof(blt) == TYPE_DICTIONARY and typeof(blt.get("Player")) == TYPE_DICTIONARY:
			team = int(blt["Player"].get("TeamNum", -1))
	if team != 0 and team != 1:
		return
	_baseline = true
	_emitted[team] += 1
	_pending[team] = -1.0
	if scores[team] < _emitted[team]:
		scores[team] = _emitted[team]
		if my_team >= 0:
			score_changed.emit(scores[my_team], scores[1 - my_team])
	_emit_goal(team, scorer)


func _emit_goal(team: int, scorer: String) -> void:
	if my_team < 0:
		goal_unknown.emit(scorer, team)
		return
	goal.emit(team == my_team, scorer, scores[my_team], scores[1 - my_team])


func _on_match_ended(winner: int) -> void:
	if _ended or (winner != 0 and winner != 1):
		return
	_ended = true
	in_match = false
	if my_team >= 0:
		match_ended.emit(winner == my_team)


## Appele par les tests pour vider les buts en attente sans attendre.
func flush_pending_for_tests() -> void:
	for t in 2:
		if _pending[t] >= 0.0:
			_pending[t] = -1.0
			if scores[t] > _emitted[t]:
				_emitted[t] = scores[t]
				_emit_goal(t, "")


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# ------------------------------------------------------------------ configuration du jeu
## Ou est Rocket League et la Stats API est-elle active ? Lecture seule.
## Retour : {found, install_dir, files: [{path, exists, rate, port}], enabled, port, writable_hint}
static func stats_api_status() -> Dictionary:
	var res := {"found": false, "install_dir": "", "files": [], "enabled": false, "port": DEFAULT_PORT}
	var inst := find_install()
	res["install_dir"] = inst
	res["found"] = inst != ""
	for p in candidate_ini_paths(inst):
		var e := {"path": p, "exists": FileAccess.file_exists(p), "rate": 0.0, "port": DEFAULT_PORT}
		if e["exists"]:
			var kv := read_section(FileAccess.get_file_as_string(p))
			e["rate"] = float(kv.get("PacketSendRate", "0"))
			e["port"] = int(kv.get("Port", str(DEFAULT_PORT)))
		res["files"].append(e)
	# le fichier effectivement lu par le jeu : TAStatsAPI.ini (genere) s'il existe, sinon DefaultStatsAPI.ini
	var eff := _effective(res["files"])
	if not eff.is_empty():
		res["enabled"] = float(eff["rate"]) > 0.0
		res["port"] = int(eff["port"]) if int(eff["port"]) > 0 else DEFAULT_PORT
	return res


static func _effective(files: Array) -> Dictionary:
	for e in files:
		if e["exists"] and str(e["path"]).get_file() == "TAStatsAPI.ini":
			return e
	for e in files:
		if e["exists"]:
			return e
	return {}


## Dossier d'installation (Epic puis Steam), "" si introuvable.
static func find_install() -> String:
	var epic := GamePaths.epic_install(PackedStringArray(["sugar", "rocketleague", "rocket league"]))
	if epic != "" and DirAccess.dir_exists_absolute(epic + "/TAGame"):
		return epic
	var steam := GamePaths.steam_app_dir("rocketleague")
	if steam != "" and DirAccess.dir_exists_absolute(steam + "/TAGame"):
		return steam
	return ""


## Fichiers ini possibles : la doc officielle cite <install>\TAGame\Config\TAStatsAPI.ini (ou
## DefaultStatsAPI.ini) ; en pratique le jeu genere aussi Documents\My Games\Rocket League\TAGame\Config\
## TAStatsAPI.ini (constate sur ce PC, avec une section [IniVersion]).
static func candidate_ini_paths(inst: String) -> PackedStringArray:
	var out := PackedStringArray()
	out.append(GamePaths.documents_dir() + "/My Games/Rocket League/TAGame/Config/TAStatsAPI.ini")
	if inst != "":
		out.append(inst + "/TAGame/Config/TAStatsAPI.ini")
		out.append(inst + "/TAGame/Config/DefaultStatsAPI.ini")
	return out


## Active la Stats API (A APPELER UNIQUEMENT APRES ACCORD DE L'UTILISATEUR).
## Idempotent : ne reecrit que les fichiers dont PacketSendRate vaut 0 ; sauvegarde unique
## `<fichier>.pompom.bak` avant la premiere modification ; Port/WebPort et le reste sont conserves.
## Retourne "" si tout va bien, sinon un message d'erreur en francais.
## Rocket League doit etre (re)demarre pour que ce soit pris en compte.
static func enable_stats_api(rate := DEFAULT_RATE) -> String:
	var inst := find_install()
	if inst == "":
		return "Rocket League introuvable (ni Epic Games ni Steam)."
	return enable_in_files(candidate_ini_paths(inst), rate)


## Desactive (PacketSendRate=0) en conservant le reste. Retourne "" si OK.
static func disable_stats_api() -> String:
	var inst := find_install()
	if inst == "":
		return "Rocket League introuvable."
	return enable_in_files(candidate_ini_paths(inst), 0)


## Coeur testable : applique `rate` aux fichiers existants de la liste.
static func enable_in_files(paths: PackedStringArray, rate: float) -> String:
	rate = clampf(rate, 0.0, 120.0)
	var errors := PackedStringArray()
	var done := 0
	for p in paths:
		if not FileAccess.file_exists(p):
			continue
		var txt := FileAccess.get_file_as_string(p)
		var cur := float(read_section(txt).get("PacketSendRate", "0"))
		if (rate > 0.0 and cur > 0.0) or (rate == 0.0 and cur == 0.0):
			done += 1  # deja dans l'etat voulu : on ne touche a rien
			continue
		var patched := patch_ini_text(txt, rate)
		if not GamePaths.backup_once(p):
			errors.append("Sauvegarde impossible pour " + p)
			continue
		var err := GamePaths.write_text_checked(p, patched)
		if err != "":
			errors.append(err)
		else:
			done += 1
	if done == 0 and errors.is_empty():
		return "Aucun fichier de configuration Stats API trouvé."
	# un seul fichier modifie suffit si c'est celui que le jeu lit ; on remonte quand meme les erreurs
	return "\n".join(errors) if done == 0 else ""


## Lit les cles de la section [TAGame.MatchStatsExporter_TA].
static func read_section(txt: String) -> Dictionary:
	var kv := {}
	var inside := false
	for raw in txt.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("["):
			inside = line == "[" + SECTION + "]"
			continue
		if not inside or line == "" or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq > 0:
			kv[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return kv


## Remplace (ou ajoute) PacketSendRate dans la section, en gardant fins de ligne et commentaires.
static func patch_ini_text(txt: String, rate: float) -> String:
	var nl := "\r\n" if txt.contains("\r\n") else "\n"
	var lines := txt.replace("\r\n", "\n").split("\n")
	var value := str(int(rate)) if is_equal_approx(rate, roundf(rate)) else str(rate)
	var inside := false
	var section_at := -1
	var replaced := false
	for i in lines.size():
		var line := lines[i].strip_edges()
		if line.begins_with("["):
			inside = line == "[" + SECTION + "]"
			if inside:
				section_at = i
			continue
		if inside and not line.begins_with(";") and line.find("=") > 0 \
				and line.substr(0, line.find("=")).strip_edges() == "PacketSendRate":
			lines[i] = "PacketSendRate=" + value
			replaced = true
	if not replaced:
		if section_at >= 0:
			lines.insert(section_at + 1, "PacketSendRate=" + value)
		else:
			if lines.size() > 0 and lines[lines.size() - 1] != "":
				lines.append("")
			lines.append("[" + SECTION + "]")
			lines.append("PacketSendRate=" + value)
			lines.append("Port=%d" % DEFAULT_PORT)
	return nl.join(lines)
