extends Node
## Two-step round trip with the Claude API using the agent's real prompt and tools
## (request -> tool_use -> tool_result -> reply). Writes res://tests/apitest_output.txt.

const Brain := preload("res://scripts/agent_brain.gd")

var _log := PackedStringArray()


func _ready() -> void:
	var key := FileAccess.get_file_as_string("res://api_key.txt").strip_edges()
	var messages: Array = [{"role": "user", "content": [{"type": "text", "text": "[Test tecnico] Crea un cubo rosso in (0,0.5,-5) con spawn_primitive, poi chiedi all'Ingegnere (say con to) di farlo ruotare, poi di' 'fatto' al giocatore."}]}]
	for step in 3:
		var data = await _call(key, messages)
		if data == null:
			break
		var content: Array = Brain.clean_content(data.get("content", []))
		messages.append({"role": "assistant", "content": content})
		var results: Array = []
		for b in content:
			if b.type == "tool_use":
				_log.append("tool_use: %s %s" % [b.name, JSON.stringify(b.input)])
				results.append({"type": "tool_result", "tool_use_id": b.id, "content": "Creato obj_1" if b.name == "spawn_primitive" else "ok", "is_error": false})
			elif b.type == "text":
				_log.append("text: " + b.text)
		if results.is_empty() or data.get("stop_reason") != "tool_use":
			break
		messages.append({"role": "user", "content": results})
	_log.append("DONE")
	var f := FileAccess.open("res://tests/apitest_output.txt", FileAccess.WRITE)
	f.store_string("\n".join(_log))
	f.close()


func _call(key: String, messages: Array):
	var http := HTTPRequest.new()
	add_child(http)
	var body := {"model": Brain.DEFAULT_MODEL, "max_tokens": 600, "system": Brain.SYSTEM_PROMPT.replace("{NAME}", "Architetto").replace("{ROLE}", "Coordinatore e costruttore").replace("{TEAM}", "- Architetto (tu) [lead]\n- Ingegnere: meccanismi").replace("{LEAD}", "Architetto"), "tools": Brain.TOOLS, "messages": messages}
	var headers := PackedStringArray(["content-type: application/json", "x-api-key: " + key, "anthropic-version: 2023-06-01"])
	http.request("https://api.anthropic.com/v1/messages", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	var res = await http.request_completed
	http.queue_free()
	var raw: String = res[3].get_string_from_utf8()
	_log.append("HTTP %s" % res[1])
	if res[1] != 200:
		_log.append(raw.left(800))
		return null
	return JSON.parse_string(raw)
