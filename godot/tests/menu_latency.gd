extends Node
## Mesure le temps d'ouverture du menu et de la boutique (ms jusqu'a la premiere image affichee).


func _ready() -> void:
	GameState.no_save = true
	await get_tree().create_timer(1.0).timeout
	for i in 4:
		var t0 := Time.get_ticks_usec()
		var m := PetMenu.open_at(Vector2i(800, 500), PetMenu.default_items(false), Callable(), self)
		var t1 := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		var t2 := Time.get_ticks_usec()
		print("MENU open call=%.1fms first_frame=%.1fms" % [(t1 - t0) / 1000.0, (t2 - t0) / 1000.0])
		await get_tree().create_timer(0.4).timeout
		m.hide()
		await get_tree().create_timer(0.3).timeout
	var shop := ShopWindow.new()
	shop.keep_alive = true
	add_child(shop)
	var tp := Time.get_ticks_usec()
	shop.prebuild()
	print("SHOP prebuild (au demarrage, cache)=%.1fms" % ((Time.get_ticks_usec() - tp) / 1000.0))
	await get_tree().create_timer(1.0).timeout
	for i in 3:
		var t0 := Time.get_ticks_usec()
		shop.open("head" if i != 1 else "look")
		var t1 := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		var t2 := Time.get_ticks_usec()
		print("SHOP open call=%.1fms first_frame=%.1fms" % [(t1 - t0) / 1000.0, (t2 - t0) / 1000.0])
		await get_tree().create_timer(1.0).timeout
		shop.close_shop()
		await get_tree().create_timer(0.5).timeout
		print("SHOP after close: valid=%s visible=%s" % [is_instance_valid(shop), shop.visible])
	get_tree().quit()
