extends UltraTour
## Review tour: gore on the dummies - a shotgun blast into the belly (guts hanging), a blast
## taking an arm off, a hand and a foot cut off, a heart shot - close up on the body (stumps,
## wounds) and on the parts that came off.
##   godot --path . --resolution 1280x720 -- --tour=gore_review --out=C:/Dev/verify/ultra/review/gore_review

var _cam: Camera3D
var _d: Array[UltraCharacter] = []
var _focus := Vector3.ZERO
var _from := Vector3(1.8, 0.6, 1.2)


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/gore_review")
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 1.0, "slot": 0},
		{"call": _belly, "t": 0.2, "slot": 0, "shot": "belly_0"},
		{"call": _belly_fx, "t": 0.1, "slot": 0},
		{"call": _look.bind(3, Vector3(0, 0.8, 0), Vector3(0.7, 0.2, -1.1)), "t": 0.5, "slot": 0, "shot": "belly_close"},
		{"t": 1.5, "slot": 0, "shot": "belly_close2"},
		{"call": _look.bind(3, Vector3(0, 0.8, 0), Vector3(1.2, 0.1, 0.1)), "t": 0.5, "slot": 0, "shot": "belly_side"},
		{"t": 1.5, "slot": 0, "shot": "belly_1"},
		{"call": _look.bind(0, Vector3(0, 0.9, 0), Vector3(1.2, 0.3, 1.4)), "t": 1.5, "slot": 0, "shot": "belly_2"},
		{"call": _arm, "t": 0.3, "slot": 0, "shot": "arm_0"},
		{"call": _look_bone.bind(1, "RightUpperArm", Vector3(0.45, 0.15, 0.35)), "t": 1.5, "slot": 0, "shot": "arm_stump"},
		{"call": _look_gib, "t": 0.5, "slot": 0, "shot": "arm_gib"},
		{"call": _hand_foot, "t": 0.3, "slot": 0},
		{"call": _look_bone.bind(2, "LeftLowerArm", Vector3(-0.35, 0.1, -0.35)), "t": 1.2, "slot": 0, "shot": "hand_stump"},
		{"call": _look_bone.bind(2, "RightLowerLeg", Vector3(0.35, 0.25, -0.4)), "t": 1.0, "slot": 0, "shot": "foot_stump"},

		{"call": _look_gib, "t": 0.5, "slot": 0, "shot": "hand_gib"},
		{"call": _heart, "t": 0.6, "slot": 0},
		{"call": _look.bind(3, Vector3(0, 1.3, 0), Vector3(1.4, 0.2, 1.4)), "t": 1.2, "slot": 0, "shot": "heart"},
		{"t": 0.3, "slot": 0},
	]


func _setup() -> void:
	var c: UltraCharacter = main.player
	for k in 4:
		var at := c.state.pos + Vector3(-6.0 + k * 4.0, 0, -6.0)
		var p := UltraNet.spawn_bot("Dummy", Transform3D(Basis(Vector3.UP, 0.0), at))
		(p.character.input_source as BotInputSource).set_steps([{"ticks": 100000}])
		_d.append(p.character)
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_look(0, Vector3(0, 1.0, 0), Vector3(1.8, 0.4, -1.6))


func _look(k: int, off: Vector3, from: Vector3) -> void:
	_bone_k = -1
	_focus = _d[k].visual_root.global_position + off if k >= 0 else off
	_from = from


var _bone_k := -1
var _bone := ""


func _look_bone(k: int, bone: String, from: Vector3) -> void:
	_bone_k = k
	_bone = bone
	_from = from


func _look_gib() -> void:
	_bone_k = -1
	var best: Node3D = null
	for g in main.get_tree().get_nodes_in_group(&"ultra_gib"):
		var n := g as Node3D
		if n and (best == null or n.get_instance_id() > best.get_instance_id()):
			best = n
	if best:
		_focus = best.global_position
		_from = Vector3(0.35, 0.3, 0.35)


func _blast(t: UltraCharacter, aim: Vector3, from_dist: float) -> void:
	var c: UltraCharacter = main.player
	var from := aim + Vector3(0, 0, -from_dist)          # (in front: the dummies face -Z)
	var dirs := []
	for i in 9:
		dirs.append(((aim - from).normalized() + Vector3(randf_range(-0.015, 0.015), randf_range(-0.015, 0.015), 0)).normalized())
	UltraCombat.hitscan_pellets(c, from, dirs, ItemDB.get_def(&"shotgun"))


func _belly() -> void:
	var t := _d[0]
	_blast(t, t.state.pos + Vector3.UP * 1.0, 1.2)


## (The gore alone on a dummy left standing: a blast's wound and guts, no damage.)
func _belly_fx() -> void:
	var t := _d[3]
	var at := t.state.pos + Vector3.UP * 1.0 + Vector3(0, 0, -0.14)
	t.body_fx.torso_blast(at, Vector3(0, 0, 1), 60.0)


func _arm() -> void:
	var t := _d[1]
	var sk := t.skeleton
	var p := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("RightLowerArm")).origin
	_blast(t, p, 1.0)


func _hand_foot() -> void:
	var t := _d[2]
	for r in [UltraLimbs.Region.HAND_L, UltraLimbs.Region.FOOT_R]:
		var d := UltraCombat.DamageInfo.new()
		d.amount = 60.0
		d.region = r
		d.kind = &"blade"
		d.dir = Vector3(0, 0, 1)
		d.point = t.state.pos + Vector3.UP
		d.attacker_id = main.player.net_id
		t.apply_damage(d)


func _heart() -> void:
	var t := _d[3]
	var h := UltraHitboxes.heart(t, t.state.pos)
	UltraCombat.hitscan(main.player, h + Vector3(0, 0, -3), Vector3(0, 0, 1), ItemDB.get_def(&"rifle"))


func _process(delta: float) -> void:
	super(delta)
	if _cam:
		_cam.current = true
		if _bone_k >= 0:
			var sk := _d[_bone_k].skeleton
			var b := sk.find_bone(_bone)
			# The end of the bone (where its child was cut off).
			var gp := sk.global_transform * sk.get_bone_global_pose(b)
			var child := sk.get_bone_children(b)
			_focus = sk.global_transform * sk.get_bone_global_pose(child[0]).origin if child.size() > 0 else gp.origin
		_cam.global_position = _focus + _from
		_cam.look_at(_focus)
