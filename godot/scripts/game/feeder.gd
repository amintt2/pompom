class_name Feeder
## Nourrir le compagnon avec des fichiers : ils partent dans la Corbeille (toujours restaurables).
## Securite : jamais de dossiers, jamais de fichiers systeme ou d'applications installees,
## jamais les fichiers de Pompom lui-meme.

const MAX_PER_MEAL := 10

## Chemins proteges (en minuscules, separateur "/").
static func _protected_roots() -> Array:
	var roots: Array = ["c:/windows", "c:/program files", "c:/program files (x86)", "c:/programdata",
		"c:/$recycle.bin", "c:/system volume information", "c:/recovery", "c:/boot"]
	for env in ["APPDATA", "LOCALAPPDATA", "WINDIR", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA"]:
		var v := OS.get_environment(env)
		if v != "":
			roots.append(v.replace("\\", "/").to_lower())
	roots.append(ProjectSettings.globalize_path("user://").to_lower().trim_suffix("/"))
	roots.append(OS.get_executable_path().get_base_dir().replace("\\", "/").to_lower())
	return roots


## Renvoie "" si le fichier peut etre mange, sinon la raison du refus (en francais).
static func refusal(path: String) -> String:
	var p := path.replace("\\", "/")
	if DirAccess.dir_exists_absolute(p):
		return "Un dossier entier ? Trop gros pour moi !"
	if not FileAccess.file_exists(p):
		return "Je ne trouve pas ce fichier."
	var low := p.to_lower()
	if low.length() <= 3:
		return "Hors de question !"
	for root in _protected_roots():
		if root != "" and low.begins_with(String(root) + "/"):
			return "Ça, c'est un fichier important, je n'y touche pas !"
	var name := p.get_file().to_lower()
	if name in ["desktop.ini", "thumbs.db", "ntuser.dat", "pagefile.sys", "hiberfil.sys", "swapfile.sys"]:
		return "Ça, c'est un fichier important, je n'y touche pas !"
	if name.get_extension() in ["sys", "dll", "lnk"]:
		return "Pas ça, c'est un fichier du système (ou un raccourci)."
	return ""


static func size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


## Satiete apportee par un fichier : les gros fichiers nourrissent plus (echelle logarithmique).
static func nutrition(size: int) -> float:
	return clampf(4.0 + log(float(size) + 1.0) / log(10.0) * 2.6, 5.0, 28.0)


## Met le fichier a la Corbeille. Renvoie OK si c'est fait.
static func eat(path: String) -> Error:
	if refusal(path) != "":
		return ERR_UNAUTHORIZED
	return OS.move_to_trash(ProjectSettings.globalize_path(path))


static func human_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d o" % bytes
	if bytes < 1024 * 1024:
		return "%.0f Ko" % (bytes / 1024.0)
	if bytes < 1024 * 1024 * 1024:
		return "%.1f Mo" % (bytes / 1048576.0)
	return "%.2f Go" % (bytes / 1073741824.0)
