extends Node
## Sky, sun, time of day and ground style. Controlled by the agents (set_environment)
## and by the player (/time, /cycle, /ground, /fog). Saved with the world.

const Legacy := preload("res://scripts/legacy.gd")

const GROUND_SHADER := """
shader_type spatial;
uniform vec3 base_color = vec3(0.035, 0.045, 0.07);
uniform vec3 line_color = vec3(0.2, 0.65, 1.0);
uniform float glow = 1.0;
uniform float line_dark = 0.0;
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid(vec2 p, float spacing, float width) {
	vec2 c = p / spacing;
	vec2 g = abs(fract(c - 0.5) - 0.5) / fwidth(c);
	return 1.0 - min(min(g.x, g.y) / width, 1.0);
}

void fragment() {
	float g1 = grid(wpos.xz, 1.0, 1.0);
	float g10 = grid(wpos.xz, 10.0, 1.6);
	float fade = 1.0 - smoothstep(30.0, 160.0, length(wpos.xz));
	float lines = (g1 * 0.4 + g10) * fade;
	ALBEDO = base_color * (1.0 - line_dark * lines);
	ROUGHNESS = 0.95;
	EMISSION = line_color * (g1 * 0.18 + g10 * 0.7) * fade * glow;
}
"""

## name -> [base color, line darkening, neon glow]
const GROUNDS := {
	"grid": ["#090b12", 0.0, 1.0],
	"grass": ["#6aa84f", 0.10, 0.0],
	"sand": ["#e0c58f", 0.08, 0.0],
	"snow": ["#eef2f5", 0.05, 0.0],
	"stone": ["#8c8f94", 0.10, 0.0],
	"dirt": ["#8b6b47", 0.10, 0.0],
}

## hour, sky top, horizon, sun energy, ambient energy
const KEYS := [
	[0.0, "#070b18", "#141c33", 0.0, 0.2],
	[5.0, "#0d1428", "#2a2f4f", 0.0, 0.22],
	[6.5, "#4a6fa5", "#f2a65a", 0.6, 0.3],
	[9.0, "#3f8fd8", "#a9d6f0", 1.0, 0.45],
	[17.0, "#3f8fd8", "#a9d6f0", 1.0, 0.45],
	[19.0, "#3b4d7a", "#f08a5d", 0.6, 0.3],
	[20.5, "#141b36", "#36325a", 0.0, 0.24],
	[24.0, "#070b18", "#141c33", 0.0, 0.2],
]

var time_of_day := 10.5
var cycle_minutes := 0.0
var fog := 0.15
var ground := "grass"

var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var ground_mat: ShaderMaterial


func build(parent: Node3D) -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_sky_affect = 0.5
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_hdr_threshold = 1.2
	env.fog_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	parent.add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_color = Color("#9fb4ff")
	moon.rotation_degrees = Vector3(-50, -30, 0)
	parent.add_child(moon)

	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(400, 1, 400)
	cs.shape = bs
	cs.position.y = -0.5
	ground_body.add_child(cs)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	mi.mesh = pm
	var shader := Shader.new()
	shader.code = GROUND_SHADER
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = shader
	mi.material_override = ground_mat
	ground_body.add_child(mi)
	parent.add_child(ground_body)
	_apply_ground()
	_apply_time()


func _process(delta: float) -> void:
	if cycle_minutes > 0.0 and env:
		time_of_day = fmod(time_of_day + delta * 24.0 / (cycle_minutes * 60.0), 24.0)
		_apply_time()


func set_values(args: Dictionary) -> Dictionary:
	var changed := PackedStringArray()
	if args.has("time_of_day"):
		time_of_day = fposmod(float(args["time_of_day"]), 24.0)
		changed.append("time %s" % clock())
	if args.has("cycle_minutes"):
		cycle_minutes = clampf(float(args["cycle_minutes"]), 0.0, 240.0)
		changed.append("cycle " + ("stopped" if cycle_minutes == 0.0 else "%d min" % cycle_minutes))
	if args.has("fog"):
		fog = clampf(float(args["fog"]), 0.0, 1.0)
		changed.append("fog %.2f" % fog)
	if args.has("ground"):
		var g := Legacy.ground(str(args["ground"]).to_lower())
		if not GROUNDS.has(g):
			return {"ok": false, "text": "Unknown ground '%s'. Values: %s" % [g, ", ".join(PackedStringArray(GROUNDS.keys()))]}
		ground = g
		changed.append("ground " + g)
		_apply_ground()
	_apply_time()
	return {"ok": true, "text": "Environment updated: " + (", ".join(changed) if not changed.is_empty() else "nothing to change")}


func clock() -> String:
	var h := int(time_of_day)
	return "%02d:%02d" % [h, int((time_of_day - h) * 60.0)]


func describe() -> String:
	return "time %s (%s), ground %s, fog %.2f" % [clock(), "cycle stopped" if cycle_minutes == 0.0 else "full day in %d min" % cycle_minutes, ground, fog]


func serialize() -> Dictionary:
	return {"time_of_day": time_of_day, "cycle_minutes": cycle_minutes, "fog": fog, "ground": ground}


func apply(data: Dictionary) -> void:
	set_values(data)


func _apply_ground() -> void:
	var g: Array = GROUNDS[ground]
	var c := Color.from_string(str(g[0]), Color.BLACK)
	ground_mat.set_shader_parameter("base_color", Vector3(c.r, c.g, c.b))
	ground_mat.set_shader_parameter("line_dark", g[1])
	ground_mat.set_shader_parameter("glow", g[2])


func _apply_time() -> void:
	var a: Array = KEYS[0]
	var b: Array = KEYS[-1]
	for i in KEYS.size() - 1:
		if time_of_day >= KEYS[i][0] and time_of_day <= KEYS[i + 1][0]:
			a = KEYS[i]
			b = KEYS[i + 1]
			break
	var t: float = 0.0 if b[0] == a[0] else (time_of_day - a[0]) / (b[0] - a[0])
	var top := Color.from_string(str(a[1]), Color.BLACK).lerp(Color.from_string(str(b[1]), Color.BLACK), t)
	var horizon := Color.from_string(str(a[2]), Color.BLACK).lerp(Color.from_string(str(b[2]), Color.BLACK), t)
	var sun_e: float = lerpf(a[3], b[3], t)
	var amb: float = lerpf(a[4], b[4], t)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = horizon
	sky_mat.ground_horizon_color = horizon
	sky_mat.ground_bottom_color = top.darkened(0.5)
	env.ambient_light_color = horizon.lerp(top, 0.3).lerp(Color.WHITE, 0.25)
	env.ambient_light_energy = amb
	env.fog_light_color = horizon.darkened(0.1)
	env.fog_density = lerpf(0.0003, 0.02, fog * fog)
	# sun arc: rises at 6 in the east (+X), sets at 18 in the west
	var day := clampf((time_of_day - 6.0) / 12.0, 0.0, 1.0)
	var elevation := sin(day * PI) * 70.0 + 4.0
	sun.rotation_degrees = Vector3(-elevation, 90.0 - day * 180.0 + 180.0, 0)
	sun.light_energy = sun_e
	sun.light_color = Color("#ffd9a8").lerp(Color("#fff6e8"), clampf(elevation / 40.0, 0.0, 1.0))
	sun.visible = sun_e > 0.01
	moon.light_energy = clampf(0.25 - sun_e, 0.0, 0.25)
	moon.visible = moon.light_energy > 0.01
