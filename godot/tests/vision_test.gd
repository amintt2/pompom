extends Node
## Test de bout en bout de VisionClient : la fenetre du test affiche une fausse « video » (scene animee)
## a un endroit connu ; on active la vision, on attend une reponse du service, et on verifie que la zone en
## mouvement trouvee par le service recouvre la fenetre (et on affiche ce qu'en pense l'encodeur).
##
##   tools\godot\Godot_v4.7.2-stable_win64_console.exe --path godot res://tests/vision_test.tscn [-- --cpu]
## (PAS --headless : il faut une vraie fenetre a l'ecran.) Code de sortie 0 = OK.

const RECT := Rect2i(320, 180, 800, 450)

var suggest: SuggestClient
var vision: VisionClient
var fails := 0
var events := 0
var _tex: ImageTexture
var _img: Image
var _t := 0.0


func _ready() -> void:
	GameState.no_save = true
	var w := get_window()
	w.borderless = true
	w.transparent = false
	w.transparent_bg = false
	w.unfocusable = true
	w.size = RECT.size
	w.position = RECT.position
	RenderingServer.set_default_clear_color(Color.BLACK)
	_img = Image.create(160, 90, false, Image.FORMAT_RGB8)
	_tex = ImageTexture.create_from_image(_img)
	var tr := TextureRect.new()
	tr.texture = _tex
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(tr)
	_run.call_deferred()


func _process(delta: float) -> void:
	# fausse video : ciel, soleil qui se deplace, collines qui defilent, bruit de « film »
	_t += delta
	for y in 90:
		for x in 160:
			var sky := Color(0.35 + 0.2 * sin(_t * 0.7), 0.55, 0.85).lerp(Color(1.0, 0.7, 0.4), y / 90.0)
			var hill := 55.0 + 10.0 * sin((x + _t * 40.0) * 0.08) + 6.0 * sin((x - _t * 25.0) * 0.21)
			var c := sky
			if y > hill:
				c = Color(0.15, 0.45 + 0.1 * sin(x * 0.3 + _t * 3.0), 0.2)
			var sun := Vector2(80 + 50 * sin(_t * 0.9), 25 + 8 * cos(_t * 1.3))
			if Vector2(x, y).distance_to(sun) < 9.0:
				c = Color(1, 0.95, 0.6)
			c = c.lightened(randf() * 0.06)
			_img.set_pixel(x, y, c)
	_tex.update(_img)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	suggest = SuggestClient.new()
	suggest.respect_setting = false
	suggest.use_gpu = not args.has("--cpu")
	add_child(suggest)
	vision = VisionClient.new()
	vision.respect_setting = false
	vision.service = suggest
	vision.poll_interval = 1.0
	add_child(vision)
	vision.vision_changed.connect(func(top: String, probs: Dictionary, r: Rect2, fs: bool):
		events += 1
		print("  vision_changed top=%s rect=%s fullscreen=%s probs=%s" % [top, r, fs, probs]))
	_check(suggest.start(), "service lance")
	var t0 := Time.get_ticks_msec()
	while suggest.state == "starting":
		await get_tree().process_frame
	_check(suggest.state == "ready", "service pret")
	vision.enable()
	# premiere reponse « ready », puis on laisse 4 passages d'encodeur pour la carte de mouvement
	while (vision.last.is_empty() or int(vision.last.get("ts", 0)) == 0) and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().create_timer(0.5).timeout
	print("vision prete en %d ms : %s" % [Time.get_ticks_msec() - t0, vision.last])
	_check(not vision.last.is_empty(), "reponse /vision")
	var t1 := Time.get_ticks_msec()
	var found := false
	while Time.get_ticks_msec() - t1 < 25000:
		await get_tree().create_timer(1.0).timeout
		var mr = vision.last.get("motion_rect")
		if typeof(mr) == TYPE_ARRAY and mr.size() == 4:
			var scr: Array = vision.last.get("screen", [0, 0, 0, 0])
			var m := Rect2(float(mr[0]) + float(scr[0]), float(mr[1]) + float(scr[1]), float(mr[2]), float(mr[3]))
			var inter := m.intersection(Rect2(RECT))
			var iou := inter.get_area() / (m.get_area() + Rect2(RECT).get_area() - inter.get_area())
			print("  zone en mouvement %s  IoU=%.2f  video_score=%s  video_rect=%s" % [m, iou, vision.last.get("video_score"), vision.last.get("video_rect")])
			if iou > 0.5:
				found = true
				break
	_check(found, "zone en mouvement = fenetre de test (IoU > 0.5)")
	print("probs : %s  top=%s  ms=%s  backend=%s" % [vision.last.get("probs"), vision.last.get("top"), vision.last.get("ms"), vision.last.get("backend")])
	_check(vision.last.get("probs", {}).size() == 7, "7 probabilites d'activite")
	var pid := suggest._pid
	vision.disable()
	await get_tree().create_timer(1.5).timeout
	suggest.stop()
	await get_tree().create_timer(2.5).timeout
	_check(not OS.is_process_running(pid), "service arrete")
	print("VISION TEST: ", "OK" if fails == 0 else "%d ECHEC(S)" % fails)
	get_tree().quit(0 if fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1
