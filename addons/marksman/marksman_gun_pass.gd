class_name MarksmanGunPass
extends RefCounted
## Marksman's gun pass (a SinewPoseModifier pass): the held firearm points where the character aims, the body
## doing it - a pass over the animated pose (after Sinew's gait and torso twist, before the physics), so what it
## makes is what shows and what the body's muscles track.
##  1. The gun: the right hand's pose x the item's grip (UltraEquipmentVisual attaches it so).
##  2. The aim point: where the gun ray (gun_ray(): the sim's aim + free-aim sway, from the shot origin) meets the
##     world, else 60 m out. The barrel (-Z of the gun) is turned onto it - the spine first (yaw and pitch spread
##     up Spine / Chest / UpperChest, <= SPINE_MAX), the rest at the shoulder (the whole gun arm), then a last
##     touch at the wrist; two rounds (each turn moves the muzzle).
##  3. The support hand back on the gun by two-bone IK: the item's fitted support grip (support_offset, rifle /
##     shotgun), else the hand where the clip had it relative to the gun (the pistol's two-handed hold).
## Weighted by how far the gun is up (UltraActionLayer.raised) and not carried low for a sprint (gun_low), eased.

const SPINE_SHARE := {"Spine": 0.2, "Chest": 0.3, "UpperChest": 0.5}
## Most the spine turns toward the aim (rad); the gun arm does the rest.
const SPINE_MAX := 0.6
## Aim point when the ray meets nothing (m).
const FAR := 60.0
## Aiming down the sights: the neck turns at most this far bringing the eye to the stock (rad), and this share of
## the way (the gun comes the rest - to the eye).
const NECK_MAX := 0.35
const HEAD_SHARE := 0.6
## The shoulder pocket off the right shoulder joint, in the chest's frame (x = left / inward, y = up, z = forward), m.
const POCKET := Vector3(0.06, -0.04, 0.05)
## A shouldered gun at the hip: the eye at least this far to the view's left of the stock (m; y unused).
const HIP_LONG := Vector2(0.10, 0.0)
## The most the neck rolls the head back up off the stock at the hip (rad).
const HIP_ROLL := 0.7
## Where a held-out gun's hand sits off the eye (m along the view's right, up, forward): low and right, out in front.
const PISTOL_HIP := Vector3(0.13, -0.22, 0.45)

var character: UltraCharacter
var ragdoll: SinewRagdoll
## How much of the pass shows now (eased).
var weight := 0.0
## Last frame's numbers (tests): barrel error to the aim point (rad), support hand off its target (m).
var aim_error := 0.0
var support_error := 0.0
var aim_point := Vector3.ZERO          ## world
var support_target := Transform3D()    ## skeleton space

var _p := {}                            ## part name -> index
var _sub := {}                          ## part index -> [subtree part indices, itself first]
var _muzzle_local := Transform3D()
var _muzzle_for: Node3D = null
var _stock_local := Transform3D()
var _stock_for: Node3D = null
var _has_stock := false
var _eye_local := Vector3.INF
var _head_bone := -1
var _neck_bone := -1
var _rear_local := Vector3.ZERO
var _front_local := Vector3.ZERO
var _sights_for: Node3D = null
var _palm_local := Vector3.ZERO
var _grip_contact := Vector3.ZERO
var _grip_for: Node3D = null
## How far down the sights now (eased ADS x the pass's weight) and the eye it aimed from (skeleton space; tests).
var ads := 0.0
var ads_eye := Vector3.ZERO
## Last frame's shoulder pocket and stock (skeleton space; tests).
var pocket := Vector3.ZERO
var stock := Vector3.ZERO


func _init(c: UltraCharacter, r: SinewRagdoll) -> void:
	character = c
	ragdoll = r
	for i in r.parts.size():
		_p[String(r.parts[i].name)] = i


func _part(n: String) -> int:
	return int(_p.get(n, -1))


func _subtree(top: int) -> Array:
	if _sub.has(top):
		return _sub[top]
	var out := [top]
	for i in ragdoll.parts.size():
		var j := i
		while j >= 0 and j != top:
			j = int(ragdoll.parts[j].parent)
		if j == top and i != top:
			out.append(i)
	_sub[top] = out
	return out


func _equipment() -> UltraEquipmentVisual:
	return character.get_node_or_null("Equipment") as UltraEquipmentVisual


## The pass. True when it changed the pose.
func apply(mod: SinewPoseModifier, sk: Skeleton3D) -> bool:
	var eq := _equipment()
	var def: ItemDefinition = eq.held_def if eq else null
	var gun_node: Node3D = eq.held_node if eq else null
	var dt := clampf(mod.get_process_delta_time(), 0.0, 0.1)
	var st := character.state
	var armed := def != null and gun_node != null and MarksmanStance.of_item(def) != "unarmed" and st.held_uid != 0
	# (Reloading the gun stays in the hands - brought in and loaded by the body, MarksmanGunPass reload section.)
	var reloading := armed and st.action == UltraActionLayer.Action.RELOADING and def.kind == ItemDefinition.Kind.FIREARM \
			and UltraInjury.two_hands(st)
	var want := (1.0 if reloading else UltraActionLayer.raised(st) * (1.0 - st.gun_low)) if armed else 0.0
	weight = move_toward(weight, want, 6.0 * dt)
	reload_w = move_toward(reload_w, 1.0 if reloading else 0.0, 4.0 * dt)
	_lean_e0 = Vector3.INF
	_armed_now = false
	var leaned := _lean(sk, mod.anim_pose, dt)
	if weight <= 0.001 or not armed:
		return _look_about(mod.anim_pose) or leaned
	var rh := _part("RightHand")
	var lh := _part("LeftHand")
	if rh < 0 or lh < 0:
		return false
	var pose: Array[Transform3D] = mod.anim_pose
	var grip: Transform3D = eq.grip()
	if _muzzle_for != gun_node:
		_muzzle_for = gun_node
		_muzzle_local = UltraPoseSampler.marker(gun_node, "M_Muzzle")
	# The clip's own support hand relative to its gun (kept where the item has no fitted grip).
	var gun0: Transform3D = pose[rh] * grip
	var support_rel: Transform3D = gun0.affine_inverse() * pose[lh]
	if def.two_handed and not def.support_offset.is_equal_approx(Transform3D.IDENTITY):
		support_rel = def.support_offset
	# Aim point (world -> skeleton space).
	var ray := eq.gun_ray()
	var origin: Vector3 = ray.origin
	var dir: Vector3 = ray.dir
	aim_point = origin + dir * FAR
	var space := character.get_world_3d().direct_space_state if character.is_inside_tree() else null
	if space:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * FAR, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
		q.exclude = [character.get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and (hit.position as Vector3).distance_to(origin) > 0.5:
			aim_point = hit.position
	var to_sk := sk.global_transform.affine_inverse()
	var target_sk := to_sk * aim_point
	if _stock_for != gun_node:
		_stock_for = gun_node
		_stock_local = UltraPoseSampler.marker(gun_node, "M_Stock")
		_has_stock = gun_node.find_child("M_Stock", true, false) != null
	var kick: Vector3 = eq._recoil.value * weight
	_rock(pose, kick)
	if def.two_handed and _has_stock:
		_shoulder(sk, pose, rh, grip, target_sk)
	else:
		_hold_out(sk, pose, rh, grip, target_sk)
	if reload_w > 0.001:
		_reload_pose(pose, rh, grip, def)
	_tuck(pose, rh, grip, def, dt)
	ads = eq.ads * weight * (1.0 - tuck_w)
	if ads > 0.001:
		_aim_down_sights(sk, pose, rh, grip, target_sk, def)
	if kick.length() > 1e-5:
		_kick(pose, rh, grip, kick)
	_kick_springs(dt)
	_apply_gun_kick(pose, rh, grip)
	if leaned:
		_lean_settle(sk, pose)
	var gun: Transform3D = pose[rh] * grip
	aim_error = _barrel_turn(gun, target_sk).get_angle()
	# The support hand onto the gun: under the fore-end at M_SupportGrip where the item says how (support_fingers /
	# palm: on top, the fitted support_offset, the forearm rose across the sight picture in ADS), else support_rel.
	support_target = gun * support_rel
	if def.two_handed and def.support_fingers != Vector3.ZERO:
		var under := _support_under(sk, gun, def)
		if under != Transform3D():
			support_target = under
	if reload_w > 0.001:
		var hand := _reload_hand(sk, gun, support_target, def, st)
		if hand != Transform3D():
			support_target = support_target.interpolate_with(hand, smoothstep(0.0, 1.0, reload_w))
	elif _shell_mesh:
		_shell_mesh.visible = false
	_two_bone(pose, _part("LeftUpperArm"), _part("LeftLowerArm"), lh, support_target, weight)
	support_error = pose[lh].origin.distance_to(support_target.origin)
	_support_rel_now = gun.affine_inverse() * support_target
	if support_kick.length() > 1e-4:
		# (The hand knocked off: the target is where the kick has it; apply_post lets go past LET_GO.)
		_two_bone(pose, _part("LeftUpperArm"), _part("LeftLowerArm"), lh, Transform3D(support_target.basis, support_target.origin + support_kick), weight)
	_grip_grip = grip
	_armed_now = true
	_look_about(pose)
	return true


## Freelook (MarksmanFreelook.offset): the head turns toward the view - yaw about the body's up, then pitch about the
## turned right - on the neck (the head's part), last, so the gun and the arms keep the aim.
func _look_about(pose: Array[Transform3D]) -> bool:
	var c := character as MarksmanCharacter
	var fl: MarksmanFreelook = c.eye.freelook if c and c.eye and is_instance_valid(c.eye) else null
	var neck := _part("Neck")
	if fl == null or fl.offset == Vector2.ZERO or neck < 0:
		return false
	# (Skeleton space: up +Y; the model faces +Z, its right is -X. + yaw turns left, + pitch looks up.)
	var yaw := Quaternion(Vector3.UP, fl.offset.x)
	var right := yaw * Vector3(-1, 0, 0)
	var q := Quaternion(right, fl.offset.y) * yaw
	_turn_subtree(pose, neck, q, pose[neck].origin)
	return true


# ------------------------------------------------------------------ hits (V5): the hands stay on the gun

## After the physics (SinewPoseModifier.post_passes): a hit makes the struck chain physical - the chest, an arm - and the
## gun goes where the physical gun hand takes it, but the support hand would stay where its own arm went: it is brought
## back onto the gun AS SHOWN (two-bone IK on the shown skeleton). Knocked further off than LET_GO it lets go (the arm
## its own) and takes hold again once the grip is back within REGRIP, easing on over REGRIP_TIME.
const LET_GO := 0.14
const REGRIP := 0.07
const REGRIP_TIME := 0.18
var grip_w := 1.0                      ## how much the support hand holds the shown gun (0 = let go)
var post_off := 0.0                    ## (tests) how far the support hand was off the shown grip before this pass (m)
var _letgo := false
var _support_rel_now := Transform3D()
var _grip_grip := Transform3D()
var _armed_now := false


func apply_post(mod: SinewPoseModifier, sk: Skeleton3D) -> void:
	var dt := clampf(mod.get_process_delta_time(), 0.0, 0.1)
	if not _armed_now or weight <= 0.001:
		grip_w = 1.0
		_letgo = false
		post_off = 0.0
		return
	var parts: Array = ragdoll.parts
	_carry_arms(mod, sk)
	var ids := [_part("RightHand"), _part("LeftUpperArm"), _part("LeftLowerArm"), _part("LeftHand")]
	for i in ids:
		if int(i) < 0:
			return
	# (Only the parts the solve needs, in skeleton space, as shown.)
	var pose: Array[Transform3D] = []
	pose.resize(parts.size())
	for i in ids:
		pose[i] = sk.get_bone_global_pose(parts[i].bone)
	var gun: Transform3D = pose[ids[0]] * _grip_grip
	var target: Transform3D = gun * _support_rel_now
	post_off = pose[ids[3]].origin.distance_to(target.origin)
	if support_kick.length() > 1e-4:
		# (Knocked off the grip by a hit: the hand goes with the kick; past LET_GO it has let go.)
		post_off = maxf(post_off, support_kick.length())
		target.origin += support_kick
	if post_off < 0.002 and not _letgo and grip_w >= 1.0:
		return
	if post_off > LET_GO:
		_letgo = true
	elif _letgo and post_off < REGRIP:
		_letgo = false
	grip_w = move_toward(grip_w, 0.0 if _letgo else 1.0, dt / REGRIP_TIME)
	var k := smoothstep(0.0, 1.0, grip_w) * weight
	if k <= 0.001:
		return
	_two_bone(pose, ids[1], ids[2], ids[3], target, k)
	for j in range(1, 4):
		sk.set_bone_global_pose(parts[ids[j]].bone, pose[ids[j]])


## An arm hit with the gun up (MarksmanRagdoll.hit): a sprung kick - the gun arm's moves the gun along the hit and turns
## it off its line (KICK_TURN rad per m); the support arm's knocks the hand off the grip (it lets go past LET_GO and takes
## hold again as it settles: apply_post). KICK_PER_DAMAGE m/s of kick per point, at most KICK_MAX; the spring KICK_HZ.
const KICK_PER_DAMAGE := 0.05
const KICK_MAX := 1.4
const SUPPORT_KICK_MAX := 7.0
const KICK_HZ := 2.6
const KICK_TURN := 5.0
var gun_kick := Vector3.ZERO           ## skeleton space (m)
var support_kick := Vector3.ZERO
var _gun_kick_v := Vector3.ZERO
var _support_kick_v := Vector3.ZERO


func arm_hit(region: int, dir: Vector3, amount: float) -> void:
	var sk := character.skeleton
	if sk == null:
		return
	var d := (sk.global_transform.basis.orthonormalized().inverse() * dir).normalized()
	var left := region in [UltraLimbs.Region.ARM_L, UltraLimbs.Region.FOREARM_L, UltraLimbs.Region.HAND_L]
	if left:
		# (A hand alone, not the gun's weight: three times the kick, up to SUPPORT_KICK_MAX - from ~50 points it lets go.)
		_support_kick_v += d * minf(amount * KICK_PER_DAMAGE * 3.0, SUPPORT_KICK_MAX)
	else:
		_gun_kick_v += d * minf(amount * KICK_PER_DAMAGE, KICK_MAX)


func _kick_springs(dt: float) -> void:
	var w := TAU * KICK_HZ
	for k in 2:
		var x: Vector3 = gun_kick if k == 0 else support_kick
		var v: Vector3 = _gun_kick_v if k == 0 else _support_kick_v
		var h := dt / 4.0
		for _s in 4:
			v += (-w * w * x - 2.0 * 0.7 * w * v) * h
			x += v * h
		if k == 0:
			gun_kick = x
			_gun_kick_v = v
		else:
			support_kick = x
			_support_kick_v = v


## The gun moved by the gun arm's kick (after it is placed, before the support hand takes it).
func _apply_gun_kick(pose: Array[Transform3D], rh: int, grip: Transform3D) -> void:
	if gun_kick.length() < 1e-4:
		return
	var gun := pose[rh] * grip
	var hand := gun * grip.affine_inverse().origin
	var axis := (-gun.basis.z.normalized()).cross(gun_kick)
	var turn := Basis(axis.normalized(), minf(gun_kick.length() * KICK_TURN, 0.6)) if axis.length() > 1e-6 else Basis()
	var g := Transform3D(turn * gun.basis, hand + turn * (gun.origin - hand) + gun_kick)
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), 1.0)


## Animated (kinematic) arms on a chest the physics moved: placed on it as they are on the animated chest - the gun
## rocks with the body instead of the arms staying where the chest was (a stretched shoulder).
func _carry_arms(mod: SinewPoseModifier, sk: Skeleton3D) -> void:
	var uc := _part("UpperChest")
	if uc < 0 or mod.anim_pose.size() <= uc:
		return
	var parts: Array = ragdoll.parts
	var shown := sk.get_bone_global_pose(parts[uc].bone)
	var anim: Transform3D = mod.anim_pose[uc]
	if shown.is_equal_approx(anim):
		return
	var delta := shown * anim.affine_inverse()
	var pw := ragdoll.part_w
	for n: String in MarksmanRagdoll.ARM_PARTS:
		var i := _part(n)
		if i >= 0 and (i >= pw.size() or pw[i] < 0.01):
			sk.set_bone_global_pose(parts[i].bone, delta * mod.anim_pose[i])


# ------------------------------------------------------------------ firing (V4): the shot through the body

## The shot's kick (UltraEquipmentVisual._recoil: a spring the fire event kicks - (0, up, back) in the gun's frame, m)
## goes through the body: the chest rocks back with it (before the gun is placed, so the stock / hold follows), then
## the gun is pushed back and its muzzle flips up in the hands, recovering with the spring (the arms follow by IK).
const ROCK := 2.4              ## rad of chest pitch per m of kick back
const FLIP := 1.8              ## rad of muzzle rise per m of kick back
const FLIP_MAX := 0.22         ## rad


func _rock(pose: Array[Transform3D], kick: Vector3) -> void:
	var uc := _part("UpperChest")
	if uc < 0 or kick.z <= 1e-5:
		return
	var ax := _chest_axes(pose, uc)
	# (The chest's x is the character's left: turning about it by -a tips the top back.)
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i >= 0:
			_turn_subtree(pose, i, Quaternion(ax.x, -minf(kick.z * ROCK, 0.25) * float(SPINE_SHARE[n])), pose[i].origin)


func _kick(pose: Array[Transform3D], rh: int, grip: Transform3D, kick: Vector3) -> void:
	var gun := pose[rh] * grip
	var b := gun.basis.orthonormalized()
	var hand := gun * grip.affine_inverse().origin
	# Muzzle up about the hand (about the gun's right: +X turns -Z up by +a), then pushed back along the gun.
	var flip := Basis(b.x.normalized(), minf(kick.z * FLIP, FLIP_MAX))
	var g := Transform3D(flip * b, hand + flip * (gun.origin - hand))
	g.origin += g.basis * kick
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), 1.0)


# ------------------------------------------------------------------ leaning and the wall (V4b)

## Leaning (uc_lean_left / right, InputFrame.B_LEAN_L / R): the spine bends sideways, so the eye - the first-person
## camera - and the gun go out round a corner together, and shots follow (the camera rig's aim_from is the eye).
## Not sprinting, prone or in the air. (rad at full lean; shared up the spine.)
const LEAN_MAX := 0.62
const LEAN_OUT := 0.28        ## m the eye goes out at full lean
const LEAN_SHARE := {"Spine": 0.3, "Chest": 0.3, "UpperChest": 0.4}
var lean := 0.0                ## -1 left .. 1 right, eased
## The gun held up out of a wall's way (0 .. 1, eased) - MarksmanCharacter.tuck_distance.
var tuck_w := 0.0


func _lean(sk: Skeleton3D, pose: Array[Transform3D], dt: float) -> bool:
	var st := character.state
	var i := character.last_input
	var want := 0.0
	var can := character.profile.enable_lean and st.is_grounded() and not st.has(MotorState.F_SPRINTING) \
			and st.stance != MotorState.Stance.CRAWL and st.state in [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.CROUCH, MotorState.Id.TURN_IN_PLACE]
	if i and can:
		want = (1.0 if i.has(InputFrame.B_LEAN_R) else 0.0) - (1.0 if i.has(InputFrame.B_LEAN_L) else 0.0)
	lean = move_toward(lean, want, 3.5 * dt)
	var a := smoothstep(0.0, 1.0, absf(lean)) * signf(lean) * LEAN_MAX
	if absf(a) < 1e-4:
		return false
	# About the VIEW's way (skeleton space; a bladed rifle stance turns the chest 35 deg off the body: about the body's
	# own forward the eye went out 18 cm one way and 27 the other): + tips the top to the view's right.
	var yaw := i.yaw if i else character.state.body_yaw
	var fwd := sk.global_transform.basis.orthonormalized().inverse() * (Basis(Vector3.UP, yaw) * Vector3.FORWARD)
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	# The eye goes out LEAN_OUT at full lean: bend, see how far it went, bend the rest (a shouldered rifle's head is
	# already over the stock - a fixed angle took the eye 20 cm right and 31 left).
	var neck := _part("Neck")
	if neck >= 0 and _eye_local == Vector3.INF:
		_eye_setup(sk)
	var side := fwd.cross(Vector3.UP).normalized()          # (the view's right, skeleton space)
	var e0 := _eye(sk, pose, neck) if neck >= 0 and _head_bone >= 0 else Vector3.INF
	_bend(pose, fwd, a)
	for _r in (2 if e0 != Vector3.INF else 0):
		var went := (_eye(sk, pose, neck) - e0).dot(side) * signf(a)
		var want_out := LEAN_OUT * smoothstep(0.0, 1.0, absf(lean))
		if went > 0.02:
			var more := clampf(a * (want_out / went - 1.0), -absf(a) * 0.5, absf(a) * 0.6) if a > 0.0 \
					else clampf(a * (want_out / went - 1.0), -absf(a) * 0.6, absf(a) * 0.5)
			_bend(pose, fwd, more)
			a += more
	if e0 != Vector3.INF:
		var went := (_eye(sk, pose, neck) - e0).dot(side)
		_lean_e0 = e0
		_lean_fwd = fwd
		_lean_side = side
		_lean_gain = absf(went / a) if absf(a) > 1e-3 else 0.0
		_lean_out = signf(a) * LEAN_OUT * smoothstep(0.0, 1.0, absf(lean))
	return true


var _lean_e0 := Vector3.INF
var _lean_fwd := Vector3.ZERO
var _lean_side := Vector3.ZERO
var _lean_gain := 0.0
var _lean_out := 0.0


## After the gun is placed: the head coming up off the stock at the hip (_head_up_at_hip) moves the eye too, by more or
## less as the spine leans - bend the rest so the eye is out LEAN_OUT from where it stands at the hip (_hip_shift left of
## the lean-free eye). About the view's way, so the gun (carried on the chest) only rolls a little round its own line.
func _lean_settle(sk: Skeleton3D, pose: Array[Transform3D]) -> void:
	var neck := _part("Neck")
	if _lean_e0 == Vector3.INF or _lean_gain < 0.05 or neck < 0 or _head_bone < 0:
		return
	var eq := _equipment()
	var held := _hip_shift * weight * (1.0 - (eq.ads if eq else 0.0))
	var want := _lean_out - held
	var total := 0.0
	for _r in 3:
		var err := want - (_eye(sk, pose, neck) - _lean_e0).dot(_lean_side)
		var more := clampf(err / _lean_gain, -0.5 - total, 0.5 - total)
		if absf(err) < 0.005 or absf(more) < 1e-3:
			break
		_bend(pose, _lean_fwd, more)
		total += more


func _bend(pose: Array[Transform3D], fwd: Vector3, a: float) -> void:
	for n: String in LEAN_SHARE:
		var k := _part(n)
		if k >= 0:
			_turn_subtree(pose, k, Quaternion(fwd, a * float(LEAN_SHARE[n])), pose[k].origin)


## Up against a wall the gun comes up out of its way - muzzle raised round the hand, drawn in - and won't fire
## (MarksmanCharacter.simulate strips the trigger on the same test).
func _tuck(pose: Array[Transform3D], rh: int, grip: Transform3D, def: ItemDefinition, dt: float) -> void:
	var c := character as MarksmanCharacter
	var near := c.tuck_distance(c.state, c.last_input) if c and c.last_input else INF
	var want := 0.0
	if near < INF:
		# (By how far the gun would go into the wall: all the way up once 25 cm of it would.)
		want = clampf((MarksmanCharacter.gun_reach(def) - near) / 0.25, 0.0, 1.0)
	tuck_w = move_toward(tuck_w, want, 5.0 * dt)
	if tuck_w <= 0.001:
		return
	var e := smoothstep(0.0, 1.0, tuck_w)
	var gun := pose[rh] * grip
	var b := gun.basis.orthonormalized()
	var hand := gun * grip.affine_inverse().origin
	var up := Basis(b.x.normalized(), deg_to_rad(55.0 if def.two_handed else 40.0) * e)
	var g := Transform3D(up * b, hand + up * (gun.origin - hand))
	g.origin += b.z * (0.12 if def.two_handed else 0.16) * e + Vector3.DOWN * 0.03 * e
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), weight)


# ------------------------------------------------------------------ reloads (V4): loaded by the body
# On the sim's reload clock (action_t, the item's reload_commit / shell timings), as UltraEquipmentVisual's hand-IK
# paths did it (Marksman has no hand IK - its reload showed nothing, the gun dropped to the stance clip and the
# magazine blinked out): the gun comes in and rolls toward the left hand; a magazine is taken out (and dropped), a fresh
# one fetched from the hip pouch and seated; a tube is loaded a shell at a time from the pouch to the load port.

## How far the reload pose is in (0 .. 1).
var reload_w := 0.0
## (roll toward the left hand deg, lowered m, drawn back m, to the middle m) for a shouldered / held-out gun.
const RELOAD_LONG := [22.0, 0.05, 0.06, 0.0]
const RELOAD_SHORT := [32.0, -0.02, 0.12, 0.1]
const MAG_GRAB := 0.22
const MAG_OUT := 0.40
var _mag_dropped := false
var _mag_snd := 0
var _shell_snd := -1
var _shell_mesh: MeshInstance3D


func _reload_pose(pose: Array[Transform3D], rh: int, grip: Transform3D, def: ItemDefinition) -> void:
	var e := smoothstep(0.0, 1.0, reload_w)
	var spec: Array = RELOAD_LONG if def.two_handed else RELOAD_SHORT
	var gun := pose[rh] * grip
	var b := gun.basis.orthonormalized()
	var hand := gun * grip.affine_inverse().origin
	# (About the barrel: -a rolls the top over to the left.)
	var roll := Basis((-b.z).normalized(), -deg_to_rad(float(spec[0])) * e)
	var g := Transform3D(roll * b, hand + roll * (gun.origin - hand))
	g.origin += Vector3.DOWN * float(spec[1]) * e + b.z * float(spec[2]) * e - b.x * float(spec[3]) * e
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), weight)


## The left hand (skeleton space) on the reload's path now, or an empty transform.
func _reload_hand(sk: Skeleton3D, gun: Transform3D, sup: Transform3D, def: ItemDefinition, st: MotorState) -> Transform3D:
	var eq := _equipment()
	if eq == null or eq.held_node == null or not _learn_palm(sk):
		return Transform3D()
	if String(def.stat("reload_mode", "")) == "shell":
		return _shell_hand(sk, gun, sup, def, st, eq)
	var mag := eq.held_node.find_child("Magazine", true, false) as Node3D
	if mag == null or st.action != UltraActionLayer.Action.RELOADING:
		eq._mag_hand = Transform3D()
		_mag_dropped = false
		_mag_snd = 0
		return Transform3D()
	var slow := UltraInjury.reload_mult(st, character.damage_profile)
	var commit := float(def.stat("reload_commit", 1.5)) * slow
	var t := st.action_t
	# An empty reload (MarksmanCharacter.F_EMPTY_RELOAD) runs slower in the sim up to the commit: on its real clock the
	# magazine goes in as usual, then the bolt / slide is racked (_rack) before the round counts.
	var empty := st.has(MarksmanCharacter.F_EMPTY_RELOAD)
	if empty:
		var stretch := MarksmanCharacter.empty_stretch(def, slow)
		t = t * stretch if t < commit else t + commit * (stretch - 1.0)
	var mag_rest: Transform3D = mag.get_meta("rest") if mag.has_meta("rest") else mag.transform
	var par := mag.get_parent() as Node3D
	var mag_in_gun := eq.held_node.global_transform.affine_inverse() * par.global_transform * mag_rest if par != eq.held_node else mag_rest
	var g := gun.orthonormalized()
	var in_well := gun * mag_in_gun
	var to_sk := sk.global_transform.affine_inverse()
	var vr := to_sk * character.visual_root.global_transform
	var fwd := (vr.basis * Vector3.FORWARD).normalized()
	var left := (vr.basis * Vector3.LEFT).normalized()
	var pose := (ragdoll.modifier as SinewPoseModifier).anim_pose
	var hips: Vector3 = pose[maxi(_part("Hips"), 0)].origin
	var pouch := Transform3D(vr.basis.orthonormalized() * mag_in_gun.basis, hips + left * 0.19 + fwd * 0.05 + Vector3.UP * 0.02)
	if st.state == MotorState.Id.CRAWL:
		var chest: Vector3 = pose[maxi(_part("UpperChest"), 0)].origin
		pouch = Transform3D(g.basis, chest + left * 0.16 + Vector3.DOWN * 0.08 - fwd * 0.05)
	var pouch_up := Transform3D(pouch.basis, pouch.origin + Vector3.UP * 0.12)
	var below := Transform3D(g.basis, in_well.origin + g.basis.y * -0.16 + left * 0.04)
	var t_pouch := minf(0.8, commit - 0.7)
	var t_up := commit - 0.3
	var t_seat := commit - 0.12
	var mag_at := in_well
	var in_hand := false
	eq._mag_hidden = false
	if t < MAG_GRAB:
		mag_at = in_well
	elif t < MAG_OUT:
		mag_at = in_well.interpolate_with(below, smoothstep(MAG_GRAB, MAG_OUT, t))
		in_hand = true
	elif t < t_pouch:
		eq._mag_hidden = true
		mag_at = pouch
	elif t < t_pouch + 0.12:
		mag_at = pouch.interpolate_with(pouch_up, smoothstep(t_pouch, t_pouch + 0.12, t))
		in_hand = true
	elif t < t_up:
		mag_at = pouch_up.interpolate_with(below, smoothstep(t_pouch + 0.12, t_up, t))
		in_hand = true
	elif t < t_seat:
		mag_at = below.interpolate_with(in_well, smoothstep(t_up, t_seat, t))
		in_hand = true
	eq._mag_hand = sk.global_transform * mag_at if in_hand else Transform3D()
	# Sounds and the dropped magazine, once each per reload (world space).
	var fx := UltraEffects.instance()
	var well_w := sk.global_transform * in_well.origin
	if fx and fx.sfx:
		var pre := UltraEffects.sound_of(def) + "_reload_"
		if t >= MAG_GRAB and _mag_snd < 1:
			_mag_snd = 1
			fx.sfx.play(pre + "mag_out", well_w, -3.0, 2.5, 25.0)
		if t >= t_up + 0.08 and _mag_snd < 2:
			_mag_snd = 2
			fx.sfx.play(pre + "mag_in", well_w, -2.0, 2.5, 25.0)
		if t >= t_seat + 0.12 and _mag_snd < 3 and not empty:
			_mag_snd = 3
			if not fx.sfx.streams(pre + "slide").is_empty():
				fx.sfx.play(pre + "slide", well_w, -2.0, 2.5, 25.0)
	if t >= MAG_OUT and not _mag_dropped:
		_mag_dropped = true
		if fx and mag is MeshInstance3D:
			var lw := (sk.global_transform.basis * left).normalized()
			fx.drop_mag(mag as MeshInstance3D, sk.global_transform * below, st.vel * 0.8 + Vector3.DOWN * 0.6 + lw * 0.3)
	if t < 0.05:
		_mag_dropped = false
		_mag_snd = 0
	# The hand on a magazine at `m`: palm against its left side, fingers forward round the front.
	var ab := (mag as MeshInstance3D).get_aabb() if mag is MeshInstance3D else AABB(Vector3(-0.012, -0.05, -0.03), Vector3(0.024, 0.1, 0.06))
	var hand_on := func(m: Transform3D) -> Transform3D:
		var mb := m.basis.orthonormalized()
		var contact := m * Vector3(ab.position.x - 0.004, ab.get_center().y - ab.size.y * 0.15, ab.get_center().z)
		return _left_hand(mb * Vector3(0.0, -0.35, -1.0), mb * Vector3.RIGHT, contact, 0.028)
	if t < MAG_GRAB:
		return sup.interpolate_with(hand_on.call(in_well), smoothstep(0.0, MAG_GRAB, t))
	if t < MAG_OUT or (t >= t_pouch and t < t_seat):
		return hand_on.call(mag_at)
	if t < t_pouch:
		return (hand_on.call(below) as Transform3D).interpolate_with(hand_on.call(pouch), smoothstep(MAG_OUT, t_pouch, t))
	if empty:
		var racked := _rack(sk, gun, sup, def, eq, t - t_seat, commit * (MarksmanCharacter.empty_stretch(def, slow) - 1.0) + 0.12, hand_on.call(in_well))
		if racked != Transform3D():
			return racked
	return (hand_on.call(in_well) as Transform3D).interpolate_with(sup, smoothstep(t_seat, commit + 0.15, t))


## The rack after an empty reload's magazine is in: the left hand over the top of the charging handle (rifle) / slide
## (pistol), pulls it back RACK_PULL and lets it fly forward, then goes back to its grip. `u` s since the magazine was
## seated, over `span` s; `from` = the hand on the seated magazine. Transform3D() once done (or nothing to rack).
const RACK_PULL := 0.07
var rack_pull := 0.0                   ## (tests) how far the bolt / slide is back now (m)
var _rack_snd := false


func _rack(sk: Skeleton3D, gun: Transform3D, sup: Transform3D, def: ItemDefinition, eq: UltraEquipmentVisual, u: float, span: float, from: Transform3D) -> Transform3D:
	var part := eq.held_node.find_child("ChargingHandle", true, false) as Node3D
	if part == null:
		part = eq.held_node.find_child("Slide", true, false) as Node3D
	rack_pull = 0.0
	if part == null or u < 0.0:
		_rack_snd = false
		return Transform3D()
	if not part.has_meta("rest"):
		part.set_meta("rest", part.position)
	var g := gun.orthonormalized()
	var to_sk := sk.global_transform.affine_inverse()
	# Back along the gun (+Z: the barrel is -Z), in the part's parent frame.
	var par := part.get_parent() as Node3D
	var back_local := (par.global_transform.basis.orthonormalized().inverse() * (eq.held_node.global_transform.basis.orthonormalized().z)).normalized()
	var reach := 0.15                    # hand from the magazine to the part
	var pull_end := span * 0.7           # pulled back by then, let go
	var back_by := span                  # the hand back on its grip
	var pull := 0.0
	if u > reach:
		pull = RACK_PULL * smoothstep(reach, pull_end, u) if u < pull_end else 0.0
	rack_pull = pull
	part.position = (part.get_meta("rest") as Vector3) + back_local * pull
	if u >= pull_end and not _rack_snd:
		_rack_snd = true
		var fx := UltraEffects.instance()
		if fx and fx.sfx:
			var pre := UltraEffects.sound_of(def) + "_reload_"
			if not fx.sfx.streams(pre + "slide").is_empty():
				fx.sfx.play(pre + "slide", part.global_position, -1.0, 2.5, 25.0)
	if u >= back_by + 0.25:
		_rack_snd = false
		part.position = part.get_meta("rest")
		return Transform3D()
	# Overhand: the palm down on the top of the part, fingers across it to the right; pulled with it.
	var top := to_sk * part.global_position + g.basis.y.normalized() * 0.012
	var held := maxf(pull, RACK_PULL * (1.0 - smoothstep(pull_end, pull_end + 0.08, u)) if u >= pull_end else pull)
	var hand := _left_hand(g.basis.x.normalized() + g.basis.z.normalized() * 0.3, -g.basis.y, top + g.basis.z.normalized() * (held - pull), 0.025)
	if u < reach:
		return from.interpolate_with(hand, smoothstep(0.0, reach, u))
	if u < back_by:
		return hand
	return hand.interpolate_with(sup, smoothstep(back_by, back_by + 0.25, u))


## A tube loaded a shell at a time: from the pouch on the left hip to the load port and in, each `shell_time`.
func _shell_hand(sk: Skeleton3D, gun: Transform3D, sup: Transform3D, def: ItemDefinition, st: MotorState, eq: UltraEquipmentVisual) -> Transform3D:
	if st.action != UltraActionLayer.Action.RELOADING:
		_shell_snd = -1
		if _shell_mesh:
			_shell_mesh.visible = false
		return Transform3D()
	var slow := UltraInjury.reload_mult(st, character.damage_profile)
	var start := float(def.stat("reload_start", 0.35)) * slow
	var each := float(def.stat("shell_time", 0.55)) * slow
	var end_t := float(def.stat("reload_end", 0.3)) * slow
	var contact := gun * UltraPoseSampler.marker(eq.held_node, "M_SupportGrip").origin
	var port := sup
	port.origin += gun * UltraPoseSampler.marker(eq.held_node, "M_LoadPort").origin - contact
	var to_sk := sk.global_transform.affine_inverse()
	var pouch := Transform3D(sup.basis, to_sk * (character.visual_root.global_transform * UltraEquipmentVisual.POUCH))
	var fwd := (-gun.basis.z).normalized()
	var t := st.action_t - start
	var target := sup
	var carry := false
	if t < 0.0:
		target = sup.interpolate_with(pouch, smoothstep(0.0, 1.0, st.action_t / maxf(start, 0.01)))
	elif st.mag >= int(def.stat("mag_size", 0)):
		target = port.interpolate_with(sup, smoothstep(0.0, 1.0, fposmod(t, each) / maxf(end_t, 0.01)))
	else:
		var u := fposmod(t, each) / each
		if u < 0.4:
			target = pouch.interpolate_with(port, smoothstep(0.0, 1.0, u / 0.4))
			carry = true
		elif u < 0.75:
			target = port
			target.origin += fwd * 0.035 * smoothstep(0.4, 0.7, u)
			carry = u < 0.68
			var n_shell := int(floor(t / each))
			if u >= 0.5 and n_shell != _shell_snd:
				_shell_snd = n_shell
				var fx := UltraEffects.instance()
				if fx and fx.sfx:
					fx.sfx.play("shotgun_shell", sk.global_transform * port.origin, -4.0, 2.0, 20.0)
		else:
			target = port.interpolate_with(pouch, smoothstep(0.0, 1.0, (u - 0.75) / 0.25))
	if carry:
		if _shell_mesh == null:
			_shell_mesh = MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.0105
			cm.bottom_radius = 0.0105
			cm.height = 0.068
			cm.radial_segments = 10
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.7, 0.1, 0.07)
			cm.material = m
			_shell_mesh.mesh = cm
			_shell_mesh.top_level = true
			character.add_child(_shell_mesh)
		_shell_mesh.visible = true
		var hw := sk.global_transform * target
		_shell_mesh.global_transform = Transform3D(Basis(hw.basis.x.normalized(), PI * 0.5), hw * Vector3(0.0, 0.09, 0.03))
	elif _shell_mesh:
		_shell_mesh.visible = false
	return target


## A gun held out (a pistol): the spine turns toward the aim, then the gun is placed gun-first like a shouldered one -
## the gun hand at `PISTOL_HIP` off the eye along the view (right, up, forward: low and to the right, out in front), the
## barrel from there onto the aim point, level - and the arm brought to it by two-bone IK. (Turning the clip's own
## hold onto the aim kept the pistol where the PST clips have it: up in front of the face - in first person it covered
## the top half of the view, 17-19 deg above the centre.) Without an eye: the arm, then the wrist, turned onto the aim.
func _hold_out(sk: Skeleton3D, pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3) -> void:
	var turn := _barrel_turn(pose[rh] * grip, target_sk)
	var spine_turn := _limit(turn, SPINE_MAX)
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i >= 0:
			_turn_subtree(pose, i, Quaternion.IDENTITY.slerp(spine_turn, float(SPINE_SHARE[n]) * weight), pose[i].origin)
	var neck := _part("Neck")
	if neck >= 0 and _eye_local == Vector3.INF:
		_eye_setup(sk)
	var ua := _part("RightUpperArm")
	var la := _part("RightLowerArm")
	if neck >= 0 and _head_bone >= 0 and ua >= 0 and la >= 0:
		var eye := _eye(sk, pose, neck)
		var d := (target_sk - eye).normalized()
		var right := d.cross(Vector3.UP)
		right = right.normalized() if right.length() > 1e-3 else -_chest_axes(pose, _part("UpperChest")).x
		var up := right.cross(d).normalized()
		var hand_at := eye + right * PISTOL_HIP.x + up * PISTOL_HIP.y + d * PISTOL_HIP.z
		var hand_in_gun := grip.affine_inverse().origin
		var gun := Transform3D(Basis(), hand_at)
		var aim := (target_sk - hand_at).normalized()
		for k in 2:
			var z := -aim
			var x := Vector3.UP.cross(z)
			x = x.normalized() if x.length() > 1e-4 else right
			gun.basis = Basis(x, z.cross(x).normalized(), z)
			gun.origin = hand_at - gun.basis * hand_in_gun
			aim = (target_sk - gun * _muzzle_local.origin).normalized()
		_two_bone(pose, ua, la, rh, gun * grip.affine_inverse(), weight)
		return
	turn = _barrel_turn(pose[rh] * grip, target_sk)
	if ua >= 0:
		_turn_subtree(pose, ua, Quaternion.IDENTITY.slerp(turn, weight), pose[ua].origin)
	for k in 4:
		turn = _barrel_turn(pose[rh] * grip, target_sk)
		if turn.get_angle() < 0.002:
			break
		_turn_subtree(pose, rh, Quaternion.IDENTITY.slerp(turn, weight), pose[rh].origin)


## A shouldered gun (two-handed, with an M_Stock): placed gun first - the stock in the right shoulder's pocket, the
## barrel from there onto the aim point, level (no cant) - and the gun hand brought onto its grip by two-bone IK.
## The spine leans into the aim's pitch (its yaw is the torso twist's); the clip's own hands held ITS rifle across
## the chest, the stock out past the left shoulder.
func _shoulder(sk: Skeleton3D, pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3) -> void:
	var uc := _part("UpperChest")
	var sh := _part("RightUpperArm")
	if uc < 0 or sh < 0:
		_hold_out(sk, pose, rh, grip, target_sk)
		return
	# Lean into the pitch (half of it, up the spine).
	var p0 := _pocket(pose, uc, sh)
	var d0 := (target_sk - p0).normalized()
	var pitch := asin(clampf(d0.y, -1.0, 1.0))
	var lean := Quaternion(_chest_axes(pose, uc).x, pitch * 0.5)
	for n: String in SPINE_SHARE:
		var i := _part(n)
		if i >= 0:
			_turn_subtree(pose, i, Quaternion.IDENTITY.slerp(lean, float(SPINE_SHARE[n]) * weight), pose[i].origin)
	pocket = _pocket(pose, uc, sh)
	# The gun: stock in the pocket, barrel (-Z) onto the aim point from the muzzle (two rounds: the muzzle sits off
	# the line from the pocket).
	var gun := Transform3D(Basis(), pocket)
	var d := (target_sk - pocket).normalized()
	for k in 2:
		var z := -d
		var x := Vector3.UP.cross(z)
		x = x.normalized() if x.length() > 1e-4 else Vector3.RIGHT
		gun.basis = Basis(x, z.cross(x).normalized(), z)
		gun.origin = pocket - gun.basis * _stock_local.origin
		var muzzle := gun * _muzzle_local.origin
		d = (target_sk - muzzle).normalized()
	stock = gun * _stock_local.origin
	_two_bone(pose, sh, _part("RightLowerArm"), rh, gun * grip.affine_inverse(), weight)
	_head_up_at_hip(sk, pose, target_sk)


## At the hip the head is up, off the stock: the rifle clips cant it over the gun (a cheek weld) and the gun sat in the
## middle of the first-person view. The neck rolls back until the eye is HIP_LONG.x left of the stock (<= HIP_ROLL; the
## stock stays in the shoulder - moving the gun out to the right floated it 12-20 cm off the shoulder). In ADS the cheek
## comes back down onto the stock (_aim_down_sights bends from here).
func _head_up_at_hip(sk: Skeleton3D, pose: Array[Transform3D], target_sk: Vector3) -> void:
	var eq := _equipment()
	# (Leaning, the head goes over with the spine - held up and left it fought the lean; _lean_settle puts the eye out.)
	var k := weight * (1.0 - (eq.ads if eq else 0.0)) * (1.0 - smoothstep(0.0, 1.0, absf(lean)))
	var neck := _part("Neck")
	if k <= 0.001 or neck < 0:
		return
	if _eye_local == Vector3.INF:
		_eye_setup(sk)
	if _head_bone < 0:
		return
	var eye := _eye(sk, pose, neck)
	var view_d := (target_sk - eye).normalized()
	var view_r := view_d.cross(Vector3.UP).normalized()
	var need := HIP_LONG.x - (stock - eye).dot(view_r)
	if need <= 0.0:
		_hip_shift = 0.0
		return
	# (Toward an eye that far left, the neck bent straight at it - as ADS bends it to the sights: the clip bows the head
	# forward over the stock, so a roll about the view hardly moved the eye.)
	var j: Vector3 = pose[neck].origin
	var want := eye - view_r * need
	var bend := _limit(_arc((eye - j).normalized(), (want - j).normalized()), HIP_ROLL)
	_turn_subtree(pose, neck, Quaternion.IDENTITY.slerp(bend, k), j)
	hip_gap = Vector2((stock - eye).dot(view_r), (stock - _eye(sk, pose, neck)).dot(view_r))
	if absf(lean) < 0.05:
		_hip_shift = (hip_gap.y - hip_gap.x) / k


var hip_gap := Vector2.ZERO        ## (tests) the stock's offset right of the eye before / after the head came up
var _hip_shift := 0.0              ## how far the head coming up moved the eye left, per unit of its weight (m)


## The right shoulder's pocket (skeleton space): just inside the shoulder joint, a little forward and down - where
## a stock sits.
func _pocket(pose: Array[Transform3D], uc: int, sh: int) -> Vector3:
	var ax := _chest_axes(pose, uc)
	return pose[sh].origin + ax.x * POCKET.x + ax.y * POCKET.y + ax.z * POCKET.z


## The chest's own axes in skeleton space (x = the character's left, y = up, z = forward), from its rest pose.
func _chest_axes(pose: Array[Transform3D], uc: int) -> Basis:
	var rest: Transform3D = ragdoll.parts[uc].rest
	return (pose[uc].basis * rest.basis.inverse()).orthonormalized()


## Aiming down the sights, through the body: the neck brings the eye toward where the held gun's sight line wants it
## (cheek down to the stock, <= NECK_MAX), then the gun goes onto the eye's line - rear sight `fp_ads_distance` in
## front of it, front sight on the aim point - and the gun hand follows by IK. The camera is this eye (MarksmanEye):
## the sights are on the view.
func _aim_down_sights(sk: Skeleton3D, pose: Array[Transform3D], rh: int, grip: Transform3D, target_sk: Vector3, def: ItemDefinition) -> void:
	var neck := _part("Neck")
	if neck < 0 or _eye_local == Vector3.INF:
		_eye_setup(sk)
	if neck < 0 or _head_bone < 0:
		return
	if _sights_for != _muzzle_for:
		_sights_for = _muzzle_for
		_rear_local = UltraPoseSampler.marker(_muzzle_for, "M_RearSight").origin
		_front_local = UltraPoseSampler.marker(_muzzle_for, "M_FrontSight").origin
		if _front_local.is_equal_approx(_rear_local):
			_front_local = _rear_local + Vector3(0, 0, -0.3)
	var dist := def.fp_ads_distance
	var gun_now: Transform3D = pose[rh] * grip
	# Where the held gun wants the eye: on its sight line, `dist` behind the rear sight.
	var line_g := (_front_local - _rear_local).normalized()
	var want_eye := gun_now * (_rear_local - line_g * dist)
	var eye := _eye(sk, pose, neck)
	var j := pose[neck].origin
	var bend := _limit(_arc((eye - j).normalized(), (want_eye - j).normalized()), NECK_MAX)
	_turn_subtree(pose, neck, Quaternion.IDENTITY.slerp(bend, ads * HEAD_SHARE), j)
	eye = _eye(sk, pose, neck)
	ads_eye = eye
	# The gun on the eye's line.
	var d := (target_sk - eye).normalized()
	var z := -d
	var x := Vector3.UP.cross(z)
	x = x.normalized() if x.length() > 1e-4 else Vector3.RIGHT
	var b := Basis(x, z.cross(x).normalized(), z)
	var line_w := b * line_g
	b = Basis(_arc(line_w, d)) * b
	var gun_ads := Transform3D(b, eye + d * dist - b * _rear_local)
	var g := gun_now.interpolate_with(gun_ads, smoothstep(0.0, 1.0, ads))
	_two_bone(pose, _part("RightUpperArm"), _part("RightLowerArm"), rh, g * grip.affine_inverse(), 1.0)


## The eye (skeleton space) on this pose: the neck part x the Head bone's own pose under it x the eye offset.
func _eye(sk: Skeleton3D, pose: Array[Transform3D], neck: int) -> Vector3:
	return (pose[neck] * _neck_to_head(sk)) * _eye_local


func _neck_to_head(sk: Skeleton3D) -> Transform3D:
	var t := Transform3D()
	var b := _head_bone
	while b >= 0 and b != _neck_bone:
		t = sk.get_bone_pose(b) * t
		b = sk.get_bone_parent(b)
	return t


func _eye_setup(sk: Skeleton3D) -> void:
	_head_bone = sk.find_bone("Head")
	_neck_bone = int(ragdoll.parts[_part("Neck")].bone) if _part("Neck") >= 0 else -1
	if _head_bone < 0:
		return
	var off := character.body_profile.eye_offset if character.body_profile else Vector3(0, 0.075, -0.1)
	_eye_local = sk.get_bone_global_rest(_head_bone).basis.orthonormalized().inverse() * Vector3(-off.x, off.y, -off.z)


## The support hand under the fore-end (skeleton space): its fingers along `support_fingers`, palm toward
## `support_palm` (item frame), the palm on M_SupportGrip - as UltraEquipmentVisual._support_under does it.
func _support_under(sk: Skeleton3D, gun: Transform3D, def: ItemDefinition) -> Transform3D:
	if not _learn_palm(sk):
		return Transform3D()
	if _grip_for != _muzzle_for:
		_grip_for = _muzzle_for
		_grip_contact = UltraPoseSampler.marker(_muzzle_for, "M_SupportGrip").origin
	var gb := gun.basis.orthonormalized()
	return _left_hand(gb * def.support_fingers, gb * def.support_palm, gun * _grip_contact, 0.03)


## The left hand's own palm axis (its rest pose, toward the curled fingertips): learnt once. False when it can't be.
func _learn_palm(sk: Skeleton3D) -> bool:
	if _palm_local != Vector3.ZERO:
		return true
	var hb := sk.get_bone_global_rest(sk.find_bone("LeftHand"))
	var tip := Vector3.ZERO
	for f in ["LeftMiddleDistal", "LeftRingDistal", "LeftIndexDistal"]:
		tip += sk.get_bone_global_rest(sk.find_bone(f)).origin / 3.0
	var v := hb.basis.orthonormalized().inverse() * (tip - hb.origin)
	v.y = 0.0
	if v.length() < 0.005:
		return false
	_palm_local = v.normalized()
	return true


## The left hand bone (skeleton space) with its fingers along `fingers`, palm toward `palm`, the palm on `contact`.
## (`_support_under` must have learnt the hand's own palm axis first.)
func _left_hand(fingers: Vector3, palm: Vector3, contact: Vector3, off := 0.03) -> Transform3D:
	var f := fingers.normalized()
	var p := (palm - f * palm.dot(f)).normalized()
	var src := Basis(Vector3.UP.cross(_palm_local), Vector3.UP, _palm_local)
	var b := Basis(f.cross(p), f, p) * src.inverse()
	# (The hand bone sits at the wrist: back along the hand, down off the palm.)
	return Transform3D(b, contact - f * 0.065 - p * off)


## The turn (skeleton space) taking the gun's barrel (-Z) from its muzzle onto `target`.
func _barrel_turn(gun: Transform3D, target: Vector3) -> Quaternion:
	var muzzle := gun * _muzzle_local.origin
	var b := -gun.basis.z.normalized()
	var d := target - muzzle
	if d.length() < 0.05:
		return Quaternion.IDENTITY
	return _arc(b, d.normalized())


func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var c := a.cross(b)
	var dt := clampf(a.dot(b), -1.0, 1.0)
	if c.length() < 1e-6:
		return Quaternion.IDENTITY
	return Quaternion(c.normalized(), acos(dt))


func _limit(q: Quaternion, most: float) -> Quaternion:
	var a := q.get_angle()
	return q if a <= most else Quaternion.IDENTITY.slerp(q, most / a)


## Turns part `top` and everything below it by `q` about `about` (skeleton space).
func _turn_subtree(pose: Array[Transform3D], top: int, q: Quaternion, about: Vector3) -> void:
	var b := Basis(q)
	var xf := Transform3D(b, about - b * about)
	for j: int in _subtree(top):
		pose[j] = xf * pose[j]


## Two-bone IK on the pose: upper / lower / end parts reach `target` (origin; the end takes its basis), keeping the
## bend on the side the pose has it (the elbow's own direction is the pole). Blended by `w`.
func _two_bone(pose: Array[Transform3D], up: int, lo: int, end: int, target: Transform3D, w: float) -> void:
	if up < 0 or lo < 0 or end < 0:
		return
	var A := pose[up].origin
	var B := pose[lo].origin
	var C := pose[end].origin
	var a := A.distance_to(B)
	var b := B.distance_to(C)
	if a < 1e-4 or b < 1e-4:
		return
	var T := C.lerp(target.origin, w)
	var at := T - A
	var c := clampf(at.length(), absf(a - b) + 1e-3, a + b - 1e-3)
	var dir := at.normalized() if at.length() > 1e-5 else (C - A).normalized()
	var pole := (B - A) - dir * (B - A).dot(dir)
	if pole.length() < 1e-4:
		pole = (C - A).cross(Vector3.UP).cross(dir)
	pole = pole.normalized()
	var cos_a := clampf((a * a + c * c - b * b) / (2.0 * a * c), -1.0, 1.0)
	var B2 := A + dir * (a * cos_a) + pole * (a * sqrt(maxf(1.0 - cos_a * cos_a, 0.0)))
	var C2 := A + dir * c
	var q_up := _arc((B - A).normalized(), (B2 - A).normalized())
	pose[up] = Transform3D(Basis(q_up) * pose[up].basis, A)
	var lo_dir := (Basis(q_up) * (C - B)).normalized()
	var q_lo := _arc(lo_dir, (C2 - B2).normalized())
	pose[lo] = Transform3D(Basis(q_lo) * Basis(q_up) * pose[lo].basis, B2)
	var end_b := Basis(q_lo) * Basis(q_up) * pose[end].basis
	pose[end] = Transform3D(end_b.orthonormalized().slerp(target.basis.orthonormalized(), w), C2)
