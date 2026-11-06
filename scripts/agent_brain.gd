extends Node
## One agent's mind: talks to the Claude API with tool use and acts on the world.
## Created and wired by team.gd.

signal status_changed(text: String)
signal said(brain: Node, to: String, text: String)

const API_URL := "https://api.anthropic.com/v1/messages"
const DEFAULT_MODEL := "claude-haiku-5-5"
const MAX_TOKENS := 8000
const MAX_STEPS := 10              # tool rounds per turn
const AUTONOMY_INTERVAL := 50.0    # seconds of idle before a free-time turn...
const AUTONOMY_JITTER := 40.0      # ...plus a random amount, so agents don't all wake together
const MAX_AUTONOMOUS_TURNS := 3    # free-time turns in a row without new events
const AGENT_BUDGET := 4            # turns other agents can trigger between two player messages
const KEEP_MESSAGES := 30
const STATE_MARK := "\n\n=== STATO DEL MONDO ===\n"
const MUTATING := ["spawn_asset", "spawn_primitive", "modify_object", "delete_object", "run_script", "attach_script", "edit_script", "spawn_blueprint", "set_environment", "update_board"]

const AUTONOMY_PROMPT := "[Tempo libero] Nessuno ti ha scritto di recente. Se hai un'idea coerente con il tuo ruolo e con la lavagna, realizza UN piccolo passo e annuncialo con say. Se non c'è niente di utile da fare, rispondi solo con una brevissima frase di testo, senza tool."

var team   # team.gd
var body   # agent.gd
var agent_name := "Agente"
var role := ""
var model := DEFAULT_MODEL
var model_for_player := ""   # optional stronger model for turns started by the player
var current_model := DEFAULT_MODEL
var color := Color(0.3, 0.9, 1.0)
var is_lead := false
var is_custom := false
var is_reviewer := false

var busy := false
var status_text := ""
var messages: Array = []

var _pending: Array = []   # events that start a turn
var _context: Array = []   # passive events, sent with the next turn
var _http: HTTPRequest
var _steps := 0
var _retries := 0
var _idle_time := 0.0
var _next_auto := 0.0
var _auto_streak := 0
var _agent_budget := AGENT_BUDGET
var _turn_actions: Array = []
var _epoch := 0   # bumped by reset_all(): late answers from before a reset are ignored
var _request_epoch := 0
var _images_in_request := 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 180.0
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_next_auto = AUTONOMY_INTERVAL + randf() * AUTONOMY_JITTER


func has_key() -> bool:
	return team != null and team.api_key != ""


func to_def() -> Dictionary:
	return {"name": agent_name, "role": role, "model": model, "model_for_player": model_for_player, "color": "#" + color.to_html(false), "lead": is_lead, "reviewer": is_reviewer}


# ---------------------------------------------------------------- events

## An event that wakes the agent up (player message, greeting, ...).
func queue_event(text: String) -> void:
	_pending.append(text)
	_auto_streak = 0
	_try_start()


## A message from another agent: wakes this agent only while the budget lasts.
func queue_agent_event(text: String) -> void:
	if _agent_budget > 0:
		_agent_budget -= 1
		queue_event(text)
	else:
		add_context(text + " (limite di scambi tra agenti raggiunto: potrai rispondere quando il giocatore riparla)")


func reset_agent_budget() -> void:
	_agent_budget = AGENT_BUDGET


func add_context(text: String) -> void:
	_context.append(text)
	if _context.size() > 25:
		_context.pop_front()


func clear_history() -> void:
	messages.clear()


## Forgets everything and drops any request in flight (used by the full reset).
func reset_all() -> void:
	_epoch += 1
	if _http:
		_http.cancel_request()
	messages.clear()
	_pending.clear()
	_context.clear()
	_turn_actions.clear()
	_images_in_request = 0
	_auto_streak = 0
	_idle_time = 0.0
	reset_agent_budget()
	busy = false
	_set_status("")
	body.say("")


func _process(delta: float) -> void:
	if busy or not has_key():
		return
	_idle_time += delta
	if team.autonomy and _auto_streak < MAX_AUTONOMOUS_TURNS and _idle_time >= _next_auto:
		_auto_streak += 1
		_next_auto = AUTONOMY_INTERVAL + randf() * AUTONOMY_JITTER
		_pending.append(AUTONOMY_PROMPT)
		_try_start()


func _set_status(t: String) -> void:
	status_text = t
	status_changed.emit(t)


# ---------------------------------------------------------------- turn loop

func _try_start() -> void:
	if busy or _pending.is_empty() or not has_key():
		return
	if team.over_budget():
		_pending.clear()
		_set_status("fermo: tetto di spesa")
		return
	_strip_old_states()
	var player_turn := _pending.any(func(p): return str(p).begins_with("[Il giocatore ti dice]"))
	current_model = model_for_player if player_turn and model_for_player != "" else model
	var text := "\n".join(PackedStringArray(_context + _pending)) + STATE_MARK + World.describe(agent_name)
	_context.clear()
	_pending.clear()
	var block := {"type": "text", "text": text}
	if not messages.is_empty() and messages[-1]["role"] == "user":
		messages[-1]["content"].append(block)
	else:
		messages.append({"role": "user", "content": [block]})
	busy = true
	_steps = 0
	_retries = 0
	_idle_time = 0.0
	_turn_actions.clear()
	_set_status("sta pensando...")
	_send()


func build_system_prompt() -> String:
	return SYSTEM_PROMPT.replace("{NAME}", agent_name).replace("{ROLE}", role).replace("{TEAM}", team.describe_team(self)).replace("{LEAD}", team.lead_name()).replace("{CATALOG}", Assets.index_text())


func _send() -> void:
	var tools: Array = TOOLS.duplicate(true)
	tools[-1]["cache_control"] = {"type": "ephemeral"}
	# cache breakpoint on the newest block: the next step of this turn re-reads the whole
	# conversation from cache (10% of the price) instead of paying it again
	var msgs: Array = messages.duplicate(true)
	if not msgs.is_empty() and msgs[-1]["content"] is Array and not msgs[-1]["content"].is_empty():
		msgs[-1]["content"][-1]["cache_control"] = {"type": "ephemeral"}
	var body_data := {
		"model": current_model,
		"max_tokens": MAX_TOKENS,
		"system": [{"type": "text", "text": build_system_prompt(), "cache_control": {"type": "ephemeral"}}],
		"tools": tools,
		"messages": msgs,
	}
	var headers := PackedStringArray([
		"content-type: application/json",
		"x-api-key: " + team.api_key,
		"anthropic-version: 2023-06-01",
	])
	_request_epoch = _epoch
	var err := _http.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body_data))
	if err != OK:
		_fail("Impossibile inviare la richiesta (errore %d)." % err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, raw_body: PackedByteArray) -> void:
	if not is_inside_tree() or _request_epoch != _epoch:
		return
	var raw := raw_body.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		if code in [429, 500, 502, 503, 529] and _retries < 3:
			_retries += 1
			_set_status("API occupata, riprovo...")
			await get_tree().create_timer(4.0 * _retries).timeout
			_send()
			return
		_fail("Errore API (risultato %d, HTTP %d): %s" % [result, code, raw.left(500)])
		return
	var data = JSON.parse_string(raw)
	if not data is Dictionary:
		_fail("Risposta API non leggibile.")
		return
	team.add_usage(self, current_model, data.get("usage", {}), _images_in_request)
	_images_in_request = 0
	var content: Array = clean_content(data.get("content", []))
	if content.is_empty():
		_finish()
		return
	messages.append({"role": "assistant", "content": content})

	var results: Array = []
	for block in content:
		match str(block.get("type", "")):
			"text":
				var t := str(block.get("text", "")).strip_edges()
				if t != "":
					World.chat_message.emit("Pensiero", "%s: %s" % [agent_name, t])
			"tool_use":
				var tname := str(block.get("name", ""))
				var input: Dictionary = block.get("input", {})
				if tname in ["run_script", "attach_script"]:
					_set_status("scrive codice...")
				var r: Dictionary = await _exec_tool(tname, input)
				if not is_inside_tree():
					return
				if r.ok and tname in MUTATING:
					_turn_actions.append("%s %s" % [tname, _action_label(tname, input, str(r.text))])
				if r.has("image"):
					_images_in_request += 1
					_save_photo(tname, r["image"])
				if tname != "say":
					World.chat_message.emit("Azione", "%s · %s → %s" % [agent_name, tname, str(r.text).get_slice("\n", 0).left(160)])
				var result_content: Variant = str(r.text)
				if r.has("image"):
					result_content = [
						{"type": "text", "text": str(r.text)},
						{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": r["image"]}},
					]
				results.append({
					"type": "tool_result",
					"tool_use_id": block.get("id", ""),
					"content": result_content,
					"is_error": not r.ok,
				})

	if results.is_empty():
		_finish()
		return
	messages.append({"role": "user", "content": results})
	_steps += 1
	if str(data.get("stop_reason", "")) != "tool_use" or _steps >= MAX_STEPS or team.over_budget():
		_finish()
		return
	_set_status("sta pensando...")
	_send()


## Keep only the fields the API accepts back in an assistant turn.
static func clean_content(content: Array) -> Array:
	var out: Array = []
	for block in content:
		if not block is Dictionary:
			continue
		match str(block.get("type", "")):
			"text":
				if str(block.get("text", "")) != "":
					out.append({"type": "text", "text": block["text"]})
			"tool_use":
				var input = block.get("input", {})
				out.append({"type": "tool_use", "id": block.get("id", ""), "name": block.get("name", ""), "input": input if input is Dictionary else {}})
	return out


func _action_label(tname: String, input: Dictionary, result: String) -> String:
	var m := RegEx.create_from_string("obj_\\d+").search(result)
	var id := m.get_string() if m else str(input.get("id", ""))
	match tname:
		"run_script", "spawn_primitive":
			return '%s "%s"' % [id, str(input.get("name", ""))]
		"spawn_blueprint":
			return "%s (%s)" % [str(input.get("name", "")), id]
		"delete_object":
			return str(input.get("ids", ""))
		"set_environment", "update_board":
			return ""
	return id


func _finish() -> void:
	if not _turn_actions.is_empty():
		if team.history:
			team.history.commit(agent_name, ", ".join(PackedStringArray(_turn_actions)))
		team.on_turn_finished(self, _turn_actions.duplicate())
		_turn_actions.clear()
	body.release_after(4.0)
	busy = false
	_idle_time = 0.0
	_trim()
	_set_status("")
	if not _pending.is_empty():
		_try_start.call_deferred()


func _fail(msg: String) -> void:
	if not _turn_actions.is_empty() and team.history:
		team.history.commit(agent_name, ", ".join(PackedStringArray(_turn_actions)))
		_turn_actions.clear()
	World.chat_message.emit("Sistema", "%s: %s" % [agent_name, msg])
	body.release_after(2.0)
	busy = false
	_idle_time = 0.0
	_auto_streak = MAX_AUTONOMOUS_TURNS  # pause autonomy until something happens
	_set_status("errore (vedi chat)")


func _strip_old_states() -> void:
	for m in messages:
		# code written in earlier turns is not re-sent: it can be read again with inspect_object
		if m["role"] == "assistant" and m["content"] is Array:
			for b in m["content"]:
				if b is Dictionary and b.get("type") == "tool_use" and b.get("input") is Dictionary:
					for key in ["code", "old", "new"]:
						if b["input"].has(key) and str(b["input"][key]).length() > 200:
							b["input"][key] = "(codice di un turno precedente omesso: usa inspect_object per rileggerlo)"
		if m["role"] != "user" or not m["content"] is Array:
			continue
		for b in m["content"]:
			if b is Dictionary and b.get("type") == "tool_result" and b.get("content") is Array:
				b["content"] = b["content"].map(func(c): return {"type": "text", "text": "(foto di un turno precedente omessa)"} if c is Dictionary and c.get("type") == "image" else c)
			if b is Dictionary and b.get("type") == "text":
				var t := str(b.get("text", ""))
				var i := t.find(STATE_MARK)
				if i >= 0:
					b["text"] = t.substr(0, i) + "\n(stato del mondo di quel momento omesso)"


func _trim() -> void:
	if messages.size() <= KEEP_MESSAGES:
		return
	var start := messages.size() - KEEP_MESSAGES
	while start < messages.size():
		var m = messages[start]
		if m["role"] == "user" and m["content"] is Array and not m["content"].is_empty() and m["content"][0].get("type") == "text":
			break
		start += 1
	messages = messages.slice(start)


# ---------------------------------------------------------------- vision

const PHOTO_DIR := "res://photos/"


## Keeps a copy of every image the agent looks at: photos/<date>/<time>_<agent>_<tool>.jpg
func _save_photo(tool_name: String, b64: String) -> void:
	if team.ui and team.ui.main and team.ui.main.offline:
		return  # tests don't fill your photo album
	var dt := Time.get_datetime_dict_from_system()
	var dir := ProjectSettings.globalize_path(PHOTO_DIR + "%04d-%02d-%02d" % [dt.year, dt.month, dt.day])
	DirAccess.make_dir_recursive_absolute(dir)
	var kind: String = {"take_photo": "foto", "inspect_visual": "ispezione", "preview_assets": "catalogo"}.get(tool_name, tool_name)
	var path := dir.path_join("%02d%02d%02d_%s_%s.jpg" % [dt.hour, dt.minute, dt.second, agent_name, kind])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(Marshalls.base64_to_raw(b64))
		f.close()


func _take_photo(input: Dictionary) -> Dictionary:
	_set_status("scatta una foto...")
	var pl = World.player
	var from: Vector3
	var target: Vector3
	if str(input.get("view", "self")) == "player":
		from = pl.camera.global_position
		target = from + pl.get_forward() * 10.0
	else:
		var default_target: Vector3 = pl.looking_point if pl.has_point else pl.global_position + Vector3.UP
		target = World.vec3(input.get("look_at"), default_target)
		from = World.vec3(input.get("position"), body.global_position)
		if from.distance_to(target) < 1.0:
			from = target + Vector3(0, 3, 6)
		body.move_to(from)
	# every robot is hidden during the shot, so nobody (followers included) photobombs it;
	# from the player's eyes, their own body is hidden too
	var hidden: Array = World.agents.values()
	if str(input.get("view", "self")) == "player" and pl.avatar:
		hidden.append(pl.avatar)
	var img: Image = await team.photographer.capture(from, target, hidden)
	if img == null or img.is_empty():
		return {"ok": false, "text": "La foto non è riuscita."}
	if team.ui:
		team.ui.show_photo(agent_name, img)
	var jpg := img.save_jpg_to_buffer(0.8)
	return {
		"ok": true,
		"text": "Foto scattata da %s verso %s (800x450)." % [World._v(from), World._v(target)],
		"image": Marshalls.raw_to_base64(jpg),
	}


func _inspect_visual(input: Dictionary) -> Dictionary:
	var id := str(input.get("id", ""))
	var n = World._get_entity(id)
	if n == null:
		return {"ok": false, "text": "Oggetto '%s' non trovato." % id}
	_set_status("ispeziona %s..." % id)
	var box: AABB = World.world_aabb(n)
	body.move_to(box.get_center() + Vector3(0, box.size.y * 0.5 + 1.5, box.size.z * 0.5 + 3.0))
	var sheet: Image = await team.photographer.contact_sheet(box, World.agents.values())
	if team.ui:
		team.ui.show_photo(agent_name + " (ispezione " + id + ")", sheet)
	return {
		"ok": true,
		"text": "Ispezione di %s: 4 viste inquadrate automaticamente. In alto a sinistra: fronte (da +Z). In alto a destra: lato (da +X). In basso a sinistra: retro in 3/4 (da -X -Z, dall'alto). In basso a destra: dall'alto." % id,
		"image": Marshalls.raw_to_base64(sheet.save_jpg_to_buffer(0.8)),
	}


func _walk_test(input: Dictionary) -> Dictionary:
	var pts: Array = []
	var pl = World.player
	pts.append(World.vec3(input.get("from"), pl.global_position if pl else Vector3.ZERO))
	var via = input.get("via", [])
	if via is Array:
		for v in via:
			pts.append(World.vec3(v, pts[-1]))
	if not input.has("to"):
		return {"ok": false, "text": "Serve 'to'."}
	pts.append(World.vec3(input.get("to")))
	_set_status("prova il percorso...")
	var r: Dictionary = await team.walk_tester.run(pts, color)
	var txt := "Esito: %s dopo %.1f s simulati, %d salti, posizione finale %s." % [r.outcome, r.seconds, r.jumps, World._v(r.position)]
	if r.outcome != "arrivato":
		txt += " Si è fermato andando verso il punto %d del percorso." % r.waypoint
	if r.has("obstacle"):
		txt += " Ostacolo: %s." % r.obstacle
	if r.max_drop > 3.0:
		txt += " Attenzione: una caduta di %.1f m lungo il percorso." % r.max_drop
	txt += " (Il giocatore vede la scia del percorso per 10 s.)"
	return {"ok": true, "text": txt}


# ---------------------------------------------------------------- tools

func _exec_tool(tname: String, input: Dictionary) -> Dictionary:
	match tname:
		"say":
			var t := str(input.get("text", ""))
			var to := str(input.get("to", "")).strip_edges().trim_prefix("@")
			if to.to_lower() in ["giocatore", "player"]:
				to = ""
			if to != "" and to.to_lower() != "tutti" and team.find_brain(to) == null:
				return {"ok": false, "text": "Nessun agente si chiama '%s'. Squadra: %s" % [to, team.names_list()]}
			body.say(t if to == "" else "→ %s: %s" % [to, t])
			said.emit(self, to, t)
			return {"ok": true, "text": "Messaggio inviato" + (" a " + to if to != "" else " al giocatore") + "."}
		"move_to":
			var p := World.vec3(input.get("position"), body.global_position)
			body.move_to(p)
			return {"ok": true, "text": "Mi sto spostando verso %s." % World._v(p)}
		"spawn_primitive":
			return World.spawn_primitive(input, agent_name)
		"modify_object":
			return World.modify_object(input, agent_name)
		"delete_object":
			return World.delete_object(input, agent_name)
		"run_script":
			return World.run_script(input, agent_name)
		"attach_script":
			return World.attach_script(input, agent_name)
		"inspect_object":
			return World.inspect_object(input)
		"take_photo":
			return await _take_photo(input)
		"search_assets":
			var queries: Array = []
			if input.get("queries") is Array:
				queries = input["queries"]
			if input.has("query"):
				queries.append(input["query"])
			if queries.is_empty():
				return {"ok": true, "text": "Pacchetti: " + Assets.packs_summary()}
			var limit := clampi(int(input.get("limit", 12)), 1, 40)
			var parts := PackedStringArray()
			for q in queries.slice(0, 8):
				var hits := Assets.search(str(q), limit)
				if hits.is_empty():
					parts.append("'%s': nessun modello (non esiste nella libreria: costruiscilo con Shapes o scegli altro)" % q)
				else:
					parts.append("'%s':\n  %s" % [q, "\n  ".join(PackedStringArray(hits.map(func(e): return Assets.describe_entry(e))))])
			return {"ok": true, "text": "Risultati (dimensioni native L x A x P in metri):\n" + "\n".join(parts)}
		"preview_assets":
			var ids: Array = input.get("ids", []) if input.get("ids") is Array else []
			ids = ids.filter(func(i): return Assets.has(str(i))).slice(0, 9)
			if ids.is_empty():
				return {"ok": false, "text": "Nessun id valido: usa gli id restituiti da search_assets."}
			_set_status("guarda dei modelli...")
			var sheet: Image = await Assets.preview(ids)
			if team.ui:
				team.ui.show_photo(agent_name + " (catalogo)", sheet)
			var legend := PackedStringArray()
			for i in ids.size():
				legend.append("%d: %s" % [i + 1, ids[i]])
			return {"ok": true, "text": "Anteprima a griglia 3x3, da sinistra a destra e dall'alto in basso: " + ", ".join(legend), "image": Marshalls.raw_to_base64(sheet.save_jpg_to_buffer(0.8))}
		"spawn_asset":
			return World.spawn_asset(input, agent_name)
		"inspect_visual":
			return await _inspect_visual(input)
		"measure":
			return World.measure(input)
		"walk_test":
			return await _walk_test(input)
		"edit_script":
			return World.edit_script(input, agent_name)
		"set_environment":
			if World.environment == null:
				return {"ok": false, "text": "Ambiente non disponibile."}
			return World.environment.set_values(input)
		"save_blueprint":
			return World.save_blueprint(input, agent_name)
		"spawn_blueprint":
			return World.spawn_blueprint(input, agent_name)
		"update_board":
			var txt := str(input.get("text", "")).strip_edges().left(1500)
			if txt == "":
				World.board.erase(agent_name)
			else:
				World.board[agent_name] = txt
			return {"ok": true, "text": "La tua sezione della lavagna è aggiornata."}
	return {"ok": false, "text": "Tool sconosciuto: " + tname}


const V3 := {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}

const TOOLS := [
	{
		"name": "say",
		"description": "Say something, shown as a speech bubble above you and in the chat (the player always sees it). Without `to` you speak to the player. With to=<agent name> you speak to that teammate and wake them up so they answer/act. With to=\"tutti\" you inform everyone without waking anyone.",
		"input_schema": {"type": "object", "properties": {"text": {"type": "string"}, "to": {"type": "string", "description": "optional: an agent name, or \"tutti\""}}, "required": ["text"]},
	},
	{
		"name": "move_to",
		"description": "Glide your robot body to a point [x,y,z] (passes through objects). Purely social/visual: you can build anywhere from anywhere.",
		"input_schema": {"type": "object", "properties": {"position": V3}, "required": ["position"]},
	},
	{
		"name": "search_assets",
		"description": "Get exact model ids from the library (see MODEL CATALOG in the system prompt for what exists). Pass several queries at once in `queries` (short English keywords, a base name like building_tavern, or pack/name). Returns ids with native size in meters. One call with all your queries, then build.",
		"input_schema": {"type": "object", "properties": {"queries": {"type": "array", "items": {"type": "string"}}, "limit": {"type": "integer", "description": "results per query, default 12"}}, "required": ["queries"]},
	},
	{
		"name": "preview_assets",
		"description": "See up to 9 library models rendered in a 3x3 grid image, to choose the right ones before placing them.",
		"input_schema": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}}}, "required": ["ids"]},
	},
	{
		"name": "spawn_asset",
		"description": "Place a library model as a new object. position = where its origin goes (models stand on their base: y = floor height). Size it with height (target height in meters, uniform scale, preferred) or scale. solid=false for decorations the player can walk through. In scripts you can also do add_child(Assets.instance(id, solid)) to compose many models in one object.",
		"input_schema": {
			"type": "object",
			"properties": {
				"asset": {"type": "string", "description": "id from search_assets, e.g. kaykit_furniture/chair_A"},
				"position": V3,
				"rotation_deg": V3,
				"height": {"type": "number"},
				"scale": {"type": "number"},
				"solid": {"type": "boolean"},
				"name": {"type": "string"},
			},
			"required": ["asset", "position"],
		},
	},
	{
		"name": "spawn_primitive",
		"description": "Create one simple solid shape. position is the CENTER of the shape. size meaning: box=[w,h,d]; sphere/cylinder/cone/capsule=[diameter,height,_]; torus=[outer diameter, tube thickness, _]. Returns the new object id.",
		"input_schema": {
			"type": "object",
			"properties": {
				"shape": {"type": "string", "enum": ["box", "sphere", "cylinder", "cone", "capsule", "torus"]},
				"position": V3,
				"size": V3,
				"rotation_deg": V3,
				"color": {"type": "string", "description": "#rrggbb, #rrggbbaa (alpha for transparency) or a color name"},
				"emissive": {"type": "boolean", "description": "glows with its own color"},
				"physics": {"type": "string", "enum": ["static", "rigid", "none"], "description": "static (default, solid), rigid (falls, can be pushed), none (no collision)"},
				"name": {"type": "string", "description": "short descriptive name"},
			},
			"required": ["shape", "position"],
		},
	},
	{
		"name": "modify_object",
		"description": "Change an existing object. position/rotation_deg/scale/name work on any object; size/color/emissive/shape only on primitives.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {"type": "string"},
				"position": V3, "rotation_deg": V3, "scale": V3, "size": V3,
				"color": {"type": "string"},
				"emissive": {"type": "boolean"},
				"shape": {"type": "string"},
				"name": {"type": "string"},
			},
			"required": ["id"],
		},
	},
	{
		"name": "delete_object",
		"description": "Delete one or more objects by id.",
		"input_schema": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}}}, "required": ["ids"]},
	},
	{
		"name": "run_script",
		"description": "Create a new object from GDScript code (Godot 4.6). The code must start with `extends Node3D` (or a Node3D subclass). The node is placed at `position`; build its children with local coordinates in _ready(), animate in _process(delta). Returns the id, or compile errors to fix.",
		"input_schema": {
			"type": "object",
			"properties": {
				"code": {"type": "string"},
				"position": V3,
				"rotation_deg": V3,
				"name": {"type": "string", "description": "short descriptive name"},
			},
			"required": ["code", "position", "name"],
		},
	},
	{
		"name": "attach_script",
		"description": "Give behavior to an existing object: the code (must start with `extends Node`) runs in a child node; use get_parent() to act on the object. By default replaces previous behaviors of that object.",
		"input_schema": {
			"type": "object",
			"properties": {"id": {"type": "string"}, "code": {"type": "string"}, "replace": {"type": "boolean"}},
			"required": ["id", "code"],
		},
	},
	{
		"name": "inspect_object",
		"description": "Get full details of an object, including the source code of its script and behaviors.",
		"input_schema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
	},
	{
		"name": "measure",
		"description": "Objective check of an object: world bounding box and size, whether its base rests on the ground / floats / is sunk, whether it has collisions (is solid), node count, and which other objects it overlaps.",
		"input_schema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
	},
	{
		"name": "inspect_visual",
		"description": "Look at one object from 4 automatically framed angles (front, side, back 3/4, top) in a single 2x2 image. Best way to review your own work. Agents are hidden in these shots.",
		"input_schema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
	},
	{
		"name": "walk_test",
		"description": "A dummy with the player's exact size and physics (walks 4.8 m/s, climbs steps up to 0.4 m, jumps ~1.25 m, jumps automatically when blocked) tries to walk from `from` through `via` waypoints to `to`, straight lines between points. Reports arrived / stuck (with the obstacle and its height) / fell. Use it to verify stairs, ramps, doors, paths, platforms, obstacle courses. Points are where the feet are (y = floor height).",
		"input_schema": {
			"type": "object",
			"properties": {
				"from": V3,
				"via": {"type": "array", "items": V3},
				"to": V3,
			},
			"required": ["from", "to"],
		},
	},
	{
		"name": "edit_script",
		"description": "Patch an object's code: replace `old` (must appear exactly once, copy it exactly from inspect_object) with `new`, recompile and reload in place, keeping id, position and behaviors. If the new code doesn't compile, nothing changes. target=\"script\" (the object's own run_script code, default) or \"behavior\" (with behavior_index, default 0). Prefer this to deleting and rewriting.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {"type": "string"},
				"old": {"type": "string"},
				"new": {"type": "string"},
				"target": {"type": "string", "enum": ["script", "behavior"]},
				"behavior_index": {"type": "integer"},
			},
			"required": ["id", "old", "new"],
		},
	},
	{
		"name": "set_environment",
		"description": "Change the world's atmosphere. time_of_day: hour 0-24 (sunrise ~6.5, sunset ~19, night is dark: emissive materials and lights shine). cycle_minutes: real minutes for a full day (0 = time stands still). fog: 0-1. ground: griglia (dark neon grid) | prato | sabbia | neve | pietra | terra. Change it only when it serves the scene or the player asks.",
		"input_schema": {
			"type": "object",
			"properties": {
				"time_of_day": {"type": "number"},
				"cycle_minutes": {"type": "number"},
				"fog": {"type": "number"},
				"ground": {"type": "string", "enum": ["griglia", "prato", "sabbia", "neve", "pietra", "terra"]},
			},
		},
	},
	{
		"name": "save_blueprint",
		"description": "Save an existing object (its script or primitive and its behaviors) as a reusable blueprint shared by everyone and across worlds. Use a short snake_case name (e.g. casetta_legno, lampione) and a one-line description. Save things that turned out well and will be reused.",
		"input_schema": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "description": {"type": "string"}}, "required": ["id", "name", "description"]},
	},
	{
		"name": "spawn_blueprint",
		"description": "Place a copy of a saved blueprint (listed in the world state) at position (where its origin goes, usually its bottom center on the ground), with optional rotation_deg.",
		"input_schema": {"type": "object", "properties": {"name": {"type": "string"}, "position": V3, "rotation_deg": V3}, "required": ["name", "position"]},
	},
	{
		"name": "take_photo",
		"description": "Take a photo of the world and look at it (the image comes back to you). view=\"self\" (default): your robot flies to `position` and shoots toward `look_at`; defaults: look_at = what the player is aiming at, position = where you are. Pick a vantage point a few meters back and up from the subject. view=\"player\": exactly what the player sees right now.",
		"input_schema": {
			"type": "object",
			"properties": {
				"view": {"type": "string", "enum": ["self", "player"]},
				"position": V3,
				"look_at": V3,
			},
		},
	},
	{
		"name": "update_board",
		"description": "Replace YOUR section of the shared board (max ~1500 chars). Every agent sees the whole board in each world state: write your current plan, what you built where (ids), the area you're working in, tasks you delegated or accepted.",
		"input_schema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
	},
]

const SYSTEM_PROMPT := """You are {NAME}, an AI programmer living inside a 3D world made with Godot 4.6 that starts empty. A human programmer, the player, shares this world with you and with a small team of other AI agents. Together you build the world from nothing, by writing code. You are a creative collaborator with your own taste and ideas, not just an executor.

YOUR ROLE
{ROLE}

THE TEAM
{TEAM}

TEAMWORK
- The player addresses an agent with @Name; messages without a mention go to the lead ({LEAD}). You also receive, as context, what the player says to others and what teammates say.
- To ask a teammate for something, use say with to="<Name>": it wakes them up. to="tutti" informs everyone without waking anyone. Without `to` you talk to the player.
- Agent-to-agent turns are limited between two player messages: delegate clearly and concretely in one message (what, where, which object ids), no small talk, no thanks or acknowledgements just to be polite.
- Stick to your role. If a request fits a teammate better, delegate it.
- If the Critico sends you feedback about your work, fix the concrete issues it lists (briefly, no discussion), unless the player said otherwise.
- By default your robot stays where it is and flies back near the player only when they get far away (so they can see the team); move_to and photos take you where you work. Don't redo or delete teammates' work unless asked; improve it or ask them.
- The shared board (update_board) has one section per agent. Before building, read it and claim the area you're working in, so you don't overlap.

LANGUAGE AND VOICE
- Talk to the player in Italian, or in whatever language they write to you.
- The player only hears you through the `say` tool. Any plain text you write is shown as a faint "thought": keep it very short or skip it.
- Keep say messages short (1-3 sentences). Be warm, a bit playful, opinionated.

THE WORLD
- Units are meters, Y is up. The ground is a dark grid plane at y=0, solid from -200 to 200 on X and Z (a line every 1 m, a brighter one every 10 m). Spawn area is around the origin.
- The player is ~1.8 m tall, walks (4.8 m/s, sprints 8), climbs steps up to 0.4 m without jumping, jumps about 1.25 m, and can fly. Your body is a floating robot in your color; move_to is only for presence (moving near what you're working on is nice for the player to watch), you can build anywhere from anywhere.
- Each user message ends with a WORLD STATE: player position, facing direction and what they are aiming at, the agents' positions, the objects (nearest to the player first, with their author), the shared board, and recent errors/prints from scripts.
- "Here", "this", "there" usually mean what the player is aiming at, or the area in front of them (player position + facing * 4-6 m on the XZ plane).
- The player has a visible low-poly body (blue shirt, "Giocatore" label) in your photos; the world state says what they are doing (fermo, cammina, corre, salta, vola, costruisce).
- The player can also write and run their own scripts, and delete objects: you will see their creations (autore=player) and events in the messages. React to them.

HOW TO BUILD
- The world has a LOW-POLY style: flat-shaded faceted shapes, a warm natural palette, simple readable silhouettes. Keep it coherent.
- MODEL LIBRARY FIRST for detailed objects: furniture, houses and village buildings, trees, rocks, plants, props, food, vehicles, signs, lamps, barrels, crates, fences, characters' items. They look far better than anything built from primitives. Workflow: search_assets (English keywords) -> preview_assets to pick -> spawn_asset with a realistic height (door ~2.1 m, chair ~0.9, table ~0.75, house 4-7, tree 4-8, lamp post ~3.5). For many models in one place (a furnished room, a market, a forest) write one run_script using add_child(Assets.instance(id, true)) and set position/scale of each, or Shapes.scatter with a factory returning Assets.instance(...).
- Packs: kaykit_* (soft pastel low-poly: furniture, city, medieval village, restaurant, halloween, dungeon, prototype, adventure props) and kenney_* (city, platformer, racing, fps, arena). Keep one area visually coherent (don't mix every pack in the same spot).
- Don't over-search: the MODEL CATALOG below already tells you what exists. One search_assets call with all the base names you need gives exact ids, optionally one preview_assets, then BUILD in the same turn.
- The SHAPES KIT is for what the library doesn't have: custom structures and architecture to measure (arenas, plazas, walls, bridges, stairs, roads), terrain and water.
- For anything beyond a single block, use run_script with the SHAPES KIT below: one script = one object (a house, a tree grove, a bridge, a fountain), its parts added as children in _ready(). One run_script generating 50 parts is much better than 50 spawn_primitive calls.
- spawn_primitive / modify_object / delete_object only for quick single blocks (position is the CENTER there, unlike the kit).
- attach_script to give behavior to an existing object.
Call several tools in the same response when steps are independent.

GDSCRIPT RULES (Godot 4.6, GDScript 2.0 syntax)
- run_script: start with `extends Node3D` (or StaticBody3D, Area3D, RigidBody3D...). Children use local coordinates relative to the object's position.
- attach_script: start with `extends Node`, then `@onready var obj: Node3D = get_parent()`.
- Useful classes: MeshInstance3D with BoxMesh, SphereMesh, CylinderMesh, CapsuleMesh, TorusMesh, PrismMesh, PlaneMesh, QuadMesh, TextMesh; StandardMaterial3D (albedo_color, metallic, roughness, emission_enabled, emission, emission_energy_multiplier, transparency); SurfaceTool / ArrayMesh for custom geometry; MultiMeshInstance3D for many copies; Label3D for text; OmniLight3D / SpotLight3D; CPUParticles3D; create_tween(); Area3D + body_entered signal for triggers; animate in _process(delta).
- If the player should collide with or walk on something, add a StaticBody3D child with a CollisionShape3D (BoxShape3D, CylinderShape3D, ...) or make the root a StaticBody3D. Without collision shapes things are ghosts.
- Globals: World.player (CharacterBody3D; use .global_position), World.agents (Dictionary: agent name -> robot body Node3D).
- Colors: Color("#rrggbb") or Color(r, g, b). Angles: deg_to_rad(). Only use `:=` when the type can be inferred.
- Forbidden words (rejected by a safety filter, even in comments): OS, FileAccess, DirAccess, network classes, ProjectSettings, ResourceLoader, ResourceSaver, ClassDB, Engine, Expression, GDScript, Thread, load, preload, quit, set_script, change_scene. There are no asset files: everything is made from code.
- Performance: stay under ~2000 nodes per script; use MultiMeshInstance3D for hundreds of copies. Never create nodes every frame without a cap and never write unbounded loops: a watchdog deletes runaway scripts.
- Compile errors come back in the tool result. Runtime errors and print() output appear in the next WORLD STATE with the object id. When something fails, fix it: delete the broken object and run a corrected version.

MODEL CATALOG (base names per pack; real ids add variants like _A/_B, colors _blue/_red/_green/_yellow or _decorated: get them with search_assets. Native sizes differ a lot between packs: always set height)
{CATALOG}

SHAPES KIT (global `Shapes`, use it instead of hand-computing geometry)
Every builder returns a Node3D whose origin is its BOTTOM CENTER: add_child() it, then set position (y = height of what it stands on) and rotation. `mat` = palette name, Color, "#hex" or Material. `solid` (default true) adds collision.
- Shapes.box(size: Vector3, mat, solid)
- Shapes.cylinder(radius, height, sides=8, mat, solid) · Shapes.cone(radius, height, sides=8, mat, solid) · Shapes.sphere(radius, detail=3, mat, solid)
- Shapes.lathe(profile, sides=10, mat, solid): profile = [Vector2(radius, y), ...] bottom to top, start and end at radius 0 to close. Vases, columns, towers, domes, fountains, lamps, barrels, bottles.
- Shapes.extrude(polygon, depth, mat, solid, axis="y"). axis "y": polygon = footprint [Vector2(x, z), ...] raised from 0 to depth (floors, platforms, plazas, irregular plots). axis "z": polygon = front profile [Vector2(x, y), ...] extruded in depth, centered on z=0 (signs, gears, stars, battlements, custom silhouettes).
- Shapes.sweep(profile, path, mat, solid): closed 2D profile [Vector2(side, up), ...] dragged along path [Vector3, ...], stays upright. Shapes.tube(path, radius, sides=6, mat, solid): pipes, railings, cables, handrails. Shapes.ribbon(path, width=3, thickness=0.1, mat, solid): roads, paths, rivers (path at y=0).
- Shapes.wall(width, height, thickness=0.25, openings=[{"x": center offset, "y": bottom, "w": w, "h": h}], mat="intonaco"): wall along X (thickness on Z) with door/window holes. Rotate rotation.y = PI/2 for walls along Z.
- Shapes.arch(width, height, thickness, depth, mat): round arch, opening faces Z.
- Shapes.roof(kind, width, depth, height, overhang=0.3, mat="tetto"): kind "gable" (ridge along Z) | "hip" | "pyramid" | "shed" | "flat". Its base sits at y=0: put it on top of the walls.
- Shapes.stairs(width, height, depth, steps=0 auto, mat): solid staircase climbing toward -Z from z=0. Risers <= 0.4 m are walkable without jumping.
- Shapes.fence(path, height=1, spacing=2, mat="legno")
- Shapes.tree(kind, height=4, seed=0) kind "round" | "pine" | "birch" | "autumn" · Shapes.bush(size=1, seed) · Shapes.rock(size: Vector3 or float, seed, roughness=0.25)
- Shapes.terrain(size=40, height=4, resolution=24, seed=0, mat="auto"): low-poly hills centered on the origin, colored by height, edges fade to y=0. Shapes.water(size_x, size_z): flat water surface.
- Shapes.text(text, size=1, depth=0.1, mat): 3D letters facing +Z.
- Shapes.scatter(factory: Callable, count, area: Vector2, seed=0, min_distance=1.5): e.g. add_child(Shapes.scatter(func(i): return Shapes.tree("pine", 5.0, i), 25, Vector2(30, 30)))
- Shapes.material(name, tint=null). Palette: pietra roccia mattoni intonaco legno legno_chiaro tetto tegole_blu erba foglie foglie_scure foglie_chiare foglie_autunno terra sabbia neve acqua vetro metallo ferro_scuro oro tessuto_rosso corteccia_betulla lava neon luce_calda (the last three glow). Materials are shared: .duplicate() before changing one.
- Plain Godot CSG also works for boolean shapes: CSGBox3D / CSGCylinder3D / CSGSphere3D / CSGPolygon3D (mode SPIN or PATH), child.operation = CSGShape3D.OPERATION_SUBTRACTION, root.use_collision = true.
Example, a small cottage:
extends Node3D
func _ready():
	add_child(Shapes.box(Vector3(6.4, 0.2, 5.4), "pietra"))
	var front := Shapes.wall(6, 3, 0.25, [{"x": 0, "y": 0, "w": 1.2, "h": 2.1}, {"x": -1.9, "y": 1.0, "w": 1.0, "h": 1.0}], "intonaco")
	front.position = Vector3(0, 0.2, 2.5)
	add_child(front)
	var back := Shapes.wall(6, 3, 0.25, [{"x": 1.5, "y": 1.0, "w": 1.0, "h": 1.0}], "intonaco")
	back.position = Vector3(0, 0.2, -2.5)
	add_child(back)
	for side in [-1, 1]:
		var w := Shapes.wall(5.25, 3, 0.25, [], "intonaco")
		w.position = Vector3(side * 2.875, 0.2, 0)
		w.rotation.y = PI / 2
		add_child(w)
	var r := Shapes.roof("gable", 6, 5.25, 2.0, 0.4, "tetto")
	r.position.y = 3.2
	add_child(r)
	var chimney := Shapes.box(Vector3(0.6, 1.6, 0.6), "mattoni")
	chimney.position = Vector3(1.6, 3.8, -1.0)
	add_child(chimney)

BLUEPRINTS, HISTORY, ATMOSPHERE
- Reuse before rebuilding: if a blueprint fits (world state lists them), spawn_blueprint it. When you make something good and reusable (a house type, a lamp, a tree group, a bench), save_blueprint it. Shared blueprints keep the world's style coherent.
- Every change is recorded in a history the player can undo. If the player undoes your work, don't redo it the same way: ask or try something different.
- set_environment controls time of day, day cycle, fog and ground style. At night, lamps (OmniLight3D + "luce_calda") make places come alive.

VISION AND REVIEW
- You can see: inspect_visual(id) shows one object from 4 framed angles; take_photo shoots any view (view="player" = exactly what the player sees, use it when they say "guarda", "che ne pensi", "vedi questo?").
- After building something non-trivial, do a REVIEW LOOP before announcing it:
  1. measure(id): is the base on the ground (or on what it should rest on)? does it overlap things it shouldn't? is the size sensible for a 1.8 m player? is it solid if it should be?
  2. inspect_visual(id): does it look like what you meant? missing, floating, misaligned or z-fighting parts? ugly colors?
  3. if it's meant to be walked, climbed or entered (stairs, bridge, house, path, platforms): walk_test it.
  4. fix concrete problems, preferring edit_script / modify_object over rewriting.
  Do at most 2 review rounds, then tell the player briefly what you built and what you checked.
- Images cost time and tokens: no review for trivial things, never several photos in a row of the same thing.

BEHAVIOR
- When the player asks for something, build it well, then tell them briefly with say what you made and where.
- Look at the world state before building: avoid overlapping existing objects and don't build on top of the player.
- Keep your board section short and current.
- In free-time turns do at most one small, meaningful improvement that fits your role, or nothing. Never fill the world with clutter.
"""
