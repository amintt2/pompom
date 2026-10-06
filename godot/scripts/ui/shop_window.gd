class_name ShopWindow
extends Window
## Boutique / garde-robe / apparence / stats / reglages.
## Fenetre sans bordure (cadre arrondi dessine en code, barre de titre maison : glisser pour deplacer,
## bords pour redimensionner, boutons reduire / fermer), mise a l'echelle DPI, mise en page adaptative.
## API : open(tab), show_tab(tab), close_shop().

signal page_shown(tab: String)

const BASE_SIZE := Vector2(1180, 740)  # px logiques (hors ombre)
const MIN_SIZE := Vector2(900, 600)
const SHADOW := 14.0  # marge transparente (ombre + zone de redimensionnement)
const TABS := [
	["head", "Chapeaux", "hat"], ["face", "Visage", "glasses"], ["neck", "Cou", "bowtie"], ["back", "Dos", "wings"],
	["look", "Apparence", "palette"], ["quests", "Quêtes", "flag"], ["stats", "Stats", "chart"], ["settings", "Réglages", "gear"],
]
const LOOK_SECTIONS := [["species", "Compagnon"], ["mat", "Matière"], ["colors", "Couleurs"], ["eye", "Yeux"], ["mouth", "Bouche"]]
const SLOT_ICONS := {"head": "hat", "face": "glasses", "neck": "bowtie", "back": "wings"}
const SLOT_TITLES := {"head": "Chapeaux", "face": "Visage", "neck": "Cou", "back": "Dos"}
const SLOT_EMPTY := {"head": "Tête nue", "face": "Rien sur le visage", "neck": "Cou dégagé", "back": "Rien dans le dos"}
const COLOR_SLOTS := [["main", "Principale"], ["accent", "Secondaire"], ["detail", "Détail"]]
const THUMB_KIND := {"item": "item", "species": "species", "mat": "material", "eye": "eye", "mouth": "mouth"}

var preview: PetStage
var preview_emotes: EmoteLayer
var thumbs: Thumbs
var tabs: UIKit.Tabs
var coin_pill: UIKit.CoinPill
var toast: UIKit.Toast
var confetti: UIKit.Confetti
var dialog: UIKit.Dialog
var close_button: Button
var min_button: Button
var name_edit: LineEdit
var preview_view: TextureRect
var outfit_chips := {}  # slot -> OutfitChip

# etat de la page courante (exposes pour les tests)
var current_tab := ""
var look_section := "species"
var cards := {}  # id -> ShopCard
var detail_buttons := {}  # buy | wear | remove | choose
var detail_swatches: UIKit.Swatches
var color_seg: UIKit.Segmented
var look_nav: UIKit.Segmented
var filter_seg: UIKit.Segmented
var settings_ctrls := {}  # key -> Toggle | Segmented
var stat_labels := {}
var fur_swatches: UIKit.Swatches
var iris_swatches: UIKit.Swatches

var _f := 1.0  # facteur DPI
var _frame: Frame
var _root: Control
var _content: Control
var _overlay: Control
var _page: Control
var _left: VBoxContainer
var _right: VBoxContainer
var _grid: GridContainer
var _scroll: ScrollContainer
var _detail: PanelContainer
var _species_label: Label
var _happy_bar: UIKit.Bar
var _energy_bar: UIKit.Bar
var _happy_pct: Label
var _energy_pct: Label
var _hunger_bar: UIKit.Bar
var _hunger_pct: Label
var _fun_bar: UIKit.Bar
var _fun_pct: Label
var _level_badge: LevelBadge
var _xp_bar: UIKit.Bar
var _xp_label: Label
var _level_label: Label
var _outfit_card: Control
var _quest_list: VBoxContainer
var quest_cards: Array = []  # PanelContainer (meta quest_id / done) - tests
var food_rows := {}  # kind -> preference affichee - tests
var level_card_label: Label
var _preview_card: PreviewCard
var _sv: SubViewport
var _hint: Control
var _sel := {}  # slot -> id essaye
var _try_colors := {}  # id -> {main, accent, detail}
var _color_slot := "main"
var _filter_owned := false
var _look_sel := {}  # section -> id selectionne
var _previewing_look := false
var _drag_rot := false
var _rot_vel := 0.0
var _refresh_t := 0.0
var _screen_t := 0.0
var _screen := -1
var _old_fps := 0
var _commit_t := -1.0
var _pending_commit := Callable()
var _closing := false
## true : fermer la cache au lieu de la detruire (le compagnon la garde prete).
var keep_alive := false
var _anim_tw: Tween
var _opened := false


func _init() -> void:
	visible = false
	borderless = true
	transparent = true
	transparent_bg = true
	wrap_controls = false
	transient = false
	exclusive = false
	unfocusable = false
	always_on_top = false
	title = "Pompom — Boutique"
	# l'anticrenelage 2D du projet ne s'applique qu'a la fenetre principale : on l'active ici
	msaa_2d = Viewport.MSAA_4X


## Construit la boutique sans l'afficher (au demarrage) : l'ouverture devient instantanee.
func prebuild() -> void:
	if _opened:
		return
	_opened = true
	theme = UITheme.theme()
	_screen = DisplayServer.window_get_current_screen()
	_apply_scale(UITheme.dpi_scale(_screen), true)
	close_requested.connect(close_shop)
	size_changed.connect(_on_resized)
	_build()
	for pair in [[GameState.coins_changed, _on_coins], [GameState.appearance_changed, _on_appearance],
			[GameState.equipment_changed, _on_equipment], [GameState.settings_changed, _on_settings],
			[GameState.needs_changed, _on_needs], [GameState.xp_changed, _on_xp], [GameState.level_up, _on_level_up],
			[GameState.quest_completed, _on_quest_completed], [GameState.stats_changed, _on_stats_changed]]:
		if not pair[0].is_connected(pair[1]):
			pair[0].connect(pair[1])


func open(tab: String) -> void:
	if _opened and visible and not _closing:
		show_tab(tab)
		return
	prebuild()
	_closing = false
	if _anim_tw:
		_anim_tw.kill()
	show()
	_on_resized()
	show_tab(tab)
	_frame.pivot_offset = _frame.size * 0.5
	_frame.modulate.a = 0.0
	_frame.scale = Vector2.ONE * 0.98
	_anim_tw = create_tween().set_parallel()
	_anim_tw.tween_property(_frame, "modulate:a", 1.0, 0.12)
	_anim_tw.tween_property(_frame, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	grab_focus()


func close_shop() -> void:
	if _closing:
		return
	_closing = true
	if not _opened or _frame == null:
		queue_free()
		return
	if _anim_tw:
		_anim_tw.kill()
	_anim_tw = create_tween().set_parallel()
	_anim_tw.tween_property(_frame, "modulate:a", 0.0, 0.1)
	_anim_tw.tween_property(_frame, "scale", Vector2.ONE * 0.98, 0.1)
	_anim_tw.chain().tween_callback(_after_close)


func _after_close() -> void:
	if not keep_alive:
		queue_free()
		return
	# gardee en memoire, cachee : la prochaine ouverture est immediate
	if is_instance_valid(dialog):
		dialog.close(false)
	hide()
	_closing = false


func _exit_tree() -> void:
	pass


## Taille en px physiques pour une taille logique donnee.
func _phys(v: Vector2) -> Vector2i:
	return Vector2i((v + Vector2(SHADOW, SHADOW) * 2.0) * _f)


func _apply_scale(f: float, recenter: bool) -> void:
	var old_logical := Vector2(size) / _f - Vector2(SHADOW, SHADOW) * 2.0 if _opened and size.x > 0 and not recenter else BASE_SIZE
	_f = f
	content_scale_factor = f
	if thumbs:
		thumbs.set_display_scale(f)
	var usable := Rect2(DisplayServer.screen_get_usable_rect(_screen if _screen >= 0 else 0))
	var max_sz := Vector2i(usable.size * 0.96)
	min_size = Vector2i(mini(_phys(MIN_SIZE).x, max_sz.x), mini(_phys(MIN_SIZE).y, max_sz.y))
	var want := _phys(old_logical)
	size = Vector2i(clampi(want.x, min_size.x, max_sz.x), clampi(want.y, min_size.y, max_sz.y))
	if recenter:
		position = Vector2i(usable.position + (usable.size - Vector2(size)) * 0.5)


func _process(delta: float) -> void:
	if _sv and not visible and _sv.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED  # cachee : l'apercu ne coute rien
	if not _opened or _closing or not visible:
		return
	# rotation de l'apercu avec inertie
	if not _drag_rot and absf(_rot_vel) > 0.01:
		preview.pet.rotation.y += _rot_vel * delta
		_rot_vel = move_toward(_rot_vel, 0.0, delta * maxf(2.0, absf(_rot_vel) * 3.0))
	# rendu de l'apercu coupe quand la fenetre est reduite
	if _sv:
		var want := SubViewport.UPDATE_DISABLED if mode == MODE_MINIMIZED else SubViewport.UPDATE_ALWAYS
		if _sv.render_target_update_mode != want:
			_sv.render_target_update_mode = want
	if _commit_t >= 0.0:
		_commit_t -= delta
		if _commit_t < 0.0 and _pending_commit.is_valid():
			_pending_commit.call()
			_pending_commit = Callable()
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 1.0
		_update_mood()
		if current_tab == "stats":
			_update_stats()
		elif current_tab == "quests":
			_update_quest_progress()
	_screen_t -= delta
	if _screen_t <= 0.0:
		_screen_t = 0.5
		var sc := current_screen
		if sc != _screen:
			_screen = sc
			var nf := UITheme.dpi_scale(sc)
			if not is_equal_approx(nf, _f):
				_apply_scale(nf, false)


# =========================================================================== structure
func _build() -> void:
	_frame = Frame.new()
	_frame.win = self
	_frame.margin = SHADOW
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)

	_root = MarginContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "bottom"]:
		_root.add_theme_constant_override("margin_" + side, int(SHADOW + 20))
	_root.add_theme_constant_override("margin_top", int(SHADOW + 8))
	_frame.add_child(_root)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(col)
	col.add_child(_build_titlebar())

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	_left = _build_left()
	row.add_child(_left)

	_right = VBoxContainer.new()
	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right.add_theme_constant_override("separation", 16)
	_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_right)
	tabs = UIKit.Tabs.new(TABS)
	tabs.tab_selected.connect(show_tab)
	_right.add_child(tabs)
	_content = Control.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.resized.connect(_update_grid_columns)
	_right.add_child(_content)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_overlay)
	toast = UIKit.Toast.new()
	_overlay.add_child(toast)

	thumbs = Thumbs.new()
	thumbs.set_display_scale(_f)
	add_child(thumbs)
	_update_mood(false)
	_refresh_outfit()


func _build_titlebar() -> Control:
	var bar := TitleBar.new()
	bar.win = self
	bar.custom_minimum_size.y = 52
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.add_theme_constant_override("separation", 12)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(h)
	var logo := Logo.new()
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(logo)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", -4)
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(tv)
	tv.add_child(UITheme.label("Pompom", UITheme.FS_TITLE, UITheme.INK, 700))
	tv.add_child(UITheme.label("Boutique & garde-robe", UITheme.FS_SMALL, UITheme.MUTED))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(sp)
	coin_pill = UIKit.CoinPill.new(GameState.coins)
	coin_pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	h.add_child(coin_pill)
	var gap := Control.new()
	gap.custom_minimum_size.x = 4
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(gap)
	min_button = WinBtn.new("minus", UITheme.LAVENDER, "Réduire")
	min_button.pressed.connect(func(): mode = MODE_MINIMIZED)
	h.add_child(min_button)
	close_button = WinBtn.new("close", UITheme.BAD, "Fermer")
	close_button.pressed.connect(close_shop)
	h.add_child(close_button)
	return bar


func _build_left() -> VBoxContainer:
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 312
	left.add_theme_constant_override("separation", 16)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.glass(24, 0, 0.88))
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)

	_preview_card = PreviewCard.new()
	_preview_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_card.custom_minimum_size = Vector2(0, 180)
	_preview_card.tint = GameState.current_fur_color()
	v.add_child(_preview_card)
	_sv = SubViewport.new()
	_sv.transparent_bg = true
	_sv.own_world_3d = true
	_sv.msaa_3d = Viewport.MSAA_4X
	_sv.msaa_2d = Viewport.MSAA_4X  # bulle / emotions dessinees dans l'apercu
	_sv.scaling_3d_scale = 2.0
	_sv.size = Vector2i(300, 360)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_card.add_child(_sv)
	preview = PetStage.new()
	_sv.add_child(preview)
	preview.build_from_state(12)
	_studio_env()
	var layer := CanvasLayer.new()
	_sv.add_child(layer)
	preview_emotes = EmoteLayer.new()
	preview_emotes.stage = preview
	preview_emotes.bubble_scale = 0.62
	layer.add_child(preview_emotes)
	preview_emotes.bind_pet(preview.pet)
	preview_view = TextureRect.new()
	preview_view.texture = _sv.get_texture()
	preview_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview_view.stretch_mode = TextureRect.STRETCH_SCALE
	preview_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview_view.mouse_default_cursor_shape = Control.CURSOR_DRAG
	preview_view.gui_input.connect(_on_preview_input)
	preview_view.resized.connect(_frame_preview)
	_preview_card.add_child(preview_view)
	confetti = UIKit.Confetti.new()
	_preview_card.add_child(confetti)
	# bouton "remettre de face"
	var reset := WinBtn.new("rotate", UITheme.ACCENT, "Remettre de face")
	reset.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 12)
	reset.pressed.connect(func():
		_rot_vel = 0.0
		var t := create_tween()
		var r := wrapf(preview.pet.rotation.y, -PI, PI)
		preview.pet.rotation.y = r
		t.tween_property(preview.pet, "rotation:y", 0.0, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	reset.solid_bg = true
	_preview_card.add_child(reset)
	# astuce en bas
	_hint = Hint.new()
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE, 12)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_preview_card.add_child(_hint)

	# infos : nom, espece, humeur
	var info := MarginContainer.new()
	for s in ["left", "right"]:
		info.add_theme_constant_override("margin_" + s, 18)
	info.add_theme_constant_override("margin_top", 10)
	info.add_theme_constant_override("margin_bottom", 18)
	v.add_child(info)
	var ib := VBoxContainer.new()
	ib.add_theme_constant_override("separation", 6)
	info.add_child(ib)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	ib.add_child(name_row)
	name_edit = LineEdit.new()
	name_edit.text = GameState.pet_name
	name_edit.placeholder_text = "Nom de ton compagnon"
	name_edit.max_length = 18
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.add_theme_font_override("font", UITheme.font(700))
	name_edit.add_theme_font_size_override("font_size", 22)
	name_edit.add_theme_color_override("font_color", UITheme.INK)
	name_edit.tooltip_text = "Clique pour le renommer"
	name_edit.text_changed.connect(_on_name_changed)
	name_edit.text_submitted.connect(func(_t: String): name_edit.release_focus())
	name_row.add_child(name_edit)
	var pen := UIKit.icon("pencil", 18.0, UITheme.FAINT)
	pen.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(pen)
	_species_label = UITheme.label("", UITheme.FS_SMALL + 1, UITheme.MUTED)
	_species_label.add_theme_constant_override("line_spacing", 0)
	var sl_m := MarginContainer.new()
	sl_m.add_theme_constant_override("margin_left", 6)
	sl_m.add_theme_constant_override("margin_top", -6)
	sl_m.add_child(_species_label)
	ib.add_child(sl_m)
	# niveau + XP
	var lv_row := HBoxContainer.new()
	lv_row.add_theme_constant_override("separation", 10)
	lv_row.tooltip_text = "Gagne de l'XP pour débloquer de nouveaux compagnons"
	ib.add_child(lv_row)
	_level_badge = LevelBadge.new()
	_level_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lv_row.add_child(_level_badge)
	var lv_v := VBoxContainer.new()
	lv_v.add_theme_constant_override("separation", 3)
	lv_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lv_row.add_child(lv_v)
	var lv_t := HBoxContainer.new()
	lv_v.add_child(lv_t)
	_level_label = UITheme.label("", UITheme.FS_SMALL + 1, UITheme.INK, 650)
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_t.add_child(_level_label)
	_xp_label = UITheme.label("", UITheme.FS_TINY, UITheme.MUTED, 650)
	lv_t.add_child(_xp_label)
	_xp_bar = UIKit.Bar.new(UITheme.GOLD)
	_xp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_v.add_child(_xp_bar)
	var sp := Control.new()
	sp.custom_minimum_size.y = 2
	ib.add_child(sp)
	var hb := _mood_row(ib, "heart", "Bonheur", UITheme.ACCENT)
	_happy_bar = hb[0]
	_happy_pct = hb[1]
	var eb := _mood_row(ib, "bolt", "Énergie", UITheme.LAVENDER)
	_energy_bar = eb[0]
	_energy_pct = eb[1]
	var fb := _mood_row(ib, "apple", "Faim", UITheme.PEACH, "Faim : 100 % = bien nourri. Glisse des fichiers sur lui pour le nourrir !")
	_hunger_bar = fb[0]
	_hunger_pct = fb[1]
	var ub := _mood_row(ib, "star", "Amusement", UITheme.SKY, "Amusement : joue avec lui (câlins, lancers, coucous)")
	_fun_bar = ub[0]
	_fun_pct = ub[1]
	_update_species_label()

	# tenue actuelle
	var outfit := PanelContainer.new()
	outfit.add_theme_stylebox_override("panel", UITheme.glass(20, 12, 0.82))
	left.add_child(outfit)
	_outfit_card = outfit
	var oh := HBoxContainer.new()
	oh.add_theme_constant_override("separation", 8)
	outfit.add_child(oh)
	var ol := UITheme.label("Tenue", UITheme.FS_SMALL + 1, UITheme.INK, 650)
	ol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ol.custom_minimum_size.x = 44
	oh.add_child(ol)
	for slot in Data.SLOTS:
		var chip := OutfitChip.new(slot)
		chip.pressed.connect(show_tab.bind(slot))
		oh.add_child(chip)
		outfit_chips[slot] = chip
	return left


func _mood_row(parent: Control, icon_name: String, label_text: String, color: Color, tip := "") -> Array:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.tooltip_text = tip if tip != "" else label_text
	parent.add_child(h)
	var ic := UIKit.IconBubble.new(icon_name, 24.0, color)
	h.add_child(ic)
	var l := UITheme.label(label_text, UITheme.FS_SMALL + 1, UITheme.BODY, 650)
	l.custom_minimum_size.x = 84
	h.add_child(l)
	var bar := UIKit.Bar.new(color)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bar)
	var pct := UITheme.label("", UITheme.FS_SMALL, UITheme.MUTED, 650)
	pct.custom_minimum_size.x = 42
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(pct)
	return [bar, pct]


func _studio_env() -> void:
	preview.pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.9)


func _frame_preview() -> void:
	if not is_instance_valid(preview_view) or preview_view.size.y < 10:
		return
	var px := Vector2i((preview_view.size * _f).round())
	if _sv.size != px:
		_sv.size = px
	var sz := Vector2(px)
	preview.frame(sz, sz.y / 2.35, sz.y * 0.14)


func _update_species_label() -> void:
	var sp: Dictionary = Data.SPECIES[GameState.species]
	var mat: Dictionary = Data.MATERIALS[GameState.material]
	_species_label.text = "%s · %s" % [sp["name"], mat["name"]]


func _update_mood(animate := true) -> void:
	_happy_bar.set_value(GameState.happiness, animate)
	_energy_bar.set_value(GameState.energy, animate)
	_happy_pct.text = "%d %%" % int(round(GameState.happiness))
	_energy_pct.text = "%d %%" % int(round(GameState.energy))
	# faim affichee comme satiete : basse = rouge
	var hungry := GameState.hunger < 25.0
	_hunger_bar.color = UITheme.BAD if hungry else UITheme.PEACH
	_hunger_bar.set_value(GameState.hunger, animate)
	_hunger_bar.queue_redraw()
	_hunger_pct.text = "%d\u00a0%%" % int(round(GameState.hunger))
	_hunger_pct.add_theme_color_override("font_color", UITheme.BAD if hungry else UITheme.MUTED)
	_fun_bar.set_value(GameState.fun, animate)
	_fun_pct.text = "%d\u00a0%%" % int(round(GameState.fun))
	_update_level(animate)


func _update_level(animate := true) -> void:
	var need := Data.xp_for_next(GameState.level)
	_level_badge.level = GameState.level
	_level_badge.queue_redraw()
	_level_label.text = "Niveau %d" % GameState.level
	_xp_label.text = "%d / %d XP" % [GameState.xp, need]
	_xp_bar.set_value(100.0 * GameState.xp / maxf(1.0, need), animate)


func _on_name_changed(t: String) -> void:
	GameState.pet_name = t.strip_edges() if t.strip_edges() != "" else Data.SPECIES[GameState.species]["name"]
	GameState.mark_dirty()


func _on_preview_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		_drag_rot = ev.pressed
		if ev.pressed:
			_rot_vel = 0.0
			if ev.double_click:
				preview.pet.act_spin()
	elif ev is InputEventMouseMotion and _drag_rot:
		preview.pet.rotation.y += ev.relative.x * 0.012
		_rot_vel = ev.relative.x * 0.012 / maxf(get_process_delta_time(), 0.008)
		_rot_vel = clampf(_rot_vel, -12.0, 12.0)
		preview.pet.push_accel(Vector2(ev.relative.x * 3.0, 0), 0.016)
		if _hint.visible:
			_hint.dismiss()


func _rebuild_preview() -> void:
	var rot := preview.pet.rotation.y
	preview.build_from_state(12)
	_studio_env()
	preview.pet.rotation.y = rot
	_previewing_look = false
	_preview_card.tint = GameState.current_fur_color()
	_preview_card.queue_redraw()


## Remet la tenue portee sur l'apercu (sauf l'emplacement en cours d'essayage).
func _sync_preview(keep_slot := "") -> void:
	if _previewing_look:
		_rebuild_preview()
	for slot in Data.SLOTS:
		if slot == keep_slot:
			continue
		var id: String = GameState.equipped.get(slot, "")
		if preview.pet.slot_items.get(slot, "") != id:
			preview.pet.set_item(slot, id, GameState.colors_for(id) if id != "" else {}, false)


func _on_resized() -> void:
	if not _opened or _frame == null:
		return
	var logical := Vector2(size) / _f
	var narrow := logical.x < 1060.0
	_left.custom_minimum_size.x = 272 if narrow else 312
	var right_w := logical.x - SHADOW * 2 - 40 - _left.custom_minimum_size.x - 20
	tabs.set_compact(tabs.full_width() > right_w)
	# fenetre basse : on cache la tenue pour laisser de la place a l'apercu
	_outfit_card.visible = logical.y >= 700.0
	_update_grid_columns.call_deferred()
	_frame_preview.call_deferred()
	_update_detail_layout.call_deferred()
	_frame.pivot_offset = _frame.size * 0.5


## Fenetre etroite : la miniature du panneau de detail est masquee (la carte la montre deja).
func _update_detail_layout() -> void:
	if is_instance_valid(_detail):
		var tile := _detail.find_child("DetailThumb", true, false)
		if tile:
			tile.visible = _content.size.x >= 660.0


func _update_grid_columns() -> void:
	if not is_instance_valid(_grid) or not is_instance_valid(_scroll):
		return
	# largeur prise sur _content (Control simple) : pas de boucle "plus de colonnes -> plus large"
	var w := _content.size.x - 20.0 - 14.0
	var gap := 14.0
	var cols := maxi(1, int(floor((w + gap) / (ShopCard.W + gap))))
	if _grid.columns != cols:
		_grid.columns = cols


# =========================================================================== onglets
func show_tab(tab: String) -> void:
	if not _opened:
		return
	var restore := mode == MODE_MINIMIZED or not visible
	if mode == MODE_MINIMIZED:
		mode = MODE_WINDOWED
	if not visible:
		show()
	if restore:
		grab_focus()  # ramene la boutique au premier plan apres une reduction
	var valid := false
	for t in TABS:
		valid = valid or t[0] == tab
	if not valid:
		tab = "head"
	if tab == current_tab and is_instance_valid(_page):
		grab_focus()
		return
	var old := current_tab
	current_tab = tab
	tabs.select(tab)
	if is_instance_valid(dialog):
		dialog.close(false)
	if _page:
		_page.queue_free()
		_page = null
	cards.clear()
	detail_buttons.clear()
	detail_swatches = null
	color_seg = null
	filter_seg = null
	look_nav = null
	fur_swatches = null
	iris_swatches = null
	settings_ctrls.clear()
	stat_labels.clear()
	_grid = null
	_scroll = null
	_detail = null
	# un essai non valide est oublie quand on quitte l'onglet : on revient sur la tenue portee
	if old in Data.SLOTS:
		_sel.erase(old)
	if old in Data.SLOTS or old == "look" or tab == "look":
		_sync_preview(tab if tab in Data.SLOTS else "")
	match tab:
		"look":
			_page = _build_look_page()
		"stats":
			_page = _build_stats_page()
		"quests":
			_page = _build_quests_page()
		"settings":
			_page = _build_settings_page()
		_:
			_page = _build_items_page(tab)
	_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.add_child(_page)
	# apparition : fondu + leger glissement (on anime les offsets, pas la position, pour garder l'ancrage plein cadre)
	_page.modulate.a = 0.0
	_page.offset_top = 10
	_page.offset_bottom = 10
	var t := create_tween().set_parallel()
	t.tween_property(_page, "modulate:a", 1.0, 0.18)
	t.tween_property(_page, "offset_top", 0.0, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(_page, "offset_bottom", 0.0, 0.25).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_update_grid_columns.call_deferred()
	page_shown.emit(tab)


func _page_header(text: String, icon_name: String, sub: String, tint := UITheme.ACCENT) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var h := UIKit.header(text, icon_name, sub, tint)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(h)
	return row


func _make_grid(parent: Control) -> void:
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.resized.connect(_update_grid_columns)
	parent.add_child(_scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "top", "right", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 8)
	m.add_theme_constant_override("margin_right", 12)
	_scroll.add_child(m)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.columns = 4
	m.add_child(_grid)


func _add_card(card: ShopCard, index: int) -> void:
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(card)
	cards[card.item_id] = card
	card.pop_in(minf(index * 0.02, 0.3))


func _request_thumb(kind: String, id: String, cb: Callable) -> void:
	if THUMB_KIND.has(kind):
		thumbs.request(THUMB_KIND[kind], id, cb)


# =========================================================================== accessoires
func _slot_ids(slot: String) -> Array:
	var ids: Array = []
	for id in Data.ITEMS:
		if Data.ITEMS[id].get("slot", "") == slot:
			ids.append(id)
	ids.sort_custom(func(a, b):
		var pa := int(Data.ITEMS[a]["price"])
		var pb := int(Data.ITEMS[b]["price"])
		return pa < pb if pa != pb else str(a) < str(b))
	return ids


func _build_items_page(slot: String) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var ids := _slot_ids(slot)
	var n_owned := 0
	for id in ids:
		if GameState.owned.has(id):
			n_owned += 1
	var head := _page_header(SLOT_TITLES[slot], SLOT_ICONS[slot], "%d / %d dans ta collection" % [n_owned, ids.size()], _slot_tint(slot))
	filter_seg = UIKit.Segmented.new(["Tout", "À moi"], 1 if _filter_owned else 0)
	filter_seg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	filter_seg.custom_minimum_size.x = 170
	filter_seg.changed.connect(func(i: int):
		_filter_owned = i == 1
		_fill_items_grid(slot))
	head.add_child(filter_seg)
	v.add_child(head)
	_make_grid(v)
	_detail = _detail_panel()
	v.add_child(_detail)
	_fill_items_grid(slot)
	var cur: String = _sel.get(slot, GameState.equipped.get(slot, ""))
	_select_item(slot, cur, false)
	return v


func _fill_items_grid(slot: String) -> void:
	for c in _grid.get_children():
		c.queue_free()
	cards.clear()
	var none := ShopCard.new().setup("none", "", "Aucun")
	none.icon_name = "none"
	none.status_text = SLOT_EMPTY[slot]
	none.tint = _slot_tint(slot).lerp(Color.WHITE, 0.7)
	none.pressed.connect(_select_item.bind(slot, "", true))
	_add_card(none, 0)
	var i := 1
	var shown := 0
	for id in _slot_ids(slot):
		if _filter_owned and not GameState.owned.has(id):
			continue
		var item: Dictionary = Data.ITEMS[id]
		var card := ShopCard.new().setup("item", id, item["name"])
		card.tint = _slot_tint(slot).lerp(Color.WHITE, 0.72)
		card.pressed.connect(_select_item.bind(slot, id, true))
		_add_card(card, i)
		_request_thumb("item", id, card.set_thumb)
		i += 1
		shown += 1
	if _filter_owned and shown == 0:
		var empty := UITheme.label("Rien ici pour l'instant… Choisis « Tout » pour découvrir la boutique !", UITheme.FS_BODY, UITheme.MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size.x = 260
		_grid.add_child(empty)
	_refresh_item_cards(slot)


func _slot_tint(slot: String) -> Color:
	return {"head": UITheme.ACCENT, "face": UITheme.SKY, "neck": UITheme.LAVENDER, "back": UITheme.PEACH}.get(slot, UITheme.ACCENT)


func _refresh_item_cards(slot: String) -> void:
	var sel: String = _sel.get(slot, GameState.equipped.get(slot, ""))
	for id in cards:
		var card: ShopCard = cards[id]
		if not is_instance_valid(card):
			continue
		if id == "":
			card.set_state(0, true, GameState.equipped.get(slot, "") == "", true)
		else:
			var price := int(Data.ITEMS[id]["price"])
			card.set_state(price, GameState.owned.has(id), GameState.is_equipped(id), GameState.coins >= price, GameState.discovered_level(id))
		card.set_pressed_no_signal(id == sel)
		card.refresh_selected()


func _select_item(slot: String, id: String, react := true) -> void:
	if id != "" and not Data.ITEMS.has(id):
		id = ""
	_sel[slot] = id
	_previewing_look = false
	if id == "":
		preview.pet.set_item(slot, "", {}, false)
		if react and GameState.equipped.get(slot, "") != "":
			GameState.unequip(slot)
	else:
		if not _try_colors.has(id):
			_try_colors[id] = GameState.colors_for(id)
		var same: bool = preview.pet.slot_items.get(slot, "") == id
		if not same or react:
			preview.pet.set_item(slot, id, _try_colors[id], react)
		if react:
			var level := Data.preference(GameState.species, id, _try_colors[id]["main"])
			GameState.discover(id, level)
			preview.pet.react_to_item(level)
			preview_emotes.say(Data.line(level), 2.4)
	_refresh_item_cards(slot)
	_fill_item_detail(slot, id)


func _detail_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.glass(22, 16, 0.9))
	p.custom_minimum_size.y = 168
	return p


func _detail_row() -> HBoxContainer:
	for c in _detail.get_children():
		c.queue_free()
	detail_buttons.clear()
	detail_swatches = null
	color_seg = null
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	_detail.add_child(row)
	return row


func _detail_thumb(row: Control, kind: String, id: String, tint: Color, icon_name := "") -> void:
	var tile := PanelContainer.new()
	tile.add_theme_stylebox_override("panel", UITheme.box(tint.lerp(Color.WHITE, 0.6), 20, Color.TRANSPARENT, 0, 6))
	tile.custom_minimum_size = Vector2(116, 116)
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tile.name = "DetailThumb"
	tile.visible = _content.size.x >= 660.0
	row.add_child(tile)
	if icon_name != "":
		var ic := UIKit.icon(icon_name, 48.0, UITheme.FAINT)
		ic.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tile.add_child(ic)
		return
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tile.add_child(tr)
	_request_thumb(kind, id, tr.set_texture)


func _pref_chip(level: int) -> Control:
	var col := ShopCard._pref_color(level)
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UITheme.pill(col.lerp(Color.WHITE, 0.85), 10, 3))
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 5)
	chip.add_child(h)
	var ic := UIKit.icon("pref_%d" % level, 16.0, col.darkened(0.1))
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	var verb: String = {2: "adore", 1: "aime", 0: "trouve ça bof", -1: "n'aime pas", -2: "déteste"}.get(level, "trouve ça bof")
	h.add_child(UITheme.label("%s %s" % [GameState.pet_name, verb], UITheme.FS_SMALL, col.darkened(0.25), 650))
	return chip


func _fill_item_detail(slot: String, id: String) -> void:
	if not is_instance_valid(_detail):
		return
	var row := _detail_row()
	if id == "":
		_detail_thumb(row, "", "", _slot_tint(slot), "none")
		var tv := VBoxContainer.new()
		tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tv.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_child(tv)
		tv.add_child(UITheme.label(SLOT_EMPTY[slot], UITheme.FS_H2 + 2, UITheme.INK, 650))
		var d := UITheme.label("Choisis un objet pour l'essayer sur %s. Tu peux l'essayer gratuitement avant de l'acheter !" % GameState.pet_name,
			UITheme.FS_BODY - 1, UITheme.MUTED)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tv.add_child(d)
		return
	var item: Dictionary = Data.ITEMS[id]
	_detail_thumb(row, "item", id, _slot_tint(slot))
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 6)
	row.add_child(mid)
	var tr := HBoxContainer.new()
	tr.add_theme_constant_override("separation", 10)
	mid.add_child(tr)
	var t := UITheme.label(item["name"], UITheme.FS_H2 + 2, UITheme.INK, 650)
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.clip_text = true
	tr.add_child(t)
	var lv = GameState.discovered_level(id)
	if lv != null:
		tr.add_child(_pref_chip(int(lv)))
	var d2 := UITheme.label(str(item.get("desc", "")), UITheme.FS_BODY - 1, UITheme.MUTED)
	d2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d2.max_lines_visible = 2
	mid.add_child(d2)
	# couleurs
	var labels := []
	for cs in COLOR_SLOTS:
		labels.append(cs[1])
	var ci := 0
	for k in COLOR_SLOTS.size():
		if COLOR_SLOTS[k][0] == _color_slot:
			ci = k
	color_seg = UIKit.Segmented.new(labels, ci)
	color_seg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mid.add_child(color_seg)
	detail_swatches = UIKit.Swatches.new(Data.PALETTE, _try_colors[id][_color_slot])
	mid.add_child(detail_swatches)
	color_seg.changed.connect(func(i: int):
		_color_slot = COLOR_SLOTS[i][0]
		if detail_swatches:
			detail_swatches.set_current(_try_colors[id][_color_slot]))
	detail_swatches.picked.connect(func(c: Color, final: bool): _set_try_color(slot, id, _color_slot, c, final))
	# action
	var act := VBoxContainer.new()
	act.custom_minimum_size.x = 180
	act.alignment = BoxContainer.ALIGNMENT_CENTER
	act.add_theme_constant_override("separation", 8)
	row.add_child(act)
	var price := int(item["price"])
	if not GameState.owned.has(id):
		var can := GameState.coins >= price
		var buy := _price_button("Acheter", price, can)
		buy.pressed.connect(_ask_buy_item.bind(slot, id))
		act.add_child(buy)
		detail_buttons["buy"] = buy
		var hint := UITheme.label("Essayé sur %s" % GameState.pet_name if can else "Il te manque %s pièces" % UIKit.fmt(price - GameState.coins),
			UITheme.FS_SMALL, UITheme.MUTED)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		act.add_child(hint)
	elif GameState.is_equipped(id):
		var rm := Button.new()
		rm.text = "Retirer"
		rm.custom_minimum_size = Vector2(0, 48)
		rm.pressed.connect(func():
			GameState.unequip(slot)
			_select_item(slot, "", false))
		act.add_child(rm)
		detail_buttons["remove"] = rm
		var ok := UITheme.label("%s le porte" % GameState.pet_name, UITheme.FS_SMALL, UITheme.MINT.darkened(0.2), 650)
		ok.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		act.add_child(ok)
	else:
		var wear := Button.new()
		wear.text = "Porter"
		wear.theme_type_variation = "PrimaryButton"
		wear.custom_minimum_size = Vector2(0, 48)
		wear.pressed.connect(func():
			_commit_try_colors(id)
			GameState.equip(id)
			_refresh_item_cards(slot)
			_fill_item_detail(slot, id))
		act.add_child(wear)
		detail_buttons["wear"] = wear
		var own := UITheme.label("Dans ta collection", UITheme.FS_SMALL, UITheme.LAVENDER.darkened(0.25), 650)
		own.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		act.add_child(own)


## Bouton principal "Acheter (piece) 120".
func _price_button(text: String, price: int, enabled: bool) -> Button:
	var b := Button.new()
	b.theme_type_variation = "PrimaryButton"
	b.custom_minimum_size = Vector2(0, 48)
	b.disabled = not enabled
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_FORBIDDEN
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	var fg := Color.WHITE if enabled else UITheme.MUTED
	if not enabled:
		var lk := UIKit.icon("lock", 18.0, fg)
		lk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(lk)
	h.add_child(UITheme.label(text, UITheme.FS_BODY + 1, fg, 650))
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", UITheme.pill(Color(1, 1, 1, 0.25) if enabled else Color(1, 1, 1, 0.6), 8, 2))
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(pill)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 4)
	ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(ph)
	var ci := UIKit.icon("coin", 16.0)
	ci.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ph.add_child(ci)
	ph.add_child(UITheme.label(UIKit.fmt(price), UITheme.FS_SMALL + 1, fg, 650))
	return b


func _commit_try_colors(id: String) -> void:
	if not _try_colors.has(id) or not GameState.owned.has(id):
		return
	var cur := GameState.colors_for(id)
	for k in _try_colors[id]:
		if not Color(cur[k]).is_equal_approx(_try_colors[id][k]):
			GameState.set_item_color(id, k, _try_colors[id][k])


func _set_try_color(slot: String, id: String, which: String, c: Color, final: bool) -> void:
	if not _try_colors.has(id):
		_try_colors[id] = GameState.colors_for(id)
	_try_colors[id][which] = c
	preview.pet.set_item(slot, id, _try_colors[id], false)
	if not final:
		return
	if GameState.owned.has(id):
		_commit_try_colors(id)
		if cards.has(id) and is_instance_valid(cards[id]):
			_request_thumb("item", id, cards[id].set_thumb)
		_refresh_outfit()
	if which == "main" and Data.is_fav_color(GameState.species, c):
		preview_emotes.say(Data.line("fav_color"), 2.0)
		preview.pet.act_love()


func _ask_buy_item(slot: String, id: String) -> void:
	var item: Dictionary = Data.ITEMS[id]
	var price := int(item["price"])
	if GameState.owned.has(id) or GameState.coins < price:
		return
	var tex = Thumbs.best("item", id)
	_ask("Acheter « %s » ?" % item["name"], "%s pourra le porter tout de suite. Tu gardes les couleurs que tu as choisies." % GameState.pet_name,
		"Acheter", tex if tex else SLOT_ICONS[slot], price, func():
			if GameState.buy(id):
				_commit_try_colors(id)
				GameState.equip(id)
				_celebrate("%s est à toi !" % item["name"])
				if _filter_owned:
					_fill_items_grid(slot)
				else:
					_refresh_item_cards(slot)
				_fill_item_detail(slot, id)
				_update_collection_count(slot))


func _update_collection_count(slot: String) -> void:
	if not is_instance_valid(_page):
		return
	var sub: Label = _page.find_child("Sub", true, false)
	if sub:
		var ids := _slot_ids(slot)
		var n := 0
		for i in ids:
			if GameState.owned.has(i):
				n += 1
		sub.text = "%d / %d dans ta collection" % [n, ids.size()]


func _ask(title_text: String, body: String, ok_text: String, icon, price: int, on_ok: Callable, on_cancel := Callable()) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()
	dialog = UIKit.Dialog.new(title_text, body, ok_text, "Non merci", icon, price, GameState.coins - price if price >= 0 else -1)
	_overlay.add_child(dialog)
	dialog.closed.connect(func(ok: bool):
		if ok:
			on_ok.call()
		elif on_cancel.is_valid():
			on_cancel.call())


func _celebrate(text: String) -> void:
	var c := confetti.size
	confetti.burst(Vector2(c.x * 0.5, c.y * 0.45))
	toast.show_msg(text, "sparkle", UITheme.ACCENT)
	preview_emotes.emit_emote("sparkle", 4)
	preview.pet.act_love()


# =========================================================================== apparence
func _build_look_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var head := _page_header("Apparence", "palette", "Espèce, matière, couleurs, yeux et bouche", UITheme.LAVENDER)
	v.add_child(head)
	var labels := []
	var sel := 0
	for i in LOOK_SECTIONS.size():
		labels.append(LOOK_SECTIONS[i][1])
		if LOOK_SECTIONS[i][0] == look_section:
			sel = i
	look_nav = UIKit.Segmented.new(labels, sel)
	look_nav.changed.connect(func(i: int): _show_look_section(LOOK_SECTIONS[i][0]))
	v.add_child(look_nav)
	var holder := VBoxContainer.new()
	holder.name = "LookHolder"
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", 12)
	v.add_child(holder)
	_fill_look_section(holder)
	return v


func _show_look_section(section: String) -> void:
	look_section = section
	if _previewing_look:
		_rebuild_preview()
	var holder: Control = _page.find_child("LookHolder", true, false) if is_instance_valid(_page) else null
	if holder == null:
		return
	for c in holder.get_children():
		c.queue_free()
	cards.clear()
	detail_buttons.clear()
	fur_swatches = null
	iris_swatches = null
	_grid = null
	_scroll = null
	_detail = null
	_fill_look_section(holder)
	_update_grid_columns.call_deferred()


func _fill_look_section(holder: Control) -> void:
	if look_section == "colors":
		_fill_colors(holder)
		return
	_make_grid(holder)
	_detail = _detail_panel()
	_detail.custom_minimum_size.y = 150
	holder.add_child(_detail)
	var i := 0
	for id in _look_ids(look_section):
		var card := ShopCard.new().setup(look_section, id, _look_name(look_section, id))
		card.tint = UITheme.LAVENDER.lerp(Color.WHITE, 0.75)
		card.pressed.connect(_look_pressed.bind(look_section, id))
		_add_card(card, i)
		_request_thumb(look_section, id, card.set_thumb)
		i += 1
	_refresh_look_cards()
	var cur: String = _look_sel.get(look_section, _look_current(look_section))
	_fill_look_detail(look_section, cur)


func _look_ids(section: String) -> Array:
	var table: Dictionary = {"species": Data.SPECIES, "mat": Data.MATERIALS, "eye": Data.EYES, "mouth": Data.MOUTHS}[section]
	var ids: Array = table.keys()
	if section == "species":
		ids.sort_custom(func(a, b): return int(Data.SPECIES_LEVEL.get(a, 1)) < int(Data.SPECIES_LEVEL.get(b, 1)))
	else:
		ids.sort_custom(func(a, b):
			var pa := int(table[a].get("price", 0))
			var pb := int(table[b].get("price", 0))
			return pa < pb if pa != pb else str(a) < str(b))
	return ids


func _look_entry(section: String, id: String) -> Dictionary:
	var table: Dictionary = {"species": Data.SPECIES, "mat": Data.MATERIALS, "eye": Data.EYES, "mouth": Data.MOUTHS}[section]
	return table.get(id, {})


func _look_name(section: String, id: String) -> String:
	return str(_look_entry(section, id).get("name", id.capitalize()))


func _look_current(section: String) -> String:
	match section:
		"species": return GameState.species
		"mat": return GameState.material
		"eye": return GameState.current_eye_style()
		"mouth": return GameState.mouth_style
	return ""


func _look_owned(section: String, id: String) -> bool:
	if section == "species":
		return GameState.species_unlocked(id)
	return GameState.owns_look("%s:%s" % [section, id])


## Niveau requis pour une espece encore verrouillee (0 = disponible).
func _species_lock(id: String) -> int:
	if GameState.species_unlocked(id):
		return 0
	return int(Data.SPECIES_LEVEL.get(id, 1))


func _look_price(section: String, id: String) -> int:
	return 0 if section == "species" else GameState.look_price("%s:%s" % [section, id])


func _refresh_look_cards() -> void:
	var cur := _look_current(look_section)
	var sel: String = _look_sel.get(look_section, cur)
	for id in cards:
		var card: ShopCard = cards[id]
		if not is_instance_valid(card):
			continue
		var price := _look_price(look_section, id)
		var lock := _species_lock(id) if look_section == "species" else 0
		card.locked_text = "Niveau %d" % lock if lock > 0 else ""
		card.set_state(price, _look_owned(look_section, id), id == cur, GameState.coins >= price)
		card.set_pressed_no_signal(id == sel)
		card.refresh_selected()


func _look_pressed(section: String, id: String) -> void:
	_look_sel[section] = id
	if section == "species" and _species_lock(id) > 0:
		# espece verrouillee : apercu seulement
		_preview_species(id)
		preview_emotes.say("Débloqué au niveau %d !" % _species_lock(id), 2.4)
	elif _look_owned(section, id):
		if id != _look_current(section):
			if section == "species":
				GameState.set_species(id)
			else:
				GameState.set_look(section, id)
		elif _previewing_look:
			_rebuild_preview()
	else:
		_preview_look(section, id)
		var price := _look_price(section, id)
		if GameState.coins < price:
			preview_emotes.say("Il manque %s pièces…" % UIKit.fmt(price - GameState.coins), 2.0)
	_refresh_look_cards()
	_fill_look_detail(section, id)


func _fill_look_detail(section: String, id: String) -> void:
	if not is_instance_valid(_detail):
		return
	var row := _detail_row()
	var e := _look_entry(section, id)
	_detail_thumb(row, section, id, UITheme.LAVENDER)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	mid.add_theme_constant_override("separation", 6)
	row.add_child(mid)
	mid.add_child(UITheme.label(_look_name(section, id), UITheme.FS_H2 + 2, UITheme.INK, 650))
	var desc := str(e.get("desc", ""))
	if desc == "":
		desc = {"eye": "Un nouveau regard pour %s." % GameState.pet_name, "mouth": "Une nouvelle frimousse pour %s." % GameState.pet_name}.get(section, "")
	var d := UITheme.label(desc, UITheme.FS_BODY - 1, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.max_lines_visible = 3
	mid.add_child(d)
	var act := VBoxContainer.new()
	act.custom_minimum_size.x = 180
	act.alignment = BoxContainer.ALIGNMENT_CENTER
	act.add_theme_constant_override("separation", 8)
	row.add_child(act)
	if section == "species" and _species_lock(id) > 0:
		var need := _species_lock(id)
		var lb := Button.new()
		lb.theme_type_variation = "PrimaryButton"
		lb.disabled = true
		lb.custom_minimum_size = Vector2(0, 48)
		lb.mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
		var lh := HBoxContainer.new()
		lh.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lh.alignment = BoxContainer.ALIGNMENT_CENTER
		lh.add_theme_constant_override("separation", 8)
		lh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lb.add_child(lh)
		var lk := UIKit.icon("lock", 18.0, UITheme.MUTED)
		lk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lh.add_child(lk)
		lh.add_child(UITheme.label("Niveau %d requis" % need, UITheme.FS_BODY, UITheme.MUTED, 650))
		act.add_child(lb)
		detail_buttons["locked"] = lb
		var missing := 0
		for l in range(GameState.level, need):
			missing += Data.xp_for_next(l)
		missing -= GameState.xp
		var hint := UITheme.label("Encore %s XP" % UIKit.fmt(maxi(missing, 0)), UITheme.FS_SMALL, UITheme.MUTED)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		act.add_child(hint)
	elif id == _look_current(section):
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", UITheme.pill(UITheme.MINT_SOFT, 14, 10))
		var h := HBoxContainer.new()
		h.alignment = BoxContainer.ALIGNMENT_CENTER
		h.add_theme_constant_override("separation", 6)
		chip.add_child(h)
		var ic := UIKit.icon("check", 18.0, UITheme.MINT.darkened(0.2))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		h.add_child(UITheme.label("Son look actuel", UITheme.FS_BODY, UITheme.MINT.darkened(0.3), 650))
		act.add_child(chip)
	elif _look_owned(section, id):
		var ch := Button.new()
		ch.text = "Choisir"
		ch.theme_type_variation = "PrimaryButton"
		ch.custom_minimum_size = Vector2(0, 48)
		ch.pressed.connect(_look_pressed.bind(section, id))
		act.add_child(ch)
		detail_buttons["choose"] = ch
	else:
		var price := _look_price(section, id)
		var can := GameState.coins >= price
		var buy := _price_button("Acheter", price, can)
		buy.pressed.connect(_ask_buy_look.bind(section, id))
		act.add_child(buy)
		detail_buttons["buy"] = buy
		var hint := UITheme.label("Aperçu sur %s" % GameState.pet_name if can else "Il te manque %s pièces" % UIKit.fmt(price - GameState.coins),
			UITheme.FS_SMALL, UITheme.MUTED)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		act.add_child(hint)


func _ask_buy_look(section: String, id: String) -> void:
	var price := _look_price(section, id)
	if GameState.coins < price:
		return
	var nm := _look_name(section, id)
	var what: String = {"mat": "cette matière", "eye": "ces yeux", "mouth": "cette bouche"}.get(section, "ce look")
	var tex = Thumbs.best(THUMB_KIND[section], id)
	var on_ok := func():
		if GameState.buy_look("%s:%s" % [section, id]):
			GameState.set_look(section, id)
			_celebrate("%s : c'est fait !" % nm)
			if current_tab == "look":
				_refresh_look_cards()
				_fill_look_detail(section, id)
	var on_cancel := func():
		if _previewing_look:
			_rebuild_preview()
	_ask("Acheter « %s » ?" % nm, "%s adoptera %s tout de suite." % [GameState.pet_name, what], "Acheter",
		tex if tex else "palette", price, on_ok, on_cancel)


func _preview_species(id: String) -> void:
	var rot := preview.pet.rotation.y
	var mat_col := str(Data.MATERIALS[GameState.material].get("color", ""))
	var col := Color.html(mat_col) if mat_col != "" else Color.html(Data.SPECIES[id]["fur"])
	preview.pet.build(id, col, GameState.material, "", GameState.mouth_style, GameState.current_iris(), 12)
	for slot in Data.SLOTS:
		var it: String = GameState.equipped.get(slot, "")
		preview.pet.set_item(slot, it, GameState.colors_for(it) if it != "" else {}, false)
	_studio_env()
	preview.pet.rotation.y = rot
	_previewing_look = true
	preview.pet.act_hop(1)


func _preview_look(section: String, id: String) -> void:
	var mat := GameState.material
	var eyes := GameState.current_eye_style()
	var mouth := GameState.mouth_style
	var col := GameState.current_fur_color()
	match section:
		"mat":
			mat = id
			if str(Data.MATERIALS[id].get("color", "")) != "":
				col = Color.html(Data.MATERIALS[id]["color"])
		"eye":
			eyes = id
		"mouth":
			mouth = id
	var rot := preview.pet.rotation.y
	preview.pet.build(GameState.species, col, mat, eyes, mouth, GameState.current_iris(), 12)
	for slot in Data.SLOTS:
		var it: String = GameState.equipped.get(slot, "")
		preview.pet.set_item(slot, it, GameState.colors_for(it) if it != "" else {}, false)
	_studio_env()
	preview.pet.rotation.y = rot
	_previewing_look = true
	preview.pet.act_spin()


func _fill_colors(holder: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "top", "right", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 6)
	scroll.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	m.add_child(v)
	# fourrure
	var c1 := _group(v, "Couleur du corps", "body", "Choisis une teinte ou crée la tienne avec l'arc-en-ciel.", UITheme.ACCENT)
	fur_swatches = UIKit.Swatches.new(Data.FUR_PALETTE, GameState.current_fur_color())
	fur_swatches.picked.connect(func(c: Color, final: bool):
		if final:
			_queue_commit(Callable(), 0.0)
			GameState.set_fur_color(c)
		else:
			preview.pet.set_body_color(c)
			_queue_commit(func(): GameState.set_fur_color(c), 0.6))
	c1.add_child(fur_swatches)
	var reset := Button.new()
	reset.text = "Couleur d'origine"
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(func():
		var mat_col := str(Data.MATERIALS[GameState.material].get("color", ""))
		var def := Color.html(mat_col) if mat_col != "" else Color.html(Data.SPECIES[GameState.species]["fur"])
		GameState.set_fur_color(def))
	c1.add_child(reset)
	detail_buttons["fur_reset"] = reset
	# iris
	var c2 := _group(v, "Couleur des yeux", "eye", "Visible avec les yeux qui ont un iris (brillants, étoiles…).", UITheme.SKY)
	iris_swatches = UIKit.Swatches.new(Data.PALETTE, GameState.current_iris())
	iris_swatches.picked.connect(func(c: Color, final: bool):
		if final:
			_queue_commit(Callable(), 0.0)
			GameState.set_iris(c)
		else:
			_queue_commit(func(): GameState.set_iris(c), 0.6))
	c2.add_child(iris_swatches)


func _queue_commit(cb: Callable, delay: float) -> void:
	_pending_commit = cb
	_commit_t = delay if cb.is_valid() else -1.0


## Carte de groupe avec titre (reglages, couleurs).
func _group(parent: Control, title_text: String, icon_name: String, sub: String, tint: Color) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.glass(22, 20, 0.9))
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	p.add_child(v)
	v.add_child(UIKit.header(title_text, icon_name, sub, tint))
	return v


# =========================================================================== quetes / progression
const QUEST_ICONS := {"feed": "apple", "feed_files": "cookie", "pet": "heart", "work_min": "briefcase", "game_min": "gamepad",
	"throw": "sparkle", "poke": "smile", "outfit": "hat", "climb": "flag"}
const QUEST_TINTS := {"feed": UITheme.PEACH, "feed_files": UITheme.GOLD, "pet": UITheme.ACCENT, "work_min": UITheme.SKY,
	"game_min": UITheme.LAVENDER, "throw": UITheme.MINT, "poke": UITheme.ACCENT, "outfit": UITheme.LAVENDER, "climb": UITheme.MINT}
## type de nourriture -> [icone, fichiers, teinte]
const FOOD_INFO := {
	"fruit": ["apple", "images", Color("f0605f")], "pain": ["bread", "documents", UITheme.PEACH],
	"bonbon": ["candy", "archives (.zip…)", UITheme.ACCENT], "burger": ["burger", "programmes (.exe)", Color("e0913a")],
	"gateau": ["cake", "vidéos et musique", UITheme.LAVENDER], "snack": ["cookie", "autres fichiers", UITheme.GOLD],
}

var _lc_bar: UIKit.Bar
var _lc_xp: Label
var _lc_next: VBoxContainer
var _lc_badge: LevelBadge
var _quest_refs: Array = []  # [{bar, count, done}]


func _scroll_col(parent: Control) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "top", "right", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 6)
	m.add_theme_constant_override("margin_right", 12)
	scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	m.add_child(col)
	return col


func _build_quests_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.add_child(_page_header("Quêtes du jour", "flag", "Trois nouvelles quêtes chaque jour", UITheme.GOLD))
	var col := _scroll_col(v)
	# carte de niveau
	var lc := PanelContainer.new()
	lc.add_theme_stylebox_override("panel", UITheme.box(UITheme.GOLD_SOFT.lerp(Color.WHITE, 0.35), 22, Color(UITheme.GOLD, 0.4), 1, 18))
	col.add_child(lc)
	var lh := HBoxContainer.new()
	lh.add_theme_constant_override("separation", 16)
	lc.add_child(lh)
	_lc_badge = LevelBadge.new(true)
	_lc_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lh.add_child(_lc_badge)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 6)
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lh.add_child(lv)
	level_card_label = UITheme.label("", UITheme.FS_H2 + 2, UITheme.INK, 700)
	lv.add_child(level_card_label)
	_lc_bar = UIKit.Bar.new(UITheme.GOLD)
	_lc_bar.custom_minimum_size.y = 12
	lv.add_child(_lc_bar)
	_lc_xp = UITheme.label("", UITheme.FS_SMALL, Color("8a5a00"), 650)
	lv.add_child(_lc_xp)
	_lc_next = VBoxContainer.new()
	_lc_next.add_theme_constant_override("separation", 4)
	_lc_next.custom_minimum_size.x = 200
	_lc_next.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lh.add_child(_lc_next)
	_refresh_level_card(false)
	# quetes
	_quest_list = VBoxContainer.new()
	_quest_list.add_theme_constant_override("separation", 10)
	col.add_child(_quest_list)
	_fill_quests()
	# nourriture
	var g := _group(col, "Ce qu'il aime manger", "apple",
		"Glisse des fichiers sur %s pour le nourrir : ils partent dans la Corbeille." % GameState.pet_name, UITheme.PEACH)
	if not setting_on("eat_files"):
		var off := UITheme.label("Désactivé dans les Réglages (Comportement).", UITheme.FS_SMALL, UITheme.BAD, 650)
		g.add_child(off)
	var grid := GridContainer.new()
	grid.name = "FoodGrid"
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	g.add_child(grid)
	food_rows.clear()
	for kind in Data.FOODS:
		var info: Array = FOOD_INFO.get(kind, ["cookie", "", UITheme.GOLD])
		var pref := Data.food_pref(GameState.species, kind)
		food_rows[kind] = pref
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", UITheme.box(Color(1, 1, 1, 0.75), 16, UITheme.LINE, 1, 10))
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(tile)
		var th := HBoxContainer.new()
		th.add_theme_constant_override("separation", 10)
		tile.add_child(th)
		var ib := UIKit.IconBubble.new(info[0], 38.0, info[2])
		ib.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		th.add_child(ib)
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", -2)
		tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		th.add_child(tv)
		tv.add_child(UITheme.label(str(Data.FOODS[kind]["name"]), UITheme.FS_BODY, UITheme.INK, 650))
		var files := UITheme.label(info[1], UITheme.FS_TINY, UITheme.MUTED)
		files.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		files.clip_text = true
		tv.add_child(files)
		var fp := FoodPref.new(pref)
		fp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		th.add_child(fp)
	var eaten := HBoxContainer.new()
	eaten.add_theme_constant_override("separation", 8)
	g.add_child(eaten)
	var eb := UIKit.IconBubble.new("cookie", 26.0, UITheme.GOLD)
	eaten.add_child(eb)
	var el := UITheme.label("Fichiers mangés : %s  ·  %s" % [UIKit.fmt(int(GameState.eaten.get("count", 0))), _fmt_bytes(int(GameState.eaten.get("bytes", 0)))],
		UITheme.FS_SMALL + 1, UITheme.BODY, 650)
	el.name = "EatenLabel"
	el.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	eaten.add_child(el)
	# aide XP
	var hg := _group(col, "Comment gagner de l'XP", "star", "Chaque niveau rapporte des pièces et débloque de nouveaux compagnons.", UITheme.GOLD)
	for row in [["apple", "Nourris-le en glissant des fichiers sur lui", "selon le repas", UITheme.PEACH],
			["flag", "Termine les quêtes du jour", "+25 à +60 XP", UITheme.GOLD],
			["heart", "Câlins, coucous, lancers et escalade", "+1 à +3 XP", UITheme.ACCENT],
			["briefcase", "Travaille ou joue sur ton PC avec lui", "+1 XP / min", UITheme.SKY]]:
		var rh := HBoxContainer.new()
		rh.add_theme_constant_override("separation", 10)
		hg.add_child(rh)
		rh.add_child(UIKit.IconBubble.new(row[0], 30.0, row[3]))
		var rl := UITheme.label(row[1], UITheme.FS_BODY - 1, UITheme.BODY, 650)
		rl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		rh.add_child(rl)
		rh.add_child(_reward_pill("star", row[2], UITheme.GOLD_SOFT, Color("8a5a00")))
	return v


func _reward_pill(icon_name: String, text: String, bg: Color, fg: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.pill(bg, 10, 3))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 5)
	p.add_child(h)
	var ic := UIKit.icon(icon_name, 15.0, fg if icon_name != "coin" else UITheme.INK)
	if icon_name == "star":
		ic.color = UITheme.GOLD
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ic)
	h.add_child(UITheme.label(text, UITheme.FS_SMALL, fg, 650))
	return p


static func _fmt_bytes(b: int) -> String:
	if b < 1024 * 1024:
		return "%d Ko" % int(ceil(b / 1024.0))
	if b < 1024 * 1024 * 1024:
		return ("%.1f Mo" % (b / 1048576.0)).replace(".", ",")
	return ("%.2f Go" % (b / 1073741824.0)).replace(".", ",")


func _refresh_level_card(animate := true) -> void:
	if not is_instance_valid(level_card_label):
		return
	var need := Data.xp_for_next(GameState.level)
	_lc_badge.level = GameState.level
	_lc_badge.queue_redraw()
	level_card_label.text = "Niveau %d" % GameState.level
	_lc_bar.set_value(100.0 * GameState.xp / maxf(1.0, need), animate)
	_lc_xp.text = "%s / %s XP  ·  encore %s XP" % [UIKit.fmt(GameState.xp), UIKit.fmt(need), UIKit.fmt(maxi(0, need - GameState.xp))]
	for ch in _lc_next.get_children():
		ch.queue_free()
	_lc_next.add_child(UITheme.label("Au niveau %d" % (GameState.level + 1), UITheme.FS_SMALL, UITheme.MUTED, 650))
	for r in Data.level_rewards(GameState.level + 1):
		var icon_name: String = {"coins": "coin", "species": "body", "gift": "bag"}.get(str(r.get("type", "")), "star")
		var txt := str(r.get("text", ""))
		if str(r.get("type", "")) == "gift":
			txt = "Un accessoire cadeau"
		_lc_next.add_child(_reward_pill(icon_name, txt, Color(1, 1, 1, 0.8), UITheme.BODY))


func _fill_quests() -> void:
	if not is_instance_valid(_quest_list):
		return
	for ch in _quest_list.get_children():
		ch.queue_free()
	quest_cards.clear()
	_quest_refs.clear()
	if GameState.quests.is_empty():
		_quest_list.add_child(UITheme.label("Les quêtes du jour arrivent bientôt…", UITheme.FS_BODY, UITheme.MUTED))
		return
	for q in GameState.quests:
		var done := bool(q.get("done", false))
		var kind := str(q.get("kind", ""))
		var tint: Color = QUEST_TINTS.get(kind, UITheme.ACCENT)
		var p := PanelContainer.new()
		if done:
			p.add_theme_stylebox_override("panel", UITheme.box(UITheme.MINT_SOFT.lerp(Color.WHITE, 0.25), 20, Color(UITheme.MINT, 0.45), 1, 16))
		else:
			p.add_theme_stylebox_override("panel", UITheme.glass(20, 16, 0.92))
		p.set_meta("quest_id", str(q.get("id", "")))
		p.set_meta("done", done)
		_quest_list.add_child(p)
		quest_cards.append(p)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 14)
		p.add_child(h)
		var ib := UIKit.IconBubble.new("check" if done else QUEST_ICONS.get(kind, "flag"), 46.0, UITheme.MINT if done else tint, done)
		ib.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ib)
		var mv := VBoxContainer.new()
		mv.add_theme_constant_override("separation", 6)
		mv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(mv)
		var t := UITheme.label(GameState.quest_text(q), UITheme.FS_BODY + 1, UITheme.MINT.darkened(0.35) if done else UITheme.INK, 650)
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		mv.add_child(t)
		var pr := HBoxContainer.new()
		pr.add_theme_constant_override("separation", 10)
		mv.add_child(pr)
		var bar := UIKit.Bar.new(UITheme.MINT if done else tint)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		pr.add_child(bar)
		var cnt := UITheme.label("", UITheme.FS_SMALL, UITheme.MUTED, 650)
		cnt.custom_minimum_size.x = 70
		cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		pr.add_child(cnt)
		var rv := VBoxContainer.new()
		rv.add_theme_constant_override("separation", 6)
		rv.custom_minimum_size.x = 112
		rv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(rv)
		if done:
			rv.add_child(_reward_pill("check", "Terminée !", UITheme.MINT, Color.WHITE))
		else:
			rv.add_child(_reward_pill("coin", "+%d" % int(q.get("coins", 0)), UITheme.GOLD_SOFT, Color("8a5a00")))
			rv.add_child(_reward_pill("star", "+%d XP" % int(q.get("xp", 0)), UITheme.LAVENDER_SOFT, UITheme.LAVENDER.darkened(0.35)))
		_quest_refs.append({"q": q, "bar": bar, "count": cnt, "done": done})
	_update_quest_progress(false)


## Mise a jour sur place des barres de progression (appelee chaque seconde).
func _update_quest_progress(animate := true) -> void:
	for r in _quest_refs:
		if not is_instance_valid(r["bar"]):
			continue
		var q: Dictionary = r["q"]
		if bool(q.get("done", false)) != r["done"]:
			_fill_quests()
			return
		var goal := maxi(1, int(q.get("goal", 1)))
		var prog := int(q.get("progress", 0))
		r["bar"].set_value(100.0 * prog / goal, animate)
		r["count"].text = "%d / %d%s" % [prog, goal, " min" if str(q.get("kind", "")).ends_with("_min") else ""]


func _on_needs() -> void:
	_update_mood()


func _on_xp(_xp: int, _lv: int) -> void:
	_update_level()
	_refresh_level_card()


func _on_level_up(lv: int, rewards: Array) -> void:
	var parts := []
	for r in rewards:
		parts.append(str(r.get("text", "")))
	toast.show_msg("Niveau %d !  %s" % [lv, " · ".join(parts)], "star", UITheme.GOLD)
	confetti.burst(Vector2(confetti.size.x * 0.5, confetti.size.y * 0.45), 70)
	preview.pet.act_love()
	_update_level()
	_refresh_level_card()
	if current_tab == "look" and look_section == "species":
		_refresh_look_cards()
		_fill_look_detail("species", _look_sel.get("species", GameState.species))


func _on_quest_completed(q: Dictionary) -> void:
	toast.show_msg("Quête terminée !  +%d pièces  ·  +%d XP" % [int(q.get("coins", 0)), int(q.get("xp", 0))], "flag", UITheme.MINT)
	if current_tab == "quests":
		_fill_quests()


func _on_stats_changed() -> void:
	# emis tres souvent (pieces, bonheur...) : simple mise a jour sur place
	if current_tab == "quests":
		_update_quest_progress()

# =========================================================================== stats
func _build_stats_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.add_child(_page_header("Statistiques", "chart", "Votre temps passé ensemble", UITheme.SKY))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "top", "right", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 6)
	m.add_theme_constant_override("margin_right", 12)
	scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	m.add_child(col)
	var sections := [
		["Aujourd'hui", [["now", "En ce moment", "clock", UITheme.LAVENDER], ["work", "Temps de travail", "briefcase", UITheme.SKY],
			["game", "Temps de jeu", "gamepad", UITheme.PEACH], ["earned_today", "Pièces gagnées", "coin", UITheme.GOLD]]],
		["Depuis le début", [["earned_total", "Pièces gagnées", "coin", UITheme.GOLD], ["work_total", "Temps de travail", "briefcase", UITheme.SKY],
			["game_total", "Temps de jeu", "gamepad", UITheme.PEACH], ["pets", "Câlins reçus", "heart", UITheme.ACCENT]]],
	]
	for sec in sections:
		col.add_child(UITheme.label(sec[0], UITheme.FS_BODY + 1, UITheme.INK, 650))
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 12)
		col.add_child(grid)
		for st in sec[1]:
			grid.add_child(_stat_tile(st[0], st[1], st[2], st[3]))
	col.add_child(UITheme.label("Collection", UITheme.FS_BODY + 1, UITheme.INK, 650))
	var coll := PanelContainer.new()
	coll.add_theme_stylebox_override("panel", UITheme.glass(18, 16, 0.9))
	col.add_child(coll)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	coll.add_child(cv)
	var n_items := 0
	for id in Data.ITEMS:
		if GameState.owned.has(id):
			n_items += 1
	var n_looks := 0
	var tot_looks := 0
	for sec2 in [["mat", Data.MATERIALS], ["eye", Data.EYES], ["mouth", Data.MOUTHS]]:
		for id2 in sec2[1]:
			tot_looks += 1
			if GameState.owns_look("%s:%s" % [sec2[0], id2]):
				n_looks += 1
	for line in [["Accessoires", n_items, Data.ITEMS.size(), UITheme.ACCENT, "hat"], ["Looks (matières, yeux, bouches)", n_looks, tot_looks, UITheme.LAVENDER, "palette"]]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		cv.add_child(h)
		h.add_child(UIKit.IconBubble.new(line[4], 28.0, line[3]))
		var l := UITheme.label(line[0], UITheme.FS_BODY - 1, UITheme.BODY, 650)
		l.custom_minimum_size.x = 210
		h.add_child(l)
		var bar := UIKit.Bar.new(line[3])
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.set_value(100.0 * line[1] / maxf(1.0, line[2]), false)
		h.add_child(bar)
		var cnt := UITheme.label("%d / %d" % [line[1], line[2]], UITheme.FS_SMALL + 1, UITheme.MUTED, 650)
		cnt.custom_minimum_size.x = 58
		cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(cnt)
	var tip := PanelContainer.new()
	tip.add_theme_stylebox_override("panel", UITheme.box(UITheme.GOLD_SOFT, 18, Color(UITheme.GOLD, 0.35), 1, 16))
	col.add_child(tip)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 12)
	tip.add_child(th)
	var tb := UIKit.IconBubble.new("info", 32.0, UITheme.GOLD, true)
	tb.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	th.add_child(tb)
	var tl := UITheme.label("Tu gagnes des pièces quand tu travailles ou que tu joues sur ton PC (3 par minute), et un peu en naviguant. Plus %s est heureux, plus tu en gagnes !" % GameState.pet_name,
		UITheme.FS_BODY - 1, Color("7a5200"))
	tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	th.add_child(tl)
	_update_stats()
	return v


func _stat_tile(key: String, label_text: String, icon_name: String, tint: Color) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.glass(18, 16, 0.9))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	p.add_child(h)
	var b := UIKit.IconBubble.new(icon_name, 40.0, tint)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(b)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var val := UITheme.label("—", 20, UITheme.INK, 650)
	val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	val.clip_text = true
	v.add_child(val)
	v.add_child(UITheme.label(label_text, UITheme.FS_SMALL, UITheme.MUTED))
	stat_labels[key] = val
	return p


func _fmt_time(sec: float) -> String:
	var m := int(sec / 60.0)
	if m < 60:
		return "%d min" % m
	return "%d h %02d" % [m / 60, m % 60]


func _update_stats() -> void:
	if stat_labels.is_empty() or not is_instance_valid(stat_labels.get("now")):
		return
	var st := GameState.stats
	var cat := {"work": "Travail", "game": "Jeu", "browse": "Navigation", "media": "Vidéo / musique", "other": "Autre"}
	var now_txt := "Mode simple"
	if Activity.available:
		now_txt = "%s%s" % [cat.get(Activity.category, "Autre"), "" if Activity.is_active() else " (absent)"]
		if Activity.proc_name != "":
			now_txt += " · " + Activity.proc_name
	stat_labels["now"].text = now_txt
	stat_labels["now"].tooltip_text = now_txt
	stat_labels["work"].text = _fmt_time(float(st["work"]))
	stat_labels["game"].text = _fmt_time(float(st["game"]))
	stat_labels["earned_today"].text = UIKit.fmt(int(st["earned_today"]))
	stat_labels["earned_total"].text = UIKit.fmt(int(st["earned_total"]))
	stat_labels["work_total"].text = _fmt_time(float(st["work_total"]))
	stat_labels["game_total"].text = _fmt_time(float(st["game_total"]))
	stat_labels["pets"].text = UIKit.fmt(int(st.get("pets", 0)))


# =========================================================================== reglages
const SETTING_OPTIONS := {
	"size": [["Petit", 0.75], ["Moyen", 1.0], ["Grand", 1.3], ["Très grand", 1.7]],
	"fur_quality": [["Rapide", 8], ["Normale", 16], ["Magnifique", 26]],
	"ssaa": [["Normal", 1.0], ["Élevé", 1.5], ["Maximum", 2.0]],
	"fps": [["60", 60], ["120", 120], ["144", 144], ["Max", 0]],
}


func _build_settings_page() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.add_child(_page_header("Réglages", "gear", "Fais de %s ton compagnon idéal" % GameState.pet_name, UITheme.MINT))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "top", "right", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 6)
	m.add_theme_constant_override("margin_right", 12)
	scroll.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	m.add_child(col)

	var g1 := _group(col, "Affichage", "sparkle", "", UITheme.ACCENT)
	_setting_row(g1, "Taille", "La taille de %s sur ton bureau." % GameState.pet_name, _seg_setting("size"))
	_setting_row(g1, "Qualité de la fourrure", "Plus c'est beau, plus ça demande à ta carte graphique.", _seg_setting("fur_quality"))
	_setting_row(g1, "Lissage des contours", "Des bords plus doux, sans escaliers.", _seg_setting("ssaa"))
	_setting_row(g1, "Images par seconde", "Sa fluidité quand tu le regardes. Il ralentit tout seul quand personne ne le regarde.", _seg_setting("fps"))
	_setting_row(g1, "Économie en jeu", "Pendant tes parties, il se fait léger (30 images/s) pour ne pas te coûter de FPS.", _toggle_setting("game_saver"))
	_setting_row(g1, "Reflets de l'écran", "Il reflète et réfracte ce qu'il y a autour de lui.", _toggle_setting("reflections"))
	_setting_row(g1, "Visible en partage d'écran", "Il apparaît dans tes partages d'écran et captures. Désactive pour des reflets parfaitement exacts (il sera alors invisible en partage).", _toggle_setting("share_visible"), false)

	var g2 := _group(col, "Comportement", "heart", "", UITheme.LAVENDER)
	_setting_row(g2, "Se promener", "Il se balade tout seul sur la barre des tâches.", _toggle_setting("wander"))
	_setting_row(g2, "Se cacher dans les jeux compétitifs", "Valorant, CS2, LoL… : il disparaît complètement pendant la partie et revient après.", _toggle_setting("competitive_hide"))
	_setting_row(g2, "Discret", "Il se pousse quand ta souris travaille juste à côté.", _toggle_setting("discreet"))
	_setting_row(g2, "Parler", "Il s'exprime avec de petites bulles.", _toggle_setting("talk"))
	_setting_row(g2, "Se cacher en plein écran", "Sinon, il te regarde discrètement depuis le bord de l'écran.", _toggle_setting("hide_fullscreen"))

	_setting_row(g2, "Me nourrir avec des fichiers", "Glisse un fichier sur lui : il le mange et le fichier part dans la Corbeille.", _toggle_setting("eat_files"), false)

	var g4 := _group(col, "Assistant", "bolt", "", UITheme.SKY)
	_setting_row(g4, "Tenir mes captures d'écran", "Quand tu fais une capture (Outil Capture d'écran, Win+Maj+S), il la garde sur sa tête. Clique-le pour la recopier.", _toggle_setting("screenshots"))
	_setting_row(g4, "Garder ce que je copie", "Il se souvient de tout ce que tu copies (presse-papiers) pour le retrouver facilement.", _toggle_setting("clipboard"))
	_setting_row(g4, "Suggestions intelligentes", "Une IA locale lui donne des idées. Rien ne quitte ton PC.", _toggle_setting("suggestions"))
	_setting_row(g4, "IA sur la carte graphique", "Plus rapide. Désactive-le si ton PC ralentit.", _toggle_setting("ai_gpu"), false)

	var g3 := _group(col, "Système", "gear", "", UITheme.MINT)
	_setting_row(g3, "Lancer au démarrage", "Pompom démarre en même temps que Windows.", _toggle_setting("autostart"))
	_setting_row(g3, "Mises à jour automatiques", "Il vérifie les nouvelles versions sur GitHub et te propose de mettre à jour (jamais sans ton accord).", _toggle_setting("auto_update"))
	var upd := Button.new()
	upd.text = "Vérifier"
	upd.custom_minimum_size = Vector2(120, 40)
	upd.pressed.connect(func():
		var host := get_parent()
		if host and host.has_method("check_updates_now"):
			host.call("check_updates_now")
		toast.show_msg("Je cherche une nouvelle version…", "sparkle", UITheme.SKY))
	settings_ctrls["check_update"] = upd
	_setting_row(g3, "Version %s" % Updater.current_version(), "Chercher tout de suite une nouvelle version (sinon il vérifie tout seul toutes les 10 minutes).", upd)
	var reset := Button.new()
	reset.text = "Replacer"
	reset.custom_minimum_size = Vector2(120, 40)
	reset.pressed.connect(func():
		GameState.set_setting("home_x", -1.0)
		toast.show_msg("%s retourne à sa place" % GameState.pet_name, "taskbar", UITheme.MINT))
	settings_ctrls["reset_position"] = reset
	_setting_row(g3, "Position par défaut", "Le remettre à sa place sur la barre des tâches.", reset, false)
	return v


func _setting_row(parent: Control, title_text: String, desc: String, ctrl: Control, sep := true) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	parent.add_child(h)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(tv)
	tv.add_child(UITheme.label(title_text, UITheme.FS_BODY, UITheme.INK, 650))
	var d := UITheme.label(desc, UITheme.FS_SMALL, UITheme.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tv.add_child(d)
	ctrl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(ctrl)
	if sep:
		var line := ColorRect.new()
		line.color = UITheme.LINE
		line.custom_minimum_size.y = 1
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(line)


func _seg_setting(key: String) -> UIKit.Segmented:
	var opts: Array = SETTING_OPTIONS[key]
	var labels := []
	for o in opts:
		labels.append(o[0])
	var seg := UIKit.Segmented.new(labels, _option_index(key))
	seg.custom_minimum_size.x = 84 * opts.size()
	seg.changed.connect(func(i: int):
		GameState.set_setting(key, opts[i][1])
		if key == "fur_quality":
			GameState.appearance_changed.emit())
	settings_ctrls[key] = seg
	return seg


func _option_index(key: String) -> int:
	var opts: Array = SETTING_OPTIONS[key]
	var cur := float(GameState.settings.get(key, opts[0][1]))
	var best := 0
	var best_d := INF
	for i in opts.size():
		var d := absf(float(opts[i][1]) - cur)
		if d < best_d:
			best_d = d
			best = i
	return best


## Valeurs par defaut des reglages qui peuvent manquer dans une vieille sauvegarde.
const SETTING_DEFAULTS := {"eat_files": true, "clipboard": false, "suggestions": false, "ai_gpu": true,
	"screenshots": true, "share_visible": true, "auto_update": true, "competitive_hide": true, "game_saver": true}


static func setting_on(key: String) -> bool:
	return bool(GameState.settings.get(key, SETTING_DEFAULTS.get(key, false)))


func _toggle_setting(key: String) -> UIKit.Toggle:
	var t := UIKit.Toggle.new()
	t.set_on(setting_on(key))
	t.toggled.connect(func(on: bool):
		GameState.set_setting(key, on)
		if key == "autostart" and not GameState.no_save:
			SystemUtil.set_autostart(on))
	settings_ctrls[key] = t
	return t


# =========================================================================== evenements
func _on_coins(v: int, _d: int) -> void:
	coin_pill.set_value(v)
	if current_tab in Data.SLOTS:
		_refresh_item_cards(current_tab)
		var sel: String = _sel.get(current_tab, "")
		if detail_buttons.has("buy"):
			_fill_item_detail(current_tab, sel)
	elif current_tab == "look" and look_section != "colors":
		_refresh_look_cards()
		if detail_buttons.has("buy"):
			_fill_look_detail(look_section, _look_sel.get(look_section, _look_current(look_section)))


func _on_equipment() -> void:
	_refresh_outfit()
	if current_tab in Data.SLOTS:
		_refresh_item_cards(current_tab)
	# l'apercu suit les changements faits ailleurs (sauf l'objet en cours d'essayage)
	_sync_preview(current_tab if current_tab in Data.SLOTS else "")


func _on_appearance() -> void:
	_rebuild_preview()
	_update_species_label()
	if not name_edit.has_focus() and name_edit.text != GameState.pet_name:
		name_edit.text = GameState.pet_name
	_refresh_outfit()
	if current_tab in Data.SLOTS:
		preview.pet.set_item(current_tab, _sel.get(current_tab, GameState.equipped.get(current_tab, "")),
			_try_colors.get(_sel.get(current_tab, ""), {}) if _sel.get(current_tab, "") != "" else {}, false)
	if current_tab == "look":
		if look_section == "colors":
			if fur_swatches:
				fur_swatches.set_current(GameState.current_fur_color())
			if iris_swatches:
				iris_swatches.set_current(GameState.current_iris())
		else:
			# les miniatures dependent de l'espece / matiere : on les redemande (rendu paresseux)
			for id in cards:
				if is_instance_valid(cards[id]):
					_request_thumb(look_section, id, cards[id].set_thumb)
			_refresh_look_cards()
			_fill_look_detail(look_section, _look_sel.get(look_section, _look_current(look_section)))


func _on_settings() -> void:
	# mise a jour sur place (le compagnon change "home_x" a chaque atterrissage : pas de reconstruction)
	for key in settings_ctrls:
		var c = settings_ctrls[key]
		if not is_instance_valid(c):
			continue
		if c is UIKit.Toggle:
			var on := setting_on(key)
			if c.button_pressed != on:
				c.set_on(on)
		elif c is UIKit.Segmented:
			var i := _option_index(key)
			if c.selected != i:
				c.select(i)


func _refresh_outfit() -> void:
	for slot in outfit_chips:
		var chip: OutfitChip = outfit_chips[slot]
		var id: String = GameState.equipped.get(slot, "")
		chip.item_id = id
		chip.tooltip_text = "%s : %s" % [SLOT_TITLES[slot], Data.ITEMS[id]["name"] if id != "" else "rien"]
		if id == "":
			chip.set_thumb(null)
		else:
			thumbs.request("item", id, chip.set_thumb)


# =========================================================================== composants internes
## Cadre de la fenetre : ombre, degrade arrondi, bords de redimensionnement.
class Frame extends Control:
	var win: Window
	var margin := 14.0

	func _draw() -> void:
		var r := Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0)
		var sh := UITheme.box(UITheme.BG, UITheme.R_WIN, Color.TRANSPARENT, 0, 0)
		sh.shadow_color = Color(0.25, 0.1, 0.25, 0.20)
		sh.shadow_size = int(margin * 0.9)
		sh.shadow_offset = Vector2(0, 3)
		draw_style_box(sh, r)
		var pts := UIKit.rounded_poly(r, UITheme.R_WIN, 10)
		var cols := PackedColorArray()
		for p in pts:
			var t := clampf((p.y - r.position.y) / r.size.y, 0.0, 1.0)
			var u := clampf((p.x - r.position.x) / r.size.x, 0.0, 1.0)
			cols.append(UITheme.BG.lerp(UITheme.BG_2, t * 0.8 + u * 0.2))
		draw_polygon(pts, cols)
		pts.append(pts[0])
		draw_polyline(pts, Color(1, 1, 1, 0.9), 1.2, true)

	func _edge(p: Vector2) -> int:
		var m := margin + 2.0
		var c := 26.0
		var l := p.x < m
		var rr := p.x > size.x - m
		var t := p.y < m
		var b := p.y > size.y - m
		if not (l or rr or t or b):
			return -1
		var lc := p.x < c
		var rc := p.x > size.x - c
		var tc := p.y < c
		var bc := p.y > size.y - c
		if (t and lc) or (l and tc):
			return DisplayServer.WINDOW_EDGE_TOP_LEFT
		if (t and rc) or (rr and tc):
			return DisplayServer.WINDOW_EDGE_TOP_RIGHT
		if (b and lc) or (l and bc):
			return DisplayServer.WINDOW_EDGE_BOTTOM_LEFT
		if (b and rc) or (rr and bc):
			return DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT
		if t:
			return DisplayServer.WINDOW_EDGE_TOP
		if b:
			return DisplayServer.WINDOW_EDGE_BOTTOM
		if l:
			return DisplayServer.WINDOW_EDGE_LEFT
		return DisplayServer.WINDOW_EDGE_RIGHT

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseMotion:
			var e := _edge(ev.position)
			var shape := Control.CURSOR_ARROW
			match e:
				DisplayServer.WINDOW_EDGE_TOP_LEFT, DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT:
					shape = Control.CURSOR_FDIAGSIZE
				DisplayServer.WINDOW_EDGE_TOP_RIGHT, DisplayServer.WINDOW_EDGE_BOTTOM_LEFT:
					shape = Control.CURSOR_BDIAGSIZE
				DisplayServer.WINDOW_EDGE_TOP, DisplayServer.WINDOW_EDGE_BOTTOM:
					shape = Control.CURSOR_VSIZE
				DisplayServer.WINDOW_EDGE_LEFT, DisplayServer.WINDOW_EDGE_RIGHT:
					shape = Control.CURSOR_HSIZE
			if mouse_default_cursor_shape != shape:
				mouse_default_cursor_shape = shape
		elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			var e2 := _edge(ev.position)
			if e2 >= 0 and win and win.mode == Window.MODE_WINDOWED:
				win.start_resize(e2)
				accept_event()


## Barre de titre : on la tire pour deplacer la fenetre.
class TitleBar extends Control:
	var win: Window

	func _gui_input(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and win:
			win.start_drag()
			accept_event()


class Logo extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(40, 40)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := 18.0
		draw_circle(c + Vector2(0, 2), r, Color(UITheme.ACCENT_DARK, 0.25), true, -1.0, true)
		draw_circle(c, r, UITheme.ACCENT, true, -1.0, true)
		draw_circle(c + Vector2(-11, -12), 5.5, UITheme.ACCENT, true, -1.0, true)
		draw_circle(c + Vector2(11, -12), 5.5, UITheme.ACCENT, true, -1.0, true)
		draw_circle(c + Vector2(-6, 1), 2.6, UITheme.INK, true, -1.0, true)
		draw_circle(c + Vector2(6, 1), 2.6, UITheme.INK, true, -1.0, true)
		draw_circle(c + Vector2(-5.2, 0.2), 0.9, Color.WHITE, true, -1.0, true)
		draw_circle(c + Vector2(6.8, 0.2), 0.9, Color.WHITE, true, -1.0, true)
		draw_arc(c + Vector2(0, 4), 3.0, PI * 0.2, PI * 0.8, 8, UITheme.INK, 1.6, true)
		draw_circle(c + Vector2(-10, 6), 2.8, Color(1, 1, 1, 0.35), true, -1.0, true)
		draw_circle(c + Vector2(10, 6), 2.8, Color(1, 1, 1, 0.35), true, -1.0, true)
		draw_circle(c + Vector2(-7, -9), 3.0, Color(1, 1, 1, 0.4), true, -1.0, true)


## Bouton rond de la barre de titre (reduire / fermer) et de l'apercu.
class WinBtn extends Button:
	var icon_name := ""
	var tint := UITheme.INK
	var solid_bg := false
	var _h := 0.0

	func _init(ic: String, t: Color, tip: String) -> void:
		icon_name = ic
		tint = t
		tooltip_text = tip
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(36, 36)
		size = custom_minimum_size
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		mouse_entered.connect(func(): _hover(1.0))
		mouse_exited.connect(func(): _hover(0.0))

	func _hover(v: float) -> void:
		create_tween().tween_method(func(x: float):
			_h = x
			queue_redraw(), _h, v, 0.12)

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		if solid_bg:
			draw_circle(c + Vector2(0, 1.5), r, Color(0.3, 0.1, 0.25, 0.12), true, -1.0, true)
			draw_circle(c, r, Color(1, 1, 1, 0.92), true, -1.0, true)
		draw_circle(c, r, Color(tint.lerp(Color.WHITE, 0.82), _h), true, -1.0, true)
		var col := UITheme.MUTED.lerp(tint.darkened(0.1), _h)
		UIIcons.draw(self, icon_name, Rect2(c - Vector2(9, 9), Vector2(18, 18)), col, 1.0)


## Zone d'apercu 3D : fond degrade teinte par la couleur du compagnon.
class PreviewCard extends Control:
	var tint := Color("f59ab8")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		clip_contents = true

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var pts := UIKit.rounded_poly(Rect2(r.position + Vector2(8, 8), r.size - Vector2(16, 8)), 18, 8)
		var top := tint.lerp(Color.WHITE, 0.86)
		var bot := tint.lerp(Color.WHITE, 0.70)
		var cols := PackedColorArray()
		for p in pts:
			cols.append(top.lerp(bot, clampf(p.y / size.y, 0.0, 1.0)))
		draw_polygon(pts, cols)
		draw_circle(Vector2(size.x * 0.5, size.y * 0.52), minf(size.x, size.y) * 0.36, Color(1, 1, 1, 0.35), true, -1.0, true)
		draw_circle(Vector2(size.x * 0.5, size.y * 0.52), minf(size.x, size.y) * 0.26, Color(1, 1, 1, 0.25), true, -1.0, true)
		for s in [[0.16, 0.18, 3.0], [0.84, 0.3, 2.2], [0.2, 0.64, 2.0], [0.8, 0.72, 3.0]]:
			UIIcons.draw(self, "sparkle", Rect2(Vector2(size.x * s[0], size.y * s[1]) - Vector2(s[2], s[2]) * 2.5, Vector2(s[2], s[2]) * 5.0),
				Color(1, 1, 1, 0.9), 1.0)


## Petite pastille "Glisse pour le faire tourner".
class Hint extends PanelContainer:
	func _init() -> void:
		add_theme_stylebox_override("panel", UITheme.pill(Color(1, 1, 1, 0.85), 12, 5))
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(h)
		var ic := UIKit.icon("rotate", 14.0, UITheme.MUTED)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		h.add_child(UITheme.label("Glisse pour le faire tourner", UITheme.FS_TINY, UITheme.MUTED, 650))

	func dismiss() -> void:
		var t := create_tween()
		t.tween_property(self, "modulate:a", 0.0, 0.4)
		t.tween_callback(func(): visible = false)


## Pastille d'emplacement de la tenue (miniature de l'objet porte).
class OutfitChip extends Button:
	var slot := ""
	var item_id := ""
	var _tex: Texture2D
	var _h := 0.0

	func _init(p_slot: String) -> void:
		slot = p_slot
		custom_minimum_size = Vector2(48, 48)
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIKit.clear_styles(self)
		mouse_entered.connect(func():
			_h = 1.0
			queue_redraw())
		mouse_exited.connect(func():
			_h = 0.0
			queue_redraw())

	func set_thumb(tex: Texture2D) -> void:
		_tex = tex
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var filled := item_id != "" and _tex != null
		draw_style_box(UITheme.box(Color.WHITE if filled else Color("f7f0f4"), 14,
			UITheme.ACCENT if _h > 0.5 else (UITheme.LINE_2 if filled else Color.TRANSPARENT), 1 if (filled or _h > 0.5) else 0, 0), r)
		if filled:
			draw_texture_rect(_tex, r.grow(-3), false)
		else:
			var ic: String = ShopWindow.SLOT_ICONS.get(slot, "none")
			UIIcons.draw(self, ic, Rect2(r.get_center() - Vector2(11, 11), Vector2(22, 22)), UITheme.FAINT, 1.0)


## Ancienne piece dessinee (compatibilite).
class CoinIcon extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(22, 22)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		UIIcons.coin(self, size * 0.5, minf(size.x, size.y) * 0.46)


## Medaille de niveau (rosette doree + numero).
class LevelBadge extends Control:
	var level := 1

	func _init(big := false) -> void:
		custom_minimum_size = Vector2(64, 64) if big else Vector2(36, 36)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		var pts := PackedVector2Array()
		for i in 60:
			var a := TAU * i / 60.0
			pts.append(c + Vector2(cos(a), sin(a)) * r * (0.9 + 0.1 * cos(a * 12.0)))
		var sh := PackedVector2Array()
		for p in pts:
			sh.append(p + Vector2(0, r * 0.06))
		UIIcons.fill_aa(self, sh, Color(UITheme.GOLD_DARK, 0.35))
		UIIcons.fill_aa(self, pts, UITheme.GOLD)
		draw_circle(c, r * 0.72, UITheme.GOLD.lightened(0.3), true, -1.0, true)
		draw_arc(c, r * 0.72, 0, TAU, 40, Color(UITheme.GOLD_DARK, 0.45), maxf(1.0, r * 0.06), true)
		draw_circle(c + Vector2(-r * 0.3, -r * 0.32), r * 0.12, Color(1, 1, 1, 0.6), true, -1.0, true)
		var f := UITheme.font(700)
		var fs := int(r * (0.86 if level < 10 else 0.7))
		var t := str(level)
		var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, c + Vector2(-tw * 0.5, f.get_ascent(fs) * 0.36), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("7a4f00"))


## Gout pour un type de nourriture : coeurs (aime / adore) ou petite tete (bof / n'aime pas).
class FoodPref extends Control:
	var pref := 0

	func _init(p: int) -> void:
		pref = p
		custom_minimum_size = Vector2(84, 40)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var txt: String = {2: "Adore", 1: "Aime", 0: "Bof", -1: "N'aime pas", -2: "Déteste"}.get(pref, "Bof")
		var col := ShopCard._pref_color(pref)
		if pref > 0:
			var w := 18.0
			var x0 := size.x * 0.5 - (pref - 1) * w * 0.5
			for i in pref:
				UIIcons.fill_aa(self, UIIcons.heart_points(Vector2(x0 + i * w, 11), 8.0), UITheme.ACCENT)
		else:
			UIIcons.draw(self, "pref_%d" % pref, Rect2(size.x * 0.5 - 9, 2, 18, 18), col, 1.0)
		var f := UITheme.font(650)
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(f, Vector2(size.x * 0.5 - tw * 0.5, 36), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col.darkened(0.15))
