class_name VideoLocator
extends Node
## Trouve ou est la video a l'ecran, sans IA : l'ecran est decoupe en une grille de petites cases ;
## une fois par seconde (sur un thread) on compare l'image a la precedente. Les cases qui bougent souvent
## pendant plusieurs secondes forment la video. Actif seulement quand il regarde une video.
##   signal video_moved(rect) : rectangle de la video en pixels ecran (Rect2() = plus de video)

signal video_moved(rect: Rect2)

const GW := 64  # grille (cases) : 2560 x 1440 -> cases de 40 x 40 px
const GH := 36
const INTERVAL := 1.0
const DECAY := 0.9  # memoire du mouvement (~8 s)
const DIFF := 10  # ecart de luminosite (0-255) pour dire qu'une case a bouge

var active := false:
	set(v):
		if v == active:
			return
		active = v
		if not v:
			_reset()
## Zones a ignorer (pixels ecran) : la fenetre du compagnon, ses bulles...
var ignore_rects: Array[Rect2] = []
## Ne chercher que dans cette zone (la fenetre au premier plan) si elle n'est pas vide.
var within := Rect2()
var rect := Rect2()  # derniere video trouvee
var cost_ms := 0.0

var _screen := 0
var _area := Rect2()
var _prev := PackedByteArray()
var _heat := PackedFloat32Array()
var _frames := 0
var _t := 0.0
var _task := -1
var _job := {}


func _reset() -> void:
	_prev = PackedByteArray()
	_heat = PackedFloat32Array()
	_frames = 0
	if rect != Rect2():
		rect = Rect2()
		video_moved.emit(rect)


func _process(delta: float) -> void:
	if _task != -1:
		if not WorkerThreadPool.is_task_completed(_task):
			return
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if _job.get("ok", false) and active:
			_finish(_job)
	if not active:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = INTERVAL
	_screen = DisplayServer.window_get_current_screen()
	var sr := Rect2(DisplayServer.screen_get_position(_screen), DisplayServer.screen_get_size(_screen))
	# on ne capture que la fenetre au premier plan (bien moins couteux que tout l'ecran)
	var area := within.intersection(sr) if within.has_area() else sr
	if not area.has_area():
		area = sr
	if area != _area:
		_area = area
		_prev = PackedByteArray()
		_heat = PackedFloat32Array()
		_frames = 0
	_job = {"area": Rect2i(area), "prev": _prev, "heat": _heat, "ok": false}
	_task = WorkerThreadPool.add_task(_work.bind(_job), false, "pompom_video")


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Thread : capture de l'ecran, reduction en niveaux de gris, carte de mouvement.
func _work(job: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var img := DisplayServer.screen_get_image_rect(job["area"])
	if img == null or img.is_empty():
		return
	img.convert(Image.FORMAT_RGBA8)
	img.resize(GW, GH, Image.INTERPOLATE_BILINEAR)
	img.convert(Image.FORMAT_L8)
	var cur := img.get_data()
	var prev: PackedByteArray = job["prev"]
	var heat: PackedFloat32Array = job["heat"]
	if heat.size() != GW * GH:
		heat = PackedFloat32Array()
		heat.resize(GW * GH)
	if prev.size() == cur.size():
		for i in GW * GH:
			var moved := absi(int(cur[i]) - int(prev[i])) > DIFF
			heat[i] = heat[i] * DECAY + (1.0 if moved else 0.0)
	job["cur"] = cur
	job["heat"] = heat
	job["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	job["ok"] = true


func _finish(job: Dictionary) -> void:
	_prev = job["cur"]
	_heat = job["heat"]
	cost_ms = job["ms"]
	_frames += 1
	if _frames < 4:
		return
	var sr := _area
	var cell := Vector2(sr.size.x / GW, sr.size.y / GH)
	# cases "vivantes" : elles ont bouge sur plusieurs des dernieres images
	var hot := PackedByteArray()
	hot.resize(GW * GH)
	var n_hot := 0
	for y in GH:
		for x in GW:
			var i := y * GW + x
			if _heat[i] < 1.6:
				continue
			var c := Rect2(sr.position + Vector2(x, y) * cell, cell)
			var skip := false
			for r in ignore_rects:
				if r.intersects(c):
					skip = true
					break
			if skip:
				continue
			hot[i] = 1
			n_hot += 1
	if n_hot < 6:
		_set_rect(Rect2())
		return
	# plus grand groupe de cases vivantes (voisinage elargi : une video n'est pas uniforme)
	var seen := PackedByteArray()
	seen.resize(GW * GH)
	var best := Rect2i()
	var best_n := 0
	for start in GW * GH:
		if hot[start] == 0 or seen[start] == 1:
			continue
		var stack := PackedInt32Array([start])
		seen[start] = 1
		var lo := Vector2i(start % GW, start / GW)
		var hi := lo
		var count := 0
		while not stack.is_empty():
			var k := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			count += 1
			var kx := k % GW
			var ky := k / GW
			lo = Vector2i(mini(lo.x, kx), mini(lo.y, ky))
			hi = Vector2i(maxi(hi.x, kx), maxi(hi.y, ky))
			for dy in range(-2, 3):
				for dx in range(-2, 3):
					var nx := kx + dx
					var ny := ky + dy
					if nx < 0 or ny < 0 or nx >= GW or ny >= GH:
						continue
					var j := ny * GW + nx
					if hot[j] == 1 and seen[j] == 0:
						seen[j] = 1
						stack.append(j)
		if count > best_n:
			best_n = count
			best = Rect2i(lo, hi - lo + Vector2i.ONE)
	if best_n < 6:
		_set_rect(Rect2())
		return
	_set_rect(Rect2(sr.position + Vector2(best.position) * cell, Vector2(best.size) * cell))


func _set_rect(r: Rect2) -> void:
	# on ne previent que si la video a vraiment bouge (evite de tourner la tete pour rien)
	if r == Rect2() and rect == Rect2():
		return
	if r != Rect2() and rect != Rect2() and r.get_center().distance_to(rect.get_center()) < 80.0 \
			and absf(r.size.x - rect.size.x) < 160.0:
		return
	rect = r
	video_moved.emit(r)
