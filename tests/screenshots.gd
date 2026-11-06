extends "res://scripts/main.gd"
## Builds a demo village and saves README screenshots to docs/screenshots/.
## Run this scene from the editor (or run_project) to regenerate them. It never saves the world.

const ShapesTest := preload("res://tests/shapestest.gd")

const LAMP_ROW := """extends Node3D
func _ready():
	add_child(Shapes.ribbon([Vector3(0, 0, 0), Vector3(0.5, 0, -8), Vector3(-0.5, 0, -16), Vector3(0, 0, -24)], 2.2, 0.06, "terra"))
	for i in 4:
		var post := Node3D.new()
		post.position = Vector3(1.8, 0, -i * 6.5 - 1)
		post.add_child(Shapes.cylinder(0.07, 3.2, 6, "ferro_scuro", true))
		var lamp := Shapes.box(Vector3(0.36, 0.42, 0.36), "luce_calda", false)
		lamp.position.y = 3.2
		post.add_child(lamp)
		var cap := Shapes.roof("pyramid", 0.4, 0.4, 0.25, 0.04, "ferro_scuro", false)
		cap.position.y = 3.62
		post.add_child(cap)
		var light := OmniLight3D.new()
		light.light_color = Color("#ffcf87")
		light.light_energy = 2.2
		light.omni_range = 9.0
		light.position.y = 3.3
		post.add_child(light)
		add_child(post)
"""

var _out := PackedStringArray()


func _ready() -> void:
	offline = true
	super._ready()
	if relaunching:
		return
	World.reset_world()
	team.autonomy = false
	team.set_follow(false)
	player.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	env.set_values({"time_of_day": 10.5, "cycle_minutes": 0, "ground": "prato", "fog": 0.15})
	World.run_script({"code": ShapesTest.SHOWCASE, "position": [0, 0, 0], "name": "villaggio"}, "Architetto")
	var cottage_id: String = World.run_script({"code": ShapesTest.COTTAGE, "position": [-6, 0, -1], "name": "casetta"}, "Architetto").text.get_slice(" ", 1)
	World.run_script({"code": LAMP_ROW, "position": [30, 0, 10], "name": "viale dei lampioni"}, "Decoratore")
	var positions := {"Architetto": Vector3(-2, 4.5, 2), "Paesaggista": Vector3(-12, 5, -6), "Decoratore": Vector3(6, 2.8, 5), "Ingegnere": Vector3(11, 3.6, 3), "Critico": Vector3(-4, 6, -3)}
	for b in team.brains:
		b.body.position = positions.get(b.agent_name, Vector3(0, 3, 0))
	team.find_brain("Architetto")._set_status("sta pensando...")
	team.find_brain("Decoratore")._set_status("scrive codice...")
	ui.chat_log.clear()
	ui.add_chat("Tu", "@Architetto facciamo un piccolo villaggio con una casetta, un bosco e una fontana")
	ui.add_chat("Architetto", "Ci sto! Piazza e casetta le faccio io, il bosco al Paesaggista e la fontana al Decoratore.")
	ui.add_chat("Azione", "Architetto · run_script → Creato %s (script Node3D) in (-6.0, 0.0, -1.0)." % cottage_id)
	ui.add_chat("Architetto → Paesaggista", "Bosco misto a ovest della casetta, tra x -25 e -7, z -17 e -3.")
	ui.add_chat("Critico → Decoratore", "obj_9: il vaso fluttua di 5 cm, abbassalo a y=0.")
	await get_tree().create_timer(1.0).timeout

	# 1. the game window, daytime village
	await _window_shot("01_villaggio", Vector3(-3, 1.6, 12), Vector3(-2, 2.0, -6))
	# 2. sunset with the lamp-lit avenue
	env.set_values({"time_of_day": 19.2})
	await _window_shot("02_tramonto", Vector3(31.5, 1.7, 13), Vector3(30, 1.4, 0))
	# 3. night
	env.set_values({"time_of_day": 22.5})
	await _window_shot("03_notte", Vector3(26, 3, 14), Vector3(31, 1.0, -4))
	env.set_values({"time_of_day": 10.5})
	# 4. what an agent sees: 4-view inspection of the cottage
	var cottage = World._get_entity(cottage_id)
	var sheet: Image = await team.photographer.contact_sheet(World.world_aabb(cottage), World.agents.values())
	_save(sheet, "04_ispezione_agente")
	# 5. the player's avatar in build mode, seen from an agent's photo
	player.global_position = Vector3(3, 0.1, 5)
	player.rotation.y = deg_to_rad(40)
	build.toggle()
	build.selected_id = cottage_id
	await get_tree().create_timer(0.6).timeout
	var pic: Image = await team.photographer.capture(Vector3(8, 3.2, 9), Vector3(-1, 1.5, 1), World.agents.values())
	_save(pic, "05_giocatore_visto_dagli_agenti")
	build.toggle()
	# 6. settings menu
	player.global_position = Vector3(-3, 0.1, 12)
	player.rotation.y = 0.0
	ui.menu.open()
	await get_tree().create_timer(0.6).timeout
	_save(get_viewport().get_texture().get_image(), "06_menu")
	ui.menu.close()

	var f := FileAccess.open("res://tests/screenshots_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_out))
	f.close()
	relaunching = true
	get_tree().quit()


func _window_shot(file: String, eye: Vector3, target: Vector3) -> void:
	player.global_position = eye - Vector3(0, 1.6, 0)
	player.velocity = Vector3.ZERO
	var flat := Vector3(target.x - eye.x, 0, target.z - eye.z)
	player.rotation.y = atan2(-flat.x, -flat.z)
	player.head.rotation.x = atan2(target.y - eye.y, flat.length())
	player.set_physics_process(false)
	await get_tree().create_timer(0.8).timeout
	_save(get_viewport().get_texture().get_image(), file)
	player.set_physics_process(true)


func _save(img: Image, file: String) -> void:
	if img.get_width() > 1600:
		img.resize(1600, int(1600.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_LANCZOS)
	var path := ProjectSettings.globalize_path("res://docs/screenshots/%s.jpg" % file)
	img.save_jpg(path, 0.85)
	_out.append("%s %s" % [file, img.get_size()])
