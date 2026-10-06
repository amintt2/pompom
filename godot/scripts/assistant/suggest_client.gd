class_name SuggestClient
extends Node
## Suggestions de collage : quand tu cliques dans un champ (email, adresse, recherche...) n'importe ou
## dans Windows, le compagnon propose le texte copie qui va bien ("Coller ton email ?").
##
## Tout reste sur la machine : le service Python (assistant/service.py) lit la DESCRIPTION du champ
## focus (UI Automation, jamais son contenu, jamais les mots de passe) et decide avec des regles + un
## petit modele local (llama-server, 127.0.0.1). Rien n'est envoye sur Internet.
##
## Reglages (GameState.settings) :
##   "suggestions" (false par defaut) : active la fonction (opt-in).
##   "ai_gpu"      (true par defaut)  : modele sur la carte graphique (Vulkan) ou sur le processeur.
##
## ------------------------------------------------------------------------------------------ CABLAGE
## Dans scripts/desktop/desktop_controller.gd :
##
##   # 1) variable (avec les autres)
##   var suggest: SuggestClient
##
##   # 2) dans setup(), juste apres clip.setup(stage, emotes) :
##   suggest = SuggestClient.new()
##   suggest.name = "Suggest"
##   add_child(suggest)
##   suggest.candidates_provider = func() -> Array:
##       var out := []
##       for it in clip.items:
##           if it["kind"] == "text":
##               out.append(it)  # Dictionary avec "text" (ou directement des String)
##       return out
##   suggest.suggestion.connect(func(text_fr: String, idx: int, _kind: String):
##       emotes.say(text_fr, 4.0)
##       pet.act_hop(1)  # (optionnel) petit sursaut pour attirer l'oeil
##   )
##   suggest.setup()  # ecoute GameState.settings_changed ; demarre si "suggestions" est actif
##
##   # 3) (optionnel) accepter la suggestion en cliquant sur le compagnon dans les 6 s :
##   #    if suggest.pending_item() : clip.copy_item(suggest.take_pending())  -> puis Ctrl+V
##
## Dans la boutique (shop_window.gd, reglages) :
##   _setting_row(g2, "Suggestions de collage", "Quand tu cliques dans un champ (email, adresse...), il propose ce que tu as copié. Tout reste sur ton PC.", _toggle_setting("suggestions"))
##   _setting_row(g2, "IA sur la carte graphique", "Plus rapide. Décoche si ton PC chauffe ou rame.", _toggle_setting("ai_gpu"))
## ------------------------------------------------------------------------------------------

signal suggestion(text_fr: String, candidate_index: int, kind: String)
signal state_changed(state: String)  ## off | starting | ready | error
signal decided(request_id: int, answer: String, confidence: float)

const SETTING := "suggestions"
const GPU_SETTING := "ai_gpu"
const PENDING_TTL := 6.0

## Dossier "assistant" (service.py, .venv, llama, models). Vide = detection automatique.
var assistant_dir := ""
var min_confidence := 0.45
var cooldown := 20.0  ## s avant de reproposer la meme chose pour le meme champ
var focus_debounce := 0.15
var use_gpu := true
var respect_setting := true  ## tests : false pour piloter start()/stop() a la main
## Appele a chaque focus : renvoie les textes copies, du plus recent au plus ancien
## (String, ou Dictionary avec une cle "text").
var candidates_provider: Callable
var candidates: Array = []  ## alternative a candidates_provider

var state := "off"
var llm_state := ""  ## loading | ready | off | error (etat du modele dans le service)
var backend := ""
var last_field := {}
var last_result := {}
var last_error := ""

var _pid := -1
var _port := 0
var _token := ""
var _base := ""
var _health_req: HTTPRequest
var _focus_req: HTTPRequest
var _suggest_req: HTTPRequest
var _health_t := 0.0
var _start_t := 0.0
var _seq := 0
var _focus_busy := false
var _suggest_busy := false
var _debounce := -1.0
var _queued_field := {}
var _recent := {}  # cle -> temps
var _pending := {}  # {item, until}
var _snapshot: Array = []  # candidats envoyes avec la derniere requete
var _next_decide := 1


func setup() -> void:
	if respect_setting and not GameState.settings_changed.is_connected(_sync_setting):
		GameState.settings_changed.connect(_sync_setting)
	_sync_setting()


func _sync_setting() -> void:
	if not respect_setting:
		return
	var want := bool(GameState.settings.get(SETTING, false))
	var gpu := bool(GameState.settings.get(GPU_SETTING, true))
	if want and state != "off" and gpu != use_gpu:
		stop()  # changement CPU/GPU : on relance
	use_gpu = gpu
	if want and state == "off":
		start()
	elif not want and state != "off":
		stop()


# =========================================================================== demarrage / arret
func resolve_dir() -> String:
	var cands := []
	if assistant_dir != "":
		cands.append(assistant_dir)
	var env := OS.get_environment("POMPOM_ASSISTANT_DIR")
	if env != "":
		cands.append(env)
	cands.append(ProjectSettings.globalize_path("res://").path_join("../assistant").simplify_path())
	cands.append(OS.get_executable_path().get_base_dir().path_join("assistant"))
	for d in cands:
		if FileAccess.file_exists(String(d).path_join("service.py")):
			return d
	return ""


func start() -> bool:
	if state != "off":
		return true
	if OS.get_name() != "Windows":
		_set_state("error", "Windows uniquement")
		return false
	var dir := resolve_dir()
	if dir == "":
		_set_state("error", "dossier assistant introuvable")
		return false
	var py := dir.path_join(".venv/Scripts/pythonw.exe")
	if not FileAccess.file_exists(py):
		py = dir.path_join(".venv/Scripts/python.exe")
	if not FileAccess.file_exists(py):
		_set_state("error", "environnement Python absent (assistant/setup.ps1)")
		return false
	_token = Crypto.new().generate_random_bytes(16).hex_encode()
	_port = 47000 + randi() % 2000
	_base = "http://127.0.0.1:%d" % _port
	var args := PackedStringArray([dir.path_join("service.py"), "--port", str(_port), "--token", _token,
		"--parent-pid", str(OS.get_process_id()), "--gpu" if use_gpu else "--cpu"])
	_pid = OS.create_process(py, args, false)
	if _pid <= 0:
		_set_state("error", "lancement du service impossible")
		return false
	_ensure_nodes()
	_seq = 0
	_start_t = 0.0
	_health_t = 0.0
	_set_state("starting")
	return true


func stop() -> void:
	if _pid > 0:
		if state == "ready":
			# arret propre (le service arrete aussi llama-server) ; OS.kill en secours
			var r := HTTPRequest.new()
			add_child(r)
			r.timeout = 1.0
			r.request_completed.connect(func(_a, _b, _c, _d): r.queue_free())
			r.request(_base + "/shutdown", _headers(), HTTPClient.METHOD_POST, "{}")
			var pid := _pid
			get_tree().create_timer(1.5).timeout.connect(func():
				if OS.is_process_running(pid):
					OS.kill(pid)
			)
		else:
			OS.kill(_pid)
	_pid = -1
	for r in [_health_req, _focus_req, _suggest_req]:
		if r:
			r.cancel_request()
	_focus_busy = false
	_suggest_busy = false
	_pending = {}
	llm_state = ""
	_set_state("off")


func _exit_tree() -> void:
	if _pid > 0:
		OS.kill(_pid)  # le service tue llama-server via son Job Object
		_pid = -1


func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


func _set_state(s: String, err := "") -> void:
	if err != "":
		last_error = err
		push_warning("SuggestClient: " + err)
	if s != state:
		state = s
		state_changed.emit(s)


func _ensure_nodes() -> void:
	if _health_req:
		return
	_health_req = _mk_req(2.0, _on_health)
	_focus_req = _mk_req(15.0, _on_focus)
	_suggest_req = _mk_req(4.0, _on_suggest)


func _mk_req(timeout: float, cb: Callable) -> HTTPRequest:
	var r := HTTPRequest.new()
	r.timeout = timeout
	r.use_threads = true
	add_child(r)
	r.request_completed.connect(cb)
	return r


func _headers() -> PackedStringArray:
	return PackedStringArray(["X-Pompom-Token: " + _token, "Content-Type: application/json"])


# =========================================================================== boucle
func _process(delta: float) -> void:
	if state == "off" or state == "error":
		return
	if _pid > 0 and not OS.is_process_running(_pid):
		_pid = -1
		_set_state("error", "le service s'est arrete")
		return
	_start_t += delta
	_health_t -= delta
	if _health_t <= 0.0 and _health_req.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		# pendant le demarrage : souvent ; ensuite : pour suivre l'etat du modele
		_health_t = 0.25 if state == "starting" else (1.0 if llm_state == "loading" else 10.0)
		_health_req.request(_base + "/health")
	if state == "starting" and _start_t > 20.0:
		stop()
		_set_state("error", "le service ne repond pas")
		return
	if state == "ready" and not _focus_busy:
		_focus_busy = true
		_focus_req.request("%s/focus?after=%d&wait=10" % [_base, _seq], _headers())
	if _debounce >= 0.0:
		_debounce -= delta
		if _debounce < 0.0:
			_ask(_queued_field)
	if not _pending.is_empty() and Time.get_ticks_msec() / 1000.0 > float(_pending["until"]):
		_pending = {}


func _on_health(result: int, code: int, _h, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var d = JSON.parse_string(body.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return
	llm_state = str(d.get("llm", ""))
	backend = str(d.get("backend", ""))
	if state == "starting":
		_set_state("ready")


func _on_focus(result: int, code: int, _h, body: PackedByteArray) -> void:
	_focus_busy = false
	if state != "ready" or result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var f = JSON.parse_string(body.get_string_from_utf8())
	if typeof(f) != TYPE_DICTIONARY:
		return
	var seq := int(f.get("seq", 0))
	if seq == _seq:
		return
	_seq = seq
	if f.has("skip"):
		last_field = {}
		return  # mot de passe, champ non editable, fenetre du jeu...
	last_field = f
	_queued_field = f
	_debounce = focus_debounce  # attend que le focus soit stable (tabulations rapides)


# =========================================================================== suggestions
func _candidate_items() -> Array:
	var raw: Array = candidates
	if candidates_provider.is_valid():
		raw = candidates_provider.call()
	return raw.slice(0, 8)


static func _text_of(it) -> String:
	if typeof(it) == TYPE_DICTIONARY:
		return str(it.get("text", ""))
	return str(it)


## Demande une suggestion pour un champ donne (tests, ou appel manuel). field vide = champ focus.
func request_suggestion(field: Dictionary = {}, items: Array = []) -> bool:
	if state != "ready" or _suggest_busy:
		return false
	if not items.is_empty():
		_snapshot = items.slice(0, 8)
	else:
		_snapshot = _candidate_items()
	if _snapshot.is_empty():
		return false
	var texts := []
	for it in _snapshot:
		texts.append(_text_of(it).left(4000))
	var payload := {"candidates": texts}
	if not field.is_empty():
		payload["field"] = field
	_suggest_busy = true
	var err := _suggest_req.request(_base + "/suggest", _headers(), HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_suggest_busy = false
		return false
	return true


func _ask(field: Dictionary) -> void:
	if (respect_setting and not bool(GameState.settings.get(SETTING, false))) or field.is_empty():
		return
	request_suggestion(field)


func _on_suggest(result: int, code: int, _h, body: PackedByteArray) -> void:
	_suggest_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var s = JSON.parse_string(body.get_string_from_utf8())
	if typeof(s) != TYPE_DICTIONARY:
		return
	last_result = s
	var idx := int(s.get("index", -1))
	if idx < 0 or idx >= _snapshot.size() or float(s.get("confidence", 0.0)) < min_confidence:
		return
	var text_fr := str(s.get("label_fr", ""))
	if text_fr == "":
		return
	var item = _snapshot[idx]
	var key := "%s|%s|%s|%d" % [last_field.get("process", ""), last_field.get("name", ""), s.get("kind", ""),
		_text_of(item).hash()]
	var now := Time.get_ticks_msec() / 1000.0
	if _recent.has(key) and now - float(_recent[key]) < cooldown:
		return
	_recent[key] = now
	if _recent.size() > 64:
		_recent.clear()
	_pending = {"item": item, "until": now + PENDING_TTL}
	suggestion.emit(text_fr, idx, str(s.get("kind", "")))


## La derniere suggestion encore valable (quelques secondes), pour l'accepter d'un clic.
func pending_item():
	return null if _pending.is_empty() else _pending["item"]


func take_pending():
	var it = pending_item()
	_pending = {}
	return it


# =========================================================================== decisions de jeu
## Decision typee generique (< ~100 ms sur GPU) : reponse = une des options.
## Le resultat arrive par le signal decided(request_id, answer, confidence) ; answer = "" si echec.
func decide(question: String, options: Array, context := "") -> int:
	var id := _next_decide
	_next_decide += 1
	if state != "ready" or llm_state != "ready":
		decided.emit.call_deferred(id, "", 0.0)
		return id
	var r := HTTPRequest.new()
	r.timeout = 3.0
	add_child(r)
	r.request_completed.connect(func(res: int, c: int, _hh, b: PackedByteArray):
		r.queue_free()
		var d = JSON.parse_string(b.get_string_from_utf8()) if res == HTTPRequest.RESULT_SUCCESS and c == 200 else null
		if typeof(d) == TYPE_DICTIONARY:
			decided.emit(id, str(d.get("answer", "")), float(d.get("confidence", 0.0)))
		else:
			decided.emit(id, "", 0.0)
	)
	r.request(_base + "/decide", _headers(), HTTPClient.METHOD_POST,
		JSON.stringify({"question": question, "options": options, "context": context}))
	return id
