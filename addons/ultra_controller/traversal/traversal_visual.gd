class_name UltraTraversalVisual
extends Node
## Hands (and feet) on traversal geometry: both hands on the rope (one above the other), palms
## over the ledge edge while hanging / shimmying, hands and feet on ladder rungs.
## Presentation only: reads MotorState, never writes it.

const GRIP_GAP := 0.13               ## rope: half the distance between the two hands
const LEDGE_HALF := 0.21             ## ledge: half the distance between the two hands
## Ladder: hand / foot bone relative to the rung it holds (up, out from the ladder). The wrist
## sits under the rung with the palm on its face and the fingers curled over the top; the
## ankle sits above and in front of the rung the ball of the foot stands on.
const RUNG_HAND := Vector2(-0.05, 0.05)
const RUNG_FOOT := Vector2(0.07, 0.13)

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
			var back := vis.basis.z.normalized() * 0.05
			_rope_legs(ik, grip, up, vis, rope)
			if absf(UltraRope.climb_input(rope, character.last_input)) > 0.0:
				# Climbing: the hands go hand over hand with the climb cycle, held onto the rope.
				ik.set_line_goal(R, grip + right * 0.035 + back, up, Vector2(-0.7, 0.7), 1.0, 14.0)
				ik.set_line_goal(L, grip - right * 0.035 + back, up, Vector2(-0.7, 0.7), 1.0, 14.0)
			else:
				# Swinging: right hand above, left below, fixed on the rope.
				ik.set_goal(R, Transform3D(vis.basis, grip + up * GRIP_GAP + right * 0.035 + back), 1.0, false, 14.0)
				ik.set_goal(L, Transform3D(vis.basis, grip - up * GRIP_GAP - right * 0.035 + back), 1.0, false, 14.0)
			_owns = true
		MotorState.Id.LEDGE_HANG:
			# Palms flat on top of the ledge, fingers curled over toward the wall: the wrist sits
			# just above the top, a hand's length back from the edge.
			var n := s.trav_normal
			var fingers := (-n * 0.85 + Vector3.DOWN * 0.15).normalized()
			var top := s.trav_point + Vector3.UP * 0.035
			var sk := character.skeleton
			for h: int in [L, R]:
				# Keep the animated (shimmying) hand's sideways position, clamped near the body.
				var hb := sk.global_transform * sk.get_bone_global_pose(ik.hand_bone(h)).origin
				var side := (hb - s.trav_point).dot(right)
				side = clampf(side, -0.45, -0.08) if h == L else clampf(side, 0.08, 0.45)
				var contact := top + right * side
				var wrist := contact + n * 0.015
				ik.set_goal(h, Transform3D(ik.hand_basis(h, fingers, Vector3.DOWN), wrist), 1.0, true, 14.0, 0.0)
			_release_feet(ik)
			_owns = true
		MotorState.Id.LADDER:
			_ladder_limbs(ik, vis)
			_owns = true
		_:
			_release(ik)


func _release(ik: HandIKModifier) -> void:
	if _owns:
		for h in 4:
			ik.release(h, 6.0)
		_owns = false


func _release_feet(ik: HandIKModifier) -> void:
	ik.release(HandIKModifier.Hand.LEFT_FOOT, 6.0)
	ik.release(HandIKModifier.Hand.RIGHT_FOOT, 6.0)


## Ladder: each hand / foot that the climb cycle brings near a rung is pulled onto it
## (hands wrapped round it, feet on it); between rungs the animation moves it.
func _ladder_limbs(ik: HandIKModifier, vis: Transform3D) -> void:
	var lad := UltraLadder.find(character.state.trav_id)
	if lad == null or lad.kind != UltraLadder.Kind.LADDER:
		_release(ik)
		return
	var sk := character.skeleton
	var o := lad.global_position
	var up := Vector3.UP
	var n := lad.normal()
	var r := up.cross(n).normalized()
	var half := lad.width * 0.5 - 0.06
	for h in 4:
		var b := ik.hand_bone(h)
		if b < 0:
			continue
		var p := sk.global_transform * sk.get_bone_global_pose(b).origin
		var foot := h >= 2
		var off := RUNG_FOOT if foot else RUNG_HAND
		var hgt := (p - o).dot(up) - off.x
		var k := clampf(roundf((hgt - UltraLadder.FIRST_RUNG) / UltraLadder.RUNG_SPACING), 0.0, lad.rung_count() - 1.0)
		var rung := UltraLadder.FIRST_RUNG + k * UltraLadder.RUNG_SPACING
		var near := absf(hgt - rung)
		var w := 1.0 - smoothstep(0.05, 0.13, near)
		var x := clampf((p - o).dot(r), -half, half)
		var target := o + up * (rung + off.x) + r * x + n * off.y
		if foot:
			ik.set_goal(h, Transform3D(vis.basis, target), w, false, 12.0)
		else:
			var fingers := (-n * 0.3 + up * 0.95).normalized()
			ik.set_goal(h, Transform3D(ik.hand_basis(h, fingers, -n), target), w, true, 12.0)


## Rope: on a swing rope the legs kick out with the arc - forward at the front of the swing,
## back at the back (angle from the hips follows the rope's angle), the way you pump a swing.
func _rope_legs(ik: HandIKModifier, grip: Vector3, up: Vector3, vis: Transform3D, rope: UltraRope) -> void:
	var climbing := absf(UltraRope.climb_input(rope, character.last_input)) > 0.0
	if climbing:
		_release_feet(ik)
		return
	var fwd := -vis.basis.z.normalized()
	var right := vis.basis.x.normalized()
	var flat := Basis(Vector3.UP, character.state.body_yaw) * Vector3.FORWARD
	var theta := asin(clampf(-up.dot(flat), -1.0, 1.0))         # + = out in front of the anchor
	var a := clampf(theta * 1.2, -0.55, 0.95)
	var sk := character.skeleton
	var hips := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Hips")).origin
	var leg := (-up * cos(a) + fwd * sin(a)) * 0.84
	for h: int in [HandIKModifier.Hand.LEFT_FOOT, HandIKModifier.Hand.RIGHT_FOOT]:
		var side := -0.1 if h == HandIKModifier.Hand.LEFT_FOOT else 0.1
		ik.set_goal(h, Transform3D(vis.basis, hips + leg + right * side), 0.9, false, 5.0)


## Where the hands hold the rope: `trav_s` down the line from the anchor through the feet.
static func rope_grip(c: UltraCharacter) -> Vector3:
	var rope := UltraRope.find(c.state.trav_id)
	if rope == null:
		return c.visual_feet + Vector3.UP * 2.0
	var a := rope.anchor()
	var d := c.visual_feet - a
	return a + (d.normalized() if d.length() > 0.01 else Vector3.DOWN) * c.state.trav_s
