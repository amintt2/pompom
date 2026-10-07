extends Node
## Mesure (developpeur) de la taille des captures du mode developpeur selon le format :
##   Godot --path godot res://tests/capture_size_bench.tscn [-- --n=4]
## Capture l'ecran principal n fois (1 s d'ecart), encode en WebP 0.85 / JPEG 0.85 / PNG, affiche tailles et
## temps d'encodage, puis SUPPRIME les fichiers (rien n'est garde).

func _ready() -> void:
	var n := 4
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			n = int(a.trim_prefix("--n="))
	get_window().size = Vector2i(1, 1)
	await get_tree().create_timer(0.5).timeout
	var d := OS.get_user_data_dir().path_join("bench_capture")
	DirAccess.make_dir_recursive_absolute(d)
	var tot := {"webp": 0, "jpg": 0, "png": 0}
	var ms := {"webp": 0, "jpg": 0, "png": 0}
	var sc := DisplayServer.get_primary_screen()
	var rect := Rect2i(DisplayServer.screen_get_position(sc), DisplayServer.screen_get_size(sc))
	for i in n:
		var img := DisplayServer.screen_get_image_rect(rect)
		img.convert(Image.FORMAT_RGB8)
		for fmt in ["webp", "jpg", "png"]:
			var p := d.path_join("b%d.%s" % [i, fmt])
			var t0 := Time.get_ticks_msec()
			match fmt:
				"webp": img.save_webp(p, true, 0.85)
				"jpg": img.save_jpg(p, 0.85)
				"png": img.save_png(p)
			ms[fmt] += Time.get_ticks_msec() - t0
			var f := FileAccess.open(p, FileAccess.READ)
			tot[fmt] += f.get_length()
			f.close()
			DirAccess.remove_absolute(p)
		print("BENCH capture %d %dx%d" % [i, img.get_width(), img.get_height()])
		await get_tree().create_timer(1.0).timeout
	DirAccess.remove_absolute(d)
	for fmt in tot:
		print("BENCH %s moyenne %.0f Ko, encodage %.0f ms" % [fmt, tot[fmt] / 1024.0 / n, ms[fmt] / float(n)])
	get_tree().quit()
