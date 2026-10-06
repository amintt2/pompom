extends Node
## Surveille l'activite de l'utilisateur et fait gagner des pieces.
## Windows : via helper/pompom_helper.ps1 (lu dans un thread).
## Autres plateformes : temps passe avec l'appli ouverte.

signal changed  # categorie / plein ecran / inactivite ont change
signal coins_earned(amount: int, kind: String)
signal foreground_changed(hwnd: int)

const IDLE_LIMIT := 90.0  # au-dela, l'utilisateur est considere absent
const RATES := {"work": 3.0, "game": 3.0, "browse": 1.0, "media": 0.5, "other": 1.0, "pet": 1.0}

const WORK_PROCS := [
	"code", "code - insiders", "cursor", "windsurf", "zed", "devenv", "rider64", "idea64", "pycharm64",
	"webstorm64", "clion64", "goland64", "phpstorm64", "rustrover64", "studio64", "sublime_text",
	"notepad++", "notepad", "windowsterminal", "wt", "powershell", "pwsh", "cmd", "conhost", "claude",
	"winword", "excel", "powerpnt", "onenote", "outlook", "olk", "teams", "ms-teams", "slack", "notion",
	"obsidian", "figma", "blender", "godot", "unity", "unrealeditor", "photoshop", "illustrator",
	"afterfx", "adobe premiere pro", "resolve", "acrobat", "zoom", "gitkraken", "githubdesktop",
	"postman", "dbeaver", "matlab", "rstudio", "soffice", "libreoffice", "krita", "inkscape", "affinity",
	"clipstudiopaint", "aseprite", "fl64", "ableton live 12 suite", "reaper", "audacity", "obs64",
]
const BROWSERS := ["chrome", "msedge", "firefox", "opera", "opera_gx", "brave", "vivaldi", "arc", "zen", "floorp"]
const WORK_TITLES := [
	"claude", "github", "gitlab", "stack overflow", "google docs", "google sheets", "google slides",
	"gmail", "outlook", "notion", "figma", "jira", "linear", "chatgpt", "trello", "confluence",
	"vercel", "supabase", "localhost", "docs", "documentation", "canva", "miro", "overleaf",
]
const MEDIA_TITLES := ["youtube", "netflix", "twitch", "prime video", "disney+", "crunchyroll", "spotify", "deezer"]
const MEDIA_PROCS := ["vlc", "spotify", "mpc-hc64", "mpc-be64", "potplayermini64", "netflix", "deezer"]
const GAME_PATHS := [
	"steamapps\\common", "epic games", "riot games", "gog galaxy\\games", "xboxgames", "ubisoft game launcher\\games",
	"ea games", "battle.net", "rockstar games", "minecraft", "hoyoplay", "genshin impact",
]
const GAME_PROCS := [
	"robloxplayerbeta", "valorant", "league of legends", "fortniteclient-win64-shipping", "cs2", "dota2",
	"gta5", "rocketleague", "overwatch", "eldenring", "minecraft", "javaw", "genshinimpact", "r5apex",
	"destiny2", "cod", "fifa", "eafc", "starrail", "zenlesszonezero", "osu!", "hollow_knight", "terraria",
	"stardew valley", "among us", "brawlhalla", "pubg", "tslgame", "rainbowsix", "warframe.x64",
]

var available := false  # helper Windows actif
var category := "other"  # work | game | browse | media | other
var idle_sec := 0.0
var fullscreen := false
var proc_name := ""
var window_title := ""
var windows: Array = []  # fenetres visibles, avant -> arriere : {id, rect: Rect2, max: bool}
var fg_hwnd := 0

var _pipe: FileAccess
var _pid := -1
var _thread: Thread
var _mutex := Mutex.new()
var _lines: PackedStringArray = []
var _running := false
var _accum := {}  # kind -> secondes actives non encore converties en pieces
var _tick := 0.0
var _continuous_work := 0.0
var _last_break_hint := 0.0


func is_active() -> bool:
	return idle_sec < IDLE_LIMIT


func start(hwnd: int) -> void:
	if OS.get_name() != "Windows" or _running:
		return
	var src := FileAccess.open("res://helper/pompom_helper.ps1", FileAccess.READ)
	if src == null:
		push_warning("helper introuvable")
		return
	var dst_path := "user://pompom_helper.ps1"
	var dst := FileAccess.open(dst_path, FileAccess.WRITE)
	dst.store_string(src.get_as_text())
	dst.close()
	var abs_path := ProjectSettings.globalize_path(dst_path)
	var args := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", abs_path, "-ParentPid", str(OS.get_process_id()), "-Hwnd", str(hwnd),
	])
	var d := OS.execute_with_pipe("powershell.exe", args, true)
	if d.is_empty():
		push_warning("impossible de lancer le helper")
		return
	_pipe = d["stdio"]
	_pid = d["pid"]
	_running = true
	_thread = Thread.new()
	_thread.start(_reader)


func _reader() -> void:
	while _running and _pipe and _pipe.is_open():
		var line := _pipe.get_line()
		if _pipe.get_error() != OK and line == "":
			break
		if line.begins_with("{"):
			_mutex.lock()
			_lines.append(line)
			_mutex.unlock()


func _exit_tree() -> void:
	stop()


func stop() -> void:
	if not _running:
		return
	_running = false
	if _pid > 0:
		OS.kill(_pid)
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func _process(delta: float) -> void:
	_mutex.lock()
	var lines := _lines
	_lines = PackedStringArray()
	_mutex.unlock()
	for l in lines:
		_handle(l)
	_tick += delta
	if _tick >= 1.0:
		_tick -= 1.0
		_second()


func _handle(line: String) -> void:
	var d = JSON.parse_string(line)
	if typeof(d) != TYPE_DICTIONARY:
		return
	available = true
	var prev := [category, fullscreen, is_active()]
	var wl = d.get("wins", [])
	if typeof(wl) == TYPE_ARRAY:
		var out: Array = []
		for w in wl:
			if typeof(w) == TYPE_ARRAY and w.size() >= 6:
				out.append({"id": int(w[0]), "rect": Rect2(float(w[1]), float(w[2]), float(w[3]), float(w[4])), "max": int(w[5]) == 1})
		windows = out
	if not bool(d.get("self", false)):
		var fg := int(d.get("fg", 0))
		if fg != fg_hwnd:
			fg_hwnd = fg
			foreground_changed.emit(fg)
	idle_sec = float(d.get("idle", 0.0))
	if not bool(d.get("self", false)):
		proc_name = str(d.get("proc", "")).to_lower()
		window_title = str(d.get("title", ""))
		fullscreen = bool(d.get("fs", false))
		category = classify(proc_name, window_title, str(d.get("path", "")), fullscreen)
	if prev != [category, fullscreen, is_active()]:
		changed.emit()


static func classify(proc: String, title: String, path: String, fs: bool) -> String:
	var t := title.to_lower()
	var p := path.to_lower()
	if proc == "" or proc == "explorer" or proc == "searchhost" or proc == "shellexperiencehost":
		return "other"
	for g in GAME_PATHS:
		if p.contains(g):
			return "game"
	if GAME_PROCS.has(proc):
		return "game"
	if BROWSERS.has(proc):
		for m in MEDIA_TITLES:
			if t.contains(m):
				return "media"
		for w in WORK_TITLES:
			if t.contains(w):
				return "work"
		return "browse"
	if MEDIA_PROCS.has(proc):
		return "media"
	if WORK_PROCS.has(proc):
		return "work"
	if fs:
		return "game"  # appli plein ecran inconnue : tres probablement un jeu
	return "other"


func _second() -> void:
	var kind := category
	var active := is_active()
	if not available:
		# Mobile / autres OS : le temps avec l'appli ouverte compte comme "pet".
		kind = "pet"
		active = true
	if active:
		GameState.add_activity_time(kind, 1.0)
		_accum[kind] = float(_accum.get(kind, 0.0)) + 1.0
		if float(_accum[kind]) >= 60.0:
			_accum[kind] = 0.0
			var amount := int(round(float(RATES.get(kind, 1.0)) * GameState.earn_multiplier()))
			if amount > 0:
				GameState.add_coins(amount)
				coins_earned.emit(amount, kind)
			# une minute ensemble = un peu d'XP et des quetes qui avancent
			GameState.add_xp(1)
			if kind == "work":
				GameState.quest_event("work_min")
			elif kind == "game":
				GameState.quest_event("game_min")
		if kind == "work" or kind == "game":
			_continuous_work += 1.0
		GameState.change_energy(-1.0 / 360.0)
	else:
		_continuous_work = maxf(0.0, _continuous_work - 3.0)
		GameState.change_energy(1.0 / 40.0)
	# Besoins : la faim et l'amusement descendent doucement (environ -10 / heure).
	GameState.change_hunger(-1.0 / (360.0 if active else 720.0))
	GameState.change_fun(-1.0 / (330.0 if active else 900.0))
	# Le bonheur depend de la tenue, de la faim et de l'amusement.
	var outfit := GameState.outfit_score()
	var mood := -1.0 / 900.0 + outfit * (1.0 / 1200.0)
	if GameState.hunger < 25.0:
		mood -= 1.0 / 300.0
	if GameState.fun < 25.0:
		mood -= 1.0 / 400.0
	if GameState.hunger > 60.0 and GameState.fun > 60.0:
		mood += 1.0 / 600.0
	GameState.change_happiness(mood)


## Vrai une fois toutes les ~2 h de travail continu : suggere une pause.
func wants_break_hint() -> bool:
	if _continuous_work > 7200.0 and Time.get_ticks_msec() / 1000.0 - _last_break_hint > 3600.0:
		_last_break_hint = Time.get_ticks_msec() / 1000.0
		_continuous_work = 0.0
		return true
	return false
