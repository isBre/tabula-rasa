extends "res://scripts/main.gd"
## Builds a small scene, asks the Architect (real API) to photograph and describe it.
## Writes the chat to res://tests/visiontest_output.txt and a photo to res://tests/visiontest_photo.jpg.

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	team.load_api_key()
	World.chat_message.connect(func(a, t): _out.append("%s: %s" % [a, t]))
	World.spawn_primitive({"shape": "box", "position": [0, 1, -4], "size": [2, 2, 2], "color": "#e63946", "name": "cube"}, "player")
	World.spawn_primitive({"shape": "sphere", "position": [3, 1, -4], "size": [2, 2, 2], "color": "#2a9d8f", "name": "ball"}, "player")
	World.spawn_primitive({"shape": "cone", "position": [-3, 1.5, -4], "size": [2, 3, 2], "color": "#f4a261", "name": "cone"}, "player")
	await get_tree().create_timer(1.0).timeout
	var img: Image = await team.photographer.capture(Vector3(0, 4, 4), Vector3(0, 1, -4))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/visiontest_photo.jpg"))
	team.find_brain("Architect").queue_event("[Technical test] The player put three objects in front of them. Without reading their names, take a photo with take_photo (look_at [0,1,-4], position [0,4,4]) and describe with say the shapes and colors you see, from left to right.")
	await get_tree().create_timer(40.0).timeout
	var f := FileAccess.open("res://tests/visiontest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
