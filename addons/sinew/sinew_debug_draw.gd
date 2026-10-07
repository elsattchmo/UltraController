class_name SinewDebugDraw
extends Node3D
## Sinew's body made visible: every physical part drawn as its collision shape (capsules, box
## feet) coloured by how hard its muscle is working - blue relaxed, green, yellow, red flat out
## (torque over strength, red from 60 %); grey = driven by the animation (kinematic), dark = cut off - the
## bones as lines between the joints, and while it balances the centre of mass (yellow), the
## capture point (green inside the support, red outside) and the support polygon (cyan).
## A label over the head says what the body is doing.
##
## `sinew_debug` (K) cycles: off -> overlay (through the body) -> x-ray (body mesh hidden) -> off.
## `--sinew-debug` starts in overlay. One switch for every Sinew character.

enum View { OFF, OVERLAY, XRAY }

## Effort drawn full red (a muscle rarely needs more than this share of its strength).
const FULL := 0.6

static var view := -1                    ## -1: not read from the command line yet
static var _toggled_frame := -1

var ragdoll: SinewRagdoll
var _shapes: Array[MeshInstance3D] = []
var _locals: Array[Transform3D] = []     ## each part's shape in the part's frame
var _mats: Array[StandardMaterial3D] = []
var _effort := PackedFloat32Array()
var _lines: MeshInstance3D
var _imm: ImmediateMesh
var _label: Label3D
var _hidden: Array[GeometryInstance3D] = []
var _shown_view := View.OFF
var _ramp: Gradient


func _ready() -> void:
	top_level = true
	if view < 0:
		view = View.OVERLAY if "--sinew-debug" in OS.get_cmdline_user_args() else View.OFF
	_ramp = Gradient.new()
	_ramp.offsets = PackedFloat32Array([0.0, 0.3, 0.6, 1.0])
	_ramp.colors = PackedColorArray([Color(0.2, 0.45, 1.0), Color(0.2, 0.9, 0.35), Color(1.0, 0.85, 0.1), Color(1.0, 0.15, 0.1)])


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"sinew_debug") and event.is_action_pressed(&"sinew_debug") and Engine.get_process_frames() != _toggled_frame:
		_toggled_frame = Engine.get_process_frames()
		view = (maxi(view, 0) + 1) % 3


func _process(_delta: float) -> void:
	var v := maxi(view, 0)
	if v != _shown_view:
		_apply_view(v)
	if v == View.OFF or ragdoll == null or ragdoll._id == 0 or ragdoll.pose_now.is_empty():
		return
	if _shapes.is_empty():
		_build()
	var phys = ragdoll.world.physics
	var f := Engine.get_physics_interpolation_fraction()
	var pose: Array[Transform3D] = []
	for i in ragdoll.pose_now.size():
		var a: Transform3D = ragdoll.pose_prev[i] if i < ragdoll.pose_prev.size() else ragdoll.pose_now[i]
		pose.append(a.interpolate_with(ragdoll.pose_now[i], f))
	# Muscles: the shapes coloured by effort (smoothed: it's a per-tick reading).
	var effort: PackedFloat32Array = phys.call("character_muscle_effort", ragdoll._id)
	if _effort.size() != effort.size():
		_effort = effort.duplicate()
	for i in mini(_shapes.size(), pose.size()):
		var e := effort[i] if i < effort.size() else -1.0
		_effort[i] = e if e < 0.0 or _effort[i] < 0.0 else lerpf(_effort[i], e, 0.35)
		_shapes[i].global_transform = pose[i] * _locals[i]
		var col: Color
		if not bool(phys.call("character_attached", ragdoll._id, i)):
			col = Color(0.35, 0.08, 0.06)
		elif _effort[i] < 0.0:
			col = Color(0.62, 0.62, 0.68)
		else:
			col = _ramp.sample(clampf(_effort[i] / FULL, 0.0, 1.0))
		col.a = 0.55 if v == View.OVERLAY else 0.9
		_mats[i].albedo_color = col
	# Bones, balance.
	_imm.clear_surfaces()
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in pose.size():
		var p: int = ragdoll.parts[i].parent
		if p >= 0 and p < pose.size():
			_line(pose[p].origin, pose[i].origin, Color(1, 1, 1))
	var st := ragdoll.balance_state()
	var com: Vector3 = st.com if not st.is_empty() else phys.call("character_center_of_mass", ragdoll._id)
	var ground: float = ragdoll.character.state.pos.y + 0.01
	_cross(com, 0.08, Color(1, 0.9, 0.1))
	_line(com, Vector3(com.x, ground, com.z), Color(1, 0.9, 0.1, 0.6))
	if not st.is_empty():
		var hull: PackedVector3Array = st.support
		for k in hull.size():
			var a := hull[k]
			var b := hull[(k + 1) % hull.size()]
			_line(Vector3(a.x, ground, a.z), Vector3(b.x, ground, b.z), Color(0.2, 0.95, 1.0))
		var cp: Vector3 = st.capture_point
		_cross(Vector3(cp.x, ground, cp.z), 0.07, Color(0.2, 1, 0.3) if float(st.capture_error) < 0.0 else Color(1, 0.2, 0.2))
	_imm.surface_end()
	# What it's doing.
	var mode := "animated"
	if ragdoll.active:
		mode = "getting up" if ragdoll._getting_up else ("dead" if ragdoll.character.state.state == MotorState.Id.DEAD else "down")
	elif ragdoll.staggering():
		mode = "stagger: %d steps%s" % [int(st.get("steps", 0)), " (stepping)" if bool(st.get("stepping", false)) else ""]
	elif ragdoll._powered_on:
		mode = "powered"
	var hardest := -1
	for i in _effort.size():
		if _effort[i] >= 0.0 and (hardest < 0 or _effort[i] > _effort[hardest]):
			hardest = i
	_label.text = mode + ("\nhardest: %s %d%%" % [ragdoll.parts[hardest].name, roundi(_effort[hardest] * 100.0)] if hardest >= 0 else "")
	_label.global_position = pose[0].origin + Vector3(0, 1.15, 0)


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(a)
	_imm.surface_set_color(c)
	_imm.surface_add_vertex(b)


func _cross(p: Vector3, s: float, c: Color) -> void:
	_line(p - Vector3(s, 0, 0), p + Vector3(s, 0, 0), c)
	_line(p - Vector3(0, s, 0), p + Vector3(0, s, 0), c)
	_line(p - Vector3(0, 0, s), p + Vector3(0, 0, s), c)


func _build() -> void:
	for i in ragdoll.parts.size():
		var d: Dictionary = ragdoll.parts[i]
		var mi := MeshInstance3D.new()
		var local := Transform3D()
		if bool(d.get("box", false)):
			var bm := BoxMesh.new()
			bm.size = (d.box_half as Vector3) * 2.0
			mi.mesh = bm
			local = d.box_xform
		else:
			var a: Vector3 = d.a
			var b: Vector3 = d.b
			var r: float = d.radius
			var cm := CapsuleMesh.new()
			cm.radius = r
			cm.height = a.distance_to(b) + 2.0 * r
			cm.radial_segments = 12
			cm.rings = 4
			mi.mesh = cm
			var axis := (b - a).normalized() if a.distance_to(b) > 1e-5 else Vector3.UP
			var side := Vector3.FORWARD if absf(axis.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
			var x := axis.cross(side).normalized()
			local = Transform3D(Basis(x, axis, x.cross(axis)), (a + b) * 0.5)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.render_priority = 10
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_shapes.append(mi)
		_locals.append(local)
		_mats.append(m)
	_imm = ImmediateMesh.new()
	_lines = MeshInstance3D.new()
	_lines.mesh = _imm
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.no_depth_test = true
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.render_priority = 12
	_lines.material_override = lm
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_lines)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 28
	_label.pixel_size = 0.0025
	_label.outline_size = 6
	add_child(_label)
	_apply_view(_shown_view)


## Show / hide the drawing and (x-ray) the character's own meshes.
func _apply_view(v: int) -> void:
	_shown_view = v
	visible = v != View.OFF
	for m in _mats:
		m.no_depth_test = v == View.OVERLAY
	for g in _hidden:
		if is_instance_valid(g):
			g.visible = true
	_hidden.clear()
	if v == View.XRAY and ragdoll and ragdoll.character and ragdoll.character.skeleton:
		for n in ragdoll.character.skeleton.find_children("*", "MeshInstance3D", true, false):
			var g := n as GeometryInstance3D
			if g.visible:
				g.visible = false
				_hidden.append(g)


func _exit_tree() -> void:
	for g in _hidden:
		if is_instance_valid(g):
			g.visible = true
	_hidden.clear()
