extends Node
## World history: a snapshot after every agent turn that changed something and after
## every player action. Supports undo (/annulla, Ctrl+Z), listing (/storia) and
## restoring any snapshot (/ripristina N). Kept in memory for the session.

const MAX_COMMITS := 60
const MERGE_SECONDS := 6.0

var commits: Array = []   # {n, time, author, summary, state, key, t}
var _counter := 0


func commit(author: String, summary: String, merge_key := "") -> void:
	var state := World.serialize()
	var now := Time.get_ticks_msec() / 1000.0
	if not commits.is_empty():
		var last: Dictionary = commits[-1]
		if JSON.stringify(last.state) == JSON.stringify(state):
			return
		if merge_key != "" and last.key == merge_key and now - last.t < MERGE_SECONDS:
			last.state = state
			last.summary = summary
			last.t = now
			return
	_counter += 1
	commits.append({
		"n": _counter,
		"time": Time.get_time_string_from_system().left(5),
		"author": author,
		"summary": summary.left(200),
		"state": state,
		"key": merge_key,
		"t": now,
	})
	while commits.size() > MAX_COMMITS:
		commits.pop_front()


## Starts a fresh history from the current world (after loading a save).
func reset(summary: String) -> void:
	commits.clear()
	commit("sistema", summary)


## Undoes the last change. Returns a message for the chat.
func undo() -> String:
	if commits.size() < 2:
		return "Niente da annullare."
	var last: Dictionary = commits.pop_back()
	World.deserialize(commits[-1].state)
	return "Annullato #%d di %s: %s" % [last.n, last.author, last.summary]


func restore(n: int) -> String:
	for c in commits:
		if c.n == n:
			World.deserialize(c.state)
			commit("giocatore", "ripristino allo stato #%d" % n)
			return "Mondo riportato allo stato #%d (%s, %s: %s)." % [n, c.time, c.author, c.summary]
	return "Stato #%d non trovato (vedi /storia)." % n


func list_text(count := 12) -> String:
	if commits.is_empty():
		return "Cronologia vuota."
	var lines := PackedStringArray(["Cronologia (più recente in fondo):"])
	for c in commits.slice(max(0, commits.size() - count)):
		lines.append("#%d %s %s: %s" % [c.n, c.time, c.author, c.summary])
	return "\n".join(lines)
