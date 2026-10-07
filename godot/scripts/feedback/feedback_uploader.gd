class_name FeedbackUploader
extends Node
## Envoi ANONYME (opt-in, reglage "share_feedback", desactive par defaut) des corrections partageables au
## serveur de contributions (server/feedback/, auto-heberge). Ce qui part, par exemple :
##   {"task", "label", "app", "model_id", "model_version", "dim", "dtype": "float16", "emb", "pet"}
## = un vecteur de nombres calcule sur le PC + l'etiquette corrigee + le nom du processus + ce que le
## compagnon avait decide. JAMAIS d'image, de titre de fenetre, de texte saisi, d'identifiant ; aucun
## identifiant de requete n'est envoye (le serveur ne garde que le jour de reception).
##
## Ne bloque jamais l'interface (HTTPRequest asynchrone), envoie par lots (MAX_BATCH), reessaie avec un delai
## croissant (1 min -> 6 h), et note les exemples envoyes / refuses dans le FeedbackStore.
##
## Adresse du serveur : user://feedback_endpoint.txt (1re ligne), sinon le reglage de projet
## "pompom/feedback/endpoint", sinon DEFAULT_ENDPOINT (factice : rien n'est envoye tant qu'il n'est pas remplace).

signal sent(count: int)
signal failed(reason: String)

const SETTING := "share_feedback"
const DEFAULT_ENDPOINT := "https://pompom-feedback.example"
const PATH := "/v1/contrib"
const MAX_BATCH := 32
const SCHEMA := 1
const ITEM_KEYS := ["task", "label", "app", "model_id", "model_version", "dim", "dtype", "emb", "pet"]
const VISION_CLASSES := ["", "game", "video", "work_code", "work_docs", "browse", "chat", "other"]
const MODES := ["", "normal", "game", "fs", "comp", "meeting", "video"]

var store: FeedbackStore
var interval := 600.0  ## s entre deux lots
var respect_setting := true  ## tests : false pour piloter `enabled` a la main
var enabled := false
var endpoint_override := ""

var _t := 45.0  # premier essai peu apres le demarrage
var _fails := 0
var _req: HTTPRequest
var _inflight: Array = []


func _ready() -> void:
	_req = HTTPRequest.new()
	_req.timeout = 20.0
	add_child(_req)
	_req.request_completed.connect(_on_done)


func _process(delta: float) -> void:
	if respect_setting:
		enabled = bool(GameState.settings.get(SETTING, false))
	if not enabled or store == null:
		return
	_t -= delta
	if _t <= 0.0:
		_t = interval
		send_now()


## Envoie tout de suite un lot (s'il y en a un, si le reglage est actif et si le serveur est configure).
func send_now() -> bool:
	if not enabled or store == null or not _inflight.is_empty():
		return false
	var ep := endpoint()
	if not is_configured(ep):
		return false
	var batch := store.pending_share(MAX_BATCH)
	var payload := build_payload(batch, str(ProjectSettings.get_setting("application/config/version", "0.0.0")))
	if (payload["items"] as Array).is_empty():
		# rien de partageable dans ces exemples (vecteur invalide...) : on ne les reproposera pas
		if not batch.is_empty():
			store.mark(batch.map(func(d): return d["id"]), "rejected")
		return false
	_inflight = batch.map(func(d): return d["id"])
	var err := _req.request(ep.trim_suffix("/") + PATH, PackedStringArray(["content-type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		_inflight = []
		_retry_later("request %d" % err)
		return false
	return true


## Envoi plus tot que prevu (apres une nouvelle correction partagee).
func poke(delay := 20.0) -> void:
	_t = minf(_t, delay)


func _on_done(result: int, code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	var ids := _inflight
	_inflight = []
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_fails = 0
		store.mark(ids, "sent")
		sent.emit(ids.size())
		_t = 5.0 if not store.pending_share(1).is_empty() else interval
		return
	if result == HTTPRequest.RESULT_SUCCESS and code in [400, 413, 415, 422]:
		store.mark(ids, "rejected")  # refuse par le serveur : inutile d'insister
		failed.emit("rejected %d" % code)
		return
	var wait := 0.0
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			wait = float(h.split(":", true, 1)[1].strip_edges())
	_retry_later("http %d/%d" % [result, code], wait)


func _retry_later(reason: String, wait := 0.0) -> void:
	_fails += 1
	_t = maxf(wait, minf(6.0 * 3600.0, 60.0 * pow(2.0, _fails - 1)))
	failed.emit(reason)


# =========================================================================== adresse
func endpoint() -> String:
	if endpoint_override != "":
		return endpoint_override
	return resolve_endpoint()


static func resolve_endpoint() -> String:
	var f := FileAccess.open("user://feedback_endpoint.txt", FileAccess.READ)
	if f:
		var line := f.get_line().strip_edges()
		f.close()
		if line != "":
			return line
	var ps := str(ProjectSettings.get_setting("pompom/feedback/endpoint", ""))
	return ps if ps != "" else DEFAULT_ENDPOINT


## HTTPS obligatoire (sauf serveur local de test) ; l'adresse factice ".example" ne compte pas.
static func is_configured(ep: String) -> bool:
	var host := ep.trim_prefix("https://").trim_prefix("http://").get_slice("/", 0).get_slice(":", 0)
	if host == "" or host.ends_with(".example") or host.ends_with(".invalid"):
		return false
	return ep.begins_with("https://") or (ep.begins_with("http://") and host in ["127.0.0.1", "localhost"])


# =========================================================================== contenu envoye
## L'objet exact envoye pour un exemple ({} s'il n'est pas partageable). Liste blanche stricte : rien
## d'autre que ITEM_KEYS ne peut sortir (ni « local », ni titre, ni note, ni capture).
static func build_item(sample: Dictionary) -> Dictionary:
	var task := str(sample.get("task", ""))
	var label := str(sample.get("label", ""))
	if not FeedbackStore.valid_label(task, label):
		return {}
	var e = sample.get("emb")
	if typeof(e) != TYPE_DICTIONARY:
		return {}
	var dim := int(e.get("dim", 0))
	var model_id := str(e.get("model_id", ""))
	var model_version := str(e.get("model_version", ""))
	if dim < 128 or dim > 1024 or not _re("^[a-z0-9][a-z0-9._:-]{2,63}$").search(model_id) \
			or not _re("^[a-z0-9._-]{1,32}$").search(model_version):
		return {}
	var f16 := to_float16_b64(str(e.get("b64", "")), str(e.get("dtype", "float32")), dim)
	if f16 == "":
		return {}
	var p: Dictionary = sample.get("pet", {}) if typeof(sample.get("pet")) == TYPE_DICTIONARY else {}
	var sit := str(p.get("situation", ""))
	var ev := str(p.get("event", ""))
	var pet := {
		"situation": sit if _re("^[a-z_]{0,32}$").search(sit) else "",
		"vision": str(p.get("vision", "")) if VISION_CLASSES.has(str(p.get("vision", ""))) else "",
		"mode": str(p.get("mode", "")) if MODES.has(str(p.get("mode", ""))) else "",
		"event": ev if _re("^[a-z_]{0,24}$").search(ev) else "",
	}
	return {"task": task, "label": label, "app": FeedbackStore.sanitize_app(str(sample.get("app", ""))),
		"model_id": model_id, "model_version": model_version, "dim": dim, "dtype": "float16", "emb": f16, "pet": pet}


static func build_payload(samples: Array, client_version: String) -> Dictionary:
	var items: Array = []
	for s in samples:
		var it := build_item(s)
		if not it.is_empty():
			items.append(it)
	var client := ""
	for ch in client_version:
		if (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch in [".", "+", "-"]:
			client += ch
	return {"schema": SCHEMA, "client": client.left(24) if client != "" else "0", "items": items}


## Texte affiche par « Voir ce qui part » : exactement le JSON envoye.
static func preview_json(samples: Array) -> String:
	return JSON.stringify(build_payload(samples, str(ProjectSettings.get_setting("application/config/version", "0.0.0"))), "  ")


## float32 (ou float16) base64 -> float16 base64, renormalise L2. "" si le vecteur est invalide.
static func to_float16_b64(b64: String, dtype: String, dim: int) -> String:
	var raw := Marshalls.base64_to_raw(b64)
	var vals := PackedFloat32Array()
	if dtype == "float16":
		if raw.size() != dim * 2:
			return ""
		vals.resize(dim)
		for i in dim:
			vals[i] = raw.decode_half(i * 2)
	else:
		if raw.size() != dim * 4:
			return ""
		vals = raw.to_float32_array()
	var n := 0.0
	for v in vals:
		if is_nan(v) or is_inf(v):
			return ""
		n += v * v
	n = sqrt(n)
	if n <= 1e-6:
		return ""
	var out := PackedByteArray()
	out.resize(dim * 2)
	for i in dim:
		out.encode_half(i * 2, vals[i] / n)
	return Marshalls.raw_to_base64(out)


static var _rx := {}


static func _re(p: String) -> RegEx:
	if not _rx.has(p):
		_rx[p] = RegEx.create_from_string(p)
	return _rx[p]
