extends Node
## Etat persistant du joueur et du compagnon (user://save.json).

signal coins_changed(value: int, delta: int)
signal equipment_changed
signal appearance_changed
signal settings_changed
signal stats_changed
signal needs_changed
signal xp_changed(xp: int, level: int)
signal level_up(level: int, rewards: Array)
signal quest_completed(quest: Dictionary)

const SAVE_PATH := "user://save.json"

var coins := 150
var species := "mochi"
var pet_name := "Mochi"
var fur_color := ""  # hex, vide = couleur de l'espece
var material := "peluche"
var eye_style := ""  # vide = style par defaut de l'espece
var mouth_style := "smile"
var iris_color := ""  # vide = couleur par defaut du style d'yeux
var owned_looks := {"mat:peluche": true}  # matieres / yeux / bouches achetes ("mat:x", "eye:x", "mouth:x")
var owned := {}  # item_id -> true
var item_colors := {}  # item_id -> {"main": hex, "accent": hex}
var equipped := {"head": "", "face": "", "neck": "", "back": ""}
var discovered := {}  # "espece:item" -> niveau de preference decouvert
var happiness := 70.0
var energy := 80.0
var hunger := 70.0  # satiete : 0 = affame, 100 = repu
var fun := 70.0  # amusement
var level := 1
var xp := 0
var quests: Array = []  # [{id, kind, goal, progress, text, coins, xp, done}]
var quest_day := ""
var eaten := {"count": 0, "bytes": 0}
var unlocked_species := {"mochi": true}
var stats := {
	"day": "", "work": 0.0, "game": 0.0, "other": 0.0, "earned_today": 0,
	"earned_total": 0, "work_total": 0.0, "game_total": 0.0, "pets": 0, "first_run": true,
}
var settings := {
	"size": 1.0, "hide_fullscreen": false, "discreet": true, "autostart": false,
	"home_x": -1.0, "talk": true, "fur_quality": 16, "wander": true, "reflections": true, "ssaa": 2.0, "windows": true, "climb": true,
	"eat_files": true, "eat_confirmed": false, "auto_update": true, "share_visible": true, "screenshots": true, "competitive_hide": true, "game_spots": {}, "clipboard": false, "suggestions": false, "ai_gpu": true,
}

var no_save := false  # mode test
var _dirty := false
var _save_timer := 0.0


func _ready() -> void:
	load_game()
	_roll_day()
	# les especes deja choisies avant la progression restent accessibles
	unlocked_species[species] = true


func _process(delta: float) -> void:
	_save_timer += delta
	if _save_timer > 20.0:
		_save_timer = 0.0
		_roll_day()
		if _dirty:
			save_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_EXIT_TREE:
		save_game()


func mark_dirty() -> void:
	_dirty = true


# ------------------------------------------------------------------ pieces
func add_coins(n: int) -> void:
	if n == 0:
		return
	coins += n
	if n > 0:
		stats["earned_today"] = int(stats["earned_today"]) + n
		stats["earned_total"] = int(stats["earned_total"]) + n
	coins_changed.emit(coins, n)
	stats_changed.emit()
	mark_dirty()


func can_afford(price: int) -> bool:
	return coins >= price


func buy(item_id: String) -> bool:
	var item: Dictionary = Data.ITEMS.get(item_id, {})
	if item.is_empty() or owned.has(item_id):
		return false
	var price: int = item["price"]
	if coins < price:
		return false
	add_coins(-price)
	owned[item_id] = true
	mark_dirty()
	save_game()
	return true


# ------------------------------------------------------------------ equipement
func colors_for(item_id: String) -> Dictionary:
	var item: Dictionary = Data.ITEMS.get(item_id, {})
	var c: Dictionary = item_colors.get(item_id, {})
	return {
		"main": Data.color_of(c.get("main", item.get("main", "blanc"))),
		"accent": Data.color_of(c.get("accent", item.get("accent", "blanc"))),
		"detail": Data.color_of(c.get("detail", item.get("detail", item.get("accent", "blanc")))),
	}


func set_item_color(item_id: String, which: String, c: Color) -> void:
	var cur: Dictionary = item_colors.get(item_id, {})
	cur[which] = c.to_html(false)
	item_colors[item_id] = cur
	mark_dirty()
	if equipped.values().has(item_id):
		equipment_changed.emit()


func equip(item_id: String) -> void:
	var item: Dictionary = Data.ITEMS.get(item_id, {})
	if item.is_empty() or not owned.has(item_id):
		return
	equipped[item["slot"]] = item_id
	mark_dirty()
	equipment_changed.emit()


func unequip(slot: String) -> void:
	equipped[slot] = ""
	mark_dirty()
	equipment_changed.emit()


func is_equipped(item_id: String) -> bool:
	return equipped.values().has(item_id)


func discover(item_id: String, level: int) -> void:
	discovered["%s:%s" % [species, item_id]] = level
	mark_dirty()


func discovered_level(item_id: String):
	return discovered.get("%s:%s" % [species, item_id], null)


# ------------------------------------------------------------------ apparence
func current_fur_color() -> Color:
	if fur_color != "":
		return Color.html(fur_color)
	var sp: Dictionary = Data.SPECIES[species]
	return Color.html(sp["fur"])


func set_species(id: String) -> void:
	if not Data.SPECIES.has(id) or id == species:
		return
	var old_default: String = Data.SPECIES[species]["name"]
	if pet_name == old_default:
		pet_name = Data.SPECIES[id]["name"]
	species = id
	if Data.MATERIALS[material].get("color", "") == "":
		fur_color = ""
	mark_dirty()
	appearance_changed.emit()


func owns_look(key: String) -> bool:
	if owned_looks.has(key):
		return true
	var parts := key.split(":")
	var price := look_price(key)
	return price == 0


func look_price(key: String) -> int:
	var parts := key.split(":")
	if parts.size() != 2:
		return 0
	var table: Dictionary = {"mat": Data.MATERIALS, "eye": Data.EYES, "mouth": Data.MOUTHS}.get(parts[0], {})
	var entry: Dictionary = table.get(parts[1], {})
	return int(entry.get("price", 0))


func buy_look(key: String) -> bool:
	if owns_look(key):
		return true
	var price := look_price(key)
	if coins < price:
		return false
	add_coins(-price)
	owned_looks[key] = true
	mark_dirty()
	save_game()
	return true


func set_look(kind: String, id: String) -> void:
	match kind:
		"mat":
			material = id
			var def: String = Data.MATERIALS.get(id, {}).get("color", "")
			if def != "":
				fur_color = def
		"eye":
			eye_style = id
		"mouth":
			mouth_style = id
	mark_dirty()
	appearance_changed.emit()


func current_eye_style() -> String:
	if eye_style != "":
		return eye_style
	return str(Data.anchors(species).get("eye_style", "dot"))


func current_iris() -> Color:
	if iris_color != "":
		return Color.html(iris_color)
	var d: String = str(Data.EYES.get(current_eye_style(), {}).get("iris", ""))
	return Color.html(d) if d != "" and Color.html_is_valid(d) else Color("6fb1f2")


func set_iris(c: Color) -> void:
	iris_color = c.to_html(false)
	mark_dirty()
	appearance_changed.emit()


func set_fur_color(c: Color) -> void:
	fur_color = c.to_html(false)
	mark_dirty()
	appearance_changed.emit()


func set_setting(key: String, value) -> void:
	settings[key] = value
	mark_dirty()
	settings_changed.emit()


# ------------------------------------------------------------------ progression
func species_unlocked(id: String) -> bool:
	return unlocked_species.has(id) or level >= int(Data.SPECIES_LEVEL.get(id, 1))


func add_xp(n: int) -> void:
	if n <= 0:
		return
	xp += n
	while xp >= Data.xp_for_next(level):
		xp -= Data.xp_for_next(level)
		level += 1
		var rewards := Data.level_rewards(level)
		for r in rewards:
			match r["type"]:
				"coins":
					add_coins(int(r["value"]))
				"species":
					unlocked_species[r["value"]] = true
				"gift":
					var pool: Array = []
					for id in Data.ITEMS:
						if not owned.has(id):
							pool.append(id)
					if not pool.is_empty():
						var gift: String = pool[randi() % pool.size()]
						owned[gift] = true
						r["text"] = "Cadeau : %s !" % Data.ITEMS[gift]["name"]
		level_up.emit(level, rewards)
	xp_changed.emit(xp, level)
	mark_dirty()


func change_hunger(d: float) -> void:
	hunger = clampf(hunger + d, 0.0, 100.0)
	needs_changed.emit()
	mark_dirty()


func change_fun(d: float) -> void:
	fun = clampf(fun + d, 0.0, 100.0)
	needs_changed.emit()
	mark_dirty()


## Le compagnon mange : `nutrition` points de satiete, `size` octets.
func feed(nutrition: float, size: int) -> void:
	change_hunger(nutrition)
	eaten["count"] = int(eaten["count"]) + 1
	eaten["bytes"] = int(eaten["bytes"]) + size
	add_xp(int(round(nutrition * 0.8)) + 2)
	quest_event("feed_files")


## Multiplicateur de gains selon les besoins (un compagnon affame gagne moins).
func earn_multiplier() -> float:
	var m := 1.0
	if happiness >= 75.0:
		m *= 1.2
	if hunger < 20.0:
		m *= 0.7
	return m


## Un evenement de jeu fait avancer les quetes du jour (feed, pet, throw, poke, outfit, climb, work_min...).
func quest_event(kind: String, amount := 1) -> void:
	_roll_day()
	for q in quests:
		if q["kind"] != kind or q["done"]:
			continue
		q["progress"] = mini(int(q["progress"]) + amount, int(q["goal"]))
		if int(q["progress"]) >= int(q["goal"]):
			q["done"] = true
			add_coins(int(q["coins"]))
			add_xp(int(q["xp"]))
			quest_completed.emit(q)
		mark_dirty()
		stats_changed.emit()


func _roll_quests() -> void:
	var pool: Array = Data.QUEST_POOL.duplicate()
	pool.shuffle()
	quests.clear()
	for i in mini(3, pool.size()):
		var q: Dictionary = pool[i].duplicate()
		q["progress"] = 0
		q["done"] = false
		quests.append(q)
	quest_day = Time.get_date_string_from_system()
	mark_dirty()


func quest_text(q: Dictionary) -> String:
	return str(q["text"]) % pet_name if str(q["text"]).contains("%s") else str(q["text"])


# ------------------------------------------------------------------ humeur
func change_happiness(d: float) -> void:
	happiness = clampf(happiness + d, 0.0, 100.0)
	mark_dirty()
	stats_changed.emit()


func change_energy(d: float) -> void:
	energy = clampf(energy + d, 0.0, 100.0)
	mark_dirty()


func add_activity_time(kind: String, seconds: float) -> void:
	match kind:
		"work":
			stats["work"] = float(stats["work"]) + seconds
			stats["work_total"] = float(stats["work_total"]) + seconds
		"game":
			stats["game"] = float(stats["game"]) + seconds
			stats["game_total"] = float(stats["game_total"]) + seconds
		_:
			stats["other"] = float(stats["other"]) + seconds
	mark_dirty()


## Bonheur moyen apporte par l'equipement porte (-2..2 par piece).
func outfit_score() -> int:
	var total := 0
	for slot in equipped:
		var id: String = equipped[slot]
		if id != "":
			total += Data.preference(species, id, colors_for(id)["main"])
	return total


func _roll_day() -> void:
	var today := Time.get_date_string_from_system()
	if stats["day"] != today:
		stats["day"] = today
		stats["work"] = 0.0
		stats["game"] = 0.0
		stats["other"] = 0.0
		stats["earned_today"] = 0
		mark_dirty()
	if quest_day != today or quests.is_empty():
		_roll_quests()


# ------------------------------------------------------------------ sauvegarde
func save_game() -> void:
	if no_save:
		return
	var d := {
		"version": 1, "coins": coins, "species": species, "pet_name": pet_name, "fur_color": fur_color,
		"material": material, "eye_style": eye_style, "mouth_style": mouth_style, "iris_color": iris_color,
		"owned_looks": owned_looks,
		"owned": owned, "item_colors": item_colors, "equipped": equipped, "discovered": discovered,
		"happiness": happiness, "energy": energy, "stats": stats, "settings": settings,
		"hunger": hunger, "fun": fun, "level": level, "xp": xp, "quests": quests, "quest_day": quest_day,
		"eaten": eaten, "unlocked_species": unlocked_species,
		"saved_at": Time.get_unix_time_from_system(),
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d, "\t"))
		_dirty = false


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	if typeof(d) != TYPE_DICTIONARY:
		return
	coins = int(d.get("coins", coins))
	species = str(d.get("species", species))
	if not Data.SPECIES.has(species):
		species = "mochi"
	pet_name = str(d.get("pet_name", pet_name))
	fur_color = str(d.get("fur_color", ""))
	material = str(d.get("material", material))
	if not Data.MATERIALS.has(material):
		material = "peluche"
	eye_style = str(d.get("eye_style", ""))
	mouth_style = str(d.get("mouth_style", "smile"))
	iris_color = str(d.get("iris_color", iris_color))
	var ol: Dictionary = d.get("owned_looks", {})
	for k in ol:
		owned_looks[k] = true
	owned = d.get("owned", {})
	item_colors = d.get("item_colors", {})
	var eq: Dictionary = d.get("equipped", {})
	for slot in equipped:
		equipped[slot] = str(eq.get(slot, ""))
	discovered = d.get("discovered", {})
	happiness = float(d.get("happiness", happiness))
	energy = float(d.get("energy", energy))
	hunger = float(d.get("hunger", hunger))
	fun = float(d.get("fun", fun))
	level = int(d.get("level", level))
	xp = int(d.get("xp", xp))
	quests = d.get("quests", [])
	quest_day = str(d.get("quest_day", ""))
	var ea: Dictionary = d.get("eaten", {})
	for k in ea:
		eaten[k] = ea[k]
	var us: Dictionary = d.get("unlocked_species", {})
	for k in us:
		unlocked_species[k] = true
	var st: Dictionary = d.get("stats", {})
	for k in st:
		stats[k] = st[k]
	var se: Dictionary = d.get("settings", {})
	for k in se:
		settings[k] = se[k]
	# Temps passe hors ligne : le compagnon s'est repose.
	var away := Time.get_unix_time_from_system() - float(d.get("saved_at", 0))
	if away > 60:
		energy = clampf(energy + away / 60.0, 0, 100)
		# pendant ton absence, il a eu un peu faim (sans jamais tomber trop bas)
		hunger = maxf(minf(hunger, 30.0), hunger - away / 900.0)
