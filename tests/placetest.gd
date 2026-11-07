extends "res://scripts/main.gd"
## Offline: normalized models, placement check, placement helpers, plan view.
## Output: res://tests/placetest_output.txt + placetest_plan.jpg + placetest_room.jpg

var _out := PackedStringArray()

const ROOM := """extends Node3D
func _ready():
	add_child(Shapes.box(Vector3(8, 0.1, 6), "legno_chiaro"))
	for w in [[8.0, Vector3(0, 0.1, -3), 0.0], [8.0, Vector3(0, 0.1, 3), 0.0], [6.0, Vector3(-4, 0.1, 0), PI / 2], [6.0, Vector3(4, 0.1, 0), PI / 2]]:
		var wall := Shapes.wall(w[0], 2.6, 0.2, [], "intonaco")
		wall.position = w[1]
		wall.rotation.y = w[2]
		add_child(wall)
"""

const FURNITURE_WITH_MISTAKES := """extends Node3D
func put(id, p, yaw := 0.0):
	var n := Assets.instance(id, true)
	n.scale = Vector3.ONE * 0.8
	n.position = p
	n.rotation.y = yaw
	add_child(n)
	return n
func _ready():
	put("kaykit_furniture/couch_pillows", Vector3(0, 0.1, 1.5), PI)
	put("kaykit_furniture/armchair_pillows", Vector3(0.9, 0.1, 1.2), 0.0)
	put("kaykit_furniture/cabinet_medium", Vector3(-3.95, 0.1, 0), PI / 2)
	put("kaykit_furniture/lamp_standing", Vector3(2.5, 0.8, -1.5))
"""


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	player.global_position = Vector3(0, 0.2, 9)
	env.set_values({"time_of_day": 13.0, "ground": "prato"})
	await get_tree().create_timer(0.3).timeout
	var b = team.find_brain("Decoratore")
	var room: Dictionary = await b._exec_tool("run_script", {"code": ROOM, "position": [0, 0, 0], "name": "stanza"})
	_out.append("ROOM: " + room.text)
	var furn: Dictionary = await b._exec_tool("run_script", {"code": FURNITURE_WITH_MISTAKES, "position": [0, 0, 0], "name": "arredi sbagliati"})
	_out.append("FURNITURE: " + furn.text)
	var furn_id: String = furn.text.get_slice(" ", 1)

	# helpers: a bookcase pushed against the nearest wall, a chair facing the player, snapping on the floor
	var shelf: Dictionary = await b._exec_tool("spawn_asset", {"asset": "kaykit_furniture/shelf_B_large_decorated", "position": [-2, 3, -2.2], "height": 2.0, "against_wall": true})
	_out.append("SHELF: " + shelf.text)
	var chair: Dictionary = await b._exec_tool("spawn_asset", {"asset": "kaykit_furniture/chair_A", "position": [2, 1.5, 0.5], "height": 0.95, "facing": "player"})
	_out.append("CHAIR: " + chair.text)

	var plan: Dictionary = await b._exec_tool("plan_view", {"id": furn_id})
	_out.append("PLAN: " + plan.text)
	var img := Image.new()
	img.load_jpg_from_buffer(Marshalls.base64_to_raw(plan.image))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/placetest_plan.jpg"))
	var area: Dictionary = await b._exec_tool("plan_view", {"center": [0, 0, 0], "size": 14})
	img.load_jpg_from_buffer(Marshalls.base64_to_raw(area.image))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/placetest_area.jpg"))
	var shot: Image = await team.photographer.capture(Vector3(5, 5, 7), Vector3(0, 0.5, 0), World.agents.values() + [player.avatar])
	shot.save_jpg(ProjectSettings.globalize_path("res://tests/placetest_room.jpg"))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/placetest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
