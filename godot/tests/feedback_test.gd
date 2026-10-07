extends Node
## Tests (headless) de la boucle de retour : jeu de donnees local (ajout, rotation, effacement), contextes
## prives (rien n'est capture), contenu envoye (aucun champ interdit), adresse du serveur, plafond disque.
##   Godot --path godot --headless res://tests/feedback_test.tscn
## Code de sortie 0 = tout passe. Ecrit aussi user://feedback_payload_sample.json (verifiable par le serveur).

const FORBIDDEN := ["title", "window_title", "text", "note", "image", "shot", "screenshot", "local", "field", "id",
	"time", "day", "vision_probs", "auto_situation", "event_ago", "category", "fullscreen", "game", "source", "share"]

var passed := 0
var failed := 0


func check(cond: bool, what: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("FAIL ", what)


func _ready() -> void:
	GameState.no_save = true
	_test_store()
	_test_private()
	_test_sanitize()
	_test_payload()
	_test_endpoint()
	_test_cap()
	_test_card_text()
	await _test_hub()
	print("FEEDBACK TEST RESULT: %d passed, %d failed" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _emb(dim := 768, seed := 1.0) -> Dictionary:
	var a := PackedFloat32Array()
	a.resize(dim)
	var n := 0.0
	for i in dim:
		a[i] = sin(seed * (i + 1))
		n += a[i] * a[i]
	for i in dim:
		a[i] /= sqrt(n)
	return {"b64": Marshalls.raw_to_base64(a.to_byte_array()), "dtype": "float32", "dim": dim,
		"model_id": "siglip-b16-224.fp16", "model_version": "e79563a4df40"}


func _sample(label := "music", emb = null, share := true) -> Dictionary:
	return {"task": "activity", "label": label, "app": "C:\\Program Files\\Spotify\\Spotify.exe", "category": "media",
		"pet": {"situation": "video_watch", "mode": "video", "vision": "video", "vision_probs": {"video": 0.7},
			"event": "", "event_ago": -1.0, "auto_situation": "music_listen"},
		"emb": emb if emb != null else _emb(), "share": share, "source": "menu", "fullscreen": false, "game": "",
		"local": {"title": "Relevé de compte - Ma Banque SECRET", "note": "note privee SECRET", "shot": "shots/x.webp"},
		"title": "TITRE SECRET", "window_title": "TITRE SECRET", "text": "texte SECRET", "image": "AAAA"}


func _test_store() -> void:
	var st := FeedbackStore.new()
	st.dir = "user://test_dataset_%d" % randi()
	st.erase_all()
	check(st.add({"task": "activity", "label": "cinema"}) == "", "etiquette hors vocabulaire refusee")
	check(st.add({"task": "screen", "label": "video"}) == "", "tache inconnue refusee")
	var id1 := st.add(_sample("music"))
	var id2 := st.add(_sample("video", null, false))
	var s3 := _sample("game")
	s3["emb"] = null
	var id3 := st.add(s3)
	check(id1 != "" and id2 != "" and id3 != "", "ajouts valides")
	var all := st.load_all()
	check(all.size() == 3, "3 exemples relus (%d)" % all.size())
	check(str(all[0]["app"]) == "spotify", "nom d'appli nettoye a l'ecriture (%s)" % all[0]["app"])
	check(str(all[0]["day"]).length() == 10 and int(all[0]["v"]) == 1, "jour + version")
	var pend := st.pending_share()
	check(pend.size() == 1 and str(pend[0]["id"]) == id1, "a partager : seulement partageable + embedding")
	st.mark([id1], "sent")
	check(st.pending_share().is_empty(), "envoye -> plus a partager")
	check(str(st.load_all()[0]["status"]) == "sent", "statut relu")
	# ligne tronquee (arret brutal) : ignoree
	var f := FileAccess.open(st.feedback_path(), FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string("{\"task\": \"activ")
	f.close()
	check(st.load_all().size() == 3, "ligne tronquee ignoree")
	# rotation
	st.max_file_bytes = 6000
	for i in 12:
		st.add(_sample("code"))
	check(FileAccess.file_exists(st.feedback_path(1)), "rotation : feedback.1.jsonl")
	check(not FileAccess.file_exists(st.feedback_path(FeedbackStore.KEEP_FILES)), "rotation : au plus KEEP_FILES fichiers")
	var n := st.count()
	check(n > 0 and n < 15, "rotation : les plus anciens sont supprimes (%d)" % n)
	check(st.disk_bytes() > 0, "taille disque")
	# effacement
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(st.dir.path_join("screens")))
	var g := FileAccess.open(st.dir.path_join("screens/a.webp"), FileAccess.WRITE)
	g.store_string("x")
	g.close()
	var removed := st.erase_all()
	check(removed >= 3, "effacement : fichiers supprimes (%d)" % removed)
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(st.dir)), "effacement : dossier supprime")
	check(st.count() == 0, "effacement : plus rien")


func _test_private() -> void:
	var priv := [
		["bitwarden", "Bitwarden", "", false, false], ["keepassxc", "Base.kdbx - KeePassXC", "", false, false],
		["chrome", "Se connecter - Google Comptes - Google Chrome", "browse", false, false],
		["msedge", "Boursorama Banque - Mes comptes - Microsoft Edge", "browse", false, false],
		["chrome", "Code de vérification - Google Chrome", "browse", false, false],
		["firefox", "Nouvel onglet — Navigation privée de Mozilla Firefox", "browse", false, false],
		["code", "main.gd - Pompom", "work", true, false],  # visio en cours
		["code", "main.gd - Pompom", "work", false, true],  # enregistrement / stream
	]
	for c in priv:
		check(FeedbackStore.is_private_context(c[0], c[1], c[2], c[3], c[4]), "prive : %s / %s" % [c[0], c[1]])
	var ok := [["spotify", "Daft Punk - One More Time", "media"], ["code", "main.gd - Pompom - Visual Studio Code", "work"],
		["rocketleague", "Rocket League (64-bit, DX11, Cooked)", "game"]]
	for c in ok:
		check(not FeedbackStore.is_private_context(c[0], c[1], c[2]), "pas prive : %s" % c[0])
	var dev := DevCollector.new()
	dev.respect_setting = false
	dev.context_provider = func() -> Dictionary: return {"proc": "1password", "title": "1Password", "category": "work"}
	add_child(dev)
	check(dev.capture_now() == "private", "collecteur : rien en contexte prive")
	dev.context_provider = func() -> Dictionary: return {"proc": "spotify", "title": "Daft Punk", "situation": "private"}
	check(dev.capture_now() == "private", "collecteur : situation private")
	dev.context_provider = func() -> Dictionary: return {"proc": "spotify", "title": "Daft Punk", "category": "media"}
	check(dev.capture_now() == "headless", "collecteur : contexte normal (headless : pas de capture)")
	var meta := DevCollector.sidecar({"proc": "spotify", "title": "Daft Punk", "mode": "video", "extra_secret": "x"})
	check(meta.has("title") and not meta.has("extra_secret") and meta.has("day"), "fichier compagnon : liste blanche")
	dev.queue_free()


func _test_sanitize() -> void:
	var cases := {"Spotify.exe": "spotify", "C:\\Games\\RocketLeague.exe": "rocketleague", "  Code.EXE ": "code",
		"League of Legends.exe": "league of legends", "évil<script>.exe": "vilscript", "": "", "...x": "x",
		"a".repeat(80): "a".repeat(40)}
	for k in cases:
		check(FeedbackStore.sanitize_app(k) == cases[k], "sanitize_app(%s) = %s" % [k, FeedbackStore.sanitize_app(k)])


func _walk_keys(v, out: Array) -> void:
	if typeof(v) == TYPE_DICTIONARY:
		for k in v:
			out.append(str(k))
			_walk_keys(v[k], out)
	elif typeof(v) == TYPE_ARRAY:
		for x in v:
			_walk_keys(x, out)


func _test_payload() -> void:
	var bad_emb := _sample("music")
	bad_emb["emb"] = {"b64": "AAAA", "dtype": "float32", "dim": 768, "model_id": "siglip-b16-224.fp16", "model_version": "x"}
	var no_emb := _sample("music")
	no_emb["emb"] = null
	var bad_label := _sample("cinema")
	var odd := _sample("video")
	odd["pet"] = {"situation": "Video Watch!", "vision": "porn", "mode": "spy", "event": "goal", "secret": "SECRET"}
	var p := FeedbackUploader.build_payload([_sample("music"), bad_emb, no_emb, bad_label, odd], "0.5.4-beta")
	check(int(p["schema"]) == 1 and str(p["client"]) == "0.5.4-beta", "en-tete du lot")
	var items: Array = p["items"]
	check(items.size() == 2, "seuls les exemples valides partent (%d)" % items.size())
	var keys: Array = []
	_walk_keys(p, keys)
	for k in FORBIDDEN:
		check(not keys.has(k), "champ interdit absent : " + k)
	check(Array(p.keys()) == ["schema", "client", "items"], "cles du lot")
	for it in items:
		var ks: Array = it.keys()
		ks.sort()
		var want: Array = FeedbackUploader.ITEM_KEYS.duplicate()
		want.sort()
		check(ks == want, "cles d'un exemple = liste blanche")
		check(Array(it["pet"].keys()) == ["situation", "vision", "mode", "event"], "cles de pet")
	var txt := JSON.stringify(p)
	for secret in ["SECRET", "Banque", "Spotify.exe", "Program Files", "AAAA\""]:
		check(not txt.contains(secret), "rien de prive dans le JSON : " + secret)
	check(str(items[1]["pet"]["situation"]) == "" and str(items[1]["pet"]["vision"]) == "" and str(items[1]["pet"]["mode"]) == "",
		"pet : valeurs hors vocabulaire videes")
	check(str(items[0]["app"]) == "spotify" and str(items[0]["dtype"]) == "float16", "app + float16")
	var raw := Marshalls.base64_to_raw(str(items[0]["emb"]))
	check(raw.size() == 768 * 2, "float16 : 768 x 2 octets")
	var n := 0.0
	for i in 768:
		var x := raw.decode_half(i * 2)
		n += x * x
	check(absf(sqrt(n) - 1.0) < 0.01, "float16 : norme 1 (%.4f)" % sqrt(n))
	var orig := Marshalls.base64_to_raw(str(_emb()["b64"])).to_float32_array()
	check(absf(raw.decode_half(20) - orig[10]) < 1e-3, "float16 : valeurs conservees (%f vs %f)" % [raw.decode_half(20), orig[10]])
	var pv := FeedbackUploader.preview_json([_sample("music")])
	check(pv.contains("\"items\"") and not pv.contains("SECRET"), "apercu « Voir ce qui part » = lot exact")
	var f := FileAccess.open("user://feedback_payload_sample.json", FileAccess.WRITE)
	f.store_string(txt)
	f.close()


func _test_endpoint() -> void:
	check(not FeedbackUploader.is_configured(FeedbackUploader.DEFAULT_ENDPOINT), "adresse factice : rien n'est envoye")
	check(FeedbackUploader.is_configured("https://feedback.mondomaine.fr"), "https accepte")
	check(FeedbackUploader.is_configured("http://127.0.0.1:8000"), "serveur local de test accepte")
	check(not FeedbackUploader.is_configured("http://feedback.mondomaine.fr"), "http distant refuse")
	check(not FeedbackUploader.is_configured(""), "vide refuse")
	var up := FeedbackUploader.new()
	up.respect_setting = false
	up.enabled = true
	up.store = FeedbackStore.new()
	up.store.dir = "user://test_dataset_up_%d" % randi()
	up.store.add(_sample("music"))
	add_child(up)
	var saved_ep = ProjectSettings.get_setting("pompom/feedback/endpoint", "")
	ProjectSettings.set_setting("pompom/feedback/endpoint", "")  # (le vrai projet a une adresse : on la masque)
	check(not up.send_now(), "adresse non configuree : aucun envoi")
	ProjectSettings.set_setting("pompom/feedback/endpoint", saved_ep)
	up.enabled = false
	up.endpoint_override = "http://127.0.0.1:9"
	check(not up.send_now(), "reglage coupe : aucun envoi")
	up.store.erase_all()
	up.queue_free()


func _test_cap() -> void:
	var d := ProjectSettings.globalize_path("user://test_cap_%d" % randi())
	DirAccess.make_dir_recursive_absolute(d)
	for i in 6:
		var f := FileAccess.open(d.path_join("2026-10-07_10-00-0%d.webp" % i), FileAccess.WRITE)
		f.store_buffer(_bytes(1000))
		f.close()
		var j := FileAccess.open(d.path_join("2026-10-07_10-00-0%d.json" % i), FileAccess.WRITE)
		j.store_string("{}")
		j.close()
	DevCollector.enforce_cap(d, 3100)
	var left := Array(DirAccess.get_files_at(d))
	left.sort()
	check(left.size() == 6, "plafond : 3 captures + 3 json gardees (%d)" % left.size())
	check(left[0] == "2026-10-07_10-00-03.json", "plafond : les plus anciennes supprimees")
	FeedbackStore._rm_tree(d)


func _bytes(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	return b


func _test_card_text() -> void:
	check(FeedbackCard.thought_text({"situation": "video_watch"}).contains("Regarde une vid"), "carte : il pensait (situation)")
	check(FeedbackCard.thought_text({"vision": "video"}).contains("vidéo"), "carte : il pensait (vision)")
	check(FeedbackCard.thought_text({"event": "goal"}).contains("J'ai marqué"), "carte : dernier evenement")
	check(FeedbackCard.thought_text({}) != "", "carte : texte par defaut")


# =========================================================================== hub (controleur simule)
class FakePet extends RefCounted:
	var busy := false
	var sleeping := false
	var nods := 0
	func act_nod() -> void:
		nods += 1


class FakeSit extends RefCounted:
	var current := "video_watch"
	var playing := false
	func is_playing() -> bool:
		return playing


class FakeGames extends Node:
	signal event(kind: String, mine: bool, data: Dictionary)
	var proc := "rocketleague"


class FakeSuggest extends Node:
	signal suggestion(text_fr: String, idx: int, kind: String)
	var last_field := {}
	func api_base() -> String:
		return ""
	func api_headers() -> PackedStringArray:
		return PackedStringArray()


class FakeEmotes extends RefCounted:
	var said := ""
	func say(t: String, _d := 3.0) -> void:
		said = t


class FakeCtrl extends Node:
	var win: Window
	var pet := FakePet.new()
	var mode := "normal"
	var situations := FakeSit.new()
	var vision = null
	var games := FakeGames.new()
	var suggest := FakeSuggest.new()
	var emotes := FakeEmotes.new()


func _test_hub() -> void:
	var ctrl := FakeCtrl.new()
	ctrl.win = get_window()
	add_child(ctrl)
	ctrl.add_child(ctrl.games)
	ctrl.add_child(ctrl.suggest)
	var hub := FeedbackHub.new()
	hub.store.dir = "user://test_dataset_hub_%d" % randi()
	ctrl.add_child(hub)
	hub.setup(ctrl)
	check(not hub.should_offer_chip(), "hub : pas de pastille sans comportement automatique")
	ctrl.situations.playing = true
	check(hub.should_offer_chip(), "hub : pastille pendant une situation imitee")
	ctrl.situations.playing = false
	ctrl.games.event.emit("goal", true, {})
	check(hub.should_offer_chip(), "hub : pastille juste apres un evenement de jeu")
	check(hub.on_pet_clicked(), "hub : pastille affichee")
	check(not hub.should_offer_chip(), "hub : pas deux fois de suite (delai)")
	var c := hub.context()
	check(str(c["event"]) == "goal" and bool(c["game_context"]) and str(c["game"]) == "rocketleague", "hub : contexte de jeu")
	await hub.open_card("chip")
	check(hub.card != null and is_instance_valid(hub.card), "hub : carte ouverte")
	check(str(hub._snap["emb_state"]) == "none", "hub : service absent -> pas d'embedding")
	hub.card.select("activity", "music")
	hub.card.select("game_event", "goal")
	hub.card.submit()
	var all := hub.store.load_all()
	check(all.size() == 2, "hub : 2 exemples enregistres (%d)" % all.size())
	if all.size() == 2:
		check(str(all[0]["task"]) == "activity" and str(all[0]["label"]) == "music", "hub : activite")
		check(str(all[1]["task"]) == "game_event" and str(all[1]["label"]) == "goal", "hub : evenement")
		check(not bool(all[0]["share"]) and all[0]["emb"] == null, "hub : sans embedding -> jamais partage")
		check(str(all[0]["pet"]["event"]) == "goal" and str(all[0]["source"]) == "chip", "hub : decision du compagnon")
		check(str(all[0]["local"]["title"]) == Activity.window_title, "hub : titre garde en local seulement")
	check(ctrl.emotes.said != "" and ctrl.pet.nods == 1, "hub : il remercie")
	hub.store.erase_all()
	ctrl.queue_free()
