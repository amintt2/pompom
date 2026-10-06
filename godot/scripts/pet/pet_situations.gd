class_name PetSituations
extends Node
## Le compagnon imite ce que fait l'utilisateur (voir Situations.detect) : il lit une lettre en suivant
## ton curseur des yeux pendant que tu lis tes mails, il tape sur son petit ordi quand tu codes, il bat la
## mesure avec un casque quand tu ecoutes de la musique...
##
## Pilote un Pet uniquement par son API publique (props, expressions, look, tweens sur hop/squash/lean...).
## Chaque situation = une boucle de "micro-actions" ponderees et aleatoires (pas de boucle visible),
## avec des objets (props_extra.glb) qui apparaissent / disparaissent en douceur.
##
## Utilisation (DesktopController) :
##   var situations := PetSituations.new()
##   add_child(situations)                    # enfant du controleur : son _process passe apres le sien
##   situations.setup(pet, stage)
##   situations.say_callback = func(t): _say(t)   # phrases rares (limitees : une toutes les 4 min max)
##   situations.play("email_read", 40.0)      # -> true si la situation est jouee
##   situations.stop()                        # arret immediat (le controleur l'appelle quand on l'attrape)
## Toute action du Pet (act_*, stop_action) interrompt aussi la situation automatiquement.

signal started(sid: String)
signal finished(sid: String)  # fin normale de la session (duree ecoulee)
signal interrupted(sid: String)  # stop() ou une autre action du compagnon
signal move_started(sid: String, move: String)  # chaque micro-action (debug / tests)

const PROPS_GLB := "res://assets/models/props_extra.glb"
const LEGACY_PROPS := ["laptop", "gamepad", "mug", "phone", "popcorn"]
## Agrandissement des objets de props_extra.glb selon leur ancrage.
const SIZE_BY_ANCHOR := {"hold": 1.5, "head": 2.0, "ground_r": 1.6, "ground_l": 1.6, "ground_f": 1.6}

## Couleurs des materiaux propres a props_extra.glb : nom -> [couleur, rugosite].
const PROP_COLORS := {
	"paper": ["fffaf0", 0.75], "news": ["ece8de", 0.8], "ink": ["3a3550", 0.45], "gray": ["aeacb9", 0.6],
	"red": ["ff5a6e", 0.38], "pink": ["ff8fbf", 0.42], "yellow": ["ffd45c", 0.42], "orange": ["ff9f45", 0.42],
	"green": ["6fd08c", 0.42], "mint": ["9ff0d0", 0.45], "sky": ["7cc8ff", 0.42], "blue": ["4f8dff", 0.4],
	"navy": ["3d4f8f", 0.45], "purple": ["a77bff", 0.42], "lilac": ["cdb8ff", 0.5], "kraft": ["d9b68a", 0.7],
	"sand": ["f2cf7a", 0.6], "coffee": ["5a3219", 0.2], "cream": ["fff1dc", 0.5],
}

# ---------------------------------------------------------------------------------------------------
# Comportements. Champs :
#   props   : [{id, at, pos, rot (degres), scale, paws}]  at = hold (tenu devant lui, suit ses mouvements)
#             | ground_r / ground_l / ground_f (pose au sol a droite / gauche / devant) | head (au-dessus)
#   wear    : accessoires portes le temps de la situation (seulement si l'emplacement est libre)
#   expr    : expression de base ; yaw : orientation du corps ; look : regard par defaut
#   gaze    : fixed | cursor (suit le curseur de l'utilisateur) | wander
#   moves   : micro-actions ponderees ; first : micro-action jouee en premier
#   pace    : pause entre deux micro-actions [min, max] ; breath : amplitude de respiration
#   silent  : aucune phrase ; no_emotes : aucune emotion dessinee
const BEHAVIOURS := {
	"email_read": {"props": [{"id": "letter", "at": "hold", "pos": Vector3(0, 0.22, 0), "rot": Vector3(8, 0, -3), "scale": 0.85,
			"paws": [Vector3(-0.14, -0.03, 0.01), Vector3(0.14, -0.03, 0.01)]}],
		"expr": "neutral", "gaze": "cursor", "look": Vector2(0, -0.3), "first": "read",
		"moves": {"read": 6.0, "nod": 1.5, "glance": 1.0, "mail_wiggle": 1.0, "think": 0.5}, "pace": [0.3, 1.0]},
	"email_write": {"props": [{"id": "keyboard", "at": "ground_f", "pos": Vector3(0, 0.035, 0.1), "rot": Vector3(45, 0, 0)}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.65), "first": "type",
		"moves": {"type": 6.0, "think": 1.0, "glance": 0.6, "send": 0.9}, "pace": [0.2, 0.9]},
	"coding": {"props": [{"id": "laptop", "at": "ground_r", "pos": Vector3(0.24, 0, 0.18), "rot": Vector3(0, -54.4, 0), "scale": 1.2}],
		"wear": ["nerd_glasses"], "expr": "focused", "yaw": 0.4, "gaze": "fixed", "look": Vector2(0.35, -0.5),
		"first": "type", "moves": {"type": 6.0, "think": 1.4, "bulb": 0.6, "glance": 0.6, "nod": 0.5}, "pace": [0.2, 1.0]},
	"ai_agent": {"props": [{"id": "laptop", "at": "ground_r", "pos": Vector3(0.24, 0, 0.18), "rot": Vector3(0, -54.4, 0), "scale": 1.2},
			{"id": "mug_coffee", "at": "ground_l", "pos": Vector3(0.1, 0, 0.16), "rot": Vector3(0, 30, 0)}],
		"wear": ["round_glasses"], "expr": "neutral", "yaw": 0.3, "gaze": "fixed", "look": Vector2(0.35, -0.3),
		"first": "think", "moves": {"watch": 5.0, "sip": 1.4, "think": 1.2, "type": 1.0, "nod": 1.4, "cheer_small": 0.5},
		"pace": [0.5, 1.6]},
	"terminal": {"props": [{"id": "keyboard", "at": "ground_f", "pos": Vector3(0, 0.035, 0.1), "rot": Vector3(45, 0, 0)}],
		"wear": ["sunglasses"], "expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.6), "first": "fast_type",
		"moves": {"fast_type": 6.0, "pause": 1.0, "nod": 0.5, "glance": 0.4}, "pace": [0.15, 0.7]},
	"ai_chat": {"props": [{"id": "keyboard", "at": "ground_f", "pos": Vector3(0, 0.035, 0.1), "rot": Vector3(45, 0, 0)}],
		"expr": "neutral", "gaze": "fixed", "look": Vector2(0, -0.5), "first": "think",
		"moves": {"type": 3.0, "think": 2.0, "bulb": 1.0, "nod": 1.0, "glance": 0.6}, "pace": [0.3, 1.2]},
	"writing_doc": {"props": [{"id": "notepad", "at": "hold", "pos": Vector3(-0.03, 0.23, 0), "rot": Vector3(10, 0, 6),
			"paws": [Vector3(-0.115, -0.07, 0.0)]},
			{"id": "pencil", "at": "hold", "pos": Vector3(0.03, 0.22, 0.035), "rot": Vector3(-10, 0, -32),
			"paws": [Vector3(0, 0.1, 0.0)]}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0.05, -0.6), "first": "scribble",
		"moves": {"scribble": 5.0, "think": 1.0, "glance": 0.6, "nod": 0.5}, "pace": [0.2, 0.9]},
	"spreadsheet": {"props": [{"id": "calculator", "at": "hold", "pos": Vector3(0, 0.23, 0), "rot": Vector3(10, 0, -6),
			"paws": [Vector3(-0.08, -0.06, 0.0), Vector3(0.08, -0.06, 0.0)]}],
		"wear": ["round_glasses"], "expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.6), "first": "calc",
		"moves": {"calc": 5.0, "think": 1.0, "nod": 1.0, "glance": 0.5}, "pace": [0.2, 0.9]},
	"slides": {"props": [{"id": "easel", "at": "ground_r", "pos": Vector3(0.1, 0, 0.08), "rot": Vector3(0, -30, 0)}],
		"expr": "happy", "yaw": 0.45, "gaze": "fixed", "look": Vector2(0.55, 0.15), "first": "point",
		"moves": {"point": 3.0, "nod": 1.0, "glance": 1.5, "bulb": 0.3}, "pace": [0.6, 1.6]},
	"design": {"props": [{"id": "palette", "at": "hold", "pos": Vector3(-0.15, 0.19, 0), "rot": Vector3(10, 0, 12),
			"paws": [Vector3(-0.12, -0.03, 0.0)]},
			{"id": "paintbrush", "at": "hold", "pos": Vector3(0.18, 0.25, 0.03), "rot": Vector3(0, 0, -28),
			"paws": [Vector3(0, -0.07, 0.0)]}],
		"wear": ["beret"], "expr": "happy", "gaze": "fixed", "look": Vector2(0.2, -0.35), "first": "brush",
		"moves": {"brush": 5.0, "think": 1.0, "glance": 0.7}, "pace": [0.3, 1.0]},
	"modeling_3d": {"props": [{"id": "cube3d", "at": "hold", "pos": Vector3(0, 0.29, 0.06), "rot": Vector3(18, 32, 0)}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.25), "first": "rotate_cube",
		"moves": {"rotate_cube": 5.0, "think": 1.0, "nod": 0.5, "bulb": 0.3}, "pace": [0.4, 1.2]},
	"video_edit": {"props": [{"id": "clapper", "at": "hold", "pos": Vector3(0, 0.20, 0), "rot": Vector3(8, 0, 0),
			"paws": [Vector3(-0.1, -0.06, 0.0), Vector3(0.1, -0.06, 0.0)]}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.3), "first": "clap",
		"moves": {"clap": 2.0, "pause": 2.0, "think": 1.0, "nod": 1.0}, "pace": [0.5, 1.4]},
	"music_listen": {"props": [], "wear": ["headphones"], "expr": "happy", "gaze": "fixed", "look": Vector2(0, 0.05),
		"first": "bob", "moves": {"bob": 8.0, "sway": 2.0, "glance": 1.0}, "pace": [0.0, 0.4]},
	"music_make": {"props": [{"id": "synth", "at": "ground_f", "pos": Vector3(0, 0.04, 0.1), "rot": Vector3(45, 0, 0)}],
		"wear": ["headphones"], "expr": "happy", "gaze": "fixed", "look": Vector2(0, -0.6), "first": "key",
		"moves": {"key": 5.0, "bob": 2.0, "think": 0.5}, "pace": [0.1, 0.6]},
	"podcast": {"props": [], "wear": ["headphones"], "expr": "neutral", "gaze": "fixed", "look": Vector2(0.25, 0.2),
		"first": "sway", "moves": {"sway": 3.0, "nod": 2.0, "think": 1.0, "pause": 2.0}, "pace": [0.5, 1.5]},
	"chat": {"props": [{"id": "phone", "at": "hold", "pos": Vector3(0.1, 0.25, 0.02), "rot": Vector3(-20, 200, 7), "scale": 1.8,
			"paws": [Vector3(-0.06, -0.06, 0.0), Vector3(0.06, -0.06, 0.0)]}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0.15, -0.55), "first": "tap",
		"moves": {"tap": 5.0, "laugh": 1.0, "glance": 1.0, "pause": 1.0}, "pace": [0.2, 0.9]},
	"social_scroll": {"props": [{"id": "phone", "at": "hold", "pos": Vector3(0.1, 0.25, 0.02), "rot": Vector3(-20, 200, 7), "scale": 1.8,
			"paws": [Vector3(-0.06, -0.06, 0.0), Vector3(0.06, -0.06, 0.0)]}],
		"expr": "neutral", "gaze": "fixed", "look": Vector2(0.15, -0.55), "first": "flick",
		"moves": {"flick": 6.0, "laugh": 1.2, "surprise": 0.4, "glance": 0.8, "heart": 0.5}, "pace": [0.3, 1.1]},
	"shopping": {"props": [{"id": "shopping_bag", "at": "ground_l", "pos": Vector3(0.1, 0, 0.12), "rot": Vector3(0, 25, 0)}],
		"expr": "happy", "gaze": "cursor", "look": Vector2(0, 0), "first": "want",
		"moves": {"want": 2.0, "nod": 1.0, "scan": 1.0, "pause": 2.0, "glance": 1.0}, "pace": [0.5, 1.5]},
	"reading": {"props": [{"id": "book", "at": "hold", "pos": Vector3(0, 0.24, 0), "rot": Vector3(6, 0, 0), "scale": 0.85,
			"paws": [Vector3(-0.17, -0.06, 0.02), Vector3(0.17, -0.06, 0.02)]}],
		"expr": "neutral", "gaze": "fixed", "look": Vector2(0, -0.55), "first": "read",
		"moves": {"read": 4.0, "page": 2.0, "nod": 0.5, "glance": 0.5}, "pace": [0.3, 1.0]},
	"news": {"props": [{"id": "newspaper", "at": "hold", "pos": Vector3(0, 0.22, 0), "rot": Vector3(8, 0, 0), "scale": 0.85,
			"paws": [Vector3(-0.155, -0.05, 0.0), Vector3(0.155, -0.05, 0.0)]}],
		"wear": ["monocle"], "expr": "neutral", "gaze": "fixed", "look": Vector2(0, -0.5), "first": "read",
		"moves": {"read": 4.0, "fold": 1.5, "surprise": 0.3, "nod": 0.7}, "pace": [0.3, 1.0]},
	"studying": {"props": [{"id": "book", "at": "hold", "pos": Vector3(0, 0.24, 0), "rot": Vector3(6, 0, 0), "scale": 0.85,
			"paws": [Vector3(-0.17, -0.06, 0.02), Vector3(0.17, -0.06, 0.02)]}],
		"wear": ["round_glasses"], "expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.5), "first": "bulb",
		"moves": {"read": 3.0, "page": 1.5, "bulb": 1.5, "think": 1.5, "nod": 0.6}, "pace": [0.3, 1.0]},
	"maps": {"props": [{"id": "map", "at": "hold", "pos": Vector3(0, 0.22, 0), "rot": Vector3(8, 0, 0), "scale": 0.85,
			"paws": [Vector3(-0.165, -0.05, 0.0), Vector3(0.165, -0.05, 0.0)]}],
		"expr": "happy", "gaze": "fixed", "look": Vector2(0, -0.45), "first": "map_trace",
		"moves": {"map_trace": 3.0, "think": 1.0, "glance": 1.0, "surprise": 0.3}, "pace": [0.4, 1.2]},
	"finance": {"props": [{"id": "coins", "at": "ground_r", "pos": Vector3(-0.02, 0, 0.26), "rot": Vector3(0, -20, 0)}],
		"wear": ["round_glasses"], "expr": "focused", "yaw": 0.2, "gaze": "fixed", "look": Vector2(0.3, -0.6),
		"first": "count", "moves": {"count": 4.0, "nod": 1.0, "pause": 2.0}, "pace": [0.5, 1.4], "silent": true,
		"no_emotes": true},
	"private": {"props": [], "expr": "happy", "yaw": -0.45, "gaze": "fixed", "look": Vector2(-0.5, 0.7),
		"first": "not_looking", "moves": {"not_looking": 2.0, "pause": 3.0}, "pace": [0.8, 2.0], "silent": true,
		"no_emotes": true},
	"calendar": {"props": [{"id": "calendar", "at": "ground_r", "pos": Vector3(0.06, 0, 0.16), "rot": Vector3(0, -32, 0)}],
		"expr": "neutral", "yaw": 0.45, "gaze": "fixed", "look": Vector2(0.45, -0.35), "first": "think",
		"moves": {"nod": 1.0, "think": 1.5, "glance": 1.0, "pause": 2.0}, "pace": [0.5, 1.5]},
	"todo": {"props": [{"id": "notepad", "at": "hold", "pos": Vector3(-0.03, 0.23, 0), "rot": Vector3(10, 0, 6),
			"paws": [Vector3(-0.115, -0.07, 0.0)]},
			{"id": "pencil", "at": "hold", "pos": Vector3(0.03, 0.22, 0.035), "rot": Vector3(-10, 0, -32),
			"paws": [Vector3(0, 0.1, 0.0)]}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0.0, -0.6), "first": "check",
		"moves": {"check": 3.0, "scribble": 2.0, "nod": 1.0, "glance": 0.5}, "pace": [0.3, 1.0]},
	"files": {"props": [{"id": "folder", "at": "hold", "pos": Vector3(0, 0.20, 0), "rot": Vector3(8, 0, 0),
			"paws": [Vector3(-0.125, -0.05, 0.0), Vector3(0.125, -0.05, 0.0)]}],
		"expr": "neutral", "gaze": "cursor", "look": Vector2(0, -0.3), "first": "rummage",
		"moves": {"rummage": 3.0, "think": 1.0, "nod": 1.0, "glance": 1.0}, "pace": [0.4, 1.2]},
	"installing": {"props": [{"id": "hourglass", "at": "ground_r", "pos": Vector3(0.04, 0.095, 0.2), "rot": Vector3(0, -15, 0)}],
		"expr": "neutral", "yaw": 0.35, "gaze": "fixed", "look": Vector2(0.45, -0.3), "first": "wait",
		"moves": {"wait": 3.0, "flip": 1.5, "yawn": 0.5, "glance": 1.0}, "pace": [0.5, 1.5]},
	"game_launcher": {"props": [{"id": "gamepad", "at": "hold", "pos": Vector3(0, 0.21, 0.04), "rot": Vector3(52, 0, 0),
			"paws": [Vector3(-0.15, -0.03, 0.0), Vector3(0.15, -0.03, 0.0)]}],
		"expr": "happy", "gaze": "cursor", "look": Vector2(0, -0.2), "first": "excited",
		"moves": {"excited": 2.0, "glance": 1.5, "pause": 1.0}, "pace": [0.5, 1.4]},
	"gaming": {"delegate": "gaming", "props": [], "moves": {}},
	"streaming": {"props": [{"id": "mic", "at": "ground_r", "pos": Vector3(0.0, 0, 0.24), "rot": Vector3(0, -20, 0)}],
		"expr": "happy", "gaze": "fixed", "look": Vector2(0, 0.1), "first": "pose",
		"moves": {"wave": 1.0, "pose": 1.0, "pause": 3.0, "glance": 2.0}, "pace": [0.8, 2.0], "silent": true},
	"meeting": {"props": [], "expr": "focused", "gaze": "fixed", "look": Vector2(0, 0.2), "first": "nod",
		"moves": {"nod": 1.0, "pause": 4.0}, "pace": [1.0, 3.0], "silent": true, "no_emotes": true},
	"video_watch": {"props": [{"id": "popcorn", "at": "ground_l", "pos": Vector3(0.06, 0, 0.12), "scale": 1.25}],
		"expr": "happy", "yaw": 2.5, "gaze": "fixed", "look": Vector2(0, 0.35), "first": "munch",
		"moves": {"munch": 3.0, "pause": 3.0, "laugh": 0.5, "turn_glance": 0.6}, "pace": [0.8, 2.2]},
	"movie": {"props": [{"id": "popcorn", "at": "ground_l", "pos": Vector3(0.06, 0, 0.12), "scale": 1.25},
			{"id": "soda", "at": "ground_r", "pos": Vector3(0.06, 0, 0.1)}],
		"expr": "happy", "yaw": 2.6, "gaze": "fixed", "look": Vector2(0, 0.35), "first": "munch",
		"moves": {"munch": 3.0, "pause": 4.0, "surprise": 0.3, "turn_glance": 0.4}, "pace": [1.0, 2.4]},
	"stream_watch": {"props": [{"id": "pennant", "at": "hold", "pos": Vector3(0.22, 0.15, -0.05), "rot": Vector3(0, 0, -14),
			"paws": [Vector3(0, 0.03, 0.0)]},
			{"id": "popcorn", "at": "ground_l", "pos": Vector3(0.06, 0, 0.12), "scale": 1.25}],
		"expr": "happy", "yaw": 1.2, "gaze": "fixed", "look": Vector2(0, 0.35), "first": "cheer",
		"moves": {"cheer": 1.5, "pause": 3.0, "munch": 1.0, "turn_glance": 0.6}, "pace": [0.8, 2.0]},
	"settings": {"props": [{"id": "wrench", "at": "hold", "pos": Vector3(0.14, 0.23, 0.02), "rot": Vector3(0, 0, -30),
			"paws": [Vector3(0, -0.075, 0.0)]}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0.3, -0.3), "first": "wrench",
		"moves": {"wrench": 3.0, "think": 1.0, "nod": 1.0}, "pace": [0.4, 1.2]},
	"chess": {"props": [{"id": "chessboard", "at": "ground_f", "pos": Vector3(0, 0.05, 0.14), "rot": Vector3(50, 0, 0)}],
		"expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.6), "first": "think",
		"moves": {"think": 2.0, "chess_move": 1.5, "pause": 1.5, "bulb": 0.5}, "pace": [0.5, 1.4]},
	"photos": {"props": [{"id": "camera", "at": "hold", "pos": Vector3(0, 0.26, 0.02), "rot": Vector3(-4, 0, 0), "scale": 1.3,
			"paws": [Vector3(-0.085, -0.02, 0.0), Vector3(0.085, -0.02, 0.0)]}],
		"expr": "happy", "gaze": "cursor", "look": Vector2(0, 0), "first": "snap",
		"moves": {"snap": 2.0, "glance": 1.0, "pause": 1.5}, "pace": [0.5, 1.4]},
	"weather": {"props": [{"id": "sun_cloud", "at": "head", "pos": Vector3(0.32, 0.08, 0)}],
		"expr": "happy", "gaze": "fixed", "look": Vector2(0.35, 0.7), "first": "look_up",
		"moves": {"look_up": 2.0, "pause": 2.0, "glance": 1.0}, "pace": [0.6, 1.6]},
	"food": {"props": [{"id": "cupcake", "at": "hold", "pos": Vector3(0, 0.12, 0.02), "scale": 1.3,
			"paws": [Vector3(-0.055, 0.03, 0.0), Vector3(0.055, 0.03, 0.0)]}],
		"expr": "happy", "gaze": "fixed", "look": Vector2(0, -0.45), "first": "drool",
		"moves": {"drool": 2.0, "smell": 1.5, "pause": 1.5, "glance": 1.0}, "pace": [0.5, 1.4]},
	"sports": {"props": [{"id": "pennant", "at": "hold", "pos": Vector3(0.22, 0.15, 0.0), "rot": Vector3(0, 0, -14), "scale": 1.2,
			"paws": [Vector3(0, 0.03, 0.0)]}],
		"expr": "happy", "gaze": "cursor", "look": Vector2(0, 0.1), "first": "cheer",
		"moves": {"cheer": 2.0, "pause": 2.0, "glance": 1.0}, "pace": [0.5, 1.4]},
	"job_hunt": {"props": [{"id": "notepad", "at": "hold", "pos": Vector3(-0.03, 0.23, 0), "rot": Vector3(10, 0, 6),
			"paws": [Vector3(-0.115, -0.07, 0.0)]},
			{"id": "pencil", "at": "hold", "pos": Vector3(0.03, 0.22, 0.035), "rot": Vector3(-10, 0, -32),
			"paws": [Vector3(0, 0.1, 0.0)]}],
		"wear": ["necktie"], "expr": "focused", "gaze": "fixed", "look": Vector2(0, -0.55), "first": "pose",
		"moves": {"scribble": 2.0, "nod": 1.5, "glance": 1.0, "pose": 1.0}, "pace": [0.4, 1.2]},
	"paperwork": {"props": [{"id": "notepad", "at": "hold", "pos": Vector3(-0.06, 0.23, 0), "rot": Vector3(10, 0, 6),
			"paws": [Vector3(-0.115, -0.07, 0.0)]},
			{"id": "stamp", "at": "hold", "pos": Vector3(0.2, 0.25, 0.06), "rot": Vector3(0, 0, -6),
			"paws": [Vector3(0, 0.1, 0.0)]}],
		"wear": ["round_glasses"], "expr": "meh", "gaze": "fixed", "look": Vector2(0, -0.55), "first": "stamp",
		"moves": {"stamp": 2.0, "sigh": 1.0, "pause": 1.0, "nod": 0.6}, "pace": [0.4, 1.2]},
	"dating": {"props": [{"id": "rose", "at": "hold", "pos": Vector3(0.14, 0.17, 0.0), "rot": Vector3(0, 0, -12),
			"paws": [Vector3(0, 0.03, 0.0)]}],
		"expr": "love", "gaze": "fixed", "look": Vector2(-0.35, -0.4), "first": "shy",
		"moves": {"shy": 2.0, "pause": 2.0, "smell": 1.0}, "pace": [0.6, 1.6], "silent": true},
	"searching": {"props": [{"id": "magnifier", "at": "hold", "pos": Vector3(0.18, 0.28, 0.05), "rot": Vector3(0, 0, 8),
			"paws": [Vector3(0.075, -0.11, 0.0)]}],
		"expr": "focused", "gaze": "cursor", "look": Vector2(0, 0), "first": "magnify",
		"moves": {"scan": 2.0, "magnify": 1.5, "think": 1.0, "pause": 1.0}, "pace": [0.4, 1.2]},
	"browsing": {"props": [], "expr": "neutral", "gaze": "cursor", "look": Vector2(0, 0), "first": "follow",
		"moves": {"follow": 4.0, "nod": 1.0, "glance": 1.0, "wiggle": 0.5}, "pace": [0.6, 1.6]},
	"afk": {"props": [], "expr": "meh", "gaze": "wander", "look": Vector2(0, 0), "first": "look_around",
		"moves": {"look_around": 2.0, "yawn": 1.0, "pause": 3.0, "sigh": 1.0}, "pace": [0.8, 2.0], "breath": 1.4},
	"late_night": {"props": [{"id": "mug_coffee", "at": "ground_l", "pos": Vector3(0.1, 0, 0.16), "rot": Vector3(0, 30, 0)}],
		"expr": "meh", "gaze": "cursor", "look": Vector2(0, 0), "first": "yawn",
		"moves": {"sip": 2.0, "yawn": 1.5, "doze": 1.5, "pause": 2.0}, "pace": [0.6, 1.6], "breath": 1.5},
}

var pet: Pet
var stage: PetStage
## Phrases (francais) : func(text: String). Limitees a une toutes les `talk_cooldown` secondes.
var say_callback: Callable
var talk_cooldown := 240.0
var talk_chance := 0.3
## true : suit Activity tout seul pendant une session (change de situation quand la fenetre / l'onglet change).
var follow_activity := false
## Le controleur peut refuser un changement automatique (ex. en plein jeu) : func(sid) -> bool.
var can_switch: Callable
## Mains (petites pattes de la couleur du corps) sur les objets tenus.
var paws_enabled := true

var current := ""
var playing := false

var _spec: Dictionary = {}
var _token := 0
var _owned_act := -1
var _tweens: Array[Tween] = []
var _props := {}  # id -> Node3D
var _prop_base := {}  # id -> Transform3D (pose de repos)
var _temps: Array = []
var _worn: Array = []
var _reg: Array = []  # materiaux enregistres pour les reflets du compagnon
var _saved := {}
var _end_time := 0.0
var _last_talk := -1000.0
var _last_emote := -1000.0
var _cursor_override := Vector2.ZERO
## Point de l'ecran a regarder pendant une video (donne par la vision) ; sinon deduit de la fenetre au premier plan.
var watch_point := Vector2.INF
const WATCH_SIDS := ["video_watch", "movie", "stream_watch"]
var _cursor_override_t := 0.0
var _gaze_override := Vector2.ZERO
var _gaze_override_t := 0.0
var _gaze_off := Vector2.ZERO
var _wander := Vector2.ZERO
var _wander_t := 0.0
var _t := 0.0
var _bpm := 110.0
var _late := false
var _follow_t := 0.0
var _pending_sid := ""
var _pending_t := 0.0
var _last_title := ""
var _title_cd := 0.0
var _checks := 0
var _pawn_moves := 0
var _restore_tween: Tween

static var _extra_root: Node


func setup(p_pet: Pet, p_stage: PetStage = null) -> void:
	pet = p_pet
	stage = p_stage


## Situation correspondant a l'activite actuelle (Activity) ; "" si rien de particulier.
static func situation_for_activity() -> String:
	if not Activity.available:
		return ""
	var hour := int(Time.get_datetime_dict_from_system().get("hour", 12))
	return Situations.detect(Activity.proc_name, Activity.window_title, Activity.category,
		{"idle": Activity.idle_sec, "meeting": Activity.meeting, "hour": hour})


func has_behaviour(sid: String) -> bool:
	return BEHAVIOURS.has(sid)


## Position du curseur (ecran) a suivre des yeux pendant `hold` secondes (sinon : la vraie souris).
## Orientation du corps : celle de la situation, ou tournee vers la video quand il en regarde une.
func _spec_yaw(sid: String, spec: Dictionary) -> float:
	var y := float(spec.get("yaw", 0.0))
	if not WATCH_SIDS.has(sid):
		return y
	var target := video_point()
	if target == Vector2.INF:
		return y
	var me := Vector2(get_window().position) + stage.camera.unproject_position(pet.center_global())
	var toward := Pet.yaw_toward(target, me)
	# meme ecart au "dos" que la situation prevoit, mais du bon cote
	return toward if absf(y) > 1.6 else signf(toward) * absf(y)


## Ou est la video a l'ecran : la vision si elle l'a trouvee, sinon une estimation d'apres la fenetre au premier plan.
func video_point() -> Vector2:
	if watch_point != Vector2.INF:
		return watch_point
	if Activity.windows.is_empty():
		return Vector2.INF
	var r: Rect2 = Activity.windows[0]["rect"]
	if Activity.fullscreen:
		return r.get_center()
	var browsers := ["chrome", "msedge", "firefox", "opera", "brave", "vivaldi", "arc", "zen"]
	if browsers.has(Activity.proc_name):
		# YouTube, Twitch... : le lecteur occupe le haut gauche de la page
		return r.position + Vector2(r.size.x * 0.36, r.size.y * 0.4)
	return r.get_center()


func set_cursor(screen_pos: Vector2, hold := 0.5) -> void:
	_cursor_override = screen_pos
	_cursor_override_t = hold


# =========================================================================== cycle de vie
## Joue une situation pendant `duration` secondes. flavor : {"late": bool} (sinon deduit de l'heure).
## Renvoie false si la situation n'existe pas ou si le compagnon ne peut pas (endormi, porte...).
func play(sid: String, duration := 40.0, flavor := {}) -> bool:
	if pet == null or pet.root_node == null or not BEHAVIOURS.has(sid):
		return false
	if pet.sleeping or pet.carried or pet.airborne:
		return false
	var spec: Dictionary = BEHAVIOURS[sid]
	if spec.has("delegate"):
		if playing:
			stop()
		if spec["delegate"] == "gaming":
			pet.act_gaming(duration)
		return true
	if playing and sid == current:
		_end_time = maxf(_end_time, _now() + duration)
		return true
	_token += 1
	_start(sid, duration, flavor, _token)
	return true


func _start(sid: String, duration: float, flavor: Dictionary, tk: int) -> void:
	var spec: Dictionary = BEHAVIOURS[sid]
	if playing:
		await _clear(false)
		if tk != _token:
			return
	else:
		pet.hide_all_props()
		pet.stop_action()
		var t0 := _now()
		while pet.busy and _now() - t0 < 0.4:
			await get_tree().process_frame
		if tk != _token or pet.carried or pet.sleeping:
			return
		_saved = {"expr": pet.base_expression, "breath": pet.breath_amp}
	if _restore_tween and _restore_tween.is_valid():
		_restore_tween.kill()
	_owned_act = pet._act
	pet.busy = true
	playing = true
	current = sid
	_spec = spec
	_late = bool(flavor.get("late", Situations.is_late(int(Time.get_datetime_dict_from_system().get("hour", 12)))))
	_end_time = _now() + duration
	_bpm = randf_range(92.0, 124.0)
	_checks = 0
	_pawn_moves = 0
	_gaze_off = Vector2.ZERO
	_gaze_override_t = 0.0
	pet.set_base_expression(str(spec.get("expr", "neutral")))
	pet.breath_amp = float(spec.get("breath", 1.0))
	var ty := _tw()
	ty.tween_property(pet, "yaw", _spec_yaw(sid, spec), 0.45).set_trans(Tween.TRANS_SINE)
	for w in spec.get("wear", []):
		_wear(str(w))
	var i := 0
	var list: Array = spec.get("props", []).duplicate()
	if _late and sid not in ["late_night", "ai_agent", "afk", "private", "meeting", "streaming", "video_watch", "movie"]:
		var has_left := false
		for p in list:
			if str(p.get("at", "")) == "ground_l":
				has_left = true
		if not has_left:
			list.append({"id": "mug_coffee", "at": "ground_l", "pos": Vector3(0.1, 0, 0.16), "rot": Vector3(0, 30, 0)})
	for p in list:
		_add_prop(p, 0.07 * i)
		i += 1
	started.emit(sid)
	_maybe_say(sid)
	_loop(tk)


## Arret immediat (attrape, poke, autre action...). smooth : petite transition au lieu d'une coupure.
func stop(smooth := false) -> void:
	_token += 1  # annule aussi un demarrage en attente
	if not playing:
		return
	var sid := current
	_kill_tweens()
	_drop_all(0.12 if not smooth else 0.25)
	_restore(smooth)
	if pet._act == _owned_act:
		pet.busy = false
	interrupted.emit(sid)


func is_playing() -> bool:
	return playing


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _loop(tk: int) -> void:
	var first := str(_spec.get("first", ""))
	while _alive(tk) and _now() < _end_time:
		var m := first if first != "" else _pick()
		first = ""
		if m == "":
			await _wait(1.0)
			continue
		var f := Callable(self, "_m_" + m)
		move_started.emit(current, m)
		if f.is_valid():
			await f.call(tk)
		else:
			await _m_pause(tk)
		if not _alive(tk):
			return
		var pace: Array = _spec.get("pace", [0.4, 1.2])
		await _wait(randf_range(float(pace[0]), float(pace[1])))
	if _alive(tk):
		var sid := current
		_token += 1
		await _clear(true)
		if pet._act == _owned_act:
			pet.busy = false
		finished.emit(sid)


func _pick() -> String:
	var moves: Dictionary = _spec.get("moves", {}).duplicate()
	if _late:
		moves["yawn"] = float(moves.get("yawn", 0.0)) + 0.8
		if _props.has("mug_coffee"):
			moves["sip"] = float(moves.get("sip", 0.0)) + 1.0
	var total := 0.0
	for k in moves:
		total += float(moves[k])
	if total <= 0.0:
		return ""
	var r := randf() * total
	for k in moves:
		r -= float(moves[k])
		if r <= 0.0:
			return k
	return moves.keys()[0]


func _alive(tk: int) -> bool:
	return tk == _token and playing and is_instance_valid(pet)


func _wait(sec: float) -> void:
	await get_tree().create_timer(maxf(sec, 0.01)).timeout


func _tw() -> Tween:
	var t := create_tween()
	_tweens.append(t)
	if _tweens.size() > 24:
		_tweens = _tweens.filter(func(x: Tween): return x.is_valid())
	return t


func _kill_tweens() -> void:
	for t in _tweens:
		if t.is_valid():
			t.kill()
	_tweens.clear()


## Fin de session : les objets disparaissent, il se remet face a toi.
func _clear(smooth: bool) -> void:
	_kill_tweens()
	_drop_all(0.22 if smooth else 0.14)
	_restore(true)
	await _wait(0.25 if smooth else 0.15)


func _restore(smooth: bool) -> void:
	playing = false
	current = ""
	_gaze_off = Vector2.ZERO
	_gaze_override_t = 0.0
	if not _saved.is_empty():
		pet.set_base_expression(str(_saved.get("expr", "neutral")))
		pet.breath_amp = float(_saved.get("breath", 1.0))
	pet.look = Vector2.ZERO
	var t := create_tween().set_parallel(true)
	_restore_tween = t
	var d := 0.3 if smooth else 0.15
	t.tween_property(pet, "yaw", 0.0, d)
	if pet._act == _owned_act:
		for p in ["hop", "squash", "lean", "pitch"]:
			t.tween_property(pet, p, 0.0, d)


func _process(delta: float) -> void:
	_t += delta
	_cursor_override_t -= delta
	if pet == null or pet.root_node == null:
		return
	if follow_activity:
		_follow(delta)
	if not playing:
		return
	# interruption : une autre action a pris la main, on l'attrape, il tombe ou s'endort
	if pet._act != _owned_act or pet.carried or pet.sleeping or pet.airborne:
		stop()
		return
	_update_gaze(delta)
	_animate_props(delta)


func _follow(delta: float) -> void:
	_follow_t -= delta
	_title_cd -= delta
	if _follow_t > 0.0:
		return
	_follow_t = 0.5
	if not Activity.available:
		return
	if playing and current == "ai_agent" and Activity.window_title != _last_title and _last_title != "" \
			and _title_cd <= 0.0 and randf() < 0.35:
		_title_cd = 20.0
		_m_cheer_small(_token)
	_last_title = Activity.window_title
	if not playing:
		_pending_sid = ""
		return
	var sid := situation_for_activity()
	if sid == current:
		_pending_sid = ""
		return
	if sid != _pending_sid:
		_pending_sid = sid
		_pending_t = 1.5
		return
	_pending_t -= 0.5
	if _pending_t > 0.0:
		return
	_pending_sid = ""
	if can_switch.is_valid() and not bool(can_switch.call(sid)):
		return
	if sid == "" or not BEHAVIOURS.has(sid) or sid in ["afk", "gaming", "meeting"]:
		stop(true)
	else:
		play(sid, maxf(_end_time - _now(), 25.0))


# =========================================================================== regard
func _update_gaze(delta: float) -> void:
	var base: Vector2 = _spec.get("look", Vector2.ZERO)
	match str(_spec.get("gaze", "fixed")):
		"cursor":
			var c := _cursor_look()
			# petits balayages de lecture autour du curseur
			base = c + Vector2(sin(_t * 1.7) * 0.05, sin(_t * 0.9) * 0.02)
		"wander":
			_wander_t -= delta
			if _wander_t <= 0.0:
				_wander_t = randf_range(1.5, 3.5)
				_wander = Vector2(randf_range(-0.8, 0.8), randf_range(-0.3, 0.5))
			base = _wander
	if _gaze_override_t > 0.0:
		_gaze_override_t -= delta
		base = _gaze_override
	pet.look = (base + _gaze_off).clamp(Vector2(-1, -1), Vector2(1, 1))


func _cursor_look() -> Vector2:
	var cur := _cursor_override if _cursor_override_t > 0.0 else Vector2(DisplayServer.mouse_get_position())
	var center := Vector2(get_window().position)
	if stage and stage.camera:
		center += stage.camera.unproject_position(pet.center_global())
	var d := cur - center
	return Vector2(clampf(d.x / 520.0, -1.0, 1.0), clampf(-d.y / 320.0, -1.0, 1.0))


func _look_at(v: Vector2, dur: float) -> void:
	_gaze_override = v
	_gaze_override_t = dur


# =========================================================================== objets
## Libere le modele charge en cache (a appeler avant de quitter, evite des avertissements de fuite).
static func free_cache() -> void:
	if _extra_root:
		_extra_root.free()
		_extra_root = null


static func _extra() -> Node:
	if _extra_root == null and ResourceLoader.exists(PROPS_GLB):
		var ps: PackedScene = load(PROPS_GLB)
		_extra_root = ps.instantiate()
	return _extra_root


## Objet pret a l'emploi (props_extra.glb, sinon props.glb), materiaux enregistres pour les reflets.
func make_prop(id: String) -> Node3D:
	var root := _extra()
	var src: Node = root.find_child(id, false, false) if root else null
	var node: Node3D
	if src == null:
		if not LEGACY_PROPS.has(id):
			push_warning("objet introuvable : " + id)
			return Node3D.new()
		var before := pet._env_props.size()
		node = PetAssets.make_prop(id, pet._env_props)
		for k in range(before, pet._env_props.size()):
			_reg.append(pet._env_props[k])
		node.name = id
		return node
	node = src.duplicate()
	node.transform = Transform3D.IDENTITY
	node.name = id
	var mats: Array = []
	_colorize(node, mats)
	_register_env(mats)
	return node


func _colorize(n: Node, mats: Array) -> void:
	for c in n.get_children():
		_colorize(c, mats)
	if not (n is MeshInstance3D):
		return
	var mi: MeshInstance3D = n
	var mname := PetAssets.material_name(mi)
	if PROP_COLORS.has(mname):
		var d: Array = PROP_COLORS[mname]
		mi.material_override = PetAssets.surface_material("plastic", Color.html(d[0]),
			{"roughness": float(d[1]), "clearcoat": 0.25}, mats, mname in ["paper", "news", "kraft"])
	elif mname == "steam":
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1, 1, 1, 0.38)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		var m2 := PetAssets.fixed_material(mname, mats)
		if m2:
			mi.material_override = m2


func _register_env(mats: Array) -> void:
	for m in mats:
		if m is ShaderMaterial:
			_reg.append(m)
			pet._env_props.append(m)
	pet._apply_env(mats.filter(func(m): return m is ShaderMaterial))


func _unregister_env() -> void:
	for m in _reg:
		pet._env_props.erase(m)
	_reg.clear()


func _anchor_parent(at: String) -> Node3D:
	match at:
		"hold":
			return pet.root_node
		"head":
			return pet.squash_node
	return pet


func _front_z() -> float:
	return float(pet.anchors.get("depth", 1.0)) * 0.5 * 0.85 + pet.skin + 0.02


func _anchor_pos(at: String, pos: Vector3) -> Vector3:
	var w := pet.width
	match at:
		"hold":
			return Vector3(pos.x, pos.y * pet.height, _front_z() + pos.z)
		"ground_r":
			return Vector3(w * 0.5 + pos.x, pos.y, pos.z)
		"ground_l":
			return Vector3(-(w * 0.5 + pos.x), pos.y, pos.z)
		"ground_f":
			return Vector3(pos.x, pos.y, _front_z() + pos.z)
		"head":
			return Vector3(pos.x, pet.height + pos.y, pos.z)
	return pos


func _add_prop(p: Dictionary, delay := 0.0, temp := false) -> Node3D:
	var id := str(p["id"])
	var node := make_prop(id)
	var at := str(p.get("at", "hold"))
	var rot: Vector3 = p.get("rot", Vector3.ZERO)
	# objets de props_extra : agrandis pour rester lisibles a la taille reelle du bureau
	var mult := 1.0 if LEGACY_PROPS.has(id) else float(SIZE_BY_ANCHOR.get(at, 1.6))
	var sc := float(p.get("scale", 1.0)) * mult
	var pos: Vector3 = p.get("pos", Vector3.ZERO)
	if at.begins_with("ground"):
		pos.y *= mult
	node.position = _anchor_pos(at, pos)
	node.rotation = Vector3(deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z))
	_anchor_parent(at).add_child(node)
	if paws_enabled and p.has("paws"):
		for pp in p["paws"]:
			var paw := _make_paw()
			paw.position = pp
			paw.scale = Vector3.ONE * 1.15 / sc
			node.add_child(paw)
	var target := Vector3.ONE * sc
	node.scale = Vector3.ONE * 0.01
	var t := create_tween()
	if delay > 0.0:
		t.tween_interval(delay)
	t.tween_property(node, "scale", target, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if temp:
		_temps.append(node)
	else:
		_props[id] = node
		_prop_base[id] = Transform3D(Basis.from_euler(node.rotation).scaled(target), node.position)
	return node


func _drop(node, dur := 0.18) -> void:
	if not is_instance_valid(node):
		return
	var t := create_tween()
	t.tween_property(node, "scale", Vector3.ONE * 0.01, dur).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	t.tween_callback(node.queue_free)


func _drop_all(dur: float) -> void:
	for id in _props:
		_drop(_props[id], dur)
	for n in _temps:
		_drop(n, dur)
	for n in _worn:
		_drop(n, dur)
	_props.clear()
	_prop_base.clear()
	_temps.clear()
	_worn.clear()
	# les materiaux ne recoivent plus l'environnement une fois les objets partis
	var regs := _reg.duplicate()
	_reg.clear()
	get_tree().create_timer(dur + 0.1).timeout.connect(func():
		if is_instance_valid(pet):
			for m in regs:
				pet._env_props.erase(m))


func _sub(id: String, child: String) -> Node3D:
	var p: Node3D = _props.get(id)
	if p == null or not is_instance_valid(p):
		return null
	return p.find_child(child, true, false) as Node3D


## Petite patte (meme matiere que le corps) qui tient l'objet.
func _make_paw() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "paw"
	var sm := SphereMesh.new()
	sm.radius = 0.05
	sm.height = 0.09
	sm.radial_segments = 20
	sm.rings = 10
	mi.mesh = sm
	var info: Dictionary = Data.MATERIALS.get(pet.material_id, {})
	var col := Color(1, 0.8, 0.9)
	if not pet.body_mats.is_empty():
		var c = pet.body_mats[0].get_shader_parameter("base_color")
		if c is Color:
			col = c
	var mats: Array = []
	if str(info.get("kind", "fur")) == "fur":
		var sp: Dictionary = Data.SPECIES.get(pet.species_id, {})
		PetAssets.apply_fur(mi, col, pet.skin * 0.35, float(sp.get("density", 70.0)) * 1.6, 6, mats)
	else:
		mi.material_override = PetAssets.surface_material(str(info.get("kind", "plastic")), col,
			info.get("params", {}), mats)
	_register_env(mats)
	return mi


## Accessoire porte le temps de la situation (lunettes, casque, beret...) si l'emplacement est libre.
func _wear(item_id: String) -> void:
	if not Data.ITEMS.has(item_id):
		return
	var item: Dictionary = Data.ITEMS[item_id]
	var slot := str(item.get("slot", "head"))
	if str(pet.slot_items.get(slot, "")) != "":
		return  # il porte deja quelque chose a cet endroit : on respecte sa tenue
	var holder := Node3D.new()
	holder.name = "situation_" + item_id
	holder.transform = _fit_transform(str(item.get("fit", "hat")))
	pet.squash_node.add_child(holder)
	var mats: Array = []
	var node := PetAssets.make_item(item_id, GameState.colors_for(item_id), maxi(4, pet.shells / 2), mats)
	holder.add_child(node)
	_register_env(mats)
	node.scale = Vector3.ONE * 0.01
	var t := create_tween()
	t.tween_property(node, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_worn.append(holder)


## Meme placement que Pet.set_item.
func _fit_transform(fit: String) -> Transform3D:
	var a := pet.anchors
	var hat := Pet._v3(a["hat"])
	var hat_n := Pet._v3(a["hat_n"])
	var skin := pet.skin
	var googly := pet.eye_style == "googly"
	match fit:
		"hat":
			var up := (hat_n * 0.6 + Vector3.UP * 0.4).normalized()
			return Transform3D(Pet.basis_up(up).scaled(Vector3.ONE * float(a["hat_width"]) / 0.6),
				hat + up * skin * 0.4 - up * 0.02)
		"headphones":
			var s := (float(a["ear_width"]) * 0.5 + skin + 0.03) / 0.38
			return Transform3D(Basis().scaled(Vector3.ONE * s), hat + Vector3.UP * skin * 0.5)
		"eyes":
			var el := Pet._v3(a["eye_l"])
			var er := Pet._v3(a["eye_r"])
			var s2 := minf((er.x - el.x) / 0.32 * (1.15 if googly else 1.0), 1.25)
			return Transform3D(Basis().scaled(Vector3.ONE * s2), (el + er) * 0.5 + Vector3(0, 0, skin + (0.13 if googly else 0.05)))
		"mouth":
			return Transform3D(Basis(), Pet._v3(a["mouth"]) + Vector3(0, 0, skin * 0.6 + 0.01))
		"neck":
			var nn := (Pet._v3(a["neck_n"]) + Vector3(0, 0, 1)).normalized()
			return Transform3D(Pet.basis_facing(nn), Pet._v3(a["neck"]) + nn * (skin + 0.02))
	return Transform3D.IDENTITY


func _animate_props(delta: float) -> void:
	var steam := _sub("mug_coffee", "mug_coffee_steam")
	if steam:
		steam.position.y = 0.12 + fmod(_t * 0.02, 0.012)
		steam.scale = Vector3(1.0, 0.9 + 0.12 * sin(_t * 2.3), 1.0)
		steam.rotation.y = sin(_t * 0.7) * 0.3
	var rays := _sub("sun_cloud", "sun_rays")
	if rays:
		rays.rotation.z += delta * 0.6
	for id in ["pennant"]:
		var fl := _sub(id, "pennant_flag")
		if fl:
			fl.rotation.y = sin(_t * 3.2) * 0.22
	var cube: Node3D = _props.get("cube3d")
	if cube and _prop_base.has("cube3d"):
		cube.position.y = (_prop_base["cube3d"] as Transform3D).origin.y + sin(_t * 2.0) * 0.012
	for n in _temps:
		if is_instance_valid(n) and n.name == "lightbulb":
			var r := n.find_child("lightbulb_rays", true, false) as Node3D
			if r:
				r.scale = Vector3.ONE * (1.0 + 0.15 * sin(_t * 9.0))


# =========================================================================== paroles / emotions
func _maybe_say(sid: String) -> void:
	if bool(_spec.get("silent", false)) or not say_callback.is_valid():
		return
	if _now() - _last_talk < talk_cooldown or randf() > talk_chance:
		return
	var ls := Situations.lines(sid)
	if ls.is_empty():
		return
	_last_talk = _now()
	say_callback.call(str(ls[randi() % ls.size()]))


func _emote(kind: String, count := 1, min_gap := 5.0) -> void:
	if bool(_spec.get("no_emotes", false)):
		return
	if _now() - _last_emote < min_gap:
		return
	_last_emote = _now()
	pet.emote.emit(kind, count)


# =========================================================================== micro-actions
# Chaque micro-action est une coroutine courte ; elle verifie _alive(tk) apres chaque attente.

func _pulse(prop_name: String, count: int, amp := -0.035, dt := 0.07, pitch_amp := 0.05) -> Tween:
	var t := _tw()
	for i in count:
		t.tween_property(pet, "squash", amp * randf_range(0.7, 1.2), dt)
		t.parallel().tween_property(pet, "pitch", pitch_amp, dt)
		t.tween_property(pet, "squash", 0.0, dt)
		t.parallel().tween_property(pet, "pitch", 0.0, dt)
	var p: Node3D = _props.get(prop_name)
	if p and _prop_base.has(prop_name):
		var base: Vector3 = (_prop_base[prop_name] as Transform3D).origin
		var tp := _tw()
		for i in count:
			tp.tween_property(p, "position", base + Vector3(0, -0.006, 0), dt)
			tp.tween_property(p, "position", base, dt)
	return t


func _m_pause(tk: int) -> void:
	var t := _tw()
	t.tween_property(pet, "lean", randf_range(-0.05, 0.05), 0.7).set_trans(Tween.TRANS_SINE)
	await _wait(randf_range(0.7, 1.6))


func _m_follow(tk: int) -> void:
	await _m_pause(tk)


func _m_watch(tk: int) -> void:
	await _m_pause(tk)
	if _alive(tk) and randf() < 0.4:
		await _m_nod(tk)


func _m_read(tk: int) -> void:
	# les yeux balaient des lignes de texte
	for i in randi_range(2, 4):
		if not _alive(tk):
			return
		var t := _tw()
		_gaze_off = Vector2(-0.22, 0.03 - i * 0.025)
		t.tween_property(self, "_gaze_off", Vector2(0.22, 0.0 - i * 0.025), randf_range(0.7, 1.0))
		await t.finished
	_gaze_off = Vector2.ZERO


func _m_type(tk: int) -> void:
	var prop := "laptop" if _props.has("laptop") else "keyboard"
	var t := _pulse(prop, randi_range(5, 10))
	await t.finished


func _m_fast_type(tk: int) -> void:
	var t := _pulse("keyboard", randi_range(10, 16), -0.03, 0.045, 0.04)
	await t.finished


func _m_calc(tk: int) -> void:
	var t := _pulse("calculator", randi_range(4, 7), -0.03, 0.08, 0.06)
	await t.finished


func _m_think(tk: int) -> void:
	pet.set_expression("focused", 2.4)
	_look_at(Vector2(0.4, 0.55), 2.2)
	var n := _add_prop({"id": "thought", "at": "head", "pos": Vector3(pet.width * 0.22, 0.0, 0.05)}, 0.0, true)
	for c in ["thought_1", "thought_2", "thought_cloud"]:
		var s := n.find_child(c, true, false) as Node3D
		if s:
			s.scale = Vector3.ONE * 0.01
	for k in 3:
		var s2 := n.find_child(["thought_1", "thought_2", "thought_cloud"][k], true, false) as Node3D
		if s2:
			var t := _tw()
			t.tween_interval(0.12 + k * 0.18)
			t.tween_property(s2, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var tl := _tw()
	tl.tween_property(pet, "lean", -0.06, 0.4).set_trans(Tween.TRANS_SINE)
	await _wait(randf_range(1.6, 2.4))
	_temps.erase(n)
	_drop(n, 0.18)
	if _alive(tk) and randf() < 0.3:
		await _m_bulb(tk)


func _m_bulb(tk: int) -> void:
	var n := _add_prop({"id": "lightbulb", "at": "head", "pos": Vector3(0.0, 0.14, 0.05)}, 0.0, true)
	pet.set_expression("happy", 1.5)
	_emote("sparkle", 2)
	var t := _tw()
	t.tween_property(pet, "hop", 0.08, 0.14).set_ease(Tween.EASE_OUT)
	t.tween_property(pet, "hop", 0.0, 0.14).set_ease(Tween.EASE_IN)
	t.tween_callback(func(): pet.land(0.6))
	await _wait(1.3)
	_temps.erase(n)
	_drop(n, 0.16)


func _m_nod(tk: int) -> void:
	var t := _tw()
	for i in 2:
		t.tween_property(pet, "pitch", 0.16, 0.14)
		t.tween_property(pet, "pitch", -0.04, 0.14)
	t.tween_property(pet, "pitch", 0.0, 0.1)
	await t.finished


func _m_glance(tk: int) -> void:
	_look_at(Vector2(0.0, 0.12), randf_range(0.8, 1.3))
	pet.set_expression("happy", 1.0)
	await _wait(1.0)


func _m_turn_glance(tk: int) -> void:
	var y0 := _spec_yaw(current, _spec)
	var t := _tw()
	t.tween_property(pet, "yaw", 0.35, 0.35).set_trans(Tween.TRANS_SINE)
	await t.finished
	if not _alive(tk):
		return
	_look_at(Vector2(0.0, 0.1), 1.0)
	pet.set_expression("happy", 1.0)
	await _wait(1.0)
	if not _alive(tk):
		return
	var t2 := _tw()
	t2.tween_property(pet, "yaw", y0, 0.4).set_trans(Tween.TRANS_SINE)
	await t2.finished


func _m_mail_wiggle(tk: int) -> void:
	var p: Node3D = _props.get("letter")
	if p == null:
		return
	var t := _tw()
	var r0 := p.rotation.z
	for i in 2:
		t.tween_property(p, "rotation:z", r0 + 0.07, 0.12)
		t.tween_property(p, "rotation:z", r0 - 0.07, 0.12)
	t.tween_property(p, "rotation:z", r0, 0.1)
	await t.finished


func _m_send(tk: int) -> void:
	var n := _add_prop({"id": "envelope", "at": "hold", "pos": Vector3(0.0, 0.37, 0.05), "rot": Vector3(0, 0, 6)}, 0.0, true)
	pet.set_expression("happy", 1.4)
	await _wait(0.5)
	if not _alive(tk):
		return
	var t := _tw()
	t.tween_property(n, "position", n.position + Vector3(0.7, 0.9, 0.0), 0.7).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(n, "rotation:z", -0.6, 0.7)
	t.parallel().tween_property(n, "scale", Vector3.ONE * 0.3, 0.7)
	_emote("sparkle", 1)
	await t.finished
	_temps.erase(n)
	if is_instance_valid(n):
		n.queue_free()


func _m_page(tk: int) -> void:
	var pg := _sub("book", "book_page")
	if pg == null:
		return
	var r0 := pg.rotation.y
	var t := _tw()
	t.tween_property(pg, "rotation:y", r0 - deg_to_rad(148.0), 0.5).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(pet, "pitch", 0.06, 0.25)
	t.tween_property(pet, "pitch", 0.0, 0.25)
	await t.finished
	pg.visible = false
	pg.rotation.y = r0
	await _wait(0.15)
	if is_instance_valid(pg):
		pg.visible = true


func _m_flick(tk: int) -> void:
	var p: Node3D = _props.get("phone")
	if p == null:
		await _wait(0.5)
		return
	var base: Vector3 = (_prop_base["phone"] as Transform3D).origin
	var t := _tw()
	for i in randi_range(1, 3):
		t.tween_property(p, "position", base + Vector3(0, 0.014, 0), 0.12).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(pet, "squash", -0.025, 0.12)
		t.tween_property(p, "position", base, 0.18).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(pet, "squash", 0.0, 0.18)
		t.tween_interval(randf_range(0.1, 0.4))
	await t.finished


func _m_tap(tk: int) -> void:
	var t := _pulse("phone", randi_range(4, 8), -0.025, 0.06, 0.03)
	await t.finished


func _m_laugh(tk: int) -> void:
	pet.set_expression("happy", 1.4)
	_emote("note" if randf() < 0.5 else "heart", 1)
	var t := _tw()
	for i in 3:
		t.tween_property(pet, "squash", -0.06, 0.09)
		t.tween_property(pet, "squash", 0.03, 0.09)
	t.tween_property(pet, "squash", 0.0, 0.1)
	await t.finished


func _m_heart(tk: int) -> void:
	pet.set_expression("love", 1.2)
	_emote("heart", 1)
	await _wait(0.8)


func _m_surprise(tk: int) -> void:
	pet.set_expression("surprised", 0.9)
	_emote("exclaim", 1)
	var t := _tw()
	t.tween_property(pet, "hop", 0.09, 0.12).set_ease(Tween.EASE_OUT)
	t.tween_property(pet, "hop", 0.0, 0.12).set_ease(Tween.EASE_IN)
	t.tween_callback(func(): pet.land(0.7))
	await t.finished
	await _wait(0.5)


func _m_bob(tk: int) -> void:
	var beat := 60.0 / _bpm
	for i in randi_range(8, 16):
		if not _alive(tk):
			return
		var s := 1.0 if i % 2 == 0 else -1.0
		var t := _tw()
		t.tween_property(pet, "lean", 0.09 * s, beat * 0.45).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(pet, "squash", -0.05, beat * 0.2)
		t.parallel().tween_property(pet, "pitch", 0.06, beat * 0.2)
		t.tween_property(pet, "squash", 0.0, beat * 0.3)
		t.parallel().tween_property(pet, "pitch", 0.0, beat * 0.3)
		if i % 4 == 0 and randf() < 0.35:
			_emote("note", 1, 3.0)
		await _wait(beat)
	var t2 := _tw()
	t2.tween_property(pet, "lean", 0.0, 0.2)


func _m_sway(tk: int) -> void:
	var t := _tw()
	t.tween_property(pet, "lean", 0.07, 1.1).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "lean", -0.07, 1.2).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "lean", 0.0, 0.8).set_trans(Tween.TRANS_SINE)
	await t.finished


func _m_scribble(tk: int) -> void:
	var p: Node3D = _props.get("pencil")
	if p == null:
		await _m_pause(tk)
		return
	var base: Vector3 = (_prop_base["pencil"] as Transform3D).origin
	var t := _tw()
	for i in randi_range(5, 9):
		var o := Vector3(randf_range(-0.035, 0.03), randf_range(-0.03, 0.03), 0)
		t.tween_property(p, "position", base + o, 0.09)
		t.parallel().tween_property(pet, "pitch", 0.03 * (1 if i % 2 == 0 else -1), 0.09)
	t.tween_property(p, "position", base, 0.12)
	t.parallel().tween_property(pet, "pitch", 0.0, 0.12)
	await t.finished


func _m_check(tk: int) -> void:
	if _checks >= 3:
		# nouvelle page : tout se decoche
		for k in 3:
			var c := _sub("notepad", "notepad_check_%d" % (k + 1))
			if c:
				var tt := _tw()
				tt.tween_property(c, "scale", Vector3.ONE * 0.01, 0.15)
		_checks = 0
		await _wait(0.4)
		return
	if _checks == 0:
		for k in 3:
			var c0 := _sub("notepad", "notepad_check_%d" % (k + 1))
			if c0:
				c0.scale = Vector3.ONE * 0.01
	await _m_scribble(tk)
	if not _alive(tk):
		return
	_checks += 1
	var c2 := _sub("notepad", "notepad_check_%d" % _checks)
	if c2:
		var t := _tw()
		t.tween_property(c2, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pet.set_expression("happy", 1.0)
	if _checks == 3:
		_emote("sparkle", 2)
	await _m_nod(tk)


func _m_rotate_cube(tk: int) -> void:
	var c: Node3D = _props.get("cube3d")
	if c == null:
		return
	var axes := [Vector3.UP, Vector3.RIGHT, Vector3.FORWARD]
	var ax: Vector3 = axes[randi() % axes.size()]
	var q := Quaternion(ax, PI * 0.5 * (1.0 if randf() < 0.5 else -1.0)) * c.quaternion
	var t := _tw()
	t.tween_property(c, "quaternion", q, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(pet, "lean", 0.06 * (1 if ax == Vector3.UP else -1), 0.3)
	t.tween_property(pet, "lean", 0.0, 0.3)
	await t.finished
	await _wait(randf_range(0.3, 0.8))


func _m_brush(tk: int) -> void:
	var b: Node3D = _props.get("paintbrush")
	if b == null:
		return
	var base: Transform3D = _prop_base["paintbrush"]
	var t := _tw()
	for i in randi_range(2, 4):
		t.tween_property(b, "position", base.origin + Vector3(-0.07, 0.02, 0.01), 0.22).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(b, "rotation:z", deg_to_rad(-28) + 0.35, 0.22)
		t.parallel().tween_property(pet, "lean", -0.04, 0.22)
		t.tween_property(b, "position", base.origin, 0.25).set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(b, "rotation:z", deg_to_rad(-28), 0.25)
		t.parallel().tween_property(pet, "lean", 0.03, 0.25)
	t.tween_property(pet, "lean", 0.0, 0.2)
	await t.finished
	if randf() < 0.3:
		pet.set_expression("love", 1.0)
		_emote("sparkle", 1)


func _m_count(tk: int) -> void:
	var c := _sub("coins", "coins_top")
	var t := _tw()
	if c:
		var y0 := c.position.y
		t.tween_property(c, "position:y", y0 + 0.06, 0.18).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(c, "rotation:y", c.rotation.y + TAU, 0.36)
		t.tween_property(c, "position:y", y0, 0.18).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(pet, "pitch", 0.1, 0.18)
	t.tween_property(pet, "pitch", 0.0, 0.18)
	await t.finished


func _m_clap(tk: int) -> void:
	var arm := _sub("clapper", "clapper_arm")
	var t := _tw()
	t.tween_property(pet, "hop", 0.05, 0.12).set_ease(Tween.EASE_OUT)
	if arm:
		var r0 := arm.rotation.z
		t.tween_property(arm, "rotation:z", 0.0, 0.07).set_ease(Tween.EASE_IN)
		t.parallel().tween_property(pet, "hop", 0.0, 0.07)
		t.parallel().tween_property(pet, "squash", -0.08, 0.07)
		t.tween_property(pet, "squash", 0.0, 0.15)
		t.tween_interval(0.25)
		t.tween_property(arm, "rotation:z", r0, 0.3).set_trans(Tween.TRANS_BACK)
	await t.finished
	pet.set_expression("happy", 0.8)


func _m_flip(tk: int) -> void:
	var h: Node3D = _props.get("hourglass")
	if h == null:
		return
	var t := _tw()
	t.tween_property(h, "rotation:z", h.rotation.z + PI, 0.6).set_trans(Tween.TRANS_BACK)
	t.parallel().tween_property(pet, "lean", -0.06, 0.3)
	t.tween_property(pet, "lean", 0.0, 0.3)
	await t.finished


func _m_wait(tk: int) -> void:
	if randf() < 0.4:
		pet.set_expression("meh", 1.6)
	var t := _tw()
	for i in 4:
		t.tween_property(pet, "squash", -0.03, 0.12)
		t.tween_property(pet, "squash", 0.0, 0.18)
		t.tween_interval(0.15)
	await t.finished


func _m_snap(tk: int) -> void:
	var fl := _sub("camera", "camera_flash")
	var t := _tw()
	t.tween_property(pet, "squash", -0.05, 0.08)
	t.tween_property(pet, "squash", 0.0, 0.12)
	if fl:
		fl.scale = Vector3.ONE * 0.01
		var tf := _tw()
		tf.tween_property(fl, "scale", Vector3.ONE * 1.4, 0.06)
		tf.tween_property(fl, "scale", Vector3.ONE * 0.01, 0.25)
	_emote("sparkle", 2, 3.0)
	await t.finished
	pet.set_expression("happy", 1.2)
	await _wait(0.5)


func _m_cheer(tk: int) -> void:
	pet.set_expression("happy", 1.5)
	_emote("sparkle", 2)
	for i in 2:
		if not _alive(tk):
			return
		var t := _tw()
		t.tween_property(pet, "squash", -0.1, 0.08)
		t.tween_property(pet, "hop", 0.13, 0.16).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(pet, "squash", 0.08, 0.16)
		t.tween_property(pet, "hop", 0.0, 0.15).set_ease(Tween.EASE_IN)
		t.parallel().tween_property(pet, "squash", 0.0, 0.15)
		await t.finished
		pet.land(1.0)


func _m_cheer_small(tk: int) -> void:
	if not _alive(tk):
		return
	pet.set_expression("happy", 1.2)
	_emote("sparkle", 2)
	var t := _tw()
	t.tween_property(pet, "hop", 0.07, 0.12).set_ease(Tween.EASE_OUT)
	t.tween_property(pet, "hop", 0.0, 0.12).set_ease(Tween.EASE_IN)
	await t.finished
	pet.land(0.5)


func _m_excited(tk: int) -> void:
	await _m_cheer(tk)


func _m_wave(tk: int) -> void:
	pet.set_expression("happy", 1.5)
	_look_at(Vector2(0, 0.1), 1.4)
	var t := _tw()
	for i in 2:
		t.tween_property(pet, "lean", 0.13, 0.16)
		t.tween_property(pet, "lean", -0.13, 0.16)
	t.tween_property(pet, "lean", 0.0, 0.14)
	await t.finished


func _m_pose(tk: int) -> void:
	pet.set_expression("happy", 1.6)
	_look_at(Vector2(0, 0.12), 1.6)
	var t := _tw()
	t.tween_property(pet, "lean", 0.1, 0.25).set_trans(Tween.TRANS_BACK)
	t.parallel().tween_property(pet, "squash", 0.05, 0.25)
	t.tween_interval(0.9)
	t.tween_property(pet, "lean", 0.0, 0.3)
	t.parallel().tween_property(pet, "squash", 0.0, 0.3)
	_emote("sparkle", 1)
	await t.finished


func _m_scan(tk: int) -> void:
	for v in [Vector2(-0.7, 0.05), Vector2(0.7, 0.1), Vector2(0.0, 0.0)]:
		if not _alive(tk):
			return
		_look_at(v, 0.8)
		await _wait(randf_range(0.6, 0.9))


func _m_magnify(tk: int) -> void:
	var m: Node3D = _props.get("magnifier")
	if m == null:
		return
	var base: Vector3 = (_prop_base["magnifier"] as Transform3D).origin
	var er := Pet._v3(pet.anchors["eye_r"])
	var target := Vector3(er.x, er.y, er.z + pet.skin + 0.1)
	_look_at(Vector2(0.0, 0.0), 2.0)
	var t := _tw()
	t.tween_property(m, "position", target, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await t.finished
	if not _alive(tk):
		return
	pet.set_expression("surprised", 1.1)
	await _wait(1.1)
	if not _alive(tk):
		return
	var t2 := _tw()
	t2.tween_property(m, "position", base, 0.35).set_trans(Tween.TRANS_SINE)
	await t2.finished


func _m_not_looking(tk: int) -> void:
	pet.set_expression("happy", 2.5)
	var t := _tw()
	t.tween_property(pet, "lean", -0.07, 0.6).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "lean", 0.0, 0.8).set_trans(Tween.TRANS_SINE)
	await t.finished
	await _wait(0.8)


func _m_sip(tk: int) -> void:
	if not _props.has("mug_coffee"):
		return
	var y0 := pet.yaw
	var t := _tw()
	t.tween_property(pet, "yaw", y0 - 0.5, 0.35)
	t.tween_property(pet, "pitch", -0.18, 0.35)
	t.tween_interval(0.8)
	t.tween_property(pet, "pitch", 0.0, 0.3)
	t.tween_property(pet, "yaw", y0, 0.35)
	await t.finished
	if _alive(tk):
		pet.set_expression("happy", 1.0)


func _m_yawn(tk: int) -> void:
	pet.set_expression("surprised", 1.3)
	var t := _tw()
	t.tween_property(pet, "squash", 0.16, 0.7).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(pet, "pitch", -0.14, 0.7)
	t.tween_interval(0.45)
	t.tween_property(pet, "squash", 0.0, 0.5)
	t.parallel().tween_property(pet, "pitch", 0.0, 0.5)
	await t.finished


func _m_doze(tk: int) -> void:
	pet.set_expression("sleep", 1.8)
	var t := _tw()
	t.tween_property(pet, "pitch", 0.16, 1.3).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(pet, "squash", -0.06, 1.3)
	await t.finished
	if not _alive(tk):
		return
	pet.set_expression("surprised", 0.6)
	var t2 := _tw()
	t2.tween_property(pet, "pitch", -0.05, 0.1)
	t2.parallel().tween_property(pet, "squash", 0.04, 0.1)
	t2.tween_property(pet, "pitch", 0.0, 0.3)
	t2.parallel().tween_property(pet, "squash", 0.0, 0.3)
	await t2.finished


func _m_point(tk: int) -> void:
	var t := _tw()
	t.tween_property(pet, "lean", -0.12, 0.25).set_trans(Tween.TRANS_BACK)
	t.parallel().tween_property(pet, "hop", 0.04, 0.2)
	t.tween_property(pet, "hop", 0.0, 0.15)
	t.tween_interval(0.5)
	t.tween_property(pet, "lean", 0.0, 0.3)
	await t.finished
	if randf() < 0.5:
		await _m_nod(tk)


func _m_key(tk: int) -> void:
	var t := _pulse("synth", randi_range(3, 6), -0.04, 0.1, 0.05)
	var tl := _tw()
	tl.tween_property(pet, "lean", randf_range(-0.08, 0.08), 0.25)
	_emote("note", 1, 2.5)
	await t.finished


func _m_chess_move(tk: int) -> void:
	var w := _sub("chessboard", "chess_pawn_w")
	if w == null:
		return
	if _pawn_moves >= 2:
		w.position.z += 0.066 * 2.0
		_pawn_moves = 0
	var p0 := w.position
	var t := _tw()
	t.tween_property(w, "position", p0 + Vector3(0, 0.04, -0.033), 0.18).set_ease(Tween.EASE_OUT)
	t.tween_property(w, "position", p0 + Vector3(0, 0, -0.066), 0.18).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(pet, "pitch", 0.1, 0.18)
	t.tween_property(pet, "pitch", 0.0, 0.2)
	await t.finished
	_pawn_moves += 1
	pet.set_expression("happy", 1.0)
	_emote("sparkle", 1)


func _m_drool(tk: int) -> void:
	pet.set_expression("love", 1.6)
	_emote("sweat", 1, 4.0)
	var t := _tw()
	t.tween_property(pet, "squash", -0.06, 0.2)
	t.tween_property(pet, "squash", 0.03, 0.2)
	t.tween_property(pet, "squash", 0.0, 0.2)
	await t.finished


func _m_smell(tk: int) -> void:
	var id := "cupcake" if _props.has("cupcake") else "rose"
	var p: Node3D = _props.get(id)
	if p == null:
		return
	var base: Vector3 = (_prop_base[id] as Transform3D).origin
	var m := Pet._v3(pet.anchors["mouth"])
	var t := _tw()
	t.tween_property(p, "position", Vector3(m.x, m.y - 0.12, m.z + pet.skin + 0.06), 0.4).set_trans(Tween.TRANS_SINE)
	await t.finished
	if not _alive(tk):
		return
	pet.set_expression("love", 1.4)
	_emote("heart", 1)
	await _wait(0.8)
	if not _alive(tk):
		return
	var t2 := _tw()
	t2.tween_property(p, "position", base, 0.4).set_trans(Tween.TRANS_SINE)
	await t2.finished


func _m_shy(tk: int) -> void:
	pet.set_expression("love", 2.2)
	_look_at(Vector2(-0.6, -0.5), 1.8)
	var t := _tw()
	t.tween_property(pet, "lean", 0.1, 0.4).set_trans(Tween.TRANS_SINE)
	t.parallel().tween_property(pet, "squash", -0.05, 0.4)
	t.tween_interval(1.0)
	t.tween_property(pet, "lean", 0.0, 0.5)
	t.parallel().tween_property(pet, "squash", 0.0, 0.5)
	await t.finished


func _m_wrench(tk: int) -> void:
	var w: Node3D = _props.get("wrench")
	if w == null:
		return
	var r0 := w.rotation.z
	var t := _tw()
	for i in 3:
		t.tween_property(w, "rotation:z", r0 + 0.55, 0.16)
		t.parallel().tween_property(pet, "squash", -0.05, 0.16)
		t.tween_property(w, "rotation:z", r0, 0.2)
		t.parallel().tween_property(pet, "squash", 0.0, 0.2)
	await t.finished
	if randf() < 0.25:
		_emote("sweat", 1)


func _m_munch(tk: int) -> void:
	var t := _tw()
	t.tween_property(pet, "pitch", 0.14, 0.15)
	t.tween_property(pet, "pitch", -0.04, 0.15)
	t.tween_property(pet, "squash", -0.06, 0.08)
	t.tween_property(pet, "squash", 0.0, 0.12)
	t.tween_property(pet, "squash", -0.05, 0.08)
	t.tween_property(pet, "squash", 0.0, 0.12)
	t.tween_property(pet, "pitch", 0.0, 0.2)
	await t.finished


func _m_stamp(tk: int) -> void:
	var s: Node3D = _props.get("stamp")
	if s == null:
		return
	var base: Vector3 = (_prop_base["stamp"] as Transform3D).origin
	var t := _tw()
	t.tween_property(s, "position", base + Vector3(-0.08, 0.05, 0.0), 0.22).set_trans(Tween.TRANS_SINE)
	t.tween_property(s, "position", base + Vector3(-0.1, -0.06, 0.0), 0.08).set_ease(Tween.EASE_IN)
	t.parallel().tween_property(pet, "squash", -0.08, 0.08)
	t.tween_property(pet, "squash", 0.0, 0.15)
	t.tween_interval(0.15)
	t.tween_property(s, "position", base, 0.25).set_trans(Tween.TRANS_SINE)
	await t.finished


func _m_sigh(tk: int) -> void:
	pet.set_expression("meh", 1.6)
	var t := _tw()
	t.tween_property(pet, "squash", 0.06, 0.5).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "squash", -0.07, 0.6).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "squash", 0.0, 0.4)
	_emote("sweat", 1, 8.0)
	await t.finished


func _m_fold(tk: int) -> void:
	var p: Node3D = _props.get("newspaper")
	if p == null:
		return
	var r0 := p.rotation.y
	var t := _tw()
	t.tween_property(p, "rotation:y", r0 + 0.2, 0.15)
	t.tween_property(p, "rotation:y", r0 - 0.12, 0.18)
	t.tween_property(p, "rotation:y", r0, 0.15)
	t.parallel().tween_property(pet, "pitch", 0.05, 0.15)
	t.tween_property(pet, "pitch", 0.0, 0.15)
	await t.finished


func _m_map_trace(tk: int) -> void:
	var t := _tw()
	_gaze_off = Vector2(-0.35, 0.05)
	t.tween_property(self, "_gaze_off", Vector2(0.35, -0.05), 1.5).set_trans(Tween.TRANS_SINE)
	t.tween_property(self, "_gaze_off", Vector2.ZERO, 0.4)
	await t.finished
	if _alive(tk) and randf() < 0.5:
		pet.set_expression("happy", 1.0)
		await _m_nod(tk)


func _m_rummage(tk: int) -> void:
	var p: Node3D = _props.get("folder")
	if p == null:
		return
	var base: Vector3 = (_prop_base["folder"] as Transform3D).origin
	var t := _tw()
	for i in 3:
		t.tween_property(p, "rotation:z", 0.08 * (1 if i % 2 == 0 else -1), 0.1)
		t.parallel().tween_property(p, "position", base + Vector3(0, 0.012, 0), 0.1)
		t.tween_property(p, "position", base, 0.1)
	t.tween_property(p, "rotation:z", 0.0, 0.1)
	await t.finished


func _m_want(tk: int) -> void:
	pet.set_expression("love", 1.4)
	_emote("heart", 1)
	var t := _tw()
	t.tween_property(pet, "squash", -0.05, 0.12)
	t.tween_property(pet, "squash", 0.04, 0.12)
	t.tween_property(pet, "squash", 0.0, 0.12)
	await t.finished
	await _wait(0.6)


func _m_look_up(tk: int) -> void:
	_look_at(Vector2(0.4, 0.85), 1.6)
	pet.set_expression("happy", 1.4)
	var t := _tw()
	t.tween_property(pet, "pitch", -0.08, 0.4)
	t.tween_interval(0.8)
	t.tween_property(pet, "pitch", 0.0, 0.4)
	await t.finished


func _m_look_around(tk: int) -> void:
	for v in [Vector2(-0.8, 0.1), Vector2(0.8, 0.2), Vector2(0.0, 0.4)]:
		if not _alive(tk):
			return
		_look_at(v, 1.0)
		await _wait(randf_range(0.7, 1.1))


func _m_wiggle(tk: int) -> void:
	var t := _tw()
	for i in 4:
		t.tween_property(pet, "lean", 0.08 * (1 if i % 2 == 0 else -1), 0.2).set_trans(Tween.TRANS_SINE)
	t.tween_property(pet, "lean", 0.0, 0.2)
	await t.finished
