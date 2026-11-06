extends "res://scripts/main.gd"
## Saves a screenshot of the whole window (3D + UI) to res://tests/uitest_screen.jpg

func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	team.autonomy = false
	for b in team.brains:
		b._set_status("sta pensando..." if b.agent_name == "Architetto" else "")
	ui.add_chat("Tu", "@Architetto costruiamo un villaggio sulla collina")
	ui.add_chat("Architetto", "Ottima idea! Preparo la piazza e chiedo al Paesaggista di sistemare il terreno.")
	ui.add_chat("Azione", "Architetto · run_script → Creato obj_12 (script Node3D) in (0.0, 0.0, -10.0).")
	ui.add_chat("Architetto → Paesaggista", "Puoi fare una collina dolce a nord della piazza, in (0, 0, -30)?")
	await get_tree().create_timer(2.5).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_jpg(ProjectSettings.globalize_path("res://tests/uitest_screen.jpg"))
	ui.menu.open()
	await get_tree().create_timer(0.5).timeout
	var img2 := get_viewport().get_texture().get_image()
	img2.save_jpg(ProjectSettings.globalize_path("res://tests/uitest_menu.jpg"))
	var f := FileAccess.open("res://tests/uitest_output.txt", FileAccess.WRITE)
	f.store_string("window %s, screen scale %.2f, content scale %.2f, image %s" % [get_window().size, DisplayServer.screen_get_scale(), get_window().content_scale_factor, img.get_size()])
	f.close()
	relaunching = true
	get_tree().quit()
