extends "res://scripts/main.gd"
## Offline test of measure / inspect_visual / walk_test / edit_script.
## Writes res://tests/toolstest_output.txt and res://tests/toolstest_sheet.jpg.

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	var arch = team.find_brain("Architetto")
	await get_tree().create_timer(0.5).timeout

	# stairs: 6 steps of 0.25 m up to a 1.5 m platform
	var stairs := """extends Node3D
func _ready():
	for i in 6:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2, 0.25 * (i + 1), 0.5)
		cs.shape = box
		body.add_child(cs)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		mi.mesh = bm
		body.add_child(mi)
		body.position = Vector3(0, 0.125 * (i + 1), -0.5 * i)
		add_child(body)
	var top := StaticBody3D.new()
	var tcs := CollisionShape3D.new()
	var tb := BoxShape3D.new()
	tb.size = Vector3(4, 1.5, 4)
	tcs.shape = tb
	top.add_child(tcs)
	var tmi := MeshInstance3D.new()
	var tbm := BoxMesh.new()
	tbm.size = tb.size
	tmi.mesh = tbm
	top.add_child(tmi)
	top.position = Vector3(0, 0.75, -4.75)
	add_child(top)
"""
	var stairs_id := _t("stairs", World.run_script({"code": stairs, "position": [0, 0, -2], "name": "scala"}, "Architetto"))
	var wall_id := _t("wall", World.spawn_primitive({"shape": "box", "position": [10, 1.5, -5], "size": [6, 3, 0.5], "color": "#888888", "name": "muro"}, "Architetto"))
	var ball_id := _t("floating ball", World.spawn_primitive({"shape": "sphere", "position": [-6, 2, -4], "size": [1, 1, 1], "color": "#ff00ff", "name": "palla", "physics": "none"}, "Decoratore"))
	_t("overlap box", World.spawn_primitive({"shape": "box", "position": [-6, 1.8, -4], "size": [1, 1, 1], "name": "cubo sovrapposto"}, "Decoratore"))
	await get_tree().physics_frame
	await get_tree().physics_frame

	_t("measure stairs", World.measure({"id": stairs_id}))
	_t("measure ball", World.measure({"id": ball_id}))
	_t("walk stairs", await arch._walk_test({"from": [0, 0, 1], "to": [0, 1.5, -7]}))
	_t("walk into wall", await arch._walk_test({"from": [10, 0, 0], "to": [10, 0, -10]}))
	_t("walk around wall", await arch._walk_test({"from": [10, 0, 0], "via": [[14, 0, -2], [14, 0, -8]], "to": [10, 0, -10]}))

	var sheet_r: Dictionary = await arch._inspect_visual({"id": stairs_id})
	_out.append("[inspect_visual] ok=%s :: %s (image b64 chars: %d)" % [sheet_r.ok, sheet_r.text.left(80), str(sheet_r.get("image", "")).length()])
	var sheet: Image = await team.photographer.contact_sheet(World.world_aabb(World._get_entity(stairs_id)), World.agents.values())
	sheet.save_jpg(ProjectSettings.globalize_path("res://tests/toolstest_sheet.jpg"))

	var spin_id := _t("spin script", World.run_script({"code": "extends Node3D\nvar speed := 1.0\nfunc _process(d):\n\trotate_y(d * speed)\n", "position": [5, 1, 5], "name": "trottola"}, "Ingegnere"))
	World.attach_script({"id": spin_id, "code": "extends Node\nfunc _ready():\n\tprint('beh ok')\n"}, "Ingegnere")
	_t("edit ok", World.edit_script({"id": spin_id, "old": "var speed := 1.0", "new": "var speed := 4.0"}, "Ingegnere"))
	_t("inspect after edit", World.inspect_object({"id": spin_id}))
	_t("edit not found", World.edit_script({"id": spin_id, "old": "pippo", "new": "x"}, "Ingegnere"))
	_t("edit breaks", World.edit_script({"id": spin_id, "old": "var speed := 4.0", "new": "var speed := = 4"}, "Ingegnere"))
	_t("edit behavior", World.edit_script({"id": spin_id, "target": "behavior", "old": "beh ok", "new": "beh modificato"}, "Ingegnere"))
	_t("edit primitive", World.edit_script({"id": wall_id, "old": "a", "new": "b"}, "Ingegnere"))

	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/toolstest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()


func _t(label: String, r: Dictionary) -> String:
	_out.append("[%s] ok=%s :: %s" % [label, r.get("ok"), str(r.get("text", r))])
	var m := RegEx.create_from_string("obj_\\d+").search(str(r.get("text", "")))
	return m.get_string() if m else ""
