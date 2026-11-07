extends "res://scripts/main.gd"
## Offline: furnishes a room turned by 30 degrees using only anchors (no coordinates).
## Output: res://tests/anchortest_output.txt + anchortest_plan.jpg + anchortest_room.jpg

var _out := PackedStringArray()
var b

const ROOM := """extends Node3D
func _ready():
	var floor_node := Shapes.box(Vector3(8, 0.1, 6), "light_wood")
	floor_node.name = "camera"
	add_child(floor_node)
	for w in [[8.0, Vector3(0, 0.1, -3), 0.0], [8.0, Vector3(0, 0.1, 3), 0.0], [6.0, Vector3(-4, 0.1, 0), PI / 2], [6.0, Vector3(4, 0.1, 0), PI / 2]]:
		var wall := Shapes.wall(w[0], 2.6, 0.2, [], "plaster")
		wall.position = w[1]
		wall.rotation.y = w[2]
		add_child(wall)
"""

const SHELF := """extends Node3D
func _ready():
	var a := Shapes.box(Vector3(1, 1.2, 0.4), "wood")
	add_child(a)
	var c := Shapes.box(Vector3(0.6, 0.8, 0.4), "light_wood")
	add_child(c)
	World.place(c, {"to": a, "side": "right"})
	var d := Shapes.box(Vector3(0.3, 0.3, 0.3), "gold")
	add_child(d)
	World.place(d, {"to": a, "side": "top"})
"""


func _id(r: Dictionary) -> String:
	var m := RegEx.create_from_string("obj_\\d+").search(str(r.text))
	return m.get_string() if m else ""


func _do(label: String, tool: String, input: Dictionary) -> String:
	var r: Dictionary = await b._exec_tool(tool, input)
	_out.append("%s [%s] %s" % [label, "OK" if r.ok else "ERR", r.text])
	return _id(r)


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	player.global_position = Vector3(0, 0.2, 12)
	env.set_values({"time_of_day": 13.0, "ground": "grass"})
	await get_tree().create_timer(0.3).timeout
	b = team.find_brain("Decorator")
	var room := await _do("ROOM", "run_script", {"code": ROOM, "position": [0, 0, 0], "rotation_deg": [0, 30, 0], "name": "room"})
	var cam := room + "/camera"
	var bed := await _do("BED", "spawn_asset", {"asset": "kaykit_furniture/bed_double_A", "height": 0.75, "anchor": {"to": cam, "wall": "back"}})
	var n1 := await _do("NIGHT L", "spawn_asset", {"asset": "kaykit_furniture/cabinet_small", "height": 0.6, "anchor": {"to": bed, "side": "left", "align": "back"}})
	await _do("NIGHT R", "spawn_asset", {"asset": "kaykit_furniture/cabinet_small", "height": 0.6, "anchor": {"to": bed, "side": "right", "align": "back"}})
	await _do("LAMP", "spawn_asset", {"asset": "kaykit_furniture/lamp_table", "height": 0.5, "anchor": {"to": n1, "side": "top"}})
	await _do("COUCH", "spawn_asset", {"asset": "kaykit_furniture/couch_pillows", "height": 0.9, "anchor": {"to": cam, "wall": ["front", "left"]}})
	var table := await _do("TABLE", "spawn_asset", {"asset": "kaykit_furniture/table_medium", "height": 0.75, "anchor": {"to": cam, "side": "inside", "offset": [-1.8, 0, 0.6]}})
	await _do("CHAIR F", "spawn_asset", {"asset": "kaykit_furniture/chair_A", "height": 0.95, "anchor": {"to": table, "side": "front", "gap": 0.1}})
	var c2 := await _do("CHAIR B", "spawn_asset", {"asset": "kaykit_furniture/chair_A", "height": 0.95, "anchor": {"to": table, "side": "back", "gap": 0.1}})
	await _do("PLACE chair->left of table", "place", {"id": c2, "anchor": {"to": table, "side": "left", "gap": 0.1, "face": "toward"}})
	await _do("CABINET east wall", "spawn_asset", {"asset": "kaykit_furniture/cabinet_medium", "height": 1.0, "anchor": {"to": cam, "wall": "east"}})
	await _do("SCRIPT east of room", "run_script", {"code": SHELF, "name": "shelf", "anchor": {"to": room, "side": "east", "gap": 2}})
	await _do("PRIMITIVE north of room", "spawn_primitive", {"shape": "box", "size": [1, 1, 1], "color": "#cc4444", "anchor": {"to": room, "side": "north", "gap": 1}})
	await _do("ERR side", "spawn_asset", {"asset": "kaykit_furniture/chair_A", "anchor": {"to": table, "side": "sideways"}})
	await _do("ERR target", "spawn_asset", {"asset": "kaykit_furniture/chair_A", "anchor": {"to": "obj_999"}})

	var plan: Dictionary = await b._exec_tool("plan_view", {"center": [1, 0, 0], "size": 16})
	var img := Image.new()
	img.load_jpg_from_buffer(Marshalls.base64_to_raw(plan.image))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/anchortest_plan.jpg"))
	var shot: Image = await team.photographer.capture(Vector3(6, 7, 8), Vector3(0, 0.5, 0), World.agents.values() + [player.avatar])
	shot.save_jpg(ProjectSettings.globalize_path("res://tests/anchortest_room.jpg"))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/anchortest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
