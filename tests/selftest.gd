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
	_t("spawn box", World.spawn_primitive({"shape": "box", "position": [0, 1, 0], "size": [2, 2, 2], "color": "#ff0000", "name": "cubo"}, "Architetto"))
	_t("spawn torus", World.spawn_primitive({"shape": "torus", "position": [4, 1, 0], "size": [2, 0.4, 0], "physics": "rigid"}, "Decoratore"))
	_t("modify", World.modify_object({"id": "obj_1", "color": "blue", "size": [3, 1, 3]}, "Architetto"))
	_t("good script", World.run_script({"code": "extends Node3D\nfunc _ready():\n\tvar m := MeshInstance3D.new()\n\tm.mesh = SphereMesh.new()\n\tadd_child(m)\n\tprint('ciao dal test')\n", "position": [0, 3, -5], "name": "sfera"}, "Ingegnere"))
	_t("parse error", World.run_script({"code": "extends Node3D\nfunc _ready(:\n\tpass\n", "position": [0, 0, 0], "name": "rotto"}, "Ingegnere"))
	_t("forbidden", World.run_script({"code": "extends Node3D\nfunc _ready():\n\tOS.execute('ls', [])\n", "position": [0, 0, 0], "name": "cattivo"}, "Ingegnere"))
	_t("attach", World.attach_script({"id": "obj_1", "code": "extends Node\n@onready var obj: Node3D = get_parent()\nfunc _process(d):\n\tobj.rotate_y(d)\n"}, "Ingegnere"))
	_t("agents global", World.run_script({"code": "extends Node3D\nfunc _process(_d):\n\tif World.agents.has('Architetto'): look_at(World.agents['Architetto'].global_position)\n", "position": [3, 2, 3], "name": "occhio"}, "player"))
	World.board["Architetto"] = "Piano: piazza centrale in (0,0,0)."

	_run_command("/nuovo Giardiniere: si occupa di alberi, fiori e parchi")
	_run_command("/nuovo Giardiniere: doppione")
	_out.append("team after /nuovo: " + team.names_list())
	var g = team.find_brain("giardiniere")
	_out.append("custom prompt team section:\n" + team.describe_team(g))
	_out.append("system prompt chars: %d, has placeholders left: %s" % [g.build_system_prompt().length(), "{NAME}" in g.build_system_prompt()])

	# simulated agent-to-agent message routing
	var arch = team.find_brain("Architetto")
	arch._exec_tool("say", {"text": "Ingegnere, fai ruotare obj_1", "to": "Ingegnere"})
	var ing = team.find_brain("Ingegnere")
	_out.append("ingegnere pending: %s" % str(ing._pending))
	_out.append("decoratore context: %s" % str(team.find_brain("Decoratore")._context))
	_out.append("say to unknown: %s" % str(arch._exec_tool("say", {"text": "x", "to": "Nessuno"})))

	await get_tree().create_timer(1.0).timeout
	_out.append("=== DESCRIBE (Decoratore) ===\n" + World.describe("Decoratore"))

	# save / load round trip
	var before := World.entities.size()
	save_world("selftest", true)
	World.reset_world()
	_run_command("/rimuovi Giardiniere")
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
