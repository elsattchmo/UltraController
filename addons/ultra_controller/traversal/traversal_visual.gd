class_name UltraTraversalVisual
extends Node
## Hands on traversal geometry: both hands on the rope (one above the other) and on the ledge
## edge while hanging / shimmying. Presentation only: reads MotorState, never writes it.

const GRIP_GAP := 0.13               ## rope: half the distance between the two hands
const LEDGE_HALF := 0.21             ## ledge: half the distance between the two hands

var character: UltraCharacter
var _owns := false


func setup(c: UltraCharacter) -> void:
	character = c
	# After equipment (110): traversal hands win while they're in use.
	process_priority = 111


func _process(_delta: float) -> void:
	if character == null or character.anim == null:
		return
	var ik := character.anim.hand_ik
	var s := character.state
	var vis := character.visual_root.global_transform
	var right := vis.basis.x.normalized()
	var L := HandIKModifier.Hand.LEFT
	var R := HandIKModifier.Hand.RIGHT
	match s.state:
		MotorState.Id.ROPE:
			var grip := rope_grip(character)
			var rope := UltraRope.find(s.trav_id)
			if rope == null:
				_release(ik)
				return
			var up := (rope.anchor() - grip).normalized()
			# Right hand above, left below; wrists just beside and behind the rope.
			var back := vis.basis.z.normalized() * 0.05
			ik.set_goal(R, Transform3D(vis.basis, grip + up * GRIP_GAP + right * 0.035 + back), 1.0, false, 14.0)
			ik.set_goal(L, Transform3D(vis.basis, grip - up * GRIP_GAP - right * 0.035 + back), 1.0, false, 14.0)
			_owns = true
		MotorState.Id.LEDGE_HANG:
			var edge_dir := s.trav_normal.cross(Vector3.UP).normalized()
			var c := s.trav_point + s.trav_normal * 0.05 + Vector3.UP * 0.02
			# Hands lead a little while shimmying.
			var lead := edge_dir * clampf(character.last_input.move.x, -1.0, 1.0) * 0.06 * signf(edge_dir.dot(right))
			ik.set_goal(L, Transform3D(vis.basis, c - right * LEDGE_HALF + lead), 1.0, false, 12.0)
			ik.set_goal(R, Transform3D(vis.basis, c + right * LEDGE_HALF + lead), 1.0, false, 12.0)
			_owns = true
		_:
			_release(ik)


func _release(ik: HandIKModifier) -> void:
	if _owns:
		ik.release(HandIKModifier.Hand.LEFT, 6.0)
		ik.release(HandIKModifier.Hand.RIGHT, 6.0)
		_owns = false


## Where the hands hold the rope: `trav_s` down the line from the anchor through the feet.
static func rope_grip(c: UltraCharacter) -> Vector3:
	var rope := UltraRope.find(c.state.trav_id)
	if rope == null:
		return c.visual_feet + Vector3.UP * 2.0
	var a := rope.anchor()
	var d := c.visual_feet - a
	return a + (d.normalized() if d.length() > 0.01 else Vector3.DOWN) * c.state.trav_s
