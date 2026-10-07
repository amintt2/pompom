class_name FeedbackHub
extends Node
## Boucle de retour sur donnees reelles : relie le compagnon (DesktopController), la pastille « Il s'est
## trompé ? », la carte de correction, le jeu de donnees local, l'envoi anonyme (opt-in) et le mode
## developpeur (captures locales). Voir docs/donnees.md.
##
## ------------------------------------------------------------------------------------------ CABLAGE
## Dans DesktopController (desktop_controller.gd) :
##   var feedback: FeedbackHub                      # avec les autres variables
##   # setup(), apres _setup_games() :
##   feedback = FeedbackHub.new()
##   feedback.name = "Feedback"
##   add_child(feedback)
##   feedback.setup(self)
##   # _poke(), en tout premier (avant que le clic n'interrompe ce qu'il faisait) :
##   if feedback:
##       feedback.on_pet_clicked()
##   # menu (clic droit) : entree {"id": 15, "label": "Il s'est trompé…", ...} ; _on_menu : 15: feedback.open_card("menu")
## Reglages (GameState.settings) : "share_feedback" (false), "dev_collect" (false), "dev_collect_interval" (180).
## ------------------------------------------------------------------------------------------
##
## Lit le controleur par ses champs publics (duck typing) : pet, win, mode, situations, vision, games, suggest,
## emotes. Rien n'est envoye nulle part sans le reglage "share_feedback" ET la case « Partager anonymement ».

signal sample_added(sample: Dictionary)

const CHIP_AFTER_EVENT := 30.0  ## s apres un evenement de jeu pendant lesquelles un clic propose la pastille
const CHIP_COOLDOWN := 15.0
const EMBED_WAIT := 0.7  ## s max d'attente de l'analyse de l'ecran avant d'ouvrir la carte
const EMBED_TIMEOUT := 6.0
const SHOT_MAX_WIDTH := 1280

var controller: Node
var store := FeedbackStore.new()
var uploader: FeedbackUploader
var collector: DevCollector
var chip: FeedbackChip
var card: FeedbackCard

var last_event := {}  # {kind, mine, t}
var last_suggestion_t := -1000.0
var _chip_t := -1000.0
var _snap := {}  # instantane en cours : {ctx, id, emb, emb_state, shot}
var _embed_req: HTTPRequest
var _shot_task := -1
var _opening := false


func setup(ctrl: Node) -> void:
	controller = ctrl
	uploader = FeedbackUploader.new()
	uploader.name = "FeedbackUploader"
	uploader.store = store
	add_child(uploader)
	collector = DevCollector.new()
	collector.name = "DevCollector"
	collector.context_provider = context
	add_child(collector)
	chip = FeedbackChip.new()
	chip.name = "FeedbackChip"
	add_child(chip)
	chip.pressed.connect(func(): open_card("chip"))
	_embed_req = HTTPRequest.new()
	_embed_req.timeout = EMBED_TIMEOUT
	add_child(_embed_req)
	_embed_req.request_completed.connect(_on_embed)
	var games = _field(ctrl, "games")
	if games and games.has_signal("event"):
		games.event.connect(_on_game_event)
	var sug = _field(ctrl, "suggest")
	if sug and sug.has_signal("suggestion"):
		sug.suggestion.connect(func(_t, _i, _k): last_suggestion_t = _now())


static func _field(o: Object, prop: String):
	return o.get(prop) if o != null and prop in o else null


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _on_game_event(kind: String, mine: bool, _data: Dictionary) -> void:
	last_event = {"kind": kind, "mine": mine, "t": _now()}


# =========================================================================== declencheurs
## A appeler au clic gauche sur le compagnon, AVANT qu'il ne reagisse : s'il faisait quelque chose tout seul
## (situation imitee, pop-corn, manette...) ou juste apres un evenement de jeu, la pastille apparait 4 s.
func on_pet_clicked() -> bool:
	if not should_offer_chip():
		return false
	_chip_t = _now()
	var win: Window = _field(controller, "win")
	if win == null:
		return false
	chip.show_near(Rect2i(win.position, win.size))
	return true


func should_offer_chip() -> bool:
	if _opening or (card != null and is_instance_valid(card)):
		return false
	if _now() - _chip_t < CHIP_COOLDOWN:
		return false
	var recent_event := not last_event.is_empty() and _now() - float(last_event.get("t", -1000.0)) < CHIP_AFTER_EVENT
	var sit = _field(controller, "situations")
	var auto_sit: bool = sit != null and sit.is_playing()
	var pet = _field(controller, "pet")
	var auto_act: bool = pet != null and bool(pet.busy) and not bool(pet.sleeping)
	var mode := str(_field(controller, "mode"))
	return recent_event or auto_sit or auto_act or mode == "video"


# =========================================================================== instantane
## Ce qui se passait (ce que le compagnon avait decide + l'appli au premier plan). Le titre de la fenetre
## n'est garde que localement.
func context() -> Dictionary:
	var c := {
		"time": int(Time.get_unix_time_from_system()), "proc": Activity.proc_name, "title": Activity.window_title,
		"category": Activity.category, "fullscreen": Activity.fullscreen, "meeting": Activity.meeting,
		"recording": Activity.recording, "mode": str(_field(controller, "mode") if controller else ""),
		"situation": "", "auto_situation": PetSituations.situation_for_activity(), "vision": "", "vision_probs": {},
		"event": "", "game": "",
	}
	var sit = _field(controller, "situations")
	if sit != null and sit.is_playing():
		c["situation"] = str(sit.current)
	var vis = _field(controller, "vision")
	if vis != null and bool(vis.enabled):
		c["vision"] = str(vis.top)
		var pr := {}
		for k in vis.probs:
			pr[k] = snappedf(float(vis.probs[k]), 0.001)
		c["vision_probs"] = pr
	if not last_event.is_empty() and _now() - float(last_event["t"]) < 300.0:
		c["event"] = str(last_event["kind"])
		c["event_ago"] = snappedf(_now() - float(last_event["t"]), 0.1)
		c["event_mine"] = bool(last_event["mine"])
	var games = _field(controller, "games")
	if games != null:
		c["game"] = str(games.proc)
	c["game_context"] = c["event"] != "" or c["game"] != "" or Activity.category == "game" \
		or c["mode"] in ["game", "fs", "comp"]
	var sug = _field(controller, "suggest")
	if sug != null and _now() - last_suggestion_t < 90.0 and typeof(sug.last_field) == TYPE_DICTIONARY:
		c["field"] = (sug.last_field as Dictionary).duplicate()
	return c


func is_private(c: Dictionary) -> bool:
	return DevCollector.skip_reason(c) != ""


# =========================================================================== carte
## Ouvre la carte de correction ("menu" = clic droit, "chip" = pastille). L'ecran est analyse AVANT que la
## carte n'apparaisse (sinon elle serait sur la capture).
func open_card(source := "menu") -> void:
	if card != null and is_instance_valid(card):
		card.grab_focus()
		return
	if _opening:
		return
	_opening = true
	chip.dismiss()
	var ctx := context()
	ctx["source"] = source
	_snap = {"ctx": ctx, "id": FeedbackStore.new_id(), "emb": null, "emb_state": "none", "shot": ""}
	var priv := is_private(ctx)
	if not priv:
		# deux images : le menu / la pastille ont bien disparu de l'ecran
		await get_tree().process_frame
		await get_tree().process_frame
		_request_embedding(ctx)
		if bool(GameState.settings.get(DevCollector.SETTING, false)):
			_take_shot(str(_snap["id"]))
		var t0 := _now()
		while str(_snap.get("emb_state", "")) == "pending" and _now() - t0 < EMBED_WAIT:
			await get_tree().process_frame
	else:
		ctx.erase("title")
		ctx.erase("field")
	_opening = false
	card = FeedbackCard.new()
	card.name = "FeedbackCard"
	add_child(card)
	card.preview_provider = func(ch: Array) -> String: return FeedbackUploader.preview_json(build_samples(ch, "", true))
	card.submitted.connect(_on_submit)
	card.canceled.connect(func(): _snap = {})
	var win: Window = _field(controller, "win")
	card.open_for(ctx, {"anchor": Rect2i(win.position, win.size) if win else Rect2i(),
		"share_available": bool(GameState.settings.get(FeedbackUploader.SETTING, false)), "share_default": true,
		"embedding": str(_snap["emb_state"])})


func _request_embedding(ctx: Dictionary) -> void:
	var sug = _field(controller, "suggest")
	var base: String = sug.api_base() if sug != null else ""
	if base == "" or _embed_req.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_snap["emb_state"] = "none"
		return
	var body := {"screen": true}
	if ctx.has("field"):
		body["field"] = ctx["field"]
	if _embed_req.request(base + "/embed", sug.api_headers(), HTTPClient.METHOD_POST, JSON.stringify(body)) == OK:
		_snap["emb_state"] = "pending"
	else:
		_snap["emb_state"] = "none"


func _on_embed(result: int, code: int, _h, body: PackedByteArray) -> void:
	if _snap.is_empty():
		return
	var d = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and code == 200 else null
	if typeof(d) == TYPE_DICTIONARY:
		_snap["emb"] = d.get("screen") if typeof(d.get("screen")) == TYPE_DICTIONARY else null
		_snap["text_emb"] = d.get("text") if typeof(d.get("text")) == TYPE_DICTIONARY else null
	_snap["emb_state"] = "ok" if _snap.get("emb") != null else "none"
	if card != null and is_instance_valid(card):
		card.set_embedding_state(str(_snap["emb_state"]))


## Petite capture LOCALE jointe a la correction (seulement en mode developpeur), sur un fil de travail.
func _take_shot(id: String) -> void:
	if _shot_task != -1 and not WorkerThreadPool.is_task_completed(_shot_task):
		return
	if _shot_task != -1:
		WorkerThreadPool.wait_for_task_completion(_shot_task)
	var sc := DisplayServer.get_primary_screen()
	var rel := "shots/%s.webp" % id
	var job := {"rect": Rect2i(DisplayServer.screen_get_position(sc), DisplayServer.screen_get_size(sc)),
		"path": ProjectSettings.globalize_path(store.dir.path_join(rel)),
		"dir": ProjectSettings.globalize_path(store.shots_dir())}
	_snap["shot"] = rel
	_shot_task = WorkerThreadPool.add_task(func():
		var img := DisplayServer.screen_get_image_rect(job["rect"])
		if img == null or img.is_empty():
			return
		img.convert(Image.FORMAT_RGB8)
		if img.get_width() > SHOT_MAX_WIDTH:
			img.resize(SHOT_MAX_WIDTH, int(round(img.get_height() * float(SHOT_MAX_WIDTH) / img.get_width())), Image.INTERPOLATE_LANCZOS)
		DirAccess.make_dir_recursive_absolute(job["dir"])
		img.save_webp(job["path"], true, DevCollector.QUALITY)
		FeedbackStore.trim_dir(job["dir"], FeedbackStore.MAX_SHOTS), false, "pompom_feedback_shot")


# =========================================================================== enregistrement
## Exemples a partir des choix de la carte (une ligne par tache choisie).
func build_samples(choices: Array, note: String, share: bool) -> Array:
	var out: Array = []
	if _snap.is_empty():
		return out
	var ctx: Dictionary = _snap["ctx"]
	for ch in choices:
		var task := str(ch["task"])
		var emb = _snap.get("text_emb") if task == "field_kind" else _snap.get("emb")
		var local := {"title": str(ctx.get("title", "")), "note": note, "shot": str(_snap.get("shot", ""))}
		if task == "field_kind" and ctx.has("field"):
			local["field"] = ctx["field"]
		out.append({
			"id": str(_snap["id"]) + ("" if out.is_empty() else "-%d" % out.size()),
			"task": task, "label": str(ch["label"]), "source": str(ctx.get("source", "menu")),
			"app": str(ctx.get("proc", "")), "category": str(ctx.get("category", "")),
			"fullscreen": bool(ctx.get("fullscreen", false)), "game": str(ctx.get("game", "")),
			"pet": {"situation": str(ctx.get("situation", "")), "auto_situation": str(ctx.get("auto_situation", "")),
				"mode": str(ctx.get("mode", "")), "vision": str(ctx.get("vision", "")),
				"vision_probs": ctx.get("vision_probs", {}), "event": str(ctx.get("event", "")),
				"event_ago": ctx.get("event_ago", -1.0)},
			"emb": emb if typeof(emb) == TYPE_DICTIONARY else null,
			"share": share and typeof(emb) == TYPE_DICTIONARY,
			"local": local,
		})
	return out


func _on_submit(choices: Array, note: String, share: bool) -> void:
	var samples := build_samples(choices, note, share)
	var any_share := false
	for s in samples:
		if store.add(s) != "":
			sample_added.emit(s)
			any_share = any_share or bool(s["share"])
	_snap = {}
	if any_share:
		uploader.poke()
	var emotes = _field(controller, "emotes")
	if emotes != null:
		emotes.say("Merci ! Je ferai mieux la prochaine fois.", 3.0)
	var pet = _field(controller, "pet")
	if pet != null and not bool(pet.sleeping):
		pet.act_nod()


## « Effacer mes données d'entraînement » (reglages).
func erase_all() -> int:
	return store.erase_all()


func _exit_tree() -> void:
	if _shot_task != -1:
		WorkerThreadPool.wait_for_task_completion(_shot_task)
		_shot_task = -1
