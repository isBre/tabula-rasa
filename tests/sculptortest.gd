extends "res://scripts/main.gd"
## Real API: asks the Scultore to design two models in the workshop and save them.
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
	var s = team.find_brain("Scultore")
	s.status_changed.connect(func(t): if t != "": _out.append("  [%s]" % t))
	s.queue_event("[Il giocatore ti dice]: modella un divano a tre posti in tessuto blu con braccioli e cuscini, e un frigorifero retrò color crema con le maniglie cromate. Salvali entrambi nella libreria.")
	for i in 30:
		await get_tree().create_timer(8.0).timeout
		_flush()
		if not s.busy and i > 1:
			break
	_out.append("LIBRERIA:\n" + Assets.index_text())
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
