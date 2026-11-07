extends Node3D
## A low-poly humanoid body: the player's (hidden from their own camera, visual layer 2)
## and the agents' (visible to everyone, with their own colors). Animated from a small
## state dictionary: walking, running, jumping, flying, pointing at work, talking.

const LAYER := 2   # visual layer bit value used only by the player's own body

var skin := "#e0ac85"
var shirt := "#2f8fce"
var pants := "#3a3f4b"
var shoes := "#2a2a2e"
var hair := "#4a3426"
var hair_style := "corti"   # corti | lunghi | cresta | calvo
var hat := "nessuno"        # nessuno | berretto | cilindro | cuoco | paglia | corona
var label_text := "Giocatore"
var label_color := Color.WHITE
var hidden_from_owner := true   # player's body: not drawn by the player's camera
var label_height := 2.1

var hip_l: Node3D
var hip_r: Node3D
var shoulder_l: Node3D
var shoulder_r: Node3D
var neck: Node3D
var torso: Node3D
var mouth: Node3D
var label: Label3D
var activity := "fermo"

var _phase := 0.0
var _talk_t := 0.0


func _ready() -> void:
	torso = Node3D.new()
	torso.position.y = 0.95
	add_child(torso)
	_part(torso, Shapes.box(Vector3(0.36, 0.14, 0.2), pants, false), Vector3(0, -0.05, 0))
	_part(torso, Shapes.box(Vector3(0.42, 0.52, 0.22), shirt, false), Vector3(0, 0.05, 0))

	neck = Node3D.new()
	neck.position.y = 0.6
	torso.add_child(neck)
	_part(neck, Shapes.box(Vector3(0.24, 0.27, 0.25), skin, false), Vector3(0, 0.02, 0))
	_hair_and_hat()
	_part(neck, Shapes.box(Vector3(0.18, 0.035, 0.02), "#1d1d22", false), Vector3(0, 0.18, -0.125))  # eyes band
	mouth = Node3D.new()
	mouth.position = Vector3(0, 0.085, -0.127)
	neck.add_child(mouth)
	_part(mouth, Shapes.box(Vector3(0.08, 0.025, 0.02), "#5a2028", false), Vector3(0, -0.0125, 0))

	shoulder_l = _limb(torso, Vector3(-0.27, 0.52, 0), [[Vector3(0.12, 0.34, 0.12), shirt], [Vector3(0.1, 0.3, 0.1), skin]])
	shoulder_r = _limb(torso, Vector3(0.27, 0.52, 0), [[Vector3(0.12, 0.34, 0.12), shirt], [Vector3(0.1, 0.3, 0.1), skin]])
	hip_l = _limb(self, Vector3(-0.1, 0.92, 0), [[Vector3(0.15, 0.48, 0.16), pants], [Vector3(0.14, 0.38, 0.15), pants], [Vector3(0.15, 0.08, 0.26), shoes]])
	hip_r = _limb(self, Vector3(0.1, 0.92, 0), [[Vector3(0.15, 0.48, 0.16), pants], [Vector3(0.14, 0.38, 0.15), pants], [Vector3(0.15, 0.08, 0.26), shoes]])

	label = Label3D.new()
	label.text = label_text
	label.modulate = label_color
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 28
	label.pixel_size = 0.005
	label.outline_size = 8
	label.position.y = label_height
	add_child(label)
	if hidden_from_owner:
		_set_layers(self)


## Hair and hat on the head (the face looks toward -Z, the top of the head is at y 0.29).
func _hair_and_hat() -> void:
	match hair_style:
		"calvo":
			pass
		"cresta":
			_part(neck, Shapes.box(Vector3(0.07, 0.12, 0.25), hair, false), Vector3(0, 0.27, 0.01))
		"lunghi":
			_part(neck, Shapes.box(Vector3(0.26, 0.08, 0.27), hair, false), Vector3(0, 0.27, 0.01))
			_part(neck, Shapes.box(Vector3(0.27, 0.3, 0.06), hair, false), Vector3(0, 0.02, 0.11))
			for side in [-1, 1]:
				_part(neck, Shapes.box(Vector3(0.03, 0.2, 0.18), hair, false), Vector3(side * 0.13, 0.1, 0.04))
		_:
			_part(neck, Shapes.box(Vector3(0.26, 0.08, 0.27), hair, false), Vector3(0, 0.27, 0.01))
	match hat:
		"berretto":
			_part(neck, Shapes.box(Vector3(0.28, 0.08, 0.29), shirt, false), Vector3(0, 0.29, 0.01))
			_part(neck, Shapes.box(Vector3(0.22, 0.02, 0.13), shirt, false), Vector3(0, 0.29, -0.18))
		"cilindro":
			_part(neck, Shapes.box(Vector3(0.38, 0.02, 0.38), "#1f1f24", false), Vector3(0, 0.3, 0.01))
			_part(neck, Shapes.box(Vector3(0.22, 0.26, 0.22), "#1f1f24", false), Vector3(0, 0.32, 0.01))
			_part(neck, Shapes.box(Vector3(0.225, 0.04, 0.225), shirt, false), Vector3(0, 0.33, 0.01))
		"cuoco":
			_part(neck, Shapes.box(Vector3(0.27, 0.07, 0.28), "#f4f4f2", false), Vector3(0, 0.28, 0.01))
			_part(neck, Shapes.box(Vector3(0.32, 0.18, 0.32), "#ffffff", false), Vector3(0, 0.35, 0.01))
		"paglia":
			_part(neck, Shapes.box(Vector3(0.52, 0.02, 0.52), "#d8b45a", false), Vector3(0, 0.3, 0.01))
			_part(neck, Shapes.box(Vector3(0.25, 0.1, 0.25), "#d8b45a", false), Vector3(0, 0.31, 0.01))
			_part(neck, Shapes.box(Vector3(0.255, 0.03, 0.255), "#a8432f", false), Vector3(0, 0.32, 0.01))
		"corona":
			_part(neck, Shapes.box(Vector3(0.27, 0.05, 0.28), "oro", false), Vector3(0, 0.3, 0.01))
			for x in [-0.11, 0.0, 0.11]:
				for z in [-0.12, 0.12]:
					_part(neck, Shapes.box(Vector3(0.05, 0.07, 0.04), "oro", false), Vector3(x, 0.34, z + 0.01))


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


## state: speed (horizontal m/s), vy, on_floor, flying, building (pointing),
## pitch (head up/down, radians), talking, walk_speed (for the stride)
func animate(delta: float, state: Dictionary) -> void:
	var speed: float = state.get("speed", 0.0)
	var on_floor: bool = state.get("on_floor", true)
	var flying: bool = state.get("flying", false)
	var building: bool = state.get("building", false)
	var pitch: float = state.get("pitch", 0.0)
	var walk_speed: float = state.get("walk_speed", 4.8)
	var t := clampf(delta * 10.0, 0.0, 1.0)
	var legs := 0.0
	var arms := 0.0
	var arm_side := 0.06
	var lean := 0.0
	if flying:
		activity = "vola"
		arm_side = 1.35
		legs = 0.15
		lean = -0.25 if speed > 1.0 else 0.0
	elif not on_floor:
		activity = "salta" if state.get("vy", 0.0) > 0.0 else "cade"
		legs = 0.5
		arms = -0.6
		arm_side = 0.4
	elif speed > 0.4:
		activity = "corre" if speed > walk_speed + 0.5 else "cammina"
		_phase += delta * speed * 2.3
		var swing := clampf(speed / walk_speed, 0.0, 1.5) * 0.55
		legs = sin(_phase) * swing
		arms = -sin(_phase) * swing * 0.8
		lean = 0.08 * clampf(speed / walk_speed, 0.0, 1.6)
	else:
		activity = "fermo"
		_phase = 0.0
	if building:
		activity = "costruisce"
	hip_l.rotation.x = lerpf(hip_l.rotation.x, legs, t)
	hip_r.rotation.x = lerpf(hip_r.rotation.x, -legs if on_floor else legs * 0.6, t)
	shoulder_l.rotation.x = lerpf(shoulder_l.rotation.x, arms, t)
	shoulder_l.rotation.z = lerpf(shoulder_l.rotation.z, -arm_side, t)
	shoulder_r.rotation.z = lerpf(shoulder_r.rotation.z, arm_side, t)
	if building:
		shoulder_r.rotation.x = lerpf(shoulder_r.rotation.x, PI * 0.5 + pitch, t)
	else:
		shoulder_r.rotation.x = lerpf(shoulder_r.rotation.x, -arms, t)
	torso.rotation.x = lerpf(torso.rotation.x, -lean, t)
	neck.rotation.x = lerpf(neck.rotation.x, pitch * 0.8 + lean, t)
	# mouth: opens and closes while talking
	if state.get("talking", false):
		_talk_t += delta
		mouth.scale.y = 1.0 + absf(sin(_talk_t * 13.0)) * 2.8 * (0.6 + 0.4 * absf(sin(_talk_t * 3.1)))
	else:
		_talk_t = 0.0
		mouth.scale.y = lerpf(mouth.scale.y, 1.0, t)
