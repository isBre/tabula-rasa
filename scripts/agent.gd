extends Node3D
## An agent's body: a floating robot in the agent's color that glides around
## and talks with speech bubbles.

const SPEED := 7.0

var agent_name := "Agente"
var color := Color(0.3, 0.9, 1.0)
var team          # team.gd, for the follow setting
var follow_slot := 0

## Slots around the player (angle from where they look, distance, height above their feet):
## in front and to the sides, so the player can see the agents while walking.
const SLOTS := [[-35.0, 4.5, 2.4], [35.0, 4.5, 2.4], [-70.0, 4.0, 2.2], [70.0, 4.0, 2.2], [-105.0, 4.0, 2.6], [105.0, 4.0, 2.6], [-140.0, 4.5, 2.6], [140.0, 4.5, 2.6]]
const FOLLOW_SPEED := 10.0
const LEASH := 16.0          # if the player gets farther than this (on the ground plane)...
const CATCH_UP_TO := 5.0     # ...the agent flies back to a spot about this close, then stays put

var _catching_up := false

var _manual := false        # true while the agent works somewhere (move_to, photos)
var _release_at := 0.0

var _target := Vector3.ZERO
var _visual: Node3D
var _ring: MeshInstance3D
var _bubble: Label3D
var _status: Label3D
var _status_text := ""
var _bubble_time := 0.0
var _t := 0.0


func _ready() -> void:
	_target = position
	_t = randf() * 10.0
	_visual = Node3D.new()
	add_child(_visual)

	var body := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.45
	sm.height = 0.9
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.13, 0.14, 0.18)
	body_mat.metallic = 0.7
	body_mat.roughness = 0.25
	sm.material = body_mat
	body.mesh = sm
	_visual.add_child(body)

	var visor := MeshInstance3D.new()
	var vm := BoxMesh.new()
	vm.size = Vector3(0.55, 0.14, 0.12)
	vm.material = _glow_mat(1.2)
	visor.mesh = vm
	visor.position = Vector3(0, 0.08, -0.38)
	_visual.add_child(visor)

	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.58
	tm.outer_radius = 0.64
	tm.material = _glow_mat(0.5)
	_ring.mesh = tm
	_ring.rotation_degrees = Vector3(15, 0, 0)
	_visual.add_child(_ring)

	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 0.5
	light.omni_range = 4.0
	_visual.add_child(light)

	_bubble = _make_label(32, Color.WHITE)
	_bubble.position.y = 1.35
	add_child(_bubble)
	_status = _make_label(24, color)
	_status.position.y = 0.8
	add_child(_status)
	set_status("")


func _glow_mat(energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


func _make_label(font_size: int, c: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.font_size = font_size
	l.pixel_size = 0.005
	l.outline_size = 10
	l.modulate = c
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.width = 600.0
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func say(text: String) -> void:
	_bubble.text = text
	_bubble_time = 8.0 + text.length() * 0.06


func set_status(text: String) -> void:
	_status_text = text
	_status.text = agent_name + ("  ·  " + text if text != "" else "")


func status_desc() -> String:
	return _status_text if _status_text != "" else "in ascolto"


func move_to(p: Vector3) -> void:
	_target = Vector3(p.x, max(p.y, 1.0), p.z)
	_manual = true
	_release_at = INF


## Go back to following the player after `seconds` (called when the agent's turn ends).
func release_after(seconds: float) -> void:
	if _manual:
		_release_at = _now() + seconds


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _follow_point() -> Vector3:
	var pl = World.player
	var slot: Array = SLOTS[follow_slot % SLOTS.size()]
	var fwd: Vector3 = pl.get_forward()
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var dir := fwd.normalized().rotated(Vector3.UP, deg_to_rad(slot[0]))
	return pl.global_position + dir * CATCH_UP_TO * float(slot[1]) / 4.5 + Vector3.UP * float(slot[2])


func _process(delta: float) -> void:
	_t += delta
	if _manual and _now() >= _release_at:
		_manual = false
	var following: bool = not _manual and team != null and team.follow and World.player != null
	if following:
		var pp: Vector3 = World.player.global_position
		var flat_dist := Vector2(position.x - pp.x, position.z - pp.z).length()
		if not _catching_up and flat_dist > LEASH:
			_catching_up = true
		if _catching_up:
			_target = _follow_point()
			if position.distance_to(_target) < 1.0:
				_catching_up = false
	else:
		_catching_up = false
	var to := _target - position
	if to.length() > 0.02:
		position += to.limit_length((FOLLOW_SPEED if _catching_up else SPEED) * delta)
	_visual.position.y = sin(_t * 2.0) * 0.08
	_ring.rotate_y(delta * 1.5)

	var look: Vector3 = _target if to.length() > 0.5 else (World.player.global_position + Vector3.UP * 1.5 if World.player else _target)
	var flat := Vector3(look.x, _visual.global_position.y, look.z)
	if flat.distance_to(_visual.global_position) > 0.2:
		var desired := _visual.global_transform.looking_at(flat, Vector3.UP).basis
		_visual.global_basis = _visual.global_basis.slerp(desired.orthonormalized(), clamp(delta * 6.0, 0.0, 1.0))

	if _bubble_time > 0.0:
		_bubble_time -= delta
		if _bubble_time <= 0.0:
			_bubble.text = ""
