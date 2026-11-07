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
	var r := _ok("Creato %s (%s, %s) in %s" % [id, shape, physics, _v(body.position)])
	return _anchor_new(r, id, args) if forced_id == "" else r


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
	var notes := PackedStringArray()
	# placement helpers (skipped when rebuilding saved worlds: forced_id)
	if forced_id == "" and not args.get("anchor") is Dictionary:
		var facing = args.get("facing")
		if facing is String and facing == "player" and player:
			node.rotation.y = Assets.yaw_towards(node.position, player.global_position)
		elif facing != null and not facing is String:
			node.rotation.y = Assets.yaw_towards(node.position, vec3(facing, node.position))
		if args.get("against_wall", false) == true:
			notes.append(_push_against_wall(node, native * s))
		if args.get("snap", true) != false:
			var gy := _surface_below(node.position, [])
			if gy != INF and absf(gy - node.position.y) > 0.01:
				notes.append("appoggiato sulla superficie a y=%.2f" % gy)
				node.position.y = gy
	var id := forced_id if forced_id != "" else _new_id()
	_register(node, id, "asset", author, str(args.get("name", asset_id.get_slice("/", 1))))
	var txt := "Creato %s (%s) in %s, rotazione %d°, dimensioni %s m." % [id, asset_id, _v(node.position), roundi(node.rotation_degrees.y), _v(native * s)]
	notes = PackedStringArray(Array(notes).filter(func(x): return x != ""))
	if not notes.is_empty():
		txt += " " + "; ".join(notes) + "."
	return _anchor_new(_ok(txt), id, args) if forced_id == "" else _ok(txt)


## Highest surface under a point (looking down from a bit above it), or INF if none.
func _surface_below(at: Vector3, exclude: Array) -> float:
	var space := root.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.6, at + Vector3.DOWN * 60.0)
	q.exclude = exclude + ([player.get_rid()] if player else [])
	var hit := space.intersect_ray(q)
	return hit.position.y if not hit.is_empty() else INF


## Moves an object so its back touches the nearest wall (within 4 m) and turns its front
## away from the wall, into the room.
func _push_against_wall(node: Node3D, size: Vector3) -> String:
	var space := root.get_world_3d().direct_space_state
	var origin := node.position + Vector3.UP * minf(1.0, size.y * 0.5 + 0.05)
	var best := {}
	var best_d := INF
	for k in 8:
		var dir := Vector3.FORWARD.rotated(Vector3.UP, k * TAU / 8.0)
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 4.0)
		if player:
			q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty() or absf(hit.normal.y) > 0.5:
			continue
		var d: float = origin.distance_to(hit.position)
		if d < best_d:
			best_d = d
			best = hit
	if best.is_empty():
		return "nessun muro entro 4 m: lasciato dov'era"
	var n: Vector3 = best.normal
	n.y = 0.0
	n = n.normalized()
	node.rotation.y = atan2(n.x, n.z)          # front (+Z) along the wall's normal, into the room
	var p: Vector3 = best.position + n * (size.z * 0.5 + 0.02)
	node.position = Vector3(p.x, node.position.y, p.z)
	return "spinto contro il muro più vicino, rivolto verso la stanza"


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
	if args.get("anchor") is Dictionary:
		var p := place(node, args["anchor"])
		if not p.ok:
			return p
		txt += " " + str(p.text) + "."
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
	var r := _ok(_with_runtime_report("Creato %s (script %s) in %s." % [id, base, _v(node.position)]))
	return _anchor_new(r, id, args) if forced_id == "" else r


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


# ---------------------------------------------------------------- anchors

## Directions an object can be placed on, in the anchor's frame. Relative sides use the
## target's own orientation: its front is its +Z, left/right are its own (like a person
## sitting on a sofa). Compass sides use the world: north = -Z, south = +Z, east = +X, west = -X.
const ANCHOR_SIDES := {
	"front": Vector3(0, 0, 1), "back": Vector3(0, 0, -1), "left": Vector3(1, 0, 0), "right": Vector3(-1, 0, 0),
	"north": Vector3(0, 0, -1), "south": Vector3(0, 0, 1), "east": Vector3(1, 0, 0), "west": Vector3(-1, 0, 0),
	"top": Vector3.UP, "bottom": Vector3.DOWN,
}
const ANCHOR_ALIASES := {
	"davanti": "front", "dietro": "back", "behind": "back", "sinistra": "left", "destra": "right",
	"nord": "north", "sud": "south", "est": "east", "ovest": "west",
	"on": "top", "above": "top", "on_top": "top", "sopra": "top", "below": "bottom", "under": "bottom", "sotto": "bottom",
	"in": "inside", "into": "inside", "dentro": "inside",
}
const RELATIVE_SIDES := ["front", "back", "left", "right"]


func _side_name(v) -> String:
	var s := str(v).strip_edges().to_lower()
	return ANCHOR_ALIASES.get(s, s)


func _axis_of(v: Vector3) -> int:
	return 0 if absf(v.x) > 0.5 else (1 if absf(v.y) > 0.5 else 2)


## What an anchor refers to: "obj_12", "obj_12/name" (a child node with that name, searched
## at any depth), "obj_12/3" (its 3rd part, numbered like the placement check and plan_view),
## "player", a point [x, y, z], or a Node3D (from scripts). Returns a Node3D, a Vector3 or null.
func anchor_target(t) -> Variant:
	if t is Node3D:
		return t if is_instance_valid(t) else null
	if t is Array or t is Vector3 or t is Dictionary:
		return vec3(t)
	var s := str(t).strip_edges()
	if s.to_lower() in ["player", "giocatore"]:
		return player
	var bits := s.split("/", true, 1)
	var n = _get_entity(bits[0])
	if n == null or bits.size() == 1:
		return n
	var sub := bits[1].strip_edges()
	var num := sub.to_lower().replace("parte", "").replace("part", "").strip_edges()
	if num.is_valid_int():
		var ps := _parts(n)
		var i := int(num) - 1
		return ps[i] if i >= 0 and i < ps.size() else null
	return n.find_child(sub, true, false)


## Bounding box of a node's visible geometry, in `frame` coordinates. `skip` (and what is
## under it) is left out, so an object can be anchored inside the object that contains it.
func _box_in(n: Node, frame: Transform3D, skip: Node = null) -> AABB:
	var inv := frame.affine_inverse()
	var out := AABB()
	var found := false
	var stack: Array = [n]
	var visited := 0
	while not stack.is_empty() and visited < 5000:
		var c = stack.pop_back()
		visited += 1
		if c == null or not is_instance_valid(c) or (skip != null and c == skip):
			continue
		if c is GeometryInstance3D and c.visible and not c is Label3D:
			var a: AABB = (inv * c.global_transform) * c.get_aabb()
			out = a if not found else out.merge(a)
			found = true
		for ch in c.get_children():
			stack.append(ch)
	if not found and n is Node3D:
		return AABB(inv * n.global_position, Vector3.ZERO)
	return out


func _yaw_of(n: Node3D) -> float:
	var z := n.global_transform.basis.z
	return atan2(z.x, z.z)


func _set_yaw(n: Node3D, yaw: float) -> void:
	var t := n.global_transform
	t.basis = Basis(Vector3.UP, yaw) * Basis.from_scale(t.basis.get_scale())
	n.global_transform = t


## A collider tall enough to be a wall (furniture in the way is skipped).
func _is_wall(collider) -> bool:
	if not collider is Node3D:
		return false
	var box := world_aabb(collider)
	if box.size.y < 0.01 and collider.get_parent() is Node3D:
		box = world_aabb(collider.get_parent())
	return box.size.y >= 1.5


## Which way the object should look, as a world yaw, or null to keep its rotation.
func _anchor_face(node: Node3D, face, side: String, walls: Array, frame: Transform3D, target) -> Variant:
	var target_node: Node3D = target if target is Node3D else null
	if face is Array or face is Vector3:
		var dp := vec3(face) - node.global_position
		if Vector2(dp.x, dp.z).length() < 0.001:
			return null
		return atan2(dp.x, dp.z)
	var f := _side_name(face)
	var d := Vector3.ZERO
	match f:
		"keep", "", "none":
			return null
		"same":
			if target_node == null:
				return null
			return _yaw_of(target_node)
		"into_room", "room":
			if walls.is_empty():
				return null
			for w in walls:
				d -= frame.basis * ANCHOR_SIDES[w]
		"toward", "towards", "verso", "away":
			if ANCHOR_SIDES.has(side) and not side in ["top", "bottom"]:
				d = frame.basis * -ANCHOR_SIDES[side]
			else:
				var c: Vector3 = world_aabb(target_node).get_center() if target_node else target
				d = c - node.global_position
			if f == "away":
				d = -d
		"player", "giocatore":
			if player == null:
				return null
			d = player.global_position - node.global_position
		_:
			if ANCHOR_SIDES.has(f) and not f in ["top", "bottom"]:
				d = frame.basis * ANCHOR_SIDES[f]
	d.y = 0.0
	if d.length() < 0.001:
		return null
	# with two walls (a corner) look along the diagonal only if asked; otherwise away from the first
	if f in ["into_room", "room"] and walls.size() > 1:
		d = frame.basis * -ANCHOR_SIDES[walls[0]]
	return atan2(d.x, d.z)


## How far to move (in frame coordinates) so the object sits where the anchor says.
func _anchor_delta(node: Node3D, target, frame: Transform3D, side: String, walls: Array, align: String, gap: float) -> Vector3:
	var target_node: Node3D = target if target is Node3D else null
	var tb := _box_in(target_node, frame, node) if target_node else AABB()
	var nb := _box_in(node, frame)
	var tc := tb.get_center()
	var nc := nb.get_center()
	var d := Vector3(tc.x - nc.x, tb.position.y - nb.position.y, tc.z - nc.z)
	var used: Array = []
	if side == "inside":
		for w in walls:
			var v: Vector3 = ANCHOR_SIDES[w]
			var k := _axis_of(v)
			d[k] = (tb.end[k] - gap - nb.end[k]) if v[k] > 0 else (tb.position[k] + gap - nb.position[k])
			used.append(k)
	elif side == "top" or side == "bottom":
		d.y = (tb.end.y + gap - nb.position.y) if side == "top" else (tb.position.y - gap - nb.end.y)
	else:
		var v: Vector3 = ANCHOR_SIDES[side]
		var k := _axis_of(v)
		d[k] = (tb.end[k] + gap - nb.position[k]) if v[k] > 0 else (tb.position[k] - gap - nb.end[k])
		used.append(k)
	for raw_al in align.split(","):
		var al := _side_name(raw_al)
		if not ANCHOR_SIDES.has(al):
			continue
		var v: Vector3 = ANCHOR_SIDES[al]
		var k := _axis_of(v)
		if k in used:
			continue
		if k == 1 and side in ["top", "bottom"]:
			continue
		d[k] = (tb.end[k] - nb.end[k]) if v[k] > 0 else (tb.position[k] - nb.position[k])
	return d


## Slides the object until it touches the real wall surface on each side in `walls`,
## looking from the middle of the target (so rays never start inside a wall).
func _anchor_walls(node: Node3D, target_node: Node3D, frame: Transform3D, walls: Array, gap: float) -> int:
	var space := root.get_world_3d().direct_space_state
	var own: Array = _rids(node, [])
	if player:
		own.append(player.get_rid())
	var tb := _box_in(target_node, frame, node)
	var touched := 0
	for w in walls:
		var v: Vector3 = ANCHOR_SIDES[w]
		var k := _axis_of(v)
		var nb := _box_in(node, frame)
		var start := nb.get_center()
		start[k] = tb.get_center()[k]
		start.y = nb.position.y + clampf(nb.size.y * 0.5, 0.15, 1.0)
		var reach := tb.size[k] * 0.5 + 1.0
		var exclude := own.duplicate()
		var hit := {}
		for _i in 8:
			var q := PhysicsRayQueryParameters3D.create(frame * start, frame * (start + v * reach))
			q.exclude = exclude
			var h := space.intersect_ray(q)
			if h.is_empty():
				break
			if absf(h.normal.y) < 0.5 and _is_wall(h.collider):
				hit = h
				break
			exclude.append(h.rid)
		if hit.is_empty():
			continue
		var hk: float = (frame.affine_inverse() * hit.position)[k]
		var cur: float = nb.end[k] if v[k] > 0 else nb.position[k]
		var want: float = hk - gap if v[k] > 0 else hk + gap
		var shift := Vector3.ZERO
		shift[k] = want - cur
		node.global_position += frame.basis * shift
		touched += 1
	return touched


## Moves and turns `node` relative to something else, so nobody computes coordinates.
## a = {to, side, wall, align, gap, offset, face, snap} (see the agents' prompt).
## Works on world objects and on parts inside a script (World.place(child, {...})).
func place(node: Node3D, a: Dictionary) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return _err("Ancora: oggetto non valido (in uno script, fai prima add_child).")
	var target = anchor_target(a.get("to", ""))
	if target == null:
		return _err("Ancora: '%s' non trovato. 'to' accetta un id (obj_12), una parte (obj_12/nome_nodo o obj_12/3), \"player\" o [x,y,z]." % str(a.get("to", "")))
	var target_node: Node3D = target if target is Node3D else null
	if target_node and (target_node == node or node.is_ancestor_of(target_node)):
		return _err("Ancora: un oggetto non si può ancorare a se stesso o a una sua parte.")
	var walls: Array = []
	var raw_walls = a.get("wall", a.get("walls", []))
	var wall_list: Array = raw_walls if raw_walls is Array else [raw_walls]
	for w in wall_list:
		var wn := _side_name(w)
		if wn == "":
			continue
		if not ANCHOR_SIDES.has(wn) or wn in ["top", "bottom"]:
			return _err("Ancora: parete '%s' non valida. Usa front, back, left, right, north, south, east, west." % str(w))
		walls.append(wn)
	var side := _side_name(a.get("side", "inside" if not walls.is_empty() else "front"))
	if side != "inside" and not ANCHOR_SIDES.has(side):
		return _err("Ancora: side '%s' non valido. Usa front, back, left, right, top, bottom, north, south, east, west o inside." % side)
	if side != "inside" and not walls.is_empty():
		return _err("Ancora: 'wall' si usa solo con side=inside (contro una parete interna del bersaglio).")
	if target_node == null and side == "inside" and not walls.is_empty():
		return _err("Ancora: per 'wall' serve un oggetto come bersaglio (una stanza, un pavimento), non un punto.")
	# walls are the target's walls: a compass name means the one that faces most that way
	var wall_notes := PackedStringArray()
	if side == "inside" and target_node:
		var inv := Basis(Vector3.UP, _yaw_of(target_node)).inverse()
		for i in walls.size():
			if walls[i] in RELATIVE_SIDES:
				continue
			var lv: Vector3 = inv * ANCHOR_SIDES[walls[i]]
			var rel := ("left" if lv.x > 0 else "right") if absf(lv.x) > absf(lv.z) else ("front" if lv.z > 0 else "back")
			if absf(absf(lv.x) - absf(lv.z)) > 0.05:
				wall_notes.append("%s = suo lato %s" % [walls[i], rel])
			walls[i] = rel
	var align := str(a.get("align", "center")).to_lower()
	var relative := side == "inside"
	for s in [side] + walls + Array(align.split(",")):
		if _side_name(s) in RELATIVE_SIDES:
			relative = true
	var origin: Vector3 = target if target is Vector3 else target_node.global_position
	var frame := Transform3D(Basis(Vector3.UP, _yaw_of(target_node) if relative and target_node else 0.0), origin)
	var default_gap := 0.02 if side == "inside" else (0.0 if side in ["top", "bottom"] else 0.05)
	var gap := float(a.get("gap", default_gap))
	var offset := vec3(a.get("offset"), Vector3.ZERO)
	var face = a.get("face", null)
	if face == null:
		if side == "inside" and not walls.is_empty():
			face = "into_room"
		elif side == "inside":
			face = "same"
		elif side in ["front", "back"]:
			face = "toward"
		elif side in ["left", "right"]:
			face = "same"
		else:
			face = "keep"
	# two passes: facing can depend on where the object ends up, and turning changes its footprint
	for _pass in 2:
		var yaw = _anchor_face(node, face, side, walls, frame, target)
		if yaw != null:
			_set_yaw(node, yaw)
		var d := _anchor_delta(node, target, frame, side, walls, align, gap)
		node.global_position += frame.basis * (d + offset)
	var notes := wall_notes
	if side == "inside" and not walls.is_empty():
		var touched := _anchor_walls(node, target_node, frame, walls, gap)
		if touched < walls.size():
			notes.append("muro vero non trovato su %d lati: usati i bordi del bersaglio" % (walls.size() - touched))
	# rest on what is below (floor, rug, platform) unless lifted on purpose
	if a.get("snap", true) != false and not side in ["top", "bottom"] and absf(offset.y) < 0.001:
		var nb := world_aabb(node)
		var from := Vector3(nb.get_center().x, nb.position.y + 0.5, nb.get_center().z)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 30.0)
		q.exclude = _rids(node, []) + ([player.get_rid()] if player else [])
		var hit := root.get_world_3d().direct_space_state.intersect_ray(q)
		if not hit.is_empty() and absf(hit.position.y - nb.position.y) > 0.005 and absf(hit.position.y - nb.position.y) < 1.0:
			node.global_position.y += hit.position.y - nb.position.y
	var box := world_aabb(node)
	var where := "%s di %s" % [side if side != "inside" else "dentro", _anchor_label(a.get("to", ""))]
	if not walls.is_empty():
		where += " contro la parete " + "+".join(PackedStringArray(walls))
	var txt := "ancorato %s: posizione %s, rotazione %d°, ingombro da %s a %s" % [where, _v(node.global_position), roundi(rad_to_deg(_yaw_of(node))), _v(box.position), _v(box.end)]
	if not notes.is_empty():
		txt += " (" + "; ".join(notes) + ")"
	return _ok(txt)


func _anchor_label(t) -> String:
	if t is Node3D:
		return str(t.name)
	if t is Array or t is Vector3:
		return _v(vec3(t))
	return str(t)


## Applies args.anchor to an object a building tool has just created.
func _anchor_new(r: Dictionary, id: String, args: Dictionary) -> Dictionary:
	if not r.ok or not args.get("anchor") is Dictionary:
		return r
	var n = _get_entity(id)
	if n == null:
		return r
	var p := place(n, args["anchor"])
	if not p.ok:
		n.queue_free()
		return _err("Non creato. " + p.text)
	r["text"] = str(r.text) + " Poi " + p.text + "."
	return r


## The `place` tool: moves an existing object with an anchor.
func place_object(args: Dictionary) -> Dictionary:
	var id := str(args.get("id", ""))
	var n = _get_entity(id)
	if n == null:
		return _err("Oggetto '%s' non trovato." % id)
	var a = args.get("anchor", args)
	if not a is Dictionary:
		return _err("anchor deve essere un oggetto {to, side, ...}.")
	var p := place(n, a)
	if p.ok:
		p["text"] = "%s %s." % [id, p.text]
		if n is RigidBody3D:
			n.linear_velocity = Vector3.ZERO
	return p


# ---------------------------------------------------------------- placement check

## The pieces of an object worth checking: the object itself for library models and
## primitives, the direct children with geometry for scripts.
func _parts(n: Node3D) -> Array:
	if n.get_meta("kind", "") != "script":
		return [n]
	var out: Array = []
	for c in n.get_children():
		if c is Node3D and not c.has_meta("behavior"):
			var box := world_aabb(c)
			if box.size.length() > 0.05:
				out.append(c)
	return out


func _part_name(n: Node3D, owner_id: String, index: int) -> String:
	var label := ""
	if n.has_meta("asset"):
		label = str(n.get_meta("asset")).get_slice("/", 1)
	elif n.has_meta("id"):
		return '%s "%s"' % [n.get_meta("id"), n.get_meta("label")]
	else:
		label = str(n.name).trim_prefix("@").get_slice("@", 0)
	return "%s parte %d (%s)" % [owner_id, index, label]


func _rids(n: Node, out: Array) -> Array:
	if n is CollisionObject3D:
		out.append(n.get_rid())
	for c in n.get_children():
		_rids(c, out)
	return out


## Lists concrete placement problems of one object: pieces interpenetrating each other or
## other objects nearby, pieces floating above what is under them. "" if everything is fine.
func placement_report(id: String) -> String:
	var n = _get_entity(id)
	if n == null:
		return ""
	var issues := PackedStringArray()
	var mine := _parts(n)
	var boxes := {}
	for i in mine.size():
		boxes[mine[i]] = world_aabb(mine[i])
	var flat := func(b: AABB) -> bool: return b.size.y < 0.25 or b.size.x * b.size.z > 150.0
	# others nearby
	var center: Vector3 = world_aabb(n).get_center()
	var others: Array = []
	for oid in entities:
		if oid == id:
			continue
		var o = _get_entity(oid)
		if o == null or world_aabb(o).get_center().distance_to(center) > 30.0:
			continue
		var oparts := _parts(o)
		for j in oparts.size():
			others.append([oparts[j], world_aabb(oparts[j]), _part_name(oparts[j], oid, j + 1) if o.get_meta("kind") == "script" else '%s "%s"' % [oid, o.get_meta("label")]])
	for i in mine.size():
		var a: Node3D = mine[i]
		var ab: AABB = boxes[a]
		if flat.call(ab):
			continue
		var aname := _part_name(a, id, i + 1)
		var against: Array = []
		for j in range(i + 1, mine.size()):
			against.append([mine[j], boxes[mine[j]], _part_name(mine[j], id, j + 1)])
		against += others
		for other in against:
			var bb: AABB = other[1]
			if flat.call(bb) or not ab.intersects(bb):
				continue
			var inter := _oriented_overlap(a, other[0])
			if inter.x > 0.1 and inter.y > 0.1 and inter.z > 0.1:
				issues.append("%s compenetra %s (sovrapposizione %.2f x %.2f x %.2f m)" % [aname, other[2], inter.x, inter.y, inter.z])
		# floating
		var bottom := Vector3(ab.get_center().x, ab.position.y, ab.get_center().z)
		var gy := _surface_below(bottom + Vector3.UP * 0.05 - Vector3.UP * 0.6, _rids(a, []))
		if gy != INF and ab.position.y - gy > 0.12 and ab.size.y > 0.25:
			issues.append("%s fluttua %.2f m sopra la superficie sotto (se non è voluto, abbassalo a y=%.2f)" % [aname, ab.position.y - gy, gy])
		if issues.size() >= 12:
			break
	if issues.is_empty():
		return "Controllo posizionamento di %s: nessuna compenetrazione o oggetto sospeso." % id
	return "Controllo posizionamento di %s, %d problemi:\n- %s" % [id, issues.size(), "\n- ".join(issues.slice(0, 12))]


## How much two pieces overlap, measured along their own orientations: a wall turned by 30
## degrees has a world box much bigger than the wall, which reported overlaps that weren't
## there. Separated along either piece's axes = not touching (Vector3.ZERO).
func _oriented_overlap(a: Node3D, b: Node3D) -> Vector3:
	var best := Vector3.ZERO
	for i in 2:
		var ref: Node3D = a if i == 0 else b
		var f := Transform3D(Basis(Vector3.UP, _yaw_of(ref)), ref.global_position)
		var ba := _box_in(a, f)
		var bb := _box_in(b, f)
		if not ba.intersects(bb):
			return Vector3.ZERO
		var sz := ba.intersection(bb).size
		if i == 0 or sz.x * sz.y * sz.z < best.x * best.y * best.z:
			best = sz
	return best


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
	lines.append("Libreria modelli della squadra: %d (elenco nel prompt; design_model per crearne di nuovi)" % Assets.catalog.size())
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
	var missing := []   # library models that don't exist (any more)
	var max_id := 0
	for e in data.get("entities", []):
		if not e is Dictionary:
			continue
		var id := str(e.get("id", ""))
		if not id.begins_with("obj_"):
			id = _new_id()
		max_id = max(max_id, int(id.substr(4)))
		if e.get("kind") == "asset" and not Assets.has(str(e.get("asset", ""))):
			missing.append(str(e.get("asset", "")))
			continue
		var r := spawn_from_data(e, str(e.get("author", "?")), id)
		if not r.ok:
			problems.append("%s: %s" % [id, r.text])
	_next_id = max(int(data.get("next_id", 1)), max_id + 1)
	var b = data.get("board", {})
	board = b if b is Dictionary else {}
	if environment and data.get("environment") is Dictionary:
		environment.apply(data["environment"])
	_logger.take()
	if not missing.is_empty():
		var kinds := {}
		for m in missing:
			kinds[m.get_slice("/", 1) if "/" in m else m] = true
		problems.push_front("%d oggetti saltati perché il loro modello non c'è nella libreria (%s)" % [missing.size(), ", ".join(PackedStringArray(kinds.keys().slice(0, 6))) + ("…" if kinds.size() > 6 else "")])
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
		r = _anchor_new(r, r.id, args)
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
