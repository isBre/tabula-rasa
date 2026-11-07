extends "res://scripts/main.gd"
## Offline: follow mode, release after work, reviewer auto-trigger, photo with followers.
## Output: res://tests/teamtest_output.txt + teamtest_view.jpg (player's view) + teamtest_photo.jpg

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	env.set_values({"time_of_day": 11, "ground": "grass"})
	player.set_process_unhandled_input(false)
	player.set_physics_process(false)
	build.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation = Vector3.ZERO
	player.head.rotation = Vector3.ZERO
	_out.append("team: %s (lead %s), reviewer: %s" % [team.names_list(), team.lead_name(), str(team.brains.filter(func(b): return b.is_reviewer).map(func(b): return b.agent_name))])
	_out.append("models: %s" % str(team.brains.map(func(b): return b.agent_name + "=" + b.model)))
	await get_tree().create_timer(3.0).timeout
	_out.append("follow positions (player at 0,0,0 looking -Z):")
	for b in team.brains:
		_out.append("  %s %s" % [b.agent_name, World._v(b.body.global_position)])
	var view: Image = await team.photographer.capture(player.camera.global_position, player.camera.global_position + player.get_forward() * 10.0, [])
	view.save_jpg(ProjectSettings.globalize_path("res://tests/teamtest_view.jpg"))

	# small moves: agents stay put. Walking far away: they catch up.
	var arch = team.find_brain("Architect")
	var before: Vector3 = arch.body.global_position
	player.global_position = Vector3(6, 0.1, 0)
	player.rotation.y = PI
	await get_tree().create_timer(2.0).timeout
	_out.append("player moved 6 m and turned: Architect moved %.1f m (should be ~0)" % arch.body.global_position.distance_to(before))
	player.global_position = Vector3(40, 0.1, 0)
	await get_tree().create_timer(6.0).timeout
	_out.append("player 40 m away: Architect at %s, distance %.1f m (should be ~5)" % [World._v(arch.body.global_position), arch.body.global_position.distance_to(player.global_position)])
	player.global_position = Vector3(0, 0.1, 0)
	player.rotation.y = 0.0
	await get_tree().create_timer(6.0).timeout

	# working: move_to keeps the agent there, release brings it back
	arch.body.move_to(Vector3(20, 2, 20))
	await get_tree().create_timer(4.0).timeout
	_out.append("working: Architect at %s (should be ~20,2,20)" % World._v(arch.body.global_position))
	arch.body.release_after(0.5)
	await get_tree().create_timer(6.0).timeout
	_out.append("released: Architect at %s (back near the player)" % World._v(arch.body.global_position))

	# reviewer trigger: two teammates finish close together -> one review
	var critic = team.find_brain("Critic")
	team.on_turn_finished(team.find_brain("Decorator"), ["run_script obj_5 \"bench\"", "update_board "])
	await get_tree().create_timer(1.0).timeout
	team.on_turn_finished(team.find_brain("Landscaper"), ["spawn_blueprint streetlight (obj_6)"])
	team.on_turn_finished(team.find_brain("Engineer"), ["set_environment "])
	team.on_turn_finished(critic, ["run_script obj_7"])
	await get_tree().create_timer(8.0).timeout
	_out.append("critic pending: %s" % str(critic._pending))
	_out.append("review budget left: %d" % team._review_budget)

	# photo from the player's view with all agents following: they must be hidden
	player.rotation.y = 0.0
	World.run_script({"code": "extends Node3D\nfunc _ready():\n\tadd_child(Shapes.tree(\"round\", 5, 1))\n", "position": [0, 0, -6], "name": "tree"}, "Landscaper")
	await get_tree().create_timer(2.0).timeout
	var r: Dictionary = await team.find_brain("Decorator")._take_photo({"view": "player"})
	_out.append("photo: %s" % r.text)
	var img := Image.new()
	img.load_jpg_from_buffer(Marshalls.base64_to_raw(r.image))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/teamtest_photo.jpg"))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/teamtest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
