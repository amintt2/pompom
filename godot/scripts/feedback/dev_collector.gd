class_name DevCollector
extends Node
## Mode developpeur (reglage "dev_collect", desactive par defaut) : une capture de l'ecran principal toutes les
## `interval` secondes (reglage "dev_collect_interval", 180 par defaut), pour etiqueter ensuite de VRAIES
## situations (assistant/tools/label_screens.py) et re-entrainer les petites tetes.
##
## - Stockage LOCAL uniquement : user://dataset/screens/<horodatage>.webp + <horodatage>.json (processus, titre,
##   categorie, plein ecran, mode et situation du compagnon, jeu). Rien n'est jamais envoye par le jeu.
## - WebP avec pertes (qualite 0.85) a la resolution NATIVE (le texte doit rester lisible pour l'etiquetage) ;
##   reduit seulement si l'ecran fait plus de MAX_WIDTH px de large. Capture + encodage sur un fil de
##   WorkerThreadPool (basse priorite) : l'image ne passe jamais par le fil principal.
## - Rien n'est capture quand la situation est privee (gestionnaire de mots de passe, connexion, 2FA, banque,
##   navigation privee...), pendant une visio ou un enregistrement / stream (FeedbackStore.is_private_context).
## - Plafond disque `max_bytes` (2 Go) : les plus anciennes captures sont supprimees.
##
##   var dev := DevCollector.new()
##   dev.context_provider = func() -> Dictionary: return {...}   # voir FeedbackHub.context()
##   add_child(dev)

signal captured(path: String)
signal skipped(reason: String)

const SETTING := "dev_collect"
const INTERVAL_SETTING := "dev_collect_interval"
const MAX_WIDTH := 2560
const QUALITY := 0.85

var dir := "user://dataset/screens"
var interval := 180.0
var max_bytes := 2 * 1024 * 1024 * 1024
var respect_setting := true  ## tests : false pour piloter `enabled` a la main
var enabled := false
## Renvoie le contexte courant : {proc, title, category, fullscreen, meeting, recording, mode, situation, pet, game}
var context_provider: Callable

var last_reason := ""
var _t := 20.0
var _task := -1
var _mutex := Mutex.new()
var _done: Array = []  # chemins termines (rempli par le fil, lu par _process)


func _process(delta: float) -> void:
	if respect_setting:
		enabled = bool(GameState.settings.get(SETTING, false))
		interval = maxf(30.0, float(GameState.settings.get(INTERVAL_SETTING, 180.0)))
	_collect_done()
	if not enabled:
		return
	_t -= delta
	if _t <= 0.0:
		_t = interval
		capture_now()


## Lance une capture tout de suite. Renvoie "" si elle part, sinon la raison ("private", "busy", "headless").
func capture_now() -> String:
	var ctx: Dictionary = context_provider.call() if context_provider.is_valid() else {}
	var why := skip_reason(ctx)
	if why == "" and _task != -1 and not WorkerThreadPool.is_task_completed(_task):
		why = "busy"
	if why == "" and DisplayServer.get_name() == "headless":
		why = "headless"
	last_reason = why
	if why != "":
		skipped.emit(why)
		return why
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
	var sc := DisplayServer.get_primary_screen()
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var job := {
		"rect": Rect2i(DisplayServer.screen_get_position(sc), DisplayServer.screen_get_size(sc)),
		"dir": ProjectSettings.globalize_path(dir), "name": "%s_%03d" % [stamp, randi() % 1000],
		"max_bytes": max_bytes, "meta": sidecar(ctx),
	}
	_task = WorkerThreadPool.add_task(_work.bind(job), false, "pompom_devcollect")
	return ""


## Raison de ne PAS capturer ("" = on peut).
static func skip_reason(ctx: Dictionary) -> String:
	if FeedbackStore.is_private_context(str(ctx.get("proc", "")), str(ctx.get("title", "")), str(ctx.get("category", "")),
			bool(ctx.get("meeting", false)), bool(ctx.get("recording", false))):
		return "private"
	if str(ctx.get("situation", "")) == "private":
		return "private"
	return ""


## Fichier compagnon de la capture (local uniquement).
static func sidecar(ctx: Dictionary) -> Dictionary:
	var keys := ["proc", "title", "category", "fullscreen", "mode", "situation", "auto_situation", "vision",
		"vision_probs", "event", "event_ago", "game"]
	var m := {"time": int(Time.get_unix_time_from_system()), "day": FeedbackStore.today(),
		"client": str(ProjectSettings.get_setting("application/config/version", "0.0.0"))}
	for k in keys:
		if ctx.has(k):
			m[k] = ctx[k]
	return m


# fil de travail : capture, reduction eventuelle, WebP, fichier compagnon, plafond disque
func _work(job: Dictionary) -> void:
	var img := DisplayServer.screen_get_image_rect(job["rect"])
	if img == null or img.is_empty():
		return
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)  # pas de canal alpha : fichier plus petit
	if img.get_width() > MAX_WIDTH:
		img.resize(MAX_WIDTH, int(round(img.get_height() * float(MAX_WIDTH) / img.get_width())), Image.INTERPOLATE_LANCZOS)
	var d: String = job["dir"]
	DirAccess.make_dir_recursive_absolute(d)
	var path := d.path_join(str(job["name"]) + ".webp")
	if img.save_webp(path, true, QUALITY) != OK:
		return
	var meta: Dictionary = job["meta"]
	meta["file"] = path.get_file()
	meta["size"] = [img.get_width(), img.get_height()]
	var f := FileAccess.open(d.path_join(str(job["name"]) + ".json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(meta))
		f.close()
	enforce_cap(d, int(job["max_bytes"]))
	_mutex.lock()
	_done.append(path)
	_mutex.unlock()


func _collect_done() -> void:
	if _done.is_empty():
		return
	_mutex.lock()
	var paths := _done.duplicate()
	_done.clear()
	_mutex.unlock()
	for p in paths:
		captured.emit(p)


## Supprime les plus anciennes captures (et leur .json) jusqu'a repasser sous `cap` octets.
static func enforce_cap(abs_dir: String, cap: int) -> void:
	var files := Array(DirAccess.get_files_at(abs_dir))
	files.sort()  # nom = horodatage : du plus ancien au plus recent
	var sizes := {}
	var total := 0
	for f in files:
		var fa := FileAccess.open(abs_dir.path_join(f), FileAccess.READ)
		if fa:
			sizes[f] = fa.get_length()
			total += int(sizes[f])
			fa.close()
	for f in files:
		if total <= cap:
			break
		if not String(f).ends_with(".json"):
			for g in [f, String(f).get_basename() + ".json"]:
				if sizes.has(g) and DirAccess.remove_absolute(abs_dir.path_join(g)) == OK:
					total -= int(sizes[g])
					sizes.erase(g)


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
