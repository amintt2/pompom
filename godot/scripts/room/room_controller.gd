class_name RoomController
extends Node
## Mode "chambre" (telephone) : plein ecran, decor doux, on touche / porte / lance le compagnon.

var stage: PetStage
var pet: Pet
var emotes: EmoteLayer
var _ui: CanvasLayer
var _coins: Label
var _drag := false
var _vel := Vector2.ZERO
var _last := Vector2.ZERO
var _falling := false
var _think := 3.0
var _shop: Window
var _rub := 0.0
var _press_pos := Vector2.ZERO


func setup(p_stage: PetStage, p_emotes: EmoteLayer) -> void:
	stage = p_stage
	pet = stage.pet
	emotes = p_emotes
	var win := get_window()
	get_viewport().transparent_bg = false
	if not OS.has_feature("mobile"):
		win.transparent = false
		win.borderless = false
		win.always_on_top = false
		win.unfocusable = false
		win.size = Vector2i(430, 780)
		win.move_to_center()
	var env := stage.world_env.environment
	env.background_mode = Environment.BG_CANVAS
	env.background_canvas_max_layer = -1
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = -1
	add_child(bg_layer)
	var bg := TextureRect.new()
	var gt := GradientTexture2D.new()
	var g := Gradient.new()
	g.set_color(0, Color("fde7ef"))
	g.set_color(1, Color("e9e4ff"))
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	bg.texture = gt
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg_layer.add_child(bg)
	pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.9)
	_build_ui()
	get_viewport().size_changed.connect(_reframe)
	_reframe()
	GameState.appearance_changed.connect(func():
		stage.build_from_state()
		pet.set_env(PetAssets.studio_env(), Vector4(0, 0, 1, 1), Vector2(0.5, 0.5), 0.3, 0.9))
	GameState.equipment_changed.connect(_on_equip)
	GameState.coins_changed.connect(func(v: int, _d: int): _coins.text = str(v))
	Activity.coins_earned.connect(func(a: int, _k: String): emotes.coin_pop(a))


func _reframe() -> void:
	var sz := Vector2(get_viewport().get_visible_rect().size)
	stage.frame(sz, minf(sz.x, sz.y) * 0.42, sz.y * 0.3)


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 10
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.theme()
	_ui.add_child(root)
	var top := HBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 20
	top.offset_top = 20
	top.offset_right = -20
	root.add_child(top)
	var name_l := Label.new()
	name_l.text = GameState.pet_name
	name_l.add_theme_font_override("font", UITheme.font(650))
	name_l.add_theme_font_size_override("font_size", 24)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_l)
	top.add_child(ShopWindow.CoinIcon.new())
	_coins = Label.new()
	_coins.text = str(GameState.coins)
	_coins.add_theme_font_override("font", UITheme.font(650))
	_coins.add_theme_font_size_override("font_size", 22)
	top.add_child(_coins)
	var bottom := HBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 20
	bottom.offset_right = -20
	bottom.offset_top = -90
	bottom.offset_bottom = -24
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 12)
	root.add_child(bottom)
	for b in [["Boutique", "head"], ["Apparence", "look"], ["Stats", "stats"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(110, 54)
		btn.theme_type_variation = "PrimaryButton" if b[1] == "head" else ""
		btn.pressed.connect(_open_shop.bind(b[1]))
		bottom.add_child(btn)


func _open_shop(tab: String) -> void:
	if _shop and is_instance_valid(_shop):
		_shop.call("show_tab", tab)
		return
	_shop = ShopWindow.new()
	add_child(_shop)
	_shop.call("open", tab)


func _on_equip() -> void:
	for slot in Data.SLOTS:
		var id: String = GameState.equipped[slot]
		if pet.slot_items.get(slot, "") != id:
			pet.set_item(slot, id, GameState.colors_for(id) if id != "" else {})
			if id != "":
				var level := Data.preference(GameState.species, id, GameState.colors_for(id)["main"])
				GameState.discover(id, level)
				pet.react_to_item(level)
				emotes.say(Data.line(level))


func _pet_screen_pos() -> Vector2:
	return stage.camera.unproject_position(pet.center_global())


func _unhandled_input(ev: InputEvent) -> void:
	var p := Vector2.ZERO
	var pressed := false
	var released := false
	var moved := false
	if ev is InputEventScreenTouch or ev is InputEventMouseButton:
		if ev is InputEventMouseButton and ev.button_index != MOUSE_BUTTON_LEFT:
			return
		p = ev.position
		pressed = ev.pressed
		released = not ev.pressed
	elif ev is InputEventScreenDrag or ev is InputEventMouseMotion:
		p = ev.position
		moved = true
	else:
		return
	var near := p.distance_to(_pet_screen_pos()) < pet.width * stage.ppu * 0.6
	if pressed and near:
		_drag = false
		_press_pos = p
		_last = p
		_falling = false
	elif moved and _press_pos != Vector2.ZERO:
		if not _drag and p.distance_to(_press_pos) > 14:
			_drag = true
			pet.carried = true
			pet.airborne = true
			pet.stop_action()
			pet.set_expression("happy", 999)
		if _drag:
			var d := (p - _last) / stage.ppu
			_vel = (p - _last) / maxf(get_process_delta_time(), 0.001)
			pet.position += Vector3(d.x, -d.y, 0)
			pet.push_accel(Vector2(_vel.x, -_vel.y) * 0.002, 0.016)
			_last = p
	elif moved and near:
		_rub += ev.relative.length() if "relative" in ev else 0.0
		if _rub > 400:
			_rub = 0
			pet.act_petted()
			GameState.change_happiness(2)
	elif released and _press_pos != Vector2.ZERO:
		if _drag:
			_drag = false
			pet.carried = false
			pet.set_expression("neutral")
			_falling = true
			_vel = _vel.limit_length(2500)
		elif near:
			pet.act_surprised()
		_press_pos = Vector2.ZERO


func _process(delta: float) -> void:
	if _falling:
		_vel.y += 2600.0 * delta
		pet.position += Vector3(_vel.x, -_vel.y, 0) / stage.ppu * delta
		var lim := 1.3
		if absf(pet.position.x) > lim:
			pet.position.x = signf(pet.position.x) * lim
			_vel.x = -_vel.x * 0.5
		if pet.position.y <= 0.0:
			pet.position.y = 0.0
			pet.land(absf(_vel.y) / stage.ppu * 0.28)
			var b := float(pet.phys.get("bounce", 0.2))
			if absf(_vel.y) * b > 140:
				_vel.y = -absf(_vel.y) * b
			else:
				_falling = false
				pet.airborne = false
				_vel = Vector2.ZERO
	elif not _drag:
		pet.position.x = move_toward(pet.position.x, 0.0, delta * 0.3)
		_think -= delta
		if _think <= 0.0 and not pet.busy:
			_think = randf_range(4.0, 9.0)
			match randi() % 6:
				0: pet.act_look_around()
				1: pet.act_hop(2, 0.12)
				2: pet.act_wiggle(1.5)
				3: pet.act_spin()
				4: pet.act_dance(3.0)
				5: pet.act_stretch()
