extends "res://scripts/main.gd"
## Offline: nodes created outside an object's subtree are removed with it;
## usage log; old code stripped from history. Output: res://tests/orphantest_output.txt

var _out := PackedStringArray()

const LEAKY := """extends Node3D
var hud: Label3D
func _ready():
	hud = Label3D.new()
	hud.text = "PUNTI: 0"
	get_tree().root.add_child(hud)
	var sticker := Label3D.new()
	sticker.text = "sulla camera"
	World.player.camera.add_child(sticker)
	add_child(Shapes.box(Vector3(1, 1, 1), "legno"))
"""


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	await get_tree().create_timer(0.3).timeout
	var root_before := get_tree().root.get_child_count()
	var cam_before: int = player.camera.get_child_count()
	var r := World.run_script({"code": LEAKY, "position": [0, 0, -4], "name": "tabellone"}, "Ingegnere")
	var id: String = r.text.get_slice(" ", 1)
	await get_tree().process_frame
	_out.append("after spawn: root children +%d, camera children +%d, tracked orphans %s" % [get_tree().root.get_child_count() - root_before, player.camera.get_child_count() - cam_before, str(World._orphans.get(id, []).size())])
	World.delete_object({"id": id}, "player")
	await get_tree().process_frame
	await get_tree().process_frame
	_out.append("after delete: root children +%d, camera children +%d" % [get_tree().root.get_child_count() - root_before, player.camera.get_child_count() - cam_before])
	# again, then undo/reset path
	World.run_script({"code": LEAKY, "position": [0, 0, -4], "name": "tabellone"}, "Ingegnere")
	await get_tree().process_frame
	World.reset_world()
	await get_tree().process_frame
	await get_tree().process_frame
	_out.append("after reset: root children +%d, camera children +%d" % [get_tree().root.get_child_count() - root_before, player.camera.get_child_count() - cam_before])

	# usage log
	team.add_usage(team.find_brain("Architetto"), "claude-haiku-5-5", {"input_tokens": 1200, "output_tokens": 300, "cache_read_input_tokens": 9000}, 0)
	var log_text := FileAccess.get_file_as_string("res://logs/usage.csv")
	_out.append("usage.csv last lines:\n" + "\n".join(log_text.strip_edges().split("\n").slice(-2)))

	# old code stripped
	var b = team.find_brain("Decoratore")
	b.messages = [
		{"role": "user", "content": [{"type": "text", "text": "fai una panchina"}]},
		{"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "run_script", "input": {"code": "extends Node3D\n" + "# riga di codice\n".repeat(40), "name": "panchina", "position": [0, 0, 0]}}]},
		{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "Creato obj_9"}]},
	]
	b._strip_old_states()
	_out.append("old code after strip: " + str(b.messages[1]["content"][0]["input"]["code"]))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/orphantest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
