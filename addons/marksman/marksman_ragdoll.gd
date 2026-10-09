class_name MarksmanRagdoll
extends SinewRagdoll
## Marksman's body: Sinew's ragdoll + gait, walking on the stance the character is in - one group of
## reference cycles per stance and posture (MarksmanStanceSet.groups: unarmed / rifle / pistol, standing /
## crouched), switched as a gun is drawn or put away and on crouching. Prone is the clips' (crawling isn't a
## biped's gait).

## The gait group walking now (an index into MarksmanStanceSet.groups; -1 before the gait is set up).
var group := -1
## Seconds a stance change cross-fades the gait's pose over.
@export var stance_blend := 0.35


## The gun pass over the animated pose (aim, support hand): see MarksmanGunPass.
var gun_pass: MarksmanGunPass
## The legs on a swing rope (MarksmanRopePass).
var rope_pass: MarksmanRopePass
## The hands on a ledge while hanging (MarksmanLedgePass).
var ledge_pass: MarksmanLedgePass


func setup(c: UltraCharacter) -> void:
	super.setup(c)
	stagger_max_time = 2.0           # (Sinew's 3 s: a stagger nobody steps out of still lets go sooner)
	if modifier != null and not parts.is_empty():
		gun_pass = MarksmanGunPass.new(c, self)
		modifier.passes.append(gun_pass)
		modifier.post_passes.append(gun_pass)
		rope_pass = MarksmanRopePass.new(c, self)
		modifier.passes.append(rope_pass)
		ledge_pass = MarksmanLedgePass.new(c, self)
		modifier.passes.append(ledge_pass)


func _setup_gait() -> void:
	_gait_on = false
	_gait_running = false
	gait_w = 0.0
	group = -1
	var aset := character.anim.anim_set as MarksmanStanceSet if character.anim else null
	if aset == null or aset.groups.is_empty():
		super._setup_gait()          # (no stances: Sinew's own cycles)
		return
	if not gait or character.anim.skeleton == null:
		return
	world.physics.call("character_gait_enable", _id, true, gait_settings)
	var cycles := []
	for gi in aset.groups.size():
		var g: Dictionary = aset.groups[gi]
		var built := SinewGaitCycles.build_group(character.anim, parts, g.get("cycles", []), g.get("upper_from", {}), gi, g.get("arms_from", {}))
		for c in built:
			# (Crouched, the feet roll onto their balls through the stance.)
			c["rolling_stance"] = g.get("posture", "") == "crouch"
		cycles.append_array(built)
		var idle := SinewGaitCycles.idle_pose(character.anim, parts, StringName(g.get("idle", "idle")))
		if not idle.is_empty():
			world.physics.call("character_gait_set_idle", _id, idle.locals, idle.pelvis_height, gi)
	world.physics.call("character_gait_set_cycles", _id, cycles)
	gait_part_w.resize(parts.size())
	gait_part_w.fill(1.0)
	_gait_on = true
	_sync_group(0.0)


## The stance group the character's state asks for (-1: none - prone, or no stance set).
func wanted_group() -> int:
	var aset := character.anim.anim_set as MarksmanStanceSet if character.anim else null
	if aset == null:
		return -1
	var posture := MarksmanStance.posture(character)
	if posture == "prone":
		posture = "crouch"           # (the gait isn't walking; keep the nearest stance's legs ready)
	# (The held item's stance, not the shown one (MarksmanDraw): switched mid-stride as the hand took the gun, the gait's
	# group moved the hips 3.3 cm in a tick - at the draw's start it's where it always was, 1.9.)
	var gi := aset.group_index(MarksmanStance.of_item(character.held_def()), posture)
	if gi < 0:
		gi = aset.group_index("unarmed", posture)
	return maxi(gi, 0)


func _sync_group(blend: float) -> void:
	var want := wanted_group()
	if want >= 0 and want != group and _gait_on and world.physics.has_method("character_gait_set_group"):
		world.physics.call("character_gait_set_group", _id, want, blend)
		group = want


## Standing on the ground (the motion matcher's states).
const GROUND_STATES := [MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.TURN_IN_PLACE, MotorState.Id.LAND]


func _gait_states() -> Array:
	# (Motion matching has the legs in whatever stance and posture it has clips for - unless a stumble handed them to the
	# gait's catching steps.)
	var all := super._gait_states() + [MotorState.Id.CROUCH]
	var drv := character.anim as MarksmanAnimDriver if character else null
	if _stumble or drv == null or drv.mm == null:
		return all
	var st := MarksmanStance.of(character)
	var out := []
	for s in all:
		var crouched: bool = s == MotorState.Id.CROUCH
		if not drv.mm.has_stance(st + "_crouch" if crouched else st):
			out.append(s)
	return out


## Motion matching walks the stance and posture the character is in (the gait stands by for stumbles).
func mm_legs() -> bool:
	var drv := character.anim as MarksmanAnimDriver if character else null
	return drv != null and drv.mm != null and drv.mm.has_stance(MarksmanMotionMatcher.key_for(character))


# ------------------------------------------------------------------ stumbles under motion matching
# Motion matching moves the legs the player asks for; what happens TO the body is Sinew's. A push hands the legs to
# the gait's catching steps (its capture footholds, physical motion, the trip rule - SinewCharacter.receive_push) on
# the feet as they stand; once caught - the stumble's time out, no step pending, the body near the motion asked for -
# the gait's weight fades and the matcher has them again. (Staggers and ball hits are the balancer's, with or
# without matching: the matcher's pass stands aside while physics has the legs.)

const STUMBLE_SETTLE := 0.25      ## s caught before the matcher takes the legs back
var _stumble := false
var _settled_t := 0.0


## A push landed: the gait starts now, on the feet as they stand (its first update seats them on the shown ones).
func stumble_start() -> void:
	if not _gait_on:
		return
	_stumble = true
	_settled_t = 0.0
	if not _gait_running:
		world.physics.call("character_gait_reset", _id, _gait_root())
		gait_now = []
		_gait_running = true


func stumbling_gait() -> bool:
	return _stumble


func _update_gait(dt: float) -> void:
	_sync_group(stance_blend)
	if _stumble:
		var c := character as SinewCharacter
		var st := character.state
		var gs: Dictionary = world.physics.call("character_gait_state", _id) if _gait_running else {}
		var cmd: Variant = c.motion_command if c else null
		var want_v: Vector3 = cmd if cmd is Vector3 else Vector3.ZERO
		var off := Vector2(st.vel.x - want_v.x, st.vel.z - want_v.z).length()
		var caught := not c.stumbling() and not bool(gs.get("stepping", false)) and off < 0.35
		# (Down, dead, in the air, crouched...: the stumble is over either way.)
		if not st.is_grounded() or st.state not in GROUND_STATES:
			caught = true
			_settled_t = STUMBLE_SETTLE
		_settled_t = _settled_t + dt if caught else 0.0
		if _settled_t >= STUMBLE_SETTLE:
			_stumble = false
	super._update_gait(dt)


## The stance cycles hold the gun the way the stance does (the rifle pack's arms carry the rifle): an item of
## the current stance doesn't take the upper body off the gait - only a carried prop or a one-shot does.
func _gait_upper_weight(busy: bool, speed: float) -> float:
	var st := character.state
	var drv := character.anim as SinewAnimDriver
	# (The held item's own stance, not the shown one: drawing a gun shows unarmed until the hand has it.)
	var item_busy := st.held_uid != 0 and MarksmanStance.of_item(character.held_def()) == "unarmed"
	var really := item_busy or st.held_id != 0 or (drv != null and drv.upper_busy())
	return super._gait_upper_weight(really, speed)


## The body went over an edge (MarksmanCharacter.simulate): the whole body physical now, the balancer on - it lands
## on whatever is below and either catches itself or goes down.
##
## Losing the footing, the body goes INTO the drop: it tips over the edge the way it went off (`dir`, flat) - the upper
## body more than the feet, so it pitches over the lip rather than dropping straight down beside it.
func over_edge(dir := Vector3.ZERO) -> void:
	if _id == 0 or active or not _powered_on or _stagger_t >= 0.0:
		return
	start_stagger()
	_over_edge = _stagger_t >= 0.0
	_standing_target()
	if _over_edge and dir.length() > 1e-3:
		world.physics.call("character_add_velocity", _id, dir.normalized() * over_edge_tip, 0.4, 1.0)


## m/s the upper body tips into a drop it lost its footing on (the pelvis 40 % of it).
@export var over_edge_tip := 1.1


var _over_edge := false


## Taken over in the air: the balancer's upright target and standing height are the body's on its feet - left to
## itself it measured them in the air (the centre of mass 1.9 m over the ground below), and any landing then "sank" under
## 60 % of that and went down.
func _standing_target() -> void:
	if _stagger_t < 0.0:
		return
	var anim := _anim_world()
	if anim.is_empty():
		return
	var p: Transform3D = anim[0]
	var h := maxf(p.origin.y - character.state.pos.y, 0.8) + 0.05
	world.physics.call("character_balance_set_target", _id, p.basis.orthonormalized().get_rotation_quaternion(), h)


## Going over an edge, the body stays powered in the air (the balancer has it until it lands and settles or falls).
func _powered_in_air() -> bool:
	if _over_edge and _stagger_t < 0.0:
		_over_edge = false
	return _over_edge or _catch_t >= 0.0 or _powered_in_air_for_landing()


## A hard landing is coming (MarksmanCharacter._predict_landing, a moment before touchdown at `speed` m/s down): the
## body is powered in the air and meets the ground with its own momentum. The legs land on the animation (the reach,
## then the squat as deep as the impact) while the upper body is physical - the torso, head and arms carry on down
## into the stop and the muscles catch them (slackened by how hard it was). Only a really hard one
## (`land_stagger_speed`) hands the legs to the balancer too: it catches itself or goes down. Asked each tick until on.
func land_brace(speed: float) -> void:
	if _id == 0 or active or not powered or _stagger_t >= 0.0 or _land_air:
		return
	_land_brace = true
	_brace_speed = speed


## Landing at least this hard (m/s down; ~4 m dropped) the legs are physical too - the balancer's.
@export var land_stagger_speed := 11.5
## The upper body's tone into the catch: a landing at the brace speed .. at the stagger speed.
@export var land_tone := Vector2(0.75, 0.4)
## Seconds the upper body stays physical after a landing.
@export var land_window := 0.8

var _land_brace := false
var _brace_speed := 0.0
var _land_air := false          ## powered in the air for a landing (till it's down)
var _land_floor := -1.0         ## the torso's slackened tone while the landing's relax runs (-1: none)


func _powered_in_air_for_landing() -> bool:
	if _land_air and character.state.is_grounded():
		_land_air = false
	return _land_air or _land_brace


# ------------------------------------------------------------------ the stick ends a stagger

## A stagger the body has come through ends when the player wants to go (the user: "after falling and running sometimes
## Sinew stays active too long and you need to stand still to stop it"): Sinew hands back only once the body is steady
## - no step, the COM still - or after stagger_max_time, and a body asked to run is never still. After `stagger_min`
## s, the stick held `stagger_wish_time` s on a body that hasn't fallen hands the legs back to the animation (the hand-back
## glide); the balancer's own end rules stay for everything else.
@export var stagger_min := 0.45
@export var stagger_wish_time := 0.2
var _stagger_wish := 0.0


func _update_stagger(dt: float, anim: Array) -> void:
	super._update_stagger(dt, anim)
	if _stagger_t < 0.0:
		_stagger_wish = 0.0
		return
	# (On the ground only: over an edge the stagger IS the fall, the stick doesn't end that.)
	var wish := character.last_input.move.length() > 0.5 and character.state.is_grounded() if character and character.last_input else false
	_stagger_wish = _stagger_wish + dt if wish else 0.0
	if _stagger_t < stagger_min or _stagger_wish < stagger_wish_time:
		return
	var st: Dictionary = balance_state()
	if st.is_empty() or bool(st.fallen):
		return
	_end_stagger(true)
	stagger_ended_by_stick += 1


## Staggers the stick ended (tests).
var stagger_ended_by_stick := 0


func sinew_pre_step(dt: float) -> void:
	_track_hips(dt)
	# (Down on the ground the landing's air mode is over: Sinew only asks _powered_in_air while airborne, so the flag
	# outlived the landing and powered the body in the air through every later jump.)
	if _land_air and character and character.state.is_grounded():
		_land_air = false
	var caught := _catch_begin()
	_update_catch(dt)
	var bracing := _land_brace and not active
	super.sinew_pre_step(dt)
	_buoy(dt)
	if caught:
		_catch_start()
	if _catch_t >= 0.0 and _dyn.size() == parts.size():
		for i in parts.size():           # (Sinew eases the upper parts in its own time: the catch fades them all)
			if not _walks(i):
				part_w[i] = minf(part_w[i], _catch_w)
	if character:
		_prev_motor = character.state.state
		_prev_vel = character.state.vel
	if not bracing:
		_land_brace = false
		return
	_land_brace = false
	if not _powered_on or _stagger_t >= 0.0:
		return
	# (Powered on mid-air just now: no 0.25 s snap onto the animation - the tree has long been posing; the body takes
	# the fall's own velocity.)
	var anim := _anim_world()
	if not anim.is_empty():
		world.physics.call("character_set_pose", _id, anim, character.state.vel)
	_powered_t = maxf(_powered_t, 0.25)
	_land_air = true
	landed_braced += 1
	if stagger and _brace_speed >= land_stagger_speed:
		start_stagger()
		_over_edge = _stagger_t >= 0.0
		_standing_target()
		return
	var k := smoothstep(0.0, 1.0, inverse_lerp(7.0, land_stagger_speed, _brace_speed))
	var spine := _part("Spine")
	for i in parts.size():
		if not _walks(i) and bool(world.physics.call("character_attached", _id, i)):
			_hit_t[i] = land_window
			_set_dyn(i, true)
			part_w[i] = 1.0
	if spine >= 0:
		_land_floor = lerpf(land_tone.x, land_tone.y, k)
		_hit_relax[spine] = 0.0
		for i in _relaxed(spine):
			world.physics.call("character_set_part_tone", _id, i, _land_floor)


## Landings the body took (tests).
var landed_braced := 0


# ------------------------------------------------------------------ catching a ledge

## Catching a ledge out of a jump or a fall the hands HOLD and the rest of the body is physics for `catch_window` s (the
## user: "grab the ledge and have the rest of the body react for a moment"): it carries the jump's momentum on - swings
## in under the hands, the feet meet the wall, a drop sags on the shoulders - and its slackened muscles bring it back to
## the hang clip. The WHOLE body is physical and each hand is pinned where the ledge pass put it by a ball joint to a
## shapeless kinematic anchor that follows the animated hand (the ledge pass easing it onto the lip; removed after). Kinematic arms tore the body in half: Sinew projects every joint back onto
## its parent from the pelvis down after each step, so a physical trunk under animated arms dragged the arms off the
## shoulders (the upper arm drew 21 cm off). Presentation: the capsule hangs where the motor put it. Shimmying or
## climbing hands it back sooner.
@export var catch_window := 0.9
## Seconds the physics picture fades back to the animation (at the window's end / when the hang is left: quicker).
@export var catch_fade := Vector2(0.35, 0.15)
## The trunk's and legs' tone at the catch (back to 1 over the window); the arms keep `catch_arm_tone`.
@export var catch_tone := 0.45
@export var catch_arm_tone := 0.8
## The momentum the body brings into the catch (share of the jump's velocity: the arms take some of it at the grip).
@export var catch_momentum := 0.85
const CATCH_FROM := [MotorState.Id.JUMP, MotorState.Id.FALL]
const CATCH_HANDS := ["LeftHand", "RightHand"]
var _catch_t := -1.0                 ## seconds since the catch (-1: none)
var _catch_w := 0.0                  ## the physics picture's share
var _catch_left := false             ## the hang was left / moved (fading quickly)
var _anchors: Array[int] = []        ## the hands' pin bodies (kinematic, each with its ball joint)
var _anchor_part: Array[int] = []    ## the hand part each anchor holds
var _catch_pending := -1             ## process frame a catch was seen on, waiting for the hang to be drawn (-1: none)
var _catch_vel := Vector3.ZERO       ## the body's velocity coming into the catch
var _catch_fresh := false            ## the catch's first step: the drawn history starts there
var _prev_motor := -1
var _prev_vel := Vector3.ZERO
## Catches the body swung through (tests).
var caught_swinging := 0


func catching() -> bool:
	return _catch_t >= 0.0


func _catch_begin() -> bool:
	if character == null or _id == 0 or active or not powered or _stagger_t >= 0.0 or _catch_t >= 0.0:
		_catch_pending = -1
		return false
	var st := character.state
	var frame := Engine.get_process_frames()
	if _catch_pending < 0:
		if st.state == MotorState.Id.LEDGE_HANG and _prev_motor in CATCH_FROM:
			# (Not yet: this tick the motor snapped the capsule onto the ledge, the animated pose is still the jump's -
			# started from it, the anchors had to jump 1.5 m to the hands. The catch starts from the first pose drawn
			# on the ledge.)
			_catch_pending = frame
			_catch_vel = _prev_vel
		return false
	if st.state != MotorState.Id.LEDGE_HANG or frame - _catch_pending > 10:
		_catch_pending = -1
		return false
	if ledge_pass == null or ledge_pass.applied_frame <= _catch_pending:
		return false
	_catch_pending = -1
	_catch_t = 0.0
	_catch_w = 1.0
	_catch_left = false
	return true


func _update_catch(dt: float) -> void:
	if _catch_t < 0.0:
		return
	_catch_t += dt
	var st := character.state
	# (Knocked off / staggered: let go at once - pinned, a ragdoll would hang on the wall.)
	if active or _stagger_t >= 0.0 or _id == 0:
		_catch_w = 0.0
	var drv := character.anim as UltraAnimDriver
	if st.state != MotorState.Id.LEDGE_HANG or (drv != null and drv._cur_loco == "hang" and absf(drv.climb_speed) > 0.05):
		_catch_left = true
	if _catch_left:
		_catch_w = maxf(_catch_w - dt / catch_fade.y, 0.0)
	elif _catch_t > catch_window:
		_catch_w = maxf(_catch_w - dt / catch_fade.x, 0.0)
	if _catch_w <= 0.0:
		_end_catch()
		return
	# The hands go where the animation has them (the ledge pass easing them onto the lip): the body hangs from them.
	var anim := _anim_world()
	if not anim.is_empty():
		for k in _anchors.size():
			world.physics.call("move_kinematic", _anchors[k], anim[_anchor_part[k]], dt)
	var tone := lerpf(catch_tone, 1.0, smoothstep(0.15, catch_window, _catch_t))
	for i in parts.size():
		if bool(world.physics.call("character_attached", _id, i)):
			world.physics.call("character_set_part_tone", _id, i, catch_arm_tone if _arm_part(i) else tone)


## The catch's first tick: no drawing between the last pose (the body following the jump, 1.5 m below the snapped
## capsule) and this one - a frame of the hands half way up.
func sinew_post_step(dt: float) -> void:
	super.sinew_post_step(dt)
	if _catch_fresh:
		_catch_fresh = false
		pose_prev = pose_now


func _exit_tree() -> void:
	_drop_anchors()
	super._exit_tree()


func _end_catch() -> void:
	_catch_t = -1.0
	_catch_w = 0.0
	_drop_anchors()
	if _id == 0:
		return
	for i in parts.size():
		if bool(world.physics.call("character_attached", _id, i)):
			world.physics.call("character_set_part_tone", _id, i, 1.0)


func _drop_anchors() -> void:
	for a in _anchors:
		if world and world.physics:
			world.physics.call("remove_body", a)      # (its joint goes with it)
	_anchors.clear()
	_anchor_part.clear()


func _arm_part(i: int) -> bool:
	return String(parts[i].name) in ARM_PARTS


## Just caught (powered on this tick, on the animated pose): every part physical with the jump's momentum, the hands
## pinned to anchors that follow the animated hands.
func _catch_start() -> void:
	if not _powered_on:
		_catch_t = -1.0
		return
	var anim := _anim_world()
	if anim.is_empty():
		_catch_t = -1.0
		return
	world.physics.call("character_set_pose", _id, anim, _catch_vel * catch_momentum)
	_powered_t = maxf(_powered_t, 0.25)
	modifier.blend = powered_blend     # (the physics is the animated pose this tick: shown at once, no 0.3 s fade-in)
	_catch_fresh = true
	for i in parts.size():
		if bool(world.physics.call("character_attached", _id, i)):
			_set_dyn(i, true)
			part_w[i] = 1.0
			world.physics.call("character_set_part_tone", _id, i, catch_arm_tone if _arm_part(i) else catch_tone)
	_drop_anchors()
	for hn: String in CATCH_HANDS:
		var h := _part(hn)
		if h < 0 or not bool(world.physics.call("character_attached", _id, h)):
			continue
		var body: int = world.physics.call("character_body", _id, h)
		var xf: Transform3D = anim[h]
		var anchor: int = world.physics.call("add_body", 1, xf)
		world.physics.call("add_ball_joint", anchor, body, Transform3D(), Transform3D(), 0.0, 0.0, 0.0)
		_anchors.append(anchor)
		_anchor_part.append(h)
	caught_swinging += 1


func _legs_physics_weight(i: int) -> float:
	if _catch_t < 0.0 or not bool(world.physics.call("character_attached", _id, i)):
		return -1.0
	return _catch_w


# ------------------------------------------------------------------ hits are felt

## Region groups for hits.
const LEG_REGIONS := [UltraLimbs.Region.THIGH_L, UltraLimbs.Region.SHIN_L, UltraLimbs.Region.FOOT_L,
		UltraLimbs.Region.THIGH_R, UltraLimbs.Region.SHIN_R, UltraLimbs.Region.FOOT_R]
const ARM_REGIONS := [UltraLimbs.Region.ARM_L, UltraLimbs.Region.FOREARM_L, UltraLimbs.Region.HAND_L,
		UltraLimbs.Region.ARM_R, UltraLimbs.Region.FOREARM_R, UltraLimbs.Region.HAND_R]
## A leg hit this hard (N s) is taken IN the leg: the legs go physical (the balancer has them), the struck leg is
## knocked and goes weak - whether the body catches itself on the other foot or goes down is the simulation's.
@export var leg_stagger_min_impulse := 6.0
## How weak a struck leg goes (tone) and for how long it takes to come back (s): harder hits, weaker and longer.
@export var leg_weak_tone := Vector2(0.7, 0.15)      ## at leg_stagger_min_impulse .. hit_impulse_max
@export var leg_weak_time := Vector2(0.5, 1.2)
## A body / leg hit too light to stagger is still felt: a shove of this many m/s per N s into the feet (the gait's
## catching steps under physical motion - SinewCharacter.receive_push; with motion matching, the hand-over).
@export var hit_push_per_impulse := 0.06
const HIT_PUSH_MIN := 0.12          ## m/s below which a hit is only the upper body's flinch

var _leg_weak := {}                  ## part -> [floor tone, seconds]


func hit(region: int, dir: Vector3, amount: float) -> void:
	# (Armed, an arm hit is the gun pass's kick - MarksmanGunPass.arm_hit: an arm switched to physics sags ~free fall
	# before its muscles take it, 23 cm in 0.18 s whatever the push, and keeps a wrist error while physical.)
	if armed_hold() and region in ARM_REGIONS:
		gun_pass.arm_hit(region, dir, amount)
	elif armed_hold():
		gun_pass.body_hit()
	var imp := minf(amount * hit_impulse_per_damage, hit_impulse_max)
	var c := character as SinewCharacter
	var hv := Vector3(character.state.vel.x, 0.0, character.state.vel.z)
	if stagger and _powered_on and not active and _stagger_t < 0.0 and character.state.is_grounded() \
			and not region in ARM_REGIONS and hv.length() > moving_hit_speed and c != null \
			and (region in LEG_REGIONS or imp >= stagger_min_impulse) and _stumble_hit(region, dir, imp, hv):
		var keep := stagger
		stagger = false                  # (the flinch and the struck part's slack, no standing stagger)
		super.hit(region, dir, amount)
		stagger = keep
		return
	if stagger and _powered_on and not active and _stagger_t < 0.0 and character.state.is_grounded() \
			and not region in ARM_REGIONS:
		if region in LEG_REGIONS and imp >= leg_stagger_min_impulse and _part_of_region.has(region):
			# (Legs physical FIRST: the base hit then strikes and weakens the leg itself instead of rocking the spine.)
			var k := clampf((imp - leg_stagger_min_impulse) / maxf(hit_impulse_max - leg_stagger_min_impulse, 1e-3), 0.0, 1.0)
			_leg_weak[int(_part_of_region[region])] = [lerpf(leg_weak_tone.x, leg_weak_tone.y, k), lerpf(leg_weak_time.x, leg_weak_time.y, k)]
			start_stagger()
		elif imp < stagger_min_impulse and c != null:
			var h := Vector3(dir.x, 0.0, dir.z)
			var dv := imp * hit_push_per_impulse
			if h.length() > 1e-3 and dv >= HIT_PUSH_MIN:
				c.receive_push(h.normalized() * dv)
	super.hit(region, dir, amount)


## Moving faster than this (m/s), a leg hit or a blow that would stagger a standing body is a stumble on the move.
@export var moving_hit_speed := 0.8
## The stumble: m/s of lurch along the way it's going per N s of hit (a leg knocked from under a moving body - it
## pitches on over the other one), plus this share of it along the hit; at most `moving_hit_max`.
@export var moving_hit_per_impulse := 0.12
@export var moving_hit_along := 0.5
@export var moving_hit_max := 1.6
## A leg hit while that leg swings (not carrying the weight) throws the body this share as much.
@export var moving_hit_swinging := 0.4


## A hit on a moving body (MarksmanRagdoll.hit): the stagger goes the way it's going. The struck leg is weakened as
## for a standing body, and the feet are handed to the gait's catching steps with the body's momentum and a lurch
## along it (SinewCharacter.receive_push): it stumbles on, catches itself in a few steps, or trips if the steps can't
## keep up (the gait's capture margin - the simulation decides, harder hits and higher speeds more often). Standing
## still the balancer has it (a stagger on the spot). False if the push couldn't be taken (then: the standing way).
func _stumble_hit(region: int, dir: Vector3, imp: float, hv: Vector3) -> bool:
	var c := character as SinewCharacter
	var h := Vector3(dir.x, 0.0, dir.z)
	h = h.normalized() if h.length() > 1e-3 else Vector3.ZERO
	var leg := region in LEG_REGIONS
	# (It matters which leg: the one carrying the weight buckles and the body pitches over it; one in the air swings
	# on and lands short.)
	var bearing := 1.0
	if leg:
		var drv := character.anim as MarksmanAnimDriver
		var side := 0 if region in [UltraLimbs.Region.THIGH_L, UltraLimbs.Region.SHIN_L, UltraLimbs.Region.FOOT_L] else 1
		if drv != null and drv.mm != null and drv._cur_loco == "mm" and not drv.mm.planted(side):
			bearing = moving_hit_swinging
	# (A lurch, not a launch: the body already carries its momentum - a faster one trips more easily through the gait's
	# capture margin, it isn't thrown harder. Scaled by speed it sped a sprinter up 4.5 m/s and the knock-down doubled
	# that: flung at 15-21 m/s.)
	var dv := minf(imp * moving_hit_per_impulse * (1.0 if leg else 0.7) * bearing, moving_hit_max)
	var fwd := hv.normalized()
	var push := fwd * dv + (h - fwd * h.dot(fwd)) * dv * moving_hit_along
	_quiet_push = true                 # (the shot already struck the part: no chest jolt for the push on top)
	var took := c.receive_push(push)
	_quiet_push = false
	if not took:
		return false
	if c is MarksmanCharacter:
		var sev := clampf(imp / maxf(hit_impulse_max, 1e-3), 0.0, 1.0) * bearing
		(c as MarksmanCharacter).moving_stumble = sev
	if leg and _part_of_region.has(region):
		var k := clampf((imp - leg_stagger_min_impulse) / maxf(hit_impulse_max - leg_stagger_min_impulse, 1e-3), 0.0, 1.0)
		_leg_weak[int(_part_of_region[region])] = [lerpf(leg_weak_tone.x, leg_weak_tone.y, k), lerpf(leg_weak_time.x, leg_weak_time.y, k)]
	moving_hits += 1
	return true


## Hits taken on the move as stumbles (tests).
var moving_hits := 0
var _quiet_push := false


func jolt(dir: Vector3, impulse: float) -> void:
	if not _quiet_push:
		super.jolt(dir, impulse)


## Knocked down while powered: the body is already moving with the character (its kinematic legs and tracked upper body
## carry the run), and Sinew adds the push ON TOP - a sprinter's 6 m/s went in twice. Only what the body doesn't already
## have is added: along the way it's going, the excess; across it, the push as is.
func start() -> void:
	if _catch_t >= 0.0:
		_end_catch()             # (knocked off a ledge mid-catch: the hands let go)
	var st := character.state if character else null
	if st == null or not _powered_on or active or _hips_v == Vector3.INF or modifier == null or modifier.blend < 0.99:
		super.start()
		return
	var keep := st.vel
	var have := Vector3(_hips_v.x, 0.0, _hips_v.z)
	var flat := Vector3(keep.x, 0.0, keep.z)
	var extra := flat
	if have.length() > 0.3:
		var along := have.normalized()
		extra = flat - along * clampf(flat.dot(along), 0.0, have.length())
	st.vel = Vector3(extra.x, keep.y, extra.z)
	super.start()
	st.vel = keep


var _hips_v := Vector3.INF
var _hips_last := Vector3.INF


func _track_hips(dt: float) -> void:
	if pose_now.is_empty() or dt <= 0.0:
		return
	var h := (pose_now[0] as Transform3D).origin
	_hips_v = (h - _hips_last) / dt if _hips_last != Vector3.INF else Vector3.INF
	_hips_last = h


## Armed, whatever holds the gun stays the animation's (V5): a hit to the body or the head makes only the spine / neck /
## head physical - the arms ride on the chest as it rocks (MarksmanGunPass.apply_post) - and an arm hit is a kick of the
## gun (gun arm) or of the support hand off it (MarksmanGunPass.arm_hit), never a physical arm (at Sinew's arm slack the
## gun dropped 66-87 deg and stayed there; a firm physical arm still sagged 23 cm on switching).
const ARM_PARTS := ["LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]


func armed_hold() -> bool:
	return gun_pass != null and gun_pass.weight > 0.5


## A stagger takes the whole body at once (Sinew sets every part physical); the arms holding a gun stay the animation's
## from the first tick - eased back by the hook they flailed for 0.3 s and the support hand flew 10 cm off the grip.
func start_stagger() -> void:
	super.start_stagger()
	if not armed_hold():
		return
	for i in parts.size():
		if String(parts[i].name) in ARM_PARTS and not _limp_arm(i):
			part_w[i] = 0.0


func _part_wants_physics(i: int, want: bool) -> bool:
	if _limp_arm(i):
		return true
	if _catch_t >= 0.0:
		return _catch_w > 0.0
	var drv := character.anim as UltraAnimDriver if character else null
	if want and drv and drv.prone_transitioning() and _stagger_t < 0.0:
		return false           # (getting down to prone / up: the clip, not a physical upper body sagging over it)
	if want and armed_hold() and String(parts[i].name) in ARM_PARTS:
		return false
	# (Drawing / putting away: the hand goes where the item is - a physical arm trailed the quick pistol draw 10 cm short.)
	# The arm comes back to the animation quickly too (Sinew eases it over 0.3 s: the pistol's reach lasts 0.16 s).
	if character and MarksmanDraw.active(character.state, character.held_def()) and String(parts[i].name) in ARM_PARTS:
		part_w[i] = maxf(part_w[i] - DRAW_FADE, 0.0)
		return false
	return want


## V6: an arm that's out (crippled, or what's left of it once severed) hangs: physical in every state at LIMP_TONE.
## The shoulder stays the animation's (the clavicle carries the chest's motion).
const LIMP_TONE := 0.08
## Drawing / putting away, a physical arm's picture goes back to the animation this much a tick (on top of Sinew's own).
const DRAW_FADE := 0.2
const LIMP_PARTS := ["UpperArm", "LowerArm", "Hand"]
var _limp: Dictionary = {}           ## part -> true while held limp (its tone restored when the arm heals)


func _limp_arm(i: int) -> bool:
	var n := String(parts[i].name)
	var left := n.begins_with("Left")
	if not left and not n.begins_with("Right"):
		return false
	if not n.trim_prefix("Left" if left else "Right") in LIMP_PARTS:
		return false
	return character != null and UltraLimbs.arm(character.state, left) >= UltraLimbs.Status.CRIPPLED


func _hold_limp() -> void:
	for i in parts.size():
		var on := _limp_arm(i)
		if on:
			world.physics.call("character_set_part_tone", _id, i, LIMP_TONE)
			_limp[i] = true
		elif _limp.has(i):
			_limp.erase(i)
			world.physics.call("character_set_part_tone", _id, i, 1.0)


func _hit_chain(part: int) -> Array:
	var chain := super._hit_chain(part)
	chain = chain.filter(func(i: int) -> bool: return not _limp_arm(i))
	if not armed_hold():
		return chain
	return chain.filter(func(i: int) -> bool: return not String(parts[i].name) in ARM_PARTS)


func _relax_floor(part: int) -> float:
	if _land_floor >= 0.0 and part == _part("Spine"):
		if _hit_relax.has(part):
			return _land_floor
		_land_floor = -1.0
	if _leg_weak.has(part):
		return float(_leg_weak[part][0])
	return super._relax_floor(part)


## A struck leg comes back over its own (longer) time; everything else as Sinew's (the leg is kept out of its pass).
func _relax_hit_limbs(dt: float) -> void:
	var held := {}
	for part: int in _leg_weak.keys():
		if not _hit_relax.has(part):
			_leg_weak.erase(part)
			continue
		var w: Array = _leg_weak[part]
		var t: float = _hit_relax[part] + dt
		_hit_relax.erase(part)
		for i in _relaxed(part):
			world.physics.call("character_set_part_tone", _id, i, lerpf(float(w[0]), 1.0, smoothstep(0.0, 1.0, t / float(w[1]))))
		if t >= float(w[1]):
			_leg_weak.erase(part)
		else:
			held[part] = t
	super._relax_hit_limbs(dt)
	for part: int in held:
		_hit_relax[part] = held[part]
	_hold_limp()


# ------------------------------------------------------------------ getting up: the clip for how the body lies

## Get-up clips by how the body lies: [clip, rise segment from .. to (s), the head's heading in the clip at `from`
## (deg, model space)]. Only clips that rise from the pose they start in and end facing ahead: GetUp_Back / GetUp_Stomach
## end turned 50-57 deg (a snap at the end), ZN_ZombieStandUp rolls over from its back onto its front on the way up.
const GETUPS := {
	"up": [["LayToIdle", 0.0, 1.5, -180.0]],
	"down": [["mixamo/GetUp_Prone", 1.4, 5.3, -13.0], ["mixamo/StandUp_Stomach", 3.0, 8.2, 1.0]],
}
## The get-up picked for this knock-down: {clip, from, to} (MarksmanAnimDriver plays that segment).
var getup_variant := {}
var _getups := 0


## Face up or down by where the BELLY points (the pelvis and the chest together; a body on its side goes the way it's
## nearer to - the chest alone at -0.2 sent a body lying on its side face down into the face-up clip, and it rolled
## over onto its back to get up). Then one of that way's clips, the yaw set by its own lying heading.
func _decide_getup() -> void:
	super._decide_getup()
	var chest := _part("Chest")
	var head := _part("Neck")
	if chest < 0 or head < 0 or pose_now.is_empty():
		getup_variant = {}
		return
	var belly := Vector3.ZERO
	for i: int in [0, chest]:
		var rest: Transform3D = parts[i].rest
		belly += pose_now[i].basis * (rest.basis.orthonormalized().inverse() * Vector3(0, 0, 1))
	var front := belly.y < 0.0
	if front != getup_front:
		getup_front = front
		var h := pose_now[head].origin - pose_now[0].origin
		h.y = 0.0
		getup_yaw = (atan2(-h.x, -h.z) if front else atan2(h.x, h.z)) if h.length() > 0.05 else NAN
	var list: Array = GETUPS["down" if front else "up"]
	_getups += 1
	var pick: Array = list[posmod(hash(Vector2i(character.net_id, _getups)), list.size())]
	getup_variant = {"clip": pick[0], "from": pick[1], "to": pick[2]}
	if not is_nan(getup_yaw):
		getup_yaw += deg_to_rad(float(list[0][3]) - float(pick[3]))


## Water holds a body up (the UltraController's UltraRagdoll._buoy, per Sinew part): a part under the surface is pushed
## up by how deep it is (<= BUOY_MAX m/s2 - more than gravity from BUOY_DEPTH 0.35 m down) and slowed by the water. A
## plunge leaves the body limp at the surface instead of on the pool's floor while the capsule floats (Sinew had none).
const BUOY_PER_M := 28.0
const BUOY_MAX := 15.0
const WATER_DRAG := 2.2
const WATER_SPIN_DRAG := 1.8


func _buoy(dt: float) -> void:
	if UltraWater.all.is_empty() or _id == 0 or not active:
		return
	var tick := TickPlatform.current_tick
	for i in parts.size():
		if not bool(world.physics.call("character_attached", _id, i)):
			continue
		var body: int = world.physics.call("character_body", _id, i)
		var at: Vector3 = (world.physics.call("body_transform", body) as Transform3D).origin
		var d := UltraWater.depth_at(at, tick)
		if d <= 0.0:
			continue
		var v: Vector3 = world.physics.call("linear_velocity", body)
		v += Vector3.UP * minf(d * BUOY_PER_M, BUOY_MAX) * dt
		world.physics.call("set_linear_velocity", body, v * exp(-WATER_DRAG * dt))
		var w: Vector3 = world.physics.call("angular_velocity", body)
		world.physics.call("set_angular_velocity", body, w * exp(-WATER_SPIN_DRAG * dt))


## Getting up the character takes the clip's facing - the way the body lies - rather than turning the body round on the
## ground to its old facing (the get-up yaw eased back to the capsule's over the clip: the body pivoted while lying).
## Single player (the capsule is the truth in a session); the aim follows it round (MarksmanCharacter._process).
func _physics_process(delta: float) -> void:
	var was := _getting_up
	super._physics_process(delta)
	if _getting_up and not was:
		_face_getup()


func _face_getup() -> void:
	var c := character as MarksmanCharacter
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	if c == null or is_nan(getup_yaw) or not offline or not c.is_authority():
		return
	var from := c.state.body_yaw
	c.state.body_yaw = wrapf(getup_yaw, -PI, PI)
	c._prev_yaw = c.state.body_yaw
	c.ragdoll_yaw = 0.0
	c.aim_turn_left = angle_difference(c.input_source.live_yaw if c.input_source else from, c.state.body_yaw)

