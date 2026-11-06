extends Node
## Walk test: a dummy with the player's size and physics tries to walk a path
## (jumping when blocked, like a person would) and reports what happened.
## The simulation runs many physics steps per frame, so it takes well under a second.

const RADIUS := 0.35
const HEIGHT := 1.8
const SPEED := 4.8
const JUMP_VELOCITY := 5.0
const DT := 1.0 / 60.0
const MAX_SECONDS := 25.0
const STEPS_PER_FRAME := 150
const STUCK_SECONDS := 1.5
const STEP_HEIGHT := 0.4
const PlayerScript := preload("res://scripts/player.gd")

var _busy := false


func run(points: Array, color: Color) -> Dictionary:
	while _busy:
		await get_tree().process_frame
	_busy = true
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

	var walker := CharacterBody3D.new()
	walker.collision_layer = 0
	walker.collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = RADIUS
	cap.height = HEIGHT
	cs.shape = cap
	cs.position.y = HEIGHT * 0.5
	walker.add_child(cs)
	World.root.add_child(walker)
	if World.player:
		walker.add_collision_exception_with(World.player)
	walker.global_position = points[0] + Vector3.UP * 0.05

	var trail: Array = [walker.global_position]
	var idx := 1
	var t := 0.0
	var jumps := 0
	var max_drop := 0.0
	var last_floor_y := walker.global_position.y
	var last_progress_t := 0.0
	var best_dist := INF
	var outcome := ""
	var steps := 0

	while t < MAX_SECONDS:
		var goal: Vector3 = points[idx]
		var to := goal - walker.global_position
		var flat := Vector3(to.x, 0, to.z)
		if flat.length() < 0.5 and absf(to.y) < 1.6:
			if idx == points.size() - 1:
				outcome = "arrivato"
				break
			idx += 1
			best_dist = INF
			last_progress_t = t
			continue
		var dir := flat.normalized()
		walker.velocity.x = dir.x * SPEED
		walker.velocity.z = dir.z * SPEED
		if walker.is_on_floor():
			PlayerScript.try_step_up(walker, Vector3(walker.velocity.x, 0, walker.velocity.z) * DT, STEP_HEIGHT)
		if walker.is_on_floor():
			var drop := last_floor_y - walker.global_position.y
			max_drop = max(max_drop, drop)
			last_floor_y = walker.global_position.y
			if walker.is_on_wall() or (t - last_progress_t > 0.4):
				walker.velocity.y = JUMP_VELOCITY
				jumps += 1
		else:
			walker.velocity.y -= gravity * DT
		walker.move_and_slide()
		t += DT
		steps += 1
		if steps % 6 == 0:
			trail.append(walker.global_position)
		var d := flat.length()
		if d < best_dist - 0.05:
			best_dist = d
			last_progress_t = t
		elif t - last_progress_t > STUCK_SECONDS:
			outcome = "bloccato"
			break
		if walker.global_position.y < -10.0:
			outcome = "caduto nel vuoto"
			break
		if steps % STEPS_PER_FRAME == 0:
			await get_tree().process_frame
	if outcome == "":
		outcome = "tempo scaduto"

	var pos := walker.global_position
	var report := {"outcome": outcome, "seconds": snappedf(t, 0.1), "jumps": jumps, "position": pos, "max_drop": max_drop, "waypoint": idx}
	if outcome == "bloccato":
		report["obstacle"] = _describe_obstacle(walker, (Vector3(points[idx].x, pos.y, points[idx].z) - pos).normalized())
	trail.append(pos)
	walker.queue_free()
	_draw_trail(trail, color, outcome == "arrivato")
	_busy = false
	return report


func _describe_obstacle(walker: CharacterBody3D, dir: Vector3) -> String:
	var space := walker.get_world_3d().direct_space_state
	var base := walker.global_position
	var parts := PackedStringArray()
	var q := PhysicsRayQueryParameters3D.create(base + Vector3.UP * 0.9, base + Vector3.UP * 0.9 + dir * 1.5)
	q.exclude = [walker.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return "nessun ostacolo davanti (forse un buco, un dislivello o un passaggio troppo stretto)"
	parts.append("davanti c'è " + _id_of(hit.collider))
	var probe: Vector3 = hit.position + dir * 0.2
	var q2 := PhysicsRayQueryParameters3D.create(probe + Vector3.UP * 20.0, probe - Vector3.UP * 1.0)
	q2.exclude = [walker.get_rid()]
	var top := space.intersect_ray(q2)
	if not top.is_empty():
		var h: float = top.position.y - base.y
		parts.append("alto circa %.2f m rispetto ai piedi (il salto massimo è circa 1.2 m)" % h)
	return ", ".join(parts)


func _id_of(collider) -> String:
	var n = collider
	while n != null and n is Node and not n.has_meta("id"):
		n = n.get_parent()
	if n != null and n is Node:
		return '%s "%s"' % [n.get_meta("id"), n.get_meta("label")]
	return "il terreno o un oggetto senza id"


func _draw_trail(points: Array, color: Color, success: bool) -> void:
	if points.size() < 2:
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in points:
		im.surface_add_vertex(p + Vector3.UP * 0.1)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color if success else Color(1, 0.25, 0.25)
	mat.no_depth_test = true
	mi.material_override = mat
	World.root.get_parent().add_child(mi)
	get_tree().create_timer(10.0).timeout.connect(mi.queue_free)
