class_name MiniGameBase
extends Control
## Base commune des mini-jeux contre Pompom (Puissance 4, Snake duel, Morpion).
## Chaque jeu se dessine lui-meme (_draw) et previent la fenetre par signaux :
##  - finished(result) : "win" | "lose" | "draw" du point de vue du JOUEUR ;
##  - status_changed(text, who) : ligne d'etat ("A toi !"), who = "user" | "pompom" | "" ;
##  - pompom_event(kind) : evenement auquel Pompom reagit (bulle + expression), voir MiniGameWindow.EVENTS ;
##  - thinking_changed(on) : Pompom reflechit (petits points).

signal finished(result: String)
signal status_changed(text: String, who: String)
signal pompom_event(kind: String)
signal thinking_changed(on: bool)

const USER := 1
const POMPOM := 2

var difficulty := 1  # 0 Facile, 1 Moyen, 2 Difficile
var user_starts := true
var over := false
var result := ""
var thinking := false
var pet_name := "Pompom"
var moves_played := 0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	_rng.randomize()


## Identifiant stable ("connect4", "snake", "tictactoe").
func game_id() -> String:
	return ""


## Demarre une nouvelle partie.
func start_game(p_difficulty: int, p_user_starts: bool) -> void:
	difficulty = clampi(p_difficulty, 0, 2)
	user_starts = p_user_starts
	over = false
	result = ""
	moves_played = 0
	_set_thinking(false)


## Arrete tout (threads de l'IA compris). Appele avant liberation / changement de jeu.
func shutdown() -> void:
	pass


## Touche clavier transmise par la fenetre ; renvoie true si consommee.
func key_input(_ev: InputEventKey) -> bool:
	return false


func _set_thinking(on: bool) -> void:
	if thinking == on:
		return
	thinking = on
	thinking_changed.emit(on)


func _finish(r: String) -> void:
	if over:
		return
	over = true
	result = r
	_set_thinking(false)
	finished.emit(r)


func _exit_tree() -> void:
	shutdown()


## Duree de reflexion "pour le personnage" (s), selon la difficulte.
func _think_time() -> float:
	match difficulty:
		0:
			return _rng.randf_range(0.3, 0.6)
		1:
			return _rng.randf_range(0.4, 0.8)
	return _rng.randf_range(0.5, 0.9)


# ------------------------------------------------------------------ dessin partage
## Ombre douce sous une forme ronde (plusieurs disques translucides).
func soft_shadow(c: Vector2, r: float, a := 0.16, dy := 3.0) -> void:
	for i in 4:
		var k := float(i) / 3.0
		draw_circle(c + Vector2(0, dy + k * 1.5), r * (1.0 + 0.07 * (3 - i)), Color(0.35, 0.12, 0.3, a * 0.32), true, -1.0, true)


## Plateau "carte verre" arrondi avec une ombre.
func card_rect(r: Rect2, radius: float, col: Color, shadow := 10) -> void:
	var st := UITheme.box(col, int(radius), Color(1, 1, 1, 0.9), 1, 0)
	st.shadow_color = Color(0.35, 0.15, 0.32, 0.14)
	st.shadow_size = shadow
	st.shadow_offset = Vector2(0, 4)
	draw_style_box(st, r)


## Texte centre (Fredoka).
func text_center(p: Vector2, txt: String, fs: int, col: Color, weight := 650) -> void:
	var f := UITheme.font(weight)
	var sz := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(f, Vector2(p.x - sz.x * 0.5, p.y + f.get_ascent(fs) * 0.5 - f.get_descent(fs) * 0.35), txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## Petit visage "Pompom" (deux yeux + sourire) dans un cercle de rayon r.
func tiny_face(c: Vector2, r: float, ink: Color, mood := "smile") -> void:
	var ex := r * 0.36
	var ey := -r * 0.08
	var er := maxf(1.2, r * 0.13)
	if mood == "happy":
		draw_arc(c + Vector2(-ex, ey + er * 0.6), er * 1.3, PI * 1.15, PI * 1.85, 8, ink, maxf(1.2, r * 0.1), true)
		draw_arc(c + Vector2(ex, ey + er * 0.6), er * 1.3, PI * 1.15, PI * 1.85, 8, ink, maxf(1.2, r * 0.1), true)
	else:
		draw_circle(c + Vector2(-ex, ey), er, ink, true, -1.0, true)
		draw_circle(c + Vector2(ex, ey), er, ink, true, -1.0, true)
		draw_circle(c + Vector2(-ex + er * 0.35, ey - er * 0.35), er * 0.38, Color(1, 1, 1, 0.9), true, -1.0, true)
		draw_circle(c + Vector2(ex + er * 0.35, ey - er * 0.35), er * 0.38, Color(1, 1, 1, 0.9), true, -1.0, true)
	draw_arc(c + Vector2(0, r * 0.12), r * 0.2, PI * 0.15, PI * 0.85, 10, ink, maxf(1.2, r * 0.1), true)
	draw_circle(c + Vector2(-ex * 1.55, r * 0.18), r * 0.13, Color(1, 0.45, 0.6, 0.35), true, -1.0, true)
	draw_circle(c + Vector2(ex * 1.55, r * 0.18), r * 0.13, Color(1, 0.45, 0.6, 0.35), true, -1.0, true)


## Etoile a 5 branches arrondie (pions du joueur).
func star_points(c: Vector2, r: float, rot := 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + rot + i * PI / 5.0
		var rr := r if i % 2 == 0 else r * 0.48
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	return pts


static func ease_out_back(t: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(t - 1.0, 3) + c1 * pow(t - 1.0, 2)
