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
	"claude-sonnet-5-5": [2.0, 10.0, 2.5, 0.10],
	"claude-opus-5-5": [4.0, 20.0, 5.0, 0.40],
}
const PALETTE := ["#c792ea", "#ff6b9a", "#ffd166", "#06d6a0", "#f78c6b", "#a0c4ff"]

var ui
var api_key := ""
var autonomy := true
var follow := true
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
	brain.is_lead = def.get("lead", false) == true
	brain.is_custom = custom
	brain.is_reviewer = def.get("reviewer", false) == true
	add_child(brain)
	brain.status_changed.connect(body.set_status)
	brain.said.connect(_on_said)

	brains.append(brain)
	World.agents[agent_name] = body
	if ui:
		ui.set_author_color(agent_name, color)
	return ""


func remove_agent(agent_name: String) -> String:
	var b = find_brain(agent_name)
	if b == null:
		return "Nessun agente si chiama '%s'." % agent_name
	brains.erase(b)
	World.agents.erase(b.agent_name)
	b.body.queue_free()
	b.queue_free()
	for other in brains:
		other.add_context("[%s ha lasciato la squadra]" % b.agent_name)
	return ""


func find_brain(agent_name: String):
	var n := agent_name.strip_edges().trim_prefix("@").to_lower()
	for b in brains:
		if b.agent_name.to_lower() == n:
			return b
	return null


func lead():
	for b in brains:
		if b.is_lead:
			return b
	return brains[0] if not brains.is_empty() else null


func lead_name() -> String:
	var l = lead()
	return l.agent_name if l else "nessuno"


func names_list() -> String:
	return ", ".join(PackedStringArray(brains.map(func(b): return b.agent_name)))


func describe_team(viewer) -> String:
	var lines := PackedStringArray()
	for b in brains:
		var tag := " (tu)" if b == viewer else ""
		if b.is_lead:
			tag += " [lead]"
		lines.append("- %s%s: %s" % [b.agent_name, tag, b.role])
	return "\n".join(lines)


func status_line() -> String:
	var parts := PackedStringArray()
	for b in brains:
		parts.append("%s · %s" % [b.agent_name, b.status_text if b.status_text != "" else "in ascolto"])
	return "\n".join(parts)


# ---------------------------------------------------------------- costs

func add_usage(brain, model_name: String, u: Dictionary, images: int) -> void:
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
	spent_usd += usd
	_log_usage(brain.agent_name, model_name, inp, out, cw, cr, images, usd)
	if over_budget() and not _budget_warned:
		_budget_warned = true
		autonomy = false
		World.chat_message.emit("Sistema", "Tetto di spesa raggiunto ($%.2f su $%.2f): gli agenti si fermano. Alzalo con /budget N (in dollari)." % [spent_usd, budget_usd])


const USAGE_LOG := "res://logs/usage.csv"


## One line per API call, to see where the money goes (open it with any spreadsheet).
func _log_usage(agent_name: String, model_name: String, inp: int, out: int, cw: int, cr: int, images: int, usd: float) -> void:
	var path := ProjectSettings.globalize_path(USAGE_LOG)
	var is_new := not FileAccess.file_exists(path)
	if is_new:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE if not is_new else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	if is_new:
		f.store_line("time,agent,model,input,output,cache_write,cache_read,images,usd")
	f.store_line("%s,%s,%s,%d,%d,%d,%d,%d,%.6f" % [Time.get_datetime_string_from_system(), agent_name, model_name, inp, out, cw, cr, images, usd])
	f.close()


func over_budget() -> bool:
	return budget_usd > 0.0 and spent_usd >= budget_usd


func set_budget(usd: float) -> void:
	budget_usd = maxf(usd, 0.0)
	_budget_warned = false


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
			targets = brains.duplicate()
			break
		var b = find_brain(who)
		if b != null and not b in targets:
			targets.append(b)
	if targets.is_empty():
		targets = [lead()]
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
		if b.is_reviewer:
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
	for b in brains:
		if b.is_custom:
			custom.append(b.to_def())
		positions[b.agent_name] = World._arr(b.body.position)
	return {"custom": custom, "positions": positions}


func apply_save(data: Dictionary) -> void:
	for b in brains.duplicate():
		if b.is_custom:
			remove_agent(b.agent_name)
	for def in data.get("custom", []):
		if def is Dictionary:
			spawn_agent(def, true)
	var positions: Dictionary = data.get("positions", {})
	for b in brains:
		if positions.has(b.agent_name):
			var p := World.vec3(positions[b.agent_name], b.body.position)
			b.body.position = p
