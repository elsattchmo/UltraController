class_name MarksmanDraw
extends RefCounted
## Drawing and putting away (the user: "we also need a small animation to equip these items"): the hand goes to where the
## item is carried - the hip holster, the sling on the back - takes it there, and brings it up into the hold; putting it
## away is the same backwards. Timed off the sim's own clock (UltraActionLayer: EQUIPPING over `equip_time`, HOLSTERING
## over 0.7 x it), so every machine shows the same; presentation only - the sim's timings stay the UltraController's.
## Until the hand has the item the body shows itself without it (`shown_def`: stance, item clips), and the item shows in
## its place (`post`: the held node is put where the stowed copy would be).

## Share of a draw when the hand has the item.
const GRAB := 0.45
## Share of putting it away when the item is back in its place.
const RELEASE := 0.68
## The hand's path bows out to its own side (round the hip / shoulder, not through the body) and forward (m).
const BOW_OUT := 0.16
const BOW_FWD := 0.08
## The support hand joins the gun over the last part of the bring-up (and leaves at the start of putting it away).
const SUPPORT_FROM := 0.5
## The trunk bends toward an item out of the arm's reach (a hip holster from upright) by at most this (rad).
const BEND_MAX := 0.45
## States the draw is shown in (lying, swimming, climbing...: the item just appears in the hand, as before).
const STATES := [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.CROUCH, MotorState.Id.LAND, MotorState.Id.JUMP,
		MotorState.Id.FALL, MotorState.Id.TURN_IN_PLACE]


## Carried somewhere on the body when it isn't in the hand (a holster, a sling): only those have a draw.
static func stowable(def: ItemDefinition) -> bool:
	return def != null and def.equip_scene != null and (def.can_equip(ItemDefinition.EquipSlot.HIP) or def.can_equip(ItemDefinition.EquipSlot.BACK))


## Seconds the draw / putting away takes (the action layer's own).
static func duration(st: MotorState, def: ItemDefinition) -> float:
	var t := def.equip_time if def else 0.3
	return t * 0.7 if st.action == UltraActionLayer.Action.HOLSTERING else t


## Is the item in the hand (rather than still, or already back, in its place)? A pure function of the state.
static func in_hand(st: MotorState, def: ItemDefinition) -> bool:
	if st.held_uid == 0 or def == null:
		return false
	if not stowable(def) or not st.state in STATES:
		return true
	if st.action == UltraActionLayer.Action.EQUIPPING:
		return st.action_t >= GRAB * duration(st, def)
	if st.action == UltraActionLayer.Action.HOLSTERING:
		return st.action_t < RELEASE * duration(st, def)
	return true


## The item the body shows holding (stances, item clips): none while the hand is still on its way to it.
static func shown_def(c: UltraCharacter) -> ItemDefinition:
	var def := c.held_def()
	return def if in_hand(c.state, def) else null


## A draw / putting away is under way (shown).
static func active(st: MotorState, def: ItemDefinition) -> bool:
	return st.held_uid != 0 and stowable(def) and st.state in STATES \
			and (st.action == UltraActionLayer.Action.EQUIPPING or st.action == UltraActionLayer.Action.HOLSTERING)


## How far the hold brings the item up (UltraActionLayer.raised, but 0 until the hand has it).
static func raised(st: MotorState, def: ItemDefinition) -> float:
	if st.action == UltraActionLayer.Action.EQUIPPING and stowable(def) and st.state in STATES:
		var u := st.action_t / maxf(duration(st, def), 0.05)
		return clampf((u - GRAB) / (1.0 - GRAB), 0.0, 1.0)
	return UltraActionLayer.raised(st)


var k := 0.0                ## how far the hand is from the hold toward the item's place (0 hold .. 1 at the place)
var at_place := false       ## the item shows in its place, not in the hand
var support_w := 1.0        ## how much the support hand is on the gun (apply_post's grip takes it)
var _def: ItemDefinition = null
var _placed: Node3D = null


## The gun-hand arm along the way (pre-physics, on the pass's pose: after the hold, so the way back ends on it).
func apply(gp: MarksmanGunPass, sk: Skeleton3D, pose: Array[Transform3D]) -> bool:
	k = 0.0
	at_place = false
	support_w = 1.0
	var st := gp.character.state
	var eq := gp._equipment()
	_def = eq.held_def if eq else null
	if _def == null or eq.held_node == null or st.held_uid == 0 or not stowable(_def) or not st.state in STATES:
		return false
	if st.action != UltraActionLayer.Action.EQUIPPING and st.action != UltraActionLayer.Action.HOLSTERING:
		return false
	var place_i := gp._part(String(_def.holster_bone))
	var h := gp._gpart("Hand")
	var uc := gp._part("UpperChest")
	if place_i < 0 or h < 0 or uc < 0:
		return false
	# (The visual runs a tick behind the sim, between the last two ticks.)
	var rate := float(Engine.physics_ticks_per_second)
	var t := maxf(st.action_t - (1.0 - Engine.get_physics_interpolation_fraction()) / rate, 0.0)
	var u := clampf(t / maxf(duration(st, _def), 0.05), 0.0, 1.0)
	var bring := 0.0            # (how far into the hand's way back to the hold, item in hand)
	if st.action == UltraActionLayer.Action.EQUIPPING:
		if u < GRAB:
			k = smoothstep(0.0, GRAB, u)
			at_place = true
		else:
			bring = smoothstep(GRAB, 1.0, u)
			k = 1.0 - bring
	else:
		if u < RELEASE:
			k = smoothstep(0.0, RELEASE, u)
			bring = 1.0 - k
		else:
			k = 1.0 - smoothstep(RELEASE, 1.0, u)
			at_place = true
	if k <= 0.0001:
		return false
	var grip := eq.grip()
	var ua := gp._gpart("UpperArm")
	var la := gp._gpart("LowerArm")
	var sp := gp._part("Spine")
	var target := _target(gp, pose, place_i, h, uc, grip)
	# (Upright, a hip holster is out of the arm's reach: the trunk bends down toward it - the shoulder drops to the draw.)
	var bent := 0.0
	for it in 3:
		if ua < 0 or la < 0 or sp < 0:
			break
		var reach := pose[ua].origin.distance_to(pose[la].origin) + pose[la].origin.distance_to(pose[h].origin)
		var short := pose[ua].origin.distance_to(target.origin) - reach * 0.97
		if short <= 0.003 or bent >= BEND_MAX:
			break
		var lever := pose[ua].origin - pose[sp].origin
		var axis := lever.cross(target.origin - pose[ua].origin)
		if axis.length() < 1e-5:
			break
		var a := minf(short / maxf(lever.length(), 0.2), BEND_MAX - bent)
		bent += a
		var bend := Quaternion(axis.normalized(), a)
		for n: String in MarksmanGunPass.SPINE_SHARE:
			var i := gp._part(n)
			if i >= 0:
				gp._turn_subtree(pose, i, Quaternion.IDENTITY.slerp(bend, float(MarksmanGunPass.SPINE_SHARE[n])), pose[i].origin)
		target = _target(gp, pose, place_i, h, uc, grip)
	# (The support arm first, onto the gun as the hand will have it - its target is solved from the clip's own hand.)
	var lh := gp._part("LeftHand")
	var rel: Transform3D = gp._support_rel_now if gp._armed_now else _def.support_offset
	var supports := _def.two_handed and gp.two and lh >= 0 and gp._clip_pose.size() == pose.size() and not rel.is_equal_approx(Transform3D.IDENTITY)
	if supports:
		support_w = smoothstep(SUPPORT_FROM, 1.0, bring) if not at_place else 0.0
	gp._two_bone(pose, ua, la, h, target, 1.0)
	if supports:
		var clip_hand: Transform3D = gp._clip_pose[lh]
		var on_gun: Transform3D = pose[h] * grip * rel
		var s_target := clip_hand.interpolate_with(on_gun, support_w) if support_w > 0.0 else clip_hand
		gp._two_bone(pose, gp._part("LeftUpperArm"), gp._part("LeftLowerArm"), lh, s_target, 1.0)
	return true


## The hand's spot now: from the hold toward where it takes the item (k), bowed out round the body.
func _target(gp: MarksmanGunPass, pose: Array[Transform3D], place_i: int, h: int, uc: int, grip: Transform3D) -> Transform3D:
	var hand_place: Transform3D = pose[place_i] * _def.holster_offset * grip.affine_inverse()
	var from: Transform3D = pose[h]
	var ax := gp._chest_axes(pose, uc)          # (x = the character's left, y up, z forward)
	var bow := (-ax.x * float(gp.side) * BOW_OUT + ax.z * BOW_FWD) * sin(PI * k)
	var p := from.origin.lerp(hand_place.origin, k) + bow
	var q := from.basis.get_rotation_quaternion().slerp(hand_place.basis.get_rotation_quaternion(), k)
	return Transform3D(Basis(q), p)


## After physics: the item in its place while the hand isn't holding it (where the stowed copy shows it).
func post(gp: MarksmanGunPass, sk: Skeleton3D) -> void:
	var eq := gp._equipment()
	var node: Node3D = eq.held_node if eq else null
	if at_place and node and _def:
		var b := sk.find_bone(String(_def.holster_bone))
		if b >= 0:
			node.top_level = true
			node.global_transform = sk.global_transform * (sk.get_bone_global_pose(b) * _def.holster_offset)
			_placed = node
			return
	if _placed != null and is_instance_valid(_placed) and _placed == node and node.top_level and not gp.pinned:
		node.top_level = false
		node.transform = eq.grip()
	_placed = null
