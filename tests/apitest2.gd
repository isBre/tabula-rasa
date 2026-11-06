extends "res://scripts/main.gd"
## Real API: environment + blueprint workflow, then history and costs.
## Output: res://tests/apitest2_output.txt and apitest2_photo.jpg

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
	player.global_position = Vector3(0, 0.1, 6)
	player.rotation = Vector3.ZERO
	World.chat_message.connect(func(a, t): _out.append("%s: %s" % [a, t]))
	team.find_brain("Architetto").queue_event("[Il giocatore ti dice]: fai diventare il tramonto (ore 19) su un prato. Poi crea un lampione low-poly con una luce calda, salvalo come blueprint e piazzane 4 copie in fila lungo un sentiero che parte davanti a me e va verso -Z. Lavora da solo, senza delegare.")
	for i in 16:
		await get_tree().create_timer(10.0).timeout
		_flush()
		if not team.find_brain("Architetto").busy and i > 1:
			break
	var img: Image = await team.photographer.capture(Vector3(5, 4, 8), Vector3(0, 1, -6), World.agents.values())
	img.save_jpg(ProjectSettings.globalize_path("res://tests/apitest2_photo.jpg"))
	_out.append(history.list_text())
	_out.append(team.costs_text())
	_out.append("=== FINE ===")
	_flush()
	relaunching = true
	get_tree().quit()


func _flush() -> void:
	var f := FileAccess.open("res://tests/apitest2_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
