extends "res://scripts/main.gd"
## Real API: asks the Architect to build a small tower with stairs and review it.
## Writes the chat to res://tests/reviewtest_output.txt.

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
	team.find_brain("Architect").queue_event("[The player tells you]: build on your own (without delegating) a small wooden house with a gable roof, a door, two windows, a small fenced garden with a tree and a path leading to the door, in front of me. Then check that it is well made.")
	for i in 16:
		await get_tree().create_timer(10.0).timeout
		_flush()
		if not team.find_brain("Architect").busy and i > 1:
			break
	var img: Image = await team.photographer.capture(World.player.global_position + Vector3(4, 6, 6), World.player.global_position + Vector3(0, 0, -10), World.agents.values())
	img.save_jpg(ProjectSettings.globalize_path("res://tests/reviewtest_photo.jpg"))
	_out.append("=== FINE ===")
	_flush()
	relaunching = true
	get_tree().quit()


func _flush() -> void:
	var f := FileAccess.open("res://tests/reviewtest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
