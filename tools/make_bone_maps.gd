extends SceneTree
## Generates the BoneMap resources that retarget source rigs onto SkeletonProfileHumanoid.
## Run: godot --headless --path . --script res://tools/make_bone_maps.gd

const OUT := "res://addons/ultra_controller/import/bone_maps/"

func _init() -> void:
	_save("ue_mannequin_humanoid.tres", _ue_map())
	_save("mixamo_humanoid.tres", _mixamo_map())
	quit()

func _save(file: String, pairs: Dictionary) -> void:
	var bm := BoneMap.new()
	bm.profile = SkeletonProfileHumanoid.new()
	for k: String in pairs:
		bm.set_skeleton_bone_name(StringName(k), StringName(pairs[k]))
	var err := ResourceSaver.save(bm, OUT + file)
	print("saved ", file, " err=", err, " mapped=", pairs.size())

func _ue_map() -> Dictionary:
	var m := {
		"Root": "root", "Hips": "pelvis", "Spine": "spine_01", "Chest": "spine_02",
		"UpperChest": "spine_03", "Neck": "neck_01", "Head": "head",
	}
	for side: Array in [["Left", "_l"], ["Right", "_r"]]:
		var s: String = side[0]
		var x: String = side[1]
		m[s + "Shoulder"] = "clavicle" + x
		m[s + "UpperArm"] = "upperarm" + x
		m[s + "LowerArm"] = "lowerarm" + x
		m[s + "Hand"] = "hand" + x
		m[s + "ThumbMetacarpal"] = "thumb_01" + x
		m[s + "ThumbProximal"] = "thumb_02" + x
		m[s + "ThumbDistal"] = "thumb_03" + x
		for f: Array in [["Index", "index"], ["Middle", "middle"], ["Ring", "ring"], ["Little", "pinky"]]:
			m[s + f[0] + "Proximal"] = f[1] + "_01" + x
			m[s + f[0] + "Intermediate"] = f[1] + "_02" + x
			m[s + f[0] + "Distal"] = f[1] + "_03" + x
		m[s + "UpperLeg"] = "thigh" + x
		m[s + "LowerLeg"] = "calf" + x
		m[s + "Foot"] = "foot" + x
		m[s + "Toes"] = "ball" + x
	return m

func _mixamo_map() -> Dictionary:
	var p := "mixamorig_"   # Godot's FBX importer turns "mixamorig:" into "mixamorig_"
	var m := {
		"Hips": p + "Hips", "Spine": p + "Spine", "Chest": p + "Spine1",
		"UpperChest": p + "Spine2", "Neck": p + "Neck", "Head": p + "Head",
	}
	for s: String in ["Left", "Right"]:
		m[s + "Shoulder"] = p + s + "Shoulder"
		m[s + "UpperArm"] = p + s + "Arm"
		m[s + "LowerArm"] = p + s + "ForeArm"
		m[s + "Hand"] = p + s + "Hand"
		m[s + "ThumbMetacarpal"] = p + s + "HandThumb1"
		m[s + "ThumbProximal"] = p + s + "HandThumb2"
		m[s + "ThumbDistal"] = p + s + "HandThumb3"
		for f: String in ["Index", "Middle", "Ring"]:
			m[s + f + "Proximal"] = p + s + "Hand" + f + "1"
			m[s + f + "Intermediate"] = p + s + "Hand" + f + "2"
			m[s + f + "Distal"] = p + s + "Hand" + f + "3"
		m[s + "LittleProximal"] = p + s + "HandPinky1"
		m[s + "LittleIntermediate"] = p + s + "HandPinky2"
		m[s + "LittleDistal"] = p + s + "HandPinky3"
		m[s + "UpperLeg"] = p + s + "UpLeg"
		m[s + "LowerLeg"] = p + s + "Leg"
		m[s + "Foot"] = p + s + "Foot"
		m[s + "Toes"] = p + s + "ToeBase"
	return m
