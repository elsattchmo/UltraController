extends "res://demo/tours/tour_base.gd"
## Marksman's gun pass filmed: rifle, shotgun and pistol, standing and crouched, aiming level, down and up, from the side and
## from a 3/4 front view. A red line runs on along the barrel from the muzzle, a green one along the aim ray (shot
## origin -> aim point): on target they meet at the aim point.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_aim_review --controller=marksman --out=<dir>

const PITCHES := {"down": -0.35, "level": 0.0, "up": 0.3}
const VIEWS := {"side": Vector3(3.2, 1.1, 0.0), "front": Vector3(2.2, 1.3, -2.6)}

var _c: UltraCharacter
var _cam: Camera3D
var _lines: MeshInstance3D
var _imm: ImmediateMesh
var _slots := {}
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_aim_review")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": 0, "view_tp": true, "slot": 0},
			{"call": _setup, "t": 1.0}]
	for item in ["rifle", "shotgun", "pistol"]:
		for posture in ["stand", "crouch"]:
			var buttons: int = InputFrame.B_CROUCH if posture == "crouch" else 0
			for p: String in PITCHES:
				steps.append({"call": _place, "t": 0.1})
				steps.append({"call": _arm.bind(item), "t": 600.0, "until": _ticks.bind(70), "buttons": buttons, "yaw": 0, "pitch": rad_to_deg(PITCHES[p])})
				for v: String in VIEWS:
					steps.append({"call": _view.bind(v), "t": 0.25, "buttons": buttons, "yaw": 0, "pitch": rad_to_deg(PITCHES[p]),
							"shot": "%s_%s_%s_%s" % [item, posture, p, v]})


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	var have := {}
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			have[it.def_id] = true
	for item: StringName in [&"rifle", &"shotgun", &"pistol"]:
		if not have.has(item):
			UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1
	_imm = ImmediateMesh.new()
	_lines = MeshInstance3D.new()
	_lines.mesh = _imm
	_lines.top_level = true
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = true
	_lines.material_override = m
	main.add_child(_lines)


func _place() -> void:
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)
	_bot.live_yaw = 0.0


func _arm(item: String) -> void:
	_slot = int(_slots.get(item, 0))
	_tick0 = Engine.get_physics_frames()
	_view("front")


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


var _view_off := Vector3(2.2, 1.3, -2.6)


func _view(v: String) -> void:
	_view_off = VIEWS[v]


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null or _c == null or _c.visual_root == null:
		return
	var root := _c.visual_root.global_position
	_cam.global_position = root + _view_off
	_cam.look_at(root + Vector3.UP * 0.9 + Vector3(0, 0, -0.6), Vector3.UP)
	_draw_lines()


func _draw_lines() -> void:
	_imm.clear_surfaces()
	var r := _c.ragdoll as MarksmanRagdoll
	var eq := _c.get_node_or_null("Equipment") as UltraEquipmentVisual
	if r == null or r.gun_pass == null or eq == null or eq.held_node == null:
		return
	var gun := eq.held_node.global_transform
	var muzzle := gun * UltraPoseSampler.marker(eq.held_node, "M_Muzzle").origin
	var ray := eq.gun_ray()
	var aim: Vector3 = r.gun_pass.aim_point
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	_imm.surface_set_color(Color(1, 0.1, 0.1))
	_imm.surface_add_vertex(muzzle)
	_imm.surface_set_color(Color(1, 0.1, 0.1))
	_imm.surface_add_vertex(muzzle - gun.basis.z.normalized() * muzzle.distance_to(aim))
	_imm.surface_set_color(Color(0.1, 1, 0.2))
	_imm.surface_add_vertex(ray.origin)
	_imm.surface_set_color(Color(0.1, 1, 0.2))
	_imm.surface_add_vertex(aim)
	_imm.surface_end()

