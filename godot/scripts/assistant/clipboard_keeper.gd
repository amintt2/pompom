class_name ClipboardKeeper
extends Node
## Petit assistant presse-papiers : quand tu copies quelque chose (texte, image, fichiers), le compagnon
## le garde sur sa tete. Clic = le remettre dans le presse-papiers, glisser hors de la fenetre = le "deposer"
## (copie + image enregistree dans Images/Pompom), clic droit ou petite croix = l'oublier.
## S'il le porte trop longtemps, il fatigue (2 min), peine (5 min), puis le pose a ses pieds (10 min).
##
## Vie privee : desactive par defaut (reglage "clipboard"), rien n'est jamais ecrit sur le disque
## (sauf l'image deposee volontairement hors de la fenetre), les textes qui ressemblent a des secrets
## sont ignores, ainsi que le contenu marque par les gestionnaires de mots de passe (helper Windows).
##
## ------------------------------------------------------------------------------------------ CABLAGE
## Dans scripts/desktop/desktop_controller.gd :
##
##   # 1) variable (avec les autres)
##   var clip: ClipboardKeeper
##
##   # 2) a la fin de setup(), apres _build_menus() :
##   clip = ClipboardKeeper.new()
##   clip.name = "Clipboard"
##   add_child(clip)
##   clip.setup(stage, emotes)  # cree le HeldItemsLayer juste sous les bulles (meme CanvasLayer)
##
##   # 3) dans _update_polygon(), juste apres le bloc "if emotes.is_busy(): ..." :
##   if clip:
##       var cb := clip.bounds()
##       if cb.size != Vector2.ZERO:
##           pts.append_array(PackedVector2Array([cb.position, Vector2(cb.end.x, cb.position.y), cb.end, Vector2(cb.position.x, cb.end.y)]))
##
##   # 4) tout en haut de _input(event) :
##   if clip and clip.handle_input(event):
##       _press = false
##       return
##
##   # 5) (conseille) dans _process_mouse_near(), pour ne pas compter le survol de la carte comme une caresse :
##   var hovering := ... and not (clip and clip.is_over(local))
##
##   # 6) eventail "main de cartes" (HeldFan, scripts/ui/held_fan.gd) : au survol de sa tete, les objets et
##   #    l'enveloppe du courrier s'ecartent en cartes ; clic sur la lettre = lire le courrier. Juste apres clip.setup() :
##   clip.attach_hud(hud)
##   clip.mail_requested.connect(_read_mail)
##   #    (sans ces 2 lignes : le GameHud frere des bulles est trouve tout seul et _read_mail() du parent est appele)
##   #    et dans _update_perf() : busy_ui ... or (clip != null and clip.fan_open())  (fluide pendant le survol)
##
## Dans scripts/ui/emote_layer.gd (conseille, 2 lignes) : bulles et emotions passent AU-DESSUS de la carte
## au lieu de la cacher. Le HeldItemsLayer remplit `bubble_lift` tout seul s'il existe.
##   var bubble_lift := 0.0  # px : hauteur de ce qu'il porte sur la tete (ClipboardKeeper)
##   func head_pos() -> Vector2:
##       ...
##       return stage.camera.unproject_position(stage.pet.head_top_global()) - Vector2(0, bubble_lift)
##
## Dans la boutique (shop_window.gd, groupe "g2" des reglages) :
##   _setting_row(g2, "Garder ce que je copie (presse-papiers)",
##       "Il garde sur sa tête ce que tu copies. Clic : recopier, glisser dehors : déposer. Rien n'est enregistré.",
##       _toggle_setting("clipboard"))
## (le keeper ecoute GameState.settings_changed : rien d'autre a faire ; desactiver efface l'historique)
##
## Le helper Windows (res://helper/clipboard_helper.ps1, deja couvert par le filtre d'export "helper/*.ps1")
## n'est lance que si le reglage est actif. Sans lui (autre OS, echec), repli : sondage a 3 Hz via DisplayServer,
## sans detection des gestionnaires de mots de passe et sans recopie d'images (Godot 4.7 n'a pas clipboard_set_image).
## ------------------------------------------------------------------------------------------

signal item_added(item: Dictionary)
signal item_copied(item: Dictionary)
signal item_removed(item: Dictionary)
signal item_put_down(item: Dictionary)
signal skipped(reason: String)
## Clic sur la carte "lettre" de l'eventail : le compagnon doit lire son courrier (DesktopController._read_mail).
signal mail_requested

const SETTING := "clipboard"
## Captures d'ecran (Outil Capture d'ecran, Win+Maj+S, Impr. ecran) : gardees meme si le gardien general
## est desactive (reglage "screenshots", actif par defaut). Seules les images de ces applis sont prises.
const SHOT_SETTING := "screenshots"
const SNIP_PROCS := ["snippingtool", "screenclippinghost", "screensketch", "snipandsketch", "shellexperiencehost"]
const MAX_ITEMS := 5
const POLL_INTERVAL := 0.33  # repli sans helper (3 Hz)
const IMAGE_POLL_INTERVAL := 2.5  # repli sans helper : relecture complete d'une image (couteux)
const HELPER_TIMEOUT := 10.0
const THUMB_PX := 192
const MAX_TEXT := 200000
const MAX_IMAGE_SIDE := 8192
const REDUCED_SIDE := 1600
const FULL_BUDGET := 128 * 1024 * 1024  # octets d'images pleine resolution gardees en memoire
const MAX_FILE_BYTES := 40 * 1024 * 1024
const IMAGE_EXT := ["png", "jpg", "jpeg", "webp", "bmp", "tga", "svg"]

const TIRED_1 := 120.0  # il commence a fatiguer
const TIRED_2 := 300.0  # il peine vraiment
const PUT_DOWN := 600.0  # il le pose a ses pieds

const LINES_NEW := ["Je le garde pour toi !", "Hop, je l'ai !", "C'est noté !", "Je m'en occupe !"]
const LINES_TIRED_1 := ["C'est lourd...", "Je peux le poser ?", "Ouf...", "Tu en as encore besoin ?", "Ça pèse, ce truc !"]
const LINES_TIRED_2 := ["Mes petits bras...", "Je fatigue...", "Je tiens bon !", "C'est vraiment lourd, tu sais...",
	"Je vais bientôt le poser..."]
const LINES_PUT_DOWN := ["Je le pose là, d'accord ?", "Pause ! Je le range à mes pieds.", "Je le garde à côté de moi."]
const LINES_TAKEN := ["Voilà ! Fais Ctrl+V où tu veux.", "Tiens ! Colle-le avec Ctrl+V."]
const LINES_FORGET := ["D'accord, j'oublie !", "Pouf, envolé !"]

var stage: PetStage
var pet: Pet
var layer: HeldItemsLayer
var fan: HeldFan  # eventail au survol de sa tete (fenetre a part)
var hud: GameHud  # enveloppe du courrier (mail_count)

var enabled := false
var shots_only := false  # seul le mode "captures d'ecran" est actif
var time_scale := 1.0  # tests : accelere la fatigue
var ignore_own_focus := true  # ignore ce qui est copie pendant qu'une fenetre du jeu a le focus
var accept_own_copies := false  # tests : accepte ce que le jeu met lui-meme dans le presse-papiers
var use_helper := true  # Windows : helper qui surveille le numero de sequence + les formats "secrets"
var talk := true
var last_skip_reason := ""
var save_dir := ""  # dossier des images deposees ("" = Images/Pompom)
# tests : souris simulee (ignore l'etat reel du bouton) et "hors fenetre" force
var sim_mouse := false
var sim_outside := false
var dry_run := false  # tests : ne touche jamais au vrai presse-papiers (retours et signaux quand meme)

## Objets, du plus recent au plus ancien :
## {id, kind: text|image|file, text, title, image: Image, thumb: ImageTexture, files: PackedStringArray,
##  hash, place: head|feet, hold: secondes portees, reduced: bool, time: date de la copie (unix)}
var items: Array[Dictionary] = []

var _next_id := 1
var _mode := "off"  # off | starting | helper | poll
var _poll_t := 0.0
var _img_poll_t := 0.0
var _last_text_hash := ""
var _last_img_sig := ""
var _had_img := false
var _self_hash := ""  # dernier texte que nous avons nous-memes remis (ignore une fois)
var _self_img_until := 0  # ms : ignore l'image que nous venons de remettre

# helper Windows
var _pipe: FileAccess
var _pid := -1
var _thread: Thread
var _mutex := Mutex.new()
var _lines := PackedStringArray()
var _running := false
var _helper_t := 0.0

# fatigue / reactions
var _react_cd := 0.0
var _talk_cd := 0.0
var _tired_cd := 20.0
var _sag_tween: Tween

# souris
var _press := {}
var _press_pos := Vector2.ZERO
var _dragging := false


# =========================================================================== mise en place
func setup(p_stage: PetStage, p_emotes: Control = null, ui_parent: Node = null) -> void:
	stage = p_stage
	pet = stage.pet
	layer = HeldItemsLayer.new()
	layer.name = "HeldItems"
	layer.stage = stage
	layer.keeper = self
	layer.emotes = p_emotes
	var parent: Node = ui_parent
	if parent == null and p_emotes:
		parent = p_emotes.get_parent()
	if parent == null:
		var cl := CanvasLayer.new()
		cl.layer = 4
		add_child(cl)
		parent = cl
	parent.add_child(layer)
	if p_emotes and p_emotes.get_parent() == parent:
		parent.move_child(layer, p_emotes.get_index())  # sous les bulles de dialogue
	# eventail "main de cartes" (fenetre a part, transitoire de la notre)
	fan = HeldFan.new()
	fan.name = "HeldFan"
	fan.keeper = self
	fan.layer = layer
	fan.main_win = get_window()
	fan.card_activated.connect(_on_fan_card)
	fan.card_removed.connect(func(e: Dictionary):
		if not (e["item"] as Dictionary).is_empty():
			forget(e["item"]))
	fan.card_dropped_out.connect(func(e: Dictionary):
		if not (e["item"] as Dictionary).is_empty():
			drop_outside(e["item"]))
	add_child(fan)
	if hud == null:
		for c in parent.get_children():
			if c is GameHud:
				attach_hud(c)
				break
	if not GameState.settings_changed.is_connected(_sync_setting):
		GameState.settings_changed.connect(_sync_setting)
	_sync_setting()


## Enveloppe du courrier (GameHud.mail_count) : montree comme une carte "lettre" dans l'eventail.
func attach_hud(h: GameHud) -> void:
	hud = h
	if fan:
		fan.hud = h


## L'eventail est-il ouvert (cartes ecartees au-dessus de sa tete) ?
func fan_open() -> bool:
	return fan != null and fan.is_shown()


func _on_fan_card(e: Dictionary) -> void:
	match str(e["kind"]):
		"mail":
			if fan:
				fan.close(true)
			if not mail_requested.get_connections().is_empty():
				mail_requested.emit()
			elif get_parent() and get_parent().has_method("_read_mail"):
				get_parent().call("_read_mail")  # DesktopController sans le cablage 6)
			else:
				mail_requested.emit()
		_:
			if items.has(e["item"]):
				copy_item(e["item"])


func _pill(text: String, color: Color, it: Dictionary) -> void:
	if fan and fan.is_open():
		fan.pill(text, color, it)
	elif layer:
		layer.pill(text, color, it)


func _sync_setting() -> void:
	talk = bool(GameState.settings.get("talk", true))
	var all_clip := bool(GameState.settings.get(SETTING, false))
	var shots := bool(GameState.settings.get(SHOT_SETTING, true))
	var want := all_clip or shots
	var only := shots and not all_clip
	if only != shots_only and enabled and want:
		shots_only = only
		if only:
			# on passe en mode "captures seulement" : on oublie le reste (vie privee)
			items = items.filter(func(it): return it.get("shot", false))
			if layer:
				layer.reset()
		return
	shots_only = only
	if want == enabled:
		return
	if want:
		start()
	else:
		stop()


## Active la surveillance (appele par le reglage ; utilisable directement en test).
func start() -> void:
	enabled = true
	_baseline()
	if use_helper and OS.get_name() == "Windows" and _start_helper():
		_mode = "starting"
		_helper_t = 0.0
	else:
		_mode = "poll"


## Arrete tout et oublie l'historique (vie privee).
func stop() -> void:
	enabled = false
	_mode = "off"
	_stop_helper()
	items.clear()
	_cancel_press()
	if layer:
		layer.reset()
	if fan and not (hud and hud.mail_count > 0):
		fan.close_now()


func _exit_tree() -> void:
	_stop_helper()


## Rectangle (pixels de la fenetre) a inclure dans la zone cliquable.
func bounds() -> Rect2:
	return layer.bounds() if layer and enabled else Rect2()


func is_over(local_pos: Vector2) -> bool:
	if fan and fan.contains_global(local_pos + Vector2(get_window().position)):
		return true
	return enabled and layer != null and not layer.hit_test(local_pos).is_empty()


func is_dragging() -> bool:
	return _dragging


func head_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in items:
		if it["place"] == "head":
			out.append(it)
	return out


func feet_items() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in items:
		if it["place"] == "feet":
			out.append(it)
	return out


func top_item() -> Dictionary:
	for it in items:
		if it["place"] == "head":
			return it
	return {}


## 0 = frais, 1 = fatigue, 2 = epuise.
func tired_level() -> int:
	var top := top_item()
	if top.is_empty():
		return 0
	var h: float = top["hold"]
	return 2 if h >= TIRED_2 else (1 if h >= TIRED_1 else 0)


## 0..1, pour l'animation de la carte.
func fatigue() -> float:
	var top := top_item()
	if top.is_empty():
		return 0.0
	return clampf((float(top["hold"]) - TIRED_1 * 0.5) / (PUT_DOWN - TIRED_1 * 0.5), 0.0, 1.0)


# =========================================================================== boucle
func _process(delta: float) -> void:
	if not enabled:
		return
	_drain_helper()
	match _mode:
		"starting":
			_helper_t += delta
			if _helper_t > HELPER_TIMEOUT or not _running:
				_stop_helper()
				_mode = "poll"
		"helper":
			if not _running:  # le helper s'est arrete : repli
				_stop_helper()
				_baseline()
				_mode = "poll"
		"poll":
			_poll_t -= delta
			if _poll_t <= 0.0:
				_poll_t = POLL_INTERVAL
				_poll_fallback()
	if not sim_mouse and not _press.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and _dragging:
		_release(_local_mouse())  # relachement perdu (hors fenetre)
	tick(delta * time_scale)


## Fatigue et petites reactions. Appele chaque image (delta deja multiplie par time_scale).
func tick(delta: float) -> void:
	_react_cd -= delta
	_talk_cd -= delta
	_tired_cd -= delta
	if _sag_tween and _sag_tween.is_valid() and pet and pet.busy:
		_sag_tween.kill()  # une vraie action commence : on ne se bat pas avec elle
	var head := head_items()
	if head.is_empty() or pet == null:
		return
	var top: Dictionary = head[0]
	var rate := minf(2.0, 1.0 + 0.25 * (head.size() - 1))  # la pile pese plus lourd
	if pet.sleeping:
		rate = 0.0  # il se repose
	if _dragging and is_same(_press.get("item"), top):
		rate = 0.0
	top["hold"] = float(top["hold"]) + delta * rate
	var h: float = top["hold"]
	if h >= PUT_DOWN and (_can_act() or h >= PUT_DOWN + 90.0):
		put_down(head, "tired")
		return
	if h >= TIRED_1 and _tired_cd <= 0.0 and _can_act():
		var lvl := tired_level()
		_tired_cd = randf_range(14.0, 22.0) if lvl >= 2 else randf_range(26.0, 40.0)
		_sigh(lvl)


func _can_act() -> bool:
	return pet != null and pet.root_node != null and not pet.busy and not pet.sleeping and not pet.carried and not _dragging


# =========================================================================== detection
func _baseline() -> void:
	_last_text_hash = ""
	_last_img_sig = ""
	_had_img = false
	if OS.get_name() != "Windows" and not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		return
	var t := DisplayServer.clipboard_get()
	_last_text_hash = t.md5_text() if t != "" else ""
	_had_img = DisplayServer.clipboard_has_image()


## Repli sans helper : texte a 3 Hz (hash), image seulement quand elle apparait ou toutes les 2,5 s.
func _poll_fallback() -> void:
	_img_poll_t -= POLL_INTERVAL
	var t := DisplayServer.clipboard_get()
	var th := t.md5_text() if t != "" else ""
	var text_changed := th != _last_text_hash
	_last_text_hash = th
	var has_img := DisplayServer.clipboard_has_image()
	var img_new := false
	var img: Image
	if has_img and (not _had_img or text_changed or _img_poll_t <= 0.0):
		_img_poll_t = IMAGE_POLL_INTERVAL
		img = DisplayServer.clipboard_get_image()
		if img and not img.is_empty():
			var sig := _image_sig(img)
			img_new = sig != _last_img_sig
			_last_img_sig = sig
	_had_img = has_img
	if not text_changed and not img_new:
		return
	if th != "" and th == _self_hash and not img_new:
		_self_hash = ""
		return
	if _own_window_focused():
		_skip("focus")
		return
	if img_new and (t.strip_edges() == "" or _text_is_image_ref(t)):
		var it2 := ingest_image(img)
		if shots_only and not it2.is_empty():
			it2["shot"] = true
	elif text_changed and t != "" and not shots_only:
		ingest_text(t)


func _on_clip_event(d: Dictionary) -> void:
	if bool(d.get("init", false)):
		if int(d.get("seq", 0)) == 0:
			# pas d'acces au numero de sequence (session restreinte) : repli
			_stop_helper()
			_mode = "poll"
		return
	if bool(d.get("sens", false)):
		_skip("password_manager")
		return
	if bool(d.get("own", false)) and not accept_own_copies:
		return
	var from_snip := SNIP_PROCS.has(str(d.get("proc", "")).to_lower())
	if shots_only and not (from_snip and bool(d.get("img", false))):
		return  # mode captures : on ignore tout le reste
	if from_snip and bool(d.get("img", false)):
		var simg := DisplayServer.clipboard_get_image()
		if simg and not simg.is_empty():
			_last_img_sig = _image_sig(simg)
			var it := ingest_image(simg)
			if not it.is_empty():
				it["shot"] = true
				if talk and pet:
					pet.say("Je garde ta capture ! Clique-moi pour la recopier.")
			return
	if bool(d.get("own", false)) and Time.get_ticks_msec() < _self_img_until:
		return  # l'image (et son fichier) que nous venons nous-memes de remettre
	if _own_window_focused():
		_skip("focus")
		return
	var files: Array = d.get("files", [])
	if not files.is_empty():
		if int(d.get("nfiles", files.size())) > files.size():
			pass  # au-dela de 5 fichiers : on garde les 5 premiers (affiches "N fichiers")
		ingest_files(PackedStringArray(files), int(d.get("nfiles", files.size())))
		return
	var t := DisplayServer.clipboard_get() if bool(d.get("txt", false)) else ""
	if bool(d.get("img", false)) and (t.strip_edges() == "" or _text_is_image_ref(t)):
		if Time.get_ticks_msec() < _self_img_until:
			return
		var img := DisplayServer.clipboard_get_image()
		if img and not img.is_empty():
			_last_img_sig = _image_sig(img)
			ingest_image(img)
			return
		if t.strip_edges() == "":
			_retry_event(d)
			return
	if t != "":
		_last_text_hash = t.md5_text()
		if _last_text_hash == _self_hash:
			_self_hash = ""
			return
		ingest_text(t)
	elif bool(d.get("txt", false)):
		_retry_event(d)


## Le presse-papiers etait occupe (historique Windows...) : on relit un peu plus tard.
func _retry_event(d: Dictionary) -> void:
	var n := int(d.get("retry", 0))
	if n >= 4:
		return
	var d2 := d.duplicate()
	d2["retry"] = n + 1
	await get_tree().create_timer(0.12).timeout
	if enabled:
		_on_clip_event(d2)


func _own_window_focused() -> bool:
	if not ignore_own_focus:
		return false
	for id in DisplayServer.get_window_list():
		if DisplayServer.window_is_focused(id):
			return true
	return false


func _skip(reason: String) -> void:
	last_skip_reason = reason
	skipped.emit(reason)


## Le texte n'est qu'une reference vers l'image (copie d'image depuis un navigateur) ?
static func _text_is_image_ref(t: String) -> bool:
	var s := t.strip_edges()
	if s.contains("\n") or s.length() > 2048:
		return false
	return s.begins_with("http") or s.begins_with("<img") or s.begins_with("data:image") or s.get_extension().to_lower() in IMAGE_EXT


static func _image_sig(img: Image) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(img.get_data())
	return "%dx%d:%s" % [img.get_width(), img.get_height(), ctx.finish().hex_encode()]


# =========================================================================== secrets
## Prudent : mieux vaut ignorer un texte normal que garder un mot de passe.
static func looks_secret(text: String) -> bool:
	var s := text.strip_edges()
	if s == "":
		return false
	var low := s.to_lower()
	for k in ["password", "passwd", "mot de passe", "motdepasse", "mdp:", "mdp =", "mdp=", "pwd=", "pwd:", "passphrase",
			"secret", "api_key", "apikey", "api-key", "token", "bearer ", "private key", "-----begin", "client_secret",
			"access_key", "auth=", "authorization:"]:
		if low.contains(k):
			return true
	for p in ["sk-", "sk_live", "pk_live", "rk_live", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xox", "akia",
			"asia", "aiza", "eyj", "hf_", "npm_", "shpat_", "ya29."]:
		if low.begins_with(p) and not s.contains(" "):
			return true
	var digits := s.replace(" ", "").replace("-", "")
	if digits.length() >= 12 and digits.length() <= 19 and RegEx.create_from_string("^[0-9]+$").search(digits) and _luhn(digits):
		return true  # numero de carte
	var compact := s.replace(" ", "")
	var iban := RegEx.create_from_string("^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$")
	if compact.length() <= 34 and iban.search(compact) and RegEx.create_from_string("[0-9]").search_all(compact).size() >= 8:
		return true  # IBAN
	if s.contains(" ") or s.contains("\n") or s.contains("\t"):
		return false
	# un seul "mot" : URL, chemin, e-mail -> normal
	if low.begins_with("http://") or low.begins_with("https://") or low.begins_with("www.") or s.contains("/") \
			or s.contains("\\") or RegEx.create_from_string("^[^@\\s]+@[^@\\s]+\\.[A-Za-z]{2,}$").search(s) != null:
		return false
	var n := s.length()
	if n < 8 or n > 256:
		return false
	var lower := false
	var upper := false
	var digit := false
	var symbol := false
	for c in s:
		if c >= "a" and c <= "z":
			lower = true
		elif c >= "A" and c <= "Z":
			upper = true
		elif c >= "0" and c <= "9":
			digit = true
		else:
			symbol = true
	var classes := int(lower) + int(upper) + int(digit) + int(symbol)
	var ent := _entropy(s)
	# mot de passe court : melange de lettres, chiffres et symboles
	if n <= 40 and classes >= 3 and (digit or symbol):
		return true
	# jeton long et aleatoire (hex, base64...)
	if n >= 20 and classes >= 2 and ent >= 3.3:
		return true
	if n >= 32 and ent >= 3.0 and RegEx.create_from_string("^[A-Za-z0-9+/=_\\-.]+$").search(s) != null and digit:
		return true
	return false


static func _entropy(s: String) -> float:
	var counts := {}
	for c in s:
		counts[c] = int(counts.get(c, 0)) + 1
	var e := 0.0
	var n := float(s.length())
	for k in counts:
		var p := float(counts[k]) / n
		e -= p * log(p) / log(2.0)
	return e


static func _luhn(d: String) -> bool:
	var sum := 0
	var alt := false
	for i in range(d.length() - 1, -1, -1):
		var v := int(d[i])
		if alt:
			v *= 2
			if v > 9:
				v -= 9
		sum += v
		alt = not alt
	return sum % 10 == 0


# =========================================================================== ajout d'objets
## Ajoute un texte (retourne l'objet, ou {} s'il est ignore).
func ingest_text(text: String) -> Dictionary:
	if text.strip_edges() == "":
		return {}
	if text.length() > MAX_TEXT:
		_skip("too_long")
		return {}
	if looks_secret(text):
		_skip("secret")
		return {}
	var h := "t:" + text.md5_text()
	var it := {"kind": "text", "text": text, "title": _first_words(text), "hash": h}
	return _add(it)


func ingest_image(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	var full := img.duplicate() as Image
	if full.is_compressed():
		full.decompress()
	if full.get_format() != Image.FORMAT_RGBA8:
		full.convert(Image.FORMAT_RGBA8)
	var reduced := false
	var m := maxi(full.get_width(), full.get_height())
	if m > MAX_IMAGE_SIDE:
		var k := float(MAX_IMAGE_SIDE) / m
		full.resize(maxi(1, int(full.get_width() * k)), maxi(1, int(full.get_height() * k)), Image.INTERPOLATE_BILINEAR)
		reduced = true
	var h := "i:" + _image_sig(full)
	var it := {"kind": "image", "image": full, "thumb": make_thumb(full), "title": "%d × %d" % [img.get_width(), img.get_height()],
		"hash": h, "reduced": reduced, "text": ""}
	return _add(it)


## Fichiers copies dans l'Explorateur : une seule image -> carte image ; sinon carte "fichier".
func ingest_files(paths: PackedStringArray, total := -1) -> Dictionary:
	if paths.is_empty():
		return {}
	if total < 0:
		total = paths.size()
	if total == 1 and paths[0].get_extension().to_lower() in IMAGE_EXT and FileAccess.file_exists(paths[0]):
		var f := FileAccess.open(paths[0], FileAccess.READ)
		if f and f.get_length() <= MAX_FILE_BYTES:
			f.close()
			var img := Image.load_from_file(paths[0])
			if img and not img.is_empty():
				var it := ingest_image(img)
				if not it.is_empty():
					it["files"] = paths
					it["title"] = paths[0].get_file()
				return it
	var title := paths[0].get_file() if total == 1 else "%d fichiers" % total
	if title == "":
		title = paths[0]
	var it2 := {"kind": "file", "files": paths, "text": "\n".join(paths), "title": title,
		"hash": "f:" + "\n".join(paths).md5_text(), "count": total}
	return _add(it2)


func _add(it: Dictionary) -> Dictionary:
	# deja garde ? on le remet sur le dessus
	for i in items.size():
		if items[i]["hash"] == it["hash"]:
			var old: Dictionary = items[i]
			items.remove_at(i)
			old["place"] = "head"
			old["hold"] = 0.0
			old["time"] = Time.get_unix_time_from_system()
			items.push_front(old)
			if layer:
				layer.on_item_added(old)
			_react_new()
			item_added.emit(old)
			return old
	it["id"] = _next_id
	_next_id += 1
	it["place"] = "head"
	it["hold"] = 0.0
	it["time"] = Time.get_unix_time_from_system()
	if not it.has("files"):
		it["files"] = PackedStringArray()
	items.push_front(it)
	while items.size() > MAX_ITEMS:
		var gone: Dictionary = items.pop_back()
		item_removed.emit(gone)
	_enforce_budget()
	if layer:
		layer.on_item_added(it)
	_react_new()
	item_added.emit(it)
	return it


## Plafonne la memoire : les images les plus anciennes sont reduites a 1600 px.
func _enforce_budget() -> void:
	var total := 0
	for it in items:
		if it["kind"] == "image":
			total += (it["image"] as Image).get_data_size()
	for i in range(items.size() - 1, 0, -1):
		if total <= FULL_BUDGET:
			return
		var it: Dictionary = items[i]
		if it["kind"] != "image":
			continue
		var img: Image = it["image"]
		var m := maxi(img.get_width(), img.get_height())
		if m <= REDUCED_SIDE:
			continue
		var before := img.get_data_size()
		var k := float(REDUCED_SIDE) / m
		var small := img.duplicate() as Image
		small.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_BILINEAR)
		it["image"] = small
		it["reduced"] = true
		total += small.get_data_size() - before


static func _first_words(text: String, max_chars := 70) -> String:
	var s := text.strip_edges()
	var ws := RegEx.create_from_string("\\s+")
	s = ws.sub(s, " ", true)
	if s.length() > max_chars:
		s = s.substr(0, max_chars)
		var cut := s.rfind(" ")
		if cut > max_chars * 0.6:
			s = s.substr(0, cut)
		s += "…"
	return s


## Miniature (192 px max) avec coins arrondis anti-crenneles.
static func make_thumb(full: Image) -> ImageTexture:
	var t := full.duplicate() as Image
	var w := t.get_width()
	var h := t.get_height()
	var m := maxi(w, h)
	if m > THUMB_PX:
		var k := float(THUMB_PX) / m
		w = maxi(1, int(round(w * k)))
		h = maxi(1, int(round(h * k)))
		t.resize(w, h, Image.INTERPOLATE_LANCZOS)
	elif m < 64:
		var k2 := 64.0 / m
		w = maxi(1, int(round(w * k2)))
		h = maxi(1, int(round(h * k2)))
		t.resize(w, h, Image.INTERPOLATE_NEAREST)  # petits pixels nets (icones)
	var r := maxf(2.0, minf(w, h) * 0.085)
	var ri := int(ceil(r))
	for cy in [0, 1]:
		for cx in [0, 1]:
			for yy in ri:
				for xx in ri:
					var px := xx if cx == 0 else w - 1 - xx
					var py := yy if cy == 0 else h - 1 - yy
					if px < 0 or py < 0 or px >= w or py >= h:
						continue
					var d := Vector2(xx + 0.5, yy + 0.5).distance_to(Vector2(r, r))
					var cov := clampf(r - d + 0.5, 0.0, 1.0) if (xx < r and yy < r) else 1.0
					if cov < 1.0:
						var c := t.get_pixel(px, py)
						c.a *= cov
						t.set_pixel(px, py, c)
	t.generate_mipmaps()
	return ImageTexture.create_from_image(t)


# =========================================================================== actions
## Remet l'objet dans le presse-papiers. Retourne false si impossible (image sans helper).
func copy_item(it: Dictionary, feedback := true) -> bool:
	if it.is_empty():
		return false
	var ok := true
	match "dry" if dry_run else str(it["kind"]):
		"dry":
			pass
		"text":
			_self_hash = (it["text"] as String).md5_text()
			_last_text_hash = _self_hash
			if _running:
				_write_cmd("txt " + Marshalls.utf8_to_base64(it["text"]))  # reessaie si le presse-papiers est occupe
			else:
				_set_text(it["text"])
		"image":
			ok = _send_image(it["image"], "")
		"file":
			if _running:
				_write_cmd("files " + Marshalls.utf8_to_base64("\n".join(it["files"])))
			else:
				_self_hash = (it["text"] as String).md5_text()
				_last_text_hash = _self_hash
				_set_text(it["text"])  # repli : les chemins en texte
	if feedback:
		if ok:
			_pill("Copié !", UITheme.MINT, it)
		else:
			_pill("Je ne peux pas copier d'image ici...", UITheme.PEACH, it)
	if ok:
		item_copied.emit(it)
		if pet and pet.root_node and not pet.carried:
			pet.set_expression("happy", 1.6)
			pet.emote.emit("sparkle", 2)
		GameState.change_happiness(0.5)
	return ok


## Le presse-papiers peut etre occupe un instant (historique Windows, autre appli) : on reessaie.
func _set_text(text: String) -> void:
	for i in 6:
		DisplayServer.clipboard_set(text)
		if DisplayServer.clipboard_get() == text:
			return
		await get_tree().create_timer(0.06).timeout


## Oublie l'objet (clic droit / petite croix).
func forget(it: Dictionary) -> void:
	var i := items.find(it)
	if i < 0:
		return
	items.remove_at(i)
	if fan and fan.is_open():
		fan.poof(it)
	elif layer:
		layer.play_forget(it)
	if talk and _talk_cd <= 0.0 and randf() < 0.35 and pet:
		_talk_cd = 20.0
		pet.say(LINES_FORGET.pick_random())
	item_removed.emit(it)


## Pose les objets a ses pieds (fatigue, ou glisse sur le tas).
func put_down(list: Array, reason := "manual") -> void:
	if list.is_empty():
		return
	for it in list:
		it["place"] = "feet"
		it["hold"] = 0.0
	# ordre : objets sur la tete, puis le tas (ceux qu'on vient de poser au-dessus)
	var head: Array[Dictionary] = []
	var feet: Array[Dictionary] = []
	for it in items:
		if it["place"] == "head":
			head.append(it)
		elif not list.has(it):
			feet.append(it)
	items.clear()
	items.append_array(head)
	for it in list:
		items.append(it)
	items.append_array(feet)
	if layer:
		layer.play_put_down(list)
	_tired_cd = 30.0
	for it in list:
		item_put_down.emit(it)
	if reason == "tired" and pet:
		if talk:
			pet.say(LINES_PUT_DOWN.pick_random())
		pet.set_expression("happy", 2.5)
		await get_tree().create_timer(1.0).timeout
		if is_instance_valid(pet) and _can_act():
			pet.act_stretch()


## Reprend un objet du tas sur sa tete (et le recopie).
func pick_up(it: Dictionary, copy := true) -> void:
	var i := items.find(it)
	if i < 0:
		return
	items.remove_at(i)
	it["place"] = "head"
	it["hold"] = 0.0
	items.push_front(it)
	if layer:
		layer.play_pick_up(it)
	if copy:
		copy_item(it)
	elif pet and _can_act():
		pet.act_hop(1, 0.06)


## Passe a l'objet suivant de la pile sur sa tete (clic sur le badge "+N").
func cycle() -> void:
	var head := head_items()
	if head.size() < 2:
		return
	var top: Dictionary = head[0]
	var nxt: Dictionary = head[1]
	nxt["hold"] = maxf(float(nxt["hold"]), float(top["hold"]))
	top["hold"] = 0.0
	items.erase(top)
	var last_head := items.find(head[head.size() - 1])
	items.insert(last_head + 1, top)
	if layer:
		layer.on_item_added(nxt)


## L'utilisateur a glisse la carte hors de la fenetre : copie + image enregistree dans Images/Pompom.
func drop_outside(it: Dictionary) -> void:
	if it.is_empty():
		return
	if it["kind"] == "image" and not dry_run:
		_save_and_copy_image(it["image"])
		item_copied.emit(it)
	else:
		var ok := copy_item(it, false)
		_pill("Copié ! Ctrl+V pour coller" if ok else "Oups, pas pu copier...", UITheme.MINT if ok else UITheme.PEACH, {})
	if it["place"] == "head":
		put_down([it], "taken")
	if pet and pet.root_node:
		pet.set_expression("happy", 2.0)
		pet.emote.emit("heart", 1)
		if talk and _talk_cd <= 0.0 and randf() < 0.5:
			_talk_cd = 15.0
			pet.say(LINES_TAKEN.pick_random())
	GameState.change_happiness(0.5)


## Enregistre l'image dans Images/Pompom (fil secondaire) puis la met dans le presse-papiers
## (bitmap + PNG + le fichier lui-meme : Ctrl+V marche dans une discussion comme dans l'Explorateur).
func _save_and_copy_image(img: Image) -> void:
	var path := _pictures_path()
	var data := {}
	var work := func() -> void:
		var png := img.save_png_to_buffer()
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(png)
			f.close()
			data["saved"] = true
		data["b64"] = Marshalls.raw_to_base64(png)
	await _run_bg(work)
	var saved := bool(data.get("saved", false))
	if _running:
		_self_img_until = Time.get_ticks_msec() + 5000
		_write_cmd("img " + str(data["b64"]) + (" " + Marshalls.utf8_to_base64(path) if saved else ""))
	if saved:
		_pill("Copié et rangé dans Images/Pompom !" if _running else "Rangé dans Images/Pompom !", UITheme.MINT, {})
	elif _running:
		_pill("Copié ! Ctrl+V pour coller", UITheme.MINT, {})
	else:
		_pill("Oups, pas pu l'enregistrer...", UITheme.PEACH, {})


func _pictures_path() -> String:
	var dir := ProjectSettings.globalize_path(save_dir) if save_dir != "" else ""
	if dir == "":
		dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
		if dir == "":
			dir = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
		dir = dir.path_join("Pompom")
	DirAccess.make_dir_recursive_absolute(dir)
	var d := Time.get_datetime_dict_from_system()
	var base := "pompom_%04d-%02d-%02d_%02d-%02d-%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]
	var path := dir.path_join(base + ".png")
	var n := 2
	while FileAccess.file_exists(path):
		path = dir.path_join("%s_%d.png" % [base, n])
		n += 1
	return path


## Travail lourd (encodage PNG) hors du fil principal ; a attendre avec await.
func _run_bg(work: Callable) -> void:
	var id := WorkerThreadPool.add_task(work, false, "pompom clipboard")
	while not WorkerThreadPool.is_task_completed(id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(id)


func _send_image(img: Image, path: String) -> bool:
	if not _running:
		return false
	_send_image_async(img, path)
	return true


func _send_image_async(img: Image, path: String) -> void:
	var data := {}
	var work := func() -> void:
		data["b64"] = Marshalls.raw_to_base64(img.save_png_to_buffer())
	await _run_bg(work)
	if _running:
		_self_img_until = Time.get_ticks_msec() + 5000
		_write_cmd("img " + str(data["b64"]) + (" " + Marshalls.utf8_to_base64(path) if path != "" else ""))


# =========================================================================== reactions du compagnon
func _react_new() -> void:
	if pet == null or pet.root_node == null or _react_cd > 0.0:
		return
	_react_cd = 4.0
	if pet.sleeping or pet.busy or pet.carried:
		return
	pet.emote.emit("sparkle", 1)
	if randf() < 0.45:
		pet.act_hop(1, 0.07)
	if talk and _talk_cd <= 0.0 and randf() < 0.25:
		_talk_cd = 60.0
		pet.say(LINES_NEW.pick_random())


func _sigh(lvl: int) -> void:
	if layer:
		layer.strain(lvl)
	var say_p := 0.6 if lvl >= 2 else 0.35
	if talk and _talk_cd <= 0.0 and randf() < say_p:
		_talk_cd = 30.0 if lvl >= 2 else 45.0
		pet.say((LINES_TIRED_2 if lvl >= 2 else LINES_TIRED_1).pick_random())
	if lvl >= 2:
		if randf() < 0.5:
			pet.act_sad()  # sueur + il s'affaisse + yeux tristes
		else:
			pet.set_expression("sad", 2.6)
			pet.emote.emit("sweat", 2)
			_sag(0.13, 0.05, 2.0, 0.012)
	else:
		if randf() < 0.5:
			pet.act_meh()
			pet.emote.emit("sweat", 1)
		else:
			pet.set_expression("meh", 2.4)
			pet.emote.emit("sweat", 1)
			_sag(0.07, 0.03, 1.4, 0.0)


## Petit affaissement (squash / lean / tremblement) sans passer par une action du compagnon.
func _sag(amount: float, lean: float, hold: float, tremble: float) -> void:
	if _sag_tween and _sag_tween.is_valid():
		_sag_tween.kill()
	var side := -1.0 if randf() < 0.5 else 1.0
	_sag_tween = create_tween().set_parallel(true)
	_sag_tween.tween_property(pet, "squash", -amount, 0.5).set_trans(Tween.TRANS_SINE)
	_sag_tween.tween_property(pet, "lean", lean * side, 0.6).set_trans(Tween.TRANS_SINE)
	if tremble > 0.0:
		_sag_tween.tween_property(pet, "shake", tremble, 0.3)
	_sag_tween.chain().tween_interval(hold)
	_sag_tween.chain().tween_property(pet, "squash", 0.0, 0.6).set_trans(Tween.TRANS_SINE)
	_sag_tween.tween_property(pet, "lean", 0.0, 0.6).set_trans(Tween.TRANS_SINE)
	_sag_tween.tween_property(pet, "shake", 0.0, 0.3)


# =========================================================================== souris
## A appeler en premier dans DesktopController._input. Retourne true si l'evenement est consomme.
func handle_input(event: InputEvent) -> bool:
	if not enabled or layer == null:
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var hit := layer.hit_test(mb.position)
				if hit.is_empty():
					return false
				_press = hit
				_press_pos = mb.position
				_dragging = false
				return true
			if _press.is_empty():
				return false
			_release(mb.position)
			return true
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if not _press.is_empty():
				return true
			return handle_right_click(mb.position)
		return false
	if event is InputEventMouseMotion and not _press.is_empty():
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_press_pos) > 6.0 * _s() and _press["zone"] in ["card", "pile"]:
			_dragging = true
			layer.begin_drag(_press["item"], _press_pos)
		if _dragging:
			layer.drag_to(mm.position, _outside_window())
		return true
	return false


## Clic gauche (sans glisser) a cette position : true si un objet tenu a ete clique.
func handle_click(local_pos: Vector2) -> bool:
	if not enabled or layer == null:
		return false
	var hit := layer.hit_test(local_pos)
	if hit.is_empty():
		return false
	_activate(hit)
	return true


func handle_right_click(local_pos: Vector2) -> bool:
	if not enabled or layer == null:
		return false
	var hit := layer.hit_test(local_pos)
	if hit.is_empty():
		return false
	forget(hit["item"])
	return true


func _activate(hit: Dictionary) -> void:
	match hit["zone"]:
		"card":
			if layer:
				layer.press_bump()
			copy_item(hit["item"])
		"close":
			forget(hit["item"])
		"badge":
			cycle()
		"pile":
			pick_up(hit["item"])


func _release(pos: Vector2) -> void:
	var hit := _press
	var was_drag := _dragging
	_cancel_press()
	if not was_drag:
		_activate(hit)
		return
	var it: Dictionary = hit["item"]
	if items.find(it) < 0:
		layer.end_drag(false)
		return
	if _outside_window():
		layer.end_drag(true)
		drop_outside(it)
	elif it["place"] == "head" and layer.pile_drop_rect().has_point(pos):
		layer.end_drag(true)
		put_down([it], "manual")
	elif it["place"] == "feet" and pos.y < layer.pile_drop_rect().position.y:
		layer.end_drag(true)
		pick_up(it, false)
	else:
		layer.end_drag(false)  # retour sur sa tete


func _cancel_press() -> void:
	_press = {}
	_dragging = false


func _outside_window() -> bool:
	if sim_mouse:
		return sim_outside
	var w := get_window()
	var m := DisplayServer.mouse_get_position()
	return not Rect2i(w.position, w.size).has_point(m)


func _local_mouse() -> Vector2:
	return Vector2(DisplayServer.mouse_get_position() - get_window().position)


func _s() -> float:
	return stage.ppu / 100.0 if stage else 1.0


# =========================================================================== helper Windows
func _start_helper() -> bool:
	var src := FileAccess.open("res://helper/clipboard_helper.ps1", FileAccess.READ)
	if src == null:
		return false
	var dst_path := "user://clipboard_helper.ps1"
	var dst := FileAccess.open(dst_path, FileAccess.WRITE)
	if dst == null:
		return false
	dst.store_string(src.get_as_text())
	dst.close()
	var args := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", ProjectSettings.globalize_path(dst_path), "-ParentPid", str(OS.get_process_id()),
	])
	var d := OS.execute_with_pipe("powershell.exe", args, true)
	if d.is_empty():
		return false
	_pipe = d["stdio"]
	_pid = d["pid"]
	_running = true
	_thread = Thread.new()
	_thread.start(_reader)
	return true


func _reader() -> void:
	while _running and _pipe and _pipe.is_open():
		var line := _pipe.get_line()
		if _pipe.get_error() != OK and line == "":
			break
		if line.begins_with("{"):
			_mutex.lock()
			_lines.append(line)
			_mutex.unlock()
	_running = false


func _drain_helper() -> void:
	if _pipe == null:
		return
	_mutex.lock()
	var lines := _lines
	_lines = PackedStringArray()
	_mutex.unlock()
	for l in lines:
		var d = JSON.parse_string(l)
		if typeof(d) != TYPE_DICTIONARY:
			continue
		match str(d.get("ev", "")):
			"ready":
				if _mode == "starting":
					_mode = "helper"
			"clip":
				if _mode == "starting":
					_mode = "helper"
				if enabled:
					_on_clip_event(d)
			"set":
				if not bool(d.get("ok", false)):
					print_verbose("Pompom presse-papiers occupe par : ", d.get("busy", "?"))
					_pill("Oups, le presse-papiers est occupé...", UITheme.PEACH, {})


func _write_cmd(line: String) -> void:
	if _pipe and _running:
		_pipe.store_string(line + "\n")
		_pipe.flush()


func _stop_helper() -> void:
	if _pipe and _running:
		_write_cmd("quit")
	_running = false
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_pipe = null
