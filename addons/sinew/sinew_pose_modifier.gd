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
## The clip's own pose (before the gait goes over it), skeleton space: the gait's standing feet.
var clip_pose: Array[Transform3D] = []
## Procedural passes over the animated pose (a controller built on Sinew adds them: Marksman's gun pass), run after
## the gait and the torso twist, before the physics: what they make is what shows AND what the body tracks. Each is
## an object with `apply(mod: SinewPoseModifier, sk: Skeleton3D) -> bool` (true = it changed `anim_pose`).
var passes: Array = []
## The same after the physics pose is written (on the skeleton itself: `apply_post(mod, sk)`): what must hold on the pose
## as it SHOWS, physics included - Marksman's support hand back on the gun a physical arm or chest carried off.
var post_passes: Array = []
## Torso twist shares, by bone (the head's part sits on the neck bone).
const TWIST_SHARE := {"Spine": 0.15, "Chest": 0.15, "UpperChest": 0.2, "Neck": 0.5}
var _twist_parts: Array = []     ## [[part index, share, [subtree part indices]], ...]


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or ragdoll == null or ragdoll.parts.is_empty():
		return
	var n := ragdoll.parts.size()
	if anim_pose.size() != n:
		anim_pose.resize(n)
	for i in n:
		anim_pose[i] = sk.get_bone_global_pose(ragdoll.parts[i].bone)
	clip_pose = anim_pose.duplicate()
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
		ragdoll.guard_clip_feet(sk.global_transform, clip)
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
	# The torso toward the aim, spread up the spine (the neck and head most), each part turning
	# everything above it about its own joint round the skeleton's up.
	var twisted := absf(ragdoll.torso_twist) > 1e-4
	if twisted:
		_twist(sk, n)
	for p in passes:
		if p.apply(self, sk):
			twisted = true      # (written below like the twist)
	if blend <= 0.0 or ragdoll.pose_now.size() != n:
		if gait or twisted:
			for i in n:
				sk.set_bone_global_pose(ragdoll.parts[i].bone, anim_pose[i])
		for p in post_passes:
			p.apply_post(self, sk)
		return
	var pw := ragdoll.part_w
	var cut := ragdoll.part_cut
	for i in n:          # parents first, so each part's local pose is taken against its placed parent
		# A cut-off part stays on its parent as animated (it's hidden; the gore system throws the gib).
		var p: int = ragdoll.parts[i].parent
		if i < cut.size() and cut[i] != 0 and p >= 0:
			var placed := sk.get_bone_global_pose(ragdoll.parts[p].bone)
			sk.set_bone_global_pose(ragdoll.parts[i].bone, placed * (anim_pose[p].affine_inverse() * anim_pose[i]))
			continue
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
	for p in post_passes:
		p.apply_post(self, sk)


func _twist(sk: Skeleton3D, n: int) -> void:
	if _twist_parts.is_empty():
		for i in n:
			var bone: String = sk.get_bone_name(ragdoll.parts[i].bone)
			if TWIST_SHARE.has(bone):
				var sub: Array[int] = []
				for j in n:
					var k := j
					while k >= 0 and k != i:
						k = ragdoll.parts[k].parent
					if k == i:
						sub.append(j)
				_twist_parts.append([i, float(TWIST_SHARE[bone]), sub])
		if _twist_parts.is_empty():
			_twist_parts.append([-1, 0.0, []])
	var up := (sk.global_transform.basis.inverse() * Vector3.UP).normalized()
	for t: Array in _twist_parts:
		var i: int = t[0]
		if i < 0:
			return
		var pivot: Vector3 = anim_pose[i].origin
		var r := Transform3D(Basis(up, ragdoll.torso_twist * float(t[1])), Vector3.ZERO)
		var about := Transform3D(Basis(), pivot) * r * Transform3D(Basis(), -pivot)
		for j: int in t[2]:
			anim_pose[j] = about * anim_pose[j]
