class_name MarksmanCharacter
extends SinewCharacter
## The third controller: Sinew's physics body and gait, built around the Mixamo rifle / pistol packs.
## Full 8-way locomotion per stance (unarmed / rifle / pistol; standing, crouched, prone), guns held and
## aimed by the body itself (one body for both views: the first-person camera is the head's eye),
## one-handed holding with either hand, Insurgency: Sandstorm-style gunplay. Plan: stages V0-V8 in
## addons/marksman/README.md. Movement, weapons, input, net and HUD are the UltraCharacter's, untouched.


## Motion matching for the standing legs (a spike: MarksmanMotionMatcher, MarksmanMMPass) instead of Sinew's gait.
## On for every Marksman made while `motion_matching_on()`: the main menu's toggle / `--mm` (kept in Engine meta
## MM_META across Pause > Main menu).
@export var motion_matching := false
const MM_META := &"marksman_mm"


static func motion_matching_on() -> bool:
	if not Engine.has_meta(MM_META):
		Engine.set_meta(MM_META, "--mm" in OS.get_cmdline_user_args())
	return bool(Engine.get_meta(MM_META))


func _ready() -> void:
	if motion_matching_on():
		motion_matching = true
	super._ready()
	# Ledges are taken crouched: the traversal hook's climb-downs (drop to hang, down a wall / ladder) only for a body
	# that is crouched or crouching - standing, the feet keep to the lip and walking on goes over (see simulate).
	if motor:
		var i := motor.transition_hooks.find(UltraTraversal.hook)
		if i >= 0:
			motor.transition_hooks[i] = _traversal_hook


func _traversal_hook(m: UltraMotor, s: MotorState, inp: InputFrame) -> int:
	var crouched := s.stance == MotorState.Stance.CROUCH or inp.has(InputFrame.B_CROUCH)
	var before := s.copy() if not crouched else null
	var r: int = UltraTraversal.hook(m, s, inp)
	if before != null and r == MotorState.Id.LEDGE_CLIMB and s.trav_kind in UltraTraversal.DOWN_MOVES:
		s.copy_from(before)           # (the down moves only set state fields)
		return -1
	return r


## Sprint held with the stick sideways / back, standing: a run rather than a walk (not a sprint).
static func side_run_wanted(s: MotorState, i: InputFrame) -> bool:
	var mag := minf(i.move.length(), 1.0)
	return i.has(InputFrame.B_SPRINT) and mag > 0.5 and i.move.y <= 0.45 * mag and s.stance == MotorState.Stance.STAND


# ------------------------------------------------------------------ the gun against a wall (V4b)

## How far a held firearm reaches in front of the shoulder (m; item stat "tuck_length", else long guns 0.75, others 0.45).
static func gun_reach(def: ItemDefinition) -> float:
	return float(def.stat("tuck_length", 0.75 if def.two_handed else 0.45))


## The distance to a wall in the gun's way (m, from the shoulder along where the gun points), or INF when it's clear or
## no firearm is up. Pure: the simulated eye, the aim + free-aim offset, a ray against the static / dynamic world.
func tuck_distance(s: MotorState, i: InputFrame) -> float:
	var def := ItemDB.by_index(s.equipped) if s.held_uid != 0 else null
	if def == null or def.kind != ItemDefinition.Kind.FIREARM or not is_inside_tree():
		return INF
	var dir := UltraActionLayer.gun_dir(i.yaw, i.pitch, s.sway)
	var right := dir.cross(Vector3.UP)
	right = right.normalized() if right.length() > 1e-3 else Vector3.RIGHT
	var shoulder := s.pos + Vector3.UP * (s.height - 0.3) + right * 0.17
	var reach := gun_reach(def)
	var q := PhysicsRayQueryParameters3D.create(shoulder, shoulder + dir * reach, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return shoulder.distance_to(hit.position) if not hit.is_empty() else INF


# ------------------------------------------------------------------ holding the breath, empty reloads (V4b)

## MotorState flag bits Marksman takes (0-7 motor_state.gd, 8 F_TURNING, 9 F_HALVED, 10 F_BLOCKING, 11 F_HEART).
const F_BREATH_OUT := 1 << 12          ## held the breath till it ran out: shaky until it's half back
const F_EMPTY_RELOAD := 1 << 13        ## this reload began on an empty magazine: the bolt / slide is racked

## Holding the breath (Insurgency: Sandstorm's way: sprint held while aiming down sights, standing still): the gun
## settles onto the aim for up to HOLD_TIME s, drawn from the swimming breath (MotorState.breath - the HUD's breath bar
## shows it, it refills out of the water); run out and the aim shakes until half of it is back.
const HOLD_TIME := 5.0
const HOLD_CALM := 16.0                ## 1/s: the free-aim offset settles toward the aim this fast while held
const BREATH_BACK := 0.5               ## share of the breath back before the shaking stops
const OUT_SHAKE_DEG := 0.9             ## the tremor once out of breath (deg, at its worst)
const BREATH_FLOOR := 0.05             ## never lower (at 0 the motor drowns you)


## Is the breath being held this tick? (State + input: every machine agrees.)
func holding_breath(s: MotorState, i: InputFrame) -> bool:
	if i == null or s.has(F_BREATH_OUT) or s.action != UltraActionLayer.Action.READY or not s.is_grounded():
		return false
	if s.state in [MotorState.Id.SWIM, MotorState.Id.DIVE]:
		return false
	return i.has(InputFrame.B_SPRINT) and i.has(InputFrame.B_SECONDARY) and s.ads_w > 0.6 \
			and Vector2(s.vel.x, s.vel.z).length() < 0.5


func _hold_breath(i: InputFrame, dt: float, breath0: float) -> void:
	var s := state
	var bt := profile.breath_time
	if s.state in [MotorState.Id.SWIM, MotorState.Id.DIVE]:
		return
	if holding_breath(s, i):
		# (Drawn down from where it was before the motor refilled it this tick.)
		s.breath = breath0 - dt * bt / HOLD_TIME
		if s.breath <= BREATH_FLOOR * bt:
			s.breath = BREATH_FLOOR * bt
			s.set_flag(F_BREATH_OUT, true)
		elif s.fire_cd <= 0.0:          # (a shot's kick still comes through)
			var k := exp(-HOLD_CALM * dt)
			s.sway *= k
			s.sway_v *= k
		return
	if s.has(F_BREATH_OUT):
		var back := s.breath / (BREATH_BACK * bt)
		if back >= 1.0:
			s.set_flag(F_BREATH_OUT, false)
		elif s.held_uid != 0 and s.action in [UltraActionLayer.Action.READY, UltraActionLayer.Action.RELOADING]:
			# Gasping: a quick, irregular tremor (off the sway clock), fading as the breath comes back.
			var ph := s.sway_phase
			var amp := deg_to_rad(OUT_SHAKE_DEG) * (1.0 - back)
			s.sway_v += Vector2(sin(ph * 7.0 + 0.4), sin(ph * 5.0 + 1.3)) * amp * 60.0 * dt


## A reload that began on an empty magazine racks the bolt / slide after the new magazine is in: the sim plays the time
## up to `reload_commit` slower (EMPTY_RACK s longer in all) - the round is only there once it's chambered. Only before
## the commit (UltraActionLayer._reload finds the commit by `action_t - dt < commit`: slowed past it, it fired again).
const EMPTY_RACK := 0.6


static func empty_stretch(def: ItemDefinition, slow: float) -> float:
	var commit := float(def.stat("reload_commit", 1.5)) * slow
	return (commit + EMPTY_RACK) / commit


func _empty_reload(dt: float) -> void:
	var s := state
	if s.action != UltraActionLayer.Action.RELOADING:
		s.set_flag(F_EMPTY_RELOAD, false)
		return
	var def := ItemDB.by_index(s.equipped) if s.held_uid != 0 else null
	if def == null or String(def.stat("reload_mode", "")) == "shell":
		return
	if s.action_t <= dt * 1.5:
		s.set_flag(F_EMPTY_RELOAD, s.mag <= 0)
	if not s.has(F_EMPTY_RELOAD):
		return
	var slow := UltraInjury.reload_mult(s, damage_profile)
	var commit := float(def.stat("reload_commit", 1.5)) * slow
	if s.action_t < commit:
		s.action_t = maxf(s.action_t - dt * (1.0 - 1.0 / empty_stretch(def, slow)), 0.0)      # (encoded as u16 ms)


# ------------------------------------------------------------------ going over an edge

## Walking off an edge standing (motion matching, single player): Sinew has the body from the moment the capsule
## leaves the ground - the legs physical in the air, the balancer meeting the ground - so how it lands (a stagger
## caught, or down) is the simulation's, not the fall clip's. Kerbs and stair steps are the motor's snap (never airborne).
## A drop at least this high (m) is a ledge: standing at it the feet keep to the lip (MarksmanMMPass), walking off it
## Sinew takes the body. Lower is a step down - walked off like a kerb.
@export var ledge_height := 0.6


var _prev_state := -1
var _prev_grounded := true


func simulate(input: InputFrame, delta: float, replaying := false) -> void:
	# A gun up against a wall can't fire (V4b): the muzzle would be in the wall - the body holds it up out of the way
	# (MarksmanGunPass) and the trigger does nothing. A query on the state: client and server agree.
	if input != null and input.has(InputFrame.B_PRIMARY) and tuck_distance(state, input) < INF:
		input = input.copy()
		input.buttons &= ~InputFrame.B_PRIMARY
	# Sprint held going sideways or back runs (the motor sprints only forward - sideways it stayed a walk): the jog gait
	# for this tick, so the stick's full way is a run (jog_speed x strafe / back share, ~3.4 m/s sideways) - the stance's
	# run strafe clips show it. Not crouched.
	var side_run := input != null and side_run_wanted(state, input)
	var gait := profile.default_gait
	if side_run:
		profile.default_gait = MovementProfile.Gait.JOG
	var breath0 := state.breath
	super.simulate(input, delta, replaying)
	profile.default_gait = gait
	# (Sim, so in replays too: from the state and the input only.)
	_hold_breath(input, delta, breath0)
	_empty_reload(delta)
	if replaying:
		return
	_cross_gaps()
	_predict_landing()
	var was := _prev_state
	var was_grounded := _prev_grounded
	_prev_state = state.state
	_prev_grounded = state.is_grounded()
	var r := ragdoll as MarksmanRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	# (Walking off: the tick the capsule leaves the ground from a ground state - not a jump. The motor only says FALL a
	# moment later, by when Sinew had already let the body go to the animation for the air.)
	if was in MOTION_STATES and was_grounded and not state.is_grounded() and state.state in [MotorState.Id.FALL, MotorState.Id.IDLE, MotorState.Id.MOVE, MotorState.Id.TURN_IN_PLACE] and r != null and r.mm_legs() and offline and is_authority() \
			and state.stance != MotorState.Stance.CROUCH and not _walking_off(input) and _drop_below() >= ledge_height:
		r.over_edge(_off_dir())


## Going over on purpose: the stick pushes the way the body faces (within 90 deg either side) and it moves that way -
## stepping, running or striding off forward is a plain drop (the air clip, the legs reaching down, the landing).
## Only an accident is Sinew's fall: backing or side-stepping off, shoved or drifting off with no stick.
func _walking_off(input: InputFrame) -> bool:
	if input == null or input.move.length() < 0.1:
		return false
	var facing := Basis(Vector3.UP, state.body_yaw) * Vector3.FORWARD
	var wish := input.move_world(input.yaw)
	var hv := Vector3(state.vel.x, 0.0, state.vel.z)
	return wish.dot(facing) > 0.0 and (hv.length() < 0.2 or hv.normalized().dot(facing) > 0.0)


## Which way the body went off an edge (flat): the way it was moving, else away from the ground it stood on (probed
## round the capsule).
func _off_dir() -> Vector3:
	var hv := Vector3(state.vel.x, 0.0, state.vel.z)
	if hv.length() > 0.15:
		return hv.normalized()
	var space := get_world_3d().direct_space_state
	var away := Vector3.ZERO
	for k in 8:
		var d := Vector3.FORWARD.rotated(Vector3.UP, k * TAU / 8.0)
		var p := state.pos + d * 0.35
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.DOWN * 0.5, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
		q.exclude = [get_rid()]
		if space.intersect_ray(q).is_empty():
			away += d
	return away.normalized() if away.length() > 1e-3 else Vector3.ZERO


# ------------------------------------------------------------------ landings

## Falling, where and how hard we'll come down: UltraMotor.predict_impact ({speed, time, point}; {} rising, grounded,
## coming down in water / on a moving platform). The driver straightens the legs to meet the ground by it.
var landing := {}
## A landing at least this hard (m/s down; a standing hop comes down at ~5.6) is met by the body: Sinew powers it a
## moment before touchdown (MarksmanRagdoll.land_brace) - the upper body physical, carried on into the stop and caught
## by its muscles, the legs on the landing clip; a very hard one is the balancer's. Softer landings are the animation's.
## The motor's own hard landing (hard_land_speed, the limp ragdoll) stays the motor's.
@export var land_brace_speed := 7.0
## Seconds before touchdown the body goes physical.
const LAND_BRACE_LEAD := 0.1


func _predict_landing() -> void:
	landing = {}
	if state.is_grounded() or state.state not in [MotorState.Id.JUMP, MotorState.Id.FALL] or state.vel.y > 0.5 or motor == null:
		return
	landing = motor.predict_impact(state)
	var r := ragdoll as MarksmanRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	if landing.is_empty() or r == null or not offline or not is_authority():
		return
	var v: float = landing.speed
	if v >= land_brace_speed and v <= profile.hard_land_speed and float(landing.time) <= LAND_BRACE_LEAD:
		r.land_brace(v)


# ------------------------------------------------------------------ gaps: one long stride

## A gap the legs can span along the way the body is going is crossed in a stride: the body is held at the edges'
## height while its centre is over it (no fall, no fall clip), and the feet land on the edges (MarksmanMMPass). Wider
## than the legs can span at this speed, it's a fall like any other edge. Single player, motion matching (like the
## rest of Marksman's physical presentation, the networked motor stays the predicting one).
## How wide a gap the legs can span (m): walking .. sprinting.
const GAP_SPAN := Vector2(0.9, 1.8)
## Ground this far below the feet is a gap; ground back within this of the near side is its far edge (m).
const GAP_DROP := 0.3
const GAP_LEVEL := 0.25
const GAP_LOOK := 2.6            ## m ahead scanned
## The gap being crossed: {from: near edge (world), to: far edge, dir: unit (flat), y: the edges' height}; {} = none.
var gap := {}


func _span(speed: float) -> float:
	return lerpf(GAP_SPAN.x, GAP_SPAN.y, smoothstep(profile.walk_speed, profile.sprint_speed, speed))


## Ahead along `dir` from the capsule: the first gap (ground falling away more than GAP_DROP, coming back within
## GAP_LEVEL of the near side) within GAP_LOOK, or {}.
func _scan_gap(dir: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var y0 := state.pos.y
	var start := -1.0
	const STEP := 0.05
	var n := int(GAP_LOOK / STEP)
	for k in n + 1:
		var d := k * STEP
		var p := state.pos + dir * d
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, y0 + 0.5, p.z), Vector3(p.x, y0 - 1.5, p.z), UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		var h: float = (hit.position as Vector3).y - y0 if not hit.is_empty() else -9.0
		if start < 0.0:
			if h < -GAP_DROP:
				if k == 0:
					return {}               # (already over it: the motor's)
				start = d
		elif absf(h) <= GAP_LEVEL:
			return {"from": state.pos + dir * (start - STEP * 0.5), "to": state.pos + dir * (d - STEP * 0.5), "dir": dir,
					"y": y0, "width": d - start}
	return {}


## After the motor's step: start, hold or end a gap crossing.
func _cross_gaps() -> void:
	var r := ragdoll as MarksmanRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	var hv := Vector3(state.vel.x, 0.0, state.vel.z)
	var speed := hv.length()
	if r == null or not r.mm_legs() or not offline or not is_authority() or r.staggering() or r.active:
		gap = {}
		return
	if gap.is_empty():
		if state.is_grounded() and state.state in MOTION_STATES and speed > 0.5:
			var g := _scan_gap(hv / speed)
			if not g.is_empty() and float(g.width) <= _span(speed):
				gap = g
		return
	# Crossing: along the gap's way, until the centre is past the far edge (or the body turned back / stopped).
	var dir: Vector3 = gap.dir
	var along := (state.pos - (gap.from as Vector3)).dot(dir)
	var width: float = gap.width
	if along > width + 0.35 or hv.dot(dir) < 0.3 or along < -0.6:
		gap = {}
		return
	if along > -0.05 and along < width + 0.05 and state.pos.y < float(gap.y) + 0.05:
		# Over it: the body stays at the edges' height, on its feet (the motor would have it fall in).
		global_position.y = float(gap.y)
		state.pos = global_position
		velocity.y = 0.0
		state.vel.y = 0.0
		state.teeter = 0.0
		if state.state in [MotorState.Id.FALL, MotorState.Id.JUMP]:
			state.state = MotorState.Id.MOVE
		state.set_flag(MotorState.F_GROUNDED, true)


## How far the ground is under the capsule's centre (m; 9 when nothing within 3 m).
func _drop_below() -> float:
	var q := PhysicsRayQueryParameters3D.create(state.pos + Vector3.UP * 0.3, state.pos + Vector3.DOWN * 3.0, UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return state.pos.y - (hit.position as Vector3).y if not hit.is_empty() else 9.0


## A hit on the move (MarksmanRagdoll._stumble_hit) doesn't stop the runner: the body still wants its run, held back
## only by how bad the hit was (`moving_stumble_sag` x severity at the hit, back over the stumble) - the gait's catching
## steps then judge the lurch against a run, not a stop (Sinew's push rule asks for nothing at first: every sprinter
## shot in the leg tripped). -1 = a plain push.
var moving_stumble := -1.0
@export var moving_stumble_sag := 0.7


func _stumble_command_share() -> float:
	if moving_stumble < 0.0 or _stumble_t <= 0.0:
		moving_stumble = -1.0
		return super._stumble_command_share()
	return 1.0 - moving_stumble * moving_stumble_sag * _stumble_t / STUMBLE_TIME


## A push under motion matching: the legs go to Sinew's gait for the stumble (its catching steps under physical
## motion, the trip rule), then back to the matcher (MarksmanRagdoll.stumble_start).
func receive_push(dv: Vector3) -> bool:
	moving_stumble = -1.0          # (a hit on the move sets it again after its push)
	var r := ragdoll as MarksmanRagdoll
	var offline := UltraNet.mode == UltraNet.Mode.NONE or UltraNet.mode == UltraNet.Mode.OFFLINE
	if not _motion_on and r != null and r.mm_legs() and physical_motion and offline and is_authority() \
			and state.is_grounded() and state.state in MOTION_STATES and state.platform_id == 0:
		r.stumble_start()
		if r.gait_walking():
			_motion_on = true
			_motion_vel = Vector3(state.vel.x, 0.0, state.vel.z)
	return super.receive_push(dv)


# ------------------------------------------------------------------ rope: letting go without a snap

## On a rope the body is drawn along it (UltraCharacter._sync_visual: tilted to the rope, 16 cm behind it); letting go it
## stood straight up in one frame - the whole skeleton turned up to 60 deg and moved 1.1 m in a frame (Sinew read it as a
## teleport and snapped the hanging body onto the animation). The tilt and offset ease out over ROPE_LET_GO s instead.
const ROPE_LET_GO := 0.3
var _rope_vis := Transform3D()
var _rope_off := Vector3.INF          ## the rope pose's offset from the upright one at the release (INF: none)
var _rope_ease := -1.0


func _sync_visual(alpha: float) -> void:
	super._sync_visual(alpha)
	if visual_root == null:
		return
	if state.state == MotorState.Id.ROPE:
		_rope_vis = visual_root.global_transform
		_rope_ease = 0.0
		_rope_off = Vector3.INF
		return
	if _rope_ease < 0.0:
		return
	var up := visual_root.global_transform
	if _rope_off == Vector3.INF:
		_rope_off = _rope_vis.origin - up.origin
	_rope_ease += get_process_delta_time()
	var k := smoothstep(0.0, 1.0, _rope_ease / ROPE_LET_GO)
	if k >= 1.0:
		_rope_ease = -1.0
		return
	var b := _rope_vis.basis.get_rotation_quaternion().slerp(up.basis.get_rotation_quaternion(), k)
	visual_root.global_transform = Transform3D(Basis(b), up.origin + _rope_off * (1.0 - k))


func _new_anim_driver() -> SinewAnimDriver:
	return MarksmanAnimDriver.new()


func _new_ragdoll() -> SinewRagdoll:
	return MarksmanRagdoll.new()


func _default_anim_set() -> String:
	return "res://addons/marksman/marksman_animset.tres"


func _new_equipment() -> UltraEquipmentVisual:
	return MarksmanEquipment.new()


## The body-true first-person eye (MarksmanEye), added beside the camera rig that follows this character - the
## rig is made by the local player manager, not the character, so it's looked for until it's there.
var eye: MarksmanEye


## Getting up facing the way the body lay (MarksmanRagdoll._face_getup): the aim still to turn round to it (rad), eased
## out over the get-up - the camera turns with the body; mouse movement meanwhile adds on top.
var aim_turn_left := 0.0
const AIM_TURN_RATE := 2.8


func _process(delta: float) -> void:
	if absf(aim_turn_left) > 1e-4 and input_source:
		var step := clampf(aim_turn_left, -AIM_TURN_RATE * delta, AIM_TURN_RATE * delta)
		input_source.live_yaw += step
		aim_turn_left -= step
	super._process(delta)
	if (eye == null or not is_instance_valid(eye)) and Engine.get_process_frames() % 30 == 0 and is_inside_tree():
		for n in get_tree().root.find_children("*", "UltraCameraRig", true, false):
			var r := n as UltraCameraRig
			if r.character == self:
				eye = MarksmanEye.new(self, r)
				r.add_child(eye)
				break
