class_name UltraRagdoll
extends Node
## Physics ragdoll for the visible body (13 bodies, ~74 kg) built from the retargeted skeleton:
## capsules along each bone (+Y points down the bone), cone joints for spine, neck, shoulders
## and hips, hinges for elbows and knees. It's cosmetic and local: the simulated character is
## the deterministic knocked-down capsule (ragdoll_state.gd). When getting up, the ragdoll fades
## into the get-up clip from where the body actually lies.

enum J { CONE, HINGE }
## bone, end bone (or "" + length), radius, mass, joint, swing/limit (deg), twist (deg)
const BODIES := [
	["Hips", "Spine", 0.13, 11.0, J.CONE, 10.0, 10.0],
	["Spine", "Chest", 0.12, 8.0, J.CONE, 22.0, 15.0],
	["Chest", "Neck", 0.15, 13.0, J.CONE, 18.0, 12.0],
	["Head", "", 0.1, 5.0, J.CONE, 35.0, 30.0],
	["LeftUpperArm", "LeftLowerArm", 0.05, 2.5, J.CONE, 75.0, 40.0],
	["LeftLowerArm", "LeftHand", 0.045, 2.0, J.HINGE, 140.0, 0.0],
	["RightUpperArm", "RightLowerArm", 0.05, 2.5, J.CONE, 75.0, 40.0],
	["RightLowerArm", "RightHand", 0.045, 2.0, J.HINGE, 140.0, 0.0],
	["LeftUpperLeg", "LeftLowerLeg", 0.075, 9.0, J.CONE, 55.0, 20.0],
	["LeftLowerLeg", "LeftFoot", 0.055, 4.5, J.HINGE, 140.0, 0.0],
	["RightUpperLeg", "RightLowerLeg", 0.075, 9.0, J.CONE, 55.0, 20.0],
	["RightLowerLeg", "RightFoot", 0.055, 4.5, J.HINGE, 140.0, 0.0],
	["LeftFoot", "LeftToes", 0.045, 1.0, J.CONE, 25.0, 10.0],
]

var character: UltraCharacter
var sim: PhysicalBoneSimulator3D
var bones: Array[PhysicalBone3D] = []
var active := false
var _fade := 0.0                          ## 1 = ragdoll, 0 = animation
var _getting_up := false


func setup(c: UltraCharacter) -> void:
	character = c
	var sk := c.skeleton
	sim = PhysicalBoneSimulator3D.new()
	sim.name = "Ragdoll"
	# Even inactive, the simulator writes the pose back; zero influence keeps it out of the way.
	sim.active = false
	sim.influence = 0.0
	sk.add_child(sim)
	# Severed parts collapse after the ragdoll has posed the body.
	var dm := sk.get_node_or_null("Dismember")
	if dm:
		sk.move_child(dm, -1)
	var specs := BODIES.duplicate()
	specs.append(["RightFoot", "RightToes", 0.045, 1.0, J.CONE, 25.0, 10.0])
	for spec: Array in specs:
		var b := sk.find_bone(spec[0])
		if b < 0:
			continue
		var end: String = spec[1]
		var length := 0.18
		if end != "":
			var e := sk.find_bone(end)
			if e >= 0:
				length = sk.get_bone_rest(e).origin.length()
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + spec[0]
		pb.bone_name = spec[0]
		pb.mass = spec[3]
		pb.friction = 0.8
		pb.bounce = 0.0
		pb.linear_damp = 0.1
		pb.angular_damp = 0.6
		pb.collision_layer = UltraLayers.RAGDOLL
		pb.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
		pb.body_offset = Transform3D(Basis(), Vector3(0, length * 0.5, 0))
		var r: float = spec[2]
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = r
		cap.height = maxf(length + r * 0.6, r * 2.0 + 0.01)
		cs.shape = cap
		pb.add_child(cs)
		if b == sk.find_bone("Hips"):
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		elif spec[4] == J.HINGE:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			# Hinge axis (joint Z) along the bone's X: the elbow / knee bend axis.
			pb.joint_offset = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0, -length * 0.5, 0))
			pb.set("joint_constraints/angular_limit_enabled", true)
			pb.set("joint_constraints/angular_limit_upper", 5.0)
			pb.set("joint_constraints/angular_limit_lower", -float(spec[5]))
		else:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			# Cone twist axis (joint X) along the bone (+Y).
			pb.joint_offset = Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0, -length * 0.5, 0))
			pb.set("joint_constraints/swing_span", float(spec[5]))
			pb.set("joint_constraints/twist_span", float(spec[6]))
		sim.add_child(pb)
		bones.append(pb)


func _physics_process(delta: float) -> void:
	if character == null or sim == null:
		return
	var st := character.state.state
	var down := st == MotorState.Id.RAGDOLL or st == MotorState.Id.DEAD
	if down and not active:
		start()
	elif st == MotorState.Id.GET_UP and active and not _getting_up:
		_getting_up = true
		character.ragdoll_offset = hips_offset()
	elif not down and st != MotorState.Id.GET_UP and active:
		stop()
	if _getting_up:
		_fade = maxf(_fade - delta / 0.6, 0.0)
		sim.influence = _fade
		if _fade <= 0.0:
			stop()


func start() -> void:
	active = true
	_getting_up = false
	_fade = 1.0
	sim.active = true
	sim.influence = 1.0
	sim.physical_bones_start_simulation()
	var v := character.state.vel + character.state.trav_from * 0.6
	for pb in bones:
		pb.linear_velocity = v
		pb.angular_velocity = Vector3.ZERO


func stop() -> void:
	active = false
	_getting_up = false
	sim.physical_bones_stop_simulation()
	sim.active = false
	sim.influence = 0.0
	_fade = 0.0


## Where the ragdoll's hips lie relative to the capsule (on the ground plane).
func hips_offset() -> Vector3:
	for pb in bones:
		if pb.bone_name == "Hips":
			var d := pb.global_position - character.state.pos
			return Vector3(d.x, 0, d.z)
	return Vector3.ZERO


func hips_position() -> Vector3:
	for pb in bones:
		if pb.bone_name == "Hips":
			return pb.global_position
	return character.state.pos


func max_speed() -> float:
	var m := 0.0
	for pb in bones:
		m = maxf(m, pb.linear_velocity.length())
	return m
