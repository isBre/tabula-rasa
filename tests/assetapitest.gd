extends "res://scripts/main.gd"
## Real API: the Architect builds a village corner with the model library.
## Output: res://tests/assetapitest_output.txt + assetapitest_photo.jpg

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	history.reset("test")
	team.autonomy = false
	team.load_api_key()
	team.set_follow(false)
	player.set_process_unhandled_input(false)
	player.global_position = Vector3(0, 0.1, 10)
	player.rotation = Vector3.ZERO
	env.set_values({"time_of_day": 16.0, "ground": "prato"})
	World.chat_message.connect(func(a, t): _out.append("%s: %s" % [a, t]))
	team.find_brain("Architetto").queue_event("[Il giocatore ti dice]: costruisci da solo, senza delegare, un angolo di villaggio medievale davanti a me: tre o quattro case, una taverna, un pozzo al centro di una piazzetta, qualche bancarella del mercato con merci, barili e casse, e alberi intorno. Usa la libreria di modelli.")
	for i in 20:
		await get_tree().create_timer(10.0).timeout
		_flush()
		if not team.find_brain("Architetto").busy and i > 1:
			break
	var img: Image = await team.photographer.capture(Vector3(12, 10, 14), Vector3(0, 0, -6), World.agents.values() + [player.avatar])
	img.save_jpg(ProjectSettings.globalize_path("res://tests/assetapitest_photo.jpg"))
	var img2: Image = await team.photographer.capture(Vector3(-3, 2.2, 6), Vector3(0, 1.5, -6), World.agents.values() + [player.avatar])
	img2.save_jpg(ProjectSettings.globalize_path("res://tests/assetapitest_photo2.jpg"))
	_out.append(team.costs_text())
	_out.append("=== FINE ===")
	_flush()
	relaunching = true
	get_tree().quit()


func _flush() -> void:
	var f := FileAccess.open("res://tests/assetapitest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
