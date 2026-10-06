class_name GamePaths
extends RefCounted
## Retrouve les dossiers d'installation des jeux (Steam, Epic) sans rien modifier.
## Uniquement en lecture : utilise par les assistants de configuration (Rocket League, CS2, Dota 2),
## jamais dans la boucle de jeu. Toutes les fonctions sont statiques et rapides (quelques lectures de
## fichiers) ; seul steam_root() peut lancer `reg query` une fois si Steam n'est pas a un endroit connu.

const STEAM_GUESSES := [
	"C:/Program Files (x86)/Steam", "C:/Program Files/Steam", "D:/Steam", "D:/SteamLibrary",
	"E:/Steam", "E:/SteamLibrary",
]

static var _steam_root_cache := ""


## Dossier racine de Steam ("" si introuvable).
static func steam_root() -> String:
	if _steam_root_cache != "" and DirAccess.dir_exists_absolute(_steam_root_cache):
		return _steam_root_cache
	if OS.get_name() != "Windows":
		var home := OS.get_environment("HOME")
		for g in [home + "/.steam/steam", home + "/.local/share/Steam"]:
			if FileAccess.file_exists(g + "/steamapps/libraryfolders.vdf"):
				_steam_root_cache = g
				return g
		return ""
	for g in STEAM_GUESSES:
		if FileAccess.file_exists(g + "/steamapps/libraryfolders.vdf"):
			_steam_root_cache = g
			return g
	# Steam installe ailleurs : la base de registre le sait (appel ponctuel, hors boucle de jeu)
	var out := []
	if OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"], out, false, false) == 0 and out.size() > 0:
		for line in str(out[0]).split("\n"):
			var i := line.find("REG_SZ")
			if i >= 0:
				var p := line.substr(i + 6).strip_edges().replace("\\", "/")
				if DirAccess.dir_exists_absolute(p):
					_steam_root_cache = p
					return p
	return ""


## Toutes les bibliotheques Steam (dossiers contenant steamapps/).
static func steam_libraries() -> PackedStringArray:
	var libs := PackedStringArray()
	var root := steam_root()
	if root == "":
		return libs
	libs.append(root)
	for vdf in [root + "/steamapps/libraryfolders.vdf", root + "/config/libraryfolders.vdf"]:
		var txt := FileAccess.get_file_as_string(vdf)
		if txt == "":
			continue
		for p in parse_vdf_paths(txt):
			var n := p.replace("\\\\", "/").replace("\\", "/")
			if not libs.has(n) and DirAccess.dir_exists_absolute(n):
				libs.append(n)
	return libs


## Extrait les valeurs "path" d'un libraryfolders.vdf (format KeyValues de Valve).
static func parse_vdf_paths(txt: String) -> PackedStringArray:
	var res := PackedStringArray()
	var re := RegEx.create_from_string("\"path\"\\s+\"([^\"]+)\"")
	for m in re.search_all(txt):
		res.append(m.get_string(1))
	return res


## Dossier steamapps/common/<folder> du premier disque qui l'a ("" sinon).
static func steam_app_dir(folder: String) -> String:
	for lib in steam_libraries():
		var d: String = lib + "/steamapps/common/" + folder
		if DirAccess.dir_exists_absolute(d):
			return d
	return ""


## Dossier d'installation Epic Games d'un jeu : `match` est compare (minuscules) a AppName,
## DisplayName et InstallLocation des manifestes du lanceur Epic.
static func epic_install(match_any: PackedStringArray) -> String:
	var pd := OS.get_environment("ProgramData")
	if pd == "":
		pd = "C:/ProgramData"
	var dir_path := pd.replace("\\", "/") + "/Epic/EpicGamesLauncher/Data/Manifests"
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	for f in d.get_files():
		if not f.to_lower().ends_with(".item"):
			continue
		var j = JSON.parse_string(FileAccess.get_file_as_string(dir_path + "/" + f))
		if typeof(j) != TYPE_DICTIONARY:
			continue
		var hay := (str(j.get("AppName", "")) + "|" + str(j.get("DisplayName", "")) + "|" + str(j.get("InstallLocation", ""))).to_lower()
		for m in match_any:
			if hay.contains(m.to_lower()):
				var loc := str(j.get("InstallLocation", "")).replace("\\", "/")
				if loc != "" and DirAccess.dir_exists_absolute(loc):
					return loc
	return ""


## Dossier "Documents" de l'utilisateur (gere la redirection OneDrive).
static func documents_dir() -> String:
	var d := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).replace("\\", "/")
	if d == "":
		d = OS.get_environment("USERPROFILE").replace("\\", "/") + "/Documents"
	return d


## Sauvegarde unique `<path>.pompom.bak` (garde l'original intact : n'ecrase jamais une sauvegarde).
static func backup_once(path: String) -> bool:
	var bak := path + ".pompom.bak"
	if FileAccess.file_exists(bak) or not FileAccess.file_exists(path):
		return true
	var src := FileAccess.get_file_as_bytes(path)
	var f := FileAccess.open(bak, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(src)
	f.close()
	return true


## Ecrit un fichier texte et verifie la relecture. Retourne "" si OK, sinon un message (francais).
static func write_text_checked(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Impossible d'écrire %s (%s). Droits administrateur nécessaires ?" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	f.close()
	if FileAccess.get_file_as_string(path) != text:
		return "Écriture incomplète de %s." % path
	return ""
