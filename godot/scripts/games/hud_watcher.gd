class_name HudWatcher
extends Node
## Detection des eliminations ET des morts de l'utilisateur dans les jeux SANS API officielle
## (Valorant, Fortnite),
## en regardant de toutes petites zones de l'ecran, comme Medal.tv / Insights. Capture d'ecran
## uniquement (DisplayServer.screen_get_image_rect = GDI BitBlt, comme OBS « capture d'ecran » ou
## Discord) : aucune lecture memoire, aucune injection, aucune entree simulee.
##
## Fonctionnement : profils de jeu « data-driven » (PROFILES), zones relatives a l'ecran du jeu,
## echantillonnees 3 fois/s dans WorkerThreadPool. Trois types de zones :
##   "flash"  : un bandeau qui APPARAIT (ex. bandeau d'elimination Valorant en bas au centre) : la part
##              de pixels de la bonne couleur passe au-dessus de on_frac (apres etre restee sous
##              off_frac) ; tant qu'il reste affiche, un changement d'empreinte = elimination suivante.
##   "digits" : un compteur (ex. eliminations Fortnite sous la mini-carte) : son empreinte change
##              (stable sur 2 captures) alors qu'il etait deja visible = +1.
##   "grey"   : l'image perd ses couleurs (observation apres la mort) ; experimental, coupe par defaut.
## Chaque zone a un `kind` : "kill" (defaut) ou "death". Morts : Valorant = bandeau « tué par » en bas au
## centre (nom du tueur en rouge) ; Fortnite = bandeau « éliminé par » / interface d'observation en haut.
## Couts mesures (docs/game_events.md) : ~0,35 ms CPU par petite capture GDI + ~1 ms d'analyse, sur un
## thread de travail ; l'appel GDI attend ~6-10 ms la composition de Windows (attente, pas du calcul).
## Ancrage (ecrans 16:9, 16:10, ultra-larges) : les coordonnees x des zones sont exprimees dans une
## boite de reference 16:9 de la hauteur de l'ecran, centree ("center") ou collee a un bord
## ("left"/"right") ; y est relatif a la hauteur. Si l'ecran est moins large que 16:9 (16:10), la boite
## fait la largeur de l'ecran.
##
## LIMITES (honnetes) : les zones par defaut sont des ESTIMATIONS de l'emplacement des elements du HUD
## par defaut, NON verifiees sur de vraies images de ces jeux (ni Valorant ni Fortnite sur ce PC) ; elles changent si l'utilisateur modifie l'echelle / la
## disposition du HUD ou la banniere d'elimination. Elles se recalibrent par `set_region()` (ou le
## reglage "hud_regions"). Voir docs/game_events.md.
##
## Capture : en plein ecran EXCLUSIF, la capture GDI peut renvoyer une image noire ou figee.
## `capture_status` : "idle" | "ok" | "black" | "frozen" -> l'interface peut conseiller
## « Mets le jeu en plein écran fenêtré » (fenetre sans bordure).

signal hud_event(game: String, kind: String, mine: bool, data: Dictionary)
signal capture_status_changed(status: String)

## Profils. rect = [x, y, w, h] (x/w dans la boite de reference 16:9, y/h relatifs a la hauteur).
## kind : evenement emis ("kill" par defaut, "death") ; enabled = false : zone experimentale coupee.
const PROFILES := {
	"valorant": {
		"procs": ["valorant-win64-shipping"],
		"regions": {
			# bandeau d'elimination (icone + chevrons) au-dessus de la barre de competences
			"kill_banner": {"rect": [0.455, 0.70, 0.09, 0.10], "anchor": "center", "mode": "flash",
				"color": "white", "on_frac": 0.10, "off_frac": 0.03},
			# recapitulatif de mort « TUÉ PAR » (nom/agent du tueur en rouge) en bas au centre
			"death_banner": {"rect": [0.38, 0.79, 0.24, 0.07], "anchor": "center", "mode": "flash",
				"color": "red", "on_frac": 0.07, "off_frac": 0.02, "kind": "death"},
			# image desaturee pendant l'observation apres la mort (experimental, coupe par defaut)
			"grey_view": {"rect": [0.30, 0.30, 0.40, 0.40], "anchor": "center", "mode": "grey",
				"on_sat": 18.0, "off_sat": 40.0, "kind": "death", "enabled": false},
		},
	},
	"fortnite": {
		"procs": ["fortniteclient-win64-shipping"],
		"regions": {
			# compteur d'eliminations (ligne de statistiques sous la mini-carte, en haut a droite)
			"elims": {"rect": [0.925, 0.265, 0.045, 0.035], "anchor": "right", "mode": "digits",
				"color": "white", "min_frac": 0.04},
			# texte « ÉLIMINÉ : pseudo » sous le reticule
			"elim_text": {"rect": [0.35, 0.585, 0.30, 0.05], "anchor": "center", "mode": "flash",
				"color": "white", "on_frac": 0.06, "off_frac": 0.015},
			# « ÉLIMINÉ PAR ... » / interface d'observation (« EN OBSERVATION ») en haut au centre
			"spectate_banner": {"rect": [0.40, 0.085, 0.20, 0.05], "anchor": "center", "mode": "flash",
				"color": "white", "on_frac": 0.08, "off_frac": 0.02, "kind": "death"},
		},
	},
}
const DEDUPE_SEC := 1.5  # deux zones qui voient la meme elimination -> un seul evenement
const PROBE := [0.47, 0.47, 0.06, 0.06]  # petite zone au centre : detecte image noire / figee
const GRID_X := 8
const GRID_Y := 4

var active := false
var game := ""  ## profil courant ("valorant", "fortnite", "" = aucun)
var interval := 0.33
var screen := -1
var overrides := {}  ## {game: {region: [x, y, w, h]}} (reglage "hud_regions")
var enabled_extra := {}  ## zones experimentales activees a la main : {"grey_view": true}

var capture_status := "idle"
var last_cost_usec := 0
var events := 0

var _t := 0.0
var _task := -1
var _result := {}
var _state := {}  # region -> etat
var _last := {}  # kind -> dernier instant emis
var _probe_hash := 0
var _probe_same_since := -1.0
var _black_n := 0


## Nom de profil pour un processus ("" si aucun).
static func profile_for(proc: String) -> String:
	for g in PROFILES:
		if proc.to_lower() in PROFILES[g]["procs"]:
			return g
	return ""


func set_game(g: String) -> void:
	if g == game:
		return
	game = g
	_state.clear()
	_last.clear()
	_probe_same_since = -1.0
	_black_n = 0
	if g == "":
		_set_status("idle")


func set_region(g: String, key: String, rect: Array) -> void:
	if not overrides.has(g):
		overrides[g] = {}
	overrides[g][key] = rect
	_state.erase(key)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _process(delta: float) -> void:
	if _task >= 0:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		ingest(_result, _now())
	if not active or game == "":
		return
	_t += delta
	if _t < interval:
		return
	_t = 0.0
	var s := _pick_screen()
	var jobs := screen_rects(game, Rect2i(DisplayServer.screen_get_position(s), DisplayServer.screen_get_size(s)))
	_task = WorkerThreadPool.add_task(_work.bind(jobs), false, "pompom hud")


## Rectangles ecran de chaque zone du profil (+ la sonde "_probe").
func screen_rects(g: String, scr: Rect2i) -> Dictionary:
	var out := {}
	var regs: Dictionary = PROFILES.get(g, {}).get("regions", {})
	for key in regs:
		if not bool(regs[key].get("enabled", true)) and not enabled_extra.has(key):
			continue
		var r: Array = overrides.get(g, {}).get(key, regs[key]["rect"])
		out[key] = rel_to_screen(r, str(regs[key].get("anchor", "center")), scr)
	out["_probe"] = rel_to_screen(PROBE, "center", scr)
	return out


## Conversion zone relative -> pixels ecran, avec la boite de reference 16:9.
static func rel_to_screen(r: Array, anchor: String, scr: Rect2i) -> Rect2i:
	var h := float(scr.size.y)
	var ref_w := minf(float(scr.size.x), h * 16.0 / 9.0)
	var ox := 0.0
	match anchor:
		"left":
			ox = 0.0
		"right":
			ox = scr.size.x - ref_w
		_:
			ox = (scr.size.x - ref_w) * 0.5
	return Rect2i(scr.position.x + int(ox + float(r[0]) * ref_w), scr.position.y + int(float(r[1]) * h),
		maxi(4, int(float(r[2]) * ref_w)), maxi(4, int(float(r[3]) * h)))


func _pick_screen() -> int:
	if screen >= 0 and screen < DisplayServer.get_screen_count():
		return screen
	var act := get_node_or_null("/root/Activity")
	if act and act.fg_hwnd != 0:
		for w in act.windows:
			if int(w.get("id", 0)) == int(act.fg_hwnd):
				var c: Vector2 = (w["rect"] as Rect2).get_center()
				for i in DisplayServer.get_screen_count():
					if Rect2(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i)).has_point(c):
						return i
	return DisplayServer.get_primary_screen()


func _work(jobs: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var imgs := {}
	for key in jobs:
		imgs[key] = DisplayServer.screen_get_image_rect(jobs[key])
	var r := analyze_all(game, imgs)
	r["cost_usec"] = Time.get_ticks_usec() - t0
	_result = r


## Analyse des captures (statique, testable) : {key: {frac, sig, blank}} + "_probe": {hash, blank}
static func analyze_all(g: String, imgs: Dictionary) -> Dictionary:
	var out := {}
	var regs: Dictionary = PROFILES.get(g, {}).get("regions", {})
	for key in imgs:
		var img: Image = imgs[key]
		if key == "_probe":
			out[key] = _probe_info(img)
		elif regs.has(key):
			out[key] = analyze_region(img, str(regs[key].get("color", "white")), 48 if regs[key]["mode"] == "digits" else 32)
	return out


static func _probe_info(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {"blank": true, "hash": 0}
	var d := img.get_data()
	var s := 0
	for i in range(0, d.size(), 7):
		s += d[i]
	return {"blank": s < d.size() / 7 * 4, "hash": hash(d)}


## Part de pixels de la couleur cible + empreinte (grille GRID_X x GRID_Y) de ces pixels.
static func analyze_region(src: Image, color: String, pts := 48) -> Dictionary:
	if src == null or src.is_empty():
		return {"blank": true, "frac": 0.0, "sig": 0}
	var img := src
	if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
		img = src.duplicate() as Image
		img.convert(Image.FORMAT_RGBA8)
	var bpp := 3 if img.get_format() == Image.FORMAT_RGB8 else 4
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, maxi(w / pts, h / (pts / 2)))  # au plus pts x pts/2 points par zone (48 compteurs, 32 bandeaux)
	var d := img.get_data()
	var cells := PackedInt32Array()
	cells.resize(GRID_X * GRID_Y)
	var tot := PackedInt32Array()
	tot.resize(GRID_X * GRID_Y)
	var hit := 0
	var n := 0
	var lum := 0
	var sat := 0
	for y in range(0, h, step):
		var gy := y * GRID_Y / h
		for x in range(0, w, step):
			var i := (y * w + x) * bpp
			var r := d[i]
			var gg := d[i + 1]
			var b := d[i + 2]
			lum += r + gg + b
			sat += maxi(r, maxi(gg, b)) - mini(r, mini(gg, b))
			n += 1
			var cell := gy * GRID_X + x * GRID_X / w
			tot[cell] += 1
			var ok := false
			match color:
				"white":
					ok = r >= 200 and gg >= 200 and b >= 200
				"red":
					ok = r >= 180 and gg < 90 and b < 90
				"yellow":
					ok = r >= 200 and gg >= 170 and b < 110
				"teal":
					ok = gg >= 170 and b >= 150 and r < 120
				_:
					ok = r + gg + b >= 600
			if ok:
				hit += 1
				cells[cell] += 1
	var sig := 0
	for c in cells.size():
		if tot[c] > 0 and float(cells[c]) / tot[c] >= 0.2:
			sig |= 1 << c
	return {"blank": lum < n * 9, "frac": float(hit) / maxi(1, n), "sig": sig, "sat": float(sat) / maxi(1, n)}


static func _bits(x: int) -> int:
	var b := 0
	while x != 0:
		x &= x - 1
		b += 1
	return b


## Integre un resultat (public pour les tests).
func ingest(r: Dictionary, now: float) -> void:
	last_cost_usec = int(r.get("cost_usec", 0))
	var probe: Dictionary = r.get("_probe", {})
	if not probe.is_empty():
		_update_status(probe, now)
	if capture_status == "black" or capture_status == "frozen":
		return
	var regs: Dictionary = PROFILES.get(game, {}).get("regions", {})
	for key in regs:
		if not r.has(key):
			continue
		var cfg: Dictionary = regs[key]
		var a: Dictionary = r[key]
		var st: Dictionary = _state.get(key, {})
		match str(cfg["mode"]):
			"flash":
				_flash(key, cfg, a, st, now)
			"grey":
				_grey(key, cfg, a, st, now)
			_:
				_digits(key, cfg, a, st, now)
		_state[key] = st


func _flash(key: String, cfg: Dictionary, a: Dictionary, st: Dictionary, now: float) -> void:
	var frac := float(a["frac"])
	var on := bool(st.get("on", false))
	if not st.has("armed"):
		st["armed"] = frac <= float(cfg["off_frac"])  # au demarrage, un bandeau deja affiche ne compte pas
	if not on:
		if frac <= float(cfg["off_frac"]):
			st["armed"] = true
		elif frac >= float(cfg["on_frac"]) and st["armed"]:
			st["on"] = true
			st["armed"] = false
			st["sig"] = int(a["sig"])
			st["sig_n"] = 0
			_fire(key, cfg, {"n": 1}, now)
		return
	if str(cfg.get("kind", "kill")) != "kill":
		if frac <= float(cfg["off_frac"]):
			st["on"] = false
			st["armed"] = true
		return  # un bandeau de mort reste affiche : un seul evenement
	# bandeau affiche : se ferme quand la couleur disparait ; une nouvelle empreinte stable = kill suivant
	if frac <= float(cfg["off_frac"]):
		st["on"] = false
		st["armed"] = true
		return
	var sig := int(a["sig"])
	if _bits(sig ^ int(st["sig"])) >= 3:
		if st.get("cand", -1) == sig:
			st["sig_n"] = int(st.get("sig_n", 0)) + 1
		else:
			st["cand"] = sig
			st["sig_n"] = 1
		if int(st["sig_n"]) >= 2:
			st["sig"] = sig
			st["sig_n"] = 0
			_fire(key, cfg, {"n": 1, "chain": true}, now, true)


func _digits(key: String, cfg: Dictionary, a: Dictionary, st: Dictionary, now: float) -> void:
	var visible := float(a["frac"]) >= float(cfg.get("min_frac", 0.04))
	if not visible:
		if not st.has("gone"):
			st["gone"] = now
		elif now - float(st["gone"]) > 6.0:
			st.erase("base")  # HUD absent longtemps (lobby, mort...) : nouvelle reference a son retour
		return
	st.erase("gone")
	var sig := int(a["sig"])
	if st.get("cand", -1) == sig:
		st["cand_n"] = int(st.get("cand_n", 0)) + 1
	else:
		st["cand"] = sig
		st["cand_n"] = 1
	if int(st["cand_n"]) < 2:
		return
	if not st.has("base"):
		st["base"] = sig
		return
	if _bits(sig ^ int(st["base"])) >= 2:
		st["base"] = sig
		_fire(key, cfg, {"n": 1}, now)


## Image qui perd ses couleurs (saturation moyenne < on_sat sur 2 captures) apres avoir ete coloree.
func _grey(key: String, cfg: Dictionary, a: Dictionary, st: Dictionary, now: float) -> void:
	var sat := float(a.get("sat", 100.0))
	if sat >= float(cfg["off_sat"]):
		st["armed"] = true
		st["on"] = false
		st["n"] = 0
		return
	if sat <= float(cfg["on_sat"]) and st.get("armed", false) and not st.get("on", false):
		st["n"] = int(st.get("n", 0)) + 1
		if int(st["n"]) >= 2:
			st["on"] = true
			st["armed"] = false
			_fire(key, cfg, {}, now)


func _fire(region: String, cfg: Dictionary, data: Dictionary, now: float, force := false) -> void:
	var kind := str(cfg.get("kind", "kill"))
	# dedoublonnage ENTRE zones (deux zones voient la meme elimination) ; une meme zone gere deja ses
	# repetitions (armement / empreinte), donc deux kills rapides au compteur restent deux kills
	var dedupe := DEDUPE_SEC if kind == "kill" else 6.0  # une mort = un seul evenement
	var prev: Array = _last.get(kind, [-100.0, ""])
	if not force and now - float(prev[0]) < dedupe and (kind != "kill" or prev[1] != region):
		return
	_last[kind] = [now, region]
	events += 1
	var d := data.duplicate()
	d["source"] = "screen"
	d["region"] = region
	hud_event.emit(game, kind, true, d)


func _update_status(p: Dictionary, now: float) -> void:
	if bool(p.get("blank", false)):
		_black_n += 1
		if _black_n >= 6:
			_set_status("black")
		return
	_black_n = 0
	var hsh := int(p.get("hash", 0))
	if hsh == _probe_hash:
		if _probe_same_since < 0.0:
			_probe_same_since = now
		elif now - _probe_same_since > 20.0:  # menu fige un moment : tolere
			_set_status("frozen")
			return
	else:
		_probe_hash = hsh
		_probe_same_since = -1.0
	_set_status("ok")


func _set_status(s: String) -> void:
	if s != capture_status:
		capture_status = s
		capture_status_changed.emit(s)


## Message pour l'interface quand la capture ne marche pas ("" sinon).
func status_hint() -> String:
	match capture_status:
		"black", "frozen":
			return "Je ne vois pas l'image du jeu : mets-le en « plein écran fenêtré » (fenêtre sans bordure) pour que je puisse fêter tes éliminations."
	return ""


## Debogage / calibration : enregistre les zones capturees en PNG dans `dir` (appel manuel seulement).
func dump_regions(dir := "user://hud_dump") -> PackedStringArray:
	var out := PackedStringArray()
	DirAccess.make_dir_recursive_absolute(dir)
	var s := _pick_screen()
	var jobs := screen_rects(game, Rect2i(DisplayServer.screen_get_position(s), DisplayServer.screen_get_size(s)))
	for key in jobs:
		var img := DisplayServer.screen_get_image_rect(jobs[key])
		if img:
			var p: String = "%s/%s_%s.png" % [dir, game, key]
			img.save_png(p)
			out.append(p)
	return out


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
