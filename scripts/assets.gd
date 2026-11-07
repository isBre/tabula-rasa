extends Node
## Assets (autoload): the team's own library of low-poly models. There are no ready-made
## files: every model is a JSON recipe in res://models/<name>.json that an agent designed in
## the workshop (design_model): a list of parts built with the Shapes kit, placed with
## coordinates or anchored to each other. The game builds each recipe once, normalizes it
## (origin at the CENTER OF ITS BASE, front toward +Z), merges it into one mesh per material
## with collision, and reuses it for every copy.

const DIR := "res://models/"
const MAX_PARTS := 160
const MAX_VERTICES := 150000
const MAX_DEPTH := 3
const PART_SHAPES := ["box", "cylinder", "cone", "sphere", "lathe", "extrude", "sweep", "tube", "ribbon", "wall", "arch", "roof", "stairs", "fence", "tree", "bush", "rock", "text", "model", "light"]
const DEFAULT_MAT := {"wall": "intonaco", "roof": "tetto", "tube": "metallo", "bush": "foglie", "rock": "roccia", "stairs": "pietra", "arch": "pietra", "text": "intonaco"}

## A few translations both ways, so "sofa" finds divano_tessuto and "sedia" finds chair_x.
const IT_EN := {
	"albero": "tree", "pino": "pine", "sedia": "chair", "tavolo": "table", "letto": "bed", "panchina": "bench",
	"lampione": "streetlight lamp", "lampada": "lamp light", "casa": "house home", "edificio": "building",
	"macchina": "car", "auto": "car", "roccia": "rock", "sasso": "stone rock", "pietra": "stone", "fiore": "flower",
	"barile": "barrel", "botte": "barrel", "cassa": "crate box", "porta": "door", "finestra": "window",
	"muro": "wall", "recinto": "fence", "staccionata": "fence", "ponte": "bridge", "torre": "tower",
	"castello": "castle", "mulino": "mill", "pozzo": "well", "carro": "cart wagon", "barca": "boat",
	"fontana": "fountain", "divano": "sofa couch", "scaffale": "shelf", "libreria": "bookcase", "tappeto": "rug",
	"pianta": "plant", "vaso": "vase pot", "frigorifero": "fridge refrigerator", "frigo": "fridge",
	"lavandino": "sink", "armadio": "wardrobe closet", "comodino": "nightstand", "televisore": "tv television",
	"cucina": "kitchen stove", "forno": "oven", "poltrona": "armchair", "scrivania": "desk", "cespuglio": "bush",
	"candela": "candle", "torcia": "torch", "scala": "stairs ladder", "colonna": "column pillar", "statua": "statue",
	"bancone": "counter", "mensola": "shelf", "specchio": "mirror", "water": "toilet", "doccia": "shower",
	"vasca": "bathtub", "cuscino": "pillow cushion", "bicicletta": "bike bicycle", "insegna": "sign",
	"cartello": "sign", "bandiera": "flag", "tenda": "tent curtain", "orologio": "clock", "quadro": "painting picture",
}

var catalog: Array = []     # [{id, description, tags, author, size: Vector3}]
var _by_id := {}
var _recipes := {}          # id -> recipe
var _built := {}            # id -> {mesh, shape, lights, size} (or {} if the recipe is broken)
var _search_words := {}     # word -> extra words
var _stage: Node3D

var _preview_vp: SubViewport
var _preview_cam: Camera3D
var _preview_holder: Node3D
var _preview_busy := false


func _ready() -> void:
	for it in IT_EN:
		var en: Array = Array(str(IT_EN[it]).split(" "))
		if not _search_words.has(it):
			_search_words[it] = []
		_search_words[it].append_array(en)
		for w in en:
			if not _search_words.has(w):
				_search_words[w] = []
			_search_words[w].append(it)
	_stage = Node3D.new()
	_stage.name = "ModelStage"
	_stage.position = Vector3(0, -2000, 0)
	_stage.visible = false
	add_child(_stage)
	_build_preview_world()
	reload_library()


# ---------------------------------------------------------------- library

func reload_library() -> void:
	catalog.clear()
	_by_id.clear()
	_recipes.clear()
	_built.clear()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var files := Array(DirAccess.get_files_at(DIR))
	files.sort()
	for f in files:
		if not f.ends_with(".json"):
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(DIR + f))
		if data is Dictionary:
			_register(f.get_basename(), data)


func _register(id: String, recipe: Dictionary) -> void:
	_recipes[id] = recipe
	var e := {"id": id, "description": str(recipe.get("description", "")), "tags": str(recipe.get("tags", "")), "author": str(recipe.get("author", "")), "size": Vector3.ZERO}
	if _by_id.has(id):
		catalog.erase(_by_id[id])
	catalog.append(e)
	_by_id[id] = e


func clean_name(raw: String) -> String:
	var s := raw.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	var out := ""
	for ch in s:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_":
			out += ch
	return out.left(40)


func has(id: String) -> bool:
	return _recipes.has(id)


## {id, description, tags, author, size} with the real size of the built model.
func info(id: String) -> Dictionary:
	if not _by_id.has(id):
		return {}
	var d := _get_built(id)
	_by_id[id].size = d.get("size", Vector3.ZERO)
	return _by_id[id]


func recipe(id: String) -> Dictionary:
	return _recipes.get(id, {})


## Saves a recipe as a model (replacing one with the same name) after checking it builds.
## Copies already in the world are rebuilt with the new version.
func save_model(raw_name: String, rec: Dictionary, description: String, author: String, tags := "") -> Dictionary:
	var id := clean_name(raw_name)
	if id == "":
		return {"ok": false, "text": "Serve un nome (lettere, numeri e _), es. divano_tessuto."}
	if description.strip_edges() == "":
		return {"ok": false, "text": "Serve una descrizione di una riga: serve agli altri per trovarlo."}
	var r := build(rec)
	if not r.ok:
		return {"ok": false, "text": "Non salvato, la ricetta ha errori:\n- " + "\n- ".join(r.errors)}
	var replaced := has(id)
	var data := {"name": id, "description": description.strip_edges().left(200), "tags": tags, "author": author, "saved": Time.get_datetime_string_from_system(), "parts": rec.get("parts", [])}
	var f := FileAccess.open(DIR + id + ".json", FileAccess.WRITE)
	if f == null:
		return {"ok": false, "text": "Impossibile scrivere il file del modello."}
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	_register(id, data)
	_built.clear()   # models made of this one change too
	var refreshed := refresh_world_copies(id)
	var size: Vector3 = info(id).size
	var txt := "%s il modello '%s' (%.2f x %.2f x %.2f m). Usalo con spawn_asset(asset=\"%s\") o Assets.instance(\"%s\", true) negli script." % ["Aggiornato" if replaced else "Salvato", id, size.x, size.y, size.z, id, id]
	if refreshed > 0:
		txt += " Aggiornate %d copie già nel mondo." % refreshed
	return {"ok": true, "text": txt}


func refresh_world_copies(id: String) -> int:
	var n := 0
	for eid in World.entities:
		var e = World._get_entity(eid)
		if e == null or not _uses(str(e.get_meta("asset", "")), id, 0):
			continue
		for c in e.get_children():
			if not c.has_meta("behavior"):
				c.queue_free()
		_fill(e, _get_built(str(e.get_meta("asset"))), e is StaticBody3D)
		n += 1
	return n


## Whether model `m` is `id` or contains it (at any depth).
func _uses(m: String, id: String, depth: int) -> bool:
	if m == id:
		return true
	if depth > MAX_DEPTH or not _recipes.has(m):
		return false
	for p in _recipes[m].get("parts", []):
		if p is Dictionary and str(p.get("shape", "")) == "model" and _uses(clean_name(str(p.get("model", ""))), id, depth + 1):
			return true
	return false


# ---------------------------------------------------------------- search

func _words(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for ch in (text.to_lower() + " "):
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch in "àèéìòù":
			cur += ch
		else:
			if cur != "":
				out.append(cur)
			cur = ""
	return out


func search(query: String, limit := 25) -> Array:
	var q := query.strip_edges().to_lower()
	if has(clean_name(q)):
		return [_by_id[clean_name(q)]]
	var words := _words(q)
	for w in words.duplicate():
		for extra in _search_words.get(w, []):
			words.append(extra)
	var scored: Array = []
	for e in catalog:
		var name_tokens := _words(str(e.id).replace("_", " "))
		var other_tokens := _words(str(e.description) + " " + str(e.tags))
		var score := 0
		for w in words:
			if w in name_tokens:
				score += 3
			elif w.length() >= 4 and Array(name_tokens).any(func(t): return t.begins_with(w.left(5))):
				score += 2
			elif w in other_tokens or (w.length() >= 4 and Array(other_tokens).any(func(t): return t.begins_with(w.left(5)))):
				score += 1
		if score > 0 or words.is_empty():
			scored.append([score, e])
	scored.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1].id < b[1].id))
	return scored.slice(0, limit).map(func(s): return s[1])


func describe_entry(e: Dictionary) -> String:
	var s: Vector3 = info(str(e.id)).get("size", Vector3.ZERO)
	var by := (", di " + str(e.author)) if str(e.author) != "" else ""
	return "%s (%.2f x %.2f x %.2f m%s): %s" % [e.id, s.x, s.y, s.z, by, e.description]


func packs_summary() -> String:
	if catalog.is_empty():
		return "la libreria è vuota: crea i modelli con design_model e save_model"
	return "%d modelli: %s" % [catalog.size(), ", ".join(PackedStringArray(catalog.map(func(e): return e.id)))]


## What exists, for the agents' system prompt.
func index_text() -> String:
	if catalog.is_empty():
		return "(vuota: ancora nessun modello. Ogni oggetto che vi serve lo progettate voi.)"
	var lines := PackedStringArray()
	for e in catalog:
		lines.append("- " + describe_entry(e))
	return "\n".join(lines)


# ---------------------------------------------------------------- building

func _f(p: Dictionary, key: String, def: float) -> float:
	var v = p.get(key, def)
	return float(v) if (v is float or v is int or (v is String and v.is_valid_float())) else def


func _i(p: Dictionary, key: String, def: int) -> int:
	return int(_f(p, key, def))


func _pts(p: Dictionary, key: String, at_least: int) -> Variant:
	var v = p.get(key)
	if not v is Array or v.size() < at_least:
		return "serve \"%s\": una lista di almeno %d punti" % [key, at_least]
	for q in v:
		if not (q is Array and q.size() >= 2):
			return "\"%s\": ogni punto è una lista di numeri, es. [0.2, 0.5]" % key
	return v


## One piece of a recipe as a Node3D (meshes only), or an error message.
func _make_part(p: Dictionary, depth: int) -> Variant:
	var shape := str(p.get("shape", "")).to_lower()
	var m: Variant = p.get("mat", p.get("color", DEFAULT_MAT.get(shape, "legno")))
	match shape:
		"box":
			return Shapes.box(World.vec3(p.get("size"), Vector3.ONE).clamp(Vector3.ONE * 0.002, Vector3.ONE * 200), m, false)
		"cylinder":
			return Shapes.cylinder(_f(p, "radius", 0.5), _f(p, "height", 1.0), _i(p, "sides", 8), m, false)
		"cone":
			return Shapes.cone(_f(p, "radius", 0.5), _f(p, "height", 1.0), _i(p, "sides", 8), m, false)
		"sphere":
			return Shapes.sphere(_f(p, "radius", 0.5), clampi(_i(p, "detail", 3), 1, 5), m, false)
		"lathe":
			var prof = _pts(p, "profile", 2)
			return prof if prof is String else Shapes.lathe(prof, _i(p, "sides", 10), m, false)
		"extrude":
			var poly = _pts(p, "polygon", 3)
			return poly if poly is String else Shapes.extrude(poly, _f(p, "depth", 0.2), m, false, str(p.get("axis", "y")))
		"sweep":
			var prof = _pts(p, "profile", 2)
			var path = _pts(p, "path", 2)
			if prof is String or path is String:
				return prof if prof is String else path
			return Shapes.sweep(prof, path, m, false)
		"tube":
			var path = _pts(p, "path", 2)
			return path if path is String else Shapes.tube(path, _f(p, "radius", 0.05), _i(p, "sides", 6), m, false)
		"ribbon":
			var path = _pts(p, "path", 2)
			return path if path is String else Shapes.ribbon(path, _f(p, "width", 1.0), _f(p, "thickness", 0.1), m, false)
		"wall":
			var op = p.get("openings", [])
			return _wall(_f(p, "width", 4.0), _f(p, "height", 3.0), _f(p, "thickness", 0.25), op if op is Array else [], m)
		"arch":
			return Shapes.arch(_f(p, "width", 3.0), _f(p, "height", 3.5), _f(p, "thickness", 0.5), _f(p, "depth", 0.6), m, 10, false)
		"roof":
			return Shapes.roof(str(p.get("kind", "gable")), _f(p, "width", 6.0), _f(p, "depth", 6.0), _f(p, "height", 2.0), _f(p, "overhang", 0.3), m, false)
		"stairs":
			return Shapes.stairs(_f(p, "width", 2.0), _f(p, "height", 2.0), _f(p, "depth", 3.0), _i(p, "steps", 0), m, false)
		"fence":
			var path = _pts(p, "path", 2)
			return path if path is String else Shapes.fence(path, _f(p, "height", 1.0), _f(p, "spacing", 2.0), m, false)
		"tree":
			return Shapes.tree(str(p.get("kind", "round")), _f(p, "height", 4.0), _i(p, "seed", 0), false)
		"bush":
			return Shapes.bush(_f(p, "size", 1.0), _i(p, "seed", 0), m)
		"rock":
			var sz = p.get("size", 1.0)
			return Shapes.rock(World.vec3(sz) if sz is Array else float(sz), _i(p, "seed", 0), _f(p, "roughness", 0.25), m, false)
		"text":
			return Shapes.text(str(p.get("text", "Ciao")), _f(p, "size", 0.5), _f(p, "depth", 0.05), m)
		"model":
			var mid := clean_name(str(p.get("model", "")))
			if not has(mid):
				return "il modello '%s' non esiste (modelli: %s)" % [mid, ", ".join(PackedStringArray(_recipes.keys()))]
			if depth >= MAX_DEPTH:
				return "troppi modelli uno dentro l'altro"
			var d := _get_built(mid, depth + 1)
			if d.is_empty():
				return "il modello '%s' ha errori" % mid
			var holder := Node3D.new()
			_fill(holder, d, false)
			if p.has("height") and d.size.y > 0.001:
				holder.scale = Vector3.ONE * _f(p, "height", d.size.y) / d.size.y
			return holder
		"light":
			var l := OmniLight3D.new()
			l.light_color = Color.from_string(str(p.get("color", "#ffd27a")), Color("#ffd27a"))
			l.light_energy = _f(p, "energy", 1.5)
			l.omni_range = _f(p, "range", 6.0)
			return l
	return "shape '%s' sconosciuta. Forme: %s" % [shape, ", ".join(PackedStringArray(PART_SHAPES))]


## Like Shapes.wall but made of plain blocks around the openings (CSG can't be merged
## into a mesh in the same frame): along X, thickness on Z, origin at the bottom center.
func _wall(width: float, height: float, thickness: float, openings: Array, m: Variant) -> Node3D:
	var root := Node3D.new()
	var holes: Array = []
	var cuts := [-width * 0.5, width * 0.5]
	for o in openings:
		if not o is Dictionary:
			continue
		var ow := float(o.get("w", 1.0))
		var ox := float(o.get("x", 0.0))
		var oy := clampf(float(o.get("y", 0.0)), 0.0, height)
		var oh := clampf(float(o.get("h", 2.0)), 0.0, height - oy)
		var x0 := clampf(ox - ow * 0.5, -width * 0.5, width * 0.5)
		var x1 := clampf(ox + ow * 0.5, -width * 0.5, width * 0.5)
		if x1 - x0 > 0.01 and oh > 0.01:
			holes.append([x0, x1, oy, oy + oh])
			cuts.append(x0)
			cuts.append(x1)
	cuts.sort()
	for i in cuts.size() - 1:
		var a: float = cuts[i]
		var b: float = cuts[i + 1]
		if b - a < 0.001:
			continue
		var mid := (a + b) * 0.5
		# vertical spans of this column that are solid
		var spans: Array = [[0.0, height]]
		for hl in holes:
			if mid > hl[0] and mid < hl[1]:
				var next: Array = []
				for sp in spans:
					if hl[2] > sp[0]:
						next.append([sp[0], minf(hl[2], sp[1])])
					if hl[3] < sp[1]:
						next.append([maxf(hl[3], sp[0]), sp[1]])
				spans = next
		for sp in spans:
			if sp[1] - sp[0] < 0.001:
				continue
			var blk := Shapes.box(Vector3(b - a, sp[1] - sp[0], thickness), m, false)
			blk.position = Vector3(mid, sp[0], 0)
			root.add_child(blk)
	return root


func _mirror_rot(r: Vector3, axis: String) -> Vector3:
	return Vector3(r.x, -r.y, -r.z) if axis == "x" else Vector3(-r.x, -r.y, r.z)


## Builds a recipe {"parts": [...]}. Returns {ok, errors, warnings, data: {mesh, shape, lights,
## size, vertices}, pieces: [[label, AABB in model coordinates]]}.
func build(rec: Dictionary, depth := 0) -> Dictionary:
	var errors := PackedStringArray()
	var warnings := PackedStringArray()
	var parts_in = rec.get("parts", [])
	if not parts_in is Array or parts_in.is_empty():
		return {"ok": false, "errors": ["servono dei pezzi: {\"parts\": [{\"shape\": \"box\", \"size\": [1, 1, 1]}, ...]}"]}
	var holder := Node3D.new()
	_stage.add_child(holder)
	var named := {}
	var pieces: Array = []   # [label, Node3D]
	var count := 0
	var mats := {}            # style check: materials used
	var off_palette := {}     # "#hex" -> part id
	var smooth := PackedStringArray()
	for i in parts_in.size():
		var p = parts_in[i]
		if not p is Dictionary:
			errors.append("pezzo %d: deve essere un oggetto {...}" % (i + 1))
			continue
		var pid := str(p.get("id", "pezzo%d" % (i + 1)))
		var mat = p.get("mat", p.get("color"))
		var shp := str(p.get("shape", "")).to_lower()
		if mat is String and not Shapes.PALETTE.has(mat) and not Color.html_is_valid(mat):
			warnings.append("pezzo '%s': materiale '%s' sconosciuto (grigio). Usa un nome della palette o \"#rrggbb\"" % [pid, mat])
		if not shp in ["light", "model", "tree"]:
			var mkey := str(mat) if mat != null else str(DEFAULT_MAT.get(shp, "legno"))
			mats[mkey] = true
			if mat is String and not Shapes.PALETTE.has(mat) and Color.html_is_valid(mat):
				off_palette[mat] = pid
		if shp in ["cylinder", "cone", "lathe", "tube"] and _i(p, "sides", 0) > 16:
			smooth.append("'%s' ha %d lati (bastano 6-12)" % [pid, _i(p, "sides", 0)])
		if shp == "sphere" and _i(p, "detail", 3) > 4:
			smooth.append("'%s' è una sfera con dettaglio %d (bastano 1-3)" % [pid, _i(p, "detail", 3)])
		var spots: Array = []
		if p.get("positions") is Array:
			for q in p["positions"]:
				spots.append(World.vec3(q))
		else:
			spots.append(World.vec3(p.get("position"), Vector3.ZERO))
		var rot := World.vec3(p.get("rotation", p.get("rotation_deg")), Vector3.ZERO)
		var sc = p.get("scale", 1.0)
		var scale_v: Vector3 = World.vec3(sc, Vector3.ONE) if sc is Array else Vector3.ONE * float(sc)
		var made_nodes: Array = []
		var shift := Vector3.ZERO
		for k in spots.size():
			if count >= MAX_PARTS:
				errors.append("troppi pezzi (massimo %d)" % MAX_PARTS)
				break
			var made = _make_part(p, depth)
			if made is String:
				errors.append("pezzo '%s': %s" % [pid, made])
				break
			var n: Node3D = made
			holder.add_child(n)
			n.position = spots[k] + shift
			n.rotation_degrees = rot
			n.scale = scale_v
			if k == 0 and p.get("anchor") is Dictionary:
				var a: Dictionary = p["anchor"].duplicate()
				var to := str(a.get("to", ""))
				if not named.has(to):
					errors.append("pezzo '%s': anchor.to '%s' non è un pezzo definito prima (pezzi: %s)" % [pid, to, ", ".join(PackedStringArray(named.keys()))])
				else:
					a["to"] = named[to]
					if not a.has("snap"):
						a["snap"] = false
					var before := n.position
					var r: Dictionary = World.place(n, a)
					if not r.ok:
						errors.append("pezzo '%s': %s" % [pid, r.text])
					shift = n.position - before   # copies keep the same spacing from the first one
			made_nodes.append(n)
			count += 1
		if made_nodes.is_empty():
			continue
		named[pid] = made_nodes[0]
		# mirrored copies across x=0 (left-right) and/or z=0 (front-back)
		var mirror := str(p.get("mirror", "")).to_lower()
		var copies: Array = made_nodes.duplicate()
		for axis in ["x", "z"]:
			if not axis in mirror:
				continue
			for src in copies.duplicate():
				if count >= MAX_PARTS:
					break
				var made = _make_part(p, depth)
				if made is String:
					break
				var n: Node3D = made
				holder.add_child(n)
				n.position = src.position * (Vector3(-1, 1, 1) if axis == "x" else Vector3(1, 1, -1))
				n.rotation_degrees = _mirror_rot(src.rotation_degrees, axis)
				n.scale = src.scale
				copies.append(n)
				count += 1
		for k in copies.size():
			pieces.append([pid if copies.size() == 1 else "%s#%d" % [pid, k + 1], copies[k]])
	if not errors.is_empty():
		holder.queue_free()
		return {"ok": false, "errors": errors, "warnings": warnings}
	var baked := _bake(holder)
	var boxes: Array = []
	for pc in pieces:
		var b := World._box_in(pc[1], holder.global_transform)
		b.position -= baked.offset
		boxes.append([pc[0], b, pc[1] is OmniLight3D])
	holder.queue_free()
	if baked.vertices == 0:
		return {"ok": false, "errors": ["nessuna geometria: controlla misure e poligoni (lati che si incrociano?)"], "warnings": warnings}
	if baked.vertices > MAX_VERTICES:
		return {"ok": false, "errors": ["troppo dettagliato: %d vertici (massimo %d). Meno pezzi o meno lati" % [baked.vertices, MAX_VERTICES]], "warnings": warnings}
	for bx in boxes:
		if not bx[2] and bx[1].size.length() < 0.001:
			warnings.append("pezzo '%s': nessuna geometria (poligono o profilo non valido?)" % bx[0])
	# style: advice, never a block
	var style := PackedStringArray()
	for hex in off_palette:
		var near: Array = Shapes.nearest(Color(hex))
		style.append("%s (pezzo '%s') non è nella palette: il più vicino è '%s' (%s). Se serve davvero e lo userete ancora, add_color" % [hex, off_palette[hex], near[0], Shapes.PALETTE[near[0]].color])
	if mats.size() > 5:
		style.append("%d colori diversi: per lo stile ne bastano 2-4 (%s)" % [mats.size(), ", ".join(PackedStringArray(mats.keys()))])
	for sm in smooth:
		style.append("troppo liscio per il low-poly: " + sm)
	var thin := PackedStringArray()
	for bx in boxes:
		var sz: Vector3 = bx[1].size
		if not bx[2] and sz.length() > 0.001 and minf(sz.x, minf(sz.y, sz.z)) < 0.01:
			thin.append(bx[0])
	if not thin.is_empty():
		style.append("pezzi più sottili di 1 cm (spariscono da lontano): " + ", ".join(thin.slice(0, 6)))
	var big := maxf(baked.size.x, maxf(baked.size.y, baked.size.z))
	if baked.vertices > 1500 * maxf(big, 1.0):
		style.append("molto dettagliato per le sue dimensioni (%d vertici per %.1f m): semplifica" % [baked.vertices, big])
	return {"ok": true, "errors": errors, "warnings": warnings, "data": baked, "pieces": boxes, "style": style}


## Merges every mesh under `holder` into one ArrayMesh (one surface per material), with the
## origin moved to the center of the base. Lights are kept apart.
func _bake(holder: Node3D) -> Dictionary:
	var inv := holder.global_transform.affine_inverse()
	var groups := {}   # Material -> [verts, normals, colors] (plain Arrays: shared by reference)
	var order_mats: Array = []
	var lights: Array = []
	var total := 0
	var stack: Array = [holder]
	while not stack.is_empty():
		var c = stack.pop_back()
		if c is OmniLight3D:
			lights.append({"xf": inv * c.global_transform, "color": c.light_color, "energy": c.light_energy, "range": c.omni_range})
		var mesh: Mesh = null
		var override: Material = null
		if c is MeshInstance3D and c.mesh and c.visible:
			mesh = c.mesh
			override = c.material_override
		elif c is CSGShape3D and c.is_root_shape():
			mesh = c.bake_static_mesh()
		if mesh != null and total <= MAX_VERTICES:
			var xf: Transform3D = inv * c.global_transform
			var flip := xf.basis.determinant() < 0.0
			var nbasis := xf.basis.inverse().transposed()
			for s in mesh.get_surface_count():
				var mat: Material = override if override else mesh.surface_get_material(s)
				if not groups.has(mat):
					groups[mat] = [[], [], []]
					order_mats.append(mat)
				var g: Array = groups[mat]
				var arr := mesh.surface_get_arrays(s)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var norms = arr[Mesh.ARRAY_NORMAL]
				var cols = arr[Mesh.ARRAY_COLOR]
				var idx = arr[Mesh.ARRAY_INDEX]
				var order := PackedInt32Array()
				if idx is PackedInt32Array and not idx.is_empty():
					order = idx
				else:
					order.resize(verts.size())
					for vi in verts.size():
						order[vi] = vi
				var has_n: bool = norms is PackedVector3Array and norms.size() == verts.size()
				var has_c: bool = cols is PackedColorArray and cols.size() == verts.size()
				for t in range(0, order.size() - 2, 3):
					var tri := [order[t], order[t + 2], order[t + 1]] if flip else [order[t], order[t + 1], order[t + 2]]
					for vi in tri:
						g[0].append(xf * verts[vi])
						g[1].append((nbasis * norms[vi]).normalized() if has_n else Vector3.UP)
						g[2].append(cols[vi] if has_c else Color.WHITE)
				total += order.size()
		for ch in c.get_children():
			stack.append(ch)
	var lo := Vector3.ONE * INF
	var hi := -Vector3.ONE * INF
	for mat in order_mats:
		for v in groups[mat][0]:
			lo = lo.min(v)
			hi = hi.max(v)
	if total == 0:
		return {"mesh": ArrayMesh.new(), "shape": null, "lights": [], "size": Vector3.ZERO, "vertices": 0, "offset": Vector3.ZERO}
	var offset := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	var out := ArrayMesh.new()
	for mat in order_mats:
		var g: Array = groups[mat]
		var pv := PackedVector3Array()
		pv.resize(g[0].size())
		for vi in g[0].size():
			pv[vi] = g[0][vi] - offset
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pv
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(g[1])
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray(g[2])
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	for l in lights:
		var lx: Transform3D = l.xf
		l["xf"] = Transform3D(lx.basis, lx.origin - offset)
	return {"mesh": out, "shape": out.create_trimesh_shape(), "lights": lights, "size": hi - lo, "vertices": total, "offset": offset}


func _get_built(id: String, depth := 0) -> Dictionary:
	if _built.has(id):
		return _built[id]
	if not _recipes.has(id):
		return {}
	_built[id] = {}   # guards against a model that contains itself
	var r := build(_recipes[id], depth)
	_built[id] = r.data if r.ok else {}
	if not r.ok:
		push_warning("Modello '%s' con errori: %s" % [id, "; ".join(r.errors)])
	return _built[id]


func _fill(root: Node3D, d: Dictionary, solid: bool) -> void:
	if d.is_empty():
		return
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = d.mesh
	root.add_child(mi)
	if solid and d.shape != null:
		var cs := CollisionShape3D.new()
		cs.shape = d.shape
		root.add_child(cs)
	for l in d.lights:
		var light := OmniLight3D.new()
		light.transform = l.xf
		light.light_color = l.color
		light.light_energy = l.energy
		light.omni_range = l.range
		root.add_child(light)


## A new copy of a model: origin at the CENTER OF ITS BASE, front facing +Z.
## solid = true adds collision.
func instance(id: String, solid := false) -> Node3D:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.set_meta("asset", id)
	var d := _get_built(id)
	if d.is_empty():
		push_error("Assets: modello '%s' non trovato o con errori (usa search_assets)" % id)
	_fill(root, d, solid)
	return root


## Rotation (rotation.y) that makes a model's front (+Z) face a point.
func yaw_towards(from: Vector3, target: Vector3) -> float:
	var d := target - from
	return atan2(d.x, d.z)


## Turns a node so its front (+Z) faces a point (in the same space as its position).
func face(node: Node3D, target: Vector3) -> void:
	node.rotation.y = yaw_towards(node.position, target)


func measure_model(id: String) -> AABB:
	var s: Vector3 = info(id).get("size", Vector3.ZERO)
	return AABB(Vector3(-s.x * 0.5, 0, -s.z * 0.5), s)


# ---------------------------------------------------------------- workshop

## Builds a recipe without saving it: 4 views + a report the designer can act on.
func design(rec: Dictionary) -> Dictionary:
	var r := build(rec)
	if not r.ok:
		var t := "Il modello non si costruisce:\n- " + "\n- ".join(r.errors)
		if not r.get("warnings", []).is_empty():
			t += "\nAvvisi:\n- " + "\n- ".join(r.warnings)
		return {"ok": false, "text": t}
	var d: Dictionary = r.data
	var node := Node3D.new()
	_fill(node, d, false)
	var sheet := await views(node)
	node.free()
	var lines := PackedStringArray()
	lines.append("Modello costruito: %.2f x %.2f x %.2f m (larghezza X, altezza Y, profondità Z), %d pezzi, %d vertici. Origine al centro della base, fronte verso +Z." % [d.size.x, d.size.y, d.size.z, r.pieces.size(), d.vertices])
	lines.append("Viste: in alto a sinistra FRONTE (da +Z), in alto a destra LATO (da +X), in basso a sinistra RETRO 3/4 dall'alto (da -X -Z), in basso a destra DALL'ALTO (+Z in basso).")
	# parts touching nothing: floating
	var solids: Array = r.pieces.filter(func(pc): return not pc[2])
	var detached := PackedStringArray()
	if solids.size() > 1:
		for i in solids.size():
			var a: AABB = solids[i][1].grow(0.02)
			var touches := false
			for j in solids.size():
				if i != j and a.intersects(solids[j][1]):
					touches = true
					break
			if not touches and solids[i][1].position.y > 0.01:
				detached.append(solids[i][0])
	if not detached.is_empty():
		lines.append("STACCATI (sospesi in aria senza toccare nessun altro pezzo): " + ", ".join(detached))
	if r.pieces.size() <= 40:
		lines.append("Pezzi (ingombro da..a, in coordinate del modello):")
		for pc in r.pieces:
			var b: AABB = pc[1]
			lines.append("  %s: %s .. %s" % [pc[0], _v(b.position), _v(b.end)])
	if not r.warnings.is_empty():
		lines.append("Avvisi:\n- " + "\n- ".join(r.warnings))
	var style: PackedStringArray = r.get("style", PackedStringArray())
	lines.append("Stile: ok (palette, numero di colori, dettaglio)." if style.is_empty() else "Stile (consigli, non blocca il salvataggio):\n- " + "\n- ".join(style))
	lines.append("Se ti piace: save_model(name, description). Altrimenti correggi e riprova.")
	return {"ok": true, "text": "\n".join(lines), "sheet": sheet, "image": Marshalls.raw_to_base64(sheet.save_jpg_to_buffer(0.85))}


func _v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


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
	env.background_color = Color("#7d8a96")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#dde6ee")
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_preview_vp.add_child(we)
	# key light from the upper left front, a soft fill from the right back: every face of a
	# box gets a different shade, so white objects still read
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -28, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	_preview_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 150, 0)
	fill.light_energy = 0.35
	_preview_vp.add_child(fill)
	# a floor tile with a 10 cm grid hint, so scale and contact read in the views
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("#9aa5ae")
	ground.material_override = gm
	_preview_vp.add_child(ground)
	_preview_cam = Camera3D.new()
	_preview_cam.fov = 35.0
	_preview_vp.add_child(_preview_cam)
	_preview_cam.make_current()
	_preview_holder = Node3D.new()
	_preview_vp.add_child(_preview_holder)


func _shoot(box: AABB, view_dir: Vector3, w: int, h: int) -> Image:
	var center := box.get_center()
	var radius: float = maxf(box.size.length() * 0.5, 0.2)
	var dir := view_dir.normalized()
	_preview_cam.global_position = center + dir * radius / tan(deg_to_rad(_preview_cam.fov * 0.5)) * 1.05
	if absf(dir.dot(Vector3.UP)) > 0.99:
		_preview_cam.look_at(center, Vector3.FORWARD)
	else:
		_preview_cam.look_at(center, Vector3.UP)
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _preview_vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(w, h)
	return img


## Front, side, back 3/4 and top views of a node, 800x600.
func views(node: Node3D) -> Image:
	while _preview_busy:
		await get_tree().process_frame
	_preview_busy = true
	_preview_holder.add_child(node)
	var box := World._box_in(node, Transform3D.IDENTITY)
	var sheet := Image.create(800, 600, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.55, 0.6, 0.65))
	var dirs := [Vector3(0, 0.25, 1), Vector3(1, 0.25, 0), Vector3(-0.8, 0.7, -1), Vector3(0, 1, 0.001)]
	for i in 4:
		var img: Image = await _shoot(box, dirs[i], 398, 298)
		sheet.blit_rect(img, Rect2i(0, 0, 398, 298), Vector2i((i % 2) * 400 + 1, (i / 2) * 300 + 1))
	_preview_holder.remove_child(node)
	_preview_busy = false
	return sheet


## Renders up to 9 saved models in a 3x3 grid (800x600), in the given order.
func preview(ids: Array, view_dir := Vector3(0.9, 0.75, 1.25)) -> Image:
	while _preview_busy:
		await get_tree().process_frame
	_preview_busy = true
	var sheet := Image.create(1200, 900, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.55, 0.6, 0.65))
	for i in mini(ids.size(), 9):
		var m := instance(str(ids[i]))
		_preview_holder.add_child(m)
		var img: Image = await _shoot(World._box_in(m, Transform3D.IDENTITY), view_dir, 398, 298)
		sheet.blit_rect(img, Rect2i(0, 0, 398, 298), Vector2i((i % 3) * 400 + 1, (i / 3) * 300 + 1))
		m.free()
	_preview_busy = false
	sheet.resize(800, 600, Image.INTERPOLATE_LANCZOS)
	return sheet
