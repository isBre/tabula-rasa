extends Node
## The team of AI agents: roles from agents.json, agents created in game,
## routing of messages between the player and the agents.

const BrainScript := preload("res://scripts/agent_brain.gd")
const BodyScript := preload("res://scripts/agent.gd")
const PhotographerScript := preload("res://scripts/photographer.gd")
const WalkTesterScript := preload("res://scripts/walk_tester.gd")
const ROLES_FILE := "res://agents.json"
const MAX_AGENTS := 8
const REVIEW_DELAY := 6.0          # seconds after a teammate finishes before the critic looks
const REVIEWS_PER_PLAYER_MESSAGE := 3
const REVIEWED_ACTIONS := ["run_script", "spawn_blueprint", "edit_script", "attach_script", "spawn_primitive"]
const DEFAULT_BUDGET_USD := 2.0

## USD per million tokens: [input, output, cache write (5 min), cache read].
## Haiku 5.5 costs 5x for prompts over 100K tokens. Estimates: check the official pricing page.
const PRICES := {
	"claude-haiku-5-5": [0.10, 0.50, 0.125, 0.01],
	"claude-sonnet-5-5": [2.0, 10.0, 2.5, 0.20],
	"claude-opus-5-5": [4.0, 20.0, 5.0, 0.40],
}
## Models the player can choose for an agent (menu > Agenti).
const MODEL_CHOICES := {
	"claude-haiku-5-5": "Haiku 5.5 · veloce ed economico",
	"claude-sonnet-5-5": "Sonnet 5.5 · più bravo",
	"claude-opus-5-5": "Opus 5.5 · il più capace, costoso",
}
const SETTINGS_PATH := "user://settings.cfg"
const PALETTE := ["#c792ea", "#ff6b9a", "#ffd166", "#06d6a0", "#f78c6b", "#a0c4ff"]

var ui
var api_key := ""
var autonomy := false       # builders act on their own only when the player turns it on (P or menu)
var npc_autonomy := false   # same for the NPCs (agents that can't build): they live their life
var follow := true
## When on, the stronger "model_for_player" is used only for the first call of a player
## turn (understand the request, plan, delegate); the following tool steps use the base model.
var strong_plan_only := true
var usage_by_model := {}   # model id -> {calls, usd}
var output_by_kind := {}   # OUTPUT_KINDS key -> {tokens, usd} (estimated split of the output)
## What the agents' output tokens go into (estimated from the length of each reply block).
const OUTPUT_KINDS := {
	"a_te": "Messaggi a te",
	"tra_agenti": "Messaggi tra agenti",
	"pensieri": "Pensieri (testo libero)",
	"codice": "Codice (script)",
	"modelli": "Modelli 3D (ricette)",
	"lavagna": "Lavagna",
	"strumenti": "Altri strumenti (piazzare, misurare, foto...)",
}
var _review_queue: Array = []
var _review_timer: SceneTreeTimer
var _review_budget := REVIEWS_PER_PLAYER_MESSAGE
var brains: Array = []
var history    # history.gd
var budget_usd := DEFAULT_BUDGET_USD
var spent_usd := 0.0
var usage := {}   # agent name -> {calls, input, output, cache_write, cache_read, images, usd}
var _budget_warned := false
var photographer
var walk_tester

var _mention_re := RegEx.new()


func _ready() -> void:
	_mention_re.compile("@([^\\s,.:;!?]+)")
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		strong_plan_only = bool(cfg.get_value("costs", "strong_plan_only", true))
		budget_usd = maxf(float(cfg.get_value("costs", "budget", DEFAULT_BUDGET_USD)), 0.0)
	photographer = PhotographerScript.new()
	photographer.name = "Photographer"
	add_child(photographer)
	walk_tester = WalkTesterScript.new()
	walk_tester.name = "WalkTester"
	add_child(walk_tester)


func load_api_key() -> void:
	api_key = OS.get_environment("ANTHROPIC_API_KEY").strip_edges()
	if api_key == "":
		for path in ["res://api_key.txt", "user://api_key.txt"]:
			if FileAccess.file_exists(path):
				api_key = FileAccess.get_file_as_string(path).strip_edges()
				if api_key != "":
					break


func load_default_agents() -> void:
	var data = World.load_json(ROLES_FILE)
	if data == null:
		World.chat_message.emit("Sistema", "agents.json mancante o non valido: nessun agente predefinito.")
		return
	for def in data.get("agents", []):
		if def is Dictionary:
			var err := spawn_agent(def, false)
			if err != "":
				World.chat_message.emit("Sistema", err)


# ---------------------------------------------------------------- agents

func spawn_agent(def: Dictionary, custom: bool) -> String:
	if brains.size() >= MAX_AGENTS:
		return "Massimo %d agenti." % MAX_AGENTS
	var agent_name := str(def.get("name", "")).strip_edges().replace(" ", "_")
	if agent_name == "" or agent_name.length() > 20 or "@" in agent_name:
		return "Nome agente non valido: '%s'." % agent_name
	agent_name = agent_name[0].to_upper() + agent_name.substr(1)
	if find_brain(agent_name) != null or agent_name.to_lower() in ["tutti", "giocatore", "player", "tu", "sistema"]:
		return "Esiste già un agente (o una parola riservata) '%s'." % agent_name
	var role := str(def.get("role", "")).strip_edges()
	if role == "":
		return "Serve una descrizione del ruolo per %s." % agent_name
	var color := Color.from_string(str(def.get("color", "")), Color.from_string(PALETTE[brains.size() % PALETTE.size()], Color.WHITE))

	var body = BodyScript.new()
	body.agent_name = agent_name
	body.color = color
	body.name = "Agent_" + agent_name
	body.team = self
	body.follow_slot = brains.size()
	body.can_fly = def.get("can_build", true) != false
	if def.get("look") is Dictionary:
		body.look = def["look"].duplicate()
	elif not custom:
		body.look = _saved_look(agent_name)
	var angle := brains.size() * TAU / 6.0 + 0.4
	body.position = World.vec3(def.get("position"), Vector3(cos(angle) * 4.0, 1.6, sin(angle) * 4.0 - 1.0))
	add_child(body)

	var brain = BrainScript.new()
	brain.name = "Brain_" + agent_name
	brain.team = self
	brain.body = body
	brain.agent_name = agent_name
	brain.role = role
	brain.color = color
	brain.model = str(def.get("model", BrainScript.DEFAULT_MODEL))
	brain.current_model = brain.model
	brain.model_for_player = str(def.get("model_for_player", ""))
	brain.is_lead = def.get("lead", false) == true
	brain.is_custom = custom
	brain.is_reviewer = def.get("reviewer", false) == true
	brain.can_build = def.get("can_build", true) != false
	brain.can_model = def.get("can_model", true) != false
	brain.can_see = def.get("can_see", true) != false
	if not custom:
		_apply_model_choice(brain)
	add_child(brain)
	brain.status_changed.connect(body.set_status)
	brain.said.connect(_on_said)

	brains.append(brain)
	World.agents[agent_name] = body
	if ui:
		ui.set_author_color(agent_name, color)
	if def.get("hidden", false) == true:
		set_hidden(brain, true, true)
	return ""


func remove_agent(agent_name: String, silent := false) -> String:
	var b = find_brain(agent_name)
	if b == null:
		return "Nessun agente si chiama '%s'." % agent_name
	if not b.is_custom and not silent:
		return "%s è un agente predefinito: puoi nasconderlo dal menu (Esc > Agenti), non rimuoverlo." % b.agent_name
	brains.erase(b)
	World.agents.erase(b.agent_name)
	b.body.queue_free()
	b.queue_free()
	if not silent:
		for other in brains:
			other.add_context("[%s ha lasciato la squadra]" % b.agent_name)
	return ""


## Hidden agents disappear from the world and stop acting until shown again.
func set_hidden(b, on: bool, quiet := false) -> void:
	b.hidden = on
	b.body.visible = not on
	b.body.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT
	if on:
		World.agents.erase(b.agent_name)
		b.status_text = ""
	else:
		World.agents[b.agent_name] = b.body
	if quiet:
		return
	for other in brains:
		if other != b:
			other.add_context("[%s %s]" % [b.agent_name, "si è assentato: per ora non risponde e non lavora" if on else "è tornato nel mondo"])


## Changes a custom agent (role, color, models, permissions): it is rebuilt where it stood.
func update_agent(agent_name: String, def: Dictionary) -> String:
	var b = find_brain(agent_name)
	if b == null:
		return "Nessun agente si chiama '%s'." % agent_name
	if not b.is_custom:
		return "Gli agenti predefiniti non si modificano (puoi cambiarne il modello o nasconderli)."
	var pos: Vector3 = b.body.position
	var was_hidden: bool = b.hidden
	var d: Dictionary = b.to_def()
	d.merge(def, true)
	d["name"] = b.agent_name
	d["position"] = World._arr(pos)
	d["hidden"] = was_hidden
	var idx := brains.find(b)
	remove_agent(agent_name, true)
	var err := spawn_agent(d, true)
	if err != "":
		return err
	# keep its place in the list
	var nb = brains.pop_back()
	brains.insert(idx, nb)
	for other in brains:
		if other != nb:
			other.add_context("[Il giocatore ha cambiato %s. Ruolo ora: %s]" % [nb.agent_name, nb.role])
	return ""


## Model choice for an agent. Built-in agents remember it on this computer, custom ones in
## the world save.
func set_models(b, model_id: String, for_player: String) -> void:
	b.model = model_id
	b.current_model = model_id
	b.model_for_player = for_player
	if b.is_custom:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("models", b.agent_name, [model_id, for_player])
	cfg.save(SETTINGS_PATH)


## Appearance (menu > Agenti > Modifica). Built-in agents remember it on this computer,
## custom ones in the world save.
func set_look(b, look: Dictionary) -> void:
	b.body.set_look(look)
	if b.is_custom:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("looks", b.agent_name, look)
	cfg.save(SETTINGS_PATH)


func _saved_look(agent_name: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK or not cfg.has_section_key("looks", agent_name):
		return {}
	var v = cfg.get_value("looks", agent_name)
	return v if v is Dictionary else {}


func _apply_model_choice(b) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK or not cfg.has_section_key("models", b.agent_name):
		return
	var v = cfg.get_value("models", b.agent_name)
	if v is Array and v.size() == 2 and MODEL_CHOICES.has(str(v[0])):
		b.model = str(v[0])
		b.current_model = b.model
		b.model_for_player = str(v[1])


func model_label(model_id: String) -> String:
	return str(MODEL_CHOICES.get(model_id, model_id)).get_slice(" ·", 0)


func find_brain(agent_name: String):
	var n := agent_name.strip_edges().trim_prefix("@").to_lower()
	for b in brains:
		if b.agent_name.to_lower() == n:
			return b
	return null


func lead():
	for b in brains:
		if b.is_lead and not b.hidden:
			return b
	for b in brains:
		if not b.hidden and b.can_build and not b.is_reviewer:
			return b
	for b in brains:
		if not b.hidden:
			return b
	return null


func lead_name() -> String:
	var l = lead()
	return l.agent_name if l else "nessuno"


func names_list() -> String:
	return ", ".join(PackedStringArray(brains.map(func(b): return b.agent_name)))


func describe_team(viewer) -> String:
	var lines := PackedStringArray()
	for b in brains:
		if b.hidden:
			continue
		var tag := " (tu)" if b == viewer else ""
		if b.is_lead:
			tag += " [lead]"
		if not b.can_build:
			tag += " [NPC: non costruisce]"
		elif not b.can_model:
			tag += " [non crea modelli]"
		lines.append("- %s%s: %s" % [b.agent_name, tag, b.role])
	return "\n".join(lines)


func status_line() -> String:
	var parts := PackedStringArray()
	for b in brains:
		if not b.hidden:
			parts.append("%s · %s" % [b.agent_name, b.status_text if b.status_text != "" else "in ascolto"])
	return "\n".join(parts)


## The agents' rows of the HUD (bbcode table: name in its color, what it's doing).
func status_bbcode() -> String:
	var rows := ""
	for b in brains:
		if b.hidden:
			continue
		var st: String = b.status_text
		var name_col: String = b.color.lightened(0.15).to_html(false)
		var npc := " [color=#7d8799][font_size=11]NPC[/font_size][/color]" if not b.can_build else ""
		rows += "[cell][color=#%s][b]%s[/b][/color]%s[/cell][cell][color=%s]%s[/color][/cell]" % [name_col, b.agent_name, npc, "#ffd27a" if st != "" else "#6f7888", st if st != "" else "in ascolto"]
	return "[table=2]" + rows + "[/table]" if rows != "" else "[color=#6f7888]nessun agente attivo[/color]"


# ---------------------------------------------------------------- costs

func add_usage(brain, model_name: String, u: Dictionary, images: int, split := {}) -> void:
	var inp := int(u.get("input_tokens", 0))
	var out := int(u.get("output_tokens", 0))
	var cw := int(u.get("cache_creation_input_tokens", 0))
	var cr := int(u.get("cache_read_input_tokens", 0))
	var p: Array = PRICES.get(model_name, PRICES["claude-haiku-5-5"])
	var mult := 5.0 if model_name.begins_with("claude-haiku") and inp + cw + cr > 100000 else 1.0
	var usd: float = (inp * p[0] + out * p[1] + cw * p[2] + cr * p[3]) * mult / 1000000.0
	var rec: Dictionary = usage.get(brain.agent_name, {"calls": 0, "input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "images": 0, "usd": 0.0})
	rec["calls"] += 1
	rec["input"] += inp
	rec["output"] += out
	rec["cache_write"] += cw
	rec["cache_read"] += cr
	rec["images"] += images
	rec["usd"] += usd
	usage[brain.agent_name] = rec
	var mrec: Dictionary = usage_by_model.get(model_name, {"calls": 0, "usd": 0.0})
	mrec["calls"] += 1
	mrec["usd"] += usd
	usage_by_model[model_name] = mrec
	var out_kinds := split_output(out, split)
	for k in out_kinds:
		var krec: Dictionary = output_by_kind.get(k, {"tokens": 0, "usd": 0.0})
		krec["tokens"] += out_kinds[k]
		krec["usd"] += out_kinds[k] * p[1] * mult / 1000000.0
		output_by_kind[k] = krec
	spent_usd += usd
	_log_usage(brain.agent_name, model_name, inp, out, cw, cr, images, usd, out_kinds)
	if over_budget() and not _budget_warned:
		_budget_warned = true
		autonomy = false
		World.chat_message.emit("Sistema", "Tetto di spesa raggiunto ($%.2f su $%.2f): gli agenti si fermano. Alzalo con /budget N (in dollari)." % [spent_usd, budget_usd])


const USAGE_LOG := "res://logs/usage.csv"


## One line per API call, to see where the money goes (open it with any spreadsheet).
func _log_usage(agent_name: String, model_name: String, inp: int, out: int, cw: int, cr: int, images: int, usd: float, out_kinds := {}) -> void:
	var path := ProjectSettings.globalize_path(USAGE_LOG)
	var is_new := not FileAccess.file_exists(path)
	if is_new:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE if not is_new else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	if is_new:
		f.store_line("time,agent,model,input,output,cache_write,cache_read,images,usd,output_split")
	var parts := PackedStringArray()
	for k in out_kinds:
		parts.append("%s:%d" % [k, out_kinds[k]])
	f.store_line("%s,%s,%s,%d,%d,%d,%d,%d,%.6f,%s" % [Time.get_datetime_string_from_system(), agent_name, model_name, inp, out, cw, cr, images, usd, ";".join(parts)])
	f.close()


func over_budget() -> bool:
	return budget_usd > 0.0 and spent_usd >= budget_usd


## Splits the output tokens of a call by kind, in proportion to the characters of each kind.
static func split_output(out_tokens: int, chars: Dictionary) -> Dictionary:
	var total := 0
	for k in chars:
		total += int(chars[k])
	var res := {}
	if total <= 0 or out_tokens <= 0:
		return res
	var given := 0
	var keys: Array = chars.keys()
	for i in keys.size():
		var n: int = out_tokens - given if i == keys.size() - 1 else roundi(out_tokens * float(chars[keys[i]]) / total)
		res[keys[i]] = n
		given += n
	return res


## Output price of a model, with the long-context multiplier of Haiku.
func output_price(model_name: String, context_tokens: int) -> float:
	var p: Array = PRICES.get(model_name, PRICES["claude-haiku-5-5"])
	var mult := 5.0 if model_name.begins_with("claude-haiku") and context_tokens > 100000 else 1.0
	return p[1] * mult / 1000000.0


func set_strong_plan_only(on: bool) -> void:
	strong_plan_only = on
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("costs", "strong_plan_only", on)
	cfg.save(SETTINGS_PATH)


## Every call ever logged in logs/usage.csv, as dictionaries (for the Costi tab).
func read_usage_log() -> Array:
	var out: Array = []
	var path := ProjectSettings.globalize_path(USAGE_LOG)
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	f.get_line()  # header
	while not f.eof_reached():
		var parts := f.get_line().split(",")
		if parts.size() < 9:
			continue
		var kinds := {}
		if parts.size() >= 10:
			for item in parts[9].split(";", false):
				var kv := item.split(":")
				if kv.size() == 2:
					kinds[kv[0]] = int(kv[1])
		out.append({"time": parts[0], "agent": parts[1], "model": parts[2], "input": int(parts[3]), "output": int(parts[4]),
			"cache_write": int(parts[5]), "cache_read": int(parts[6]), "images": int(parts[7]), "usd": float(parts[8]), "out_kinds": kinds})
	f.close()
	return out


func set_budget(usd: float, remember := true) -> void:
	budget_usd = maxf(usd, 0.0)
	_budget_warned = false
	if not remember:
		return
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("costs", "budget", budget_usd)
	cfg.save(SETTINGS_PATH)


func costs_text() -> String:
	var lines := PackedStringArray(["Spesa stimata della sessione: $%.4f (tetto $%.2f)" % [spent_usd, budget_usd]])
	for agent_name in usage:
		var r: Dictionary = usage[agent_name]
		lines.append("- %s: $%.4f · %d chiamate · input %d (+ cache: scritti %d, letti %d) · output %d · immagini %d" % [agent_name, r["usd"], r["calls"], r["input"], r["cache_write"], r["cache_read"], r["output"], r["images"]])
	return "\n".join(lines)


# ---------------------------------------------------------------- messages

func route_player_message(text: String) -> void:
	if brains.is_empty():
		World.chat_message.emit("Sistema", "Non c'è nessun agente: creane uno con /nuovo Nome: descrizione")
		return
	if api_key == "":
		World.chat_message.emit("Sistema", "Gli agenti non hanno una API key: vedi README (api_key.txt o ANTHROPIC_API_KEY).")
		return
	var targets: Array = []
	for m in _mention_re.search_all(text):
		var who := m.get_string(1).to_lower()
		if who == "tutti":
			targets = brains.filter(func(x): return not x.hidden)
			break
		var b = find_brain(who)
		if b != null and b.hidden:
			World.chat_message.emit("Sistema", "%s è nascosto: rimostralo dal menu (Esc > Agenti) per parlargli." % b.agent_name)
			continue
		if b != null and not b in targets:
			targets.append(b)
	if targets.is_empty():
		var l = lead()
		if l == null:
			World.chat_message.emit("Sistema", "Tutti gli agenti sono nascosti.")
			return
		targets = [l]
	_review_budget = REVIEWS_PER_PLAYER_MESSAGE
	var names := PackedStringArray(targets.map(func(b): return b.agent_name))
	for b in brains:
		b.reset_agent_budget()
		if b in targets:
			b.queue_event("[Il giocatore ti dice]: " + text)
		else:
			b.add_context("[Il giocatore ha detto a %s]: %s" % [", ".join(names), text])


func _on_said(from, to: String, text: String) -> void:
	var target = find_brain(to) if to != "" and to.to_lower() != "tutti" else null
	var label: String = from.agent_name
	if target != null:
		label += " → " + target.agent_name
	elif to.to_lower() == "tutti":
		label += " → tutti"
	World.chat_message.emit(label, text)
	for b in brains:
		if b == from:
			continue
		if b == target:
			b.queue_agent_event("[%s ti dice]: %s" % [from.agent_name, text])
		else:
			var dest: String = "a " + target.agent_name if target != null else ("a tutti" if to != "" else "al giocatore")
			b.add_context("[%s ha detto %s]: %s" % [from.agent_name, dest, text])


## Called by an agent when its turn ends. Significant work by a builder triggers the
## reviewer (if any) after a short delay, a few times per player message at most.
func on_turn_finished(brain, actions: Array) -> void:
	if brain.is_reviewer or _review_budget <= 0:
		return
	var reviewer = null
	for b in brains:
		if b.is_reviewer and not b.hidden:
			reviewer = b
			break
	if reviewer == null:
		return
	var relevant := actions.filter(func(a): return str(a).get_slice(" ", 0) in REVIEWED_ACTIONS)
	if relevant.is_empty():
		return
	_review_queue.append("%s: %s" % [brain.agent_name, ", ".join(PackedStringArray(relevant))])
	_review_timer = get_tree().create_timer(REVIEW_DELAY)
	var my_timer := _review_timer
	await my_timer.timeout
	if my_timer != _review_timer or _review_queue.is_empty() or _review_budget <= 0:
		return  # a newer finish restarted the delay
	_review_budget -= 1
	var work := "; ".join(PackedStringArray(_review_queue))
	_review_queue.clear()
	reviewer.queue_event("[Revisione automatica] Lavoro appena finito da controllare: %s. Ispeziona gli oggetti nuovi o modificati (measure, inspect_visual, walk_test se sono da percorrere). Se trovi problemi concreti scrivi all'autore con say(to=Nome) cosa correggere e dove. Se è tutto a posto non scrivere a nessuno: rispondi solo con una breve frase di testo." % work)


func set_follow(on: bool) -> void:
	follow = on
	if on:
		for b in brains:
			if not b.busy:
				b.body.release_after(0.0)


func reset_all() -> void:
	_review_queue.clear()
	_review_budget = REVIEWS_PER_PLAYER_MESSAGE
	for b in brains:
		b.reset_all()


func broadcast_context(text: String) -> void:
	for b in brains:
		b.add_context(text)


func clear_histories() -> void:
	for b in brains:
		b.clear_history()


# ---------------------------------------------------------------- save / load

func serialize() -> Dictionary:
	var custom := []
	var positions := {}
	var hidden := []
	for b in brains:
		if b.is_custom:
			custom.append(b.to_def())
		elif b.hidden:
			hidden.append(b.agent_name)
		positions[b.agent_name] = World._arr(b.body.position)
	return {"custom": custom, "positions": positions, "hidden": hidden}


func apply_save(data: Dictionary) -> void:
	for b in brains.duplicate():
		if b.is_custom:
			remove_agent(b.agent_name)
	for def in data.get("custom", []):
		if def is Dictionary:
			spawn_agent(def, true)
	var hidden: Array = data.get("hidden", [])
	for b in brains:
		if not b.is_custom and b.hidden != (b.agent_name in hidden):
			set_hidden(b, b.agent_name in hidden, true)
	var positions: Dictionary = data.get("positions", {})
	for b in brains:
		if positions.has(b.agent_name):
			var p := World.vec3(positions[b.agent_name], b.body.position)
			b.body.position = p
