class_name ZombieDebug
extends Node3D
## Debug overlay for the zombie AI: a label over each zombie (mode, awareness), its path and where it is
## headed, a line along its facing, and a ring for every noise as it goes out. Toggled by the
## `zombie_debug` action (F7) or `--zdebug`.

var director: ZombieDirector
var enabled := false

var _labels := {}                      ## ZombieBrain -> Label3D
var _mesh := ImmediateMesh.new()
var _mi := MeshInstance3D.new()
var _noises: Array = []                ## [pos, loudness, age]
var _pts := PackedVector3Array()
var _cols := PackedColorArray()

const COLORS := {
	"dormant": Color(0.5, 0.5, 0.6), "idle": Color(0.7, 0.7, 0.7), "wander": Color(0.6, 0.8, 0.6), "investigate": Color(1.0, 0.85, 0.3),
	"chase": Color(1.0, 0.25, 0.2), "attack": Color(1.0, 0.0, 0.5), "stagger": Color(0.8, 0.5, 0.2), "open_door": Color(0.4, 0.8, 1.0),
	"bash_door": Color(0.9, 0.4, 1.0), "downed": Color(0.5, 0.3, 0.3), "dead": Color(0.3, 0.3, 0.3),
}


func _ready() -> void:
	_mi.mesh = _mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	m.render_priority = 50
	_mi.material_override = m
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = 4096.0
	add_child(_mi)
	UltraNoise.listen(_on_noise)
	enabled = enabled or UltraArgs.has("zdebug")


func _exit_tree() -> void:
	UltraNoise.unlisten(_on_noise)


func _on_noise(pos: Vector3, loud: float, _kind: StringName, _src: int) -> void:
	_noises.append([pos, loud, 0.0])


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(UltraInput.action(&"zombie_debug")):
		enabled = not enabled


func _process(delta: float) -> void:
	_mesh.clear_surfaces()
	_pts.clear()
	_cols.clear()
	for b: ZombieBrain in _labels.keys():
		var lab: Label3D = _labels[b]
		lab.visible = enabled
	if not enabled or director == null:
		return
	for b in director.brains:
		if not is_instance_valid(b.c):
			continue
		var lab: Label3D = _labels.get(b)
		if lab == null:
			lab = Label3D.new()
			lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			lab.no_depth_test = true
			lab.fixed_size = true
			lab.pixel_size = 0.0009
			lab.font_size = 26
			lab.outline_size = 8
			lab.render_priority = 60
			add_child(lab)
			_labels[b] = lab
		var col: Color = COLORS.get(b.mode_name(), Color.WHITE)
		lab.visible = true
		lab.modulate = col
		lab.global_position = b.c.state.pos + Vector3.UP * (b.c.state.height + 0.55)
		lab.text = "%s %.2f%s" % [b.mode_name(), b.awareness, " (%s)" % ZombieFactory.archetype_of(UltraNet.players[b.c.net_id]).id if UltraNet.players.has(b.c.net_id) else ""]
		var feet := b.c.state.pos + Vector3.UP * 0.15
		var fwd := Vector3(-sin(b.c.state.body_yaw), 0.0, -cos(b.c.state.body_yaw))
		_line(feet + Vector3.UP * 1.0, feet + Vector3.UP * 1.0 + fwd * 1.2, col)
		# its path from where it is
		if not b.path.is_empty():
			var prev := feet
			for i in range(b.path_i, b.path.size()):
				var p := b.path[i] + Vector3.UP * 0.12
				_line(prev, p, col)
				prev = p
		if b.goal != Vector3.INF:
			_line(b.goal, b.goal + Vector3.UP * 1.5, col)
		if b.target != null and is_instance_valid(b.target) and b.mode in [ZombieBrain.Mode.CHASE, ZombieBrain.Mode.ATTACK]:
			_line(feet + Vector3.UP * 1.3, b.target.state.pos + Vector3.UP * 1.2, Color(1, 0.2, 0.2, 0.6))
	# noise rings
	for n in _noises:
		n[2] += delta
		var r: float = float(n[1]) * clampf((n[2] as float) / 0.8, 0.0, 1.0)
		var a := 1.0 - clampf((n[2] as float) / 1.4, 0.0, 1.0)
		var col2 := Color(1.0, 0.9, 0.3, a)
		for k in 32:
			var a0 := TAU * k / 32.0
			var a1 := TAU * (k + 1) / 32.0
			var c0: Vector3 = (n[0] as Vector3) + Vector3(cos(a0), 0, sin(a0)) * r
			var c1: Vector3 = (n[0] as Vector3) + Vector3(cos(a1), 0, sin(a1)) * r
			_line(c0, c1, col2)
	_noises = _noises.filter(func(n: Array) -> bool: return (n[2] as float) < 1.4)
	if _pts.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _pts.size():
		_mesh.surface_set_color(_cols[i])
		_mesh.surface_add_vertex(_pts[i])
	_mesh.surface_end()


func _line(a: Vector3, b: Vector3, col: Color) -> void:
	_pts.append(a)
	_pts.append(b)
	_cols.append(col)
	_cols.append(col)
