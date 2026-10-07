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
	var to_skel := sk.global_transform.affine_inverse()
	var f := Engine.get_physics_interpolation_fraction()
	# The gait's pose over the clip's (it IS the animated pose then: what shows and what the body tracks).
	var gw := ragdoll.gait_w
	var gait := gw > 0.0 and ragdoll.gait_now.size() == n and ragdoll.gait_prev.size() == n
	if gait:
		# Blended down the chain, part by part in its parent's frame: a part keeping the clip (an
		# arm holding an item) stays attached to the gait's pelvis / spine instead of floating where
		# the clip's own pelvis had it.
		var clip := anim_pose.duplicate()
		var g: Array[Transform3D] = []
		g.resize(n)
		for i in n:
			g[i] = to_skel * ragdoll.gait_prev[i].interpolate_with(ragdoll.gait_now[i], f)
		for i in n:
			var k := gw * (ragdoll.gait_part_w[i] if i < ragdoll.gait_part_w.size() else 1.0)
			var p: int = ragdoll.parts[i].parent
			if p < 0:
				anim_pose[i] = clip[i].interpolate_with(g[i], k)
				continue
			var local_clip: Transform3D = (clip[p] as Transform3D).affine_inverse() * clip[i]
			var local_gait: Transform3D = g[p].affine_inverse() * g[i]
			anim_pose[i] = anim_pose[p] * local_clip.interpolate_with(local_gait, k)
	if blend <= 0.0 or ragdoll.pose_now.size() != n:
		if gait:
			for i in n:
				sk.set_bone_global_pose(ragdoll.parts[i].bone, anim_pose[i])
		return
	var pw := ragdoll.part_w
	for i in n:          # parents first, so each part's local pose is taken against its placed parent
		# Per part: physics where it's physical, else exactly this frame's animated pose (set
		# explicitly - a physical parent would otherwise carry an animated child off its pose).
		var k := blend * (pw[i] if i < pw.size() else 1.0)
		if k <= 0.0:
			sk.set_bone_global_pose(ragdoll.parts[i].bone, anim_pose[i])
			continue
		var w: Transform3D = ragdoll.pose_prev[i].interpolate_with(ragdoll.pose_now[i], f)
		var phys := to_skel * w
		var xf := anim_pose[i].interpolate_with(phys, k) if k < 1.0 else phys
		sk.set_bone_global_pose(ragdoll.parts[i].bone, xf)
