extends Node
## Test du detecteur de video : une fenetre affiche une zone animee (fausse video) a un endroit connu ;
## le detecteur doit la retrouver. (La recherche est limitee a cette fenetre : le vrai ecran peut bouger aussi.)

var _video: ColorRect
var _t := 0.0


func _ready() -> void:
	var w := Window.new()
	w.title = "Pompom test video"
	w.size = Vector2i(900, 600)
	w.position = Vector2i(120, 120)
	w.unfocusable = true
	add_child(w)
	var bg := ColorRect.new()
	bg.color = Color(0.95, 0.95, 0.95)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	w.add_child(bg)
	_video = ColorRect.new()
	_video.position = Vector2(60, 60)
	_video.size = Vector2(480, 270)
	w.add_child(_video)
	var loc := VideoLocator.new()
	add_child(loc)
	await get_tree().create_timer(0.5).timeout
	loc.within = Rect2(Vector2(w.position), Vector2(w.size))
	loc.active = true
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 9000:
		await get_tree().create_timer(0.3).timeout
	var expect := Rect2(Vector2(w.position) + _video.position, _video.size)
	var got := loc.rect
	var ok := got.has_area() and got.get_center().distance_to(expect.get_center()) < 120.0
	print("VIDEOLOC expect=%s got=%s cost=%.1fms -> %s" % [expect, got, loc.cost_ms, "OK" if ok else "KO"])
	get_tree().quit(0 if ok else 1)


func _process(delta: float) -> void:
	_t += delta
	if _video:
		# une "video" : couleurs et motifs qui changent sans arret
		_video.color = Color.from_hsv(fmod(_t * 0.37, 1.0), 0.8, 0.5 + 0.5 * sin(_t * 5.0))
