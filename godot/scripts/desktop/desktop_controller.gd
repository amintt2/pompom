class_name DesktopController
extends Node
## Compagnon de bureau : petite fenetre transparente, toujours devant, posee sur la barre des taches.
## Gere la souris (porter, lancer, caresser), la chute avec rebonds, la discretion, le mode plein ecran,
## le "cerveau" (quelles actions faire) et les menus.

const GRAVITY := 2600.0

var stage: PetStage
var pet: Pet
var emotes: EmoteLayer
var capture: EnvCapture
var win: Window

var s := 1.0  # echelle (taille x DPI)
var W := 260
var H := 300
var margin := 14.0
var pos := Vector2.ZERO  # coin haut-gauche de la fenetre (ecran)
var vel := Vector2.ZERO
var state := "ground"  # ground | walk | drag | fall | peek | hidden

var _press := false
var _press_mouse := Vector2.ZERO
var _grab := Vector2.ZERO
var _drag_hist: Array = []
var _prev_drag_vel := Vector2.ZERO
var _rub := 0.0
var _rub_timer := 0.0
var _pet_cd := 0.0
var _last_mouse := Vector2.ZERO
var _mouse_still := 0.0
var _near_time := 0.0
var _was_near := false
var _notice_cd := 5.0
var _hover_time := 0.0
var _think := 4.0
var _poly_t := 0.0
var _cap_t := 0.0
var _poly := PackedVector2Array()
var _slept_at := 0.0
var _grumpy_t := 240.0
var _attention_t := 400.0
var _carry_talk_cd := 0.0
var _prev_look := {}
var _tray: StatusIndicator
var _shop: ShopWindow
var _peek_shy := 0.0
var _move_tween: Tween
## Surface sur laquelle il est pose : id 0 = barre des taches, sinon le handle de la fenetre.
var plat := {"id": 0, "y": 0.0, "x0": 0.0, "x1": 0.0, "rect": Rect2()}
var _climb_cd := 20.0
var hud: GameHud
var clip: ClipboardKeeper
var updater: Updater
var suggest: SuggestClient
var _needs_t := 240.0
var _eating := false
var _hover_needs_t := 0.0
## Mode de vie : normal | game | fs (plein ecran) | comp (jeu competitif) | meeting (visio) | video
var mode := "normal"
var _mail: Array[String] = []  # boite aux lettres : messages mis de cote pendant le jeu / la visio
var _mail_ready_t := 0.0
var _reading_mail := false
var _session := {}  # partie en cours : {name, start, coins}
var _home_screen := -1
var _pet_scale_target := 1.0
var _dive_t := 0.0
var _hang_t := 0.0
var _shake := {"last_dx": 0.0, "flips": [], "cd": 0.0}
var _perf_t := 0.0
var perf_locked := false  # --bench
var _mouse_dist := INF
var _cap_interval := 0.15
var games: GameEvents
var situations: PetSituations
var vision: VisionClient
var video_loc: VideoLocator
var _video_rect := Rect2()
var _vision_cd := 20.0
var _guest_win: Window  # fenetre de mini-jeu ou il est assis
var _side_peek := false  # en jeu plein ecran : accroche au bord droit de l'ecran
var _side_hide := 0.0
var _spun := false  # on l'a fait tourner (boutique) : pas de "coucou" au relachement
var _guest_away := 0.0
var _guest_cd := 0.0
var _game_react_cd := 0.0
var _pending_setups: Array = []
var _setup_dialog: ConfirmationDialog
var _thinking_game := false
var _think_t := 12.0
var feedback: FeedbackHub  # « Il s'est trompé » : corrections, jeu de donnees local (voir scripts/feedback/)


func setup(p_stage: PetStage, p_emotes: EmoteLayer) -> void:
	stage = p_stage
	pet = stage.pet
	emotes = p_emotes
	win = get_window()
	capture = EnvCapture.new()
	capture.stage = stage
	add_child(capture)
	win.unfocusable = true
	_apply_settings()
	var u := _usable()
	var hx: float = GameState.settings.get("home_x", -1.0)
	if hx < u.position.x or hx > u.end.x - W:
		hx = u.end.x - W - 160.0 * s
	pos = Vector2(hx, _ground_y())
	win.position = Vector2i(pos)
	_prev_look = _outfit_key()

	Activity.start(DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE))
	Activity.changed.connect(_on_activity_changed)
	Activity.coins_earned.connect(_on_coins)
	Activity.foreground_changed.connect(_on_foreground_changed)
	GameState.equipment_changed.connect(_on_equipment_changed)
	GameState.appearance_changed.connect(_on_appearance_changed)
	GameState.settings_changed.connect(_apply_settings)
	_build_menus()
	hud = GameHud.new()
	hud.stage = stage
	emotes.get_parent().add_child(hud)
	win.files_dropped.connect(_on_files_dropped)
	emotes.say_filter = func(text: String) -> bool:
		if _quiet() and not _reading_mail:
			_queue_mail(text)
			return true
		return false
	clip = ClipboardKeeper.new()
	clip.name = "Clipboard"
	add_child(clip)
	clip.setup(stage, emotes)
	clip.attach_hud(hud)
	clip.mail_requested.connect(_read_mail)
	suggest = SuggestClient.new()
	suggest.name = "Suggest"
	add_child(suggest)
	suggest.candidates_provider = func() -> Array:
		var out := []
		for it in clip.items:
			if it["kind"] == "text":
				out.append(it)
		return out
	suggest.suggestion.connect(func(text_fr: String, _idx: int, _kind: String):
		emotes.say(text_fr + " (clique-moi)", 5.0)
		pet.act_hop(1, 0.1))
	suggest.setup()
	situations = PetSituations.new()
	situations.name = "Situations"
	add_child(situations)
	situations.setup(pet, stage)
	situations.say_callback = func(t: String): _say(t)
	situations.follow_activity = true
	situations.can_switch = func(_sid: String) -> bool: return mode in ["normal", "video"] and state == "ground"
	vision = VisionClient.new()
	vision.name = "Vision"
	vision.service = suggest
	add_child(vision)
	vision.vision_changed.connect(_on_vision)
	vision.setup()
	video_loc = VideoLocator.new()
	video_loc.name = "VideoLocator"
	add_child(video_loc)
	video_loc.video_moved.connect(_on_video_located)
	updater = Updater.new()
	updater.name = "Updater"
	add_child(updater)
	updater.update_available.connect(func(v: String, _notes: String):
		_say("Une nouvelle version est sortie (v%s) ! Clic droit sur moi → Mettre à jour." % v)
		pet.act_hop(2, 0.14))
	updater.update_progress.connect(func(t: String): _say(t))
	updater.update_failed.connect(func(t: String):
		_say(t)
		pet.act_sad())
	GameState.level_up.connect(_on_level_up)
	GameState.quest_completed.connect(_on_quest_completed)
	_setup_games()
	feedback = FeedbackHub.new()
	feedback.name = "Feedback"
	add_child(feedback)
	feedback.setup(self)

	await get_tree().process_frame
	if bool(GameState.stats.get("first_run", true)):
		GameState.stats["first_run"] = false
		GameState.mark_dirty()
		_say(Data.line("hello"))
		pet.act_hop(2)
	else:
		pet.act_stretch()
	if OS.get_cmdline_user_args().has("--open-shop"):
		open_shop("head")
	else:
		get_tree().create_timer(2.5).timeout.connect(_prewarm_ui)


# =========================================================================== reglages / taille
func _apply_settings() -> void:
	var dpi := float(DisplayServer.screen_get_dpi(DisplayServer.window_get_current_screen())) / 96.0
	s = float(GameState.settings.get("size", 1.0)) * clampf(dpi, 1.0, 3.0)
	W = int(260 * s)
	H = int(300 * s)
	margin = 14.0 * s
	win.size = Vector2i(W, H)
	get_viewport().scaling_3d_scale = float(GameState.settings.get("ssaa", 2.0))
	stage.frame(Vector2(W, H), 100.0 * s, margin)
	var refl := bool(GameState.settings.get("reflections", true))
	# visible en partage d'ecran (par defaut) : la capture le voit, on l'efface par inpainting
	var share := bool(GameState.settings.get("share_visible", true))
	win.exclude_from_capture = refl and not share
	capture.inpaint = share
	capture.interval = 0.15 if share else 0.1
	capture.enabled = refl
	if not refl:
		pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.8)
	emotes.talk_enabled = bool(GameState.settings.get("talk", true))
	if state in ["ground", "walk"]:
		pos.y = _ground_y()
	_poly = PackedVector2Array()


func _screen() -> int:
	return DisplayServer.window_get_current_screen()


func _usable() -> Rect2:
	return Rect2(DisplayServer.screen_get_usable_rect(_screen()))


func _screen_rect() -> Rect2:
	var sc := _screen()
	return Rect2(DisplayServer.screen_get_position(sc), DisplayServer.screen_get_size(sc))


## Sol de la barre des taches : son bord haut, meme en masquage automatique (il s'assoit alors en bas de
## l'ecran et remonte avec elle quand elle apparait).
func _taskbar_floor() -> float:
	var u := _usable()
	var sr := _screen_rect()
	var tb: Rect2 = Activity.taskbar_rect
	if tb.size.x > tb.size.y and tb.end.y >= sr.end.y - 4.0 and tb.position.x < sr.end.x and tb.end.x > sr.position.x:
		return clampf(tb.position.y, u.end.y, sr.end.y)
	return u.end.y


func _ground_y() -> float:
	# le sol du compagnon (y = 0) tombe exactement sur le bord superieur de sa surface
	if int(plat["id"]) == 0:
		return _taskbar_floor() - H + margin
	return float(plat["y"]) - H + margin


func _foot_y() -> float:
	return pos.y + H - margin


func _center_x() -> float:
	return pos.x + W * 0.5


func _set_taskbar() -> void:
	var u := _usable()
	plat = {"id": 0, "y": _taskbar_floor(), "x0": u.position.x, "x1": u.end.x, "rect": Rect2()}


## Surfaces disponibles : barre des taches + bords superieurs visibles des fenetres.
func _platforms() -> Array:
	var u := _usable()
	var out: Array = [{"id": 0, "y": _taskbar_floor(), "x0": u.position.x, "x1": u.end.x, "rect": Rect2()}]
	if not bool(GameState.settings.get("windows", true)):
		return out
	var wins: Array = Activity.windows
	var need := _pet_px() * 0.9
	for i in wins.size():
		var w: Dictionary = wins[i]
		if w["max"]:
			continue
		var r: Rect2 = w["rect"]
		var sc := DisplayServer.get_screen_from_rect(Rect2i(r))
		var su := Rect2(DisplayServer.screen_get_usable_rect(maxi(sc, 0)))
		if r.position.y < su.position.y + _pet_px() * 0.8 or r.position.y > su.end.y - 30.0:
			continue
		var segs: Array = [[r.position.x + 8.0, r.end.x - 8.0]]
		for j in i:
			var rj: Rect2 = wins[j]["rect"]
			if rj.position.y < r.position.y + 1.0 and rj.end.y > r.position.y:
				segs = _subtract(segs, rj.position.x, rj.end.x)
		for sg in segs:
			if float(sg[1]) - float(sg[0]) >= need:
				out.append({"id": w["id"], "y": r.position.y, "x0": sg[0], "x1": sg[1], "rect": r})
	return out


func _subtract(segs: Array, a: float, b: float) -> Array:
	var out: Array = []
	for sg in segs:
		var s0: float = sg[0]
		var s1: float = sg[1]
		if b <= s0 or a >= s1:
			out.append(sg)
			continue
		if a > s0:
			out.append([s0, a])
		if b < s1:
			out.append([b, s1])
	return out


## Suit la fenetre sous lui (elle bouge -> il bouge) ; tombe si elle disparait ou est couverte.
func _follow_platform() -> void:
	if int(plat["id"]) == 0:
		var u := _usable()
		plat["y"] = _taskbar_floor()
		plat["x0"] = u.position.x
		plat["x1"] = u.end.x
		return
	var found: Dictionary = {}
	for w in Activity.windows:
		if int(w["id"]) == int(plat["id"]):
			found = w
			break
	if found.is_empty():
		_fall_off()
		return
	if found["max"]:
		_elevator()  # la fenetre est maximisee : il est propulse vers le haut
		return
	var r: Rect2 = found["rect"]
	var old: Rect2 = plat["rect"]
	if old.size != Vector2.ZERO and r.position != old.position:
		var dx := r.position.x - old.position.x
		pos.x += dx
		_track_shake(dx)
	plat["rect"] = r
	plat["y"] = r.position.y
	var cx := _center_x()
	var mine: Array = []
	for p in _platforms():
		if int(p["id"]) == int(plat["id"]):
			mine.append(p)
			if cx >= float(p["x0"]) - 6.0 and cx <= float(p["x1"]) + 6.0:
				plat["x0"] = p["x0"]
				plat["x1"] = p["x1"]
				return
	# la fenetre retrecit sous lui : il est pousse par le bord (tapis roulant)
	for p in mine:
		var x0: float = p["x0"]
		var x1: float = p["x1"]
		if cx > x1 and cx - x1 < 80.0 * s:
			pos.x = x1 - _pet_px() * 0.55 - W * 0.5
			plat["x0"] = x0
			plat["x1"] = x1
			pet.yaw = -1.0
			pet.lean = 0.15
			return
		if cx < x0 and x0 - cx < 80.0 * s:
			pos.x = x0 + _pet_px() * 0.55 - W * 0.5
			plat["x0"] = x0
			plat["x1"] = x1
			pet.yaw = 1.0
			pet.lean = -0.15
			return
	_fall_off()


## Fenetre secouee : il a le vertige (la slime colle, le chrome glisse).
func _track_shake(dx: float) -> void:
	if absf(dx) < 25.0 * s or float(_shake["cd"]) > 0.0:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var last := float(_shake["last_dx"])
	if last != 0.0 and signf(dx) != signf(last):
		var flips: Array = _shake["flips"]
		flips.append(now)
		while not flips.is_empty() and now - float(flips[0]) > 1.4:
			flips.pop_front()
		if flips.size() >= 3:
			flips.clear()
			_shake["cd"] = 4.0
			_on_shaken(dx)
	_shake["last_dx"] = dx


func _on_shaken(dx: float) -> void:
	var kind: String = Data.MATERIALS[pet.material_id]["kind"]
	pet.act_dizzy()
	if kind == "slime":
		_say("Je colle, je colle !")
		return
	await get_tree().create_timer(0.1 if kind in ["chrome", "glass", "liquid", "wood"] else 0.7).timeout
	if state not in ["ground", "walk"]:
		return
	_say("Waaah !")
	_stop_move()
	state = "fall"
	pet.airborne = true
	vel = Vector2(signf(dx) * 900.0 * s, -500.0 * s)


## Fenetre maximisee : il est propulse vers le haut, se cogne, puis retombe.
func _elevator() -> void:
	_stop_move()
	pet.stop_action()
	_set_taskbar()
	state = "fall"
	pet.airborne = true
	vel = Vector2(0, -2300.0 * s)
	_say("Ascenseur !")


func _fall_off() -> void:
	_stop_move()
	pet.stop_action()
	# chute facon dessin anime : il reste suspendu une seconde, regarde la camera, puis tombe
	state = "hang"
	_hang_t = 0.5
	pet.airborne = true
	pet.set_expression("surprised", 1.2)
	pet.look = Vector2(0.0, 0.0)
	vel = Vector2(randf_range(-40.0, 40.0) * s, 0.0)
	if randf() < 0.6:
		_say("Ouh la !")


## Saute sur une autre surface (arc de parabole).
func _jump_to(p: Dictionary) -> void:
	if state not in ["ground", "walk"]:
		return
	_stop_move()
	pet.stop_action()
	var x0: float = p["x0"]
	var x1: float = p["x1"]
	var margin_px := _pet_px() * 0.6
	var tcx := clampf(x1 - 200.0 * s, x0 + margin_px, x1 - margin_px)
	var start := pos
	var end := Vector2(tcx - W * 0.5, float(p["y"]) - H + margin)
	var arc := maxf(90.0 * s, (start.y - end.y) * 0.35 + 70.0 * s)
	state = "jump"
	var crouch := create_tween()
	crouch.tween_property(pet, "squash", -0.2, 0.18)
	await crouch.finished
	pet.airborne = true
	pet.squash = 0.15
	var dur := clampf(start.distance_to(end) / (900.0 * s), 0.45, 1.1)
	var dirx := signf(end.x - start.x)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		pos = start.lerp(end, t) + Vector2(0, -arc * 4.0 * t * (1.0 - t))
		pet.yaw = dirx * 0.6 * sin(t * PI), 0.0, 1.0, dur)
	tw.parallel().tween_property(pet, "squash", 0.0, dur * 0.5)
	await tw.finished
	if state != "jump":
		return
	plat = p.duplicate()
	state = "ground"
	pet.yaw = 0.0
	pet.airborne = false
	pet.land(2.4)
	_think = randf_range(3.0, 6.0)
	GameState.quest_event("climb")
	GameState.add_xp(2)


func _on_foreground_changed(hwnd: int) -> void:
	if not bool(GameState.settings.get("climb", true)) or _climb_cd > 0.0:
		return
	if state != "ground" or pet.busy or pet.sleeping or Activity.fullscreen:
		return
	await get_tree().create_timer(0.7).timeout
	if state != "ground":
		return
	var chance := 0.75 if Activity.proc_name == "explorer" else 0.3
	if randf() > chance:
		return
	for p in _platforms():
		if int(p["id"]) == hwnd and int(p["id"]) != int(plat["id"]):
			_climb_cd = 25.0
			if randf() < 0.4:
				_say("Hop ! Je monte voir.")
			_jump_to(p)
			return


func _pet_px() -> float:
	return pet.width * stage.ppu


# =========================================================================== boucle
func _process(delta: float) -> void:
	if pet.root_node == null:
		return
	var mouse := Vector2(DisplayServer.mouse_get_position())
	var center := pos + stage.camera.unproject_position(pet.center_global())
	var to_mouse := mouse - center
	var dist := to_mouse.length()
	var mouse_moved := mouse.distance_to(_last_mouse) > 1.0
	_mouse_still = 0.0 if mouse_moved else _mouse_still + delta
	_last_mouse = mouse
	_pet_cd -= delta
	_notice_cd -= delta
	_carry_talk_cd -= delta
	_climb_cd -= delta

	match state:
		"drag":
			_process_drag(mouse, delta)
		"fall":
			_process_fall(delta)
		"ground", "walk":
			_follow_platform()
			if state in ["ground", "walk"]:
				pos.y = lerpf(pos.y, _ground_y(), minf(1.0, delta * 18.0))
			_process_mouse_near(mouse, center, to_mouse, dist, mouse_moved, delta)
			_brain(delta)
		"peek":
			_process_peek(dist, delta)
		"spot":
			_process_spot(dist, delta)
		"guest":
			_process_guest()
		"hang":
			_hang_t -= delta
			if _hang_t <= 0.0:
				state = "fall"

	# taille (periscope / visio / esquive)
	var tgt := _pet_scale_target * (0.06 if (_dive_t > 0.0 and state == "spot" and not _side_peek) else 1.0)
	var k := minf(1.0, delta * (16.0 if _dive_t > 0.0 else 4.0))
	pet.scale = pet.scale.lerp(Vector3.ONE * tgt, k)
	_shake["cd"] = maxf(0.0, float(_shake["cd"]) - delta)
	if _mail_ready_t > 0.0 and not _reading_mail:
		_mail_ready_t -= delta
		if _mail_ready_t <= 0.0:
			_mail.clear()
			hud.mail_count = 0

	var ip := Vector2i(pos.round())
	if win.position != ip:
		win.position = ip

	_poly_t -= delta
	if _poly_t <= 0.0:
		_poly_t = 0.06
		_update_polygon()
	_mouse_dist = dist
	_update_perf(delta)
	_game_tick(delta)
	_cap_t -= delta
	if _cap_t <= 0.0 and state != "hidden" and _cap_interval > 0.0:
		if capture.capture(Rect2i(Vector2i(pos), Vector2i(W, H)), center, _pet_px(), pet, _poly):
			_cap_t = _cap_interval


# =========================================================================== evenements de jeu
## Buts, eliminations, morts... (API officielles des jeux ou lecture de l'ecran, voir scripts/games/).
func _setup_games() -> void:
	games = GameEvents.new()
	games.name = "GameEvents"
	add_child(games)
	games.event.connect(_on_game_event)
	games.game_changed.connect(_on_game_changed)
	games.setup_suggested.connect(func(game: String, msg: String):
		var asked: Dictionary = GameState.settings.get("game_setup_asked", {})
		if not asked.has(game):
			_pending_setups.append([game, msg]))
	games.status_changed.connect(func(source: String, status: String):
		if source == "hud" and status in ["black", "frozen"]:
			var hint := games.hud_hint()
			if hint != "":
				_queue_mail("Je ne vois pas ton jeu pour fêter tes exploits : " + hint + "."))


func _on_game_event(kind: String, mine: bool, data: Dictionary) -> void:
	var good := mine and kind in ["goal", "kill", "multikill", "first_blood", "ace", "round_won", "match_won", "objective", "assist"]
	var bad := kind in ["death", "round_lost", "match_lost"] or (kind == "goal" and not mine)
	if not _session.is_empty():
		if kind == "goal" and mine:
			_session["goals"] = int(_session.get("goals", 0)) + 1
		elif kind == "kill" and mine:
			_session["kills"] = int(_session.get("kills", 0)) + 1
		elif kind == "death":
			_session["deaths"] = int(_session.get("deaths", 0)) + 1
	if state in ["hidden", "drag"] or pet.sleeping or not (good or bad or kind == "goal_any"):
		return
	var big := kind in ["multikill", "ace", "match_won", "match_lost"]
	if _game_react_cd > 0.0 and not big:
		return
	_game_react_cd = 2.5
	if good:
		GameState.change_happiness(1.0)
		match kind:
			"goal":
				pet.act_spin()
				emotes.emit_emote("sparkle", 4)
				_say("BUUUT !")
			"multikill":
				pet.act_hop(clampi(int(data.get("n", 2)), 2, 4), 0.14)
				emotes.emit_emote("star", clampi(int(data.get("n", 2)) + 1, 3, 6))
			"ace", "match_won":
				pet.act_dance(3.0)
				emotes.emit_emote("sparkle", 6)
				_say("GG !! Trop fort !")
			"assist", "objective":
				pet.act_nod()
			_:
				pet.act_hop(1, 0.12)
				emotes.emit_emote("sparkle", 2)
	elif bad:
		match kind:
			"match_lost":
				pet.act_sad()
				_say("Pas grave, la prochaine sera la bonne.")
			"death":
				pet.act_sad()
			_:
				pet.act_meh()
	else:
		pet.act_surprised()


func _on_game_changed(_proc: String, genre: String) -> void:
	var thinking := GameCatalog.is_thinking_genre(genre)
	if thinking == _thinking_game:
		return
	_thinking_game = thinking
	if thinking:
		# jeu de reflexion : il met ses lunettes et reflechit avec toi
		if str(pet.slot_items.get("face", "")) == "":
			pet.set_item("face", "round_glasses", GameState.colors_for("round_glasses"))
		pet.set_base_expression("focused")
		_think_t = 4.0
	else:
		var eq: String = GameState.equipped.get("face", "")
		if str(pet.slot_items.get("face", "")) != eq:
			pet.set_item("face", eq, GameState.colors_for(eq) if eq != "" else {})
		pet.set_base_expression("neutral")


func _game_tick(delta: float) -> void:
	_game_react_cd = maxf(0.0, _game_react_cd - delta)
	# il cherche la video a l'ecran seulement quand il en regarde une (et que la vision IA ne l'a pas deja)
	if video_loc:
		var watching := situations != null and situations.is_playing() and PetSituations.WATCH_SIDS.has(situations.current)
		watching = watching or (mode == "video" and state in ["ground", "walk"])
		video_loc.active = watching and not _video_rect.has_area() and state != "hidden"
		if video_loc.active:
			video_loc.ignore_rects = [Rect2(pos, Vector2(W, H))]
			video_loc.within = Rect2() if Activity.windows.is_empty() or Activity.fullscreen else Activity.windows[0]["rect"]
	_vision_cd = maxf(0.0, _vision_cd - delta)
	# retour dans la fenetre du mini-jeu quand elle repasse au premier plan
	_guest_cd = maxf(0.0, _guest_cd - delta)
	if is_instance_valid(_guest_win) and _guest_cd <= 0.0 and state in ["ground", "walk"] and _guest_win.has_focus():
		_guest_cd = 2.0
		_enter_guest(_guest_win)
	if _thinking_game and state in ["ground", "walk", "spot", "peek"] and not pet.busy and not pet.sleeping:
		_think_t -= delta
		if _think_t <= 0.0:
			_think_t = randf_range(14.0, 26.0)
			# « hmm... » : il leve les yeux, se pose la question, puis acquiesce
			pet.look = Vector2(randf_range(-0.6, 0.6), 0.6)
			emotes.emit_emote("question", 1)
			get_tree().create_timer(1.6).timeout.connect(func():
				if _thinking_game and not pet.busy:
					pet.act_nod())
	# proposer l'activation d'une integration officielle, une fois le jeu quitte (jamais en pleine partie)
	if not _pending_setups.is_empty() and mode == "normal" and state in ["ground", "walk"] and not pet.busy \
			and (_setup_dialog == null or not is_instance_valid(_setup_dialog)):
		_ask_game_setup(_pending_setups.pop_front())


func _ask_game_setup(entry: Array) -> void:
	var game: String = entry[0]
	var asked: Dictionary = (GameState.settings.get("game_setup_asked", {}) as Dictionary).duplicate()
	asked[game] = true
	GameState.set_setting("game_setup_asked", asked)
	var dlg := ConfirmationDialog.new()
	_setup_dialog = dlg
	dlg.theme = UITheme.theme()
	dlg.content_scale_factor = clampf(float(DisplayServer.screen_get_dpi(_screen())) / 96.0, 1.0, 3.0)
	dlg.title = "%s veut fêter tes parties" % GameState.pet_name
	dlg.dialog_text = str(entry[1])
	dlg.dialog_autowrap = true
	dlg.min_size = Vector2i(460, 0)
	dlg.ok_button_text = "Oui, active-le"
	dlg.cancel_button_text = "Non merci"
	dlg.always_on_top = true
	add_child(dlg)
	dlg.confirmed.connect(func():
		var err := games.apply_setup(game)
		if err == "":
			_say("C'est fait ! Relance le jeu et je fêterai tes exploits.")
			pet.act_hop(2, 0.14)
		else:
			_say(err)
			pet.act_sad()
		dlg.queue_free())
	dlg.canceled.connect(func():
		_say("D'accord ! Tu pourras changer d'avis dans les réglages.")
		dlg.queue_free())
	dlg.popup_centered()


# =========================================================================== vision (option)
## Ce que l'IA locale voit a l'ecran : une video -> il va s'asseoir dessous et la regarde avec toi ;
## un jeu (meme inconnu du catalogue) -> il sort sa manette si tu en as une.
func _on_vision(top: String, probs: Dictionary, video_rect: Rect2, fullscreen: bool) -> void:
	var video_like := top == "video" or float(probs.get("video", 0.0)) > 0.45
	_video_rect = video_rect if video_like else Rect2()
	if situations:
		situations.watch_point = _video_rect.get_center() if _video_rect.has_area() else Vector2.INF
	if _vision_cd > 0.0 or fullscreen or state != "ground" or pet.sleeping or mode not in ["normal", "video"]:
		return
	if _video_rect.has_area():
		_vision_cd = 60.0
		_watch_video()
	elif top == "game" and float(probs.get("game", 0.0)) > 0.6 and not pet.busy \
			and not Input.get_connected_joypads().is_empty():
		_vision_cd = 90.0
		pet.act_gaming(randf_range(30.0, 60.0))


## Le detecteur de mouvement a trouve (ou perdu) la video.
func _on_video_located(r: Rect2) -> void:
	if not situations:
		return
	situations.watch_point = r.get_center() if r.has_area() else Vector2.INF
	if not r.has_area():
		return
	pet.watch_yaw = Pet.yaw_toward(r.get_center(), Vector2(_center_x(), _foot_y()))
	# loin sur le cote : il va s'asseoir dessous ; sinon il se tourne simplement vers elle
	if absf(r.get_center().x - _center_x()) > 420.0 * s and state == "ground" and _vision_cd <= 0.0 \
			and DisplayServer.get_screen_from_rect(Rect2i(r)) == _screen():
		_vision_cd = 60.0
		_video_rect = r
		await _watch_video()
		_video_rect = Rect2()
	else:
		situations.refresh_watch()


func _watch_video() -> void:
	if situations:
		situations.stop()
	pet.stop_action()
	# sous la video (sur la barre des taches de cet ecran), puis il se tourne vers elle
	var sc := DisplayServer.get_screen_from_rect(Rect2i(_video_rect))
	if sc != _screen():
		return  # video sur un autre ecran : il ne traverse pas les ecrans
	await _walk_to(_video_rect.get_center().x - W * 0.5)
	if state != "ground" or not _video_rect.has_area():
		return
	situations.watch_point = _video_rect.get_center()
	pet.watch_yaw = Pet.yaw_toward(_video_rect.get_center(), Vector2(_center_x(), _foot_y()))
	if not situations.play("video_watch", randf_range(45.0, 80.0)):
		pet.act_popcorn(randf_range(30.0, 60.0))


## Images par seconde, sur-echantillonnage et frequence de capture selon la situation :
## tres fluide quand on le regarde ou qu'on le touche, econome pendant un jeu, presque a l'arret cache.
func _update_perf(delta: float) -> void:
	if perf_locked:
		return
	_perf_t -= delta
	var busy_ui := (_shop != null and is_instance_valid(_shop) and _shop.visible) or PetMenu.current() != null \
		or MiniGames.current() != null or (clip != null and clip.fan_open())
	var active := busy_ui or state in ["drag", "fall"] or _mouse_dist < _pet_px() * 2.0
	if _perf_t > 0.0 and not (active and Engine.max_fps != _perf_fps_full()):
		return
	_perf_t = 0.25
	var fps := _perf_fps_full()
	var ssaa := float(GameState.settings.get("ssaa", 2.0))
	var cap := capture.interval
	var saver := bool(GameState.settings.get("game_saver", true))
	if state == "hidden":
		fps = 8
		cap = -1.0
	elif saver and mode in ["game", "fs", "comp"] and not active:
		# en jeu : le jeu passe d'abord (petite fenetre, 30 images/s, pas de sur-echantillonnage)
		fps = 30
		ssaa = minf(ssaa, 1.0)
		cap = 1.0
	elif mode == "meeting" and not active:
		fps = 30
		cap = 0.6
	elif pet.sleeping and not active:
		fps = 30
		cap = 0.5
	elif _mouse_still > 20.0 and not pet.busy and state == "ground" and Activity.idle_sec > 60.0:
		# personne ne bouge depuis un moment : il respire, ca suffit
		fps = mini(fps, 60) if fps > 0 else 60
	if Engine.max_fps != fps:
		Engine.max_fps = fps
	if not is_equal_approx(get_viewport().scaling_3d_scale, ssaa):
		get_viewport().scaling_3d_scale = ssaa
	_cap_interval = cap


func _perf_fps_full() -> int:
	return int(GameState.settings.get("fps", 120))


func _input(event: InputEvent) -> void:
	if clip and clip.handle_input(event):
		_press = false
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var mouse := Vector2(DisplayServer.mouse_get_position())
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					open_shop("head")
					return
				_press = true
				_press_mouse = mouse
				_grab = mouse - pos
				# retour immediat sous le doigt : il s'enfonce un peu des qu'on appuie
				if state in ["ground", "walk", "spot"]:
					pet.land(0.9)
			else:
				if state == "drag":
					_end_drag()
				elif _press and not _spun:
					_poke()
				_spun = false
				_press = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			PetMenu.open_at(DisplayServer.mouse_get_position(), _menu_items(), _on_menu, self)
	elif event is InputEventMouseMotion and _press and state == "guest" and _guest_win == _shop:
		# dans la boutique : glisser le fait tourner sur lui-meme (comme l'apercu)
		var mm: InputEventMouseMotion = event
		pet.rotation.y += mm.relative.x * 0.012
		_spun = _spun or absf(mm.relative.x) > 1.0
		pet.push_accel(Vector2(mm.relative.x * 3.0, 0), 0.016)
		_press_mouse = Vector2(DisplayServer.mouse_get_position())
	elif event is InputEventMouseMotion and _press and state != "drag":
		var mouse2 := Vector2(DisplayServer.mouse_get_position())
		if mouse2.distance_to(_press_mouse) > 6.0 * s and state in ["ground", "walk", "fall", "peek", "spot", "hang", "guest"]:
			_start_drag()


# =========================================================================== porter / lancer
func _start_drag() -> void:
	_side_peek = false
	if is_instance_valid(_guest_win):
		# on le sort du jeu : le dessin reprend sa place dans la carte
		_guest_win.call("set_external_avatar", false)
		_guest_win = null
		_pet_scale_target = 1.0
	state = "drag"
	pet.airborne = true
	_stop_move()
	pet.stop_action()
	pet.carried = true
	if pet.sleeping:
		pet.sleeping = false
		pet.breath_amp = 1.0
		pet.set_base_expression("neutral")
	var likes: bool = Data.SPECIES[pet.species_id].get("likes_carry", true)
	pet.set_expression("happy" if likes else "surprised", 999.0)
	if _carry_talk_cd <= 0.0 and randf() < 0.5:
		_carry_talk_cd = 6.0
		_say(Data.line("carry" if likes else "carry_no"))
	_drag_hist.clear()
	_prev_drag_vel = Vector2.ZERO


func _process_drag(mouse: Vector2, delta: float) -> void:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_drag()
		return
	var target := mouse - _grab
	var v := (target - pos) / maxf(delta, 0.001)
	var a := (v - _prev_drag_vel) / maxf(delta, 0.001)
	_prev_drag_vel = v
	pet.push_accel(Vector2(a.x, -a.y) / stage.ppu * 0.05, delta)
	pos = target
	var now := Time.get_ticks_msec() / 1000.0
	_drag_hist.append([now, mouse])
	while _drag_hist.size() > 2 and now - float(_drag_hist[0][0]) > 0.1:
		_drag_hist.pop_front()
	pet.look = Vector2(clampf(v.x / 1500.0, -1, 1), clampf(-v.y / 1500.0, -1, 1))


func _end_drag() -> void:
	_press = false
	pet.carried = false
	pet.set_expression(pet.base_expression)
	vel = Vector2.ZERO
	if _drag_hist.size() >= 2:
		var a: Array = _drag_hist[0]
		var b: Array = _drag_hist[_drag_hist.size() - 1]
		var dt := maxf(float(b[0]) - float(a[0]), 0.016)
		vel = (Vector2(b[1]) - Vector2(a[1])) / dt
		vel = vel.limit_length(3000.0 * s)
		if vel.length() > 700.0 * s:
			GameState.change_fun(6.0)
			GameState.add_xp(3)
			GameState.quest_event("throw")
	if mode == "fs":
		# en plein ecran : on le pose ou on veut, et il retient cette place pour ce jeu
		_save_game_spot()
		state = "spot"
		pet.airborne = false
		pet.land(1.2)
		return
	state = "fall"
	pet.airborne = true


func _process_fall(delta: float) -> void:
	vel.y += GRAVITY * s * delta
	vel.x *= pow(0.6, delta)
	var prev_v := vel
	pos += vel * delta
	var sr := _screen_rect()
	var half := W * 0.5 - _pet_px() * 0.5
	if pos.x < sr.position.x - half:
		pos.x = sr.position.x - half
		vel.x = absf(vel.x) * 0.5
	elif pos.x > sr.end.x - W + half:
		pos.x = sr.end.x - W + half
		vel.x = -absf(vel.x) * 0.5
	pet.push_accel(Vector2(0, 0), delta)
	# plafond (fenetre maximisee sous lui = ascenseur) : il se cogne la tete
	var ph := pet.height * stage.ppu * pet.scale.y
	var top_y := pos.y + H - margin - ph
	if vel.y < 0.0 and top_y < sr.position.y:
		pos.y += sr.position.y - top_y
		vel.y = 320.0 * s
		pet.land(2.5)
		pet.act_dizzy()
	# atterrissage sur la surface la plus haute traversee (fenetres, barre des taches)
	var foot := _foot_y()
	var prev_foot := foot - prev_v.y * delta
	var landed: Dictionary = {}
	if vel.y > 0.0:
		var cx := _center_x()
		for p in _platforms():
			var py: float = p["y"]
			if py >= prev_foot - 2.0 and py <= foot and cx >= float(p["x0"]) and cx <= float(p["x1"]):
				if landed.is_empty() or py < float(landed["y"]):
					landed = p
		var tb := _usable().end.y
		if landed.is_empty() and foot >= tb:
			landed = {"id": 0, "y": tb, "x0": _usable().position.x, "x1": _usable().end.x, "rect": Rect2()}
	if not landed.is_empty():
		plat = landed.duplicate()
		var gy := _ground_y()
		pos.y = gy
		var impact := absf(prev_v.y)
		var bounce := float(pet.phys.get("bounce", 0.2))
		pet.airborne = false
		pet.land(impact / stage.ppu * 0.28)
		if impact * bounce > 140.0 * s:
			vel.y = -impact * bounce
			vel.x *= 0.7
			pet.airborne = true
		else:
			vel = Vector2.ZERO
			state = "ground"
			if int(plat["id"]) == 0:
				GameState.set_setting("home_x", pos.x)
			_after_landing(impact)


func _after_landing(impact: float) -> void:
	_think = randf_range(2.0, 4.0)
	if impact > 1700.0 * s:
		var kind: String = Data.MATERIALS[pet.material_id]["kind"]
		if kind in ["slime", "dough"]:
			_say("Splotch !")
			pet.set_expression("surprised", 1.2)
		elif float(pet.phys.get("rigid", 0.0)) > 0.5:
			_say("Toc !")
			pet.act_dizzy()
		else:
			pet.act_dizzy()
	elif impact > 500.0 * s:
		pet.set_expression("happy", 1.0)


func _poke() -> void:
	if state == "peek":
		return
	if hud.mail_count > 0 and not _quiet():
		_read_mail()
		return
	if suggest and suggest.pending_item():
		clip.copy_item(suggest.take_pending())
		_say("C'est copié ! Ctrl+V pour coller.")
		pet.act_hop(1, 0.12)
		return
	if pet.sleeping:
		pet.wake_up()
		_say(Data.line("wake"))
		return
	if feedback:
		feedback.on_pet_clicked()  # avant qu'il ne reagisse : il fait encore son comportement automatique
	_stop_move()
	if randf() < 0.5:
		pet.act_surprised()
	else:
		pet.act_spin()
	if randf() < 0.4:
		_say(Data.line("poke"))
	GameState.change_happiness(0.5)
	GameState.change_fun(1.0)
	GameState.add_xp(1)
	GameState.quest_event("poke")


# =========================================================================== souris proche / caresses
func _process_mouse_near(mouse: Vector2, center: Vector2, to_mouse: Vector2, dist: float, moved: bool, delta: float) -> void:
	var local := mouse - pos
	var hovering := _poly.size() >= 3 and Geometry2D.is_point_in_polygon(local, _poly) and dist < _pet_px() * 0.6 		and not (clip and clip.is_over(local))
	var near_r := 170.0 * s
	var near := dist < near_r
	if not pet.busy or pet.expression == "neutral":
		if near and not pet.sleeping:
			pet.look = Vector2(clampf(to_mouse.x / near_r, -1, 1), clampf(-to_mouse.y / near_r, -1, 1))
		elif not pet.busy:
			pet.look = Vector2.ZERO
	# la souris arrive : petite reaction
	if near and not _was_near and _notice_cd <= 0.0 and not pet.busy and not pet.sleeping and not _press:
		_notice_cd = 25.0
		if randf() < 0.5:
			pet.act_hop(1, 0.1)
		else:
			pet.set_expression("happy", 1.2)
			pet.act_wiggle(1.0)
	_was_near = near
	# survol : on voit ses besoins, seulement si l'un d'eux est bas (sinon rien ne vient gener ce qu'il tient)
	var low_need := minf(minf(GameState.hunger, GameState.energy), minf(GameState.fun, GameState.happiness)) < 35.0
	_hover_needs_t = 1.2 if (hovering and low_need) else maxf(0.0, _hover_needs_t - delta)
	hud.show_needs(_hover_needs_t > 0.0 and not _press)
	# caresses : la souris frotte le compagnon
	if hovering and moved and not _press:
		_rub += mouse.distance_to(_last_mouse + Vector2(0.01, 0)) + 4.0
		_rub_timer = 1.5
		_hover_time += delta
		if pet.sleeping and _hover_time > 1.5:
			pet.wake_up()
	else:
		_rub_timer -= delta
		if _rub_timer <= 0.0:
			_rub = 0.0
			_hover_time = 0.0
	if _rub > 220.0 * s and _pet_cd <= 0.0 and not pet.sleeping:
		_rub = 0.0
		_pet_cd = 3.5
		pet.act_petted()
		GameState.change_happiness(2.0)
		GameState.change_fun(4.0)
		GameState.add_xp(2)
		GameState.quest_event("pet")
		GameState.stats["pets"] = int(GameState.stats.get("pets", 0)) + 1
		if randf() < 0.45:
			_say(Data.line("pet"))
	# discretion : la souris travaille juste a cote -> il se pousse
	if bool(GameState.settings.get("discreet", true)) and near and not hovering and not _press and dist < 120.0 * s:
		if moved:
			_near_time += delta
	else:
		_near_time = maxf(0.0, _near_time - delta * 2.0)
	if _near_time > 3.0 and state == "ground" and not pet.sleeping:
		_near_time = 0.0
		var dir := -signf(to_mouse.x) if absf(to_mouse.x) > 4.0 else 1.0
		_walk_to(pos.x + dir * 240.0 * s)
		if randf() < 0.3:
			_say("Je te laisse la place !")


# =========================================================================== cerveau
func _brain(delta: float) -> void:
	_grumpy_t -= delta
	_attention_t -= delta
	_needs_t -= delta
	if state != "ground" or pet.busy:
		return
	if mode == "meeting":
		return  # en visio : il reste sage et immobile
	_think -= delta
	if _think > 0.0:
		return
	_think = randf_range(6.0, 13.0)
	# devant une video on ne touche a rien : ce n'est pas une absence
	var watching_video := mode == "video" or (video_loc != null and video_loc.rect.has_area()) 		or (situations != null and situations.is_playing() and PetSituations.WATCH_SIDS.has(situations.current))
	var away := Activity.available and Activity.idle_sec > 180.0 and not watching_video
	if (away or GameState.energy < 5.0) and not pet.sleeping:
		_slept_at = Time.get_ticks_msec() / 1000.0
		pet.act_sleep()
		return
	if pet.sleeping:
		return
	if Activity.wants_break_hint():
		_say(Data.line("break"))
		pet.act_drink()
		return
	if _grumpy_t <= 0.0:
		_grumpy_t = randf_range(240.0, 420.0)
		if _wearing_hated():
			_say(Data.line("grumpy"))
			pet.act_angry()
			return
	if _needs_t <= 0.0:
		_needs_t = randf_range(300.0, 480.0)
		if GameState.hunger < 25.0:
			_say(Data.line("hungry"))
			hud.show_needs(true)
			_hover_needs_t = 3.0
			pet.act_sad()
			return
		if GameState.fun < 25.0:
			_say(Data.line("bored"))
			pet.act_hop(2, 0.14)
			return
	if _attention_t <= 0.0:
		_attention_t = randf_range(360.0, 600.0)
		if GameState.happiness < 30.0:
			_say(Data.line("hungry_attention"))
			pet.act_sad()
			return
	var r := randf()
	# il imite ce que tu fais (mails, code, Claude Code, musique, Excel, lecture... voir data/situations.json)
	if Activity.is_active() or mode == "video":
		var sid := PetSituations.situation_for_activity()
		if sid == "gaming" and Input.get_connected_joypads().is_empty() and r > 0.4:
			sid = ""
		if sid != "" and sid != "afk" and mode in ["normal", "video", "game"] and r < 0.85:
			if situations.play(sid, randf_range(30.0, 60.0)):
				return
	var choices := {"look": 3.0, "hop": 1.5, "wiggle": 1.5, "stretch": 1.0}
	if Activity.category in ["browse", "media", "other"] or (Activity.available and Activity.idle_sec > 30.0):
		choices["phone"] = 2.0
	if int(plat["id"]) != 0:
		choices["look"] = 4.0  # perche sur une fenetre : il observe
	if GameState.settings.get("wander", true):
		choices["walk"] = 3.0
	if GameState.happiness > 60.0:
		choices["spin"] = 1.0
		choices["dance"] = 0.8
	if GameState.energy < 40.0:
		choices["yawn"] = 2.0
	match _weighted(choices):
		"look": pet.act_look_around()
		"hop": pet.act_hop(2, 0.12)
		"wiggle": pet.act_wiggle(1.5)
		"stretch": pet.act_stretch()
		"spin": pet.act_spin()
		"dance": pet.act_dance(3.0)
		"yawn": pet.act_yawn()
		"phone": pet.act_phone(randf_range(10.0, 25.0))
		"walk":
			var home: float = GameState.settings.get("home_x", pos.x) if int(plat["id"]) == 0 else pos.x
			_walk_to(home + randf_range(-170.0, 170.0) * s)


func _weighted(d: Dictionary) -> String:
	var total := 0.0
	for k in d:
		total += float(d[k])
	var r := randf() * total
	for k in d:
		r -= float(d[k])
		if r <= 0.0:
			return k
	return d.keys()[0]


func _wearing_hated() -> bool:
	for slot in GameState.equipped:
		var id: String = GameState.equipped[slot]
		if id != "" and Data.preference(GameState.species, id, GameState.colors_for(id)["main"]) == Data.HATE:
			return true
	return false


func _walk_to(target_x: float) -> void:
	var minx := float(plat["x0"]) - W * 0.5 + _pet_px() * 0.6
	var maxx := float(plat["x1"]) - W * 0.5 - _pet_px() * 0.6
	target_x = clampf(target_x, minx, maxx)
	if absf(target_x - pos.x) < 10.0:
		return
	state = "walk"
	var dir := signf(target_x - pos.x)
	var tw := create_tween()
	tw.tween_property(pet, "yaw", dir * 1.1, 0.25)
	await tw.finished
	while state == "walk" and absf(target_x - pos.x) > 3.0:
		var step := clampf(target_x - pos.x, -38.0 * s, 38.0 * s)
		_move_tween = create_tween()
		_move_tween.tween_property(self, "pos:x", pos.x + step, 0.42).set_trans(Tween.TRANS_SINE)
		await pet.act_hop(1, 0.11)
		if _move_tween and _move_tween.is_running():
			await _move_tween.finished
	if state == "walk":
		state = "ground"
	var tw2 := create_tween()
	tw2.tween_property(pet, "yaw", 0.0, 0.3)


func _stop_move() -> void:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	if state == "walk":
		state = "ground"
	pet.yaw = 0.0


# =========================================================================== plein ecran
func _on_activity_changed() -> void:
	_update_mode()
	if Activity.is_active() and pet.sleeping and state == "ground":
		pet.wake_up()
		var slept := Time.get_ticks_msec() / 1000.0 - _slept_at
		_say(Data.line("welcome_back" if slept > 300.0 else "wake"))
	if Activity.is_active() and not pet.sleeping and state == "ground" and not pet.busy:
		if Activity.category == "game" and randf() < 0.3:
			_say(Data.line("game"))


# =========================================================================== modes de vie
func _compute_mode() -> String:
	if Activity.meeting:
		return "meeting"
	if Activity.is_competitive() and bool(GameState.settings.get("competitive_hide", true)):
		return "comp"
	if Activity.fullscreen and Activity.category in ["game", "media"]:
		return "fs"
	if Activity.category == "game":
		return "game"
	if Activity.category == "media":
		return "video"
	return "normal"


## Silence radio (les bulles vont dans la boite aux lettres) : en jeu, en visio, en stream.
func _quiet() -> bool:
	return mode in ["game", "fs", "comp", "meeting"] or Activity.recording


func _update_mode() -> void:
	var m := _compute_mode()
	if m == mode:
		return
	var old := mode
	mode = m
	emotes.mute_emotes = m == "meeting"
	var gaming := ["game", "fs", "comp"]
	if gaming.has(m) and not gaming.has(old):
		_session = {"name": Activity.game_name, "start": Time.get_ticks_msec() / 1000.0, "kills": 0, "deaths": 0, "goals": 0,
			"coins": int(GameState.stats.get("earned_total", 0)), "comp": m == "comp"}
	if gaming.has(old) and not gaming.has(m):
		_end_game_session()
	if old in ["fs", "comp", "meeting"]:
		_leave_special()
	match m:
		"comp":
			_enter_hidden()
		"fs":
			_enter_fs()
		"meeting":
			_enter_meeting()
		"video":
			if state == "ground" and not pet.busy and not pet.sleeping:
				if not situations.play(PetSituations.situation_for_activity(), 45.0):
					var vp := situations.video_point()
					pet.watch_yaw = Pet.yaw_toward(vp, Vector2(_center_x(), _foot_y())) if vp != Vector2.INF else PI * 0.82
					pet.act_popcorn(randf_range(30.0, 60.0))
		"game":
			if state == "ground" and not pet.busy and not Input.get_connected_joypads().is_empty():
				pet.act_gaming(60.0)
	if not _quiet() and not _mail.is_empty():
		hud.mail_count = _mail.size()
		_mail_ready_t = 120.0
		if state == "ground" and not pet.busy:
			pet.act_hop(1, 0.1)


func _end_game_session() -> void:
	if _session.is_empty():
		return
	var dur := Time.get_ticks_msec() / 1000.0 - float(_session["start"])
	var coins := int(GameState.stats.get("earned_total", 0)) - int(_session["coins"])
	var name_: String = str(_session["name"]) if str(_session["name"]) != "" else "ton jeu"
	var feats := ""
	if int(_session.get("goals", 0)) > 0:
		feats += " · %d but%s" % [_session["goals"], "s" if int(_session["goals"]) > 1 else ""]
	if int(_session.get("kills", 0)) > 0:
		feats += " · %d élimination%s" % [_session["kills"], "s" if int(_session["kills"]) > 1 else ""]
	if dur >= 20.0 * 60.0 or (feats != "" and dur >= 5.0 * 60.0):
		_queue_mail("Session de %s : %s%s · +%d pièces. GG !" % [name_, _fmt_dur(dur), feats, coins])
	elif bool(_session.get("comp", false)) and dur >= 5.0 * 60.0:
		_queue_mail("GG ?")
	_session = {}


static func _fmt_dur(sec: float) -> String:
	var m := int(sec / 60.0)
	if m >= 60:
		return "%d h %02d" % [m / 60, m % 60]
	return "%d min" % m


func _queue_mail(text: String) -> void:
	if text == "" or _mail.has(text):
		return
	_mail.append(text)
	if _mail.size() > 8:
		_mail.pop_front()


func _read_mail() -> void:
	_reading_mail = true
	hud.mail_count = 0
	_mail_ready_t = 0.0
	pet.set_expression("happy", 1.5)
	var msgs := _mail.duplicate()
	_mail.clear()
	for t in msgs:
		emotes.say(t, 3.4)
		await get_tree().create_timer(3.6).timeout
	_reading_mail = false


## Ecran du jeu (la fenetre au premier plan est en tete de liste).
func _game_screen() -> int:
	if not Activity.windows.is_empty():
		return DisplayServer.get_screen_from_rect(Rect2i(Activity.windows[0]["rect"]))
	return _screen()


func _enter_fs() -> void:
	_stop_move()
	pet.stop_action()
	var gs := _game_screen()
	var n := DisplayServer.get_screen_count()
	if n > 1:
		# 1) un deuxieme ecran : il y va et joue "en parallele"
		for i in n:
			if i == gs:
				continue
			_home_screen = gs
			var u := Rect2(DisplayServer.screen_get_usable_rect(i))
			pos = Vector2(u.end.x - W - 160.0 * s, u.end.y - H + margin - 120.0 * s)
			_set_taskbar()
			state = "fall"
			vel = Vector2.ZERO
			pet.airborne = true
			return
	# 2) sa place pour ce jeu (la ou tu l'as pose une fois)
	var spots: Dictionary = GameState.settings.get("game_spots", {})
	var spot = spots.get(Activity.proc_name)
	if spot != null:
		var sr := _screen_rect()
		pos = sr.position + Vector2(float(spot["x"]), float(spot["y"]))
		state = "spot"
		_pet_scale_target = float(spot.get("scale", 0.8))
		pet.airborne = false
		return
	# 3) sur le cote, en bas : il regarde ta partie avec son pop-corn (il plonge si ta souris approche)
	if bool(GameState.settings.get("hide_fullscreen", false)):
		_enter_hidden()
	else:
		_enter_side()


## En jeu plein ecran : il se cache a moitie derriere le bord droit de l'ecran, aux deux tiers de la hauteur,
## et regarde ta partie. Il disparait derriere le bord si ta souris approche.
func _enter_side() -> void:
	pet.stop_action()
	_side_peek = true
	_pet_scale_target = 0.75
	pos = _side_pos(0.0)
	state = "spot"
	pet.airborne = true  # accroche au bord, pas pose au sol
	var t := create_tween()
	t.tween_property(pet, "yaw", -0.95, 0.5).set_trans(Tween.TRANS_SINE)


## Position accrochee au bord droit (hide : 0 = il regarde, 1 = completement cache derriere le bord).
func _side_pos(hide: float) -> Vector2:
	var sr := _screen_rect()
	var w := _pet_px() * 0.75
	var cx := sr.end.x - w * lerpf(0.12, -0.7, hide)  # ~60 % du corps visible
	var foot := sr.position.y + sr.size.y * 0.72
	return Vector2(cx - W * 0.5, foot - (H - margin))


func _save_game_spot() -> void:
	if Activity.proc_name == "":
		return
	var sr := _screen_rect()
	var spots: Dictionary = (GameState.settings.get("game_spots", {}) as Dictionary).duplicate()
	spots[Activity.proc_name] = {"x": pos.x - sr.position.x, "y": pos.y - sr.position.y, "scale": _pet_scale_target}
	GameState.set_setting("game_spots", spots)
	emotes.emit_emote("sparkle", 2)


func _process_spot(dist: float, delta: float) -> void:
	# esquive rapide : la souris approche -> il plonge, et revient 3 s plus tard
	if dist < 120.0 * s:
		_dive_t = 3.0
	_dive_t = maxf(0.0, _dive_t - delta)
	if _side_peek:
		# il glisse derriere le bord de l'ecran au lieu de rapetisser
		_side_hide = move_toward(_side_hide, 1.0 if _dive_t > 0.0 else 0.0, delta * (5.0 if _dive_t > 0.0 else 1.6))
		pos = _side_pos(_side_hide)
		pet.look = Vector2(-0.75, 0.05 + 0.06 * sin(Time.get_ticks_msec() / 900.0))
		return
	pet.look = Vector2(0.0, 0.1)


func _enter_hidden() -> void:
	_stop_move()
	pet.stop_action()
	state = "hidden"
	var sr := _screen_rect()
	_move_tween = create_tween()
	_move_tween.tween_property(self, "pos:y", sr.end.y + 40.0, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


func _enter_meeting() -> void:
	# en visio : tout petit dans le coin, sans un bruit
	_stop_move()
	pet.stop_action()
	_pet_scale_target = 0.55
	if state in ["ground", "walk"]:
		var u := _usable()
		_move_tween = create_tween()
		_move_tween.tween_property(self, "pos:x", u.end.x - W * 0.5 - 140.0 * s, 0.6).set_trans(Tween.TRANS_SINE)
	pet.set_base_expression("focused")


func _leave_special() -> void:
	_pet_scale_target = 1.0
	_dive_t = 0.0
	pet.set_base_expression("neutral")
	if state in ["peek", "hidden", "spot"] or _home_screen >= 0:
		_home_screen = -1
		_exit_peek()


func _enter_peek() -> void:
	_stop_move()
	pet.stop_action()
	state = "peek"
	_pet_scale_target = 0.55
	pet.yaw = 0.0
	pet.look = Vector2(0.0, 0.35)


func _process_peek(dist: float, delta: float) -> void:
	# periscope : seul le haut de sa tete depasse du bas de l'ecran ; il plonge si la souris approche
	var sr := _screen_rect()
	var ph := pet.height * stage.ppu * pet.scale.y
	if dist < 120.0 * s:
		_dive_t = 3.0
	_dive_t = maxf(0.0, _dive_t - delta)
	var hidden_frac := 1.1 if _dive_t > 0.0 else 0.58
	var ty := sr.end.y - H + margin + ph * hidden_frac
	pos.y = lerpf(pos.y, ty, minf(1.0, delta * (16.0 if _dive_t > 0.0 else 3.0)))
	pos.x = lerpf(pos.x, sr.end.x - W * 0.5 - 260.0 * s, minf(1.0, delta * 3.0))
	pet.look = Vector2(0.0, 0.35)


func _exit_peek() -> void:
	# retour a la maison : il retombe sur la barre des taches, a sa place habituelle
	_side_peek = false
	_side_hide = 0.0
	_set_taskbar()
	_pet_scale_target = 1.0
	var home: float = GameState.settings.get("home_x", pos.x)
	pos.x = home
	pos.y = minf(pos.y, _usable().end.y - H + margin - 200.0 * s)
	state = "fall"
	vel = Vector2.ZERO
	pet.airborne = true
	var t := create_tween()
	t.tween_property(pet, "yaw", 0.0, 0.4)
	pet.look = Vector2.ZERO


# =========================================================================== zone cliquable
func _update_polygon() -> void:
	var poly := PackedVector2Array()
	if state == "hidden":
		poly = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)])
	else:
		var pts := pet.screen_points(stage.camera)
		if emotes.is_busy():
			var b := emotes.bounds()
			if b.size != Vector2.ZERO:
				pts.append_array(PackedVector2Array([b.position, Vector2(b.end.x, b.position.y), b.end, Vector2(b.position.x, b.end.y)]))
		if clip:
			var cb := clip.bounds()
			if cb.size != Vector2.ZERO:
				pts.append_array(PackedVector2Array([cb.position, Vector2(cb.end.x, cb.position.y), cb.end, Vector2(cb.position.x, cb.end.y)]))
		if hud and hud.is_busy():
			var hb := hud.bounds()
			if hb.size != Vector2.ZERO:
				pts.append_array(PackedVector2Array([hb.position, Vector2(hb.end.x, hb.position.y), hb.end, Vector2(hb.position.x, hb.end.y)]))
		if pts.size() < 3:
			return
		# l'ombre portee sur le bureau doit rester visible : on agrandit la zone dans sa direction
		var so := _shadow_offset()
		if so.length() > 1.0:
			var n0 := pts.size()
			for i in n0:
				pts.append(pts[i] + so)
		var hull := Geometry2D.convex_hull(pts)
		var off := Geometry2D.offset_polygon(hull, 3.0 * s)
		poly = off[0] if off.size() > 0 else hull
		var clip := Rect2(Vector2.ZERO, Vector2(W, H))
		if state == "peek" or _side_peek:
			var sr := _screen_rect()
			clip = clip.intersection(Rect2(sr.position - pos, sr.size))
		var clipped := Geometry2D.intersect_polygons(poly, PackedVector2Array([
			clip.position, Vector2(clip.end.x, clip.position.y), clip.end, Vector2(clip.position.x, clip.end.y)]))
		if clipped.is_empty():
			return
		poly = clipped[0]
	if not _poly_changed(poly):
		return
	_poly = poly
	DisplayServer.window_set_mouse_passthrough(poly)


func _shadow_offset() -> Vector2:
	if pet.airborne:
		return Vector2.ZERO
	var dir := -stage.key_light.global_transform.basis.z
	var c := pet.center_global()
	var wall_z := -PetStage.WALL_OFFSET
	if absf(dir.z) < 0.01:
		return Vector2.ZERO
	var t := (wall_z - c.z) / dir.z
	return stage.camera.unproject_position(c + dir * t) - stage.camera.unproject_position(c)


func _poly_changed(p: PackedVector2Array) -> bool:
	if p.size() != _poly.size():
		return true
	for i in p.size():
		if p[i].distance_squared_to(_poly[i]) > 2.0:
			return true
	return false


# =========================================================================== evenements
func _say(text: String) -> void:
	emotes.say(text)


func _on_coins(amount: int, _kind: String) -> void:
	emotes.coin_pop(amount)
	if randf() < 0.06:
		_say(Data.line("coins"))


func _outfit_key() -> Dictionary:
	var d := {}
	for slot in GameState.equipped:
		var id: String = GameState.equipped[slot]
		d[slot] = id + "|" + (str(GameState.item_colors.get(id, {})) if id != "" else "")
	return d


func _on_equipment_changed() -> void:
	var now := _outfit_key()
	for slot in now:
		if now[slot] == _prev_look.get(slot, ""):
			continue
		var id: String = GameState.equipped[slot]
		pet.set_item(slot, id, GameState.colors_for(id) if id != "" else {})
		if id == "":
			continue
		var main: Color = GameState.colors_for(id)["main"]
		var level := Data.preference(GameState.species, id, main)
		GameState.discover(id, level)
		if pet.sleeping:
			pet.wake_up()
		pet.react_to_item(level)
		var line := Data.line(level)
		if Data.is_fav_color(GameState.species, main) and randf() < 0.6:
			line = Data.line("fav_color")
		_say(line)
		GameState.change_happiness(level * 2.0)
		GameState.quest_event("outfit")
	_prev_look = now


func _on_appearance_changed() -> void:
	stage.build_from_state()
	_prev_look = _outfit_key()
	_poly = PackedVector2Array()
	pet.act_spin()
	_say("Ooh, tout neuf !")


# =========================================================================== manger des fichiers
func _on_files_dropped(files: PackedStringArray) -> void:
	if _eating or state in ["drag", "fall", "jump"]:
		return
	if not bool(GameState.settings.get("eat_files", true)):
		_say("Je ne mange pas les fichiers (voir les réglages).")
		return
	if GameState.hunger >= 97.0:
		_say(Data.line("full"))
		pet.act_shake_no()
		return
	var ok: Array = []
	var refused := ""
	for f in files:
		var why := Feeder.refusal(f)
		if why == "":
			ok.append(f)
		else:
			refused = why
	if ok.is_empty():
		_say(refused if refused != "" else "Je ne peux pas manger ça.")
		pet.act_shake_no()
		return
	if ok.size() > Feeder.MAX_PER_MEAL:
		ok = ok.slice(0, Feeder.MAX_PER_MEAL)
	var total := 0
	for f in ok:
		total += Feeder.size_of(f)
	var need_confirm := not bool(GameState.settings.get("eat_confirmed", false)) or ok.size() > 5 or total > 500 * 1048576
	if need_confirm:
		var dlg := ConfirmationDialog.new()
		dlg.theme = UITheme.theme()
		dlg.content_scale_factor = clampf(float(DisplayServer.screen_get_dpi(_screen())) / 96.0, 1.0, 3.0)
		dlg.title = "%s a faim !" % GameState.pet_name
		dlg.dialog_text = "%s va manger %d fichier%s (%s).\n\nIls iront dans la Corbeille de Windows :\ntu pourras toujours les restaurer." % [
			GameState.pet_name, ok.size(), "s" if ok.size() > 1 else "", Feeder.human_size(total)]
		dlg.ok_button_text = "Miam, vas-y !"
		dlg.cancel_button_text = "Non, garde-les"
		dlg.always_on_top = true
		add_child(dlg)
		dlg.confirmed.connect(func():
			GameState.set_setting("eat_confirmed", true)
			_eat_files(ok)
			dlg.queue_free())
		dlg.canceled.connect(func():
			pet.act_sad()
			dlg.queue_free())
		dlg.popup_centered()
		return
	_eat_files(ok)


func _eat_files(files: Array) -> void:
	_eating = true
	_stop_move()
	if pet.sleeping:
		pet.sleeping = false
		pet.breath_amp = 1.0
		pet.set_base_expression("neutral")
	var drop := Vector2(DisplayServer.mouse_get_position()) - pos
	var eaten := 0
	for f in files:
		if GameState.hunger >= 98.0:
			_say(Data.line("full"))
			break
		var kind := Data.food_kind(f)
		var pref := Data.food_pref(GameState.species, kind)
		var size := Feeder.size_of(f)
		hud.fly_food(kind, drop + Vector2(randf_range(-10, 10), randf_range(-10, 10)), 0.45)
		pet.act_eat(pref)
		await get_tree().create_timer(0.45).timeout
		if Feeder.eat(f) != OK:
			_say("Beurk, je n'arrive pas à manger ça...")
			pet.act_shake_no()
			await get_tree().create_timer(1.0).timeout
			continue
		var nut := Feeder.nutrition(size) * (1.3 if pref >= 2 else (0.7 if pref < 0 else 1.0))
		GameState.feed(nut, size)
		GameState.change_happiness(1.0 + maxf(0.0, pref))
		eaten += 1
		await get_tree().create_timer(0.95).timeout
	if eaten > 0:
		GameState.quest_event("feed")
		var last_pref := Data.food_pref(GameState.species, Data.food_kind(files[0]))
		_say(Data.line("yum_love" if last_pref >= 2 else ("yum_meh" if last_pref < 0 else "yum")))
		_hover_needs_t = 2.5
	_eating = false


func _on_level_up(lv: int, rewards: Array) -> void:
	var texts: Array = []
	for r in rewards:
		texts.append(str(r["text"]))
	hud.banner("Niveau %d !" % lv, " · ".join(texts), 4.5)
	pet.act_spin()
	emotes.emit_emote("sparkle", 5)


func _on_quest_completed(q: Dictionary) -> void:
	emotes.coin_pop(int(q["coins"]))
	_say("Quête réussie : %s !" % GameState.quest_text(q))


# =========================================================================== menus
func _build_menus() -> void:
	_tray = StatusIndicator.new()
	_tray.tooltip = "Pompom"
	_tray.icon = load("res://icon.svg")
	add_child(_tray)
	_tray.pressed.connect(func(button: int, p: Vector2i):
		if button == MOUSE_BUTTON_LEFT:
			open_shop("head")
		elif button == MOUSE_BUTTON_RIGHT:
			PetMenu.open_at(p, _menu_items(), _on_menu, self))


## Entrees du menu (clic droit sur lui / icone de la zone de notification).
func _menu_items() -> Array:
	var items: Array = PetMenu.default_items(pet.sleeping)
	var extra := [
		{"id": 10, "label": "Danser", "icon": "sparkle", "tint": UITheme.PEACH},
		{"id": 14, "label": "Jouer avec moi", "icon": "gamepad", "tint": UITheme.SKY, "hint": "Puissance 4, Snake…"},
		{"id": 11, "label": "Changer de compagnon", "icon": "body", "tint": UITheme.LAVENDER},
	]
	var at := items.size()
	for i in items.size():
		if int(items[i].get("id", -1)) == 4:
			at = i + 1
			break
	for e in extra:
		items.insert(at, e)
		at += 1
	if updater and not updater.latest.is_empty():
		items.insert(0, {"id": 12, "label": "Mettre à jour (v%s)" % updater.latest["version"], "icon": "sparkle",
			"tint": UITheme.GOOD, "hint": "Nouveau !"})
	else:
		for i in items.size():
			if int(items[i].get("id", -1)) == 7:
				items.insert(i + 1, {"id": 13, "label": "Chercher une mise à jour", "icon": "sparkle", "tint": UITheme.SKY,
					"hint": "v" + Updater.current_version()})
				break
	for i in items.size():
		if int(items[i].get("id", -1)) == 7:
			items.insert(i, {"id": 15, "label": "Il s'est trompé…", "icon": "pencil", "tint": UITheme.PEACH})
			break
	return items


## Verification manuelle des mises a jour (menu ou reglages) : il repond dans une bulle.
func check_updates_now() -> void:
	if updater == null:
		return
	if not updater.latest.is_empty():
		_say("La version %s est prête ! Clic droit sur moi → Mettre à jour." % updater.latest["version"])
		return
	_say("Je regarde s'il y a du nouveau…")
	pet.act_look_around()
	updater.check_now()
	var found: bool = await updater.check_finished
	if not found:
		_say("Tu as déjà la toute dernière version (v%s) !" % Updater.current_version())


func _on_menu(id: int) -> void:
	match id:
		1: open_shop("head")
		2: open_shop("look")
		3: open_shop("stats")
		4:
			pet.act_petted()
			GameState.change_happiness(2.0)
			_say(Data.line("pet"))
		5:
			if pet.sleeping:
				pet.wake_up()
			else:
				_slept_at = Time.get_ticks_msec() / 1000.0
				pet.act_sleep()
		6:
			_stop_move()
			_set_taskbar()
			state = "fall"
			vel = Vector2.ZERO
			var u := _usable()
			pos.x = u.end.x - W - 160.0 * s
			GameState.set_setting("home_x", pos.x)
		7: open_shop("settings")
		10:
			pet.act_dance(4.0)
			GameState.change_fun(3.0)
		11: open_shop("look")
		12: updater.install()
		13: check_updates_now()
		14: open_minigames()
		15:
			if feedback:
				feedback.open_card("menu")
		9: quit()


func open_shop(tab := "head") -> void:
	if _shop == null or not is_instance_valid(_shop):
		_shop = ShopWindow.new()
		_shop.keep_alive = true
		add_child(_shop)
	_shop.call("open", tab)
	# il saute dans la boutique : un seul compagnon, c'est lui qu'on habille
	if _guest_win != _shop or state != "guest":
		_enter_guest(_shop)


## Mini-jeux contre lui (Puissance 4, Snake duel, Morpion) : il reagit aussi sur le bureau.
func open_minigames(game_id := "") -> void:
	var already := MiniGames.current() != null
	var w := MiniGames.open(stage, emotes, self, game_id)
	if already or w == null:
		return
	pet.set_base_expression("focused")
	_enter_guest(w)
	w.connect("pompom_reaction", _on_minigame_reaction)
	w.connect("game_result", func(info: Dictionary):
		GameState.quest_event("minigame")
		if str(info.get("result", "")) == "win":
			GameState.change_happiness(2.0))
	w.connect("closed", func():
		pet.set_base_expression("neutral")
		_exit_guest()
		if state in ["ground", "walk"]:
			pet.act_hop(1, 0.1))


func _on_minigame_reaction(kind: String, _text: String) -> void:
	if state not in ["ground", "walk", "guest"]:
		return
	match kind:
		"pompom_wins":
			pet.act_dance(2.5)
		"user_wins":
			pet.act_surprised()
			emotes.emit_emote("sparkle", 3)
		"draw":
			pet.act_nod()
		"worried", "behind":
			if not pet.busy:
				pet.act_meh()
		"sure_win", "lead":
			if not pet.busy:
				pet.act_hop(1, 0.08)


## Il saute dans la fenetre du mini-jeu et s'assoit dans sa carte (a la place du dessin 2D).
func _enter_guest(w: Window) -> void:
	_guest_win = w
	_guest_away = 0.0
	for _i in 3:
		await get_tree().process_frame  # mise en page de la fenetre
	if not is_instance_valid(w) or state not in ["ground", "walk", "fall", "spot", "peek"]:
		return
	var info: Dictionary = w.call("avatar_screen_info")
	if info.is_empty():
		return
	_stop_move()
	pet.stop_action()
	if situations:
		situations.stop()
	w.call("set_external_avatar", true)
	var start := pos
	var crouch := create_tween()
	crouch.tween_property(pet, "squash", -0.2, 0.16)
	await crouch.finished
	state = "guest_jump"
	pet.airborne = true
	pet.squash = 0.15
	_pet_scale_target = _guest_scale(info)
	var dur := clampf(start.distance_to(_guest_pos(info)) / (1400.0 * s), 0.45, 0.9)
	var arc := maxf(120.0 * s, absf(start.y - _guest_pos(info).y) * 0.3 + 90.0 * s)
	var dirx := signf(_guest_pos(info).x - start.x)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		var end := start
		if is_instance_valid(w):
			var inf2: Dictionary = w.call("avatar_screen_info")
			if not inf2.is_empty():
				end = _guest_pos(inf2)
		pos = start.lerp(end, t) + Vector2(0, -arc * 4.0 * t * (1.0 - t))
		pet.yaw = dirx * 0.6 * sin(t * PI), 0.0, 1.0, dur)
	tw.parallel().tween_property(pet, "squash", 0.0, dur * 0.5)
	await tw.finished
	if state != "guest_jump":
		return
	state = "guest"
	pet.yaw = 0.0
	pet.airborne = false
	pet.land(2.4)
	emotes.emit_emote("sparkle", 2)


## Position de la fenetre du compagnon pour que ses pieds soient au sol de la carte.
func _guest_pos(info: Dictionary) -> Vector2:
	var f: Vector2 = info["floor"]
	return Vector2(f.x - W * 0.5, f.y - (H - margin))


func _guest_scale(info: Dictionary) -> float:
	if info.has("ppu"):
		return clampf(float(info["ppu"]) * 0.88 / maxf(stage.ppu, 1.0), 0.4, 1.3)
	var r: Rect2 = info["rect"]
	return clampf(minf(r.size.y * 0.62, r.size.x * 0.5) / maxf(_pet_px(), 1.0), 0.35, 1.0)


func _process_guest() -> void:
	if not is_instance_valid(_guest_win):
		_exit_guest()
		return
	var info: Dictionary = _guest_win.call("avatar_screen_info")
	if info.is_empty():
		_exit_guest()  # fenetre reduite : il redescend
		return
	# une autre fenetre passe devant le jeu : il redescend (et revient quand tu reviens au jeu)
	if _guest_win.has_focus() or PetMenu.current() != null:
		_guest_away = 0.0
	else:
		_guest_away += get_process_delta_time()
		if _guest_away > 1.5:
			_exit_guest(false)
			return
	pos = _guest_pos(info)  # il suit la fenetre si on la deplace
	_pet_scale_target = _guest_scale(info)
	if not pet.busy:
		pet.look = info.get("look", Vector2(0.55, -0.15))  # il regarde le plateau (ou toi, dans la boutique)


func _exit_guest(forget := true) -> void:
	if is_instance_valid(_guest_win):
		_guest_win.call("set_external_avatar", false)
	if forget:
		_guest_win = null
	_guest_cd = 2.0
	_guest_away = 0.0
	_pet_scale_target = 1.0
	if state in ["guest", "guest_jump"]:
		_set_taskbar()
		state = "fall"
		vel = Vector2(0.0, -260.0 * s)
		pet.airborne = true


## Prepare le menu et la boutique en coulisse : clic droit et double-clic deviennent instantanes.
func _prewarm_ui() -> void:
	PetMenu.prewarm(self)
	if _shop == null or not is_instance_valid(_shop):
		_shop = ShopWindow.new()
		_shop.keep_alive = true
		add_child(_shop)
		_shop.prebuild()


func quit() -> void:
	PetSituations.free_cache()
	GameState.save_game()
	Activity.stop()
	get_tree().quit()
