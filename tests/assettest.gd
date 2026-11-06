extends "res://scripts/main.gd"
## Offline test of the model library. Output: res://tests/assettest_output.txt,
## assettest_preview.jpg, assettest_village.jpg

var _out := PackedStringArray()

const VILLAGE := """extends Node3D
func _ready():
	var houses := ["kaykit_medieval/building_home_A_blue", "kaykit_medieval/building_home_B_red", "kaykit_medieval/building_tavern_yellow", "kaykit_medieval/building_blacksmith_green", "kaykit_medieval/building_well_blue"]
	var spots := [Vector3(-7, 0, -4), Vector3(7, 0, -4), Vector3(-7, 0, 6), Vector3(7, 0, 6), Vector3(0, 0, 1)]
	for i in houses.size():
		var h := Assets.instance(houses[i], true)
		var native: Vector3 = Assets.info(houses[i]).size
		h.scale = Vector3.ONE * (5.0 if i < 4 else 2.0) / native.y
		h.position = spots[i]
		h.rotation.y = PI if spots[i].z < 0 else 0.0
		add_child(h)
	var forest := Shapes.scatter(func(i):
		var t := Assets.instance(["kaykit_medieval/tree_single_A", "kaykit_medieval/tree_single_B"][i % 2], true)
		t.scale = Vector3.ONE * randf_range(4.5, 6.5) / 1.2
		return t, 18, Vector2(30, 8), 4, 3.0)
	forest.position = Vector3(0, 0, -16)
	add_child(forest)
	for x in [-3.0, 3.0]:
		var bench := Assets.instance("kaykit_furniture/bench", true) if Assets.has("kaykit_furniture/bench") else Node3D.new()
		bench.position = Vector3(x, 0, 1)
		add_child(bench)
"""


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	team.set_follow(false)
	player.set_process_unhandled_input(false)
	for b in team.brains:
		b.body.position = Vector3(40, 2, 40)
	await get_tree().create_timer(0.3).timeout
	_out.append("catalog: %d models" % Assets.catalog.size())
	_out.append("packs: " + Assets.packs_summary())
	for q in ["chair", "panchina", "albero", "casa", "barrel", "lampione", "car"]:
		_out.append("search '%s': %s" % [q, ", ".join(PackedStringArray(Assets.search(q, 6).map(func(e): return Assets.describe_entry(e))))])
	var b = team.find_brain("Decoratore")
	var r: Dictionary = b._exec_tool("search_assets", {"query": "table"})
	_out.append("tool search: " + r.text.left(300))
	var ids := Assets.search("chair", 4).map(func(e): return e.id) + Assets.search("tree", 3).map(func(e): return e.id) + Assets.search("house", 2).map(func(e): return e.id)
	var pr: Dictionary = await b._exec_tool("preview_assets", {"ids": ids})
	_out.append("preview: " + pr.text)
	var img := Image.new()
	img.load_jpg_from_buffer(Marshalls.base64_to_raw(pr.image))
	img.save_jpg(ProjectSettings.globalize_path("res://tests/assettest_preview.jpg"))

	var s1 := World.spawn_asset({"asset": "kaykit_furniture/chair_A", "position": [2, 0, -3], "height": 0.95}, "Decoratore")
	_out.append("spawn chair: " + s1.text)
	var s2 := World.spawn_asset({"asset": "kaykit_furniture/sedia_rossa", "position": [0, 0, 0]}, "Decoratore")
	_out.append("spawn wrong id: " + s2.text)
	var chair_id: String = s1.text.get_slice(" ", 1)
	_out.append("measure: " + World.measure({"id": chair_id}).text.get_slice("\n", 1))
	var v := World.run_script({"code": VILLAGE, "position": [0, 0, -12], "name": "villaggio medievale"}, "Architetto")
	_out.append("village script: " + v.text)
	await get_tree().create_timer(0.5).timeout
	# save/load round trip keeps the asset
	var data := World.serialize()
	World.deserialize(data)
	await get_tree().process_frame
	_out.append("after reload: %d objects, chair kind=%s asset=%s" % [World.entities.size(), World._get_entity(chair_id).get_meta("kind"), World._get_entity(chair_id).get_meta("asset")])
	_out.append("describe line: " + str(Array(World.describe("Critico").split("\n")).filter(func(l): return l.contains("modello=")).front()))
	env.set_values({"time_of_day": 16.0})
	await get_tree().create_timer(0.3).timeout
	var shot: Image = await team.photographer.capture(Vector3(14, 9, 8), Vector3(0, 1, -12), World.agents.values())
	shot.save_jpg(ProjectSettings.globalize_path("res://tests/assettest_village.jpg"))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/assettest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
