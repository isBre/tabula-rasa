extends Node3D
## Builds the world and wires player, agents, UI, commands and saving together.

const PlayerScript := preload("res://scripts/player.gd")
const TeamScript := preload("res://scripts/team.gd")
const UIScript := preload("res://scripts/ui.gd")
const EnvironmentScript := preload("res://scripts/environment.gd")
const HistoryScript := preload("res://scripts/history.gd")
const BuildScript := preload("res://scripts/build_mode.gd")
const SettingsMenuScript := preload("res://scripts/settings_menu.gd")

const SAVE_DIR := "res://saves/"
const AUTOSAVE := "autosave"
const AUTOSAVE_INTERVAL := 90.0

## With a debugger attached, any error in the agents' code freezes the game in a
## "Debugger Break". So by default the game restarts itself without the debugger.
## Pass `-- --keep-debugger` on the command line to opt out.
const RELAUNCH_WITHOUT_DEBUGGER := true


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
		history.reset("mondo nuovo")

	if team.api_key == "":
		ui.add_chat("Sistema", "Nessuna API key trovata: crea api_key.txt nella cartella del progetto (vedi README). Intanto puoi usare la tua console con Tab.")
		return
	ui.add_chat("Sistema", "Squadra: %s. Scrivi @Nome per parlare a un agente (senza @ risponde %s). /aiuto per i comandi." % [team.names_list(), team.lead_name()])
	var l = team.lead()
	if l:
		if loaded:
			l.queue_event("[Il giocatore è appena rientrato in un mondo ricaricato da un salvataggio. Salutalo con say in una frase e ricordagli brevemente cosa c'è o a cosa stavate lavorando (guarda oggetti e lavagna). Non costruire niente.]")
		else:
			l.queue_event("[Il giocatore è appena entrato nel mondo, che è completamente vuoto. Salutalo con say, presenta la squadra in due frasi e chiedigli cosa vuole costruire. Non costruire ancora niente.]")


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
	var s := "Autonomia %s · %d oggetti · ore %s\nSpesa $%.3f / $%.2f\n%s" % ["ON" if team.autonomy else "OFF", World.entities.size(), env.clock(), team.spent_usd, team.budget_usd, team.status_line()]
	if player.flying:
		s += " · VOLO"
	if build.active:
		s += "\n" + build.status_text()
	if player.looking_at_id != "":
		var n = World.entities.get(player.looking_at_id)
		if n != null and is_instance_valid(n):
			s += '\nMirino: %s "%s" (di %s)' % [player.looking_at_id, n.get_meta("label"), n.get_meta("author")]
	ui.set_status(s)


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
				ui.add_chat("Sistema", "Hai eliminato " + id)
				team.broadcast_context("[Il giocatore ha eliminato %s]" % id)
				history.commit("giocatore", "eliminato " + id)
		KEY_P:
			_toggle_autonomy()
		KEY_B:
			build.toggle()


func _undo() -> void:
	var msg: String = history.undo()
	ui.add_chat("Sistema", msg)
	if msg.begins_with("Annullato"):
		team.broadcast_context("[Il giocatore ha annullato l'ultima modifica. %s]" % msg)


func _toggle_autonomy() -> void:
	team.autonomy = not team.autonomy
	ui.add_chat("Sistema", "Autonomia degli agenti: " + ("ON" if team.autonomy else "OFF"))


# ---------------------------------------------------------------- commands

const HELP_TEXT := """Comandi:
@Nome messaggio · parla a un agente (@tutti a tutti; senza @ risponde il lead)
/agenti · elenca la squadra
/nuovo Nome: descrizione del ruolo · crea un nuovo agente
/rimuovi Nome · rimuove un agente
/salva [nome] · /carica [nome] · /salvataggi
/annulla (Ctrl+Z) · /storia · /ripristina N · cronologia del mondo
/blueprint nome descrizione · salva l'oggetto mirato · /piazza nome · /blueprints
/ora H · /ciclo minuti (0 = fermo) · /terreno griglia|prato|sabbia|neve|pietra|terra · /nebbia 0-1
/costi · /budget dollari · spesa stimata e tetto
/segui · gli agenti ti raggiungono on/off   /ui 1.2 · dimensione dell'interfaccia
/reset · svuota il mondo   /auto · autonomia on/off   /clear · gli agenti dimenticano la conversazione
Tasti: B modalità costruzione · P autonomia · X elimina mirato · F volo"""


func _on_player_message(text: String) -> void:
	if text.begins_with("/"):
		_run_command(text)
		return
	World.chat_message.emit("Tu", text)
	team.route_player_message(text)


func _run_command(text: String) -> void:
	var cmd := text.get_slice(" ", 0).to_lower()
	var arg := text.substr(cmd.length()).strip_edges()
	match cmd:
		"/annulla":
			_undo()
		"/storia":
			ui.add_chat("Sistema", history.list_text())
		"/ripristina":
			ui.add_chat("Sistema", history.restore(int(arg)))
			team.broadcast_context("[Il giocatore ha riportato il mondo a uno stato precedente (#%s).]" % arg)
		"/costi":
			ui.add_chat("Sistema", team.costs_text())
		"/budget":
			if arg.is_valid_float():
				team.set_budget(arg.to_float())
			ui.add_chat("Sistema", "Tetto di spesa: $%.2f (speso finora $%.4f)." % [team.budget_usd, team.spent_usd])
		"/ora", "/ciclo", "/terreno", "/nebbia":
			var key: String = {"/ora": "time_of_day", "/ciclo": "cycle_minutes", "/terreno": "ground", "/nebbia": "fog"}[cmd]
			var value: Variant = arg
			if cmd != "/terreno":
				value = arg.to_float()
			var r: Dictionary = env.set_values({key: value})
			ui.add_chat("Sistema", r.text)
			if r.ok:
				team.broadcast_context("[Il giocatore ha cambiato l'ambiente: %s]" % env.describe())
				history.commit("giocatore", "ambiente: " + env.describe(), "env")
		"/blueprint":
			var bp_name := arg.get_slice(" ", 0)
			var r: Dictionary = {"ok": false, "text": "Mira un oggetto e scrivi /blueprint nome descrizione."}
			if player.looking_at_id != "" and bp_name != "":
				r = World.save_blueprint({"id": player.looking_at_id, "name": bp_name, "description": arg.substr(bp_name.length()).strip_edges()}, "player")
			ui.add_chat("Sistema", r.text)
		"/piazza":
			var f: Vector3 = player.get_forward()
			f.y = 0.0
			var pos: Vector3 = player.looking_point if player.has_point else player.global_position + f.normalized() * 5.0
			var r: Dictionary = World.spawn_blueprint({"name": arg, "position": [pos.x, maxf(pos.y, 0.0), pos.z], "rotation_deg": [0, rad_to_deg(player.rotation.y), 0]}, "player")
			ui.add_chat("Sistema", r.text)
			if r.ok:
				history.commit("giocatore", "piazzato blueprint " + arg)
				team.broadcast_context("[Il giocatore ha piazzato il blueprint '%s' come %s]" % [arg, r.id])
		"/blueprints":
			var names := PackedStringArray()
			for bp in World.list_blueprints():
				names.append("%s%s" % [bp.name, (" (" + bp.description + ")") if bp.description != "" else ""])
			ui.add_chat("Sistema", "Blueprint: " + (", ".join(names) if not names.is_empty() else "nessuno. Mira un oggetto e usa /blueprint nome descrizione"))
		"/reset":
			World.reset_world()
			history.commit("giocatore", "mondo svuotato")
			ui.add_chat("Sistema", "Mondo svuotato (Ctrl+Z per tornare indietro).")
			team.broadcast_context("[Il giocatore ha svuotato completamente il mondo con /reset. Anche la lavagna è stata cancellata.]")
		"/auto":
			_toggle_autonomy()
		"/ui":
			if arg.is_valid_float():
				ui.set_ui_scale(arg.to_float())
			ui.add_chat("Sistema", "Scala dell'interfaccia: %.2f (es. /ui 1.2 per ingrandire, /ui 0.9 per rimpicciolire)." % ui.ui_scale)
		"/segui":
			team.set_follow(not team.follow)
			ui.add_chat("Sistema", "Gli agenti " + ("ti seguono." if team.follow else "restano dove lavorano."))
		"/clear":
			team.clear_histories()
			ui.add_chat("Sistema", "Gli agenti hanno dimenticato la conversazione (il mondo e la lavagna restano).")
		"/agenti":
			for b in team.brains:
				ui.add_chat(b.agent_name, "%s[%s] %s" % ["(lead) " if b.is_lead else "", b.model, b.role])
		"/nuovo":
			_create_agent(arg)
		"/rimuovi":
			var err: String = team.remove_agent(arg)
			ui.add_chat("Sistema", err if err != "" else "%s ha lasciato la squadra." % arg)
		"/salva":
			save_world(arg if arg != "" else "mondo", true)
		"/carica":
			load_world(arg if arg != "" else "mondo", true)
		"/salvataggi":
			var names := PackedStringArray()
			for f in DirAccess.get_files_at(SAVE_DIR):
				if f.ends_with(".json"):
					names.append(f.get_basename())
			ui.add_chat("Sistema", "Salvataggi: " + (", ".join(names) if not names.is_empty() else "nessuno"))
		_:
			ui.add_chat("Sistema", HELP_TEXT)


func _create_agent(arg: String) -> void:
	var i := arg.find(":")
	if i <= 0:
		ui.add_chat("Sistema", "Uso: /nuovo Nome: descrizione del ruolo (es. /nuovo Giardiniere: si occupa di alberi, fiori e parchi)")
		return
	var agent_name := arg.substr(0, i).strip_edges()
	var role := arg.substr(i + 1).strip_edges()
	var err: String = team.spawn_agent({"name": agent_name, "role": role}, true)
	if err != "":
		ui.add_chat("Sistema", err)
		return
	var b = team.find_brain(agent_name)
	ui.add_chat("Sistema", "Benvenuto %s nella squadra." % b.agent_name)
	for other in team.brains:
		if other != b:
			other.add_context("[Il giocatore ha creato un nuovo agente, %s, con questo ruolo: %s]" % [b.agent_name, role])
	if team.api_key != "":
		b.queue_event("[Sei appena stato creato dal giocatore. Presentati in una frase con say e, se ha senso, proponi o chiedi cosa fare. Non costruire ancora.]")


func _on_run_code(code: String) -> void:
	var f: Vector3 = player.get_forward()
	f.y = 0.0
	if f.length() < 0.01:
		f = Vector3.FORWARD
	var pos: Vector3 = player.global_position + f.normalized() * 4.0 + Vector3.UP * 1.0
	var r := World.run_script({"code": code, "position": [pos.x, pos.y, pos.z], "name": "creazione del giocatore"}, "player")
	ui.show_code_result(r.ok, r.text)
	if r.ok:
		history.commit("giocatore", "console: " + str(r.text).get_slice("\n", 0))
		ui.add_chat("Sistema", "Hai eseguito il tuo codice: " + str(r.text).get_slice("\n", 0))
		team.broadcast_context("[Il giocatore ha eseguito codice dalla sua console. Risultato: %s]\n```gdscript\n%s\n```" % [r.text, code])


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
		DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(_save_path(AUTOSAVE + "_precedente")))
	var err := World.save_json(path, data)
	if verbose or err != "":
		ui.add_chat("Sistema", err if err != "" else "Mondo salvato in saves/%s.json (%d oggetti)." % [save_name.validate_filename(), World.entities.size()])
	return err == ""


func load_world(save_name: String, _verbose: bool) -> bool:
	var data = World.load_json(_save_path(save_name))
	if data == null:
		ui.add_chat("Sistema", "Salvataggio '%s' non trovato o non valido." % save_name)
		return false
	var problems := World.deserialize(data)
	team.apply_save(data.get("agents", {}))
	var pl: Dictionary = data.get("player", {})
	if pl.has("position"):
		player.position = World.vec3(pl["position"], player.position)
		player.rotation.y = float(pl.get("rot_y", 0.0))
		player.velocity = Vector3.ZERO
	team.clear_histories()
	history.reset("caricato '%s'" % save_name)
	team.broadcast_context("[Il mondo è stato caricato dal salvataggio '%s'.]" % save_name)
	ui.add_chat("Sistema", "Caricato '%s': %d oggetti%s." % [save_name, World.entities.size(), "" if problems.is_empty() else ", %d problemi" % problems.size()])
	for p in problems.slice(0, 5):
		ui.add_chat("Sistema", str(p).get_slice("\n", 0))
	return true
