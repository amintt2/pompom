class_name EnvCapture
extends Node
## Capture reguliere de l'ecran autour du compagnon (la fenetre du compagnon est exclue de la capture
## grace a Window.exclude_from_capture). La texture sert aux reflets / refractions.

const CAP_SIZE := 256  # resolution de la texture (la zone capturee est plus grande, puis reduite)

var interval := 0.1
var stage: PetStage
var avg_color := Color(0.3, 0.3, 0.35)
var enabled := true
## Mode "visible en partage d'ecran" : la fenetre n'est plus exclue des captures, donc la capture
## contient le compagnon lui-meme. On efface ses pixels (grace a sa propre image) et on reconstruit
## le fond derriere lui a partir des alentours (inpainting).
var inpaint := false
var texture: ImageTexture
var cap_rect := Rect2i()
var _timer := 0.0
var _busy := false


## win_rect : rectangle de la fenetre a l'ecran ; pet_center : centre du compagnon a l'ecran ;
## pet_px : taille du compagnon en pixels. Renvoie false si la capture a echoue.
func capture(win_rect: Rect2i, pet_center: Vector2, pet_px: float, pet: Pet, self_img: Image = null) -> bool:
	if not enabled:
		return false
	var half := int(maxf(pet_px * 2.6, maxf(win_rect.size.x, win_rect.size.y) * 0.75))
	var r := Rect2i(Vector2i(pet_center) - Vector2i(half, half), Vector2i(half * 2, half * 2))
	var scr := DisplayServer.window_get_current_screen()
	var srect := Rect2i(DisplayServer.screen_get_position(scr), DisplayServer.screen_get_size(scr))
	r = r.intersection(srect)
	if r.size.x < 16 or r.size.y < 16:
		return false
	var img := DisplayServer.screen_get_image_rect(r)
	if img == null or img.is_empty():
		return false
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img.resize(CAP_SIZE, CAP_SIZE, Image.INTERPOLATE_BILINEAR)
	if inpaint and self_img != null:
		_inpaint(img, r, win_rect, self_img)
	var tiny := img.duplicate() as Image
	tiny.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	avg_color = avg_color.lerp(tiny.get_pixel(0, 0), 0.3)
	img.generate_mipmaps()
	if texture == null:
		texture = ImageTexture.create_from_image(img)
	else:
		texture.update(img)
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
	return true


## Efface le compagnon de la capture et reconstruit le fond derriere lui.
## La zone a remplir est connue exactement : ce sont les pixels non transparents de sa propre fenetre.
func _inpaint(img: Image, r: Rect2i, win_rect: Rect2i, self_img: Image) -> void:
	var n := img.get_width()
	var sx := float(n) / r.size.x
	var sy := float(n) / r.size.y
	var x0 := int(floor((win_rect.position.x - r.position.x) * sx))
	var y0 := int(floor((win_rect.position.y - r.position.y) * sy))
	var x1 := int(ceil((win_rect.end.x - r.position.x) * sx))
	var y1 := int(ceil((win_rect.end.y - r.position.y) * sy))
	var cx0 := clampi(x0, 0, n)
	var cy0 := clampi(y0, 0, n)
	var cx1 := clampi(x1, 0, n)
	var cy1 := clampi(y1, 0, n)
	if cx1 - cx0 < 2 or cy1 - cy0 < 2:
		return
	# masque du compagnon (sa propre image, reduite a la resolution de la capture)
	var a := self_img.duplicate() as Image
	a.resize(maxi(1, x1 - x0), maxi(1, y1 - y0), Image.INTERPOLATE_BILINEAR)
	var hole := {}
	for y in range(cy0, cy1):
		for x in range(cx0, cx1):
			if a.get_pixel(x - x0, y - y0).a > 0.02:
				# un pixel de marge (bords flous, petit decalage temporel)
				for dy in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						var px: int = x + dx
						var py: int = y + dy
						if px >= 0 and py >= 0 and px < n and py < n:
							hole[Vector2i(px, py)] = true
	if hole.is_empty():
		return
	# remplissage a basse resolution : chaque trou prend la moyenne de ses voisins connus, couche par couche
	const LOW := 64
	var f := float(n) / LOW
	var low := img.duplicate() as Image
	low.resize(LOW, LOW, Image.INTERPOLATE_BILINEAR)
	var lhole := {}
	for p in hole:
		lhole[Vector2i(int(p.x / f), int(p.y / f))] = true
	var guard := 0
	while not lhole.is_empty() and guard < 64:
		guard += 1
		var done: Array[Vector2i] = []
		var vals: Array[Color] = []
		for p in lhole:
			var acc := Color(0, 0, 0, 0)
			var cnt := 0
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
				var q: Vector2i = p + d
				if q.x < 0 or q.y < 0 or q.x >= LOW or q.y >= LOW or lhole.has(q):
					continue
				acc += low.get_pixelv(q)
				cnt += 1
			if cnt > 0:
				done.append(p)
				vals.append(acc / cnt)
		if done.is_empty():
			break
		for i in done.size():
			low.set_pixelv(done[i], vals[i])
			lhole.erase(done[i])
	# reinjection dans la capture pleine resolution (interpolation bilineaire du fond reconstruit)
	for p in hole:
		var u := (float(p.x) + 0.5) / f - 0.5
		var v := (float(p.y) + 0.5) / f - 0.5
		var ix := clampi(int(floor(u)), 0, LOW - 2)
		var iy := clampi(int(floor(v)), 0, LOW - 2)
		var tx := clampf(u - ix, 0.0, 1.0)
		var ty := clampf(v - iy, 0.0, 1.0)
		var c := low.get_pixel(ix, iy).lerp(low.get_pixel(ix + 1, iy), tx).lerp(
			low.get_pixel(ix, iy + 1).lerp(low.get_pixel(ix + 1, iy + 1), tx), ty)
		c.a = 1.0
		img.set_pixelv(p, c)
