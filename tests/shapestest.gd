extends "res://scripts/main.gd"
## Builds a showcase with the Shapes kit through runtime scripts (like an agent would),
## takes photos and runs walk tests. Output: res://tests/shapestest_output.txt + shapestest_*.jpg

var _out := PackedStringArray()

const COTTAGE := """extends Node3D
func _ready():
	add_child(Shapes.box(Vector3(6.4, 0.2, 5.4), "pietra"))
	var front := Shapes.wall(6, 3, 0.25, [{"x": 0, "y": 0, "w": 1.2, "h": 2.1}, {"x": -1.9, "y": 1.0, "w": 1.0, "h": 1.0}], "intonaco")
	front.position = Vector3(0, 0.2, 2.5)
	add_child(front)
	var back := Shapes.wall(6, 3, 0.25, [{"x": 1.5, "y": 1.0, "w": 1.0, "h": 1.0}], "intonaco")
	back.position = Vector3(0, 0.2, -2.5)
	add_child(back)
	for side in [-1, 1]:
		var w := Shapes.wall(5.25, 3, 0.25, [], "intonaco")
		w.position = Vector3(side * 2.875, 0.2, 0)
		w.rotation.y = PI / 2
		add_child(w)
	var r := Shapes.roof("gable", 6, 5.25, 2.0, 0.4, "tetto")
	r.position.y = 3.2
	add_child(r)
	var chimney := Shapes.box(Vector3(0.6, 1.6, 0.6), "mattoni")
	chimney.position = Vector3(1.6, 3.8, -1.0)
	add_child(chimney)
"""

const SHOWCASE := """extends Node3D
func _ready():
	var hills := Shapes.terrain(40, 5, 24, 3)
	hills.position = Vector3(0, 0, -45)
	add_child(hills)
	add_child(Shapes.ribbon([Vector3(0, 0, 8), Vector3(2, 0, 0), Vector3(-1, 0, -8), Vector3(3, 0, -18)], 2.5, 0.06, "sabbia"))
	var forest := Shapes.scatter(func(i): return Shapes.tree(["pine", "round", "birch", "autumn"][i % 4], 4.5, i), 24, Vector2(18, 14), 7, 2.5)
	forest.position = Vector3(-16, 0, -10)
	add_child(forest)
	var vase := Shapes.lathe([Vector2(0, 0), Vector2(0.5, 0), Vector2(0.7, 0.4), Vector2(0.45, 1.1), Vector2(0.55, 1.4), Vector2(0, 1.4)], 10, "mattoni")
	vase.position = Vector3(6, 0, 4)
	add_child(vase)
	var fountain := Shapes.lathe([Vector2(0, 0), Vector2(2.2, 0), Vector2(2.2, 0.6), Vector2(1.9, 0.6), Vector2(1.9, 0.2), Vector2(0, 0.2)], 12, "pietra")
	fountain.position = Vector3(8, 0, -4)
	add_child(fountain)
	var w := Shapes.water(3.6, 3.6)
	w.position = Vector3(8, 0.35, -4)
	add_child(w)
	var col := Shapes.lathe([Vector2(0, 0), Vector2(0.35, 0), Vector2(0.3, 2.2), Vector2(0.4, 2.4), Vector2(0, 2.4)], 8, "intonaco")
	col.position = Vector3(8, 0.2, -4)
	add_child(col)
	var a := Shapes.arch(4, 4.5, 0.6, 0.8, "pietra")
	a.position = Vector3(1, 0, -12)
	add_child(a)
	var st := Shapes.stairs(2, 2, 3.5, 0, "legno")
	st.position = Vector3(12, 0, 6)
	add_child(st)
	var deck := Shapes.box(Vector3(4, 2, 4), "legno_chiaro")
	deck.position = Vector3(12, 0, 1.5)
	add_child(deck)
	add_child(Shapes.fence([Vector3(4, 0, 9), Vector3(10, 0, 9), Vector3(10, 0, 4)], 1.0, 1.5))
	var rocks := Shapes.scatter(func(i): return Shapes.rock(randf_range(0.6, 1.6), i), 8, Vector2(10, 6), 3, 1.5)
	rocks.position = Vector3(-6, 0, 8)
	add_child(rocks)
	var sign := Shapes.text("Tabula Rasa", 0.8, 0.15, "oro")
	sign.position = Vector3(-4, 0.3, 3)
	add_child(sign)
	var pipe := Shapes.tube([Vector3(14, 0.3, -6), Vector3(14, 3, -6), Vector3(17, 3, -6), Vector3(17, 0.3, -9)], 0.15, 8, "metallo")
	add_child(pipe)
	var star := Shapes.extrude([Vector2(0, 1), Vector2(0.25, 0.35), Vector2(0.95, 0.3), Vector2(0.4, -0.1), Vector2(0.6, -0.8), Vector2(0, -0.4), Vector2(-0.6, -0.8), Vector2(-0.4, -0.1), Vector2(-0.95, 0.3), Vector2(-0.25, 0.35)], 0.2, "luce_calda", false, "z")
	star.position = Vector3(1, 5.5, -12)
	add_child(star)
	for i in 4:
		var kinds := ["gable", "hip", "pyramid", "shed"]
		var base := Shapes.box(Vector3(3, 2, 3), "mattoni")
		base.position = Vector3(-12 + i * 4.5, 0, 14)
		add_child(base)
		var r := Shapes.roof(kinds[i], 3, 3.0 + (1.0 if i == 1 else 0.0), 1.4, 0.25, "tegole_blu" if i % 2 else "tetto")
		r.position = Vector3(-12 + i * 4.5, 2, 14)
		add_child(r)
"""


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	await get_tree().create_timer(0.3).timeout
	var c := _t("cottage", World.run_script({"code": COTTAGE, "position": [-6, 0, -1], "name": "casetta"}, "Architetto"))
	_t("showcase", World.run_script({"code": SHOWCASE, "position": [0, 0, 0], "name": "vetrina"}, "Architetto"))
	await get_tree().physics_frame
	await get_tree().physics_frame
	_t("measure cottage", World.measure({"id": c}))
	var arch = team.find_brain("Architetto")
	_t("walk up stairs", await arch._walk_test({"from": [12, 0, 7], "to": [12, 2, 1.5]}))
	_t("walk into cottage door", await arch._walk_test({"from": [-6, 0, 5], "to": [-6, 0.2, -0.5]}))
	_t("walk through arch", await arch._walk_test({"from": [1, 0, -8], "to": [1, 0, -16]}))
	var shots := {
		"overview": [Vector3(0, 16, 26), Vector3(0, 0, -4)],
		"cottage": [Vector3(-1, 3, 8), Vector3(-6, 2, -1)],
		"details": [Vector3(14, 4, 12), Vector3(9, 1, 0)],
		"forest": [Vector3(-6, 5, 4), Vector3(-16, 2, -12)],
	}
	for k in shots:
		var img: Image = await team.photographer.capture(shots[k][0], shots[k][1], World.agents.values())
		img.save_jpg(ProjectSettings.globalize_path("res://tests/shapestest_%s.jpg" % k))
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/shapestest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()


func _t(label: String, r: Dictionary) -> String:
	_out.append("[%s] ok=%s :: %s" % [label, r.get("ok"), str(r.get("text", r))])
	var m := RegEx.create_from_string("obj_\\\\d+").search(str(r.get("text", "")))
	return m.get_string() if m else ""
