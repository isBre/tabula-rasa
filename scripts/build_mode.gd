extends Node
## The player's build mode (B): select what you aim at, grab and move it on surfaces,
## rotate, scale, duplicate, delete. Every finished edit goes into the history.

var player
var ui
var team
var history

var active := false
var selected_id := ""
var grabbed := false

var _grab_offset := Vector3.ZERO
var _grab_start := Transform3D()
var _grab_rid_exclude: Array = []
var _box_mesh := ImmediateMesh.new()
var _box_node: MeshInstance3D


func _ready() -> void:
	_box_node = MeshInstance3D.new()
	_box_node.mesh = _box_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.2)
	mat.no_depth_test = true
	_box_node.material_override = mat
	add_child(_box_node)


func toggle() -> void:
	active = not active
	player.building = active
	if not active:
		_drop(false)
		selected_id = ""
	ui.add_chat("Sistema", "Modalità costruzione ON: clic seleziona · G afferra/posa · R/Shift+R ruota · rotellina ruota (Shift: scala) · +/- scala · C duplica · X elimina · Ctrl+Z annulla · B esci" if active else "Modalità costruzione OFF")


func _node():
	var n = World._get_entity(selected_id)
	return n


func status_text() -> String:
	if not active:
		return ""
	var n = _node()
	if n == null:
		return "COSTRUZIONE · mira e clicca per selezionare"
	return 'COSTRUZIONE · %s "%s"%s' % [selected_id, n.get_meta("label"), " (afferrato: clic per posare, Esc annulla)" if grabbed else ""]


func handle_input(event: InputEvent) -> bool:
	if not active:
		return false
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if grabbed:
					_drop(true)
				else:
					selected_id = player.looking_at_id
				return true
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				var up: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
				if event.shift_pressed:
					_scale(1.1 if up else 1.0 / 1.1)
				else:
					_rotate(15.0 if up else -15.0)
				return true
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_G:
				if grabbed:
					_drop(true)
				else:
					_grab()
				return true
			KEY_R:
				_rotate(-15.0 if event.shift_pressed else 15.0)
				return true
			KEY_EQUAL, KEY_KP_ADD:
				_scale(1.1)
				return true
			KEY_MINUS, KEY_KP_SUBTRACT:
				_scale(1.0 / 1.1)
				return true
			KEY_C:
				_duplicate()
				return true
			KEY_X, KEY_DELETE, KEY_BACKSPACE:
				_delete()
				return true
			KEY_ESCAPE:
				if grabbed:
					_drop(false)
					return true
				if selected_id != "":
					selected_id = ""
					return true
	return false


func _grab() -> void:
	if selected_id == "":
		selected_id = player.looking_at_id
	var n = _node()
	if n == null:
		return
	var box: AABB = World.world_aabb(n)
	_grab_offset = n.global_position - Vector3(box.get_center().x, box.position.y, box.get_center().z)
	_grab_start = n.global_transform
	_grab_rid_exclude = [player.get_rid()]
	_collect_rids(n)
	if n is RigidBody3D:
		n.freeze = true
	grabbed = true


func _collect_rids(n: Node) -> void:
	if n is CollisionObject3D:
		_grab_rid_exclude.append(n.get_rid())
	for c in n.get_children():
		_collect_rids(c)


func _drop(commit: bool) -> void:
	if not grabbed:
		return
	grabbed = false
	var n = _node()
	if n == null:
		return
	if n is RigidBody3D:
		n.freeze = false
	if not commit:
		n.global_transform = _grab_start
		return
	_record("spostato %s in %s" % [selected_id, World._v(n.global_position)], "")


func _rotate(deg: float) -> void:
	var n = _node()
	if n == null:
		return
	n.rotate_y(deg_to_rad(deg))
	if not grabbed:
		_record("ruotato %s" % selected_id, "rot_" + selected_id)


func _scale(f: float) -> void:
	var n = _node()
	if n == null:
		return
	n.scale = (n.scale * f).clamp(Vector3.ONE * 0.05, Vector3.ONE * 50.0)
	if not grabbed:
		_record("scalato %s (x%.2f)" % [selected_id, n.scale.x], "scale_" + selected_id)


func _duplicate() -> void:
	if selected_id == "":
		selected_id = player.looking_at_id
	if selected_id == "":
		return
	var r := World.duplicate_entity(selected_id, "player")
	if not r.ok:
		ui.add_chat("Sistema", r.text)
		return
	selected_id = r.id
	_record("duplicato in %s" % r.id, "")
	_grab()


func _delete() -> void:
	var id := selected_id if selected_id != "" else str(player.looking_at_id)
	if id == "":
		return
	grabbed = false
	World.delete_object({"id": id}, "player")
	selected_id = ""
	_record("eliminato %s" % id, "")


func _record(summary: String, merge_key: String) -> void:
	history.commit("giocatore", summary, merge_key)
	team.broadcast_context("[Il giocatore, in modalità costruzione, ha %s]" % summary)


func _process(_delta: float) -> void:
	_box_mesh.clear_surfaces()
	if not active:
		return
	var n = _node()
	if n == null:
		if selected_id != "":
			selected_id = ""
			grabbed = false
		return
	if grabbed:
		var cam: Camera3D = player.camera
		var from := cam.global_position
		var to: Vector3 = from + player.get_forward() * 40.0
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = _grab_rid_exclude
		var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
		var p: Vector3 = hit.position if not hit.is_empty() else from + player.get_forward() * 6.0
		n.global_position = p + _grab_offset
	_draw_box(World.world_aabb(n).grow(0.05))


func _draw_box(b: AABB) -> void:
	var c: Array = []
	for i in 8:
		c.append(b.position + Vector3(b.size.x * (i & 1), b.size.y * ((i >> 1) & 1), b.size.z * ((i >> 2) & 1)))
	_box_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for e in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		_box_mesh.surface_add_vertex(c[e[0]])
		_box_mesh.surface_add_vertex(c[e[1]])
	_box_mesh.surface_end()
