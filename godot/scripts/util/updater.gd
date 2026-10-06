class_name Updater
extends Node
## Mises a jour automatiques depuis les Releases GitHub.
## - sonde toutes les 10 min si la version suivante est deja telechargeable (lien direct, sans attendre
##   l'API GitHub qui peut avoir du retard), et interroge l'API toutes les 3 h (reglage "auto_update")
## - verification manuelle : check_now() (menu "Chercher une mise a jour")
## - previent quand une version plus recente existe (signal update_available)
## - n'installe QUE si l'utilisateur le demande : telecharge Pompom.exe + SHA256SUMS.txt,
##   verifie l'empreinte SHA-256, puis un petit script remplace l'exe et relance le jeu.

signal update_available(version: String, notes: String)
signal update_progress(text: String)
signal update_failed(reason: String)
signal check_finished(found: bool)

const REPO := "amintt2/pompom"
const API := "https://api.github.com/repos/%s/releases?per_page=10" % REPO
const RELEASES_PAGE := "https://github.com/%s/releases" % REPO
const ASSET_EXE := "Pompom.exe"
const ASSET_SUMS := "SHA256SUMS.txt"
const DOWNLOAD := "https://github.com/%s/releases/download/v%s/%s"
const PROBE_EVERY := 10.0 * 60.0
const API_EVERY := 3.0 * 3600.0

var latest := {}  # {version, notes, exe_url, sums_url}
var _api_timer := 20.0
var _probe_timer := 20.0 + PROBE_EVERY
var _busy := false


static func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## Compare deux versions "1.2.3" / "1.2.3-beta" : >0 si a > b. Une beta est avant la version finale.
static func compare(a: String, b: String) -> int:
	var pa := _parse(a)
	var pb := _parse(b)
	for i in 3:
		if pa[i] != pb[i]:
			return 1 if pa[i] > pb[i] else -1
	# meme numero : "" (finale) > "rc" > "beta" > "alpha"
	var rank := {"": 4, "rc": 3, "beta": 2, "alpha": 1}
	var ra: int = rank.get(pa[3], 0)
	var rb: int = rank.get(pb[3], 0)
	if ra != rb:
		return 1 if ra > rb else -1
	return signi(pa[4] - pb[4])


static func _parse(v: String) -> Array:
	v = v.strip_edges().trim_prefix("v").to_lower()
	var pre := ""
	var pre_n := 0
	var dash := v.find("-")
	if dash >= 0:
		var tail := v.substr(dash + 1)
		v = v.substr(0, dash)
		for k in ["alpha", "beta", "rc"]:
			if tail.begins_with(k):
				pre = k
				pre_n = int(tail.trim_prefix(k).trim_prefix(".")) if tail.length() > k.length() else 0
	var nums := v.split(".")
	var out: Array = [0, 0, 0, pre, pre_n]
	for i in mini(3, nums.size()):
		out[i] = int(nums[i])
	return out


## Versions qui pourraient suivre `v` (de la plus proche a la plus lointaine).
static func next_candidates(v: String) -> PackedStringArray:
	var p := _parse(v)
	var x: int = p[0]
	var y: int = p[1]
	var z: int = p[2]
	var pre: String = p[3]
	var out := PackedStringArray()
	if pre != "":
		out.append("%d.%d.%d" % [x, y, z])
	for base in ["%d.%d.%d" % [x, y, z + 1], "%d.%d.0" % [x, y + 1], "%d.0.0" % [x + 1]]:
		if pre != "":
			out.append("%s-%s" % [base, pre])
		out.append(base)
	return out


func _process(delta: float) -> void:
	if not bool(GameState.settings.get("auto_update", true)) or _busy:
		return
	_api_timer -= delta
	_probe_timer -= delta
	if _api_timer <= 0.0:
		_api_timer = API_EVERY
		_probe_timer = PROBE_EVERY
		check()
	elif _probe_timer <= 0.0:
		_probe_timer = PROBE_EVERY
		probe()


## Verification immediate demandee par l'utilisateur : sonde directe puis API. Emet check_finished.
func check_now() -> void:
	if _busy:
		return
	var found := await probe()
	if not found:
		found = await check()
	check_finished.emit(found or not latest.is_empty())


## Sonde directe : la version suivante a-t-elle deja ses fichiers en ligne ? (des que la Release est publiee)
func probe() -> bool:
	if _busy:
		return false
	_busy = true
	var base := current_version()
	if not latest.is_empty() and compare(latest["version"], base) > 0:
		base = latest["version"]
	var found := ""
	for _i in 6:  # plusieurs versions d'avance possibles
		var hit := ""
		for c in next_candidates(base):
			var has_sums: bool = await _exists(DOWNLOAD % [REPO, c, ASSET_SUMS])
			if not has_sums:
				continue
			var has_exe: bool = await _exists(DOWNLOAD % [REPO, c, ASSET_EXE])
			if has_exe:
				hit = c
				break
		if hit == "":
			break
		found = hit
		base = hit
	_busy = false
	if found == "" or compare(found, current_version()) <= 0:
		return false
	if not latest.is_empty() and compare(found, latest["version"]) <= 0:
		return false
	latest = {"version": found, "notes": "", "exe_url": DOWNLOAD % [REPO, found, ASSET_EXE],
		"sums_url": DOWNLOAD % [REPO, found, ASSET_SUMS]}
	update_available.emit(found, "")
	return true


func _exists(url: String) -> bool:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = 10.0
	req.max_redirects = 0  # GitHub repond 302 (fichier present) ou 404 (absent) : pas besoin de suivre
	add_child(req)
	if req.request(url, ["User-Agent: Pompom-updater"], HTTPClient.METHOD_HEAD) != OK:
		req.queue_free()
		return false
	var res: Array = await req.request_completed
	req.queue_free()
	var code := int(res[1])
	return code == 200 or code == 302


## Interroge l'API GitHub (liste des Releases, avec les notes). Renvoie true si une nouvelle version est annoncee.
func check() -> bool:
	if _busy:
		return false
	_busy = true
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = 15.0
	add_child(req)
	var err := req.request(API, ["Accept: application/vnd.github+json", "User-Agent: Pompom-updater"])
	if err != OK:
		_busy = false
		req.queue_free()
		return false
	var res: Array = await req.request_completed
	req.queue_free()
	_busy = false
	if int(res[1]) != 200:
		return false
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if typeof(data) != TYPE_ARRAY:
		return false
	var best := {}
	for rel in data:
		if typeof(rel) != TYPE_DICTIONARY or rel.get("draft", false):
			continue
		var ver := str(rel.get("tag_name", "")).trim_prefix("v")
		var exe_url := ""
		var sums_url := ""
		for a in rel.get("assets", []):
			match str(a.get("name", "")):
				ASSET_EXE:
					exe_url = str(a.get("browser_download_url", ""))
				ASSET_SUMS:
					sums_url = str(a.get("browser_download_url", ""))
		if exe_url == "" or sums_url == "":
			continue
		if best.is_empty() or compare(ver, best["version"]) > 0:
			best = {"version": ver, "notes": str(rel.get("body", "")), "exe_url": exe_url, "sums_url": sums_url}
	if best.is_empty() or compare(best["version"], current_version()) <= 0:
		return false
	if not latest.is_empty() and compare(best["version"], latest["version"]) < 0:
		return false
	var fresh := latest.is_empty() or compare(best["version"], latest["version"]) > 0
	latest = best  # (memes fichiers ; l'API apporte en plus les notes de version)
	if fresh:
		update_available.emit(best["version"], best["notes"])
	return fresh


## Telecharge, verifie et installe la derniere version (a appeler apres accord de l'utilisateur).
func install() -> void:
	if latest.is_empty() or _busy:
		return
	if not OS.has_feature("template") or OS.get_name() != "Windows":
		OS.shell_open(RELEASES_PAGE)
		return
	_busy = true
	var dir := ProjectSettings.globalize_path("user://update")
	DirAccess.make_dir_recursive_absolute(dir)
	var exe_tmp := dir.path_join("Pompom.new.exe")
	update_progress.emit("Je télécharge la version %s..." % latest["version"])
	var sums := await _get_text(latest["sums_url"])
	var expected := ""
	for line in sums.split("\n"):
		var parts := line.strip_edges().split(" ", false)
		if parts.size() >= 2 and parts[parts.size() - 1].trim_prefix("*") == ASSET_EXE:
			expected = parts[0].to_lower()
	if expected.length() != 64:
		_fail("Empreinte de sécurité introuvable, mise à jour annulée.")
		return
	var ok := await _download(latest["exe_url"], exe_tmp)
	if not ok:
		_fail("Le téléchargement a échoué.")
		return
	var got := FileAccess.get_sha256(exe_tmp).to_lower()
	if got != expected:
		DirAccess.remove_absolute(exe_tmp)
		_fail("Le fichier téléchargé n'est pas intact (empreinte différente). Mise à jour annulée.")
		return
	update_progress.emit("Tout est vérifié, je redémarre !")
	var target := OS.get_executable_path()
	var script := dir.path_join("apply_update.ps1")
	var f := FileAccess.open(script, FileAccess.WRITE)
	f.store_string("""param([int]$P, [string]$New, [string]$Target)
$ErrorActionPreference = 'Stop'
for ($i = 0; $i -lt 100; $i++) { if (-not (Get-Process -Id $P -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 200 }
$backup = "$Target.old"
try {
  Copy-Item -LiteralPath $Target -Destination $backup -Force
  Copy-Item -LiteralPath $New -Destination $Target -Force
  Remove-Item -LiteralPath $New -Force
} catch {
  if (Test-Path $backup) { Copy-Item -LiteralPath $backup -Destination $Target -Force }
}
Start-Process -FilePath $Target
""")
	f.close()
	GameState.save_game()
	OS.create_process("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", script, "-P", str(OS.get_process_id()), "-New", exe_tmp, "-Target", target])
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()


func _fail(reason: String) -> void:
	_busy = false
	update_failed.emit(reason)


func _get_text(url: String) -> String:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = 30.0
	add_child(req)
	if req.request(url, ["User-Agent: Pompom-updater"]) != OK:
		req.queue_free()
		return ""
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[1]) != 200:
		return ""
	return (res[3] as PackedByteArray).get_string_from_utf8()


func _download(url: String, path: String) -> bool:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.download_file = path
	req.timeout = 600.0
	add_child(req)
	if req.request(url, ["User-Agent: Pompom-updater"]) != OK:
		req.queue_free()
		return false
	var res: Array = await req.request_completed
	req.queue_free()
	return int(res[0]) == HTTPRequest.RESULT_SUCCESS and int(res[1]) == 200 and FileAccess.file_exists(path)
