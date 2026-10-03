extends SceneTree
func _init() -> void:
	for c in ["SkeletonModifier3D","TwoBoneIK3D","FABRIK3D","CCDIK3D","JacobianIK3D","SplineIK3D","ChainIK3D","IKModifier3D","LookAtModifier3D","BoneConstraint3D","AimModifier3D","CopyTransformModifier3D","RetargetModifier3D","SpringBoneSimulator3D","PhysicalBoneSimulator3D","BoneTwistDisperser3D","LimitAngularVelocityModifier3D","ModifierBoneTarget3D","SkeletonIK3D","AnimationNodeExtension","OfflineMultiplayerPeer","JoltPhysicsServer3D"]:
		print(c, " exists=", ClassDB.class_exists(c))
	for c in ["SkeletonModifier3D","TwoBoneIK3D","LookAtModifier3D"]:
		if not ClassDB.class_exists(c): continue
		print("== ", c, " methods:")
		var ms := []
		for m in ClassDB.class_get_method_list(c, true): ms.append(m.name)
		print("  ", ms)
		var ps := []
		for p in ClassDB.class_get_property_list(c, true): ps.append(p.name)
		print("  props: ", ps)
		print("  signals: ", ClassDB.class_get_signal_list(c, true).map(func(s): return s.name))
	print("Skeleton3D signals: ", ClassDB.class_get_signal_list("Skeleton3D", true).map(func(s): return s.name))
	var aps := []
	for p in ClassDB.class_get_property_list("AnimationNodeAnimation", true): aps.append(p.name)
	print("AnimationNodeAnimation props: ", aps)
	var bps := []
	for p in ClassDB.class_get_property_list("AnimationNodeBlendSpace2D", true): bps.append(p.name)
	print("BS2D props: ", bps)
	print("physics engine setting: ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	var jp := []
	for p in ProjectSettings.get_property_list():
		if str(p.name).begins_with("physics/jolt"): jp.append(p.name)
	print("jolt settings: ", jp)
	quit()
