extends "res://scripts/main.gd"
## Simulated key presses: acceleration, stopping, jump height, sprint, stairs.
## Output: res://tests/movetest_output.txt

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation = Vector3.ZERO
	player.head.rotation = Vector3.ZERO
	await get_tree().create_timer(0.5).timeout

	_key(KEY_W, true)
	for t in [0.05, 0.1, 0.2, 0.5]:
		await get_tree().create_timer(t if t == 0.05 else t - [0.05, 0.1, 0.2, 0.5][[0.05, 0.1, 0.2, 0.5].find(t) - 1]).timeout
		_out.append("W held %.2f s: speed %.2f m/s" % [t, _hspeed()])
	var z0: float = player.global_position.z
	_key(KEY_W, false)
	await get_tree().create_timer(0.6).timeout
	_out.append("released W: stopped after %.2f m, speed now %.2f" % [z0 - player.global_position.z, _hspeed()])

	_key(KEY_SHIFT, true)
	_key(KEY_W, true)
	await get_tree().create_timer(0.8).timeout
	_out.append("sprint: speed %.2f m/s, fov %.1f" % [_hspeed(), player.camera.fov])
	_key(KEY_W, false)
	_key(KEY_SHIFT, false)
	await get_tree().create_timer(0.8).timeout

	var y0: float = player.global_position.y
	var peak := y0
	_key(KEY_SPACE, true)
	var t_air := 0.0
	while t_air < 2.0:
		await get_tree().physics_frame
		t_air += get_physics_process_delta_time()
		peak = maxf(peak, player.global_position.y)
		if t_air > 0.2 and player.is_on_floor():
			break
	_key(KEY_SPACE, false)
	_out.append("jump (Space held): height %.2f m, air time %.2f s" % [peak - y0, t_air])
	await get_tree().create_timer(0.3).timeout
	y0 = player.global_position.y
	peak = y0
	_key(KEY_SPACE, true)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_key(KEY_SPACE, false)
	t_air = 0.0
	while t_air < 2.0:
		await get_tree().physics_frame
		t_air += get_physics_process_delta_time()
		peak = maxf(peak, player.global_position.y)
		if t_air > 0.2 and player.is_on_floor():
			break
	_out.append("short hop (Space tapped): height %.2f m" % (peak - y0))

	# stairs: 10 steps of 0.2 m, walk up without jumping
	World.run_script({"code": "extends Node3D\nfunc _ready():\n\tadd_child(Shapes.stairs(2, 2, 3.5, 10, \"legno\"))\n\tvar top := Shapes.box(Vector3(2, 2, 3), \"legno\")\n\ttop.position.z = -5\n\tadd_child(top)\n", "position": [0, 0, -4], "name": "scala"}, "player")
	await get_tree().create_timer(0.3).timeout
	player.global_position = Vector3(0, 0.1, -2)
	await get_tree().create_timer(0.3).timeout
	_key(KEY_W, true)
	var max_dy := 0.0
	var last_y: float = player.head.global_position.y
	var t := 0.0
	while t < 2.0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
		max_dy = maxf(max_dy, absf(player.head.global_position.y - last_y))
		last_y = player.head.global_position.y
	_key(KEY_W, false)
	_out.append("stairs: feet at y=%.2f (top is 2.0), z=%.2f, biggest camera jump per frame %.3f m" % [player.global_position.y, player.global_position.z, max_dy])
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/movetest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()


func _hspeed() -> float:
	return Vector2(player.velocity.x, player.velocity.z).length()


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
