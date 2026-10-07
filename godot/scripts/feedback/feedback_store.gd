class_name FeedbackStore
extends RefCounted
## Jeu de donnees LOCAL des corrections de l'utilisateur (« Il s'est trompé »), pour re-entrainer les petites
## tetes de decision sur des situations reelles (voir docs/donnees.md).
##
## Fichier : user://dataset/feedback.jsonl (une ligne JSON par exemple ; rotation a MAX_FILE_BYTES,
## KEEP_FILES fichiers gardes). Etat d'envoi : user://dataset/sent.jsonl ({id, status, t}).
## Un exemple :
##   {v, id, time, day, task, label, source, app, category, fullscreen, game, client,
##    pet: {situation, mode, vision, vision_probs, event, event_ago},
##    emb: {b64, dtype, dim, model_id, model_version} | null,      # embedding calcule par le service local
##    share: bool,                                                    # l'utilisateur accepte de le partager
##    local: {title, note, shot, field_text}}                         # JAMAIS envoye (reste sur le PC)
## Seuls les champs listes par FeedbackUploader.build_item peuvent partir (embedding + etiquette + appli...).
##
##   var store := FeedbackStore.new()
##   store.add({"task": "activity", "label": "music", "app": "spotify", ...})
##   store.erase_all()   # « Effacer mes données d'entraînement » (aussi les captures du mode developpeur)

const VERSION := 1
const MAX_FILE_BYTES := 4 * 1048576
const KEEP_FILES := 3  # feedback.jsonl + feedback.1.jsonl + feedback.2.jsonl
const MAX_SHOTS := 300  # petites captures locales jointes aux corrections (mode developpeur)

# vocabulaire commun (identique a assistant/pompom_assist/feedback.py et server/feedback/app.py)
const ACTIVITY_LABELS := ["video", "music", "game", "code", "ai", "email", "docs", "spreadsheet", "chat", "social",
	"reading", "design", "browse", "meeting", "other"]
const GAME_EVENT_LABELS := ["goal", "goal_against", "kill", "death", "round_won", "round_lost", "match_won", "match_lost",
	"none"]
const FIELD_KIND_LABELS := ["email", "phone", "address", "url", "search", "name", "code", "chat_message", "username",
	"number", "date", "other"]
const TASKS := {"activity": ACTIVITY_LABELS, "game_event": GAME_EVENT_LABELS, "field_kind": FIELD_KIND_LABELS}

## Titres de fenetre qui ne doivent jamais etre captures (en plus de la situation "private" de situations.json).
const SENSITIVE_TITLES := ["mot de passe", "password", "passphrase", "passcode", "login", "log in", "sign in", "signin",
	"se connecter", "connectez-vous", "identifiez-vous", "connexion", "authentification", "authenticator", "2fa",
	"two-factor", "verification code", "code de vérification", "code de sécurité", "security code", "banque", "bank",
	"banking", "paypal", "carte bancaire", "credit card", "iban", "virement", "boursorama", "crédit agricole",
	"société générale", "lcl", "bnp paribas", "caisse d'epargne", "caisse d'épargne", "revolut", "n26", "impots.gouv",
	"ameli", "inprivate", "incognito", "navigation privée", "private browsing", "fenêtre privée", "keepass", "bitwarden",
	"1password", "dashlane", "lastpass"]

var dir := "user://dataset"
var max_file_bytes := MAX_FILE_BYTES


# =========================================================================== chemins
func feedback_path(i := 0) -> String:
	return dir.path_join("feedback.jsonl" if i == 0 else "feedback.%d.jsonl" % i)


func sent_path() -> String:
	return dir.path_join("sent.jsonl")


func shots_dir() -> String:
	return dir.path_join("shots")


func _ensure_dir(d: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))


# =========================================================================== ecriture
## Ajoute un exemple (complete id, date, version). Renvoie son id, ou "" s'il est invalide.
func add(sample: Dictionary) -> String:
	var s := sample.duplicate(true)
	if not valid_label(str(s.get("task", "")), str(s.get("label", ""))):
		return ""
	if str(s.get("id", "")) == "":
		s["id"] = new_id()
	if not s.has("time"):
		s["time"] = int(Time.get_unix_time_from_system())
	if not s.has("day"):
		s["day"] = today()
	s["v"] = VERSION
	s["app"] = sanitize_app(str(s.get("app", "")))
	if not s.has("share"):
		s["share"] = false
	if not s.has("client"):
		s["client"] = str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
	var line := JSON.stringify(s) + "\n"
	_ensure_dir(dir)
	_rotate_if_needed(line.to_utf8_buffer().size())
	var path := feedback_path()
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f == null:
		return ""
	f.seek_end()
	f.store_string(line)
	f.close()
	return str(s["id"])


func _rotate_if_needed(extra: int) -> void:
	var path := feedback_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var size := f.get_length() if f else 0
	if f:
		f.close()
	if size + extra <= max_file_bytes:
		return
	var ap := func(i: int) -> String: return ProjectSettings.globalize_path(feedback_path(i))
	if FileAccess.file_exists(feedback_path(KEEP_FILES - 1)):
		DirAccess.remove_absolute(ap.call(KEEP_FILES - 1))
	for i in range(KEEP_FILES - 2, -1, -1):
		if FileAccess.file_exists(feedback_path(i)):
			DirAccess.rename_absolute(ap.call(i), ap.call(i + 1))


## Note l'etat d'envoi d'exemples : "sent" (accepte par le serveur) ou "rejected" (refuse : on n'insiste pas).
func mark(ids: Array, status: String) -> void:
	if ids.is_empty():
		return
	_ensure_dir(dir)
	var path := sent_path()
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	var t := int(Time.get_unix_time_from_system())
	for id in ids:
		f.store_line(JSON.stringify({"id": str(id), "status": status, "t": t}))
	f.close()


# =========================================================================== lecture
static func _read_lines(path: String) -> Array:
	var out: Array = []
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var js := JSON.new()  # (parse_string afficherait une erreur pour une ligne tronquee)
		if js.parse(line) == OK and typeof(js.data) == TYPE_DICTIONARY:
			out.append(js.data)  # ligne tronquee (arret brutal) : ignoree
	f.close()
	return out


## id -> statut d'envoi.
func status_map() -> Dictionary:
	var m := {}
	for d in _read_lines(sent_path()):
		m[str(d.get("id", ""))] = str(d.get("status", ""))
	return m


## Tous les exemples, du plus ancien au plus recent (champ "status" ajoute : "", "sent", "rejected").
func load_all() -> Array:
	var st := status_map()
	var out: Array = []
	for i in range(KEEP_FILES - 1, -1, -1):
		for d in _read_lines(feedback_path(i)):
			d["status"] = st.get(str(d.get("id", "")), "")
			out.append(d)
	return out


func count() -> int:
	return load_all().size()


## Exemples a envoyer : partageables, avec embedding, jamais envoyes.
func pending_share(max_n := 32) -> Array:
	var out: Array = []
	for d in load_all():
		if bool(d.get("share", false)) and str(d.get("status", "")) == "" and typeof(d.get("emb")) == TYPE_DICTIONARY:
			out.append(d)
			if out.size() >= max_n:
				break
	return out


## Place prise sur le disque par tout le jeu de donnees (octets).
func disk_bytes() -> int:
	return _dir_bytes(ProjectSettings.globalize_path(dir))


static func _dir_bytes(abs_dir: String) -> int:
	var total := 0
	var da := DirAccess.open(abs_dir)
	if da == null:
		return 0
	for f in da.get_files():
		var fa := FileAccess.open(abs_dir.path_join(f), FileAccess.READ)
		if fa:
			total += fa.get_length()
			fa.close()
	for sub in da.get_directories():
		total += _dir_bytes(abs_dir.path_join(sub))
	return total


# =========================================================================== effacement
## « Effacer mes données d'entraînement » : corrections, etat d'envoi, petites captures ET captures du mode
## developpeur. Renvoie le nombre de fichiers supprimes.
func erase_all() -> int:
	return _rm_tree(ProjectSettings.globalize_path(dir))


static func _rm_tree(abs_dir: String) -> int:
	var n := 0
	var da := DirAccess.open(abs_dir)
	if da == null:
		return 0
	for sub in da.get_directories():
		n += _rm_tree(abs_dir.path_join(sub))
	for f in da.get_files():
		if DirAccess.remove_absolute(abs_dir.path_join(f)) == OK:
			n += 1
	DirAccess.remove_absolute(abs_dir)
	return n


## Garde au plus `keep` fichiers dans un dossier (supprime les plus anciens, par nom = horodatage).
static func trim_dir(abs_dir: String, keep: int) -> void:
	var files := Array(DirAccess.get_files_at(abs_dir))
	if files.size() <= keep:
		return
	files.sort()
	for i in files.size() - keep:
		DirAccess.remove_absolute(abs_dir.path_join(files[i]))


# =========================================================================== regles
static func valid_label(task: String, label: String) -> bool:
	return TASKS.has(task) and (TASKS[task] as Array).has(label)


## Nom de processus partageable : minuscules, sans .exe ni chemin, caracteres simples, 40 max.
static func sanitize_app(proc: String) -> String:
	var p := proc.strip_edges().to_lower().replace("\\", "/").get_file()
	if p.ends_with(".exe"):
		p = p.substr(0, p.length() - 4)
	var out := ""
	for ch in p:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch in [".", "_", "-", "+", " "]:
			out += ch
	out = out.strip_edges().left(40)
	while out != "" and not ((out[0] >= "a" and out[0] <= "z") or (out[0] >= "0" and out[0] <= "9")):
		out = out.substr(1)
	return out


## Contexte ou l'on ne capture RIEN (ni capture locale, ni embedding) : gestionnaire de mots de passe, page de
## connexion / 2FA / banque, navigation privee, visio, enregistrement ou stream en cours.
static func is_private_context(proc: String, title: String, category := "", meeting := false, recording := false) -> bool:
	if meeting or recording:
		return true
	if Situations.detect(proc, title, category) == "private":
		return true
	var t := title.to_lower()
	for k in SENSITIVE_TITLES:
		if t.contains(k):
			return true
	return false


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()


static func today() -> String:
	return Time.get_date_string_from_system()
