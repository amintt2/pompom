class_name VisionClient
extends Node
## Les « yeux » du compagnon : que fait l'utilisateur (jeu, video, code, documents, web, discussion, autre)
## et OU est la video a l'ecran. Tout est calcule en local par assistant/service.py (le meme service que
## SuggestClient : meme processus, meme jeton) ; les captures d'ecran restent en memoire dans ce service,
## ne sont jamais ecrites ni envoyees, et n'existent que si le reglage "vision" est actif (opt-in).
##
## Signal vision_changed(top, probs, video_rect, fullscreen) :
##   top        : "game" | "video" | "work_code" | "work_docs" | "browse" | "chat" | "other"
##   probs      : {classe: probabilite} lissees dans le temps (somme = 1)
##   video_rect : rectangle de la video en pixels ECRAN (Rect2() vide s'il n'y en a pas)
##   fullscreen : la fenetre au premier plan couvre tout l'ecran principal
## En pause (jeu plein ecran / competitif) : top = "game", fullscreen = true, last["paused"] != "".
## Emis quand la classe principale change, quand la zone video bouge/apparait/disparait, ou quand une
## probabilite varie de plus de `prob_step`. `last` garde la derniere reponse complete du service.
##
## ------------------------------------------------------------------------------------------ CABLAGE
## Dans scripts/desktop/desktop_controller.gd, apres la creation de `suggest` (SuggestClient, qui gere le
## processus du service ; il le demarre si "suggestions" OU "vision" est actif) :
##
##   var vision: VisionClient                       # avec les autres variables
##
##   vision = VisionClient.new()
##   vision.name = "Vision"
##   vision.service = suggest                       # reutilise le service et son jeton
##   add_child(vision)
##   vision.vision_changed.connect(func(top: String, probs: Dictionary, video_rect: Rect2, fullscreen: bool):
##       # ex. : marcher sous la video, popcorn ; manette si "game" ; rester discret en plein ecran
##       if video_rect.has_area() and not fullscreen:
##           _walk_to(video_rect.get_center().x - W * 0.5)   # coordonnees ecran, comme pos
##       ...
##   )
##   vision.setup()                                 # suit GameState.settings "vision" (false par defaut)
##
## Reglage boutique : _setting_row(g2, "Il regarde ton écran", "Il devine si tu joues, regardes une vidéo
##   ou travailles, et où est la vidéo. Les images restent en mémoire sur ton PC, jamais enregistrées.",
##   _toggle_setting("vision"))
## ------------------------------------------------------------------------------------------

signal vision_changed(top: String, probs: Dictionary, video_rect: Rect2, fullscreen: bool)

const SETTING := "vision"

var service: SuggestClient  ## fournit l'adresse + le jeton du service local
var poll_interval := 1.5
var prob_step := 0.15
var respect_setting := true  ## tests : false pour piloter enable()/disable() a la main

var enabled := false
var last := {}
var top := ""
var probs := {}
var video_rect := Rect2()
var fullscreen := false

var _req: HTTPRequest
var _toggle_req: HTTPRequest
var _t := 0.0
var _remote_on := false  # le service a confirme que la vision tourne
var _want_sent := -1  # derniere consigne envoyee (0/1), -1 = rien
var _pause_sent := -1
var _pause_req: HTTPRequest
## Pause totale (aucune capture, aucun calcul) quand un jeu competitif ou un jeu plein ecran a le focus
## (d'apres Activity). Le service se met aussi en pause tout seul pour toute appli plein ecran qui n'est
## ni un navigateur ni un lecteur video. Une integration de jeu peut demander une image : request_frame().
var auto_pause := true


func setup() -> void:
	if respect_setting and not GameState.settings_changed.is_connected(_sync_setting):
		GameState.settings_changed.connect(_sync_setting)
	_sync_setting()


func _sync_setting() -> void:
	if not respect_setting:
		return
	if bool(GameState.settings.get(SETTING, false)):
		enable()
	else:
		disable()


func enable() -> void:
	enabled = true
	_want_sent = -1


func disable() -> void:
	enabled = false
	_want_sent = -1
	if top != "" or video_rect.has_area():
		top = ""
		probs = {}
		video_rect = Rect2()
		fullscreen = false
		vision_changed.emit(top, probs, video_rect, fullscreen)


func _ready() -> void:
	_req = HTTPRequest.new()
	_req.timeout = 3.0
	add_child(_req)
	_req.request_completed.connect(_on_vision)
	_toggle_req = HTTPRequest.new()
	_toggle_req.timeout = 3.0
	add_child(_toggle_req)
	_toggle_req.request_completed.connect(_on_toggle)
	_pause_req = HTTPRequest.new()
	_pause_req.timeout = 3.0
	add_child(_pause_req)
	_pause_req.request_completed.connect(func(res: int, c: int, _h, _b):
		if res != HTTPRequest.RESULT_SUCCESS or c != 200:
			_pause_sent = -1)


func _base() -> String:
	return service.api_base() if service else ""


func _process(delta: float) -> void:
	var base := _base()
	if base == "":
		_remote_on = false
		_want_sent = -1
		return
	var want := 1 if enabled else 0
	if want != _want_sent and _toggle_req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_want_sent = want
		_toggle_req.request(base + "/vision/enable", service.api_headers(), HTTPClient.METHOD_POST,
			JSON.stringify({"on": enabled}))
	if not enabled:
		return
	var pause := 1 if auto_pause and _game_focused() else 0
	if pause != _pause_sent and _pause_req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_pause_sent = pause
		_pause_req.request(base + "/vision/pause", service.api_headers(), HTTPClient.METHOD_POST,
			JSON.stringify({"paused": pause == 1}))
	_t -= delta
	if _t <= 0.0 and _req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_t = poll_interval
		_req.request(base + "/vision", service.api_headers())


func _game_focused() -> bool:
	return Activity.is_competitive() or (Activity.fullscreen and Activity.category == "game")


## Une analyse immediate, meme en pause (ex. un mini-jeu qui veut savoir ce qu'il y a a l'ecran).
func request_frame() -> void:
	var base := _base()
	if base == "" or not enabled:
		return
	var r := HTTPRequest.new()
	r.timeout = 3.0
	add_child(r)
	r.request_completed.connect(func(_a, _b, _c, _d): r.queue_free())
	r.request(base + "/vision/frame", service.api_headers(), HTTPClient.METHOD_POST, "{}")
	_t = 0.4  # relit /vision peu apres


func _on_toggle(result: int, code: int, _h, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_want_sent = -1  # on reessaiera
		return
	_remote_on = enabled


func _on_vision(result: int, code: int, _h, body: PackedByteArray) -> void:
	if not enabled or result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var d = JSON.parse_string(body.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return
	if not bool(d.get("enabled", false)):
		_want_sent = -1  # le service a redemarre : on renvoie la consigne
		_pause_sent = -1
		return
	if not bool(d.get("ready", false)):
		return
	last = d
	var new_top := str(d.get("top", ""))
	var new_probs: Dictionary = d.get("probs", {})
	var r = d.get("video_rect")
	var new_rect := Rect2()
	if typeof(r) == TYPE_ARRAY and r.size() == 4:
		new_rect = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
	var scr = d.get("screen")
	if typeof(scr) == TYPE_ARRAY and scr.size() == 4 and new_rect.has_area():
		new_rect.position += Vector2(float(scr[0]), float(scr[1]))  # ecran principal -> bureau virtuel
	var new_fs := bool(d.get("fullscreen", false))
	var changed := new_top != top or new_fs != fullscreen or new_rect.has_area() != video_rect.has_area()
	if not changed and new_rect.has_area():
		changed = new_rect.position.distance_to(video_rect.position) > 40.0 or new_rect.size.distance_to(video_rect.size) > 60.0
	if not changed:
		for k in new_probs:
			if absf(float(new_probs[k]) - float(probs.get(k, 0.0))) > prob_step:
				changed = true
				break
	top = new_top
	probs = new_probs
	video_rect = new_rect
	fullscreen = new_fs
	if changed:
		vision_changed.emit(top, probs, video_rect, fullscreen)
