extends CharacterBody3D
## First-person player: walk, jump, fly, aim at objects.

const WALK_SPEED := 4.8
const SPRINT_SPEED := 8.0
const GROUND_ACCEL := 38.0        # m/s² when pushing
const GROUND_DECEL := 30.0        # m/s² when letting go
const AIR_ACCEL := 7.0            # little control in the air
const JUMP_VELOCITY := 5.0        # ~1.3 m jump
const FALL_GRAVITY := 1.6         # falling is faster than rising: less floaty
const SHORT_HOP_GRAVITY := 2.2    # releasing Space early makes a shorter jump
const COYOTE_TIME := 0.12         # can still jump just after walking off an edge
const JUMP_BUFFER := 0.12         # a jump pressed just before landing still happens
const FLY_SPEED := 10.0
const STEP_HEIGHT := 0.4
const EYE_HEIGHT := 1.6
const SPRINT_FOV_BONUS := 6.0

var head: Node3D
var camera: Camera3D
var flying := false
var looking_at_id := ""
var looking_point := Vector3.ZERO
var has_point := false
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

const AvatarScript := preload("res://scripts/avatar.gd")

var avatar        # avatar.gd: the body the agents see
var building := false   # set by build mode, for the pointing pose
var mouse_sens := 0.0022
var bob_amount := 0.035
var base_fov := 75.0

var _coyote := 0.0
var _jump_buffer := 0.0
var _space_was_down := false
var _was_on_floor := true
var _bob_phase := 0.0
var _bob := Vector2.ZERO
var _step_offset := 0.0
var _land_dip := 0.0


func _ready() -> void:
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	head = Node3D.new()
	head.position.y = EYE_HEIGHT
	add_child(head)
	camera = Camera3D.new()
	camera.fov = base_fov
	camera.cull_mask = 0xFFFFF & ~AvatarScript.LAYER   # you don't see your own body (only its shadow)
	avatar = AvatarScript.new()
	avatar.name = "Avatar"
	add_child(avatar)
	camera.far = 600.0
	head.add_child(camera)
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _typing() -> bool:
	return get_viewport().gui_get_focus_owner() != null


func get_forward() -> Vector3:
	return -camera.global_basis.z


func activity_desc() -> String:
	return avatar.activity if avatar else "idle"


func looking_desc() -> String:
	if looking_at_id != "":
		var n = World.entities.get(looking_at_id)
		var label: String = n.get_meta("label") if n != null and is_instance_valid(n) else "?"
		return '%s "%s" (hit point %s)' % [looking_at_id, label, World._v(looking_point)]
	if has_point:
		return "the ground at %s" % World._v(looking_point)
	return "the sky"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sens)
		head.rotate_x(-event.relative.y * mouse_sens)
		head.rotation.x = clamp(head.rotation.x, -1.55, 1.55)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _typing():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F:
		flying = not flying
		velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	var input := Vector2.ZERO
	var vertical := 0.0
	var sprint := false
	var space_down := false
	if not _typing():
		if Input.is_physical_key_pressed(KEY_W): input.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S): input.y += 1.0
		if Input.is_physical_key_pressed(KEY_A): input.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D): input.x += 1.0
		space_down = Input.is_physical_key_pressed(KEY_SPACE)
		if space_down: vertical += 1.0
		if Input.is_physical_key_pressed(KEY_C): vertical -= 1.0
		sprint = Input.is_physical_key_pressed(KEY_SHIFT) and input.y < 0.0
	input = input.limit_length(1.0)
	var wish := transform.basis * Vector3(input.x, 0.0, input.y)

	if flying:
		# fly where you look, with smooth acceleration
		var fs := FLY_SPEED * (2.5 if sprint else 1.0)
		var fly_dir := camera.global_basis * Vector3(input.x, 0.0, input.y) + Vector3.UP * vertical
		velocity = velocity.lerp(fly_dir.limit_length(1.0) * fs, clampf(delta * 6.0, 0.0, 1.0))
		move_and_slide()
	else:
		var on_floor := is_on_floor()
		_coyote = COYOTE_TIME if on_floor else _coyote - delta
		if space_down and not _space_was_down:
			_jump_buffer = JUMP_BUFFER
		else:
			_jump_buffer -= delta
		if _jump_buffer > 0.0 and _coyote > 0.0:
			velocity.y = JUMP_VELOCITY
			_jump_buffer = 0.0
			_coyote = 0.0
			on_floor = false
		if not on_floor:
			var g := gravity
			if velocity.y < 0.0:
				g *= FALL_GRAVITY
			elif not space_down:
				g *= SHORT_HOP_GRAVITY
			velocity.y -= g * delta

		var target := wish * (SPRINT_SPEED if sprint else WALK_SPEED)
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		var rate := AIR_ACCEL
		if on_floor:
			rate = GROUND_ACCEL if wish != Vector3.ZERO else GROUND_DECEL
		horizontal = horizontal.move_toward(target, rate * delta)
		velocity.x = horizontal.x
		velocity.z = horizontal.z

		if on_floor and wish != Vector3.ZERO:
			var y_before := global_position.y
			try_step_up(self, horizontal * delta, STEP_HEIGHT)
			_step_offset -= global_position.y - y_before   # camera follows the step smoothly

		var falling_speed := -velocity.y
		move_and_slide()
		if is_on_floor() and not _was_on_floor and falling_speed > 4.0:
			_land_dip = clampf(falling_speed * 0.012, 0.0, 0.14)
		_was_on_floor = is_on_floor()
	_space_was_down = space_down

	if global_position.y < -60.0:
		global_position = Vector3(0, 1, 6)
		velocity = Vector3.ZERO
	_update_camera(delta, sprint)
	_update_aim()
	avatar.animate(delta, {
		"speed": Vector2(velocity.x, velocity.z).length(),
		"vy": velocity.y,
		"on_floor": is_on_floor(),
		"flying": flying,
		"building": building,
		"pitch": head.rotation.x,
		"walk_speed": WALK_SPEED,
	})


func _update_camera(delta: float, sprint: bool) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if not flying and is_on_floor() and speed > 0.5:
		_bob_phase += delta * speed * 2.1
		var amount := bob_amount * clampf(speed / WALK_SPEED, 0.0, 1.4)
		_bob = Vector2(cos(_bob_phase) * amount * 0.6, absf(sin(_bob_phase)) * amount)
	else:
		_bob = _bob.lerp(Vector2.ZERO, clampf(delta * 8.0, 0.0, 1.0))
	_step_offset = lerpf(_step_offset, 0.0, clampf(delta * 12.0, 0.0, 1.0))
	_land_dip = lerpf(_land_dip, 0.0, clampf(delta * 7.0, 0.0, 1.0))
	head.position = Vector3(_bob.x, EYE_HEIGHT + _bob.y + _step_offset - _land_dip, 0.0)
	var fov_target := base_fov + SPRINT_FOV_BONUS if sprint and speed > WALK_SPEED + 0.5 else base_fov
	camera.fov = lerpf(camera.fov, fov_target, clampf(delta * 6.0, 0.0, 1.0))


## Climbs low steps without jumping: if the way forward is blocked but free one step
## higher, lift the body onto the step. Shared with the walk test dummy.
static func try_step_up(body: CharacterBody3D, motion: Vector3, step: float) -> void:
	var probe := motion.normalized() * maxf(motion.length(), 0.08)
	var hit := KinematicCollision3D.new()
	if not body.test_move(body.global_transform, probe, hit):
		return
	if hit.get_normal().y > 0.6:
		return  # a walkable slope, not a step
	var up := Vector3.UP * step
	if body.test_move(body.global_transform, up):
		return
	var raised := body.global_transform.translated(up)
	if body.test_move(raised, probe):
		return
	body.global_position += up
	body.velocity.y = 0.0


func _update_aim() -> void:
	var from := camera.global_position
	var to := from + get_forward() * 60.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	looking_at_id = ""
	has_point = not hit.is_empty()
	if not has_point:
		return
	looking_point = hit.position
	var n = hit.collider
	while n != null and n is Node and not n.has_meta("id"):
		n = n.get_parent()
	if n != null and n is Node:
		looking_at_id = str(n.get_meta("id"))
