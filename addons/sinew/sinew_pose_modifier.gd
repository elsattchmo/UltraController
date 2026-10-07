class_name SinewPoseModifier
extends SkeletonModifier3D
## Sinew's place in the skeleton's modifier stack (where the PhysicalBoneSimulator3D was: after
## the animation, IK and injury passes, before Dismember). Each frame it
##  1. records the pose that reaches it (the animated pose: Sinew's target / tracking pose), and
##  2. writes the physics pose over it, by `influence` (1 = the body is all physics), each part
##     interpolated between the last two physics ticks.
## Bones without a part of their own (shoulders, fingers, toes, the head on the neck part) keep
## their animated pose relative to their parent.

var ragdoll: SinewRagdoll
## 0 = animation only, 1 = the physics body.
var blend := 0.0
## The animated pose of each part's bone, skeleton space, as of the last frame.
var anim_pose: Array[Transform3D] = []


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or ragdoll == null or ragdoll.parts.is_empty():
		return
	var n := ragdoll.parts.size()
	if anim_pose.size() != n:
		anim_pose.resize(n)
	for i in n:
		anim_pose[i] = sk.get_bone_global_pose(ragdoll.parts[i].bone)
	if blend <= 0.0 or ragdoll.pose_now.size() != n:
		return
	var to_skel := sk.global_transform.affine_inverse()
	var f := Engine.get_physics_interpolation_fraction()
	for i in n:          # parents first, so each part's local pose is taken against its placed parent
		var w: Transform3D = ragdoll.pose_prev[i].interpolate_with(ragdoll.pose_now[i], f)
		var phys := to_skel * w
		var xf := anim_pose[i].interpolate_with(phys, blend) if blend < 1.0 else phys
		sk.set_bone_global_pose(ragdoll.parts[i].bone, xf)
