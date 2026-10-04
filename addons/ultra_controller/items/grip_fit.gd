class_name UltraGripFit
extends RefCounted
## Fits a one-hand item into the posed hand from the fingers themselves: the item's handle runs
## through the hole the curled middle/ring/little fingers make against the palm, top of the
## handle toward the index finger, barrel along the straight trigger finger. The item marks its
## handle with a "GripBody" (centre, +Y up the handle) and points its barrel down -Z.
## Returns the item's transform in the hand bone's space (grip_offset).

static func fit(sk: Skeleton3D, item: Node3D, side := "Right", depth := 0.0) -> Transform3D:
	var g := func(b: String) -> Vector3: return UltraPoseSampler.global_pose(sk, sk.find_bone(side + b)).origin
	var hand := UltraPoseSampler.global_pose(sk, sk.find_bone(side + "Hand"))
	# The fist's hole: centroid of the curled middle / ring finger joints and the palm points
	# under them (knuckle pulled halfway back toward the wrist).
	var pts: Array[Vector3] = []
	for f in ["Middle", "Ring"]:
		var k: Vector3 = g.call(f + "Proximal")
		pts.append(k)
		pts.append(g.call(f + "Intermediate"))
		pts.append(g.call(f + "Distal"))
		pts.append(k.lerp(hand.origin, 0.45))
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	# Up the handle: little-finger knuckle -> index knuckle. Barrel: along the index finger.
	var up: Vector3 = (g.call("IndexProximal") - g.call("LittleProximal")).normalized()
	var idx: Vector3 = (g.call("IndexDistal") - g.call("IndexProximal")).normalized()
	var fwd := (idx - up * idx.dot(up)).normalized()
	# Item frame: handle axis and barrel (orthogonalized) from its GripBody marker.
	var gb := UltraPoseSampler.marker(item, "GripBody")
	var a_g := gb.basis.y.normalized()
	var f_g := Vector3(0, 0, -1)
	f_g = (f_g - a_g * f_g.dot(a_g)).normalized()
	var src := Basis(f_g, a_g, f_g.cross(a_g))
	var dst := Basis(fwd, up, fwd.cross(up))
	var b := dst * src.inverse()
	var centre_g := gb.origin + a_g * depth
	var item_world := Transform3D(b.orthonormalized(), c - b * centre_g)
	return hand.affine_inverse() * item_world
