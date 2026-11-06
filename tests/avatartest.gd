extends "res://scripts/main.gd"
## Photos of the player's avatar in different poses, as an agent would see it.
## Output: res://tests/avatartest_sheet.jpg (2x2), avatartest_view.jpg, avatartest_output.txt

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	team.set_follow(false)
	for b in team.brains:
		b.body.position = Vector3(30, 2, 30)
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation = Vector3(0, deg_to_rad(-30), 0)
	player.head.rotation = Vector3.ZERO
	World.run_script({"code": "extends Node3D\nfunc _ready():\n\tadd_child(Shapes.tree(\"round\", 4, 2))\n", "position": [2, 0, -4], "name": "albero"}, "Paesaggista")
	await get_tree().create_timer(0.6).timeout
	var shots: Array = []
	shots.append(await _shot("fermo"))
	_key(KEY_W, true)
	await get_tree().create_timer(0.35).timeout
	shots.append(await _shot("cammina"))
	_key(KEY_W, false)
	await get_tree().create_timer(0.6).timeout
	build.toggle()
	player.head.rotation.x = 0.25
	await get_tree().create_timer(0.5).timeout
	shots.append(await _shot("costruisce"))
	build.toggle()
	player.head.rotation.x = 0.0
	player.flying = true
	player.global_position = Vector3(0, 2.5, 0)
	_key(KEY_W, true)
	await get_tree().create_timer(0.4).timeout
	shots.append(await _shot("vola"))
	_key(KEY_W, false)
	var sheet := Image.create(1600, 900, false, Image.FORMAT_RGB8)
	for i in 4:
		var img: Image = shots[i]
		img.convert(Image.FORMAT_RGB8)
		sheet.blit_rect(img, Rect2i(0, 0, 800, 450), Vector2i((i % 2) * 800, (i >> 1) * 450))
	sheet.save_jpg(ProjectSettings.globalize_path("res://tests/avatartest_sheet.jpg"))
	player.flying = false
	player.global_position = Vector3(0, 0.1, 0)
	await get_tree().create_timer(0.8).timeout
	var view := get_viewport().get_texture().get_image()
	view.save_jpg(ProjectSettings.globalize_path("res://tests/avatartest_view.jpg"))
	_out.append("world state line: " + World.describe("Critico").get_slice("\n", 0))
	var f := FileAccess.open("res://tests/avatartest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()


func _shot(label: String) -> Image:
	var p: Vector3 = player.global_position
	var side: Vector3 = player.global_transform.basis.x
	var img: Image = await team.photographer.capture(p + side * 3.2 + Vector3(0, 1.4, -1.2), p + Vector3(0, 1.0, 0), [])
	_out.append("%s: activity=%s" % [label, player.activity_desc()])
	return img


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
