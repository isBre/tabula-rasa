extends "res://scripts/main.gd"
## Offline: the modeling workshop. Designs, saves and places models made only of recipes.
## Output: res://tests/modeltest_output.txt + modeltest_*.jpg. Uses res://models/test_*.json
## and deletes them at the end.

var _out := PackedStringArray()
var b

const CHAIR := {"parts": [
	{"id": "leg", "shape": "box", "size": [0.05, 0.45, 0.05], "mat": "wood", "positions": [[0.2, 0, 0.2], [0.2, 0, -0.2]], "mirror": "x"},
	{"id": "seat", "shape": "box", "size": [0.5, 0.05, 0.5], "mat": "light_wood", "position": [0, 0.45, 0]},
	{"id": "backrest", "shape": "box", "size": [0.5, 0.45, 0.05], "mat": "wood", "anchor": {"to": "seat", "side": "top", "align": "back"}},
]}

const FRIDGE := {"parts": [
	{"id": "body", "shape": "box", "size": [0.7, 1.8, 0.65], "mat": "#e8eef0"},
	{"id": "upper_door", "shape": "box", "size": [0.68, 0.55, 0.05], "mat": "#f4f8f9", "anchor": {"to": "body", "side": "front", "gap": 0, "offset": [0, 1.22, 0]}},
	{"id": "lower_door", "shape": "box", "size": [0.68, 1.15, 0.05], "mat": "#f4f8f9", "anchor": {"to": "body", "side": "front", "gap": 0, "offset": [0, 0.03, 0]}},
	{"id": "handle", "shape": "box", "size": [0.04, 0.4, 0.04], "mat": "metal", "positions": [[-0.28, 1.1, 0.37], [-0.28, 1.35, 0.37]]},
	{"id": "feet", "shape": "cylinder", "radius": 0.03, "height": 0.03, "mat": "dark_iron", "positions": [[0.3, -0.03, 0.28], [0.3, -0.03, -0.28]], "mirror": "x"},
]}

const LAMP := {"parts": [
	{"id": "base", "shape": "cylinder", "radius": 0.18, "height": 0.04, "sides": 10, "mat": "dark_iron"},
	{"id": "stem", "shape": "cylinder", "radius": 0.02, "height": 1.4, "mat": "dark_iron", "anchor": {"to": "base", "side": "top"}},
	{"id": "shade", "shape": "lathe", "profile": [[0.12, 0], [0.22, 0], [0.14, 0.3], [0.1, 0.3]], "sides": 10, "mat": "warm_light", "anchor": {"to": "stem", "side": "top", "offset": [0, -0.2, 0]}},
	{"id": "light", "shape": "light", "position": [0, 1.35, 0], "energy": 1.2, "range": 5},
]}

const FACADE := {"parts": [
	{"id": "wall", "shape": "wall", "width": 4, "height": 3, "thickness": 0.25, "mat": "plaster", "openings": [{"x": 0, "y": 0, "w": 1.0, "h": 2.1}, {"x": -1.3, "y": 1.0, "w": 0.8, "h": 0.9}, {"x": 1.3, "y": 1.0, "w": 0.8, "h": 0.9}]},
	{"id": "roof", "shape": "roof", "kind": "gable", "width": 4.4, "depth": 1.2, "height": 1.0, "anchor": {"to": "wall", "side": "top"}},
	{"id": "sign", "shape": "text", "text": "BAR", "size": 0.4, "mat": "gold", "position": [0, 2.3, 0.15]},
	{"id": "stone", "shape": "rock", "size": 0.4, "position": [3, 0, 2]},
]}

const SET := {"parts": [
	{"id": "table", "shape": "box", "size": [1.2, 0.05, 0.8], "mat": "wood", "position": [0, 0.72, 0]},
	{"id": "legs", "shape": "box", "size": [0.06, 0.72, 0.06], "mat": "wood", "positions": [[0.55, 0, 0.35]], "mirror": "xz"},
	{"id": "chair", "shape": "model", "model": "test_chair", "position": [0, 0, 0.75], "rotation": [0, 180, 0]},
	{"id": "chair2", "shape": "model", "model": "test_chair", "position": [0, 0, -0.75]},
]}

const BROKEN := {"parts": [
	{"id": "a", "shape": "boxx", "size": [1, 1, 1]},
	{"id": "b", "shape": "box", "anchor": {"to": "none", "side": "top"}},
]}


func _say(label: String, r: Dictionary) -> void:
	_out.append("%s [%s] %s" % [label, "OK" if r.ok else "ERR", str(r.text)])


func _design(label: String, rec: Dictionary, save_as := "", desc := "") -> void:
	var r: Dictionary = await b._exec_tool("design_model", rec)
	_say("DESIGN " + label, r)
	if r.ok and r.has("image"):
		var img := Image.new()
		img.load_jpg_from_buffer(Marshalls.base64_to_raw(r.image))
		img.save_jpg(ProjectSettings.globalize_path("res://tests/modeltest_%s.jpg" % label))
	if r.ok and save_as != "":
		_say("SAVE " + label, await b._exec_tool("save_model", {"name": save_as, "description": desc}))


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	player.global_position = Vector3(0, 0.2, 9)
	env.set_values({"time_of_day": 13.0, "ground": "grass"})
	await get_tree().create_timer(0.3).timeout
	b = team.find_brain("Sculptor")
	if b == null:
		b = team.find_brain("Decorator")
	_out.append("agent: " + str(b.agent_name))
	await _design("chair", CHAIR, "test_chair", "simple wooden chair")
	await _design("fridge", FRIDGE, "test_fridge", "white two-door fridge")
	await _design("lamp", LAMP, "test_lamp", "floor lamp with a warm shade")
	await _design("facade", FACADE)
	await _design("set", SET, "test_set", "table with two chairs")
	await _design("broken", BROKEN)
	_say("SAVE without design", await b._exec_tool("save_model", {"name": "x", "description": ""}))
	_say("SEARCH", await b._exec_tool("search_assets", {"queries": ["chair", "refrigerator", "lamp", "sofa"]}))
	_out.append("INDEX:\n" + Assets.index_text())
	# into the world, with anchors
	var t: Dictionary = await b._exec_tool("spawn_asset", {"asset": "test_set", "position": [0, 0, 0]})
	_say("SPAWN set", t)
	var set_id := RegEx.create_from_string("obj_\\d+").search(str(t.text)).get_string()
	_say("SPAWN fridge", await b._exec_tool("spawn_asset", {"asset": "test_fridge", "anchor": {"to": set_id, "side": "east", "gap": 1.0, "face": "west"}}))
	_say("SPAWN lamp", await b._exec_tool("spawn_asset", {"asset": "test_lamp", "anchor": {"to": set_id, "side": "west", "gap": 0.6}}))
	# new version of the chair: copies inside the world update
	var chair2: Dictionary = CHAIR.duplicate(true)
	chair2.parts[1]["mat"] = "red_fabric"
	await b._exec_tool("design_model", chair2)
	_say("RESAVE chair", await b._exec_tool("save_model", {"name": "test_chair", "description": "wooden chair with a red seat"}))
	_say("GET", await b._exec_tool("get_model", {"name": "test_chair"}))
	await get_tree().process_frame
	var se = World._get_entity(set_id)
	for c in se.get_children():
		var extra := ""
		if c is MeshInstance3D:
			extra = " surfaces=%d aabb=%s" % [c.mesh.get_surface_count(), c.mesh.get_aabb()]
		_out.append("SET CHILD %s %s%s" % [c.name, c.get_class(), extra])
	_out.append("SET built size: %s" % Assets.info("test_set").size)
	await get_tree().create_timer(0.3).timeout
	var shot: Image = await team.photographer.capture(Vector3(3.5, 2.6, 4.5), Vector3(0, 0.6, 0), World.agents.values() + [player.avatar])
	shot.save_jpg(ProjectSettings.globalize_path("res://tests/modeltest_world.jpg"))
	for f in DirAccess.get_files_at("res://models/"):
		if f.begins_with("test_"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("res://models/" + f))
	_out.append("=== DONE ===")
	var fo := FileAccess.open("res://tests/modeltest_output.txt", FileAccess.WRITE)
	fo.store_string("\n".join(_out))
	fo.close()
	relaunching = true
	get_tree().quit()
