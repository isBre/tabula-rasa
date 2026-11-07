extends "res://scripts/main.gd"
## Offline: HUD, menu tabs, creating/editing/hiding agents and NPC permissions.
## Output: res://tests/uitest_output.txt + uitest_*.png

var _out := PackedStringArray()


func _snap(label: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path("res://tests/uitest_%s.png" % label))


func arch_restore():
	return team.find_brain("Architetto")


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	player.set_process_unhandled_input(false)
	await get_tree().create_timer(0.5).timeout
	team.find_brain("Scultore").status_text = "modella..."
	await get_tree().create_timer(0.3).timeout
	await _snap("hud")
	var m = ui.menu
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	var saved_looks = cfg.get_value("looks", "Architetto", null) if cfg.has_section_key("looks", "Architetto") else null
	m.open()
	await _snap("menu_settings")
	var tabs: TabContainer = m.find_children("*", "TabContainer", true, false)[0]
	tabs.current_tab = 1
	await _snap("menu_agents")
	# a new NPC through the form
	m._open_form("")
	m._f_name.text = "Oste"
	m._f_kind.select(1)
	m._f_kind.item_selected.emit(1)
	m._f_role.text = "L'oste della taverna: burbero ma generoso, conosce tutti i pettegolezzi."
	m._pick(m._f_hat, "cuoco")
	m._pick(m._f_hair_style, "lunghi")
	m._f_height.value = 1.1
	await _snap("menu_form")
	m._save_form()
	var oste = team.find_brain("Oste")
	_out.append("oste: %s build=%s model=%s see=%s" % [oste != null, oste.can_build, oste.can_model, oste.can_see])
	_out.append("oste allows spawn_asset=%s say=%s design_model=%s take_photo=%s" % [oste.allows("spawn_asset"), oste.allows("say"), oste.allows("design_model"), oste.allows("take_photo")])
	_out.append("oste tools sent: %d of %d" % [oste.TOOLS.filter(func(t): return oste.allows(str(t.name))).size(), oste.TOOLS.size()])
	_out.append("oste prompt has permissions: %s" % ("YOUR PERMISSIONS" in oste.build_system_prompt()))
	var blocked: Dictionary = await oste._exec_tool("spawn_primitive", {"shape": "box", "position": [0, 0.5, 0]})
	_out.append("oste spawn: %s" % blocked.text)
	oste.body.move_to(Vector3(3, 6, 3))
	_out.append("oste fly: target y=%.2f flying=%s can_fly=%s look=%s" % [oste.body._target.y, oste.body._flying, oste.body.can_fly, oste.body.look])
	var arch = team.find_brain("Architetto")
	team.set_look(arch, {"hat": "corona", "hair_style": "cresta", "hair": "#d8d0c8"})
	_out.append("arch look: %s" % arch.body.full_look())
	m.close()
	team.find_brain("Oste").status_text = "passeggia..."
	oste.body.position = player.global_position + Vector3(-1.2, 0, -3.5)
	arch.body.position = player.global_position + Vector3(1.0, 0, -3.5)
	oste.body._target = oste.body.position
	arch.body._target = arch.body.position
	await get_tree().create_timer(1.0).timeout
	await _snap("hud_npc")
	var pic: Image = await team.photographer.capture(player.global_position + Vector3(0, 1.6, -0.8), player.global_position + Vector3(0, 1.2, -3.5), [player.avatar])
	pic.save_png(ProjectSettings.globalize_path("res://tests/uitest_looks.png"))
	m.open()
	# edit the NPC into a builder with Sonnet
	m._open_form("Oste")
	m._f_kind.select(0)
	m._f_kind.item_selected.emit(0)
	m._pick(m._f_model, "claude-sonnet-5-5")
	m._save_form()
	oste = team.find_brain("Oste")
	_out.append("oste after edit: build=%s model=%s custom=%s index=%d" % [oste.can_build, oste.model, oste.is_custom, team.brains.find(oste)])
	# built-in: hide and change model, but not remove
	var crit = team.find_brain("Critico")
	team.set_hidden(crit, true)
	_out.append("critico hidden: visible=%s in World.agents=%s in team description=%s" % [crit.body.visible, World.agents.has("Critico"), "Critico" in team.describe_team(null)])
	_out.append("remove builtin: " + team.remove_agent("Critico"))
	m._open_form("Paesaggista")
	m._pick(m._f_model, "claude-sonnet-5-5")
	m._save_form()
	_out.append("paesaggista model: " + team.find_brain("Paesaggista").model)
	team.set_models(team.find_brain("Paesaggista"), "claude-haiku-5-5", "")   # back to default
	var saved: Dictionary = team.serialize()
	_out.append("save: custom=%s hidden=%s" % [saved.custom.map(func(d): return d.name), saved.hidden])
	m._refresh_agents()
	await get_tree().process_frame
	await _snap("menu_agents2")
	tabs.current_tab = 3
	await _snap("menu_commands")
	for t in tabs.get_tab_count():
		tabs.current_tab = t
		await get_tree().process_frame
		await get_tree().process_frame
		_out.append("menu width tab %d: %d" % [t, tabs.size.x])
	tabs.current_tab = 1
	m._open_form("Oste")
	await get_tree().process_frame
	await get_tree().process_frame
	_out.append("tabs disabled while editing: %s" % [[tabs.is_tab_disabled(0), tabs.is_tab_disabled(1), tabs.is_tab_disabled(2)]])
	await _snap("menu_edit")
	await get_tree().process_frame
	_out.append("menu width form: %d" % tabs.size.x)
	m._close_form()
	# chat filters
	ui.add_chat("Azione", "Architetto · run_script → Creato obj_1")
	ui.add_chat("Pensiero", "Architetto: penso alla casa")
	ui.add_chat("Architetto → Scultore", "mi serve una panchina")
	ui.add_chat("Architetto", "Ciao!")
	var before: String = ui.chat_log.get_parsed_text()
	ui.set_chat_filter("azioni", true)
	var after: String = ui.chat_log.get_parsed_text()
	ui.set_chat_filter("azioni", false)
	_out.append("chat: azioni hidden=%s shown after toggle=%s squadra shown=%s" % [not ("run_script" in before), "run_script" in after, "panchina" in before])
	team.set_hidden(crit, false)
	team.set_look(arch_restore(), saved_looks if saved_looks is Dictionary else {})
	team.remove_agent("Oste")
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/uitest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
