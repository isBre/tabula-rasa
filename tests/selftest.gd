extends "res://scripts/main.gd"
## Runs the game offline (no API calls), exercises World, team and save/load,
## writes the results to res://tests/selftest_output.txt, then quits.

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	team.autonomy = false
	World.reset_world()
	await get_tree().create_timer(0.5).timeout
	_out.append("team: " + team.names_list() + " lead=" + team.lead_name())
	_t("spawn box", World.spawn_primitive({"shape": "box", "position": [0, 1, 0], "size": [2, 2, 2], "color": "#ff0000", "name": "cube"}, "Architect"))
	_t("spawn torus", World.spawn_primitive({"shape": "torus", "position": [4, 1, 0], "size": [2, 0.4, 0], "physics": "rigid"}, "Decorator"))
	_t("modify", World.modify_object({"id": "obj_1", "color": "blue", "size": [3, 1, 3]}, "Architect"))
	_t("good script", World.run_script({"code": "extends Node3D\nfunc _ready():\n\tvar m := MeshInstance3D.new()\n\tm.mesh = SphereMesh.new()\n\tadd_child(m)\n\tprint('hello from the test')\n", "position": [0, 3, -5], "name": "sphere"}, "Engineer"))
	_t("parse error", World.run_script({"code": "extends Node3D\nfunc _ready(:\n\tpass\n", "position": [0, 0, 0], "name": "broken"}, "Engineer"))
	_t("forbidden", World.run_script({"code": "extends Node3D\nfunc _ready():\n\tOS.execute('ls', [])\n", "position": [0, 0, 0], "name": "nasty"}, "Engineer"))
	_t("attach", World.attach_script({"id": "obj_1", "code": "extends Node\n@onready var obj: Node3D = get_parent()\nfunc _process(d):\n\tobj.rotate_y(d)\n"}, "Engineer"))
	_t("agents global", World.run_script({"code": "extends Node3D\nfunc _process(_d):\n\tif World.agents.has('Architect'): look_at(World.agents['Architect'].global_position)\n", "position": [3, 2, 3], "name": "eye"}, "player"))
	World.board["Architect"] = "Plan: central square at (0,0,0)."

	_run_command("/new Gardener: takes care of trees, flowers and parks")
	_run_command("/new Gardener: duplicate")
	_out.append("team after /new: " + team.names_list())
	var g = team.find_brain("gardener")
	_out.append("custom prompt team section:\n" + team.describe_team(g))
	_out.append("system prompt chars: %d, has placeholders left: %s" % [g.build_system_prompt().length(), "{NAME}" in g.build_system_prompt()])

	# simulated agent-to-agent message routing
	var arch = team.find_brain("Architect")
	arch._exec_tool("say", {"text": "Engineer, make obj_1 spin", "to": "Engineer"})
	var ing = team.find_brain("Engineer")
	_out.append("engineer pending: %s" % str(ing._pending))
	_out.append("decorator context: %s" % str(team.find_brain("Decorator")._context))
	_out.append("say to unknown: %s" % str(arch._exec_tool("say", {"text": "x", "to": "Nobody"})))

	await get_tree().create_timer(1.0).timeout
	_out.append("=== DESCRIBE (Decorator) ===\n" + World.describe("Decorator"))

	# save / load round trip
	var before := World.entities.size()
	save_world("selftest", true)
	World.reset_world()
	_run_command("/remove Gardener")
	_out.append("after reset: %d objects, team %s" % [World.entities.size(), team.names_list()])
	await get_tree().process_frame
	load_world("selftest", true)
	await get_tree().create_timer(0.5).timeout
	_out.append("after load: %d objects (before %d), team %s, board %s" % [World.entities.size(), before, team.names_list(), str(World.board)])
	_t("inspect after load", World.inspect_object({"id": "obj_1"}))
	_t("new id after load", World.spawn_primitive({"shape": "sphere", "position": [0, 5, 0]}, "player"))
	_out.append("=== SELFTEST DONE ===")
	var f := FileAccess.open("res://tests/selftest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true  # skip autosave on quit
	await get_tree().create_timer(1.0).timeout
	get_tree().quit()


func _t(label: String, r: Dictionary) -> void:
	_out.append("[%s] ok=%s :: %s" % [label, r.get("ok"), str(r.get("text", r))])
