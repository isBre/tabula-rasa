extends Logger
## Captures engine errors and print() output so they can be fed back to the agent.

const LIVE_PREFIX := "res://__live__/"
const MAX_LINES := 60

var _mutex := Mutex.new()
var _buf: Array = []


func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING:
		return
	var msg := rationale if rationale != "" else code
	var where := ""
	if file.begins_with(LIVE_PREFIX):
		where = " [%s line %d]" % [file.get_file().get_basename(), line]
	else:
		for bt in script_backtraces:
			if bt == null:
				continue
			for i in bt.get_frame_count():
				var f := bt.get_frame_file(i)
				if f.begins_with(LIVE_PREFIX):
					where = " [%s line %d]" % [f.get_file().get_basename(), bt.get_frame_line(i)]
					break
			if where != "":
				break
	_push("ERROR: " + msg.strip_edges() + where)


func _log_message(message: String, error: bool) -> void:
	var m := message.strip_edges()
	if m == "":
		return
	_push(("printerr: " if error else "print: ") + m.left(300))


func _push(s: String) -> void:
	_mutex.lock()
	_buf.append(s)
	while _buf.size() > MAX_LINES:
		_buf.pop_front()
	_mutex.unlock()


func take() -> Array:
	_mutex.lock()
	var out := _buf.duplicate()
	_buf.clear()
	_mutex.unlock()
	return out
