extends Node
## Planche de la carte « Il s'est trompé » et de la pastille (verification visuelle) :
##   Godot --path godot res://tests/feedback_shot.tscn
## Sortie : %APPDATA%/Pompom/feedback_card_sheet.png (etats : vide, choix + JSON, « Autre… », sans partage, pastille)

const BG := Color("6b7a93")

var sheet_parts: Array = []


func _ready() -> void:
	GameState.no_save = true
	get_tree().create_timer(60.0).timeout.connect(func(): get_tree().quit(2))
	var w := get_window()
	w.size = Vector2i(64, 64)
	w.position = Vector2i(0, 0)
	_run.call_deferred()


func _ctx(extra := {}) -> Dictionary:
	var c := {"situation": "video_watch", "mode": "video", "vision": "video", "proc": "spotify", "title": "x",
		"event": "", "game": "", "game_context": false}
	c.merge(extra, true)
	return c


func _emb() -> Dictionary:
	var a := PackedFloat32Array()
	a.resize(768)
	for i in 768:
		a[i] = sin(i * 0.37) / 19.6
	return {"b64": Marshalls.raw_to_base64(a.to_byte_array()), "dtype": "float32", "dim": 768,
		"model_id": "siglip-b16-224.fp16", "model_version": "e79563a4df40"}


func _shot_card(ctx: Dictionary, opts: Dictionary, actions: Callable, label: String) -> void:
	var card := FeedbackCard.new()
	add_child(card)
	card.preview_provider = func(ch: Array) -> String:
		var samples: Array = []
		for c in ch:
			samples.append({"task": c["task"], "label": c["label"], "app": "Spotify.exe", "emb": _emb(),
				"pet": {"situation": "video_watch", "mode": "video", "vision": "video", "event": ""}})
		return FeedbackUploader.preview_json(samples)
	opts["anchor"] = Rect2i(900, 300, 260, 300)
	card.open_for(ctx, opts)
	await get_tree().create_timer(0.35).timeout
	actions.call(card)
	await get_tree().create_timer(0.45).timeout
	await RenderingServer.frame_post_draw
	var img := card.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	sheet_parts.append([label, img])
	print("SHOT ", label, " ", img.get_size(), " choices=", card.choices())
	card.queue_free()
	await get_tree().process_frame


func _run() -> void:
	await get_tree().create_timer(0.3).timeout
	var share := {"share_available": true, "share_default": true, "embedding": "ok"}
	await _shot_card(_ctx(), share.duplicate(), func(_c): pass, "1_vide")
	await _shot_card(_ctx({"event": "goal", "event_ago": 4.0, "game": "rocketleague", "game_context": true}),
		share.duplicate(), func(c: FeedbackCard):
			c.select("activity", "music")
			c.select("game_event", "goal")
			c._see.pressed.emit(), "2_choix_json")
	await _shot_card(_ctx({"field": {"name": "Adresse e-mail", "process": "chrome.exe"}}), {"share_available": false},
		func(c: FeedbackCard):
			c.select("activity", "other")
			c._note.text = "Je regardais un tuto en fond", "3_autre_sans_partage")
	await _shot_card(_ctx(), {"share_available": true, "embedding": "none"}, func(c: FeedbackCard):
		c.select("activity", "music"), "4_sans_embedding")
	# pastille
	var chip := FeedbackChip.new()
	add_child(chip)
	chip.duration = 30.0
	chip.show_near(Rect2i(900, 300, 260, 300))
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var ci := chip.get_texture().get_image()
	ci.convert(Image.FORMAT_RGBA8)
	sheet_parts.append(["5_pastille", ci])
	print("SHOT chip ", ci.get_size())
	_save_sheet()
	get_tree().quit()


func _save_sheet() -> void:
	var pad := 24
	var wsum := pad
	var hmax := 0
	for p in sheet_parts:
		wsum += (p[1] as Image).get_width() + pad
		hmax = maxi(hmax, (p[1] as Image).get_height())
	var sheet := Image.create(wsum, hmax + pad * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(BG)
	var x := pad
	for p in sheet_parts:
		var img: Image = p[1]
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(x, pad))
		x += img.get_width() + pad
	var path := ProjectSettings.globalize_path("user://feedback_card_sheet.png")
	sheet.save_png(path)
	print("SHEET ", path)
