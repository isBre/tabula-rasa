extends "res://scripts/main.gd"
## Offline: shared palette, add_color, style checks in the workshop, style guide in the prompt,
## the Stile tab. Restores palette.json at the end.
## Output: res://tests/styletest_output.txt + styletest_menu.png

var _out := PackedStringArray()

const UGLY := {"parts": [
	{"id": "base", "shape": "cylinder", "radius": 0.4, "height": 0.1, "sides": 32, "mat": "#123456"},
	{"id": "palla", "shape": "sphere", "radius": 0.2, "detail": 5, "mat": "#ff00ff", "position": [0, 0.1, 0]},
	{"id": "foglio", "shape": "box", "size": [0.4, 0.4, 0.004], "mat": "oro", "position": [0, 0.5, 0]},
	{"id": "a", "shape": "box", "size": [0.1, 0.1, 0.1], "mat": "legno", "position": [0.3, 0.1, 0]},
	{"id": "b", "shape": "box", "size": [0.1, 0.1, 0.1], "mat": "pietra", "position": [-0.3, 0.1, 0]},
	{"id": "c", "shape": "box", "size": [0.1, 0.1, 0.1], "mat": "neve", "position": [0, 0.1, 0.3]},
	{"id": "d", "shape": "box", "size": [0.1, 0.1, 0.1], "mat": "tetto", "position": [0, 0.1, -0.3]},
]}

const NICE := {"parts": [
	{"id": "gamba", "shape": "box", "size": [0.05, 0.45, 0.05], "mat": "legno", "positions": [[0.2, 0, 0.2], [0.2, 0, -0.2]], "mirror": "x"},
	{"id": "seduta", "shape": "box", "size": [0.5, 0.05, 0.5], "mat": "legno_chiaro", "position": [0, 0.45, 0]},
]}


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	var original := FileAccess.get_file_as_string("res://palette.json")
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	await get_tree().create_timer(0.3).timeout
	var b = team.find_brain("Scultore")
	_out.append("palette: %d colori, gruppi nel testo: %s" % [Shapes.PALETTE.size(), "legni:" in Shapes.palette_text() and "metalli:" in Shapes.palette_text()])
	var dup: Dictionary = await b._exec_tool("add_color", {"name": "legno_quasi", "color": "#8c5b2c", "group": "legni", "description": "prova"})
	_out.append("add near-duplicate: [%s] %s" % [dup.ok, dup.text])
	var ok: Dictionary = await b._exec_tool("add_color", {"name": "viola_prova", "color": "#7a3fa0", "group": "tessuti e superfici", "description": "stoffa viola di prova"})
	_out.append("add new: [%s] %s · in palette=%s · material=%s" % [ok.ok, ok.text, Shapes.PALETTE.has("viola_prova"), Shapes.material("viola_prova").albedo_color.to_html(false)])
	var ugly: Dictionary = await b._exec_tool("design_model", UGLY)
	_out.append("UGLY: " + str(ugly.text).substr(str(ugly.text).find("Stile")))
	var nice: Dictionary = await b._exec_tool("design_model", NICE)
	_out.append("NICE: " + str(nice.text).substr(str(nice.text).find("Stile")).get_slice("\n", 0))
	var prompt: String = b.build_system_prompt()
	_out.append("prompt: STYLE=%s PALETTE listed=%s viola=%s" % ["STYLE (the same" in prompt, "legno_chiaro #c19a6b" in prompt, "viola_prova" in prompt])
	var npc_def := {"name": "Passante", "role": "un passante", "can_build": false, "can_model": false}
	team.spawn_agent(npc_def, true)
	var npc = team.find_brain("Passante")
	_out.append("add_color allowed: builder=%s npc=%s" % [b.allows("add_color"), npc.allows("add_color")])
	team.remove_agent("Passante")
	var m = ui.menu
	m.open()
	var tabs: TabContainer = m.find_children("*", "TabContainer", true, false)[0]
	tabs.current_tab = 2
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/styletest_menu.png"))
	_out.append("menu width on Stile: %d" % tabs.size.x)
	m.close()
	# restore the palette
	var f := FileAccess.open("res://palette.json", FileAccess.WRITE)
	f.store_string(original)
	f.close()
	Shapes.load_palette()
	_out.append("restored: viola gone=%s" % [not Shapes.PALETTE.has("viola_prova")])
	_out.append("=== DONE ===")
	var fo := FileAccess.open("res://tests/styletest_output.txt", FileAccess.WRITE)
	fo.store_string("\n".join(_out))
	fo.close()
	relaunching = true
	get_tree().quit()
