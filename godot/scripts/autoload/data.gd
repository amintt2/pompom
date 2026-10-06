extends Node
## Catalogue statique : especes, accessoires, palettes, repliques.

const LOVE := 2
const LIKE := 1
const NEUTRAL := 0
const DISLIKE := -1
const HATE := -2

## Couleurs proposees pour personnaliser les accessoires.
const PALETTE := {
	"blanc": "f7f4ee", "noir": "232027", "gris": "9a98a3", "rouge": "e5484d", "corail": "ff7f6e",
	"orange": "ff9f43", "jaune": "ffd23f", "vert": "5cc46b", "menthe": "7ee0c3", "ciel": "7cc8ff",
	"bleu": "3d6fe0", "violet": "9b5de5", "rose": "ff7eb3", "marron": "9c6644",
}

## Couleurs de fourrure proposees.
const FUR_PALETTE := {
	"rose": "f59ab8", "jaune": "f7c948", "lavande": "b38be0", "bleu": "6fb1f2", "vert": "a8d94a",
	"menthe": "86dcc0", "pêche": "ffb38a", "crème": "f3e6cf", "gris": "b9b7c2", "chocolat": "8d6248",
	"nuit": "4b4a6b", "corail": "ff8a80",
}

const SPECIES := {
	"mochi": {
		"name": "Mochi", "desc": "Une boule de poils toute douce avec deux petites oreilles.",
		"fur": "f59ab8", "fur_length": 0.06, "density": 70.0, "fav_color": "rose", "likes_carry": true,
		"prefs": {
			"headphones": LOVE, "ribbon": LOVE, "beanie": LIKE, "flower": LIKE, "party_hat": LIKE,
			"bunny_ears": LIKE, "scarf": LIKE, "viking": DISLIKE, "monocle": DISLIKE, "witch": HATE,
		},
	},
	"pico": {
		"name": "Pico", "desc": "Un petit triangle très distingué. Aime les belles manières.",
		"fur": "f7c948", "fur_length": 0.05, "density": 80.0, "fav_color": "noir", "likes_carry": false,
		"prefs": {
			"round_glasses": LOVE, "bow_tie": LOVE, "top_hat": LIKE, "monocle": LIKE, "chef": LIKE,
			"beret": LIKE, "party_hat": DISLIKE, "bunny_ears": DISLIKE, "cap": HATE,
		},
	},
	"coco": {
		"name": "Coco", "desc": "Un cœur cool, toujours à l'aise. Adore briller.",
		"fur": "b04fc4", "fur_length": 0.035, "density": 110.0, "fav_color": "violet", "likes_carry": true,
		"prefs": {
			"sunglasses": LOVE, "crown": LOVE, "star_glasses": LIKE, "halo": LIKE, "flower": LIKE,
			"headphones": LIKE, "chef": DISLIKE, "cowboy": DISLIKE, "beanie": HATE,
		},
	},
	"nuage": {
		"name": "Nuage", "desc": "Une fleur-nuage rêveuse. Un peu artiste.",
		"fur": "6fb1f2", "fur_length": 0.05, "density": 75.0, "fav_color": "ciel", "likes_carry": true,
		"prefs": {
			"beret": LOVE, "scarf": LOVE, "halo": LIKE, "flower": LIKE, "ribbon": LIKE,
			"round_glasses": LIKE, "viking": DISLIKE, "crown": DISLIKE, "top_hat": HATE,
		},
	},
	"kiwi": {
		"name": "Kiwi", "desc": "Une grenouille pleine d'énergie. Toujours partante pour jouer !",
		"fur": "a8d94a", "fur_length": 0.055, "density": 70.0, "fav_color": "orange", "likes_carry": false,
		"prefs": {
			"propeller": LOVE, "cap": LOVE, "cowboy": LIKE, "party_hat": LIKE, "headphones": LIKE,
			"viking": LIKE, "round_glasses": DISLIKE, "monocle": DISLIKE, "bow_tie": HATE,
		},
	},
}

## Catalogue de secours (remplace par data/accessories.json s'il existe).
## fit : hat | headphones | eyes | mouth | neck | scarf | back
const FALLBACK_ITEMS := {
	"flower": {"name": "Fleur", "slot": "head", "price": 60, "fit": "hat", "main": "rose", "accent": "jaune",
		"desc": "Une jolie fleur posée sur la tete."},
	"ribbon": {"name": "Nœud", "slot": "head", "price": 70, "fit": "hat", "main": "rouge", "accent": "rouge",
		"desc": "Un nœud tout mignon."},
	"party_hat": {"name": "Chapeau de fête", "slot": "head", "price": 80, "fit": "hat", "main": "ciel", "accent": "jaune",
		"desc": "Pour fêter chaque victoire."},
	"cap": {"name": "Casquette", "slot": "head", "price": 100, "fit": "hat", "main": "rouge", "accent": "blanc",
		"desc": "Style décontracté garanti."},
	"beret": {"name": "Béret", "slot": "head", "price": 120, "fit": "hat", "main": "noir", "accent": "noir",
		"desc": "Tres chic, tres artiste."},
	"beanie": {"name": "Bonnet", "slot": "head", "price": 120, "fit": "hat", "main": "menthe", "accent": "blanc",
		"desc": "Bien au chaud, avec un pompon tout doux."},
	"chef": {"name": "Toque", "slot": "head", "price": 180, "fit": "hat", "main": "blanc", "accent": "blanc",
		"desc": "Pour les grands chefs."},
	"bunny_ears": {"name": "Oreilles de lapin", "slot": "head", "price": 200, "fit": "hat", "main": "blanc", "accent": "rose",
		"desc": "Des oreilles toutes douces."},
	"cowboy": {"name": "Chapeau de cowboy", "slot": "head", "price": 220, "fit": "hat", "main": "marron", "accent": "noir",
		"desc": "Yee-haw !"},
	"top_hat": {"name": "Haut-de-forme", "slot": "head", "price": 250, "fit": "hat", "main": "noir", "accent": "rouge",
		"desc": "L'elegance absolue."},
	"witch": {"name": "Chapeau de sorcière", "slot": "head", "price": 260, "fit": "hat", "main": "violet", "accent": "noir",
		"desc": "Un peu de magie sur le bureau."},
	"headphones": {"name": "Casque audio", "slot": "head", "price": 280, "fit": "headphones", "main": "noir", "accent": "rose",
		"desc": "Pour écouter de la musique en travaillant."},
	"propeller": {"name": "Casquette hélice", "slot": "head", "price": 300, "fit": "hat", "main": "jaune", "accent": "rouge",
		"desc": "L'hélice tourne quand il est content !"},
	"viking": {"name": "Casque viking", "slot": "head", "price": 350, "fit": "hat", "main": "gris", "accent": "blanc",
		"desc": "Pour les guerriers du clavier."},
	"halo": {"name": "Auréole", "slot": "head", "price": 400, "fit": "hat", "main": "jaune", "accent": "jaune",
		"desc": "Un petit ange (presque)."},
	"crown": {"name": "Couronne", "slot": "head", "price": 600, "fit": "hat", "main": "jaune", "accent": "ciel",
		"desc": "Pour le roi ou la reine du bureau."},
	"round_glasses": {"name": "Lunettes rondes", "slot": "face", "price": 150, "fit": "eyes", "main": "noir", "accent": "noir",
		"desc": "Un air tres intelligent."},
	"sunglasses": {"name": "Lunettes de soleil", "slot": "face", "price": 180, "fit": "eyes", "main": "noir", "accent": "noir",
		"desc": "Trop cool pour l'école."},
	"star_glasses": {"name": "Lunettes étoiles", "slot": "face", "price": 220, "fit": "eyes", "main": "rose", "accent": "rose",
		"desc": "Une vraie star."},
	"monocle": {"name": "Monocle", "slot": "face", "price": 260, "fit": "eyes", "main": "jaune", "accent": "jaune",
		"desc": "Fort distingué, tres cher."},
	"bow_tie": {"name": "Nœud papillon", "slot": "neck", "price": 110, "fit": "neck", "main": "noir", "accent": "noir",
		"desc": "Toujours sur son trente-et-un."},
	"scarf": {"name": "Écharpe", "slot": "neck", "price": 140, "fit": "scarf", "main": "rouge", "accent": "blanc",
		"desc": "Une écharpe rayée bien chaude."},
}

const SLOTS := ["head", "face", "neck", "back"]
const SLOT_NAMES := {"head": "Chapeaux", "face": "Visage", "neck": "Cou", "back": "Dos"}

## Matieres du corps. kind : fur (coques de poils) ou un shader lisse.
## phys : k = raideur du ressort, c = amortissement, bounce = rebond a l'atterrissage,
##        stretch = etirement quand on le porte, plastic = garde la deformation (pate),
##        ripple = ondulation de surface, rigid = se balance comme un objet dur au lieu de se deformer.
const MATERIALS := {
	"peluche": {"name": "Peluche", "price": 0, "kind": "fur", "color": "", "desc": "Tout doux, plein de poils.",
		"fur_scale": 1.0, "density_scale": 1.0, "sheen": 0.0,
		"phys": {"k": 160.0, "c": 9.0, "bounce": 0.22, "stretch": 0.18, "plastic": 0.0, "ripple": 0.0, "rigid": 0.0}},
	"velours": {"name": "Velours", "price": 150, "kind": "fur", "color": "", "desc": "Poils ras et reflets satinés.",
		"fur_scale": 0.3, "density_scale": 2.6, "sheen": 0.7,
		"phys": {"k": 180.0, "c": 10.0, "bounce": 0.2, "stretch": 0.15, "plastic": 0.0, "ripple": 0.0, "rigid": 0.0}},
	"gelee": {"name": "Gelée", "price": 250, "kind": "jelly", "color": "", "desc": "Transparente et toute tremblotante.",
		"params": {"roughness": 0.04, "opacity": 0.85, "ior": 1.36, "dispersion": 0.012, "thickness": 1.1},
		"phys": {"k": 70.0, "c": 2.2, "bounce": 0.6, "stretch": 0.35, "plastic": 0.0, "ripple": 1.0, "rigid": 0.0}},
	"slime": {"name": "Slime", "price": 300, "kind": "slime", "color": "8ef25c", "desc": "Gluant, mou, et ça s'étale !",
		"params": {"roughness": 0.12, "opacity": 0.55, "ior": 1.34, "dispersion": 0.006, "thickness": 1.4},
		"phys": {"k": 32.0, "c": 4.5, "bounce": 0.06, "stretch": 0.7, "plastic": 0.15, "ripple": 0.7, "rigid": 0.0}},
	"pate": {"name": "Pâte à pain", "price": 200, "kind": "dough", "color": "f1d6a8", "desc": "Moelleuse, garde la forme quand on l'écrase.",
		"params": {"roughness": 0.85, "clearcoat": 0.05},
		"phys": {"k": 55.0, "c": 13.0, "bounce": 0.0, "stretch": 0.3, "plastic": 0.8, "ripple": 0.0, "rigid": 0.0}},
	"plastique": {"name": "Plastique", "price": 150, "kind": "plastic", "color": "", "desc": "Brillant comme un jouet, rebondit très bien.",
		"params": {"roughness": 0.18, "clearcoat": 0.9},
		"phys": {"k": 300.0, "c": 7.0, "bounce": 0.72, "stretch": 0.08, "plastic": 0.0, "ripple": 0.0, "rigid": 0.0}},
	"bois": {"name": "Bois", "price": 200, "kind": "wood", "color": "c08a5a", "desc": "Solide et verni. Toc toc !",
		"params": {"roughness": 0.35, "clearcoat": 0.55},
		"phys": {"k": 1200.0, "c": 40.0, "bounce": 0.35, "stretch": 0.0, "plastic": 0.0, "ripple": 0.0, "rigid": 1.0}},
	"chrome": {"name": "Chrome", "price": 400, "kind": "chrome", "color": "dfe6f0", "desc": "Un miroir : il reflète tout ton écran.",
		"params": {"roughness": 0.03},
		"phys": {"k": 900.0, "c": 28.0, "bounce": 0.5, "stretch": 0.0, "plastic": 0.0, "ripple": 0.0, "rigid": 1.0}},
	"verre": {"name": "Verre", "price": 450, "kind": "liquid", "color": "f4f8ff", "desc": "Du vrai verre : il réfracte ton écran comme une lentille, avec des reflets arc-en-ciel.",
		"params": {"lens": 0.24, "frost": 0.6, "glass_glow": 0.12},
		"phys": {"k": 1500.0, "c": 45.0, "bounce": 0.3, "stretch": 0.0, "plastic": 0.0, "ripple": 0.0, "rigid": 1.0}},
	"neon": {"name": "Néon fluo", "price": 350, "kind": "neon", "color": "3dffa0", "desc": "Brille dans le noir !",
		"params": {"emit": 0.4},
		"phys": {"k": 220.0, "c": 9.0, "bounce": 0.45, "stretch": 0.1, "plastic": 0.0, "ripple": 0.0, "rigid": 0.0}},
}

const FALLBACK_EYES := {"dot": {"name": "Points", "price": 0}, "googly": {"name": "Gros yeux", "price": 0}}
const FALLBACK_MOUTHS := {"smile": {"name": "Sourire", "price": 0}}

var ITEMS := {}
var EYES := {}
var MOUTHS := {}

## Materiaux fixes des accessoires (kind = shader de surface)
const FIXED_MATS := {
	"gold": {"color": "f2b84b", "kind": "chrome", "rough": 0.18},
	"silver": {"color": "dfe3ea", "kind": "chrome", "rough": 0.14},
	"metal": {"color": "dfe3ea", "kind": "chrome", "rough": 0.2},
	"white": {"color": "f3eee2", "kind": "plastic", "rough": 0.45},
	"black": {"color": "1f1d22", "kind": "plastic", "rough": 0.3},
	"glass": {"color": "2a2735", "kind": "glass", "rough": 0.04, "opacity": 0.35},
	"clear_glass": {"color": "eaf6ff", "kind": "glass", "rough": 0.03, "opacity": 0.9},
	"gem": {"color": "4fc3f7", "kind": "jelly", "rough": 0.03, "opacity": 0.55},
	"gem_red": {"color": "ff2d55", "kind": "jelly", "rough": 0.03, "opacity": 0.55},
	"gem_blue": {"color": "2d8cff", "kind": "jelly", "rough": 0.03, "opacity": 0.55},
	"gem_green": {"color": "2dd36f", "kind": "jelly", "rough": 0.03, "opacity": 0.55},
	"gem_pink": {"color": "ff6fd8", "kind": "jelly", "rough": 0.03, "opacity": 0.55},
	"pearl": {"color": "fbf3ea", "kind": "plastic", "rough": 0.15},
	"glow": {"color": "ffd96a", "kind": "neon"},
	"leather": {"color": "7a4a2b", "kind": "plastic", "rough": 0.6},
	"wood": {"color": "b07a4a", "kind": "wood", "rough": 0.4},
	"rubber": {"color": "2b2a30", "kind": "plastic", "rough": 0.85},
	"screen": {"color": "9fd8ff", "kind": "neon"},
	"eye_black": {"color": "0b0a0d", "kind": "plastic", "rough": 0.08},
	"eye_white": {"color": "fbfbfb", "kind": "plastic", "rough": 0.25},
	"tongue": {"color": "ff6f8e", "kind": "plastic", "rough": 0.4},
	"tooth": {"color": "fbfbf6", "kind": "plastic", "rough": 0.25},
	"mouth_inside": {"color": "5a1f2a", "kind": "plastic", "rough": 0.6},
	"beak": {"color": "ffb02e", "kind": "plastic", "rough": 0.3},
	"blush_mark": {"color": "ff8fab", "kind": "plastic", "rough": 0.6},
}

const LINES := {
	LOVE: ["Je l'adore !!", "C'est trop moi !", "Wahou, merci !!", "Je ne l'enlève plus jamais !"],
	LIKE: ["J'aime bien !", "Pas mal du tout.", "Ça me va bien, non ?", "Sympa !"],
	NEUTRAL: ["Hmm... ok.", "Pourquoi pas.", "C'est... un choix."],
	DISLIKE: ["Bof...", "Mouais...", "C'est pas trop mon style."],
	HATE: ["Beurk ! Enlève ça !", "Non non non !", "Je déteste ça !"],
	"fav_color": ["Oh, ma couleur préférée !", "Cette couleur, j'adore !"],
	"pet": ["Hihi !", "Encore !", "Ronron...", "Trop doux !", "Ça chatouille !"],
	"poke": ["Hey !", "Oh !", "Coucou !", "Hi !"],
	"wake": ["Bien dormi !", "Hmm... déjà ?", "Je suis là !"],
	"welcome_back": ["Te revoilà !", "Tu m'as manqué !", "Coucou toi !"],
	"work": ["Au boulot !", "On bosse dur !", "Concentration...", "Tu gères !"],
	"game": ["On joue ? Allez !", "Gagne pour moi !", "Trop fort !"],
	"break": ["Petite pause ? Bois un peu d'eau !", "Ça fait longtemps... étire-toi un peu !"],
	"carry": ["Wiii !", "Je vole !", "Haha !"],
	"carry_no": ["Pose-moi !", "Aaah !", "J'ai le vertige !"],
	"coins": ["Des pièces !", "Cha-ching !", "On s'enrichit !"],
	"hello": ["Coucou ! Je m'installe ici.", "Salut ! On travaille ensemble ?"],
	"grumpy": ["Grr... ce truc...", "Toujours ce truc sur la tête...", "Hmpf."],
	"hungry_attention": ["Tu me caresses un peu ?", "Je m'ennuie..."],
	"hungry": ["J'ai faim... glisse-moi un fichier !", "Mon ventre gargouille...", "Tu as des vieux fichiers à me donner ?"],
	"bored": ["On joue ? Lance-moi !", "Je m'ennuie un peu...", "Un câlin ?"],
	"full": ["Je n'ai plus faim !", "Je suis plein !", "Plus de place dans mon ventre !"],
	"yum": ["Miam !", "Délicieux !", "Encore !", "Crunch crunch..."],
	"yum_love": ["MIAM ! Mon préféré !", "C'est trop bon !!", "Je l'adore !"],
	"yum_meh": ["Bof, ça...", "Pas trop mon truc...", "Beurk, mais j'avais faim..."],
}

var species_anchors := {}


func _ready() -> void:
	species_anchors = _load_json("res://data/species.json", {})
	ITEMS = _load_json("res://data/accessories.json", FALLBACK_ITEMS)
	var face: Dictionary = _load_json("res://data/face.json", {})
	EYES = face.get("eyes", FALLBACK_EYES)
	MOUTHS = face.get("mouths", FALLBACK_MOUTHS)


func _load_json(path: String, fallback: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(path):
		return fallback
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY or d.is_empty():
		return fallback
	return d


func anchors(species_id: String) -> Dictionary:
	return species_anchors.get(species_id, {})


func color_of(name_or_hex: String) -> Color:
	if PALETTE.has(name_or_hex):
		return Color.html(PALETTE[name_or_hex])
	if FUR_PALETTE.has(name_or_hex):
		return Color.html(FUR_PALETTE[name_or_hex])
	if Color.html_is_valid(name_or_hex):
		return Color.html(name_or_hex)
	return Color.WHITE


## Nom de palette le plus proche (pour la couleur preferee).
func nearest_palette_name(c: Color) -> String:
	var best := ""
	var best_d := INF
	for k in PALETTE:
		var p := Color.html(PALETTE[k])
		var d := Vector3(p.r - c.r, p.g - c.g, p.b - c.b).length_squared()
		if d < best_d:
			best_d = d
			best = k
	return best


## Niveau de preference (-2..2) d'une espece pour un accessoire dans une couleur donnee.
func preference(species_id: String, item_id: String, main_color: Color) -> int:
	var sp: Dictionary = SPECIES.get(species_id, {})
	var prefs: Dictionary = sp.get("prefs", {})
	var level: int
	if prefs.has(item_id):
		level = prefs[item_id]
	else:
		# gout "cache" mais stable pour les accessoires sans avis explicite
		var h := absi(hash(species_id + ":" + item_id)) % 10
		level = [LIKE, LIKE, LIKE, NEUTRAL, NEUTRAL, NEUTRAL, LOVE, DISLIKE, DISLIKE, HATE][h]
	if is_fav_color(species_id, main_color):
		level = mini(level + 1, LOVE)
	return level


func is_fav_color(species_id: String, c: Color) -> bool:
	var sp: Dictionary = SPECIES.get(species_id, {})
	return nearest_palette_name(c) == sp.get("fav_color", "")


func pref_label(level: int) -> String:
	match level:
		LOVE: return "Adore"
		LIKE: return "Aime"
		DISLIKE: return "N'aime pas"
		HATE: return "Déteste"
	return "Bof"


func line(key) -> String:
	var arr: Array = LINES.get(key, [""])
	return arr[randi() % arr.size()]


# =========================================================================== jeu : nourriture, quetes, niveaux
## Nourriture selon le type de fichier mange.
const FOODS := {
	"fruit": {"name": "Fruit", "exts": ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "svg", "ico", "psd"]},
	"pain": {"name": "Pain", "exts": ["txt", "md", "pdf", "doc", "docx", "odt", "rtf", "csv", "xls", "xlsx", "ppt", "pptx", "json", "log", "xml", "html"]},
	"bonbon": {"name": "Bonbon", "exts": ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso"]},
	"burger": {"name": "Burger", "exts": ["exe", "msi", "dmg", "apk", "appx", "msix", "bat", "cmd"]},
	"gateau": {"name": "Gâteau", "exts": ["mp4", "mkv", "mov", "avi", "webm", "mp3", "wav", "flac", "ogg", "m4a"]},
	"snack": {"name": "Petit snack", "exts": []},
}
## Gouts de chaque espece pour la nourriture : 2 adore, 1 aime, -1 n'aime pas.
const FOOD_PREFS := {
	"mochi": {"fruit": 2, "gateau": 1, "burger": -1},
	"pico": {"pain": 2, "fruit": 1, "burger": -1, "bonbon": -1},
	"coco": {"gateau": 2, "bonbon": 1, "pain": -1},
	"nuage": {"fruit": 2, "pain": 1, "burger": -1},
	"kiwi": {"burger": 2, "bonbon": 2, "fruit": -1},
}
## Niveau requis pour chaque espece.
const SPECIES_LEVEL := {"mochi": 1, "pico": 2, "kiwi": 3, "coco": 5, "nuage": 7}
## Quetes du jour (3 tirees au hasard chaque jour). %s = nom du compagnon.
const QUEST_POOL := [
	{"id": "feed3", "kind": "feed", "goal": 3, "text": "Nourris %s 3 fois", "coins": 40, "xp": 40},
	{"id": "files10", "kind": "feed_files", "goal": 10, "text": "Fais manger 10 fichiers à %s", "coins": 60, "xp": 60},
	{"id": "pet5", "kind": "pet", "goal": 5, "text": "Fais 5 câlins à %s", "coins": 30, "xp": 35},
	{"id": "work60", "kind": "work_min", "goal": 60, "text": "Travaille 60 minutes avec %s", "coins": 50, "xp": 50},
	{"id": "game30", "kind": "game_min", "goal": 30, "text": "Joue 30 minutes avec %s", "coins": 40, "xp": 40},
	{"id": "throw3", "kind": "throw", "goal": 3, "text": "Lance %s en l'air 3 fois", "coins": 25, "xp": 30},
	{"id": "poke10", "kind": "poke", "goal": 10, "text": "Fais coucou à %s 10 fois (clic)", "coins": 20, "xp": 25},
	{"id": "outfit", "kind": "outfit", "goal": 1, "text": "Change la tenue de %s", "coins": 25, "xp": 30},
	{"id": "climb", "kind": "climb", "goal": 2, "text": "%s doit grimper 2 fois sur une fenêtre", "coins": 30, "xp": 35},
]


## XP necessaire pour passer du niveau `lv` au suivant.
func xp_for_next(lv: int) -> int:
	return int(80.0 * pow(float(lv), 1.45))


## Recompenses en atteignant le niveau `lv` : [{type, value, text}]
func level_rewards(lv: int) -> Array:
	var out: Array = [{"type": "coins", "value": 40 + lv * 20, "text": "+%d pièces" % (40 + lv * 20)}]
	for sp in SPECIES_LEVEL:
		if int(SPECIES_LEVEL[sp]) == lv:
			out.append({"type": "species", "value": sp, "text": "%s est débloqué !" % SPECIES[sp]["name"]})
	if lv % 4 == 0:
		out.append({"type": "gift", "value": "", "text": "Un accessoire cadeau !"})
	return out


func food_kind(path: String) -> String:
	var ext := path.get_extension().to_lower()
	for k in FOODS:
		if (FOODS[k]["exts"] as Array).has(ext):
			return k
	return "snack"


func food_pref(species_id: String, kind: String) -> int:
	var d: Dictionary = FOOD_PREFS.get(species_id, {})
	return int(d.get(kind, 0))
