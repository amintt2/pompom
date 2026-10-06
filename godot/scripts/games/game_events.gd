class_name GameEvents
extends Node
## Hub des integrations de jeux : suit le jeu au premier plan (Activity), demarre/arrete les liens
## officiels (Rocket League Stats API, Valve GSI pour CS2/Dota 2, Riot Live Client Data pour LoL) et
## les observateurs d'ecran opt-in (tableau Rocket League, HUD Valorant/Fortnite), puis re-emet tout en
## signaux generiques. Voir docs/game_events.md (sources, reglages, limites).
##
## Signaux :
##   event(kind, mine, data)
##     kind : "goal" (mine = mon equipe a marque / false = l'adversaire), "goal_any" (but, equipe de
##            l'utilisateur inconnue), "kill", "death", "assist", "multikill" (data.n), "first_blood",
##            "ace", "objective", "round_won" / "round_lost", "match_won" / "match_lost", "match_started".
##            kill / death / assist / multikill / first_blood concernent TOUJOURS l'utilisateur
##            lui-meme (mine = true ; "death" = c'est lui qui est mort).
##     data : toujours {game, source ("api" | "screen")} + champs propres (scorer, score_mine, n...).
##   game_changed(proc, genre) : jeu au premier plan (stable 1,5 s) ; ("", "") quand on quitte les jeux.
##     genre : voir GameCatalog ; "unknown" si Activity dit "jeu" mais qu'il n'est pas au catalogue.
##   setup_suggested(game, message) : une integration officielle existe mais n'est pas activee ; message
##     en francais pour la boite de confirmation. Si l'utilisateur accepte : apply_setup(game).
##   status_changed(source, status) : "rocket_league" connected/disconnected, "cs2_dota" ..., "lol" ...,
##     "hud" ok/black/frozen (black/frozen -> hud_hint() donne le conseil « plein écran fenêtré »).
##
## CABLAGE (desktop_controller.gd) :
##   var games := GameEvents.new(); games.name = "GameEvents"; add_child(games)
##   games.event.connect(func(kind, mine, data): ...)        # fete / petite moue, limitee en frequence
##   games.game_changed.connect(func(proc, genre): if GameCatalog.is_thinking_genre(genre): ...)
##   games.setup_suggested.connect(func(game, msg): <confirmation> -> games.apply_setup(game))

signal event(kind: String, mine: bool, data: Dictionary)
signal game_changed(proc: String, genre: String)
signal setup_suggested(game: String, message: String)
signal status_changed(source: String, status: String)

const POLL := 0.5
const STABLE_SEC := 1.5
const GRACE_SEC := 600.0  # le jeu reste « present » 10 min apres son dernier passage au premier plan
const DEDUPE_SEC := 1.0
const RL_PROCS := ["rocketleague", "rocketleague_eac"]
const LOL_PROCS := ["league of legends"]
const CS2_PROCS := ["cs2"]
const DOTA_PROCS := ["dota2"]

## Reglages lus dans GameState.settings (valeurs par defaut si absents).
const DEFAULTS := {
	"game_events": true, "rl_stats_api": true, "rl_screen_watch": false, "rl_my_color": "auto",
	"rl_player_name": "", "valve_gsi": true, "lol_live": true, "hud_watch": false, "hud_regions": {},
}

var rl: RocketLeagueLink
var scoreboard: ScoreboardWatcher
var valve: ValveGsiLink
var lol: LolLiveLink
var hud: HudWatcher

var proc := ""  ## jeu courant (stable)
var genre := ""
var info := {}  ## {id, name, genre} du catalogue
var proc_override := ""  ## tests : remplace Activity.proc_name
var title_override := ""

var _t := 0.0
var _cand := ""
var _cand_title := ""
var _cand_since := 0.0
var _seen := {}  # cle d'integration -> dernier instant au premier plan
var _suggested := {}
var _last_emit := {}
var _rl_known_team := -1


func _ready() -> void:
	rl = RocketLeagueLink.new()
	rl.name = "RocketLeague"
	add_child(rl)
	rl.goal.connect(func(mine: bool, scorer: String, sm: int, st: int):
		_emit("goal", mine, {"game": "rocket_league", "source": "api", "scorer": scorer, "score_mine": sm, "score_theirs": st}))
	rl.goal_unknown.connect(func(scorer: String, team: int):
		_emit("goal_any", false, {"game": "rocket_league", "source": "api", "scorer": scorer, "team": team}))
	rl.match_started.connect(func(): _emit("match_started", true, {"game": "rocket_league", "source": "api"}))
	rl.match_ended.connect(func(won: bool):
		_emit("match_won" if won else "match_lost", won, {"game": "rocket_league", "source": "api"}))
	rl.connected_changed.connect(func(ok: bool):
		status_changed.emit("rocket_league", "connected" if ok else "disconnected")
		_refresh())
	rl.team_known.connect(func(t: int):
		_rl_known_team = t
		scoreboard.known_team = t)

	scoreboard = ScoreboardWatcher.new()
	scoreboard.name = "Scoreboard"
	add_child(scoreboard)
	scoreboard.goal.connect(func(mine: bool, color: String, sm: int, st: int):
		_emit("goal", mine, {"game": "rocket_league", "source": "screen", "scorer": color, "score_mine": sm, "score_theirs": st}))
	scoreboard.goal_unknown.connect(func(color: String, team: int):
		_emit("goal_any", false, {"game": "rocket_league", "source": "screen", "scorer": color, "team": team}))

	valve = ValveGsiLink.new()
	valve.name = "ValveGSI"
	add_child(valve)
	valve.game_event.connect(func(g: String, kind: String, mine: bool, data: Dictionary): _forward(g, kind, mine, data, "api"))
	valve.connected_changed.connect(func(ok: bool): status_changed.emit("cs2_dota", "connected" if ok else "disconnected"))

	lol = LolLiveLink.new()
	lol.name = "LoL"
	add_child(lol)
	lol.game_event.connect(func(g: String, kind: String, mine: bool, data: Dictionary): _forward(g, kind, mine, data, "api"))
	lol.connected_changed.connect(func(ok: bool): status_changed.emit("lol", "connected" if ok else "disconnected"))
	lol.mode_known.connect(func(mode: String):
		if mode == "TFT" and LOL_PROCS.has(proc) and genre != "strategy":
			genre = "strategy"  # Teamfight Tactics tourne dans le meme processus que LoL
			game_changed.emit(proc, genre))

	hud = HudWatcher.new()
	hud.name = "HUD"
	add_child(hud)
	hud.hud_event.connect(func(g: String, kind: String, mine: bool, data: Dictionary): _forward(g, kind, mine, data, "screen"))
	hud.capture_status_changed.connect(func(s: String): status_changed.emit("hud", s))

	var gs := get_node_or_null("/root/GameState")
	if gs and gs.has_signal("settings_changed"):
		gs.settings_changed.connect(_refresh)
	_refresh()


func setting(key: String):
	var gs := get_node_or_null("/root/GameState")
	if gs and gs.settings.has(key):
		return gs.settings[key]
	return DEFAULTS.get(key)


func _process(delta: float) -> void:
	_t += delta
	if _t < POLL:
		return
	_t = 0.0
	var p := proc_override
	var title := title_override
	var act := get_node_or_null("/root/Activity")
	if p == "" and act:
		p = str(act.proc_name)
		title = str(act.window_title)
	var now := _now()
	if p != _cand or (title != _cand_title and GameCatalog.TITLE_HOSTS.has(p)):
		_cand = p
		_cand_title = title
		_cand_since = now
	var key := _integration_key(p)
	if key != "":
		_seen[key] = now
	if now - _cand_since >= STABLE_SEC:
		_apply_foreground(_cand, _cand_title, act)
	_refresh_presence()


func _integration_key(p: String) -> String:
	if RL_PROCS.has(p):
		return "rocket_league"
	if LOL_PROCS.has(p):
		return "lol"
	if CS2_PROCS.has(p):
		return "cs2"
	if DOTA_PROCS.has(p):
		return "dota2"
	return ""


func _apply_foreground(p: String, title: String, act) -> void:
	var inf := GameCatalog.lookup(p, title)
	var g := str(inf.get("genre", ""))
	if g == "" and act and str(act.category) == "game" and p != "":
		g = "unknown"
	var new_proc := p if g != "" else ""
	if new_proc == proc and (g == genre or (genre == "strategy" and LOL_PROCS.has(p))):
		return
	proc = new_proc
	genre = g
	info = inf
	game_changed.emit(proc, genre)
	_refresh()
	_maybe_suggest(_integration_key(proc))


## Met a jour les integrations selon les reglages et le jeu courant.
func _refresh() -> void:
	if rl == null:
		return
	var on := bool(setting("game_events"))
	rl.force_color = str(setting("rl_my_color"))
	rl.player_name = str(setting("rl_player_name"))
	scoreboard.my_color = rl.force_color
	scoreboard.known_team = _rl_known_team
	var fg_rl := RL_PROCS.has(proc)
	scoreboard.active = on and fg_rl and bool(setting("rl_screen_watch")) and not rl.connected
	if not fg_rl:
		scoreboard.reset()
	var hg := HudWatcher.profile_for(proc) if on and bool(setting("hud_watch")) else ""
	var ov = setting("hud_regions")
	hud.overrides = ov if typeof(ov) == TYPE_DICTIONARY else {}
	hud.set_game(hg)
	hud.active = hg != ""
	_refresh_presence()


func _present(key: String) -> bool:
	return _seen.has(key) and _now() - float(_seen[key]) < GRACE_SEC


func _refresh_presence() -> void:
	var on := bool(setting("game_events"))
	rl.game_present = on and bool(setting("rl_stats_api")) and _present("rocket_league")
	lol.game_present = on and bool(setting("lol_live")) and _present("lol")
	var want_valve := on and bool(setting("valve_gsi")) and (_present("cs2") or _present("dota2"))
	if want_valve and not valve.listening:
		valve.start()
	elif not want_valve and valve.listening:
		valve.stop()


func _forward(g: String, kind: String, mine: bool, data: Dictionary, source: String) -> void:
	var d := data.duplicate()
	d["game"] = g
	d["source"] = source
	_emit(kind, mine, d)


func _emit(kind: String, mine: bool, data: Dictionary) -> void:
	if not bool(setting("game_events")):
		return
	var k := "%s|%s|%s" % [kind, mine, data.get("game", "")]
	var now := _now()
	if kind != "multikill" and now - float(_last_emit.get(k, -100.0)) < DEDUPE_SEC:
		return  # meme evenement vu par deux sources (API + ecran)
	_last_emit[k] = now
	event.emit(kind, mine, data)


# ------------------------------------------------------------------ configuration (avec accord)
func _maybe_suggest(key: String) -> void:
	if key == "" or _suggested.has(key) or not bool(setting("game_events")):
		return
	var msg := ""
	match key:
		"rocket_league":
			var st := RocketLeagueLink.stats_api_status()
			if st["found"] and not st["enabled"]:
				msg = "Je peux activer l'API officielle de Rocket League (Stats API) pour fêter tes buts. " \
					+ "Je modifie juste un petit fichier de réglages du jeu (avec une sauvegarde). " \
					+ "Il faudra relancer Rocket League. D'accord ?"
		"cs2", "dota2":
			var st := ValveGsiLink.config_status(key)
			if st["found"] and not st["installed"]:
				msg = "Je peux brancher l'intégration officielle de Valve (Game State Integration) pour fêter tes éliminations. " \
					+ "J'ajoute un petit fichier dans le dossier du jeu. Il faudra relancer le jeu."
				if key == "dota2":
					msg += " Pour Dota 2, ajoute aussi « -gamestateintegration » dans Steam > Dota 2 > Propriétés > Options de lancement."
				msg += " D'accord ?"
	if msg != "":
		_suggested[key] = true
		setup_suggested.emit(key, msg)


## A appeler UNIQUEMENT apres accord de l'utilisateur. Retourne "" si OK, sinon un message d'erreur.
func apply_setup(key: String) -> String:
	match key:
		"rocket_league":
			return RocketLeagueLink.enable_stats_api()
		"cs2", "dota2":
			var err := ValveGsiLink.install_config(key, valve.port)
			if err == "":
				valve.token = ValveGsiLink.read_installed_token()
			return err
	return "Jeu inconnu."


## Conseil a afficher si la capture d'ecran du HUD ne marche pas ("" sinon).
func hud_hint() -> String:
	return hud.status_hint()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
