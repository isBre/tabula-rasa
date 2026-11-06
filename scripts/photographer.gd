extends Node
## Renders photos of the world from any point of view, for the agents' vision.
## Uses one SubViewport (sharing the main World3D) that renders only on demand.

const WIDTH := 800
const HEIGHT := 450

var _vp: SubViewport
var _cam: Camera3D
var _busy := false


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(WIDTH, HEIGHT)
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.msaa_3d = Viewport.MSAA_2X
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 600.0
	_vp.add_child(_cam)
	_cam.make_current()


## Takes a photo from `from` looking at `target`. Nodes in `hide` are hidden during the shot.
func capture(from: Vector3, target: Vector3, hide: Array = []) -> Image:
	while _busy:
		await get_tree().process_frame
	_busy = true
	_cam.global_position = from
	var dir := target - from
	if dir.length() > 0.01:
		var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
		_cam.look_at(target, up)
	var hidden: Array = []
	for h in hide:
		if is_instance_valid(h) and h.visible:
			h.visible = false
			hidden.append(h)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	for h in hidden:
		if is_instance_valid(h):
			h.visible = true
	var img := _vp.get_texture().get_image()
	_busy = false
	return img


## Four framed views of an AABB in one 2x2 image: front, right side, back 3/4, top.
func contact_sheet(box: AABB, hide: Array = []) -> Image:
	var center := box.get_center()
	var radius: float = max(box.size.length() * 0.5, 0.5)
	var dist := radius / tan(deg_to_rad(_cam.fov * 0.5)) * 0.95
	var dirs := [Vector3(0, 0.35, 1), Vector3(1, 0.35, 0), Vector3(-0.7, 0.6, -0.7), Vector3(0.01, 1, 0.01)]
	var sheet := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.6, 0.6, 0.6))
	var half := Vector2i(WIDTH >> 1, HEIGHT >> 1)
	var cell := half - Vector2i(2, 2)
	for i in dirs.size():
		var from: Vector3 = center + (dirs[i] as Vector3).normalized() * dist
		var img: Image = await capture(from, center, hide)
		img.convert(Image.FORMAT_RGB8)
		img.resize(cell.x, cell.y, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, cell), Vector2i((i % 2) * half.x + 1, (i >> 1) * half.y + 1))
	return sheet
