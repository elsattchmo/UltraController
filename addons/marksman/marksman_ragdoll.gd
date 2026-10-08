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


func setup(c: UltraCharacter) -> void:
	super.setup(c)
	if modifier != null and not parts.is_empty():
		gun_pass = MarksmanGunPass.new(c, self)
		modifier.passes.append(gun_pass)


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
	var gi := aset.group_index(MarksmanStance.of(character), posture)
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
	var item_busy := st.held_uid != 0 and MarksmanStance.of(character) == "unarmed"
	var really := item_busy or st.held_id != 0 or (drv != null and drv.upper_busy())
	return super._gait_upper_weight(really, speed)


## The body went over an edge (MarksmanCharacter.simulate): the whole body physical now, the balancer on - it lands
## on whatever is below and either catches itself or goes down.
func over_edge() -> void:
	if _id == 0 or active or not _powered_on or _stagger_t >= 0.0:
		return
	start_stagger()
	_over_edge = _stagger_t >= 0.0


var _over_edge := false


## Going over an edge, the body stays powered in the air (the balancer has it until it lands and settles or falls).
func _powered_in_air() -> bool:
	if _over_edge and _stagger_t < 0.0:
		_over_edge = false
	return _over_edge


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
	var imp := minf(amount * hit_impulse_per_damage, hit_impulse_max)
	var c := character as SinewCharacter
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


func _relax_floor(part: int) -> float:
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
