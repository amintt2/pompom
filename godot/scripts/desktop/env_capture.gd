class_name EnvCapture
extends Node
## Capture reguliere de l'ecran autour du compagnon (la fenetre du compagnon est exclue de la capture
## grace a Window.exclude_from_capture). La texture sert aux reflets / refractions.

const CAP_SIZE := 256  # resolution de la texture (la zone capturee est plus grande, puis reduite)

var interval := 0.1
var stage: PetStage
var avg_color := Color(0.3, 0.3, 0.35)
var enabled := true
var texture: ImageTexture
var cap_rect := Rect2i()
var _timer := 0.0
var _busy := false


## win_rect : rectangle de la fenetre a l'ecran ; pet_center : centre du compagnon a l'ecran ;
## pet_px : taille du compagnon en pixels. Renvoie false si la capture a echoue.
func capture(win_rect: Rect2i, pet_center: Vector2, pet_px: float, pet: Pet) -> bool:
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
