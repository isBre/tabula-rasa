extends "res://scripts/main.gd"
## Offline test of history/undo, environment, blueprints, build mode, costs, save/load.
## Output: res://tests/featuretest_output.txt + featuretest_day.jpg / featuretest_night.jpg

const ShapesTest := preload("res://tests/shapestest.gd")

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	history.reset("test")
	team.autonomy = false
	await get_tree().create_timer(0.3).timeout

	# --- history / undo
	var r := World.run_script({"code": ShapesTest.COTTAGE, "position": [0, 0, -8], "name": "cottage"}, "Architect")
	var cottage: String = r.text.get_slice(" ", 1)
	history.commit("Architect", "run_script " + cottage)
	World.spawn_primitive({"shape": "box", "position": [4, 0.5, -4], "name": "crate"}, "Decorator")
	history.commit("Decorator", "spawn crate")
	_out.append("objects before undo: %d" % World.entities.size())
	_out.append(history.undo())
	_out.append("objects after undo: %d (cottage still there: %s)" % [World.entities.size(), World._get_entity(cottage) != null])
	_out.append(history.list_text())

	# --- environment
	_log("env night", env.set_values({"time_of_day": 22, "ground": "grass", "fog": 0.2}))
	await get_tree().process_frame
	var night: Image = await team.photographer.capture(Vector3(6, 4, 2), Vector3(0, 1.5, -8))
	night.save_jpg(ProjectSettings.globalize_path("res://tests/featuretest_night.jpg"))
	_log("env day", env.set_values({"time_of_day": 11, "cycle_minutes": 0}))
	_log("env bad ground", env.set_values({"ground": "lava"}))
	await get_tree().process_frame
	var day: Image = await team.photographer.capture(Vector3(-5, 4, -18), Vector3(0, 1.5, -8))
	day.save_jpg(ProjectSettings.globalize_path("res://tests/featuretest_day.jpg"))
	_out.append("describe env: " + env.describe())

	# --- blueprints
	_log("save blueprint", World.save_blueprint({"id": cottage, "name": "Plastered cottage", "description": "cottage with a door, two windows, a gable roof and a chimney"}, "Architect"))
	_log("spawn blueprint", World.spawn_blueprint({"name": "plastered_cottage", "position": [10, 0, -8], "rotation_deg": [0, 90, 0]}, "Decorator"))
	_log("spawn missing", World.spawn_blueprint({"name": "castle", "position": [0, 0, 0]}, "Decorator"))
	_out.append("blueprints: " + str(World.list_blueprints().map(func(b): return b.name)))
	_out.append("describe has blueprints: %s" % World.describe("Architect").contains("Available blueprints: plastered_cottage"))

	# --- build mode (programmatic)
	build.toggle()
	build.selected_id = cottage
	build._rotate(15)
	build._rotate(15)
	build._scale(1.1)
	build._duplicate()
	var dup: String = build.selected_id
	build._drop(true)
	_out.append("build: selected after duplicate %s, grabbed=%s, rotation of original %.0f°" % [dup, build.grabbed, World._get_entity(cottage).rotation_degrees.y])
	build.selected_id = dup
	build._delete()
	_out.append("after delete dup exists: %s" % (World._get_entity(dup) != null))
	_out.append(history.list_text())
	_out.append(history.restore(history.commits[0].n))
	_out.append("after restore to first: %d objects" % World.entities.size())

	# --- costs
	team.set_budget(0.001, false)
	team.add_usage(team.find_brain("Architect"), "claude-haiku-5-5", {"input_tokens": 3000, "output_tokens": 800, "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 20000}, 1)
	team.add_usage(team.find_brain("Engineer"), "claude-sonnet-5-5", {"input_tokens": 1000, "output_tokens": 500}, 0)
	_out.append(team.costs_text())
	_out.append("over budget: %s, autonomy: %s" % [team.over_budget(), team.autonomy])

	# --- save / load with environment
	env.set_values({"time_of_day": 18.5, "ground": "sand"})
	save_world("featuretest", true)
	env.set_values({"time_of_day": 3, "ground": "snow"})
	load_world("featuretest", true)
	_out.append("after load env: " + env.describe())
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/featuretest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()


func _log(label: String, r: Dictionary) -> void:
	_out.append("[%s] ok=%s :: %s" % [label, r.get("ok"), str(r.get("text", r))])
