extends Node
## Captures d'ecran des mini-jeux (fenetre reelle, coups scriptes).
## Lancer : Godot --path godot res://tests/minigames_shot.tscn
## Les PNG sont enregistres dans user:// (%APPDATA%\Pompom\minigames_*.png).

var win: MiniGameWindow


func _ready() -> void:
	GameState.no_save = true
	var w := get_window()
	w.transparent = false
	w.borderless = false
	w.size = Vector2i(320, 240)
	w.position = Vector2i(20, 20)
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color("40424a"))
	get_tree().create_timer(120.0).timeout.connect(func():
		print("=== WATCHDOG ===")
		get_tree().quit(2))
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _wait_state(g: Object, prop: String, want: String, timeout := 8.0) -> void:
	var t0 := Time.get_ticks_msec()
	while str(g.get(prop)) != want and Time.get_ticks_msec() - t0 < timeout * 1000.0:
		await get_tree().process_frame


func _key(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = true
	return e


func shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := win.get_texture().get_image()
	if img == null:
		print("NO IMAGE ", name)
		return
	img.convert(Image.FORMAT_RGBA8)
	var bg := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
	for y in range(0, img.get_height(), 8):
		var t := float(y) / img.get_height()
		bg.fill_rect(Rect2i(0, y, img.get_width(), 8), Color("5b6475").lerp(Color("3a4050"), t))
	bg.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	var path := ProjectSettings.globalize_path("user://minigames_%s.png" % name)
	bg.save_png(path)
	print("SHOT ", path, "  ", img.get_size(), "  fps ", Engine.get_frames_per_second())


func _run() -> void:
	MiniGames.last_difficulty = 1
	win = MiniGames.open(null, null, self, "connect4") as MiniGameWindow
	win.auto_reward = false
	win.auto_pause = false
	await _wait(0.6)
	for id in ["connect4", "snake", "tictactoe"]:
		win.select_game(id)
		await _frames(2)
		var need: Vector2 = win._frame.get_child(0).get_combined_minimum_size()
		var have := Vector2(win.size) / win.content_scale_factor
		print("LAYOUT %s : contenu min %s / fenetre %s -> %s" % [id, need, have, "OK" if need.x <= have.x + 0.5 and need.y <= have.y + 0.5 else "DEBORDE"])
	win.select_game("connect4")
	await _wait(0.3)
	# ---------------------------------------------------------------- Puissance 4
	var g := win.game as Connect4Game
	for col in [3, 2, 4, 3]:
		await _wait_state(g, "state", "user")
		await _wait(0.2)
		g.user_play(col)
	await _wait_state(g, "state", "pompom")
	await _wait(0.25)
	await shot("connect4_thinking")
	await _wait_state(g, "state", "user")
	g.hover_col = 1
	await _wait(0.4)
	await shot("connect4")
	# victoire : on prepare une grille ou le joueur gagne au prochain coup
	win.new_game()
	g = win.game as Connect4Game
	await _wait_state(g, "state", "user")
	await _wait(0.2)
	var setup := [[1, 2], [1, 2, 1], [1, 2, 2], [], [2], [2, 1], []]
	var n := 0
	for c in 7:
		for r in 6:
			g.grid[c][r] = 0
		for r in (setup[c] as Array).size():
			g.grid[c][r] = setup[c][r]
			n += 1
	g.moves_played = n
	g.state = "user"
	g.user_play(3)  # aligne 4 pions dores sur la ligne du bas
	await _wait(1.3)
	await shot("connect4_end")
	# ---------------------------------------------------------------- Snake
	win.select_game("snake")
	var s := win.game as SnakeDuelGame
	s.autoplay_user = true
	await _wait(1.2)
	await shot("snake_countdown")
	await _wait(6.5)
	await shot("snake")
	# ---------------------------------------------------------------- Morpion
	win.select_game("tictactoe")
	var t := win.game as TicTacToeGame
	for cell in [4, 0, 6, 2, 1, 7, 3, 5, 8]:
		await _wait_state(t, "state", "user", 4.0)
		if t.state != "user":
			break
		await _wait(0.15)
		t.user_play(cell)
	await _wait(0.9)
	await shot("tictactoe")
	# ---------------------------------------------------------------- Difficile
	win.set_difficulty(2)
	win.select_game("connect4")
	await _wait(0.5)
	await shot("connect4_difficile")
	# clavier : fleche droite deplace le pion, Echap ferme
	var g2 := win.game as Connect4Game
	await _wait_state(g2, "state", "user")
	var before := g2.hover_col
	print("KEY droite : ", win._on_key(_key(KEY_RIGHT)), " colonne ", before, " -> ", g2.hover_col)
	print("focus fenetre : ", win.has_focus(), "  unfocusable : ", win.unfocusable)
	print("KEY Echap : ", win._on_key(_key(KEY_ESCAPE)))
	await _wait(0.4)
	print("closed: ", MiniGames.current() == null)
	get_tree().quit(0)
