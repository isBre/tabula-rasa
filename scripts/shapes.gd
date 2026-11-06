extends Node
## Shapes (autoload): a low-poly shape kit for the agents' and the player's scripts.
## Every builder returns a ready Node3D whose origin is at its BOTTOM CENTER:
## add_child() it and set its position. Faces are flat-shaded for the low-poly look.
## `mat` accepts a palette name, a Color, a "#hex" string or a Material.
## `solid` (default true) adds collision so the player can stand on / bump into it.

const PALETTE := {
	"pietra": {"color": "#8d9096", "rough": 0.95},
	"roccia": {"color": "#7a7570", "rough": 1.0},
	"mattoni": {"color": "#b4583e", "rough": 0.9},
	"intonaco": {"color": "#e9dcc3", "rough": 0.9},
	"legno": {"color": "#8b5a2b", "rough": 0.85},
	"legno_chiaro": {"color": "#c19a6b", "rough": 0.85},
	"tetto": {"color": "#a8432f", "rough": 0.8},
	"tegole_blu": {"color": "#3d5a80", "rough": 0.8},
	"erba": {"color": "#6ab04c", "rough": 1.0},
	"foglie": {"color": "#4c9a2a", "rough": 1.0},
	"foglie_scure": {"color": "#2d6a4f", "rough": 1.0},
	"foglie_chiare": {"color": "#95c95f", "rough": 1.0},
	"foglie_autunno": {"color": "#e07a3f", "rough": 1.0},
	"terra": {"color": "#8d6e4a", "rough": 1.0},
	"sabbia": {"color": "#e3c88f", "rough": 1.0},
	"neve": {"color": "#f2f5f7", "rough": 0.9},
	"acqua": {"color": "#3fa7d6c8", "rough": 0.1, "metal": 0.1},
	"vetro": {"color": "#bfe6ff66", "rough": 0.05},
	"metallo": {"color": "#a7b0b8", "rough": 0.45, "metal": 0.35},
	"ferro_scuro": {"color": "#4a4f55", "rough": 0.55, "metal": 0.3},
	"oro": {"color": "#e8c04f", "rough": 0.4, "metal": 0.4},
	"tessuto_rosso": {"color": "#c0392b", "rough": 1.0},
	"corteccia_betulla": {"color": "#e8e4da", "rough": 0.9},
	"lava": {"color": "#ff6a1a", "rough": 0.6, "glow": 3.0},
	"neon": {"color": "#4fd1ff", "rough": 0.4, "glow": 2.5},
	"luce_calda": {"color": "#ffd27a", "rough": 0.5, "glow": 2.0},
}

var _mat_cache := {}


# ================================================================ materials

## Low-poly material from the palette (or any color). Materials are cached and
## shared: call .duplicate() before changing one.
func material(kind: Variant = "pietra", tint: Variant = null) -> Material:
	if kind is Material:
		return kind
	var preset: Dictionary = {}
	var col := Color(0.8, 0.8, 0.8)
	var vertex := false
	if kind is Color:
		col = kind
	elif str(kind) == "vertex":
		vertex = true
		col = Color.WHITE
	elif PALETTE.has(str(kind)):
		preset = PALETTE[str(kind)]
		col = Color.from_string(str(preset["color"]), col)
	else:
		col = Color.from_string(str(kind), col)
	if tint != null:
		col = tint if tint is Color else Color.from_string(str(tint), col)
	var key := "%s|%s|%s" % [str(kind) if not preset.is_empty() else "", col.to_html(), vertex]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = preset.get("rough", 0.9)
	m.metallic = preset.get("metal", 0.0)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = vertex
	if col.a < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if preset.has("glow"):
		m.emission_enabled = true
		m.emission = col
		m.emission_energy_multiplier = preset["glow"]
	_mat_cache[key] = m
	return m


func palette() -> Array:
	return PALETTE.keys()


# ================================================================ mesh building

class MeshBuilder:
	var st := SurfaceTool.new()
	var use_color := false
	var tris := 0

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	## Adds a flat-shaded triangle facing `outward` (winding is fixed automatically).
	func tri(a: Vector3, b: Vector3, c: Vector3, outward: Vector3, col := Color.WHITE) -> void:
		var n := (c - a).cross(b - a)
		if n.length_squared() < 1e-12:
			return
		if n.dot(outward) < 0.0:
			var tmp := b
			b = c
			c = tmp
			n = -n
		n = n.normalized()
		for v in [a, b, c]:
			if use_color:
				st.set_color(col)
			st.set_normal(n)
			st.add_vertex(v)
		tris += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, col := Color.WHITE) -> void:
		tri(a, b, c, outward, col)
		tri(a, c, d, outward, col)

	func fan(points: Array, outward: Vector3, col := Color.WHITE) -> void:
		for i in range(1, points.size() - 1):
			tri(points[0], points[i], points[i + 1], outward, col)

	func commit() -> ArrayMesh:
		if tris == 0:
			return ArrayMesh.new()
		return st.commit()


func _finish(mesh: ArrayMesh, mat: Variant, solid: bool) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material(mat)
	if not solid or mesh.get_surface_count() == 0:
		return mi
	var body := StaticBody3D.new()
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	return body


func _v2(p) -> Vector2:
	if p is Vector2:
		return p
	if p is Array and p.size() >= 2:
		return Vector2(float(p[0]), float(p[1]))
	if p is Vector3:
		return Vector2(p.x, p.z)
	return Vector2.ZERO


func _v3(p) -> Vector3:
	return World.vec3(p)


## Outward 2D normal of edge p0->p1 of a closed polygon (works for concave ones).
func _edge_out(poly: PackedVector2Array, p0: Vector2, p1: Vector2) -> Vector2:
	var e := p1 - p0
	var n := Vector2(e.y, -e.x).normalized()
	var probe := (p0 + p1) * 0.5 + n * 0.001 * maxf(e.length(), 0.01)
	return -n if Geometry2D.is_point_in_polygon(probe, poly) else n


# ================================================================ basic solids

func box(size: Vector3 = Vector3.ONE, mat: Variant = "pietra", solid := true) -> Node3D:
	var h := size * 0.5
	var c := [
		Vector3(-h.x, 0, -h.z), Vector3(h.x, 0, -h.z), Vector3(h.x, 0, h.z), Vector3(-h.x, 0, h.z),
		Vector3(-h.x, size.y, -h.z), Vector3(h.x, size.y, -h.z), Vector3(h.x, size.y, h.z), Vector3(-h.x, size.y, h.z),
	]
	var b := MeshBuilder.new()
	b.quad(c[0], c[1], c[2], c[3], Vector3.DOWN)
	b.quad(c[4], c[5], c[6], c[7], Vector3.UP)
	b.quad(c[0], c[1], c[5], c[4], Vector3.FORWARD)
	b.quad(c[3], c[2], c[6], c[7], Vector3.BACK)
	b.quad(c[0], c[3], c[7], c[4], Vector3.LEFT)
	b.quad(c[1], c[2], c[6], c[5], Vector3.RIGHT)
	return _finish(b.commit(), mat, solid)


## Revolves a profile [Vector2(radius, y), ...] (bottom to top) around the Y axis.
## Start and end with radius 0 to close the bottom and the top.
func lathe(profile: Array, sides := 10, mat: Variant = "pietra", solid := true, jitter := 0.0, random_seed := 0, scale := Vector3.ONE) -> Node3D:
	var prof: Array = profile.map(func(p): return _v2(p))
	sides = clampi(sides, 3, 64)
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var grid: Array = []
	for p in prof:
		var ring: Array = []
		for j in sides:
			var ang := TAU * j / sides
			var v := Vector3(cos(ang) * p.x, p.y, sin(ang) * p.x)
			if jitter > 0.0 and p.x > 0.001:
				v += Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * jitter
			ring.append(v * scale)
		grid.append(ring)
	var b := MeshBuilder.new()
	for i in prof.size() - 1:
		var d: Vector2 = prof[i + 1] - prof[i]
		for j in sides:
			var j2 := (j + 1) % sides
			var mid := TAU * (j + 0.5) / sides
			var radial := Vector3(cos(mid), 0, sin(mid))
			var outward := radial * d.y - Vector3.UP * d.x
			if outward.length_squared() < 1e-9:
				outward = radial
			b.quad(grid[i][j], grid[i + 1][j], grid[i + 1][j2], grid[i][j2], outward * scale.inverse())
	return _finish(b.commit(), mat, solid)


func cylinder(radius := 0.5, height := 1.0, sides := 8, mat: Variant = "pietra", solid := true) -> Node3D:
	return lathe([Vector2(0, 0), Vector2(radius, 0), Vector2(radius, height), Vector2(0, height)], sides, mat, solid)


func cone(radius := 0.5, height := 1.0, sides := 8, mat: Variant = "pietra", solid := true) -> Node3D:
	return lathe([Vector2(0, 0), Vector2(radius, 0), Vector2(0, height)], sides, mat, solid)


func _sphere_profile(radius: float, rings: int) -> Array:
	var prof: Array = []
	for k in rings + 1:
		var a := -PI / 2 + PI * k / rings
		prof.append(Vector2(cos(a) * radius if k > 0 and k < rings else 0.0, radius + sin(a) * radius))
	return prof


## Low-poly sphere resting on y=0. detail 2..6.
func sphere(radius := 0.5, detail := 3, mat: Variant = "pietra", solid := true) -> Node3D:
	var rings := clampi(detail, 2, 8) + 2
	return lathe(_sphere_profile(radius, rings), rings * 2, mat, solid)


## Irregular low-poly rock of roughly `size`.
func rock(size: Variant = Vector3(1, 0.8, 1), random_seed := 0, roughness := 0.25, mat: Variant = "roccia", solid := true) -> Node3D:
	var s: Vector3 = size if size is Vector3 else (Vector3.ONE * float(size))
	return lathe(_sphere_profile(0.5, 5), 7, mat, solid, roughness * 0.5, random_seed, s)


## Bushy blob of foliage.
func bush(size := 1.0, random_seed := 0, mat: Variant = "foglie") -> Node3D:
	return lathe(_sphere_profile(0.5, 4), 7, mat, false, 0.12, random_seed, Vector3(size, size * 0.75, size))


# ================================================================ extrusion and sweeps

## Extrudes a polygon. axis "y": polygon is a footprint [Vector2(x, z)...] raised from y=0 to depth.
## axis "z": polygon is a front profile [Vector2(x, y)...] extruded along Z, centered on z=0.
func extrude(polygon: Array, depth := 1.0, mat: Variant = "pietra", solid := true, axis := "y") -> Node3D:
	var poly := PackedVector2Array()
	for p in polygon:
		poly.append(_v2(p))
	var idx := Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		push_error("Shapes.extrude: poligono non valido (lati che si incrociano o meno di 3 punti)")
		return Node3D.new()
	var on_y := axis != "z"
	var h0 := 0.0 if on_y else -depth * 0.5
	var h1 := depth if on_y else depth * 0.5
	var up := Vector3.UP if on_y else Vector3.BACK
	var to3 := func(p: Vector2, h: float) -> Vector3: return Vector3(p.x, h, p.y) if on_y else Vector3(p.x, p.y, h)
	var b := MeshBuilder.new()
	for t in range(0, idx.size(), 3):
		var a := poly[idx[t]]
		var bb := poly[idx[t + 1]]
		var c := poly[idx[t + 2]]
		b.tri(to3.call(a, h0), to3.call(bb, h0), to3.call(c, h0), -up)
		b.tri(to3.call(a, h1), to3.call(bb, h1), to3.call(c, h1), up)
	for i in poly.size():
		var p0 := poly[i]
		var p1 := poly[(i + 1) % poly.size()]
		var n2 := _edge_out(poly, p0, p1)
		var out3: Vector3 = to3.call(n2, 0.0) - to3.call(Vector2.ZERO, 0.0)
		b.quad(to3.call(p0, h0), to3.call(p1, h0), to3.call(p1, h1), to3.call(p0, h1), out3)
	return _finish(b.commit(), mat, solid)


## Drags a closed 2D profile [Vector2(side, up)...] along a path [Vector3...].
## The profile stays upright (good for roads, rails, walls following a curve).
func sweep(profile: Array, path: Array, mat: Variant = "pietra", solid := true) -> Node3D:
	var prof := PackedVector2Array()
	for p in profile:
		prof.append(_v2(p))
	var pts: Array = path.map(func(p): return _v3(p))
	if pts.size() < 2 or prof.size() < 2:
		push_error("Shapes.sweep: servono almeno 2 punti nel percorso e 2 nel profilo")
		return Node3D.new()
	var frames: Array = []
	for k in pts.size():
		var t: Vector3 = (pts[min(k + 1, pts.size() - 1)] - pts[max(k - 1, 0)]).normalized()
		var side := t.cross(Vector3.UP)
		if side.length() < 0.01:
			side = t.cross(Vector3.RIGHT)
		side = side.normalized()
		frames.append([t, side, side.cross(t).normalized()])
	var rings: Array = []
	for k in pts.size():
		var ring: Array = []
		for q in prof:
			ring.append(pts[k] + frames[k][1] * q.x + frames[k][2] * q.y)
		rings.append(ring)
	var closed := prof.size() >= 3
	var b := MeshBuilder.new()
	var n := prof.size()
	for k in pts.size() - 1:
		for i in (n if closed else n - 1):
			var i2 := (i + 1) % n
			var out2 := _edge_out(prof, prof[i], prof[i2]) if closed else Vector2(0, 1)
			var out3: Vector3 = (frames[k][1] + frames[k + 1][1]) * 0.5 * out2.x + (frames[k][2] + frames[k + 1][2]) * 0.5 * out2.y
			b.quad(rings[k][i], rings[k][i2], rings[k + 1][i2], rings[k + 1][i], out3)
	if closed:
		var idx := Geometry2D.triangulate_polygon(prof)
		for t in range(0, idx.size(), 3):
			b.tri(rings[0][idx[t]], rings[0][idx[t + 1]], rings[0][idx[t + 2]], -frames[0][0])
			b.tri(rings[-1][idx[t]], rings[-1][idx[t + 1]], rings[-1][idx[t + 2]], frames[-1][0])
	return _finish(b.commit(), mat, solid)


func tube(path: Array, radius := 0.1, sides := 6, mat: Variant = "metallo", solid := true) -> Node3D:
	var prof: Array = []
	for j in sides:
		var a := TAU * j / sides
		prof.append(Vector2(cos(a) * radius, sin(a) * radius))
	return sweep(prof, path, mat, solid)


## Flat strip following a path on the ground: roads, paths, rivers.
func ribbon(path: Array, width := 3.0, thickness := 0.1, mat: Variant = "pietra", solid := true) -> Node3D:
	var w := width * 0.5
	return sweep([Vector2(-w, 0), Vector2(w, 0), Vector2(w, thickness), Vector2(-w, thickness)], path, mat, solid)


# ================================================================ architecture

## Wall along X (thickness along Z) with rectangular openings:
## openings = [{"x": center offset, "y": bottom height, "w": width, "h": height}, ...]
func wall(width := 4.0, height := 3.0, thickness := 0.25, openings: Array = [], mat: Variant = "intonaco", solid := true) -> Node3D:
	var root := Node3D.new()
	var csg := CSGBox3D.new()
	csg.size = Vector3(width, height, thickness)
	csg.position.y = height * 0.5
	csg.material = material(mat)
	csg.use_collision = solid
	root.add_child(csg)
	for o in openings:
		if not o is Dictionary:
			continue
		var hole := CSGBox3D.new()
		var ow := float(o.get("w", 1.0))
		var oh := float(o.get("h", 2.0))
		hole.size = Vector3(ow, oh, thickness + 0.2)
		hole.position = Vector3(float(o.get("x", 0.0)), float(o.get("y", 0.0)) + oh * 0.5 - height * 0.5, 0)
		hole.operation = CSGShape3D.OPERATION_SUBTRACTION
		csg.add_child(hole)
	return root


## Round arch facing Z: outer width, total height, side thickness, depth along Z.
func arch(width := 3.0, height := 3.5, thickness := 0.5, depth := 0.6, mat: Variant = "pietra", segments := 10, solid := true) -> Node3D:
	var r_out := width * 0.5
	var r_in: float = max(r_out - thickness, 0.05)
	var spring: float = max(height - r_out, 0.0)
	var poly: Array = [Vector2(-r_out, 0)]
	for k in segments + 1:
		var a := PI - PI * k / segments
		poly.append(Vector2(cos(a) * r_out, spring + sin(a) * r_out))
	poly.append(Vector2(r_out, 0))
	poly.append(Vector2(r_in, 0))
	for k in segments + 1:
		var a := PI * k / segments
		poly.append(Vector2(cos(a) * r_in, spring + sin(a) * r_in))
	poly.append(Vector2(-r_in, 0))
	return extrude(poly, depth, mat, solid, "z")


## Roof whose base (at y=0) covers width (X) x depth (Z) plus overhang.
## kind: "gable" (ridge along Z), "hip", "pyramid", "shed", "flat".
func roof(kind := "gable", width := 6.0, depth := 6.0, height := 2.0, overhang := 0.3, mat: Variant = "tetto", solid := true) -> Node3D:
	var W := width + overhang * 2.0
	var D := depth + overhang * 2.0
	match kind:
		"flat":
			return box(Vector3(W, max(height, 0.1), D), mat, solid)
		"gable":
			return extrude([Vector2(-W / 2, 0), Vector2(W / 2, 0), Vector2(0, height)], D, mat, solid, "z")
		"shed":
			return extrude([Vector2(-W / 2, 0), Vector2(W / 2, 0), Vector2(-W / 2, height)], D, mat, solid, "z")
	var c1 := Vector3(-W / 2, 0, -D / 2)
	var c2 := Vector3(W / 2, 0, -D / 2)
	var c3 := Vector3(W / 2, 0, D / 2)
	var c4 := Vector3(-W / 2, 0, D / 2)
	var faces: Array = []
	if kind == "pyramid" or is_equal_approx(W, D):
		var apex := Vector3(0, height, 0)
		faces = [[c1, c2, apex], [c2, c3, apex], [c3, c4, apex], [c4, c1, apex]]
	elif D > W:
		var r := (D - W) / 2
		var r1 := Vector3(0, height, -r)
		var r2 := Vector3(0, height, r)
		faces = [[c1, c2, r1], [c2, c3, r2, r1], [c3, c4, r2], [c4, c1, r1, r2]]
	else:
		var r := (W - D) / 2
		var r1 := Vector3(-r, height, 0)
		var r2 := Vector3(r, height, 0)
		faces = [[c1, c2, r2, r1], [c2, c3, r2], [c3, c4, r1, r2], [c4, c1, r1]]
	var b := MeshBuilder.new()
	var center := Vector3(0, height * 0.3, 0)
	for f in faces:
		var fc := Vector3.ZERO
		for v in f:
			fc += v
		b.fan(f, fc / f.size() - center)
	b.fan([c1, c2, c3, c4], Vector3.DOWN)
	return _finish(b.commit(), mat, solid)


## Solid staircase climbing toward -Z from z=0. steps=0 picks ~0.2 m risers.
func stairs(width := 2.0, height := 2.0, depth := 3.0, steps := 0, mat: Variant = "pietra", solid := true) -> Node3D:
	if steps <= 0:
		steps = maxi(1, roundi(height / 0.2))
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	var rise := height / steps
	var run := depth / steps
	var b := MeshBuilder.new()
	for i in steps:
		var top := rise * (i + 1)
		var z0 := -run * i
		var z1 := -run * (i + 1)
		var x := width * 0.5
		b.quad(Vector3(-x, top, z0), Vector3(x, top, z0), Vector3(x, top, z1), Vector3(-x, top, z1), Vector3.UP)
		b.quad(Vector3(-x, top - rise, z0), Vector3(x, top - rise, z0), Vector3(x, top, z0), Vector3(-x, top, z0), Vector3.BACK)
		b.quad(Vector3(-x, 0, z0), Vector3(-x, 0, z1), Vector3(-x, top, z1), Vector3(-x, top, z0), Vector3.LEFT)
		b.quad(Vector3(x, 0, z0), Vector3(x, 0, z1), Vector3(x, top, z1), Vector3(x, top, z0), Vector3.RIGHT)
		if solid:
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(width, top, run)
			cs.shape = bs
			cs.position = Vector3(0, top * 0.5, (z0 + z1) * 0.5)
			root.add_child(cs)
	var x2 := width * 0.5
	b.quad(Vector3(-x2, 0, -depth), Vector3(x2, 0, -depth), Vector3(x2, height, -depth), Vector3(-x2, height, -depth), Vector3.FORWARD)
	var mi := MeshInstance3D.new()
	mi.mesh = b.commit()
	mi.material_override = material(mat)
	root.add_child(mi)
	return root


## Wooden fence along a path: posts every `spacing` meters and two rails.
func fence(path: Array, height := 1.0, spacing := 2.0, mat: Variant = "legno", solid := true) -> Node3D:
	var pts: Array = path.map(func(p): return _v3(p))
	var root := Node3D.new()
	var posts: Array = []
	for k in pts.size() - 1:
		var seg: Vector3 = pts[k + 1] - pts[k]
		var count := maxi(1, ceili(seg.length() / spacing))
		for s in count:
			posts.append(pts[k] + seg * (float(s) / count))
	posts.append(pts[-1])
	for p in posts:
		var post := box(Vector3(0.14, height, 0.14), mat, solid)
		post.position = p
		root.add_child(post)
	for frac in [0.45, 0.85]:
		var rail: Array = pts.map(func(p): return p + Vector3.UP * height * frac)
		root.add_child(tube(rail, 0.05, 4, mat, solid))
	return root


# ================================================================ nature

## Low-poly tree. kind: "round", "pine", "birch", "autumn".
func tree(kind := "round", height := 4.0, random_seed := 0, solid := true) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	height *= rng.randf_range(0.9, 1.1)
	var root := Node3D.new()
	var trunk_mat := "corteccia_betulla" if kind == "birch" else "legno"
	var trunk_h := height * (0.35 if kind == "pine" else 0.55)
	var r := height * (0.035 if kind == "birch" else 0.055)
	root.add_child(lathe([Vector2(0, 0), Vector2(r, 0), Vector2(r * 0.7, trunk_h), Vector2(0, trunk_h)], 6, trunk_mat, solid))
	match kind:
		"pine":
			var levels := 3
			for i in levels:
				var base_y := trunk_h * 0.6 + i * height * 0.2
				var cr := height * (0.3 - i * 0.07)
				var c := cone(cr, height * 0.38, 7, "foglie_scure", false)
				c.position.y = base_y
				c.rotation.y = rng.randf() * TAU
				root.add_child(c)
		_:
			var leaf: String = "foglie_autunno" if kind == "autumn" else ("foglie_chiare" if kind == "birch" else ["foglie", "foglie_scure", "foglie_chiare"][rng.randi() % 3])
			var blobs := 3 if kind != "birch" else 2
			var size := height * (0.5 if kind != "birch" else 0.38)
			for i in blobs:
				var blob := lathe(_sphere_profile(0.5, 4), 7, leaf, false, 0.1, random_seed * 7 + i, Vector3.ONE * size * rng.randf_range(0.75, 1.0))
				blob.position = Vector3(rng.randf_range(-0.25, 0.25) * size, trunk_h - size * 0.25 + i * size * 0.18, rng.randf_range(-0.25, 0.25) * size)
				root.add_child(blob)
	return root


## Low-poly hills: size x size meters centered on the origin, colored by height when
## mat is "auto". Edges fade down to y=0 so it blends with the ground.
func terrain(size := 40.0, height := 4.0, resolution := 24, random_seed := 0, mat: Variant = "auto", solid := true) -> Node3D:
	resolution = clampi(resolution, 4, 96)
	var noise := FastNoiseLite.new()
	noise.seed = random_seed
	noise.frequency = 2.5 / size
	var step := size / resolution
	var hgt := func(x: float, z: float) -> float:
		var edge: float = 1.0 - max(absf(x), absf(z)) / (size * 0.5)
		var fade := clampf(edge * 4.0, 0.0, 1.0)
		return maxf(0.0, (noise.get_noise_2d(x, z) * 0.5 + 0.5) * height * fade)
	var b := MeshBuilder.new()
	var auto: bool = str(mat) == "auto"
	b.use_color = auto
	for i in resolution:
		for j in resolution:
			var x0 := -size * 0.5 + i * step
			var z0 := -size * 0.5 + j * step
			var p00 := Vector3(x0, hgt.call(x0, z0), z0)
			var p10 := Vector3(x0 + step, hgt.call(x0 + step, z0), z0)
			var p01 := Vector3(x0, hgt.call(x0, z0 + step), z0 + step)
			var p11 := Vector3(x0 + step, hgt.call(x0 + step, z0 + step), z0 + step)
			b.tri(p00, p10, p11, Vector3.UP, _height_color((p00.y + p10.y + p11.y) / 3.0, height))
			b.tri(p00, p11, p01, Vector3.UP, _height_color((p00.y + p11.y + p01.y) / 3.0, height))
	return _finish(b.commit(), "vertex" if auto else mat, solid)


func _height_color(y: float, max_h: float) -> Color:
	var t := y / maxf(max_h, 0.01)
	if t < 0.08:
		return Color("#d9c38c")
	if t < 0.55:
		return Color("#6ab04c").lerp(Color("#4c9a2a"), t)
	if t < 0.8:
		return Color("#8a8178")
	return Color("#f2f5f7")


## Flat water surface (not solid), size_x by size_z, slightly above y=0.
func water(size_x := 10.0, size_z := 10.0, mat: Variant = "acqua") -> Node3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(size_x, size_z)
	mi.mesh = pm
	mi.position.y = 0.03
	mi.material_override = material(mat)
	return mi


# ================================================================ misc

## 3D text standing on y=0, facing +Z. size = letter height in meters.
func text(content := "Ciao", size := 1.0, depth := 0.1, mat: Variant = "intonaco") -> Node3D:
	var tm := TextMesh.new()
	tm.text = content
	tm.font_size = 64
	tm.pixel_size = size / 64.0
	tm.depth = depth
	var mi := MeshInstance3D.new()
	mi.mesh = tm
	mi.material_override = material(mat)
	mi.position.y = size * 0.5
	var root := Node3D.new()
	root.add_child(mi)
	return root


## Scatters factory.call(i) results randomly over an area (x by z) centered on the
## origin, keeping min_distance between them and a random rotation.
func scatter(factory: Callable, count := 20, area: Variant = Vector2(20, 20), random_seed := 0, min_distance := 1.5) -> Node3D:
	var a: Vector2 = area if area is Vector2 else Vector2.ONE * float(area)
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var root := Node3D.new()
	var placed: Array = []
	for i in mini(count, 500):
		for attempt in 30:
			var p := Vector3(rng.randf_range(-a.x, a.x) * 0.5, 0, rng.randf_range(-a.y, a.y) * 0.5)
			var ok := true
			for q in placed:
				if p.distance_to(q) < min_distance:
					ok = false
					break
			if ok:
				var n = factory.call(i)
				if n is Node3D:
					n.position += p
					n.rotation.y = rng.randf() * TAU
					root.add_child(n)
				placed.append(p)
				break
	return root
