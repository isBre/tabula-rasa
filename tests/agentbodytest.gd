extends "res://scripts/main.gd"
## Offline: the agents' human bodies walk to work, point, come to talk, move the mouth.
## Output: res://tests/agentbodytest_output.txt + agentbodytest_*.jpg

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
	player.global_position = Vector3(0, 0.1, 8)
	player.rotation = Vector3.ZERO
	player.head.rotation = Vector3.ZERO
	env.set_values({"time_of_day": 15.0, "ground": "prato"})
	await get_tree().create_timer(2.0).timeout
	var shot1: Image = await team.photographer.capture(Vector3(0, 2.2, 13), Vector3(0, 1.0, 2), [player.avatar])
	_save(shot1, "team")

	var arch = team.find_brain("Architetto")
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = await arch._exec_tool("spawn_asset", {"asset": "kaykit_medieval/building_tavern_red", "position": [10, 0, -10], "height": 5})
	_out.append("spawn after walking %.1f s: %s; Architetto at %s" % [(Time.get_ticks_msec() - t0) / 1000.0, r.text.left(60), World._v(arch.body.global_position)])
	await get_tree().create_timer(0.3).timeout
	var shot2: Image = await team.photographer.capture(Vector3(16, 3, -2), Vector3(9, 1.5, -9), [player.avatar])
	_save(shot2, "work")

	t0 = Time.get_ticks_msec()
	var s: Dictionary = await arch._exec_tool("say", {"text": "Ecco la taverna! Ti piace il tetto rosso?"})
	_out.append("say after %.1f s: %s; distance from player %.1f m, talking %s" % [(Time.get_ticks_msec() - t0) / 1000.0, s.text, arch.body.global_position.distance_to(player.global_position), arch.body._talk_until > Time.get_ticks_msec() / 1000.0])
	await get_tree().create_timer(0.25).timeout
	var shot3: Image = await team.photographer.capture(player.camera.global_position + Vector3(0.3, 0, 0), arch.body.global_position + Vector3.UP * 1.6, [player.avatar])
	_save(shot3, "talk")
	_out.append("mouth scale while talking: %.2f" % arch.body.avatar.mouth.scale.y)

	var d = team.find_brain("Decoratore")
	await d._exec_tool("say", {"text": "Metto due lanterne?", "to": "Architetto"})
	_out.append("Decoratore → Architetto: distance %.1f m" % d.body.global_position.distance_to(arch.body.global_position))
	await d._exec_tool("spawn_asset", {"asset": "kaykit_medieval/flag_red", "position": [10, 6, -10], "height": 1.5})
	_out.append("high work: Decoratore at %s (flying %s)" % [World._v(d.body.global_position), d.body._flying])
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/agentbodytest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()


func _save(img: Image, n: String) -> void:
	img.save_jpg(ProjectSettings.globalize_path("res://tests/agentbodytest_%s.jpg" % n))
