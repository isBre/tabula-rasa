extends Node3D
## Builds the world and wires player, agents, UI, commands and saving together.

const PlayerScript := preload("res://scripts/player.gd")
const TeamScript := preload("res://scripts/team.gd")
const UIScript := preload("res://scripts/ui.gd")
const EnvironmentScript := preload("res://scripts/environment.gd")
const HistoryScript := preload("res://scripts/history.gd")
const BuildScript := preload("res://scripts/build_mode.gd")
const SettingsMenuScript := preload("res://scripts/settings_menu.gd")
const Legacy := preload("res://scripts/legacy.gd")

const SAVE_DIR := "res://saves/"
const AUTOSAVE := "autosave"
const AUTOSAVE_INTERVAL := 90.0

## With a debugger attached, any error in the agents' code freezes the game in a
## "Debugger Break". So by default the game restarts itself without the debugger.
## Pass `-- --keep-debugger` on the command line to opt out.
const RELAUNCH_WITHOUT_DEBUGGER := false


var player
var team
var ui
var env
var history
var build
var relaunching := false
var offline := false   # tests: no API calls

var _autosave_t := 0.0


func _ready() -> void:
	if _relaunch_if_debugging():
		return
	Legacy.migrate_settings("user://settings.cfg")
	_size_window()
	env = EnvironmentScript.new()
	env.name = "Environment"
	add_child(env)
	env.build(self)
	World.environment = env
	history = HistoryScript.new()
	history.name = "History"
	add_child(history)

	var world_root := Node3D.new()
	world_root.name = "WorldRoot"
	add_child(world_root)
	World.root = world_root

	player = PlayerScript.new()
	player.name = "Player"
	player.position = Vector3(0, 0.1, 6)
	add_child(player)
	World.player = player

	ui = UIScript.new()
	ui.main = self
	add_child(ui)
	SettingsMenuScript.load_personal(player, ui)
	World.chat_message.connect(ui.add_chat)
	ui.player_message.connect(_on_player_message)
	ui.run_code_requested.connect(_on_run_code)

	team = TeamScript.new()
	team.name = "Team"
	team.ui = ui
	team.history = history
	add_child(team)

	build = BuildScript.new()
	build.name = "BuildMode"
	build.player = player
	build.ui = ui
	build.team = team
	build.history = history
	add_child(build)

	var menu := SettingsMenuScript.new()
	menu.main = self
	ui.add_child(menu)
	ui.menu = menu
	if not offline:
		team.load_api_key()
	team.load_default_agents()

	var loaded := false
	if FileAccess.file_exists(_save_path(AUTOSAVE)):
		loaded = load_world(AUTOSAVE, false)
	if not loaded:
		history.reset("new world")

	if team.api_key == "":
		ui.add_chat("System", "No API key found: create api_key.txt in the project folder (see the README). Meanwhile you can use your own console with Tab.")
		return
	ui.add_chat("System", "Team: %s. Write @Name to talk to an agent (without @, %s answers). /help for the commands." % [team.names_list(), team.lead_name()])
	var l = team.lead()
	if l:
		if loaded:
			l.queue_event("[The player just came back into a world reloaded from a save. Greet them with say in one sentence and briefly remind them what is there or what you were working on (look at the objects and the board). Don't build anything.]")
		else:
			l.queue_event("[The player just entered the world, which is completely empty. Greet them with say, introduce the team in two sentences and ask them what they want to build. Don't build anything yet.]")


## Opens the window at ~85% of the screen, centered (on Retina screens the default
## 1600x900 pixels would be a small window).
func _size_window() -> void:
	var w := get_window()
	if w.mode != Window.MODE_WINDOWED:
		return
	var r := DisplayServer.screen_get_usable_rect(w.current_screen)
	var target := Vector2i(Vector2(r.size) * 0.85)
	w.size = target
	w.position = r.position + Vector2i((r.size - target) / 2.0)


func _relaunch_if_debugging() -> bool:
	if not RELAUNCH_WITHOUT_DEBUGGER or not EngineDebugger.is_active():
		return false
	if "--keep-debugger" in OS.get_cmdline_user_args():
		return false
	var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), scene_file_path])
	OS.create_process(OS.get_executable_path(), args)
	relaunching = true
	set_process(false)
	set_process_unhandled_input(false)
	get_tree().quit()
	return true


func _process(delta: float) -> void:
	if relaunching:
		return
	_autosave_t += delta
	if _autosave_t >= AUTOSAVE_INTERVAL and not offline:
		_autosave_t = 0.0
		save_world(AUTOSAVE, false)
	var agents: Array = []
	var npcs: Array = []
	for b in team.brains:
		if not b.hidden:
			(agents if b.can_build else npcs).append([b.agent_name, b.color, b.status_text])
	var foot := PackedStringArray()
	foot.append("autonomy " + ("on" if team.autonomy else "off"))
	foot.append("%d objects" % World.entities.size())
	if player.flying:
		foot.append("flying")
	var footer := "  ·  ".join(foot)
	if build.active:
		footer += "\n" + build.status_text()
	if player.looking_at_id != "":
		var n = World.entities.get(player.looking_at_id)
		if n != null and is_instance_valid(n):
			footer += '\naiming at: %s "%s" by %s' % [player.looking_at_id, n.get_meta("label"), n.get_meta("author")]
	ui.set_hud({
		"time": env.clock(),
		"spend": "$%.3f / $%.2f" % [team.spent_usd, team.budget_usd],
		"over": team.spent_usd >= team.budget_usd,
		"agents": agents,
		"footer": footer,
		"npcs": npcs,
		"npc_footer": "autonomy " + ("on" if team.npc_autonomy else "off"),
	})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not relaunching and not offline and team != null:
		save_world(AUTOSAVE, false)


func _unhandled_input(event: InputEvent) -> void:
	if get_viewport().gui_get_focus_owner() != null:
		return
	if build.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.physical_keycode == KEY_Z and (event.ctrl_pressed or event.meta_pressed):
		_undo()
		return
	match event.physical_keycode:
		KEY_X:
			var id: String = player.looking_at_id
			if id != "":
				World.delete_object({"id": id}, "player")
				ui.add_chat("System", "You deleted " + id)
				team.broadcast_context("[The player deleted %s]" % id)
				history.commit("player", "deleted " + id)
		KEY_P:
			_toggle_autonomy()
		KEY_B:
			build.toggle()


func _undo() -> void:
	var msg: String = history.undo()
	ui.add_chat("System", msg)
	if msg.begins_with("Undid"):
		team.broadcast_context("[The player undid the last change. %s]" % msg)


func _toggle_autonomy() -> void:
	team.autonomy = not team.autonomy
	ui.add_chat("System", "Agent autonomy: " + ("ON" if team.autonomy else "OFF"))


# ---------------------------------------------------------------- commands

const HELP_TEXT := """Commands:
@Name message · talk to an agent (@all to everyone; without @ the lead answers)
/agents · list the team
/new Name: role description · create a new agent
/remove Name · remove an agent you created (agents, NPCs, models and permissions: Esc > Agents)
/save [name] · /load [name] · /saves
/undo (Ctrl+Z) · /history · /restore N · world history
/blueprint name description · save the object you aim at · /place name · /blueprints
/time H · /cycle minutes (0 = stopped) · /ground grid|grass|sand|snow|stone|dirt · /fog 0-1
/costs · /budget dollars · estimated spending and cap
/follow · agents catch up with you on/off   /ui 1.2 · interface size
/wipe · full reset (world, agents' memory, board, history)
/reset · empty the world   /auto · autonomy on/off   /clear · agents forget the conversation
Keys: B build mode · P autonomy · X delete aimed object · F fly"""


func _on_player_message(text: String) -> void:
	if text.begins_with("/"):
		_run_command(text)
		return
	World.chat_message.emit("You", text)
	team.route_player_message(text)


func _run_command(text: String) -> void:
	var cmd := text.get_slice(" ", 0).to_lower()
	var arg := text.substr(cmd.length()).strip_edges()
	match cmd:
		"/undo":
			_undo()
		"/history":
			ui.add_chat("System", history.list_text())
		"/restore":
			ui.add_chat("System", history.restore(int(arg)))
			team.broadcast_context("[The player brought the world back to an earlier state (#%s).]" % arg)
		"/costs":
			ui.add_chat("System", team.costs_text())
		"/budget":
			if arg.is_valid_float():
				team.set_budget(arg.to_float())
			ui.add_chat("System", "Spending cap: $%.2f (spent so far $%.4f)." % [team.budget_usd, team.spent_usd])
		"/time", "/cycle", "/ground", "/fog":
			var key: String = {"/time": "time_of_day", "/cycle": "cycle_minutes", "/ground": "ground", "/fog": "fog"}[cmd]
			var value: Variant = arg
			if cmd != "/ground":
				value = arg.to_float()
			var r: Dictionary = env.set_values({key: value})
			ui.add_chat("System", r.text)
			if r.ok:
				team.broadcast_context("[The player changed the environment: %s]" % env.describe())
				history.commit("player", "environment: " + env.describe(), "env")
		"/blueprint":
			var bp_name := arg.get_slice(" ", 0)
			var r: Dictionary = {"ok": false, "text": "Aim at an object and write /blueprint name description."}
			if player.looking_at_id != "" and bp_name != "":
				r = World.save_blueprint({"id": player.looking_at_id, "name": bp_name, "description": arg.substr(bp_name.length()).strip_edges()}, "player")
			ui.add_chat("System", r.text)
		"/place":
			var f: Vector3 = player.get_forward()
			f.y = 0.0
			var pos: Vector3 = player.looking_point if player.has_point else player.global_position + f.normalized() * 5.0
			var r: Dictionary = World.spawn_blueprint({"name": arg, "position": [pos.x, maxf(pos.y, 0.0), pos.z], "rotation_deg": [0, rad_to_deg(player.rotation.y), 0]}, "player")
			ui.add_chat("System", r.text)
			if r.ok:
				history.commit("player", "placed blueprint " + arg)
				team.broadcast_context("[The player placed the blueprint '%s' as %s]" % [arg, r.id])
		"/blueprints":
			var names := PackedStringArray()
			for bp in World.list_blueprints():
				names.append("%s%s" % [bp.name, (" (" + bp.description + ")") if bp.description != "" else ""])
			ui.add_chat("System", "Blueprint: " + (", ".join(names) if not names.is_empty() else "none. Aim at an object and use /blueprint name description"))
		"/wipe":
			full_reset()
		"/reset":
			World.reset_world()
			history.commit("player", "world emptied")
			ui.add_chat("System", "World emptied (Ctrl+Z to go back).")
			team.broadcast_context("[The player completely emptied the world with /reset. The board was cleared too.]")
		"/auto":
			_toggle_autonomy()
		"/ui":
			if arg.is_valid_float():
				ui.set_ui_scale(arg.to_float())
			ui.add_chat("System", "Interface scale: %.2f (e.g. /ui 1.2 to enlarge, /ui 0.9 to shrink)." % ui.ui_scale)
		"/follow":
			team.set_follow(not team.follow)
			ui.add_chat("System", "The agents " + ("follow you." if team.follow else "stay where they work."))
		"/clear":
			team.clear_histories()
			ui.add_chat("System", "The agents forgot the conversation (the world and the board stay).")
		"/agents":
			for b in team.brains:
				var models: String = b.model if b.model_for_player == "" else "%s, %s when you write to it" % [b.model, b.model_for_player]
				ui.add_chat(b.agent_name, "%s[%s] %s" % ["(lead) " if b.is_lead else "", models, b.role])
		"/new":
			_create_agent(arg)
		"/remove":
			var err: String = team.remove_agent(arg)
			ui.add_chat("System", err if err != "" else "%s left the team." % arg)
		"/save":
			save_world(arg if arg != "" else "world", true)
		"/load":
			load_world(arg if arg != "" else "world", true)
		"/saves":
			var names := PackedStringArray()
			for f in DirAccess.get_files_at(SAVE_DIR):
				if f.ends_with(".json"):
					names.append(f.get_basename())
			ui.add_chat("System", "Saves: " + (", ".join(names) if not names.is_empty() else "none"))
		_:
			ui.add_chat("System", HELP_TEXT)


func _create_agent(arg: String) -> void:
	var i := arg.find(":")
	if i <= 0:
		ui.add_chat("System", "Usage: /new Name: role description (e.g. /new Gardener: takes care of trees, flowers and parks)")
		return
	var agent_name := arg.substr(0, i).strip_edges()
	var role := arg.substr(i + 1).strip_edges()
	var err: String = team.spawn_agent({"name": agent_name, "role": role}, true)
	if err != "":
		ui.add_chat("System", err)
		return
	var b = team.find_brain(agent_name)
	ui.add_chat("System", "Welcome to the team, %s." % b.agent_name)
	for other in team.brains:
		if other != b:
			other.add_context("[The player created a new agent, %s, with this role: %s]" % [b.agent_name, role])
	if team.api_key != "":
		b.queue_event("[The player just created you. Introduce yourself in one sentence with say and, if it makes sense, suggest or ask what to do. Don't build yet.]")


func _on_run_code(code: String) -> void:
	var f: Vector3 = player.get_forward()
	f.y = 0.0
	if f.length() < 0.01:
		f = Vector3.FORWARD
	var pos: Vector3 = player.global_position + f.normalized() * 4.0 + Vector3.UP * 1.0
	var r := World.run_script({"code": code, "position": [pos.x, pos.y, pos.z], "name": "player's creation"}, "player")
	ui.show_code_result(r.ok, r.text)
	if r.ok:
		history.commit("player", "console: " + str(r.text).get_slice("\n", 0))
		ui.add_chat("System", "You ran your code: " + str(r.text).get_slice("\n", 0))
		team.broadcast_context("[The player ran code from their console. Result: %s]\n```gdscript\n%s\n```" % [r.text, code])


## Starts over: empty world, agents with no memory, empty board and history, default
## atmosphere. The current world is first saved to saves/before_reset.json.
func full_reset() -> void:
	if not offline:
		save_world("before_reset", false)
	team.reset_all()
	World.reset_world()
	env.set_values({"time_of_day": 10.5, "cycle_minutes": 0.0, "fog": 0.15, "ground": "grass"})
	player.global_position = Vector3(0, 0.1, 6)
	player.rotation = Vector3.ZERO
	player.velocity = Vector3.ZERO
	history.reset("full reset")
	ui.chat_log.clear()
	ui.add_chat("System", "Full reset: empty world and agents with no memory. The previous world is in saves/before_reset.json (/load before_reset).")
	if not offline:
		save_world(AUTOSAVE, false)
	var l = team.lead()
	if l and team.api_key != "":
		l.queue_event("[The player just wiped everything: the world is completely empty and none of you remembers anything. Greet them with say, introduce the team in two sentences and ask them what they want to build. Don't build anything yet.]")


# ---------------------------------------------------------------- save / load

func _save_path(save_name: String) -> String:
	return SAVE_DIR + save_name.validate_filename() + ".json"


func save_world(save_name: String, verbose: bool) -> bool:
	var data := World.serialize()
	data["agents"] = team.serialize()
	data["player"] = {"position": World._arr(player.position), "rot_y": player.rotation.y}
	data["saved_at"] = Time.get_datetime_string_from_system()
	var path := _save_path(save_name)
	if save_name == AUTOSAVE and FileAccess.file_exists(path):
		# keep the previous autosave as a safety copy
		DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(_save_path(AUTOSAVE + "_previous")))
	var err := World.save_json(path, data)
	if verbose or err != "":
		ui.add_chat("System", err if err != "" else "World saved to saves/%s.json (%d objects)." % [save_name.validate_filename(), World.entities.size()])
	return err == ""


func load_world(save_name: String, _verbose: bool) -> bool:
	var data = World.load_json(_save_path(save_name))
	if data == null:
		ui.add_chat("System", "Save '%s' not found or not valid." % save_name)
		return false
	Legacy.migrate_save(data)
	var problems := World.deserialize(data)
	team.apply_save(data.get("agents", {}))
	var pl: Dictionary = data.get("player", {})
	if pl.has("position"):
		player.position = World.vec3(pl["position"], player.position)
		player.rotation.y = float(pl.get("rot_y", 0.0))
		player.velocity = Vector3.ZERO
	team.clear_histories()
	history.reset("loaded '%s'" % save_name)
	team.broadcast_context("[The world was loaded from the save '%s'.]" % save_name)
	ui.add_chat("System", "Loaded '%s': %d objects%s." % [save_name, World.entities.size(), "" if problems.is_empty() else ", %d problems" % problems.size()])
	for p in problems.slice(0, 5):
		ui.add_chat("System", str(p).get_slice("\n", 0))
	return true
