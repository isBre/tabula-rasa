extends Node3D
## An agent's body: a low-poly human in the agent's colors. It walks on the ground
## (or flies to high spots), goes where it builds and points at its work, comes to
## the player (or a teammate) to talk and moves its mouth while the bubble is shown.
## It passes through obstacles like a ghost so it never gets stuck.

const AvatarScript := preload("res://scripts/avatar.gd")

const WALK_SPEED := 3.6
const RUN_SPEED := 7.5
const FLY_SPEED := 10.0
const LEASH := 16.0          # comes back near the player when they get farther than this
const CATCH_UP_TO := 5.0
const WORK_DISTANCE := 2.6   # how far from the work spot it stands
const TALK_DISTANCE := 2.4   # how close it comes to talk
const MAX_WAIT := 2.5        # seconds a tool waits for the agent to reach the spot

const SKINS := ["#e0ac85", "#c68a62", "#f1c7a3", "#8d5a3b", "#d9a07a", "#b97a56", "#f0cfb0", "#a8704c"]
const HAIRS := ["#2b1d14", "#c9a25b", "#7a3b1d", "#111111", "#d8d0c8", "#5b3a29", "#9b4d2a", "#3a2a20"]
const PANTS := ["#3a3f4b", "#4b3b2b", "#2f4a3a", "#2d2d38", "#5a4a6a", "#394a5c", "#4a4a4a", "#3d3226"]

## Slots around the player (angle from where they look, distance factor, unused):
## in front and to the sides, so the player can see the agents.
const SLOTS := [[-35.0, 1.0], [35.0, 1.0], [-70.0, 0.9], [70.0, 0.9], [-105.0, 0.9], [105.0, 0.9], [-140.0, 1.0], [140.0, 1.0]]

var agent_name := "Agente"
var color := Color(0.3, 0.9, 1.0)
var team            # team.gd, for the follow setting
var follow_slot := 0

var avatar
var can_fly := true      # NPCs live on the ground: they walk everywhere
var _label_lift := 0.0
var look := {}           # appearance chosen in the menu: skin, hair, hair_style, pants, hat, height
var velocity := Vector3.ZERO
var _target := Vector3.ZERO
var _follow_node: Node3D = null   # walking toward a moving target (player / teammate)
var _follow_dist := 0.0
var _flying := false
var _manual := false        # true while busy somewhere (work, photos, talking)
var _release_at := 0.0
var _catching_up := false
var _work_point := Vector3.ZERO
var _work_until := 0.0
var _talk_until := 0.0
var _look_node: Node3D = null
var _bubble: Label3D
var _status: Label3D
var _status_text := ""
var _bubble_time := 0.0


func _ready() -> void:
	_target = position
	_build_avatar()

	_status = _make_label(20, color.lightened(0.4))
	add_child(_status)
	_bubble = _make_label(30, Color.WHITE)
	add_child(_bubble)
	_place_labels()
	set_status("")


## The appearance this agent has by default (from its slot), merged with `look`.
func full_look() -> Dictionary:
	var i := follow_slot
	var d := {
		"skin": SKINS[i % SKINS.size()], "hair": HAIRS[(i * 3 + 1) % HAIRS.size()], "hair_style": "corti",
		"pants": PANTS[(i * 5 + 2) % PANTS.size()], "hat": "nessuno", "height": 0.94 + 0.03 * (i % 4),
	}
	d.merge(look, true)
	return d


func _build_avatar() -> void:
	if avatar != null:
		avatar.queue_free()
	var l := full_look()
	avatar = AvatarScript.new()
	avatar.shirt = "#" + color.to_html(false)
	avatar.skin = str(l.skin)
	avatar.hair = str(l.hair)
	avatar.hair_style = str(l.hair_style)
	avatar.pants = str(l.pants)
	avatar.hat = str(l.hat)
	avatar.label_text = agent_name
	avatar.label_color = color.lightened(0.25)
	avatar.hidden_from_owner = false
	var h := clampf(float(l.height), 0.7, 1.3)
	var hat_extra: float = {"cuoco": 0.28, "cilindro": 0.3, "corona": 0.12, "berretto": 0.06, "paglia": 0.1}.get(str(l.hat), 0.0)
	avatar.label_height = 2.12 + hat_extra / h
	avatar.scale = Vector3.ONE * h
	add_child(avatar)
	_label_lift = (2.12 + hat_extra) * h - 2.12 * 0.97
	if _status:
		_place_labels()


## New appearance, applied right away.
## Status and speech bubble above the head (and the hat).
func _place_labels() -> void:
	_status.position.y = 2.3 + _label_lift
	_bubble.position.y = 2.55 + _label_lift


func set_look(new_look: Dictionary) -> void:
	look = new_look.duplicate()
	_build_avatar()


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


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# ---------------------------------------------------------------- public API

func say(text: String) -> void:
	_bubble.text = text
	_bubble_time = 7.0 + text.length() * 0.06
	_talk_until = _now() + clampf(1.2 + text.length() * 0.045, 1.5, 9.0)


func set_status(text: String) -> void:
	_status_text = text
	_status.text = text


func status_desc() -> String:
	return _status_text if _status_text != "" else "in ascolto"


## Go to a point (feet position, or a spot in the air: then it flies).
func move_to(p: Vector3) -> void:
	_follow_node = null
	_target = p
	_flying = can_fly and p.y - _ground_y(p, p.y) > 1.5
	if not can_fly:
		_target.y = _ground_y(p, p.y + 1.0)
	_manual = true
	_release_at = INF


## Walks next to `point` (where it is about to build) and points at it.
## Returns once it is there, or after MAX_WAIT seconds.
func go_work(point: Vector3) -> void:
	var from := Vector3(position.x, 0, position.z)
	var dir := (from - Vector3(point.x, 0, point.z))
	if dir.length() < 0.1:
		dir = Vector3(0, 0, 1)
	var spot := point + dir.normalized() * WORK_DISTANCE
	var ground := _ground_y(spot, point.y + 1.0)
	spot.y = ground if point.y - ground < 2.5 or not can_fly else point.y   # high work: hover at its height
	move_to(spot)
	_work_point = point
	await _arrive(MAX_WAIT)
	_work_until = _now() + 1.6


## Walks up to a node (the player or a teammate) to talk; returns when close enough.
func approach(node: Node3D, distance := TALK_DISTANCE) -> void:
	if node == null or not is_instance_valid(node):
		return
	_follow_node = node
	_follow_dist = distance
	_flying = false
	_manual = true
	_release_at = INF
	_look_node = node
	await _arrive(MAX_WAIT + 0.5)


## Go back to free behavior after `seconds` (called when the agent's turn ends).
func release_after(seconds: float) -> void:
	if _manual:
		_release_at = _now() + seconds


func _arrive(max_wait: float) -> void:
	var t0 := _now()
	while _now() - t0 < max_wait:
		if _distance_to_goal() < 0.4:
			return
		await get_tree().process_frame


func _goal() -> Vector3:
	if _follow_node != null and is_instance_valid(_follow_node):
		var p := _follow_node.global_position
		var away := Vector3(position.x - p.x, 0, position.z - p.z)
		if away.length() < 0.1:
			away = Vector3(1, 0, 0)
		var g := p + away.normalized() * _follow_dist
		g.y = _ground_y(g, p.y + 0.5)
		return g
	return _target


func _distance_to_goal() -> float:
	var g := _goal()
	return Vector2(position.x - g.x, position.z - g.z).length() + absf(position.y - g.y) * 0.5


# ---------------------------------------------------------------- per frame

func _ground_y(at: Vector3, from_y: float) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, from_y + 1.0, at.z), Vector3(at.x, -50.0, at.z))
	if World.player:
		q.exclude = [World.player.get_rid()]
	var hit := space.intersect_ray(q)
	return hit.position.y if not hit.is_empty() else 0.0


func _follow_point() -> Vector3:
	var pl = World.player
	var slot: Array = SLOTS[follow_slot % SLOTS.size()]
	var fwd: Vector3 = pl.get_forward()
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var dir := fwd.normalized().rotated(Vector3.UP, deg_to_rad(slot[0]))
	var p: Vector3 = pl.global_position + dir * CATCH_UP_TO * float(slot[1])
	p.y = _ground_y(p, pl.global_position.y + 0.5)
	return p


func _process(delta: float) -> void:
	var now := _now()
	if _manual and now >= _release_at:
		_manual = false
		_follow_node = null
		_look_node = null
	# free behavior: stay put, catch up with the player if they get too far
	if not _manual and team != null and team.follow and World.player != null:
		var pp: Vector3 = World.player.global_position
		var flat_dist := Vector2(position.x - pp.x, position.z - pp.z).length()
		if not _catching_up and flat_dist > LEASH:
			_catching_up = true
		if _catching_up:
			_target = _follow_point()
			_flying = false
			if Vector2(position.x - _target.x, position.z - _target.z).length() < 0.8:
				_catching_up = false
	elif _manual:
		_catching_up = false

	var goal := _goal()
	var before := position
	var flat := Vector3(goal.x - position.x, 0, goal.z - position.z)
	if _flying:
		var to := goal - position
		if to.length() > 0.05:
			position += to.limit_length(FLY_SPEED * delta)
	elif flat.length() > 0.15:
		var speed := RUN_SPEED if (flat.length() > 3.0 or _catching_up) else WALK_SPEED
		position += flat.limit_length(speed * delta)
		var gy := _ground_y(position, position.y + 0.6)
		position.y = lerpf(position.y, gy, clampf(delta * 12.0, 0.0, 1.0))
	else:
		var gy2 := _ground_y(position, position.y + 0.6)
		if position.y - gy2 > 0.05 and not _flying:
			position.y = lerpf(position.y, gy2, clampf(delta * 8.0, 0.0, 1.0))
	velocity = (position - before) / maxf(delta, 0.0001)
	var moving := Vector2(velocity.x, velocity.z).length() > 0.3

	# where to face: where it walks, else what it works on / who it talks to / the player
	var face_at := Vector3.INF
	if moving and not _flying:
		face_at = position + Vector3(velocity.x, 0, velocity.z)
	elif now < _work_until:
		face_at = _work_point
	elif _look_node != null and is_instance_valid(_look_node):
		face_at = _look_node.global_position
	elif World.player and Vector2(position.x - World.player.global_position.x, position.z - World.player.global_position.z).length() < 12.0:
		face_at = World.player.global_position
	if face_at != Vector3.INF:
		var d := Vector3(face_at.x - position.x, 0, face_at.z - position.z)
		if d.length() > 0.2:
			var yaw := atan2(-d.x, -d.z)
			rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 8.0, 0.0, 1.0))

	var pitch := 0.0
	if now < _work_until:
		var wd := _work_point - (position + Vector3.UP * 1.5)
		pitch = clampf(atan2(wd.y, Vector2(wd.x, wd.z).length()), -0.9, 0.9)
	avatar.animate(delta, {
		"speed": Vector2(velocity.x, velocity.z).length(),
		"vy": velocity.y,
		"on_floor": not _flying or not moving,
		"flying": _flying and (moving or position.y - _ground_y(position, position.y) > 0.5),
		"building": now < _work_until,
		"pitch": pitch,
		"talking": now < _talk_until,
		"walk_speed": WALK_SPEED,
	})

	if _bubble_time > 0.0:
		_bubble_time -= delta
		if _bubble_time <= 0.0:
			_bubble.text = ""
