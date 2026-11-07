extends "res://scripts/main.gd"
## Real API: asks the Sculptor to design two models in the workshop and save them.
## Output: res://tests/sculptortest_output.txt + sculptortest_library.jpg + the lab views.

var _out := PackedStringArray()
var _shot := 0


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	team.load_api_key()
	World.chat_message.connect(func(a, t): _out.append("%s: %s" % [a, t]))
	var s = team.find_brain("Sculptor")
	s.status_changed.connect(func(t): if t != "": _out.append("  [%s]" % t))
	s.queue_event("[The player tells you]: model a three-seat sofa in blue fabric with armrests and cushions, and a cream retro fridge with chrome handles. Save both in the library.")
	for i in 30:
		await get_tree().create_timer(8.0).timeout
		_flush()
		if not s.busy and i > 1:
			break
	_out.append("LIBRARY:\n" + Assets.index_text())
	if not Assets.catalog.is_empty():
		var img: Image = await Assets.preview(Assets.catalog.map(func(e): return e.id))
		img.save_jpg(ProjectSettings.globalize_path("res://tests/sculptortest_library.jpg"))
	_out.append("=== FINE ===")
	_flush()
	relaunching = true
	get_tree().quit()


func _flush() -> void:
	var f := FileAccess.open("res://tests/sculptortest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
