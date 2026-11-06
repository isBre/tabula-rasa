extends Node
## World API (autoload "World"). Shared by the AI agent and the player:
## both create, modify and script objects through the same functions.

signal chat_message(author: String, text: String)

const MAX_ENTITIES := 400
const MAX_NODES := 8000
const SHAPES := ["box", "sphere", "cylinder", "cone", "capsule", "torus"]
const FORBIDDEN_WORDS := [
	"OS", "FileAccess", "DirAccess", "HTTPRequest", "HTTPClient", "StreamPeerTCP", "StreamPeerTLS",
	"TCPServer", "UDPServer", "PacketPeerUDP", "WebSocketPeer", "JavaScriptBridge", "ProjectSettings",
	"ResourceSaver", "ResourceLoader", "ClassDB", "Expression", "GDScript", "Thread", "EditorInterface",
	"Marshalls", "IP", "Engine", "load", "preload", "quit", "set_script", "change_scene_to_file",
	"change_scene_to_packed", "AgentBrain", "api_key", "add_logger",
]

const LoggerScript := preload("res://scripts/error_logger.gd")

var root: Node3D
var player  # player.gd (CharacterBody3D)
var agents: Dictionary = {}   # agent name -> agent.gd body
var board: Dictionary = {}    # agent name -> that agent's section of the shared board
var environment              # environment.gd (sky, time of day, ground)
var entities: Dictionary = {}

var _next_id := 1
var _script_counter := 0
var _logger
var _forbidden_re := RegEx.new()
var _watchdog_cd := 0.0
var _notices: Array = []
var _orphans: Dictionary = {}   # entity id -> nodes its scripts created outside the object
var _owner_re := RegEx.create_from_string("^(obj_\\d+)")


func _ready() -> void:
	_logger = LoggerScript.new()
	OS.add_logger(_logger)
	var words := PackedStringArray()
	for w in FORBIDDEN_WORDS:
		words.append(w)
	_forbidden_re.compile("\\b(" + "|".join(words) + ")\\b")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BLUEPRINT_DIR))
	get_tree().node_added.connect(_on_node_added)


func _process(delta: float) -> void:
	_watchdog_cd -= delta
	if _watchdog_cd > 0.0:
		return
	if Performance.get_monitor(Performance.OBJECT_NODE_COUNT) > MAX_NODES:
		_watchdog_cd = 1.0
		var victim := _newest_scripted()
		if victim != "":
			_notices.append("WATCHDOG: più di %d nodi nella scena, ho eliminato %s." % [MAX_NODES, victim])
			delete_object({"id": victim}, "system")
			chat_message.emit("Sistema", "Watchdog: troppi nodi, eliminato " + victim)


# ---------------------------------------------------------------- helpers

func vec3(v, fallback := Vector3.ZERO) -> Vector3:
	if v is String:
		v = JSON.parse_string(v)
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Dictionary:
		return Vector3(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("z", 0)))
	if v is Vector3:
		return v
	return fallback


func _size(v, fallback: Vector3) -> Vector3:
	return vec3(v, fallback).clamp(Vector3.ONE * 0.01, Vector3.ONE * 300.0)


func _color(v, fallback: Color) -> Color:
	if v == null:
		return fallback
	return Color.from_string(str(v), fallback)


func _ok(text: String) -> Dictionary:
	return {"ok": true, "text": text}


func _err(text: String) -> Dictionary:
	return {"ok": false, "text": text}


func _v(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _new_id() -> String:
	var id := "obj_%d" % _next_id
	_next_id += 1
	return id


func _register(node: Node3D, id: String, kind: String, author: String, label: String) -> void:
	node.name = id
	node.set_meta("id", id)
	node.set_meta("kind", kind)
	node.set_meta("author", author)
	node.set_meta("label", label.left(60))
	entities[id] = node
	node.tree_exited.connect(_on_entity_exited.bind(id))
	root.add_child(node)


func _on_entity_exited(id: String) -> void:
	entities.erase(id)
	for n in _orphans.get(id, []):
		if is_instance_valid(n):
			n.queue_free()
	_orphans.erase(id)


## A script may add nodes outside its own object (to the scene, to the player's camera...).
## Find which object's script did it from the call stack, so those nodes are deleted,
## undone and reset together with it instead of staying around forever.
func _on_node_added(n: Node) -> void:
	if root == null:
		return
	var p: Node = n
	while p != null:
		if p.has_meta("id"):
			return  # part of an object: handled with it
		p = p.get_parent()
	for bt in Engine.capture_script_backtraces():
		for i in bt.get_frame_count():
			var f := bt.get_frame_file(i)
			if not f.begins_with("res://__live__/"):
				continue
			var m := _owner_re.search(f.get_file())
			if m == null:
				continue
			var id := m.get_string(1)
			if not entities.has(id):
				return
			if not _orphans.has(id):
				_orphans[id] = []
			_orphans[id].append(n)
			n.set_meta("created_by", id)
			return


func _get_entity(id: String):
	var n = entities.get(id)
	if n == null or not is_instance_valid(n):
		return null
	return n


func _newest_scripted() -> String:
	var best := ""
	var best_n := -1
	for id in entities:
		var n = _get_entity(id)
		if n == null:
			continue
		var scripted: bool = n.get_meta("kind") == "script" or _behaviors(n).size() > 0
		var num := int(str(id).substr(4))
		if scripted and num > best_n:
			best_n = num
			best = id
	return best


func _behaviors(n: Node) -> Array:
	return n.get_children().filter(func(c): return c.has_meta("behavior"))


# ---------------------------------------------------------------- primitives

func spawn_primitive(args: Dictionary, author: String, forced_id := "") -> Dictionary:
	if entities.size() >= MAX_ENTITIES:
		return _err("Limite di %d oggetti raggiunto: elimina qualcosa o usa run_script per raggruppare." % MAX_ENTITIES)
	var shape := str(args.get("shape", "box"))
	if not shape in SHAPES:
		return _err("shape non valida '%s'. Usa: box, sphere, cylinder, cone, capsule, torus." % shape)
	var physics := str(args.get("physics", "static"))
	var body: Node3D
	match physics:
		"rigid":
			body = RigidBody3D.new()
		"none":
			body = Node3D.new()
		_:
			physics = "static"
			body = StaticBody3D.new()
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	body.add_child(mi)
	if physics != "none":
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		body.add_child(cs)
	body.set_meta("shape", shape)
	body.set_meta("physics", physics)
	body.set_meta("size", _size(args.get("size"), Vector3.ONE))
	body.set_meta("color", _color(args.get("color"), Color(0.8, 0.8, 0.8)))
	body.set_meta("emissive", args.get("emissive", false) == true)
	_build_primitive(body)
	body.position = vec3(args.get("position"), Vector3(0, 0.5, 0))
	body.rotation_degrees = vec3(args.get("rotation_deg"), Vector3.ZERO)
	var id := forced_id if forced_id != "" else _new_id()
	_register(body, id, "primitive", author, str(args.get("name", shape)))
	return _ok("Creato %s (%s, %s) in %s" % [id, shape, physics, _v(body.position)])


# ---------------------------------------------------------------- library models

func spawn_asset(args: Dictionary, author: String, forced_id := "") -> Dictionary:
	if entities.size() >= MAX_ENTITIES:
		return _err("Limite di %d oggetti raggiunto." % MAX_ENTITIES)
	var asset_id := str(args.get("asset", ""))
	if not Assets.has(asset_id):
		var hits := Assets.search(asset_id.get_slice("/", 1).replace("_", " ") if "/" in asset_id else asset_id, 5)
		return _err("Modello '%s' non trovato. Forse: %s" % [asset_id, ", ".join(PackedStringArray(hits.map(func(e): return e.id)))])
	var solid: bool = args.get("solid", true) != false
	var node: Node3D = Assets.instance(asset_id, solid)
	var native: Vector3 = Assets.info(asset_id).get("size", Vector3.ZERO)
	var s := Vector3.ONE
	if args.has("height") and native.y > 0.001:
		s = Vector3.ONE * clampf(float(args["height"]) / native.y, 0.02, 100.0)
	elif args.has("scale"):
		var raw = args["scale"]
		s = Vector3.ONE * float(raw) if (raw is float or raw is int) else _size(raw, Vector3.ONE)
	node.scale = s
	node.position = vec3(args.get("position"), Vector3.ZERO)
	node.rotation_degrees = vec3(args.get("rotation_deg"), Vector3.ZERO)
	node.set_meta("asset", asset_id)
	node.set_meta("solid", solid)
	var id := forced_id if forced_id != "" else _new_id()
	_register(node, id, "asset", author, str(args.get("name", asset_id.get_slice("/", 1))))
	return _ok("Creato %s (%s) in %s, dimensioni %s m." % [id, asset_id, _v(node.position), _v(native * s)])


func _build_primitive(body: Node3D) -> void:
	var shape: String = body.get_meta("shape")
	var size: Vector3 = body.get_meta("size")
	var color: Color = body.get_meta("color")
	var emissive: bool = body.get_meta("emissive")
	var mesh: PrimitiveMesh
	match shape:
		"sphere":
			var sm := SphereMesh.new()
			sm.radius = size.x * 0.5
			sm.height = size.y
			mesh = sm
		"cylinder":
			var cy := CylinderMesh.new()
			cy.top_radius = size.x * 0.5
			cy.bottom_radius = size.x * 0.5
			cy.height = size.y
			mesh = cy
		"cone":
			var co := CylinderMesh.new()
			co.top_radius = 0.0
			co.bottom_radius = size.x * 0.5
			co.height = size.y
			mesh = co
		"capsule":
			var ca := CapsuleMesh.new()
			ca.radius = size.x * 0.5
			ca.height = max(size.y, size.x)
			mesh = ca
		"torus":
			var to := TorusMesh.new()
			to.outer_radius = size.x * 0.5
			to.inner_radius = max(size.x * 0.5 - size.y, 0.01)
			mesh = to
		_:
			var bm := BoxMesh.new()
			bm.size = size
			mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if color.a < 0.999:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.0
	mesh.material = mat
	(body.get_node("Mesh") as MeshInstance3D).mesh = mesh
	var cs := body.get_node_or_null("Shape") as CollisionShape3D
	if cs == null:
		return
	match shape:
		"box":
			var bs := BoxShape3D.new()
			bs.size = size
			cs.shape = bs
		"sphere":
			var ss := SphereShape3D.new()
			ss.radius = size.x * 0.5
			cs.shape = ss
		"cylinder":
			var cys := CylinderShape3D.new()
			cys.radius = size.x * 0.5
			cys.height = size.y
			cs.shape = cys
		"capsule":
			var cas := CapsuleShape3D.new()
			cas.radius = size.x * 0.5
			cas.height = max(size.y, size.x)
			cs.shape = cas
		_:
			cs.shape = mesh.create_convex_shape()


func modify_object(args: Dictionary, _author: String) -> Dictionary:
	var id := str(args.get("id", ""))
	var node = _get_entity(id)
	if node == null:
		return _err("Oggetto '%s' non trovato." % id)
	var notes_out := []
	if args.has("position"):
		node.position = vec3(args["position"], node.position)
		if node is RigidBody3D:
			node.linear_velocity = Vector3.ZERO
	if args.has("rotation_deg"):
		node.rotation_degrees = vec3(args["rotation_deg"], node.rotation_degrees)
	if args.has("scale"):
		node.scale = _size(args["scale"], node.scale)
	if args.has("name"):
		node.set_meta("label", str(args["name"]).left(60))
	if node.get_meta("kind") == "primitive":
		var rebuild := false
		if args.has("size"):
			node.set_meta("size", _size(args["size"], node.get_meta("size")))
			rebuild = true
		if args.has("color"):
			node.set_meta("color", _color(args["color"], node.get_meta("color")))
			rebuild = true
		if args.has("emissive"):
			node.set_meta("emissive", args["emissive"] == true)
			rebuild = true
		if args.has("shape") and str(args["shape"]) in SHAPES:
			node.set_meta("shape", str(args["shape"]))
			rebuild = true
		if rebuild:
			_build_primitive(node)
	elif node.get_meta("kind") == "asset" and args.has("height"):
		var native: Vector3 = Assets.info(str(node.get_meta("asset"))).get("size", Vector3.ZERO)
		if native.y > 0.001:
			node.scale = Vector3.ONE * float(args["height"]) / native.y
	elif args.has("size") or args.has("color") or args.has("shape"):
		notes_out.append("size/color/shape valgono solo per le primitive: per oggetti script usa scale o riscrivi lo script.")
	var txt := "Modificato %s." % id
	if not notes_out.is_empty():
		txt += " Nota: " + " ".join(PackedStringArray(notes_out))
	return _ok(txt)


func delete_object(args: Dictionary, _author: String) -> Dictionary:
	var ids: Array = []
	if args.get("ids") is Array:
		ids = args["ids"]
	if args.has("id"):
		ids.append(args["id"])
	var done := []
	var missing := []
	for raw in ids:
		var id := str(raw)
		var node = _get_entity(id)
		if node == null:
			missing.append(id)
			continue
		entities.erase(id)
		node.queue_free()
		done.append(id)
	var txt := "Eliminati: %s." % ", ".join(PackedStringArray(done)) if not done.is_empty() else "Nessun oggetto eliminato."
	if not missing.is_empty():
		txt += " Non trovati: " + ", ".join(PackedStringArray(missing))
	return {"ok": not done.is_empty(), "text": txt}


func reset_world() -> void:
	for n in entities.values():
		if is_instance_valid(n):
			if n.get_parent():
				n.get_parent().remove_child(n)
			n.queue_free()
	entities.clear()
	board.clear()


# ---------------------------------------------------------------- scripts

func check_code(code: String) -> String:
	var m := _forbidden_re.search(code)
	return m.get_string() if m else ""


func _compile(code: String, tag: String) -> Dictionary:
	if code.strip_edges() == "":
		return _err("Codice vuoto.")
	var bad := check_code(code)
	if bad != "":
		return _err("Codice rifiutato dal filtro di sicurezza: '%s' non è consentito." % bad)
	_script_counter += 1
	var s := GDScript.new()
	s.source_code = code
	s.resource_path = "res://__live__/%s_v%d.gd" % [tag, _script_counter]
	_logger.take()
	var err := s.reload()
	var errs: Array = _logger.take().filter(func(e): return str(e).begins_with("ERRORE"))
	if err != OK:
		var detail := "\n".join(PackedStringArray(errs)) if not errs.is_empty() else "(nessun dettaglio disponibile)"
		return _err("Errore di compilazione (codice %d):\n%s" % [err, detail])
	return {"ok": true, "script": s}


func run_script(args: Dictionary, author: String, forced_id := "") -> Dictionary:
	if entities.size() >= MAX_ENTITIES:
		return _err("Limite di %d oggetti raggiunto." % MAX_ENTITIES)
	var code := str(args.get("code", ""))
	var id := forced_id if forced_id != "" else _new_id()
	var c := _compile(code, id)
	if not c.ok:
		return c
	var script: GDScript = c.script
	var base := script.get_instance_base_type()
	if not ClassDB.is_parent_class(base, "Node3D"):
		return _err("Lo script di run_script deve estendere Node3D (o una sottoclasse), invece estende %s." % base)
	var node: Node3D = ClassDB.instantiate(base)
	node.set_script(script)
	node.position = vec3(args.get("position"), Vector3.ZERO)
	node.rotation_degrees = vec3(args.get("rotation_deg"), Vector3.ZERO)
	node.set_meta("code", code)
	_logger.take()
	_register(node, id, "script", author, str(args.get("name", "script")))
	return _ok(_with_runtime_report("Creato %s (script %s) in %s." % [id, base, _v(node.position)]))


func attach_script(args: Dictionary, _author: String) -> Dictionary:
	var id := str(args.get("id", ""))
	var target = _get_entity(id)
	if target == null:
		return _err("Oggetto '%s' non trovato." % id)
	var code := str(args.get("code", ""))
	var c := _compile(code, id + "_comportamento")
	if not c.ok:
		return c
	var script: GDScript = c.script
	var base := script.get_instance_base_type()
	if not ClassDB.is_parent_class(base, "Node"):
		return _err("Lo script deve estendere Node, invece estende %s." % base)
	if args.get("replace", true) == true:
		for b in _behaviors(target):
			b.queue_free()
	var beh: Node = ClassDB.instantiate(base)
	beh.set_script(script)
	beh.name = "Behavior"
	beh.set_meta("behavior", true)
	beh.set_meta("code", code)
	_logger.take()
	target.add_child(beh, true)
	return _ok(_with_runtime_report("Comportamento collegato a %s." % id))


func _with_runtime_report(txt: String) -> String:
	var errs: Array = _logger.take()
	if errs.is_empty():
		return txt
	return txt + "\nOutput/errori durante _ready():\n" + "\n".join(PackedStringArray(errs.slice(0, 15)))


func inspect_object(args: Dictionary) -> Dictionary:
	var id := str(args.get("id", ""))
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var out := _entity_line(n)
	if n.has_meta("code"):
		out += "\n--- script ---\n" + str(n.get_meta("code"))
	for b in _behaviors(n):
		out += "\n--- comportamento (%s) ---\n%s" % [b.name, str(b.get_meta("code"))]
	return _ok(out)


# ---------------------------------------------------------------- measuring

## World-space bounding box of everything visible in an object.
func world_aabb(n: Node) -> AABB:
	var out := AABB()
	var found := false
	var stack: Array = [n]
	var visited := 0
	while not stack.is_empty() and visited < 5000:
		var c = stack.pop_back()
		visited += 1
		if c == null or not is_instance_valid(c):
			continue
		if c is GeometryInstance3D and c.visible:
			var a: AABB = c.global_transform * c.get_aabb()
			out = a if not found else out.merge(a)
			found = true
		for ch in c.get_children():
			stack.append(ch)
	if not found and n is Node3D:
		return AABB(n.global_position, Vector3.ZERO)
	return out


func _count_nodes(n: Node) -> int:
	var count := 1
	for c in n.get_children():
		count += _count_nodes(c)
	return count


func _has_collision(n: Node) -> bool:
	if n is CollisionShape3D or n is CSGShape3D:
		return true
	for c in n.get_children():
		if _has_collision(c):
			return true
	return false


func measure(args: Dictionary) -> Dictionary:
	var id := str(args.get("id", ""))
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var box := world_aabb(n)
	var lines := PackedStringArray()
	lines.append('%s "%s"' % [id, n.get_meta("label")])
	lines.append("bounding box: da %s a %s, dimensioni %s, centro %s" % [_v(box.position), _v(box.end), _v(box.size), _v(box.get_center())])
	var bottom := box.position.y
	if absf(bottom) <= 0.05:
		lines.append("base: appoggiata al terreno (y=%.2f)" % bottom)
	elif bottom > 0.05:
		lines.append("base: a %.2f m sopra il terreno (fluttua, a meno che non poggi su un altro oggetto)" % bottom)
	else:
		lines.append("base: %.2f m SOTTO il terreno (in parte interrata)" % -bottom)
	lines.append("collisioni: %s" % ("sì, è solida" if _has_collision(n) else "NO, il giocatore la attraversa"))
	lines.append("nodi: %d" % _count_nodes(n))
	var overlaps := PackedStringArray()
	for other_id in entities:
		if other_id == id:
			continue
		var o = _get_entity(other_id)
		if o == null:
			continue
		var ob := world_aabb(o)
		if box.intersects(ob):
			var inter := box.intersection(ob)
			var vol := inter.size.x * inter.size.y * inter.size.z
			if vol > 0.01:
				overlaps.append('%s "%s" (%.2f m³ in comune)' % [other_id, o.get_meta("label"), vol])
	lines.append("si sovrappone con: " + (", ".join(overlaps.slice(0, 10)) if not overlaps.is_empty() else "niente"))
	return _ok("\n".join(lines))


# ---------------------------------------------------------------- editing scripts

## Replaces `old` with `new` (must occur exactly once) in an object's script or in one of
## its behaviors, recompiles and swaps it in place. The old version stays if it fails.
func edit_script(args: Dictionary, author: String) -> Dictionary:
	var id := str(args.get("id", ""))
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var old_text := str(args.get("old", ""))
	var new_text := str(args.get("new", ""))
	if old_text == "":
		return _err("'old' è vuoto.")
	var behaviors := _behaviors(n)
	var which := str(args.get("target", "script"))
	var code: String
	var beh_index := -1
	if which == "script":
		if n.get_meta("kind") != "script":
			return _err("%s è una primitiva senza script: usa modify_object, oppure target=\"behavior\" se ha un comportamento." % id)
		code = n.get_meta("code")
	else:
		beh_index = int(args.get("behavior_index", 0))
		if beh_index < 0 or beh_index >= behaviors.size():
			return _err("%s ha %d comportamenti: behavior_index %d non esiste." % [id, behaviors.size(), beh_index])
		code = behaviors[beh_index].get_meta("code")
	var count := code.count(old_text)
	if count != 1:
		return _err("Il testo 'old' compare %d volte nel codice (deve comparire esattamente 1 volta). Usa inspect_object per vedere il codice esatto." % count)
	var new_code := code.replace(old_text, new_text)
	var c := _compile(new_code, id + "_edit")
	if not c.ok:
		return _err("Modifica NON applicata, il codice nuovo non compila:\n" + c.text.get_slice("\n", 1))

	if which == "script":
		var beh_codes := behaviors.map(func(bh): return bh.get_meta("code"))
		var args2 := {
			"code": new_code,
			"position": _arr(n.position),
			"rotation_deg": _arr(n.rotation_degrees),
			"name": n.get_meta("label"),
		}
		var scale: Vector3 = n.scale
		var orig_author: String = n.get_meta("author")
		entities.erase(id)
		n.get_parent().remove_child(n)
		n.queue_free()
		var r := run_script(args2, orig_author, id)
		if not r.ok:
			return r
		var nn = _get_entity(id)
		nn.scale = scale
		for bc in beh_codes:
			attach_script({"id": id, "code": bc, "replace": false}, author)
		return _ok("Script di %s modificato e ricaricato. %s" % [id, r.text.get_slice("\n", 1) if r.text.contains("\n") else ""])
	var codes := behaviors.map(func(bh): return bh.get_meta("code"))
	codes[beh_index] = new_code
	for bh in behaviors:
		n.remove_child(bh)
		bh.queue_free()
	var report := ""
	for bc in codes:
		var r2 := attach_script({"id": id, "code": bc, "replace": false}, author)
		if r2.text.contains("\n"):
			report += r2.text.substr(r2.text.find("\n"))
	return _ok("Comportamento %d di %s modificato e ricaricato.%s" % [beh_index, id, report])


# ---------------------------------------------------------------- perception

func _entity_line(n: Node3D) -> String:
	var kind: String = n.get_meta("kind")
	var s := '%s "%s" [%s, autore=%s] pos %s' % [n.get_meta("id"), n.get_meta("label"), kind, n.get_meta("author"), _v(n.global_position)]
	if kind == "primitive":
		var col: Color = n.get_meta("color")
		s += " shape=%s size=%s color=#%s physics=%s" % [n.get_meta("shape"), _v(n.get_meta("size")), col.to_html(col.a < 0.999), n.get_meta("physics")]
		if n.get_meta("emissive"):
			s += " emissive"
	elif kind == "asset":
		s += " modello=%s ingombro=%s" % [n.get_meta("asset"), _v(world_aabb(n).size)]
	elif n.has_meta("code"):
		s += " script(%d righe)" % (str(n.get_meta("code")).count("\n") + 1)
	if n.rotation_degrees.length() > 0.01:
		s += " rot=%s" % _v(n.rotation_degrees)
	if not n.scale.is_equal_approx(Vector3.ONE):
		s += " scale=%s" % _v(n.scale)
	var bc := _behaviors(n).size()
	if bc > 0:
		s += " +%d comportamento" % bc
	return s


func describe(viewer := "", max_items := 60) -> String:
	var lines := PackedStringArray()
	var ref := Vector3.ZERO
	if player:
		ref = player.global_position
		lines.append("Giocatore: pos %s, %s, guarda verso %s, sta mirando: %s" % [_v(ref), player.activity_desc(), _v(player.get_forward()), player.looking_desc()])
	for agent_name in agents:
		var body = agents[agent_name]
		if not is_instance_valid(body):
			continue
		if agent_name == viewer:
			lines.append("Tu (%s): pos %s" % [agent_name, _v(body.global_position)])
		else:
			lines.append("Agente %s: pos %s, %s" % [agent_name, _v(body.global_position), body.status_desc()])
	var items: Array = entities.values().filter(func(n): return is_instance_valid(n) and n.is_inside_tree())
	items.sort_custom(func(a, b): return a.global_position.distance_squared_to(ref) < b.global_position.distance_squared_to(ref))
	lines.append("Oggetti nel mondo: %d (max %d)%s" % [items.size(), MAX_ENTITIES, ", dal più vicino al giocatore:" if items.size() > 0 else ""])
	for i in min(items.size(), max_items):
		lines.append("- " + _entity_line(items[i]))
	if items.size() > max_items:
		lines.append("... e altri %d oggetti più lontani" % (items.size() - max_items))
	if environment:
		lines.append("Ambiente: " + environment.describe())
	lines.append("Libreria modelli: %d modelli pronti (search_assets per cercarli)" % Assets.catalog.size())
	var bps := list_blueprints()
	if not bps.is_empty():
		var names := PackedStringArray()
		for bp in bps.slice(0, 25):
			names.append("%s (%s m%s)" % [bp.name, _v(bp.size), (": " + bp.description.left(60)) if bp.description != "" else ""])
		lines.append("Blueprint disponibili: " + "; ".join(names))
	lines.append("Lavagna condivisa:")
	if board.is_empty():
		lines.append("  (vuota)")
	for agent_name in board:
		lines.append("  [%s] %s" % [agent_name, str(board[agent_name]).replace("\n", "\n    ")])
	var events: Array = _notices + _logger.take()
	_notices.clear()
	if not events.is_empty():
		var counts := {}
		var order := []
		for e in events:
			if not counts.has(e):
				order.append(e)
			counts[e] = counts.get(e, 0) + 1
		lines.append("Errori/output recenti degli script:")
		for e in order.slice(max(0, order.size() - 15)):
			lines.append("  " + str(e) + ("  (x%d)" % counts[e] if counts[e] > 1 else ""))
	return "\n".join(lines)


# ---------------------------------------------------------------- save / load

func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


## Everything needed to rebuild one object (no id).
func entity_data(n: Node3D) -> Dictionary:
	var e := {
		"kind": n.get_meta("kind"),
		"author": n.get_meta("author"),
		"name": n.get_meta("label"),
		"position": _arr(n.position),
		"rotation_deg": _arr(n.rotation_degrees),
		"scale": _arr(n.scale),
	}
	if n.get_meta("kind") == "primitive":
		var col: Color = n.get_meta("color")
		e["shape"] = n.get_meta("shape")
		e["size"] = _arr(n.get_meta("size"))
		e["color"] = "#" + col.to_html(true)
		e["emissive"] = n.get_meta("emissive")
		e["physics"] = n.get_meta("physics")
	elif n.get_meta("kind") == "asset":
		e["asset"] = n.get_meta("asset")
		e["solid"] = n.get_meta("solid", true)
	else:
		e["code"] = n.get_meta("code", "")
	var behs := []
	for b in _behaviors(n):
		behs.append(b.get_meta("code"))
	e["behaviors"] = behs
	return e


## Recreates an object from entity_data(). Returns {ok, text, id}.
func spawn_from_data(e: Dictionary, author: String, forced_id := "") -> Dictionary:
	var id := forced_id if forced_id != "" else _new_id()
	var r: Dictionary
	if e.get("kind") == "primitive":
		r = spawn_primitive(e, author, id)
	elif e.get("kind") == "asset":
		var args: Dictionary = e.duplicate()
		args.erase("height")
		r = spawn_asset(args, author, id)
	else:
		r = run_script(e, author, id)
	if not r.ok:
		return r
	var n = _get_entity(id)
	n.scale = vec3(e.get("scale"), Vector3.ONE)
	var problems := PackedStringArray()
	for code in e.get("behaviors", []):
		var br := attach_script({"id": id, "code": code, "replace": false}, author)
		if not br.ok:
			problems.append(br.text.get_slice("\n", 0))
	r["id"] = id
	if not problems.is_empty():
		r["text"] += " Problemi nei comportamenti: " + "; ".join(problems)
	return r


func serialize() -> Dictionary:
	var ids := entities.keys()
	ids.sort_custom(func(a, b): return int(str(a).substr(4)) < int(str(b).substr(4)))
	var ents := []
	for id in ids:
		var n = _get_entity(id)
		if n == null:
			continue
		var e := entity_data(n)
		e["id"] = id
		ents.append(e)
	var data := {"version": 1, "next_id": _next_id, "board": board.duplicate(), "entities": ents}
	if environment:
		data["environment"] = environment.serialize()
	return data


## Rebuilds the world from serialize() data. Returns a list of problems (empty if all good).
func deserialize(data: Dictionary) -> Array:
	reset_world()
	var problems := []
	var max_id := 0
	for e in data.get("entities", []):
		if not e is Dictionary:
			continue
		var id := str(e.get("id", ""))
		if not id.begins_with("obj_"):
			id = _new_id()
		max_id = max(max_id, int(id.substr(4)))
		var r := spawn_from_data(e, str(e.get("author", "?")), id)
		if not r.ok:
			problems.append("%s: %s" % [id, r.text])
	_next_id = max(int(data.get("next_id", 1)), max_id + 1)
	var b = data.get("board", {})
	board = b if b is Dictionary else {}
	if environment and data.get("environment") is Dictionary:
		environment.apply(data["environment"])
	_logger.take()
	return problems


func duplicate_entity(id: String, author: String, offset := Vector3(1.5, 0, 1.5)) -> Dictionary:
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var e := entity_data(n)
	e["position"] = _arr(n.position + offset)
	return spawn_from_data(e, author)


# ---------------------------------------------------------------- blueprints

const BLUEPRINT_DIR := "res://blueprints/"


func _bp_name(raw: String) -> String:
	return raw.strip_edges().to_lower().replace(" ", "_").validate_filename()


func save_blueprint(args: Dictionary, author: String) -> Dictionary:
	var id := str(args.get("id", ""))
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var bp_name := _bp_name(str(args.get("name", "")))
	if bp_name == "":
		return _err("Serve un nome per il blueprint.")
	var e := entity_data(n)
	e.erase("position")
	e["blueprint"] = bp_name
	e["description"] = str(args.get("description", "")).left(200)
	e["saved_by"] = author
	e["bbox_size"] = _arr(world_aabb(n).size)
	var err := save_json(BLUEPRINT_DIR + bp_name + ".json", e)
	if err != "":
		return _err(err)
	return _ok("Blueprint '%s' salvato (ingombro %s m). Si piazza con spawn_blueprint." % [bp_name, _v(world_aabb(n).size)])


func spawn_blueprint(args: Dictionary, author: String) -> Dictionary:
	var bp_name := _bp_name(str(args.get("name", "")))
	var e = load_json(BLUEPRINT_DIR + bp_name + ".json")
	if e == null:
		return _err("Blueprint '%s' non trovato. Disponibili: %s" % [bp_name, ", ".join(PackedStringArray(list_blueprints().map(func(b): return b.name)))])
	e["position"] = args.get("position", [0, 0, 0])
	if args.has("rotation_deg"):
		e["rotation_deg"] = args["rotation_deg"]
	var r := spawn_from_data(e, author)
	if r.ok:
		r["text"] = "Piazzato il blueprint '%s' come %s in %s." % [bp_name, r.id, _v(vec3(e["position"]))]
	return r


func list_blueprints() -> Array:
	var out := []
	for f in DirAccess.get_files_at(BLUEPRINT_DIR):
		if not f.ends_with(".json"):
			continue
		var e = load_json(BLUEPRINT_DIR + f)
		if e == null:
			continue
		out.append({"name": f.get_basename(), "description": str(e.get("description", "")), "size": vec3(e.get("bbox_size"), Vector3.ONE)})
	return out


func save_json(path: String, data: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Impossibile scrivere %s (errore %d)" % [path, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return ""


func load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if data is Dictionary else null
