class_name Situations
## Detection de la "situation" de l'utilisateur (lit ses mails, code, ecoute de la musique...)
## d'apres le processus au premier plan et le titre de sa fenetre.
## Les regles sont dans res://data/situations.json (testees dans l'ordre, la premiere gagne).
##
## Utilisation :
##   var sid := Situations.detect(Activity.proc_name, Activity.window_title, Activity.category,
##       {"idle": Activity.idle_sec, "meeting": Activity.meeting, "hour": Time.get_datetime_dict_from_system()["hour"]})
##   -> "email_read", "coding", "music_listen"... ou "" (rien de particulier)

const DATA_PATH := "res://data/situations.json"

static var _data: Dictionary = {}
static var _browsers: Dictionary = {}
static var _terminals: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f:
			var d = JSON.parse_string(f.get_as_text())
			if typeof(d) == TYPE_DICTIONARY:
				_data = d
		if _data.is_empty():
			push_warning("situations.json illisible")
			_data = {"rules": [], "situations": {}, "browsers": [], "terminals": []}
		for b in _data.get("browsers", []):
			_browsers[str(b)] = true
		for t in _data.get("terminals", []):
			_terminals[str(t)] = true
	return _data


## Toutes les situations connues (id -> {label, lines}).
static func all() -> Dictionary:
	return data().get("situations", {})


static func label(sid: String) -> String:
	return str(all().get(sid, {}).get("label", sid))


## Petites phrases (francais) pour une situation ; vide = il reste silencieux.
static func lines(sid: String) -> Array:
	return all().get(sid, {}).get("lines", [])


static func is_browser(proc: String) -> bool:
	data()
	return _browsers.has(_clean_proc(proc))


static func is_terminal(proc: String) -> bool:
	data()
	return _terminals.has(_clean_proc(proc))


static func is_late(hour: int) -> bool:
	return data().get("late_hours", []).has(float(hour)) or data().get("late_hours", []).has(hour)


## extra (optionnel) : idle (s), meeting (bool), hour (0-23, -1 = ignore).
static func detect(proc: String, title: String, category := "", extra := {}) -> String:
	var d := data()
	var p := _clean_proc(proc)
	var idle := float(extra.get("idle", 0.0))
	if idle >= float(d.get("afk_after", 180.0)):
		return "afk"
	if bool(extra.get("meeting", false)):
		return "meeting"
	var browser := _browsers.has(p)
	var terminal := _terminals.has(p)
	var t := clean_title(title, browser)
	var sid := ""
	for r in d.get("rules", []):
		if _match(r, p, t, category, browser, terminal):
			sid = str(r.get("id", ""))
			break
	if sid == "" and browser and t != "":
		sid = "browsing"
	var hour := int(extra.get("hour", -1))
	if hour >= 0 and is_late(hour) and d.get("late_override", []).has(sid):
		sid = "late_night"
	return sid


static func _clean_proc(proc: String) -> String:
	var p := proc.strip_edges().to_lower()
	if p.ends_with(".exe"):
		p = p.substr(0, p.length() - 4)
	return p


const _BROWSER_SUFFIXES := ["google chrome", "chrome", "mozilla firefox", "firefox", "microsoft edge", "microsoft​ edge",
	"edge", "brave", "opera", "opera gx", "vivaldi", "arc", "zen browser", "floorp", "librewolf", "waterfox", "chromium",
	"thorium", "yandex browser", "comet", "dia"]
const _PROFILE_WORDS := ["personnel", "personal", "travail", "work", "perso", "pro", "école", "school", "invité", "guest",
	"inprivate", "navigation privée", "private browsing"]


## Titre en minuscules, sans le nom du navigateur ni le profil Edge ("... - Personnel - Microsoft Edge").
static func clean_title(title: String, browser := false) -> String:
	var t := title.strip_edges().to_lower().replace("​", "")
	if not browser:
		return t
	for _i in 3:
		var cut := -1
		for sep in [" - ", " — ", " – "]:
			cut = maxi(cut, t.rfind(sep))
		if cut < 0:
			break
		var last := t.substr(cut + 3).strip_edges()
		var is_suffix := _BROWSER_SUFFIXES.has(last) or _PROFILE_WORDS.has(last) or last.begins_with("profil") \
			or last.begins_with("profile")
		if not is_suffix:
			break
		t = t.substr(0, cut).strip_edges()
	# Edge : "titre et 3 pages supplementaires" / "title and 2 more pages"
	var re := RegEx.create_from_string("\\s+(et \\d+ pages? supplémentaires?|and \\d+ more pages?)$")
	t = re.sub(t, "").strip_edges()
	return t


static func _proc_match(list: Array, p: String) -> bool:
	for e in list:
		var s := str(e)
		var a := s.begins_with("*")
		var b := s.ends_with("*") and s.length() > 1
		var core := s.trim_prefix("*").trim_suffix("*")
		if a and b:
			if p.contains(core):
				return true
		elif b:
			if p.begins_with(core):
				return true
		elif a:
			if p.ends_with(core):
				return true
		elif p == s:
			return true
	return false


static func _match(r: Dictionary, p: String, t: String, category: String, browser: bool, terminal: bool) -> bool:
	if r.has("category") and str(r["category"]) != category:
		return false
	match str(r.get("apps", "")):
		"browser":
			if not browser:
				return false
		"terminal":
			if not terminal:
				return false
		"app":
			if browser:
				return false
	if r.has("procs") and not _proc_match(r["procs"], p):
		return false
	if bool(r.get("need_title", false)) and t == "":
		return false
	if r.has("not"):
		for n in r["not"]:
			if t.contains(str(n)):
				return false
	var any_title_rule := r.has("titles") or r.has("ends") or r.has("equals")
	if not any_title_rule:
		return true
	if r.has("equals") and r["equals"].has(t):
		return true
	if r.has("ends"):
		for e in r["ends"]:
			if t.ends_with(str(e)):
				return true
	if r.has("titles"):
		for k in r["titles"]:
			if t.contains(str(k)):
				return true
	return false
