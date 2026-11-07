extends "res://scripts/main.gd"
## Offline: the Costi tab (session numbers, history from logs/usage.csv, prices) and the
## "strong model only to plan" option. Output: res://tests/coststest_output.txt + coststest_tab.png

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	team.autonomy = false
	player.set_process_unhandled_input(false)
	await get_tree().create_timer(0.5).timeout
	# fake a few calls of this session (not written to the log)
	var arch = team.find_brain("Architetto")
	var saved_spent: float = team.spent_usd
	team.usage["Architetto"] = {"calls": 3, "input": 10, "output": 2400, "cache_write": 3000, "cache_read": 60000, "images": 1, "usd": 0.05}
	team.usage_by_model["claude-sonnet-5-5"] = {"calls": 1, "usd": 0.04}
	team.usage_by_model["claude-haiku-5-5"] = {"calls": 2, "usd": 0.01}
	team.spent_usd = 0.05
	# output split of a fake reply: a thought, a message to the player, one to a teammate, a script
	var content := [
		{"type": "text", "text": "Faccio prima la base."},
		{"type": "tool_use", "name": "say", "input": {"text": "Ecco la casa!"}},
		{"type": "tool_use", "name": "say", "input": {"text": "Aggiungi i lampioni", "to": "Decoratore"}},
		{"type": "tool_use", "name": "run_script", "input": {"code": "extends Node3D\nfunc _ready():\n\tadd_child(Shapes.box(Vector3(4, 3, 4)))\n"}},
	]
	var chars: Dictionary = arch.output_split(content)
	var toks: Dictionary = team.split_output(1000, chars)
	_out.append("caratteri per tipo: %s" % chars)
	_out.append("1000 token divisi: %s (somma %d)" % [toks, toks.values().reduce(func(a, b): return a + b, 0)])
	team.output_by_kind = {"codice": {"tokens": 1500, "usd": 0.012}, "a_te": {"tokens": 300, "usd": 0.003}, "pensieri": {"tokens": 200, "usd": 0.001}, "tra_agenti": {"tokens": 400, "usd": 0.004}}
	var was: bool = team.strong_plan_only
	var m = ui.menu
	m.open()
	var tabs: TabContainer = m.find_children("*", "TabContainer", true, false)[0]
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == "Costi":
			tabs.current_tab = i
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/coststest_tab.png"))
	var sc: ScrollContainer = tabs.get_current_tab_control()
	sc.scroll_vertical = 330
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/coststest_output_split.png"))
	_out.append("tab Costi: %s" % ("ok" if tabs.get_tab_title(tabs.current_tab) == "Costi" else "MANCA"))
	_out.append("righe nel log: %d" % team.read_usage_log().size())
	_out.append("strong_plan_only: %s" % team.strong_plan_only)
	_out.append("architetto: %s, per il giocatore %s" % [arch.model, arch.model_for_player])
	team.set_strong_plan_only(was)
	team.usage.clear()
	team.usage_by_model.clear()
	team.output_by_kind.clear()
	team.spent_usd = saved_spent
	var f := FileAccess.open("res://tests/coststest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out) + "\n")
	f.close()
	get_tree().quit()
