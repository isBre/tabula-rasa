extends Node
## Assets (autoload): the library of ready-made CC0 low-poly models in res://assets/
## (KayKit and Kenney packs). Agents search it, preview models and place them;
## scripts can use Assets.instance(id) to compose scenes from them.

const ROOT := "res://assets/"
const CATALOG := "res://assets/catalog.json"

## Theme words added to every model of a pack, to make search work by topic.
const PACK_TAGS := {
	"kaykit_furniture": "furniture interior home house room arredo interni casa stanza",
	"kaykit_city": "city urban town street road car building citta strada",
	"kaykit_medieval": "medieval village fantasy kingdom nature castle borgo medievale villaggio natura",
	"kaykit_restaurant": "restaurant kitchen food cafe bar cucina cibo ristorante",
	"kaykit_halloween": "halloween spooky graveyard horror pumpkin cimitero",
	"kaykit_dungeon": "dungeon castle medieval crypt treasure prison castello sotterraneo",
	"kaykit_prototype": "prototype basic shapes target obstacle game prototipo",
	"kaykit_adventurers_props": "weapon adventure rpg item tool armi avventura",
	"kenney_city": "city road building suburb town citta strada",
	"kenney_platformer": "platformer platform game coin jump piattaforma gioco",
	"kenney_racing": "racing race track vehicle car truck corsa pista veicolo",
	"kenney_fps": "shooter arena platform wall sparatutto",
	"kenney_arena": "arena medieval castle wall column statue castello",
}

## Italian -> English, so a search in Italian finds English file names.
const IT_EN := {
	"albero": "tree", "alberi": "tree", "pino": "pine", "sedia": "chair", "sedie": "chair", "tavolo": "table",
	"letto": "bed", "panchina": "bench", "lampione": "lamp light streetlight", "lampada": "lamp light",
	"casa": "house home building", "case": "house home building", "edificio": "building", "macchina": "car",
	"auto": "car", "camion": "truck", "moto": "motorcycle", "roccia": "rock", "rocce": "rock",
	"sasso": "rock stone", "pietra": "stone rock", "fiore": "flower", "fiori": "flower", "barile": "barrel",
	"botte": "barrel", "cassa": "crate box", "scatola": "box crate", "porta": "door", "finestra": "window",
	"muro": "wall", "mura": "wall", "recinto": "fence", "staccionata": "fence", "strada": "road",
	"ponte": "bridge", "torre": "tower", "castello": "castle", "mulino": "mill windmill", "pozzo": "well",
	"carro": "cart wagon", "barca": "boat", "nave": "ship boat", "fontana": "fountain", "divano": "couch sofa",
	"scaffale": "shelf", "libreria": "bookcase shelf", "tappeto": "rug", "pianta": "plant", "vaso": "pot vase plant",
	"cibo": "food", "torta": "cake", "zucca": "pumpkin", "tomba": "grave tomb", "lapide": "grave",
	"scheletro": "skeleton", "spada": "sword", "scudo": "shield", "forziere": "chest", "tesoro": "chest treasure",
	"moneta": "coin", "bandiera": "flag", "nuvola": "cloud", "erba": "grass", "cespuglio": "bush",
	"montagna": "mountain", "collina": "hill", "acqua": "water", "mercato": "market", "stalla": "stable",
	"chiesa": "church", "taverna": "tavern", "caserma": "barracks", "fattoria": "farm", "campo": "field farm",
	"cucina": "kitchen stove", "frigo": "fridge", "lavandino": "sink", "bagno": "bathroom toilet",
	"armadio": "wardrobe cabinet", "comodino": "nightstand", "televisore": "tv television", "cuscino": "pillow",
	"candela": "candle", "torcia": "torch", "scala": "stairs ladder", "scale": "stairs", "colonna": "column pillar",
	"statua": "statue", "trono": "throne", "gabbia": "cage", "ascia": "axe", "arco": "bow arch",
	"bersaglio": "target", "ostacolo": "obstacle", "piattaforma": "platform", "pista": "track",
	"fungo": "mushroom", "foglia": "leaf", "legno": "wood log", "tronco": "log trunk", "pane": "bread",
	"bicchiere": "glass cup", "piatto": "plate", "pentola": "pot", "lampadario": "chandelier",
}

var catalog: Array = []       # [{id, path, size: Vector3, tags: String}]
var _by_id := {}
var _cache := {}              # id -> PackedScene
var _shape_cache := {}        # id -> Array of [Transform3D, Shape3D]

var _preview_vp: SubViewport
var _preview_cam: Camera3D
var _preview_holder: Node3D
var _preview_busy := false


func _ready() -> void:
	var data = null
	if FileAccess.file_exists(CATALOG):
		data = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if data is Array:
		for e in data:
			_add(str(e.id), str(e.path), Vector3(e.size[0], e.size[1], e.size[2]))
	else:
		for path in _scan(ROOT):
			_add(_make_id(path), path, Vector3.ZERO)
	_build_preview_world()


func _add(id: String, path: String, size: Vector3) -> void:
	var pack := id.get_slice("/", 0)
	var words := id.get_slice("/", 1).to_lower().replace("_", " ").replace("-", " ")
	var folder := path.get_base_dir().trim_prefix(ROOT + pack).replace("/", " ")
	var e := {"id": id, "path": path, "size": size, "tags": "%s %s %s" % [words, folder, PACK_TAGS.get(pack, "")]}
	catalog.append(e)
	_by_id[id] = e


func _scan(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".glb") or f.ends_with(".gltf"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out += _scan(dir.path_join(d))
	return out


func _make_id(path: String) -> String:
	var rel := path.trim_prefix(ROOT)
	return rel.get_slice("/", 0) + "/" + rel.get_file().get_basename().trim_suffix(".gltf")


func has(id: String) -> bool:
	return _by_id.has(id)


func info(id: String) -> Dictionary:
	return _by_id.get(id, {})


# ---------------------------------------------------------------- search

func search(query: String, limit := 25) -> Array:
	var q := query.to_lower().strip_edges()
	# an id or a piece of one ("kaykit_medieval/building_home", "building_tavern")
	if "/" in q or (q.contains("_") and not q.contains(" ")):
		var direct: Array = catalog.filter(func(e): return e.id.to_lower().contains(q))
		if not direct.is_empty():
			return direct.slice(0, limit)
	var pack_filter := ""
	for p in PACK_TAGS:
		if q.contains(p):
			pack_filter = p
			q = q.replace(p, " ")
	var words := PackedStringArray()
	for w in q.replace(",", " ").replace("_", " ").replace("/", " ").split(" ", false):
		words.append(w)
		if IT_EN.has(w):
			for t in str(IT_EN[w]).split(" "):
				words.append(t)
	var scored: Array = []
	for e in catalog:
		if pack_filter != "" and not e.id.begins_with(pack_filter + "/"):
			continue
		var score := 0
		var name_tokens: PackedStringArray = e.id.get_slice("/", 1).to_lower().replace("-", "_").split("_", false)
		var tag_tokens: PackedStringArray = e.tags.split(" ", false)
		for w in words:
			if w in name_tokens or (w + "s") in name_tokens:
				score += 3
			elif w.length() >= 4 and Array(name_tokens).any(func(t): return t.begins_with(w)):
				score += 2
			elif w in tag_tokens:
				score += 1
		if score > 0 or (pack_filter != "" and words.is_empty()):
			scored.append([score, e])
	scored.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1].id < b[1].id))
	return scored.slice(0, limit).map(func(s): return s[1])


func describe_entry(e: Dictionary) -> String:
	var s: Vector3 = e.size
	return "%s (%.1f x %.1f x %.1f m)" % [e.id, s.x, s.y, s.z] if s != Vector3.ZERO else str(e.id)


func packs_summary() -> String:
	var counts := {}
	for e in catalog:
		var p: String = e.id.get_slice("/", 0)
		counts[p] = counts.get(p, 0) + 1
	var parts := PackedStringArray()
	for p in counts:
		parts.append("%s (%d: %s)" % [p, counts[p], PACK_TAGS.get(p, "").get_slice(" ", 0) + " " + PACK_TAGS.get(p, "").get_slice(" ", 1)])
	return ", ".join(parts)


## Compact index of what exists: per pack, the base names of its models (variants
## like _A/_B, colors and _decorated removed). Goes in the agents' system prompt.
func index_text() -> String:
	var drop := RegEx.create_from_string("^([a-f]|\\d+|blue|red|green|yellow|neutral|decorated|wood|colored|variation)$")
	var stems := {}
	for e in catalog:
		var pack: String = e.id.get_slice("/", 0)
		var toks := PackedStringArray()
		for t in e.id.get_slice("/", 1).to_lower().replace("-", "_").split("_", false):
			if drop.search(t) == null:
				toks.append(t)
		if not stems.has(pack):
			stems[pack] = {}
		stems[pack]["_".join(toks)] = true
	var lines := PackedStringArray()
	for pack in stems:
		var names: Array = stems[pack].keys()
		names.sort()
		lines.append("%s: %s" % [pack, ", ".join(PackedStringArray(names))])
	return "\n".join(lines)


# ---------------------------------------------------------------- loading

func _scene(id: String) -> PackedScene:
	if _cache.has(id):
		return _cache[id]
	var e: Dictionary = _by_id.get(id, {})
	if e.is_empty():
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(e.path, state) != OK:
		push_error("Assets: impossibile leggere " + str(e.path))
		return null
	var root: Node = doc.generate_scene(state)
	if root == null:
		return null
	_own(root, root)
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	_cache[id] = ps
	return ps


func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own(c, owner_node)


## A new copy of a model (origin as authored, usually bottom center).
## solid = true wraps it in a StaticBody3D with collision shapes.
func instance(id: String, solid := false) -> Node3D:
	var ps := _scene(id)
	if ps == null:
		push_error("Assets: modello '%s' non trovato (usa search_assets)" % id)
		return Node3D.new()
	var model: Node3D = ps.instantiate()
	if not solid:
		return model
	var body := StaticBody3D.new()
	body.add_child(model)
	for pair in _shapes(id, model):
		var cs := CollisionShape3D.new()
		cs.transform = pair[0]
		cs.shape = pair[1]
		body.add_child(cs)
	return body


func _shapes(id: String, model: Node3D) -> Array:
	if _shape_cache.has(id):
		return _shape_cache[id]
	var out: Array = []
	var stack: Array = [[model, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != model:
			xf = xf * n.transform
		if n is MeshInstance3D and n.mesh:
			out.append([xf, n.mesh.create_trimesh_shape()])
		for c in n.get_children():
			stack.append([c, xf])
	_shape_cache[id] = out
	return out


## Native bounding box of a model, measured from its meshes.
func measure_model(id: String) -> AABB:
	var m := instance(id)
	var box := _local_aabb(m)
	m.free()
	return box


func _local_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var found := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is Node3D and n != root:
			xf = xf * n.transform
		if n is GeometryInstance3D:
			var a: AABB = xf * n.get_aabb()
			out = a if not found else out.merge(a)
			found = true
		for c in n.get_children():
			stack.append([c, xf])
	return out


# ---------------------------------------------------------------- previews

func _build_preview_world() -> void:
	_preview_vp = SubViewport.new()
	_preview_vp.own_world_3d = true
	_preview_vp.size = Vector2i(400, 300)
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_preview_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_preview_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#dfe8ef")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	_preview_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.1
	_preview_vp.add_child(sun)
	_preview_cam = Camera3D.new()
	_preview_cam.fov = 35.0
	_preview_vp.add_child(_preview_cam)
	_preview_cam.make_current()
	_preview_holder = Node3D.new()
	_preview_vp.add_child(_preview_holder)


## Renders up to 9 models in a 3x3 grid (800x600), in the given order, each framed alone.
func preview(ids: Array) -> Image:
	while _preview_busy:
		await get_tree().process_frame
	_preview_busy = true
	var sheet := Image.create(1200, 900, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.55, 0.6, 0.65))
	for i in mini(ids.size(), 9):
		var m := instance(str(ids[i]))
		_preview_holder.add_child(m)
		var box := _local_aabb(m)
		var center := box.get_center()
		var radius: float = maxf(box.size.length() * 0.5, 0.2)
		var dir := Vector3(0.9, 0.75, 1.25).normalized()
		_preview_cam.global_position = center + dir * radius / tan(deg_to_rad(_preview_cam.fov * 0.5)) * 1.05
		_preview_cam.look_at(center, Vector3.UP)
		_preview_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var img := _preview_vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGB8)
		img.resize(398, 298)
		sheet.blit_rect(img, Rect2i(0, 0, 398, 298), Vector2i((i % 3) * 400 + 1, (i / 3) * 300 + 1))
		m.free()
	_preview_busy = false
	sheet.resize(800, 600, Image.INTERPOLATE_LANCZOS)
	return sheet


# ---------------------------------------------------------------- catalog building

## Measures every model and writes catalog.json (run once, e.g. from tools/build_catalog).
func rebuild_catalog() -> int:
	var out: Array = []
	for path in _scan(ROOT):
		var id := _make_id(path)
		if not _by_id.has(id):
			_add(id, path, Vector3.ZERO)
		var box := measure_model(id)
		_by_id[id].size = box.size
		out.append({"id": id, "path": path, "size": [snappedf(box.size.x, 0.01), snappedf(box.size.y, 0.01), snappedf(box.size.z, 0.01)]})
		_cache.erase(id)
	var f := FileAccess.open(CATALOG, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	return out.size()
