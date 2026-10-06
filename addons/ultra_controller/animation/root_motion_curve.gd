@tool
class_name RootMotionCurve
extends Resource
## Root displacement of a clip, baked at import. Positions are in CHARACTER space
## (metres, -Z forward, +X right) relative to the clip start. The motor plays these instead of
## reading root motion from the AnimationTree, so root-motion moves are deterministic,
## predictable on clients and warpable (scale per axis to hit a ledge exactly).

@export var clip: StringName
@export var length: float = 0.0
@export var sample_rate: float = 60.0
## Playback speed (the motor's clock and the clip together; the prone roll is played at 1.6).
@export var rate: float = 1.0
@export var positions: PackedVector3Array = []
@export var yaws: PackedFloat32Array = []


func sample_pos(t: float) -> Vector3:
	if positions.is_empty():
		return Vector3.ZERO
	var f := clampf(t, 0.0, length) * sample_rate
	var i := int(f)
	if i >= positions.size() - 1:
		return positions[positions.size() - 1]
	return positions[i].lerp(positions[i + 1], f - i)


func sample_yaw(t: float) -> float:
	if yaws.is_empty():
		return 0.0
	var f := clampf(t, 0.0, length) * sample_rate
	var i := int(f)
	if i >= yaws.size() - 1:
		return yaws[yaws.size() - 1]
	return lerpf(yaws[i], yaws[i + 1], f - i)


func total() -> Vector3:
	return positions[positions.size() - 1] if not positions.is_empty() else Vector3.ZERO


## Axis-aligned extent of the path (for warping).
func extent() -> AABB:
	var a := AABB()
	for p in positions:
		a = a.expand(p)
	return a
