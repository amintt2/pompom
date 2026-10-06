class_name MiniGames
## Point d'entree des mini-jeux contre Pompom.
##
##   var win := MiniGames.open(stage, emotes, self)          # ouvre (ou ramene au premier plan) la fenetre
##   win.game_finished.connect(func(game_id, result): ...)   # result = "win" | "lose" | "draw" (point de vue du joueur)
##   win.game_result.connect(func(info): ...)                # {game, result, difficulty, coins, xp, rewarded}
##   win.pompom_reaction.connect(func(kind, text): ...)      # pour faire reagir le compagnon du bureau
##   win.closed.connect(...)
##   MiniGames.current()  -> fenetre ouverte ou null (ex. : compter la fenetre comme "UI occupee")
##
## Les recompenses (pieces / XP / amusement) sont donnees par la fenetre via GameState.add_coins / add_xp /
## change_fun si `auto_reward` est vrai (defaut) ; mettre `win.auto_reward = false` pour les gerer soi-meme
## (game_result donne alors la recompense suggeree avec rewarded = false).

const GAMES := [
	{"id": "connect4", "name": "Puissance 4", "desc": "Aligne 4 pions"},
	{"id": "snake", "name": "Snake duel", "desc": "Le plus long gagne"},
	{"id": "tictactoe", "name": "Morpion", "desc": "Trois d'affilée"},
]
const DIFFICULTIES := ["Facile", "Moyen", "Difficile"]

## Scores de la session : game_id -> [joueur, Pompom, nuls]
static var scores := {}
static var last_game := "connect4"
static var last_difficulty := 1
static var _current: Window


## Ouvre la fenetre des mini-jeux (une seule a la fois). `stage` / `emotes` : compagnon du bureau (optionnels,
## servent a la couleur et au nom) ; `owner` : noeud parent de la fenetre. `game_id` vide = dernier jeu choisi.
static func open(stage: PetStage, emotes: EmoteLayer, owner: Node, game_id := "") -> Window:
	if _current and is_instance_valid(_current) and not _current.is_queued_for_deletion():
		if game_id != "":
			_current.call("select_game", game_id)
		_current.grab_focus()
		return _current
	var w := MiniGameWindow.new()
	w.stage = stage
	w.emotes = emotes
	owner.add_child(w)
	w.open(game_id if game_id != "" else last_game)
	_current = w
	return w


static func current() -> Window:
	if _current and is_instance_valid(_current) and not _current.is_queued_for_deletion():
		return _current
	return null


static func game_name(id: String) -> String:
	for g in GAMES:
		if g["id"] == id:
			return g["name"]
	return id


## Recompense suggeree (pieces, XP) selon le jeu, le resultat et la difficulte.
static func reward(game_id: String, result: String, difficulty: int) -> Dictionary:
	var d := clampi(difficulty, 0, 2)
	var coins: int = [6, 12, 25][d]
	var xp: int = [4, 8, 15][d]
	if game_id == "tictactoe":
		# partie courte ; en Difficile l'IA est parfaite : le nul vaut presque une victoire
		coins = [3, 6, 12][d]
		xp = [2, 4, 8][d]
		if result == "draw":
			return {"coins": coins if d == 2 else coins / 2, "xp": xp if d == 2 else xp / 2}
	match result:
		"win":
			return {"coins": coins, "xp": xp}
		"draw":
			return {"coins": coins / 2, "xp": xp / 2}
	return {"coins": 2, "xp": 2}


static func record(game_id: String, result: String) -> void:
	var s: Array = scores.get(game_id, [0, 0, 0])
	match result:
		"win":
			s[0] += 1
		"lose":
			s[1] += 1
		_:
			s[2] += 1
	scores[game_id] = s


static func score(game_id: String) -> Array:
	return scores.get(game_id, [0, 0, 0])
