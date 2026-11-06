extends Node3D
## The player's low-poly body. Invisible to the player's own camera (visual layer 2)
## but seen by the agents' photos, so they can see where you are and what you do.

const LAYER := 2   # visual layer bit value used only by the avatar

const SKIN := "#e0ac85"
const SHIRT := "#2f8fce"
const PANTS := "#3a3f4b"
const SHOES := "#2a2a2e"
const HAIR := "#4a3426"

var hip_l: Node3D
var hip_r: Node3D
var shoulder_l: Node3D
var shoulder_r: Node3D
var neck: Node3D
var torso: Node3D
var activity := "fermo"

var _phase := 0.0


func _ready() -> void:
	torso = Node3D.new()
	torso.position.y = 0.95
	add_child(torso)
	_part(torso, Shapes.box(Vector3(0.36, 0.14, 0.2), PANTS, false), Vector3(0, -0.05, 0))
	_part(torso, Shapes.box(Vector3(0.42, 0.52, 0.22), SHIRT, false), Vector3(0, 0.05, 0))

	neck = Node3D.new()
	neck.position.y = 0.6
	torso.add_child(neck)
	_part(neck, Shapes.box(Vector3(0.24, 0.27, 0.25), SKIN, false), Vector3(0, 0.02, 0))
	_part(neck, Shapes.box(Vector3(0.26, 0.08, 0.27), HAIR, false), Vector3(0, 0.27, 0.01))
	_part(neck, Shapes.box(Vector3(0.18, 0.04, 0.02), "#1d1d22", false), Vector3(0, 0.17, -0.125))  # eyes band

	shoulder_l = _limb(torso, Vector3(-0.27, 0.52, 0), [[Vector3(0.12, 0.34, 0.12), SHIRT], [Vector3(0.1, 0.3, 0.1), SKIN]])
	shoulder_r = _limb(torso, Vector3(0.27, 0.52, 0), [[Vector3(0.12, 0.34, 0.12), SHIRT], [Vector3(0.1, 0.3, 0.1), SKIN]])
	hip_l = _limb(self, Vector3(-0.1, 0.92, 0), [[Vector3(0.15, 0.48, 0.16), PANTS], [Vector3(0.14, 0.38, 0.15), PANTS], [Vector3(0.15, 0.08, 0.26), SHOES]])
	hip_r = _limb(self, Vector3(0.1, 0.92, 0), [[Vector3(0.15, 0.48, 0.16), PANTS], [Vector3(0.14, 0.38, 0.15), PANTS], [Vector3(0.15, 0.08, 0.26), SHOES]])

	var label := Label3D.new()
	label.text = "Giocatore"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.pixel_size = 0.005
	label.outline_size = 8
	label.position.y = 2.1
	label.layers = LAYER
	add_child(label)
	_set_layers(self)


## A limb hanging down from a pivot: segments stacked downward.
func _limb(parent: Node3D, pivot: Vector3, segments: Array) -> Node3D:
	var p := Node3D.new()
	p.position = pivot
	parent.add_child(p)
	var y := 0.0
	for seg in segments:
		var size: Vector3 = seg[0]
		y -= size.y
		var z := -size.z * 0.25 if size.z > 0.2 else 0.0   # shoes stick out forward
		_part(p, Shapes.box(size, seg[1], false), Vector3(0, y, z))
	return p


func _part(parent: Node3D, n: Node3D, pos: Vector3) -> void:
	n.position = pos
	parent.add_child(n)


func _set_layers(n: Node) -> void:
	if n is VisualInstance3D:
		n.layers = LAYER
	for c in n.get_children():
		_set_layers(c)


## Called every frame by the player.
func animate(delta: float, pl) -> void:
	var speed := Vector2(pl.velocity.x, pl.velocity.z).length()
	var on_floor: bool = pl.is_on_floor()
	var t := clampf(delta * 10.0, 0.0, 1.0)
	var legs := 0.0
	var arms := 0.0
	var arm_side := 0.06
	var lean := 0.0
	if pl.flying:
		activity = "vola"
		arm_side = 1.35
		legs = 0.15
		lean = -0.25 if speed > 1.0 else 0.0
	elif not on_floor:
		activity = "salta" if pl.velocity.y > 0.0 else "cade"
		legs = 0.5
		arms = -0.6
		arm_side = 0.4
	elif speed > 0.4:
		activity = "corre" if speed > pl.WALK_SPEED + 0.5 else "cammina"
		_phase += delta * speed * 2.3
		var swing := clampf(speed / pl.WALK_SPEED, 0.0, 1.5) * 0.55
		legs = sin(_phase) * swing
		arms = -sin(_phase) * swing * 0.8
		lean = 0.08 * clampf(speed / pl.WALK_SPEED, 0.0, 1.6)
	else:
		activity = "fermo"
		_phase = 0.0
	if pl.building:
		activity = "costruisce"
	hip_l.rotation.x = lerpf(hip_l.rotation.x, legs, t)
	hip_r.rotation.x = lerpf(hip_r.rotation.x, -legs if on_floor else legs * 0.6, t)
	shoulder_l.rotation.x = lerpf(shoulder_l.rotation.x, arms, t)
	shoulder_l.rotation.z = lerpf(shoulder_l.rotation.z, -arm_side, t)
	shoulder_r.rotation.z = lerpf(shoulder_r.rotation.z, arm_side, t)
	if pl.building:
		# point at what you aim: right arm raised forward, following the camera pitch
		shoulder_r.rotation.x = lerpf(shoulder_r.rotation.x, PI * 0.5 + pl.head.rotation.x, t)
	else:
		shoulder_r.rotation.x = lerpf(shoulder_r.rotation.x, -arms, t)
	torso.rotation.x = lerpf(torso.rotation.x, -lean, t)
	neck.rotation.x = lerpf(neck.rotation.x, pl.head.rotation.x * 0.8 + lean, t)
