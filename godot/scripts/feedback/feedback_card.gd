class_name FeedbackCard
extends Window
## Carte « Qu'est-ce que tu faisais vraiment ? » : l'utilisateur corrige le compagnon (il regardait une
## « vidéo » alors que tu écoutais de la musique, il n'a pas fêté ton but...). Meme style que PetMenu / la
## boutique : carte blanche arrondie, pastilles pastel, Fredoka.
##
##   var card := FeedbackCard.new()
##   add_child(card)
##   card.preview_provider = func(choices: Array) -> String: return "{...}"   # JSON exact envoye
##   card.submitted.connect(func(choices: Array, note: String, share: bool): ...)
##   card.open_for(ctx, {"anchor": Rect2i(...), "share_available": true, "share_default": true,
##       "embedding": "pending" | "ok" | "none"})
##   card.set_embedding_state("ok")   # quand l'analyse locale de l'ecran arrive
##
## choices = [{task, label}] : une activite (grille), un evenement de jeu manque et/ou le vrai type d'un
## champ (seulement si une suggestion de collage vient d'avoir lieu). La note « Autre… » reste LOCALE.

signal submitted(choices: Array, note: String, share: bool)
signal canceled

const MARGIN := 18.0  # marge transparente (ombre)
const COLS := 5
const TILE := Vector2(80, 74)
const GAP := 6

## [etiquette, texte, icone, teinte]
const ACTIVITIES := [
	["video", "Vidéo", "play", UITheme.ACCENT], ["music", "Musique", "note", UITheme.LAVENDER],
	["game", "Jeu", "gamepad", UITheme.SKY], ["code", "Code", "code", UITheme.MINT],
	["ai", "Claude / IA", "sparkle", UITheme.PEACH], ["email", "Mails", "mail", UITheme.SKY],
	["docs", "Documents", "doc", UITheme.LAVENDER], ["spreadsheet", "Tableur", "grid", UITheme.MINT],
	["chat", "Discussion", "chat", UITheme.ACCENT], ["social", "Réseaux", "social", UITheme.PEACH],
	["reading", "Lecture", "book", UITheme.GOLD], ["design", "Design", "palette", UITheme.ACCENT],
	["browse", "Web", "globe", UITheme.SKY], ["meeting", "Visio", "camera", UITheme.LAVENDER],
	["other", "Autre…", "dots", UITheme.MUTED],
]
const EVENTS := [
	["goal", "J'ai marqué", "ball", UITheme.MINT], ["kill", "J'ai fait un kill", "target", UITheme.MINT],
	["round_won", "Manche gagnée", "flag", UITheme.MINT], ["match_won", "Mon équipe a gagné", "trophy", UITheme.GOLD],
	["death", "Je suis mort", "skull", UITheme.BAD], ["goal_against", "On m'a marqué", "ball", UITheme.BAD],
	["round_lost", "Manche perdue", "flag", UITheme.BAD], ["match_lost", "Mon équipe a perdu", "cup_down", UITheme.BAD],
	["none", "Il a fêté pour rien", "none", UITheme.MUTED],
]
const FIELDS := [
	["email", "E-mail", "at"], ["phone", "Téléphone", "phone"], ["address", "Adresse", "home"], ["url", "Lien", "link"],
	["search", "Recherche", "search"], ["name", "Nom", "person"], ["code", "Code", "code"],
	["chat_message", "Message", "chat"], ["username", "Identifiant", "user"], ["number", "Nombre", "hash"],
	["date", "Date", "calendar"], ["other", "Autre", "dots"],
]
## Classes de la vision -> texte « il pensait »
const VISION_FR := {"game": "Tu joues", "video": "Tu regardes une vidéo", "work_code": "Tu programmes",
	"work_docs": "Tu travailles sur un document", "browse": "Tu navigues sur le web", "chat": "Tu discutes",
	"other": "Rien de spécial"}

var ctx := {}
var share_available := false
var embedding_state := "pending"  # pending | ok | none
var preview_provider: Callable

var _f := 1.0
var _anchor := Rect2i()
var _sel := {"activity": "", "game_event": "", "field_kind": ""}
var _items := {}  # "task:label" -> bouton
var _root: MarginContainer
var _card: PanelContainer
var _note_box: Control
var _note: LineEdit
var _events_box: Control
var _events_link: Button
var _share: UIKit.Toggle
var _share_pref := true  # choix de l'utilisateur (garde quand le partage est indisponible)
var _share_sub: Label
var _see: Button
var _json_box: Control
var _json: TextEdit
var _ok: Button
var _foot: Label
var _closing := false


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	unresizable = true
	always_on_top = true
	transient = false
	exclusive = false
	unfocusable = false
	wrap_controls = false
	title = "Pompom — Il s'est trompé"
	msaa_2d = Viewport.MSAA_4X
	theme = UITheme.theme()
	close_requested.connect(cancel)


# =========================================================================== ouverture
func open_for(p_ctx: Dictionary, opts := {}) -> void:
	ctx = p_ctx
	share_available = bool(opts.get("share_available", false))
	embedding_state = str(opts.get("embedding", "pending"))
	_anchor = opts.get("anchor", Rect2i())
	_sel = {"activity": "", "game_event": "", "field_kind": ""}
	var pre: Dictionary = opts.get("preselect", {})
	for k in pre:
		_sel[k] = str(pre[k])
	var sc := DisplayServer.get_screen_from_rect(Rect2(_anchor)) if _anchor.has_area() else DisplayServer.window_get_current_screen()
	_f = UITheme.dpi_scale(maxi(sc, 0))
	content_scale_factor = _f
	_build(bool(opts.get("share_default", true)))
	_refresh()
	show()
	_fit(true)
	_card.pivot_offset = _card.size * 0.5
	_card.modulate.a = 0.0
	_card.scale = Vector2.ONE * 0.96
	var t := create_tween().set_parallel()
	t.tween_property(_card, "modulate:a", 1.0, 0.12)
	t.tween_property(_card, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	grab_focus()


func set_embedding_state(st: String) -> void:
	embedding_state = st
	if _share:
		_refresh()


## Selection courante : [{task, label}].
func choices() -> Array:
	var out: Array = []
	for task in ["activity", "game_event", "field_kind"]:
		if str(_sel[task]) != "":
			out.append({"task": task, "label": str(_sel[task])})
	return out


func select(task: String, label: String) -> void:
	_sel[task] = "" if str(_sel[task]) == label else label
	_refresh()


func submit() -> void:
	if _closing or choices().is_empty():
		return
	var note := _note.text.strip_edges() if _note and _note_box.visible else ""
	var share := share_available and embedding_state == "ok" and _share != null and _share.button_pressed
	submitted.emit(choices(), note, share)
	_close()


func cancel() -> void:
	if _closing:
		return
	canceled.emit()
	_close()


func _close() -> void:
	_closing = true
	var t := create_tween().set_parallel()
	t.tween_property(_card, "modulate:a", 0.0, 0.1)
	t.tween_property(_card, "scale", Vector2.ONE * 0.97, 0.1)
	t.chain().tween_callback(func():
		hide()
		queue_free())


func _input(ev: InputEvent) -> void:
	if not visible or _closing:
		return
	if ev is InputEventKey and ev.pressed and not ev.echo:
		if ev.keycode == KEY_ESCAPE:
			cancel()
			set_input_as_handled()
		elif (ev.keycode == KEY_ENTER or ev.keycode == KEY_KP_ENTER) and not (_note and _note.has_focus()):
			submit()
			set_input_as_handled()


# =========================================================================== construction
func _build(share_default: bool) -> void:
	for c in get_children():
		c.queue_free()
	_items.clear()
	_root = MarginContainer.new()
	for s in ["left", "top", "right", "bottom"]:
		_root.add_theme_constant_override("margin_" + s, int(MARGIN))
	add_child(_root)
	_card = PanelContainer.new()
	var st := UITheme.glass(24, 18, 1.0, 16)
	st.shadow_color = Color(0.3, 0.1, 0.25, 0.22)
	st.border_color = UITheme.LINE
	_card.add_theme_stylebox_override("panel", st)
	_card.custom_minimum_size.x = COLS * TILE.x + (COLS - 1) * GAP + 36
	_root.add_child(_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_card.add_child(v)

	# en-tete : avatar, question, ce qu'il pensait, fermer
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	var av := Avatar.new()
	av.custom_minimum_size = Vector2(46, 46)
	av.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(av)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", -1)
	hv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(hv)
	hv.add_child(UITheme.label("Qu'est-ce que tu faisais vraiment ?", UITheme.FS_H2, UITheme.INK, 650))
	var thought := UITheme.label(thought_text(ctx), UITheme.FS_SMALL, UITheme.MUTED)
	thought.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hv.add_child(thought)
	var close := Button.new()
	close.theme_type_variation = "GhostButton"
	close.custom_minimum_size = Vector2(34, 34)
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close.focus_mode = Control.FOCUS_NONE
	close.tooltip_text = "Fermer (Échap)"
	close.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var ci := UIKit.icon("close", 16.0, UITheme.MUTED)
	ci.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	close.add_child(ci)
	close.pressed.connect(cancel)
	head.add_child(close)

	# grille des activites
	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", GAP)
	grid.add_theme_constant_override("v_separation", GAP)
	v.add_child(grid)
	for a in ACTIVITIES:
		var t := Tile.new(str(a[1]), str(a[2]), a[3])
		t.pressed.connect(select.bind("activity", str(a[0])))
		if a[0] == "ai":
			t.tooltip_text = "Claude Code, ChatGPT, une autre IA…"
		grid.add_child(t)
		_items["activity:" + str(a[0])] = t

	# « Autre… » : quelques mots, gardes sur le PC
	_note_box = PanelContainer.new()
	_note_box.add_theme_stylebox_override("panel", UITheme.box(Color(1, 1, 1, 0.95), 12, UITheme.LINE_2, 1, 4))
	_note = LineEdit.new()
	_note.placeholder_text = "Dis-le en quelques mots… (ça reste sur ton PC)"
	_note.max_length = 120
	_note.add_theme_font_size_override("font_size", UITheme.FS_SMALL + 1)
	_note.text_submitted.connect(func(_t): submit())
	_note_box.add_child(_note)
	_note_box.visible = false
	v.add_child(_note_box)

	# evenements de jeu manques
	var game_ctx := bool(ctx.get("game_context", false))
	_events_link = _link_button(("▾ " if game_ctx else "▸ ") + "Il a raté un moment de jeu ?")
	_events_link.pressed.connect(func():
		_events_box.visible = not _events_box.visible
		_events_link.text = ("▾ " if _events_box.visible else "▸ ") + "Il a raté un moment de jeu ?"
		_fit())
	v.add_child(_events_link)
	var ef := HFlowContainer.new()
	ef.add_theme_constant_override("h_separation", 6)
	ef.add_theme_constant_override("v_separation", 6)
	for e in EVENTS:
		var chip := Chip.new(str(e[1]), str(e[2]), e[3])
		chip.pressed.connect(select.bind("game_event", str(e[0])))
		ef.add_child(chip)
		_items["game_event:" + str(e[0])] = chip
	_events_box = ef
	_events_box.visible = game_ctx
	v.add_child(ef)

	# type d'un champ (seulement juste apres une suggestion de collage)
	if typeof(ctx.get("field")) == TYPE_DICTIONARY and not (ctx["field"] as Dictionary).is_empty():
		v.add_child(_section_label("La suggestion de collage était fausse ? Ce champ, c'était…"))
		var ff := HFlowContainer.new()
		ff.add_theme_constant_override("h_separation", 6)
		ff.add_theme_constant_override("v_separation", 6)
		for fk in FIELDS:
			var c := Chip.new(str(fk[1]), str(fk[2]), UITheme.SKY)
			c.pressed.connect(select.bind("field_kind", str(fk[0])))
			ff.add_child(c)
			_items["field_kind:" + str(fk[0])] = c
		v.add_child(ff)

	# partage anonyme (seulement si le reglage est actif)
	_share = null
	if share_available:
		var sep := ColorRect.new()
		sep.color = UITheme.LINE
		sep.custom_minimum_size.y = 1
		v.add_child(sep)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		v.add_child(row)
		_share = UIKit.Toggle.new()
		_share_pref = share_default
		_share.set_on(share_default)
		_share.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(_share)
		var sv := VBoxContainer.new()
		sv.add_theme_constant_override("separation", -2)
		sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sv)
		sv.add_child(UITheme.label("Partager anonymement", UITheme.FS_BODY, UITheme.INK, 650))
		_share_sub = UITheme.label("", UITheme.FS_TINY, UITheme.MUTED)
		_share_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sv.add_child(_share_sub)
		_see = _link_button("Voir ce qui part")
		_see.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_see.pressed.connect(func():
			_json_box.visible = not _json_box.visible
			_see.text = "Masquer" if _json_box.visible else "Voir ce qui part"
			_refresh())
		row.add_child(_see)
		_json_box = PanelContainer.new()
		_json_box.add_theme_stylebox_override("panel", UITheme.box(Color("faf5f8"), 12, UITheme.LINE, 1, 8))
		_json = TextEdit.new()
		_json.editable = false
		_json.custom_minimum_size = Vector2(0, 150)
		_json.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		var mono := SystemFont.new()
		mono.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "Courier New", "monospace"])
		_json.add_theme_font_override("font", mono)
		_json.add_theme_font_size_override("font_size", 11)
		_json.add_theme_color_override("font_readonly_color", UITheme.BODY)
		_json.add_theme_color_override("font_color", UITheme.BODY)
		var empty := StyleBoxEmpty.new()
		for k in ["normal", "read_only", "focus"]:
			_json.add_theme_stylebox_override(k, empty)
		_json_box.add_child(_json)
		_json_box.visible = false
		v.add_child(_json_box)
		_share.toggled.connect(func(on: bool):
			_share_pref = on
			_refresh())

	# boutons
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 10)
	v.add_child(btns)
	var cancel_b := Button.new()
	cancel_b.text = "Annuler"
	cancel_b.custom_minimum_size = Vector2(130, 44)
	cancel_b.focus_mode = Control.FOCUS_NONE
	cancel_b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cancel_b.pressed.connect(cancel)
	btns.add_child(cancel_b)
	_ok = Button.new()
	_ok.text = "Ajouter au jeu de données"
	_ok.theme_type_variation = "PrimaryButton"
	_ok.custom_minimum_size = Vector2(0, 44)
	_ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ok.focus_mode = Control.FOCUS_NONE
	_ok.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_ok.pressed.connect(submit)
	btns.add_child(_ok)
	_foot = UITheme.label("", UITheme.FS_TINY, UITheme.MUTED)
	_foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_foot)
	_card.minimum_size_changed.connect(_fit)


func _section_label(t: String) -> Label:
	var l := UITheme.label(t, UITheme.FS_SMALL, UITheme.BODY, 650)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _link_button(t: String) -> Button:
	var b := Button.new()
	b.text = t
	b.theme_type_variation = "GhostButton"
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", UITheme.FS_SMALL + 1)
	for k in ["font_color", "font_focus_color"]:
		b.add_theme_color_override(k, UITheme.ACCENT_DARK)
	return b


# =========================================================================== etat
func _refresh() -> void:
	for key in _items:
		var parts := String(key).split(":")
		var on := str(_sel[parts[0]]) == parts[1]
		_items[key].set_selected(on)
	if _note_box:
		var show_note := str(_sel["activity"]) == "other"
		if _note_box.visible != show_note:
			_note_box.visible = show_note
			if show_note:
				_note.grab_focus.call_deferred()
	if _ok:
		_ok.disabled = choices().is_empty()
	var sharing := false
	if _share:
		_share.disabled = embedding_state != "ok"
		var shown := _share_pref and embedding_state == "ok"  # indisponible : affiche coupe
		if _share.button_pressed != shown:
			_share.set_on(shown)
		sharing = shown
		match embedding_state:
			"ok":
				_share_sub.text = "Seulement des nombres calculés sur ton PC : ni image, ni titre, ni texte."
			"pending":
				_share_sub.text = "Analyse de l'écran en cours sur ton PC…"
			_:
				_share_sub.text = "Indisponible pour cet exemple (assistant local arrêté ou écran privé)."
		if _json_box.visible:
			var txt := "(rien ne partira pour cet exemple)"
			if sharing and not choices().is_empty() and preview_provider.is_valid():
				txt = str(preview_provider.call(choices()))
			elif sharing:
				txt = "(choisis d'abord ce que tu faisais)"
			if _json.text != txt:
				_json.text = txt
	if _foot:
		_foot.text = "Rien ne quitte ton PC, sauf si tu partages : uniquement ces nombres, anonymes." if sharing \
			else "C'est enregistré sur ton PC uniquement, pour qu'il apprenne de ses erreurs."
	_fit()


## Taille de la fenetre = taille de la carte (+ marge d'ombre) ; elle reste dans l'ecran.
func _fit(place := false) -> void:
	if _root == null or not is_inside_tree():
		return
	var ms := _root.get_combined_minimum_size()
	var sz := Vector2i((ms * _f).ceil())
	var sc := DisplayServer.get_screen_from_rect(Rect2(_anchor)) if _anchor.has_area() else current_screen
	var usable := DisplayServer.screen_get_usable_rect(maxi(sc, 0))
	var p := position
	if place:
		var m := int(MARGIN * _f)
		if _anchor.has_area():
			# a gauche du compagnon, bas aligne sur ses pieds ; a droite s'il n'y a pas la place
			p = Vector2i(_anchor.position.x - sz.x + m + int(_anchor.size.x * 0.18), _anchor.end.y - sz.y)
			if p.x < usable.position.x:
				p.x = _anchor.end.x - m - int(_anchor.size.x * 0.18)
		else:
			p = usable.get_center() - sz / 2
	p.x = clampi(p.x, usable.position.x, maxi(usable.position.x, usable.end.x - sz.x))
	p.y = clampi(p.y, usable.position.y, maxi(usable.position.y, usable.end.y - sz.y))
	if size != sz:
		size = sz
	if position != p:
		position = p


static func thought_text(c: Dictionary) -> String:
	var sit := str(c.get("situation", ""))
	if sit != "" and sit != "private":
		return "Il pensait : « %s »." % Situations.label(sit)
	var ev := str(c.get("event", ""))
	if ev != "":
		return "Dernier moment de jeu vu : « %s »." % _event_fr(ev)
	var vis := str(c.get("vision", ""))
	if VISION_FR.has(vis):
		return "Il pensait : « %s »." % VISION_FR[vis]
	if str(c.get("mode", "")) == "video":
		return "Il pensait : « Tu regardes une vidéo »."
	return "Montre-lui ce qui se passait : il apprendra de ses erreurs."


static func _event_fr(kind: String) -> String:
	for e in EVENTS:
		if e[0] == kind:
			return str(e[1])
	return {"multikill": "Multi-kill", "ace": "Ace", "first_blood": "Premier sang", "assist": "Passe décisive",
		"objective": "Objectif", "goal_any": "But"}.get(kind, kind)


# =========================================================================== composants
## Mini avatar du compagnon (comme l'en-tete de PetMenu).
class Avatar extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 2.0
		var fur := GameState.current_fur_color()
		draw_circle(c, r + 2.0, fur.lerp(Color.WHITE, 0.75), true, -1.0, true)
		draw_circle(c + Vector2(0, 1.5), r - 3.0, Color(fur.darkened(0.4), 0.25), true, -1.0, true)
		draw_circle(c, r - 3.0, fur, true, -1.0, true)
		draw_circle(c + Vector2(-5.5, -2), 2.4, UITheme.INK, true, -1.0, true)
		draw_circle(c + Vector2(5.5, -2), 2.4, UITheme.INK, true, -1.0, true)
		draw_arc(c + Vector2(0, 5.5), 2.6, PI * 1.15, PI * 1.85, 8, UITheme.INK, 1.5, true)  # petite moue
		draw_circle(c + Vector2(-6, -8), 3.0, Color(1, 1, 1, 0.45), true, -1.0, true)


## Tuile de la grille : grosse icone dans une pastille + texte.
class Tile extends Button:
	var label_text := ""
	var icon_name := ""
	var tint := UITheme.ACCENT
	var selected := false
	var _h := 0.0

	func _init(p_label: String, p_icon: String, p_tint: Color) -> void:
		label_text = p_label
		icon_name = p_icon
		tint = p_tint
		custom_minimum_size = FeedbackCard.TILE
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = p_label
		UIKit.clear_styles(self)
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.1)

	func set_selected(on: bool) -> void:
		if on != selected:
			selected = on
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var soft := tint.lerp(Color.WHITE, 0.86)
		var bg := soft if selected else Color.WHITE.lerp(soft, _h * 0.7)
		var st := UITheme.box(bg, 16, tint if selected else UITheme.LINE.lerp(tint.lerp(Color.WHITE, 0.5), _h), 2 if selected else 1, 0)
		if selected or _h > 0.01:
			st.shadow_color = Color(tint.darkened(0.3), 0.18 * maxf(_h, 1.0 if selected else 0.0))
			st.shadow_size = 6
			st.shadow_offset = Vector2(0, 2)
		draw_style_box(st, r)
		var c := Vector2(size.x * 0.5, 27)
		var rad := 16.0 + _h
		draw_circle(c, rad, tint if selected else tint.lerp(Color.WHITE, 0.80), true, -1.0, true)
		FeedbackIcons.draw(self, icon_name, Rect2(c - Vector2(10, 10), Vector2(20, 20)),
			Color.WHITE if selected else tint.darkened(0.15), 1.0)
		var f := UITheme.font(650 if selected else 500)
		var fs := 12
		var tw := f.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if tw > size.x - 8:
			fs = 11
		draw_string(f, Vector2(4, size.y - 12), label_text, HORIZONTAL_ALIGNMENT_CENTER, size.x - 8, fs,
			tint.darkened(0.35) if selected else UITheme.INK)
		if selected:
			var bc := Vector2(size.x - 13, 13)
			draw_circle(bc, 8.5, tint, true, -1.0, true)
			UIIcons.draw(self, "check", Rect2(bc - Vector2(6, 6), Vector2(12, 12)), Color.WHITE, 1.2)


## Pastille cliquable (evenements de jeu, types de champ).
class Chip extends Button:
	var label_text := ""
	var icon_name := ""
	var tint := UITheme.ACCENT
	var selected := false
	var _h := 0.0

	func _init(p_label: String, p_icon: String, p_tint: Color) -> void:
		label_text = p_label
		icon_name = p_icon
		tint = p_tint
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		var w := UITheme.font(650).get_string_size(p_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		custom_minimum_size = Vector2(w + 44, 32)
		mouse_entered.connect(func():
			_h = 1.0
			queue_redraw())
		mouse_exited.connect(func():
			_h = 0.0
			queue_redraw())

	func set_selected(on: bool) -> void:
		if on != selected:
			selected = on
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var soft := tint.lerp(Color.WHITE, 0.86)
		var bg := tint if selected else (soft if _h > 0.5 else Color.WHITE)
		draw_style_box(UITheme.box(bg, 99, tint if (selected or _h > 0.5) else UITheme.LINE_2, 1, 0), r)
		var col := Color.WHITE if selected else tint.darkened(0.25)
		FeedbackIcons.draw(self, icon_name, Rect2(Vector2(10, size.y * 0.5 - 8), Vector2(16, 16)), col, 1.0)
		var f := UITheme.font(650)
		draw_string(f, Vector2(32, size.y * 0.5 + f.get_ascent(13) * 0.5 - 2), label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Color.WHITE if selected else UITheme.INK)
