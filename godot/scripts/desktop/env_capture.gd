class_name EnvCapture
extends Node
## Capture reguliere de l'ecran autour du compagnon. La texture sert aux reflets / refractions.
## Tout le travail lourd (copie de l'ecran, reduction, effacement du compagnon) se fait sur un thread :
## la boucle d'affichage ne fait que lancer la tache puis envoyer l'image prete a la carte graphique.

const CAP_SIZE := 256  # resolution de la texture (la zone capturee est plus grande, puis reduite)
const LOW := 32  # resolution du remplissage derriere le compagnon

var interval := 0.1
var stage: PetStage
var avg_color := Color(0.3, 0.3, 0.35)
var enabled := true
## Mode "visible en partage d'ecran" : la fenetre n'est plus exclue des captures, donc la capture
## contient le compagnon lui-meme. On efface ses pixels (tout ce que sa fenetre peut dessiner tient dans
## son polygone cliquable) et on reconstruit le fond derriere lui a partir des alentours (inpainting).
var inpaint := false
var texture: ImageTexture
var cap_rect := Rect2i()
var _task := -1
var _job: Dictionary = {}
# mesure (--bench)
var cost_us := 0
var cost_n := 0
var cost_max := 0


## win_rect : rectangle de la fenetre a l'ecran ; pet_center : centre du compagnon a l'ecran ;
## pet_px : taille du compagnon en pixels ; mask_poly : zone ou la fenetre dessine (coordonnees fenetre).
## Renvoie false si une capture est deja en cours ou impossible.
func capture(win_rect: Rect2i, pet_center: Vector2, pet_px: float, pet: Pet, mask_poly := PackedVector2Array()) -> bool:
	if not enabled or _task != -1:
		return false
	var half := int(maxf(pet_px * 2.6, maxf(win_rect.size.x, win_rect.size.y) * 0.75))
	var r := Rect2i(Vector2i(pet_center) - Vector2i(half, half), Vector2i(half * 2, half * 2))
	var scr := DisplayServer.window_get_current_screen()
	var srect := Rect2i(DisplayServer.screen_get_position(scr), DisplayServer.screen_get_size(scr))
	r = r.intersection(srect)
	if r.size.x < 16 or r.size.y < 16:
		return false
	if inpaint and mask_poly.size() < 3:
		var sz := Vector2(win_rect.size)
		mask_poly = PackedVector2Array([Vector2.ZERO, Vector2(sz.x, 0), sz, Vector2(0, sz.y)])
	_job = {"r": r, "win": win_rect, "center": pet_center, "pet_px": pet_px, "pet": pet,
		"poly": mask_poly if inpaint else PackedVector2Array(), "ok": false}
	_task = WorkerThreadPool.add_task(_work.bind(_job), false, "pompom_env")
	return true


func _process(_delta: float) -> void:
	if _task == -1 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var job := _job
	_job = {}
	if job.get("ok", false):
		_apply(job)


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Sur le thread : copie de l'ecran, reduction, effacement du compagnon, couleur moyenne, mipmaps.
func _work(job: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var img := DisplayServer.screen_get_image_rect(job["r"])
	if img == null or img.is_empty():
		return
	var t1 := Time.get_ticks_usec()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.resize(CAP_SIZE, CAP_SIZE, Image.INTERPOLATE_BILINEAR)
	var t2 := Time.get_ticks_usec()
	var poly: PackedVector2Array = job["poly"]
	if poly.size() >= 3:
		_inpaint(img, job["r"], job["win"], poly)
	var t3 := Time.get_ticks_usec()
	if OS.has_environment("POMPOM_CAPDBG"):
		print("CAP grab=%d resize=%d inpaint=%d size=%s" % [t1 - t0, t2 - t1, t3 - t2, job["r"].size])
	var tiny := img.duplicate() as Image
	tiny.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	job["avg"] = tiny.get_pixel(0, 0)
	img.generate_mipmaps()
	job["img"] = img
	job["ok"] = true
	var dt := Time.get_ticks_usec() - t0
	cost_us += dt
	cost_n += 1
	cost_max = maxi(cost_max, dt)


## Sur la boucle principale : envoi de la texture et des parametres au compagnon.
func _apply(job: Dictionary) -> void:
	var pet: Pet = job["pet"]
	if not is_instance_valid(pet):
		return
	var img: Image = job["img"]
	if texture == null or texture.get_size() != Vector2(img.get_size()):
		texture = ImageTexture.create_from_image(img)
	else:
		texture.update(img)
	avg_color = avg_color.lerp(job["avg"], 0.3)
	var r: Rect2i = job["r"]
	var win_rect: Rect2i = job["win"]
	var pet_center: Vector2 = job["center"]
	var pet_px: float = job["pet_px"]
	cap_rect = r
	var sz := Vector2(r.size)
	var rect := Vector4(
		float(win_rect.position.x - r.position.x) / sz.x, float(win_rect.position.y - r.position.y) / sz.y,
		float(win_rect.size.x) / sz.x, float(win_rect.size.y) / sz.y)
	var center := (pet_center - Vector2(r.position)) / sz
	var spread := clampf(pet_px * 1.6 / sz.x, 0.08, 0.48)
	var uvu := Vector2(stage.ppu / sz.x, stage.ppu / sz.y) if stage else Vector2(0.25, 0.25)
	pet.set_env(texture, rect, center, spread, 1.0, uvu, avg_color)
	if stage:
		stage.match_screen_light(avg_color)


## Efface le compagnon de la capture et reconstruit le fond derriere lui.
## Le trou est le polygone de la fenetre (il contient tout ce qu'elle dessine : compagnon, ombre, bulles),
## rempli a basse resolution depuis ses bords puis recolle en douceur sur la capture.
func _inpaint(img: Image, r: Rect2i, win_rect: Rect2i, poly: PackedVector2Array) -> void:
	var n := img.get_width()
	var fx := float(LOW) / r.size.x
	var fy := float(LOW) / r.size.y
	var off := Vector2(win_rect.position - r.position)
	# boite du polygone en cellules basse resolution
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	var cx0 := clampi(int(floor((lo.x + off.x) * fx)) - 1, 0, LOW)
	var cy0 := clampi(int(floor((lo.y + off.y) * fy)) - 1, 0, LOW)
	var cx1 := clampi(int(ceil((hi.x + off.x) * fx)) + 1, 0, LOW)
	var cy1 := clampi(int(ceil((hi.y + off.y) * fy)) + 1, 0, LOW)
	if cx1 - cx0 < 1 or cy1 - cy0 < 1:
		return
	# cellules touchees par le polygone (centre dedans), puis une cellule de marge tout autour
	var inside := PackedByteArray()
	inside.resize(LOW * LOW)
	for y in range(cy0, cy1):
		for x in range(cx0, cx1):
			var q := Vector2((x + 0.5) / fx, (y + 0.5) / fy) - off
			if Geometry2D.is_point_in_polygon(q, poly):
				inside[y * LOW + x] = 1
	var hole := PackedByteArray()
	hole.resize(LOW * LOW)
	var todo := PackedInt32Array()
	for y in range(maxi(cy0 - 1, 0), mini(cy1 + 1, LOW)):
		for x in range(maxi(cx0 - 1, 0), mini(cx1 + 1, LOW)):
			var hit := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var px := x + dx
					var py := y + dy
					if px >= 0 and py >= 0 and px < LOW and py < LOW and inside[py * LOW + px] == 1:
						hit = true
			if hit:
				hole[y * LOW + x] = 1
				todo.append(y * LOW + x)
	if todo.is_empty():
		return
	var low := img.duplicate() as Image
	low.resize(LOW, LOW, Image.INTERPOLATE_BILINEAR)
	var d := low.get_data()
	# alpha du raccord : 1 sur le trou (marge comprise), 0 ailleurs ; l'agrandissement bilineaire l'adoucit
	for i in LOW * LOW:
		d[i * 4 + 3] = 255 if hole[i] == 1 else 0
	# remplissage couche par couche : chaque cellule du trou prend la moyenne de ses voisines connues
	var guard := 0
	while not todo.is_empty() and guard < LOW:
		guard += 1
		var done := PackedInt32Array()
		var vals := PackedInt32Array()
		var rest := PackedInt32Array()
		for i in todo:
			var x := i % LOW
			var y := i / LOW
			var ar := 0
			var ag := 0
			var ab := 0
			var cnt := 0
			for dy in range(-1, 2):
				var py := y + dy
				if py < 0 or py >= LOW:
					continue
				for dx in range(-1, 2):
					var px := x + dx
					if px < 0 or px >= LOW:
						continue
					var j := py * LOW + px
					if hole[j] == 1:
						continue
					ar += d[j * 4]
					ag += d[j * 4 + 1]
					ab += d[j * 4 + 2]
					cnt += 1
			if cnt > 0:
				done.append(i)
				vals.append(ar / cnt)
				vals.append(ag / cnt)
				vals.append(ab / cnt)
			else:
				rest.append(i)
		if done.is_empty():
			break
		for k in done.size():
			var i := done[k]
			d[i * 4] = vals[k * 3]
			d[i * 4 + 1] = vals[k * 3 + 1]
			d[i * 4 + 2] = vals[k * 3 + 2]
			hole[i] = 0
		todo = rest
	var fill := Image.create_from_data(LOW, LOW, false, Image.FORMAT_RGBA8, d)
	fill.resize(n, n, Image.INTERPOLATE_BILINEAR)
	img.blend_rect(fill, Rect2i(0, 0, n, n), Vector2i.ZERO)
