@tool
class_name DismemberModifier
extends SkeletonModifier3D
## Last in the modifier stack: severed regions collapse to their joint (the region's root bone
## is scaled to nothing, so everything below it goes too). A flesh cap on the parent hides the
## pinch. Attachments and IK on those bones vanish with them.

var severed := 0                     ## UltraLimbs bitmask (set by UltraBodyFX)
var _roots := {}                     ## region -> bone index


func _ready() -> void:
	_resolve()


func _skeleton_changed(_o: Skeleton3D, _n: Skeleton3D) -> void:
	_resolve()


func _resolve() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	for r: int in UltraLimbs.BONES:
		_roots[r] = sk.find_bone(UltraLimbs.BONES[r][0])


func _process_modification_with_delta(_delta: float) -> void:
	if severed == 0:
		return
	var sk := get_skeleton()
	if sk == null:
		return
	if _roots.is_empty():
		_resolve()
	for r: int in _roots:
		if severed & (1 << r) and _roots[r] >= 0:
			sk.set_bone_pose_scale(_roots[r], Vector3.ONE * 0.0005)
