extends "res://scripts/main.gd"
## Offline: full reset and the Architect's per-turn model choice.
## Output: res://tests/resettest_output.txt + resettest_dialog.jpg

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	team.autonomy = false
	player.set_process_unhandled_input(false)
	await get_tree().create_timer(0.3).timeout
	var arch = team.find_brain("Architetto")
	_out.append("Architetto models: default=%s, player=%s" % [arch.model, arch.model_for_player])
	# model routing (fake key: the request fails, we only look at the chosen model)
	team.api_key = "test"
	arch.queue_event("[Ingegnere ti dice]: ho finito la porta")
	_out.append("teammate turn -> %s" % arch.current_model)
	arch.reset_all()
	arch.queue_event("[Il giocatore ti dice]: facciamo un castello")
	_out.append("player turn -> %s" % arch.current_model)
	arch.reset_all()
	team.api_key = ""

	World.spawn_asset({"asset": "kaykit_medieval/building_tavern_red", "position": [0, 0, -6], "height": 5}, "Architetto")
	World.board["Architetto"] = "piano: taverna"
	arch.messages = [{"role": "user", "content": [{"type": "text", "text": "ciao"}]}]
	arch.busy = true
	history.commit("Architetto", "taverna")
	_out.append("before: %d objects, board %s, arch messages %d, busy %s, history %d" % [World.entities.size(), str(World.board), arch.messages.size(), arch.busy, history.commits.size()])
	ui.menu.open()
	ui.menu._confirm.popup_centered()
	await get_tree().create_timer(0.6).timeout
	get_viewport().get_texture().get_image().save_jpg(ProjectSettings.globalize_path("res://tests/resettest_dialog.jpg"))
	ui.menu._confirm.confirmed.emit()
	await get_tree().create_timer(0.3).timeout
	_out.append("after: %d objects, board %s, arch messages %d, busy %s, history %d, menu visible %s, env %s" % [World.entities.size(), str(World.board), arch.messages.size(), arch.busy, history.commits.size(), ui.menu.visible, env.describe()])
	_out.append("=== DONE ===")
	var f := FileAccess.open("res://tests/resettest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()
