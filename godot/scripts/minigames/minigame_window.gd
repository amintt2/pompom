class_name MiniGameWindow
extends Window
## Fenetre "Jouer avec Pompom" : choix du jeu, difficulte, scores, Pompom qui parle et reagit,
## et la zone de jeu (Puissance 4, Snake duel, Morpion). Sans bordure, cadre arrondi dessine en code
## (comme la boutique), glisser la barre de titre pour deplacer, Echap pour fermer, mise a l'echelle DPI.
## Ouvrir via MiniGames.open(stage, emotes, owner).

signal game_started(game_id: String, difficulty: int)
## result = "win" | "lose" | "draw" du point de vue du joueur.
signal game_finished(game_id: String, result: String)
## {game, result, difficulty, coins, xp, rewarded}
signal game_result(info: Dictionary)
## Pompom reagit (kind = evenement, text = phrase dite ou "").
signal pompom_reaction(kind: String, text: String)
signal closed

const BASE_SIZE := Vector2(1080, 740)  # px logiques (hors ombre)
const SHADOW := 14.0
const CRITICAL := ["start", "go", "worried", "blocked", "user_blocked", "sure_win", "pompom_wins", "user_wins", "draw", "level"]
## evenement -> [probabilite de parler, humeur, repliques]
const REACT := {
	"start": [1.0, "happy", ["C'est parti !", "Que le meilleur gagne !", "Je ne vais pas te faire de cadeau !", "Prêt ? On y va !"]],
	"go": [1.0, "focus", ["C'est parti !", "Attrape-moi si tu peux !", "Les pommes sont à moi !"]],
	"think": [0.3, "think", ["Hmm... je réfléchis.", "Voyons voir...", "Laisse-moi réfléchir...", "Hmm..."]],
	"play": [0.35, "happy", ["À moi !", "Et hop !", "Voilà !", "Tiens, prends ça !", "À toi maintenant !"]],
	"user_move": [0.15, "focus", ["Intéressant...", "Je vois, je vois...", "Hmm, d'accord."]],
	"worried": [0.85, "surprised", ["Oh oh...", "Aïe, attends...", "Tu prépares quelque chose, toi !", "Hé, pas si vite !"]],
	"user_blocked": [0.8, "pout", ["Bien joué !", "Bien vu !", "Zut, tu m'as vu venir !", "Malin !"]],
	"blocked": [0.85, "smug", ["Pas si vite !", "Bloqué !", "Je t'ai vu venir !", "Hihi, raté !"]],
	"threat": [0.6, "smug", ["Hihi, à toi de voir...", "Attention...", "Tu as vu ce que je prépare ?"]],
	"sure_win": [1.0, "smug", ["Je crois que j'ai gagné...", "Hihi, c'est presque fini !", "Plus rien ne peut m'arrêter !"]],
	"eat": [0.3, "happy", ["Miam !", "Croc !", "Délicieux !", "Encore une !"]],
	"user_eat": [0.25, "pout", ["Hé, c'était ma pomme !", "Pas juste !", "Je la voulais !"]],
	"lead": [0.9, "smug", ["Mon serpent est plus long !", "Hihi, je grandis !"]],
	"behind": [0.9, "surprised", ["Tu es rapide !", "Attends-moi !", "Ton serpent est énorme !"]],
	"pompom_wins": [1.0, "happy", ["J'ai gagné !", "Victoire ! On en refait une ?", "Hihi, j'ai gagné !", "Trop facile... je rigole !"]],
	"user_wins": [1.0, "sad", ["Bravo, tu as gagné !", "Nooon... Revanche !", "Tu es trop fort !", "Bien joué, champion !"]],
	"draw": [1.0, "idle", ["Égalité !", "Match nul... on remet ça ?", "Personne ne gagne, tout le monde est content !"]],
	"level": [1.0, "happy", ["D'accord, mode %s !"]],
}

const HINTS := {
	"connect4": "Clique sur une colonne, ou flèches puis Entrée.",
	"snake": "Flèches, ZQSD ou WASD pour tourner.",
	"tictactoe": "Clique sur une case, ou touches 1 à 9.",
}

var stage: PetStage
var emotes: EmoteLayer
var auto_reward := true
var auto_pause := true  # met le Snake en pause quand la fenetre perd le focus
var game: MiniGameBase
var game_id := ""
var difficulty := 1
var pet_name := "Pompom"
var last_result := {}
var avatar: MiniGameAvatar
var close_button: Button
var replay_button: Button
var diff_seg: UIKit.Segmented
var game_tiles := {}
var status_label: Label
var confetti: UIKit.Confetti

var _f := 1.0
var _frame: Frame
var _area: Control
var _pop: ResultPop
var _status_dot: StatusDot
var _reward_box: HBoxContainer
var _title_label: Label
var _sub_label: Label
var _game_icon: GameIcon
var _score_user: Label
var _score_pom: Label
var _score_draw: Label
var _caption: Label
var _hint_label: Label
var _coin_pill: UIKit.CoinPill
var _starts := {}  # game_id -> le joueur commence la prochaine partie
var _last_line_t := -10.0
var _t := 0.0
var _closing := false
var _opened := false
var _old_fps := 0
var _screen := -1


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	wrap_controls = false
	transient = false
	exclusive = false
	unfocusable = false
	always_on_top = false
	unresizable = true
	title = "Pompom — Mini-jeux"
	# l'anticrenelage 2D du projet ne s'applique qu'a la fenetre principale
	msaa_2d = Viewport.MSAA_4X


func open(first_game := "connect4") -> void:
	if _opened:
		select_game(first_game)
		return
	_opened = true
	theme = UITheme.theme()
	pet_name = GameState.pet_name if GameState.pet_name != "" else "Pompom"
	difficulty = MiniGames.last_difficulty
	_screen = DisplayServer.window_get_current_screen()
	_apply_scale(true)
	close_requested.connect(close_window)
	focus_exited.connect(_on_focus.bind(false))
	focus_entered.connect(_on_focus.bind(true))
	_build()
	_old_fps = Engine.max_fps
	if Engine.max_fps > 0 and Engine.max_fps < 60:
		Engine.max_fps = 60
	show()
	select_game(first_game)
	_frame.pivot_offset = _frame.size * 0.5
	_frame.modulate.a = 0.0
	_frame.scale = Vector2.ONE * 0.97
	var t := create_tween().set_parallel()
	t.tween_property(_frame, "modulate:a", 1.0, 0.18)
	t.tween_property(_frame, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	grab_focus()


## Scene du compagnon dans la carte, en pixels ecran : {rect, floor} (vide si pas encore construite).
func avatar_screen_info() -> Dictionary:
	if avatar == null or not is_instance_valid(avatar) or not visible or mode == MODE_MINIMIZED:
		return {}
	var r := avatar.get_global_rect()
	var origin := Vector2(position)
	return {"rect": Rect2(origin + r.position * _f, r.size * _f), "floor": origin + (r.position + avatar.floor_point()) * _f}


## true : le vrai compagnon (3D) vient s'asseoir dans la carte a la place du dessin.
func set_external_avatar(on: bool) -> void:
	if avatar:
		avatar.external = on


func close_window() -> void:
	if _closing:
		return
	_closing = true
	if game:
		game.shutdown()
	if not _opened or _frame == null:
		queue_free()
		return
	var t := create_tween().set_parallel()
	t.tween_property(_frame, "modulate:a", 0.0, 0.12)
	t.tween_property(_frame, "scale", Vector2.ONE * 0.97, 0.12)
	t.chain().tween_callback(queue_free)


func _exit_tree() -> void:
	if GameState.coins_changed.is_connected(_on_coins):
		GameState.coins_changed.disconnect(_on_coins)
	if game:
		game.shutdown()
	if _old_fps > 0 and Engine.max_fps == 60:
		Engine.max_fps = _old_fps
	closed.emit()


func _apply_scale(recenter: bool) -> void:
	var usable := Rect2(DisplayServer.screen_get_usable_rect(_screen if _screen >= 0 else 0))
	var logical := BASE_SIZE + Vector2(SHADOW, SHADOW) * 2.0
	# echelle DPI, reduite si l'ecran est trop petit
	_f = minf(UITheme.dpi_scale(_screen), minf(usable.size.x * 0.96 / logical.x, usable.size.y * 0.96 / logical.y))
	_f = maxf(_f, 0.6)
	content_scale_factor = _f
	size = Vector2i((logical * _f).ceil())
	min_size = size
	if recenter:
		position = Vector2i(usable.position + (usable.size - Vector2(size)) * 0.5)


func _process(delta: float) -> void:
	_t += delta
	if _closing:
		return
	if Engine.max_fps > 0 and Engine.max_fps < 60:
		Engine.max_fps = 60  # animations fluides tant que la fenetre est ouverte
	var sc := current_screen
	if sc != _screen and mode == MODE_WINDOWED:
		_screen = sc
		var old := _f
		var keep := position
		_apply_scale(false)
		if not is_equal_approx(old, _f):
			position = keep


func _on_coins(v: int, _d: int) -> void:
	if _coin_pill and is_instance_valid(_coin_pill):
		_coin_pill.set_value(v)


func _on_focus(on: bool) -> void:
	if game is SnakeDuelGame and auto_pause:
		(game as SnakeDuelGame).set_paused(not on)


# =========================================================================== jeux
func select_game(id: String) -> void:
	if _closing:
		return
	var found := false
	for g in MiniGames.GAMES:
		found = found or g["id"] == id
	if not found:
		id = "connect4"
	if game:
		game.shutdown()
		game.queue_free()
		game = null
	game_id = id
	MiniGames.last_game = id
	match id:
		"snake":
			game = SnakeDuelGame.new()
		"tictactoe":
			game = TicTacToeGame.new()
		_:
			game = Connect4Game.new()
	game.pet_name = pet_name
	game.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game.finished.connect(_on_finished)
	game.status_changed.connect(_on_status)
	game.pompom_event.connect(_react)
	game.thinking_changed.connect(func(on: bool): avatar.set_thinking(on))
	_area.add_child(game)
	_area.move_child(game, 0)
	for k in game_tiles:
		game_tiles[k].selected = k == id
		game_tiles[k].queue_redraw()
	_title_label.text = MiniGames.game_name(id)
	_hint_label.text = HINTS.get(id, "")
	_game_icon.game = id
	_game_icon.queue_redraw()
	new_game()


## Nouvelle partie du jeu courant (le premier joueur alterne).
func new_game() -> void:
	if game == null:
		return
	var starts: bool = _starts.get(game_id, true)
	_starts[game_id] = not starts
	_pop.hide_now()
	_clear_rewards()
	replay_button.text = "Recommencer"
	replay_button.theme_type_variation = ""
	avatar.set_mood("idle")
	game.start_game(difficulty, starts)
	_update_header(starts)
	_update_score()
	_react("start")
	game_started.emit(game_id, difficulty)


func set_difficulty(d: int) -> void:
	d = clampi(d, 0, 2)
	if diff_seg and diff_seg.selected != d:
		diff_seg.select(d)
	if d == difficulty:
		return
	difficulty = d
	MiniGames.last_difficulty = d
	new_game()
	_say_line("level", (REACT["level"][2][0] as String) % MiniGames.DIFFICULTIES[d].to_lower(), "happy")


func _update_header(user_first: bool) -> void:
	var who := "Tu commences" if user_first else "%s commence" % pet_name
	if game_id == "snake":
		who = "2 minutes · le plus long gagne"
	_sub_label.text = "%s  ·  %s" % [MiniGames.DIFFICULTIES[difficulty], who]


func _update_score() -> void:
	var s := MiniGames.score(game_id)
	_score_user.text = str(s[0])
	_score_pom.text = str(s[1])
	_score_draw.text = "%d nul%s" % [s[2], "s" if s[2] > 1 else ""]
	_score_draw.visible = s[2] > 0


func _on_status(text: String, who: String) -> void:
	status_label.text = text
	_status_dot.who = who
	_status_dot.queue_redraw()


func _on_finished(result: String) -> void:
	MiniGames.record(game_id, result)
	_update_score()
	var r := MiniGames.reward(game_id, result, difficulty)
	var info := {"game": game_id, "result": result, "difficulty": difficulty, "coins": int(r["coins"]),
		"xp": int(r["xp"]), "rewarded": false}
	if auto_reward:
		info["rewarded"] = true
		GameState.add_coins(int(r["coins"]))
		GameState.add_xp(int(r["xp"]))
		GameState.change_fun(10.0 if result == "win" else 6.0)
	last_result = info
	_show_rewards(info)
	replay_button.text = "Rejouer"
	replay_button.theme_type_variation = "PrimaryButton"
	match result:
		"win":
			_react("user_wins")
			_pop.show_text("Victoire !", UITheme.MINT)
			confetti.burst(_area.get_global_rect().get_center() - _frame.get_global_rect().position + Vector2(0, 60), 70)
		"lose":
			_react("pompom_wins")
			avatar.bounce(1.0)
			_pop.show_text("%s gagne !" % pet_name, UITheme.ACCENT)
		_:
			_react("draw")
			_pop.show_text("Égalité !", UITheme.LAVENDER)
	game_finished.emit(game_id, result)
	game_result.emit(info)


func _clear_rewards() -> void:
	for c in _reward_box.get_children():
		c.queue_free()


func _show_rewards(info: Dictionary) -> void:
	_clear_rewards()
	if int(info["coins"]) > 0:
		_reward_box.add_child(_pill("coin", "+%d" % int(info["coins"]), UITheme.GOLD_SOFT, Color("8a5a00")))
	if int(info["xp"]) > 0:
		_reward_box.add_child(_pill("star", "+%d XP" % int(info["xp"]), UITheme.LAVENDER_SOFT, UITheme.LAVENDER.darkened(0.3)))


func _pill(icon_name: String, text: String, bg: Color, fg: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.pill(bg, 12, 5))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	var ic := UIKit.icon(icon_name, 18.0, fg if icon_name != "coin" else UITheme.INK)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	h.add_child(UITheme.label(text, UITheme.FS_BODY, fg, 650))
	p.pivot_offset = Vector2(30, 14)
	p.scale = Vector2.ONE * 0.6
	p.modulate.a = 0.0
	var t := p.create_tween().set_parallel()
	t.tween_property(p, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT).set_delay(0.5)
	t.tween_property(p, "modulate:a", 1.0, 0.2).set_delay(0.5)
	return p


# =========================================================================== Pompom
func _react(kind: String) -> void:
	if not REACT.has(kind):
		return
	var e: Array = REACT[kind]
	var critical := kind in CRITICAL
	var text := ""
	if critical or (randf() < float(e[0]) and _t - _last_line_t > 1.6 and not avatar.is_talking()):
		var lines: Array = e[2]
		text = lines[randi() % lines.size()]
		if kind == "level":
			text = text % MiniGames.DIFFICULTIES[difficulty].to_lower()
	if text != "":
		_say_line(kind, text, e[1])
	elif not avatar.is_talking():
		avatar.set_mood(e[1], 1.2)  # (on ne contredit pas la phrase en cours)
	if kind in ["eat", "pompom_wins", "blocked"]:
		avatar.bounce(0.6 if kind == "eat" else 1.0)
	elif kind in ["worried", "behind"]:
		avatar.bounce(0.35)
	if text == "":
		pompom_reaction.emit(kind, "")


func _say_line(kind: String, text: String, mood: String) -> void:
	_last_line_t = _t
	avatar.say(text)
	var dur := 3.0 if kind in ["pompom_wins", "user_wins", "draw"] else 1.6
	avatar.set_mood(mood, dur)
	_caption.text = _caption_for(kind)
	pompom_reaction.emit(kind, text)


func _caption_for(kind: String) -> String:
	match kind:
		"pompom_wins":
			return "est tout content"
		"user_wins":
			return "veut sa revanche"
		"worried", "behind":
			return "commence à s'inquiéter"
		"blocked", "threat", "sure_win", "lead":
			return "est très fier de lui"
	return "ton adversaire"


# =========================================================================== clavier
func _on_key(ev: InputEventKey) -> bool:
	if not ev.pressed:
		return false
	if ev.keycode == KEY_ESCAPE and not ev.echo:
		close_window()
		return true
	if game and game.over and not ev.echo and ev.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		new_game()
		return true
	if ev.keycode == KEY_F2 or (ev.keycode == KEY_R and ev.ctrl_pressed):
		new_game()
		return true
	if game:
		return game.key_input(ev)
	return false


# =========================================================================== construction
func _build() -> void:
	_frame = Frame.new()
	_frame.win = self
	_frame.margin = SHADOW
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "bottom"]:
		root.add_theme_constant_override("margin_" + side, int(SHADOW + 20))
	root.add_theme_constant_override("margin_top", int(SHADOW + 8))
	_frame.add_child(root)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(col)
	col.add_child(_build_titlebar())
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	row.add_child(_build_left())
	row.add_child(_build_right())
	confetti = UIKit.Confetti.new()
	_frame.add_child(confetti)


func _build_titlebar() -> Control:
	var bar := TitleBar.new()
	bar.win = self
	bar.custom_minimum_size.y = 52
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(h)
	var logo := UIKit.IconBubble.new("gamepad", 40.0, UITheme.ACCENT, true)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(logo)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", -4)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(tv)
	tv.add_child(UITheme.label("Jouer avec %s" % pet_name, UITheme.FS_TITLE, UITheme.INK, 700))
	tv.add_child(UITheme.label("Mini-jeux · %s est ton adversaire" % pet_name, UITheme.FS_SMALL, UITheme.MUTED))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(sp)
	var coin := UIKit.CoinPill.new(GameState.coins)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(coin)
	_coin_pill = coin
	GameState.coins_changed.connect(_on_coins)
	var gap := Control.new()
	gap.custom_minimum_size.x = 4
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(gap)
	var min_b := WinBtn.new("minus", UITheme.LAVENDER, "Réduire")
	min_b.pressed.connect(func(): mode = MODE_MINIMIZED)
	h.add_child(min_b)
	close_button = WinBtn.new("close", UITheme.BAD, "Fermer (Échap)")
	close_button.pressed.connect(close_window)
	h.add_child(close_button)
	return bar


func _build_left() -> Control:
	var v := VBoxContainer.new()
	v.custom_minimum_size.x = 280
	v.add_theme_constant_override("separation", 14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Pompom
	var card := PanelContainer.new()
	var cst := UITheme.glass(UITheme.R_CARD, 12, 0.85, 12)
	card.add_theme_stylebox_override("panel", cst)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(card)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 0)
	cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(cv)
	var stagebg := AvatarBg.new()
	stagebg.custom_minimum_size = Vector2(250, 186)
	stagebg.tint = GameState.current_fur_color()
	cv.add_child(stagebg)
	avatar = MiniGameAvatar.new()
	avatar.custom_minimum_size = Vector2.ZERO
	avatar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stagebg.add_child(avatar)
	var nm := UITheme.label(pet_name, UITheme.FS_H2, UITheme.INK, 650)
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(nm)
	_caption = UITheme.label("ton adversaire", UITheme.FS_SMALL, UITheme.MUTED)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(_caption)
	# jeux
	var games := PanelContainer.new()
	games.add_theme_stylebox_override("panel", UITheme.glass(UITheme.R_CARD, 10, 0.85, 12))
	games.mouse_filter = Control.MOUSE_FILTER_IGNORE
	games.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(games)
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 4)
	gv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	games.add_child(gv)
	for g in MiniGames.GAMES:
		var tile := GameTile.new(g["id"], g["name"], g["desc"])
		tile.pressed.connect(select_game.bind(g["id"]))
		gv.add_child(tile)
		game_tiles[g["id"]] = tile
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gv.add_child(fill)
	var hint := PanelContainer.new()
	hint.add_theme_stylebox_override("panel", UITheme.box(Color("f7eef4"), 12, Color.TRANSPARENT, 0, 8))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gv.add_child(hint)
	var hh := HBoxContainer.new()
	hh.add_theme_constant_override("separation", 8)
	hh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_child(hh)
	var hi := UIKit.icon("info", 18.0, UITheme.MUTED)
	hi.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hh.add_child(hi)
	_hint_label = UITheme.label("", UITheme.FS_SMALL, UITheme.BODY)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_label.custom_minimum_size.x = 200
	hh.add_child(_hint_label)
	# difficulte
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 6)
	dv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(dv)
	var dl := UITheme.label("Difficulté", UITheme.FS_SMALL, UITheme.MUTED, 650)
	dv.add_child(dl)
	diff_seg = UIKit.Segmented.new(MiniGames.DIFFICULTIES, difficulty)
	diff_seg.changed.connect(set_difficulty)
	dv.add_child(diff_seg)
	return v


func _build_right() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UITheme.glass(UITheme.R_CARD, 18, 0.8, 12))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(v)
	# en-tete : jeu + score
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(head)
	_game_icon = GameIcon.new()
	_game_icon.custom_minimum_size = Vector2(44, 44)
	_game_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_game_icon)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", -3)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(tv)
	_title_label = UITheme.label("", UITheme.FS_H2 + 2, UITheme.INK, 650)
	tv.add_child(_title_label)
	_sub_label = UITheme.label("", UITheme.FS_SMALL, UITheme.MUTED)
	tv.add_child(_sub_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(sp)
	head.add_child(_score_chip("Toi", true))
	_score_draw = UITheme.label("", UITheme.FS_SMALL, UITheme.MUTED, 650)
	_score_draw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_score_draw)
	head.add_child(_score_chip(pet_name, false))
	# zone de jeu
	_area = Control.new()
	_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_area.clip_contents = false
	v.add_child(_area)
	_pop = ResultPop.new()
	_pop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_area.add_child(_pop)
	# pied : etat + recompenses + rejouer
	var foot := PanelContainer.new()
	var fst := UITheme.box(Color(1, 1, 1, 0.75), 16, Color(1, 1, 1, 0.95), 1, 8)
	fst.content_margin_left = 14
	foot.add_theme_stylebox_override("panel", fst)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(foot)
	var fh := HBoxContainer.new()
	fh.add_theme_constant_override("separation", 10)
	fh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	foot.add_child(fh)
	_status_dot = StatusDot.new()
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	fh.add_child(_status_dot)
	status_label = UITheme.label("", UITheme.FS_BODY, UITheme.INK, 650)
	status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	fh.add_child(status_label)
	_reward_box = HBoxContainer.new()
	_reward_box.add_theme_constant_override("separation", 6)
	_reward_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fh.add_child(_reward_box)
	replay_button = Button.new()
	replay_button.text = "Recommencer"
	replay_button.focus_mode = Control.FOCUS_NONE
	replay_button.custom_minimum_size = Vector2(140, 40)
	replay_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	replay_button.tooltip_text = "Nouvelle partie (Entrée en fin de partie)"
	replay_button.pressed.connect(new_game)
	fh.add_child(replay_button)
	return panel


func _score_chip(who: String, is_user: bool) -> Control:
	var p := PanelContainer.new()
	var bg := Color("fff1d3") if is_user else UITheme.ACCENT_SOFT
	p.add_theme_stylebox_override("panel", UITheme.pill(bg, 12, 4))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	var fg := Color("8a5a00") if is_user else UITheme.ACCENT_DARK
	h.add_child(UITheme.label(who, UITheme.FS_SMALL + 1, fg, 650))
	var n := UITheme.label("0", UITheme.FS_H2, fg, 700)
	h.add_child(n)
	if is_user:
		_score_user = n
	else:
		_score_pom = n
	return p


# =========================================================================== composants internes
## Cadre : ombre + degrade arrondi ; transmet le clavier a la fenetre.
class Frame extends Control:
	var win: MiniGameWindow
	var margin := 14.0

	func _input(ev: InputEvent) -> void:
		if ev is InputEventKey and win and win._on_key(ev):
			get_viewport().set_input_as_handled()

	func _draw() -> void:
		var r := Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0)
		var sh := UITheme.box(UITheme.BG, UITheme.R_WIN, Color.TRANSPARENT, 0, 0)
		sh.shadow_color = Color(0.25, 0.1, 0.25, 0.20)
		sh.shadow_size = int(margin * 0.9)
		sh.shadow_offset = Vector2(0, 3)
		draw_style_box(sh, r)
		var pts := UIKit.rounded_poly(r, UITheme.R_WIN, 10)
		var cols := PackedColorArray()
		for p in pts:
			var t := clampf((p.y - r.position.y) / r.size.y, 0.0, 1.0)
			var u := clampf((p.x - r.position.x) / r.size.x, 0.0, 1.0)
			cols.append(UITheme.BG.lerp(UITheme.BG_2, t * 0.8 + u * 0.2))
		draw_polygon(pts, cols)
		pts.append(pts[0])
		draw_polyline(pts, Color(1, 1, 1, 0.9), 1.2, true)


class TitleBar extends Control:
	var win: Window

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and win:
			win.start_drag()
			accept_event()


class WinBtn extends Button:
	var icon_name := ""
	var tint := UITheme.INK
	var _h := 0.0

	func _init(ic: String, t: Color, tip: String) -> void:
		icon_name = ic
		tint = t
		tooltip_text = tip
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(36, 36)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.12)

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c, r, Color(tint.lerp(Color.WHITE, 0.82), _h), true, -1.0, true)
		UIIcons.draw(self, icon_name, Rect2(c - Vector2(9, 9), Vector2(18, 18)), UITheme.MUTED.lerp(tint.darkened(0.1), _h), 1.0)


## Fond de la carte de Pompom : degrade teinte + halo.
class AvatarBg extends Control:
	var tint := Color("f59ab8")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var pts := UIKit.rounded_poly(r, 16, 8)
		var top := tint.lerp(Color.WHITE, 0.88)
		var bot := tint.lerp(Color.WHITE, 0.72)
		var cols := PackedColorArray()
		for p in pts:
			cols.append(top.lerp(bot, clampf(p.y / size.y, 0.0, 1.0)))
		draw_polygon(pts, cols)
		var c := Vector2(size.x * 0.5, size.y * 0.66)
		draw_circle(c, size.y * 0.36, Color(1, 1, 1, 0.32), true, -1.0, true)
		draw_circle(c, size.y * 0.26, Color(1, 1, 1, 0.22), true, -1.0, true)
		for s in [[0.12, 0.2, 2.6], [0.88, 0.32, 2.0], [0.16, 0.7, 1.8], [0.86, 0.76, 2.6]]:
			UIIcons.draw(self, "sparkle", Rect2(Vector2(size.x * s[0], size.y * s[1]) - Vector2(s[2], s[2]) * 2.5, Vector2(s[2], s[2]) * 5.0),
				Color(1, 1, 1, 0.9), 1.0)


## Pastille d'etat (vert = a toi, rose = Pompom).
class StatusDot extends Control:
	var who := ""
	var _t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(18, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var col := UITheme.MINT if who == "user" else (UITheme.ACCENT if who == "pompom" else UITheme.LAVENDER)
		var c := size * 0.5
		var p := 0.5 + 0.5 * sin(_t * 4.0)
		draw_circle(c, 6.0 + p * 3.0, Color(col, 0.18 * (1.0 - p) + 0.08), true, -1.0, true)
		draw_circle(c, 5.0, col, true, -1.0, true)


## Icone vectorielle de chaque jeu.
class GameIcon extends Control:
	var game := "connect4"
	var selected := true

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s := minf(size.x, size.y)
		var r := Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s))
		var tint: Color = {"connect4": UITheme.LAVENDER, "snake": UITheme.MINT, "tictactoe": UITheme.SKY}.get(game, UITheme.ACCENT)
		draw_style_box(UITheme.box(tint.lerp(Color.WHITE, 0.8), int(s * 0.3), Color.TRANSPARENT, 0, 0), r)
		var c := r.get_center()
		var u := s / 44.0
		match game:
			"connect4":
				draw_style_box(UITheme.box(Color("ab9dfb"), int(5 * u), Color.TRANSPARENT, 0, 0), Rect2(c - Vector2(14, 12) * u, Vector2(28, 24) * u))
				var cols := [[0, 1, 2], [2, 1, 0], [1, 2, 1]]
				for x in 3:
					for y in 3:
						var p := c + Vector2((x - 1) * 8.6, (y - 1) * 7.0) * u
						var v: int = cols[y][x]
						var cc := Color("5d4fc4") if v == 0 else (Color("ffc94a") if v == 1 else Color("ff7eb0"))
						if y == 0 and v != 0:
							cc = Color("5d4fc4")
						draw_circle(p, 3.0 * u, cc, true, -1.0, true)
			"snake":
				var pts := PackedVector2Array([c + Vector2(-12, 8) * u, c + Vector2(-12, -2) * u, c + Vector2(0, -2) * u, c + Vector2(0, 8) * u, c + Vector2(10, 8) * u, c + Vector2(10, -6) * u])
				for i in pts.size():
					draw_circle(pts[i], 3.6 * u, Color("2f9e78"), true, -1.0, true)
					if i > 0:
						draw_line(pts[i - 1], pts[i], Color("2f9e78"), 7.2 * u, true)
				for i in pts.size():
					draw_circle(pts[i], 2.6 * u, Color("5fd3a4"), true, -1.0, true)
					if i > 0:
						draw_line(pts[i - 1], pts[i], Color("5fd3a4"), 5.2 * u, true)
				draw_circle(pts[pts.size() - 1], 4.6 * u, Color("5fd3a4"), true, -1.0, true)
				draw_circle(pts[pts.size() - 1] + Vector2(-1.6, -1) * u, 1.1 * u, UITheme.INK, true, -1.0, true)
				draw_circle(pts[pts.size() - 1] + Vector2(1.6, -1) * u, 1.1 * u, UITheme.INK, true, -1.0, true)
				draw_circle(c + Vector2(-4, -11) * u, 3.4 * u, Color("ff5a6e"), true, -1.0, true)
				draw_line(c + Vector2(-4, -14) * u, c + Vector2(-3, -16) * u, Color("8a5a3c"), 1.2 * u, true)
			"tictactoe":
				var w := 2.2 * u
				var ink := Color(UITheme.SKY.darkened(0.25), 0.4)
				for i in [-1, 1]:
					draw_line(c + Vector2(i * 4.5, -13) * u, c + Vector2(i * 4.5, 13) * u, ink, w, true)
					draw_line(c + Vector2(-13, i * 4.5) * u, c + Vector2(13, i * 4.5) * u, ink, w, true)
				var xc := c + Vector2(-9, -9) * u
				draw_line(xc - Vector2(3, 3) * u, xc + Vector2(3, 3) * u, Color("3d8ad6"), 2.6 * u, true)
				draw_line(xc + Vector2(3, -3) * u, xc - Vector2(3, -3) * u, Color("3d8ad6"), 2.6 * u, true)
				draw_arc(c, 3.4 * u, 0, TAU, 20, Color("ff7eb0"), 2.6 * u, true)
				draw_arc(c + Vector2(9, 9) * u, 3.4 * u, 0, TAU, 20, Color("ff7eb0"), 2.6 * u, true)


## Tuile de choix du jeu.
class GameTile extends Button:
	var game_id := ""
	var title_text := ""
	var desc := ""
	var selected := false
	var _h := 0.0
	var _icon: GameIcon

	func _init(id: String, t: String, d: String) -> void:
		game_id = id
		title_text = t
		desc = d
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(0, 56)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		_icon = GameIcon.new()
		_icon.game = id
		_icon.position = Vector2(8, 6)
		_icon.size = Vector2(44, 44)
		add_child(_icon)
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.12)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if selected:
			var st := UITheme.box(Color.WHITE, 16, Color(UITheme.ACCENT, 0.7), 2, 0)
			st.shadow_color = Color(0.35, 0.15, 0.32, 0.12)
			st.shadow_size = 8
			st.shadow_offset = Vector2(0, 2)
			draw_style_box(st, r.grow(-1))
		elif _h > 0.01:
			draw_style_box(UITheme.box(Color(UITheme.ACCENT_SOFT, 0.7 * _h), 16, Color.TRANSPARENT, 0, 0), r.grow(-1))
		var f := UITheme.font(650)
		var f2 := UITheme.font(500)
		var x := 64.0
		draw_string(f, Vector2(x, size.y * 0.5 - 2), title_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			UITheme.INK if selected else UITheme.INK.lerp(UITheme.ACCENT_DARK, _h))
		draw_string(f2, Vector2(x, size.y * 0.5 + 16), desc, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.MUTED)
		if selected:
			UIIcons.draw(self, "check", Rect2(size.x - 30, size.y * 0.5 - 8, 16, 16), UITheme.ACCENT, 1.2)


## Grand texte de fin qui saute au-dessus du plateau puis s'efface.
class ResultPop extends Control:
	var _text := ""
	var _col := UITheme.ACCENT
	var _t := -1.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func show_text(t: String, c: Color) -> void:
		_text = t
		_col = c
		_t = 0.0
		set_process(true)

	func hide_now() -> void:
		_t = -1.0
		queue_redraw()

	func _process(delta: float) -> void:
		if _t < 0.0:
			set_process(false)
			return
		_t += delta
		if _t > 2.2:
			_t = -1.0
		queue_redraw()

	func _draw() -> void:
		if _t < 0.0:
			return
		var k := clampf(_t / 0.45, 0.0, 1.0)
		var s := MiniGameBase.ease_out_back(k)
		var a := clampf((2.2 - _t) / 0.5, 0.0, 1.0)
		var f := UITheme.font(700)
		var fs := 46
		var tsz := f.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var c := size * 0.5
		draw_set_transform(c, sin(_t * 3.0) * 0.03, Vector2.ONE * lerpf(0.4, 1.0, s))
		var r := Rect2(-tsz.x * 0.5 - 30, -tsz.y * 0.5 - 14, tsz.x + 60, tsz.y + 28)
		var st := UITheme.box(Color(1, 1, 1, 0.95 * a), 99, Color(_col, 0.6 * a), 3, 0)
		st.shadow_color = Color(0.35, 0.15, 0.32, 0.2 * a)
		st.shadow_size = 18
		st.shadow_offset = Vector2(0, 6)
		draw_style_box(st, r)
		draw_string(f, Vector2(-tsz.x * 0.5, f.get_ascent(fs) * 0.5 - f.get_descent(fs) * 0.3 + 3), _text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(_col.darkened(0.15), a))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
