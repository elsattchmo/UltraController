class_name MotorState
extends RefCounted
## Everything needed to resimulate a character from a tick: the motor is a pure function of
## (MotorState, InputFrame, profile, world). Snapshots and reconciliation copy this object.

enum Id {
	IDLE, MOVE, CROUCH, CRAWL, SLIDE, JUMP, FALL, LAND, ROOT_MOTION, TURN_IN_PLACE,
	MANTLE, VAULT, LEDGE_HANG, LEDGE_CLIMB, LADDER, WALL_CLIMB, ROPE, SWIM, DIVE,
	RAGDOLL, GET_UP, DEAD,
}
enum Stance { STAND, CROUCH, CRAWL }

const F_GROUNDED := 1 << 0
const F_JUMP_HELD := 1 << 1       ## jump still held since takeoff (variable height)
const F_WAS_GROUNDED := 1 << 2
const F_SPRINTING := 1 << 3
const F_ON_PLATFORM := 1 << 4
const F_HARD_LANDING := 1 << 5

var pos := Vector3.ZERO
var vel := Vector3.ZERO
var body_yaw: float = 0.0
var state: int = Id.IDLE
var prev_state: int = Id.IDLE
var state_time: float = 0.0
var stance: int = Stance.STAND
var height: float = 1.8          ## current capsule height (lerps between stances)
var flags: int = 0
var coyote_t: float = 0.0
var jump_buf_t: float = 0.0
var land_impact: float = 0.0      ## vertical speed at last landing (m/s)
var air_time: float = 0.0
var prev_buttons: int = 0
## Root-motion action: clip index into the AnimationSet's root motion table, and time.
var rm_clip: int = -1
var rm_t: float = 0.0
var rm_yaw0: float = 0.0
var rm_scale := Vector3.ONE
## Interaction / traversal context (filled in later milestones).
var held_id: int = 0
var held_mass: float = 0.0
var carry_mult: float = 1.0
var injury_bits: int = 0
var trav_point := Vector3.ZERO
var trav_normal := Vector3.ZERO
var trav_height: float = 0.0
var platform_id: int = 0
var platform_local := Vector3.ZERO
## Held item / action layer (items, weapons, interaction). See UltraActionLayer.
var held_uid: int = 0              ## ItemInstance uid in hand (0 = empty hands)
var equipped: int = 0              ## ItemDB index of the held item
var action: int = 0                ## UltraActionLayer.Action
var action_t: float = 0.0
var fire_cd: float = 0.0
var mag: int = 0
var fire_seq: int = 0              ## +1 per shot (remote clients play effects on change)
var hp: float = 100.0
var throw_charge: float = 0.0      ## 0..1 while the throw button is held with a prop
var held_grip: int = -1            ## team lift: which grip point we hold
var team_share: float = 1.0        ## team lift: our share of the load (server)
## Traversal (mantle / vault / ledge / ladder / wall / rope).
var trav_from := Vector3.ZERO      ## scripted move: start position (rope: swing velocity)
var trav_to := Vector3.ZERO        ## scripted move: end position
var trav_t: float = 0.0            ## scripted move: elapsed
var trav_dur: float = 0.0          ## scripted move: duration
var trav_id: int = 0               ## ladder / rope id
var trav_s: float = 0.0            ## ladder height / rope grip distance
var trav_kind: int = 0             ## UltraTraversal.Move


func has(f: int) -> bool:
	return (flags & f) != 0


func set_flag(f: int, on: bool) -> void:
	flags = (flags | f) if on else (flags & ~f)


func is_grounded() -> bool:
	return has(F_GROUNDED)


func copy() -> MotorState:
	var s := MotorState.new()
	s.copy_from(self)
	return s


func copy_from(o: MotorState) -> void:
	pos = o.pos; vel = o.vel; body_yaw = o.body_yaw
	state = o.state; prev_state = o.prev_state; state_time = o.state_time
	stance = o.stance; height = o.height; flags = o.flags
	coyote_t = o.coyote_t; jump_buf_t = o.jump_buf_t; land_impact = o.land_impact
	air_time = o.air_time; prev_buttons = o.prev_buttons
	rm_clip = o.rm_clip; rm_t = o.rm_t; rm_yaw0 = o.rm_yaw0; rm_scale = o.rm_scale
	held_id = o.held_id; held_mass = o.held_mass; carry_mult = o.carry_mult
	injury_bits = o.injury_bits
	trav_point = o.trav_point; trav_normal = o.trav_normal; trav_height = o.trav_height
	platform_id = o.platform_id; platform_local = o.platform_local
	held_uid = o.held_uid; equipped = o.equipped; action = o.action; action_t = o.action_t
	fire_cd = o.fire_cd; mag = o.mag; fire_seq = o.fire_seq; hp = o.hp
	throw_charge = o.throw_charge; held_grip = o.held_grip; team_share = o.team_share
	trav_from = o.trav_from; trav_to = o.trav_to; trav_t = o.trav_t; trav_dur = o.trav_dur
	trav_id = o.trav_id; trav_s = o.trav_s; trav_kind = o.trav_kind


## Error metric used by reconciliation (metres, plus a penalty for discrete mismatches).
func diff(o: MotorState) -> float:
	var d := pos.distance_to(o.pos) + vel.distance_to(o.vel) * 0.05
	if state != o.state or stance != o.stance or held_id != o.held_id:
		d += 1.0
	if held_uid != o.held_uid or action != o.action or mag != o.mag or fire_seq != o.fire_seq:
		d += 1.0
	d += absf(action_t - o.action_t) + absf(hp - o.hp) * 0.01
	return d


func encode(buf: StreamPeerBuffer) -> void:
	buf.put_float(pos.x); buf.put_float(pos.y); buf.put_float(pos.z)
	buf.put_16(_q(vel.x, 100.0)); buf.put_16(_q(vel.y, 100.0)); buf.put_16(_q(vel.z, 100.0))
	buf.put_u16(int(roundf(fposmod(body_yaw, TAU) / TAU * 65536.0)) % 65536)
	buf.put_u8(state); buf.put_u8(prev_state); buf.put_u8(stance)
	buf.put_u16(clampi(int(state_time * 1000.0), 0, 65535))
	buf.put_u16(int(roundf(height * 1000.0)))
	buf.put_u16(flags)
	buf.put_u8(clampi(int(coyote_t * 255.0 / 0.5), 0, 255))
	buf.put_u8(clampi(int(jump_buf_t * 255.0 / 0.5), 0, 255))
	buf.put_16(_q(land_impact, 100.0))
	buf.put_u16(clampi(int(air_time * 1000.0), 0, 65535))
	buf.put_u32(prev_buttons)
	buf.put_8(rm_clip)
	buf.put_u16(clampi(int(rm_t * 1000.0), 0, 65535))
	buf.put_float(rm_yaw0)
	buf.put_float(rm_scale.x); buf.put_float(rm_scale.y); buf.put_float(rm_scale.z)
	buf.put_u16(held_id)
	buf.put_float(held_mass)
	buf.put_u16(injury_bits)
	buf.put_float(trav_point.x); buf.put_float(trav_point.y); buf.put_float(trav_point.z)
	buf.put_8(_q8(trav_normal.x, 127.0)); buf.put_8(_q8(trav_normal.y, 127.0)); buf.put_8(_q8(trav_normal.z, 127.0))
	buf.put_float(trav_height)
	buf.put_u16(platform_id)
	buf.put_float(platform_local.x); buf.put_float(platform_local.y); buf.put_float(platform_local.z)
	buf.put_u32(held_uid)
	buf.put_u16(equipped)
	buf.put_u8(action)
	buf.put_u16(clampi(int(roundf(action_t * 1000.0)), 0, 65535))
	buf.put_u16(clampi(int(roundf(fire_cd * 1000.0)), 0, 65535))
	buf.put_u8(clampi(mag, 0, 255))
	buf.put_u8(fire_seq & 255)
	buf.put_u16(clampi(int(roundf(hp * 10.0)), 0, 65535))
	buf.put_u8(clampi(int(roundf(throw_charge * 255.0)), 0, 255))
	buf.put_8(held_grip)
	buf.put_u8(clampi(int(roundf(team_share * 255.0)), 0, 255))
	buf.put_u16(clampi(int(roundf(carry_mult * 1000.0)), 0, 65535))
	for v in [trav_from, trav_to]:
		buf.put_float(v.x); buf.put_float(v.y); buf.put_float(v.z)
	buf.put_u16(clampi(int(roundf(trav_t * 1000.0)), 0, 65535))
	buf.put_u16(clampi(int(roundf(trav_dur * 1000.0)), 0, 65535))
	buf.put_u16(trav_id)
	buf.put_float(trav_s)
	buf.put_u8(trav_kind)


func decode(buf: StreamPeerBuffer) -> void:
	pos = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	vel = Vector3(buf.get_16() / 100.0, buf.get_16() / 100.0, buf.get_16() / 100.0)
	body_yaw = buf.get_u16() / 65536.0 * TAU
	state = buf.get_u8(); prev_state = buf.get_u8(); stance = buf.get_u8()
	state_time = buf.get_u16() / 1000.0
	height = buf.get_u16() / 1000.0
	flags = buf.get_u16()
	coyote_t = buf.get_u8() / 255.0 * 0.5
	jump_buf_t = buf.get_u8() / 255.0 * 0.5
	land_impact = buf.get_16() / 100.0
	air_time = buf.get_u16() / 1000.0
	prev_buttons = buf.get_u32()
	rm_clip = buf.get_8()
	rm_t = buf.get_u16() / 1000.0
	rm_yaw0 = buf.get_float()
	rm_scale = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	held_id = buf.get_u16()
	held_mass = buf.get_float()
	injury_bits = buf.get_u16()
	trav_point = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	trav_normal = Vector3(buf.get_8() / 127.0, buf.get_8() / 127.0, buf.get_8() / 127.0)
	trav_height = buf.get_float()
	platform_id = buf.get_u16()
	platform_local = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	held_uid = buf.get_u32()
	equipped = buf.get_u16()
	action = buf.get_u8()
	action_t = buf.get_u16() / 1000.0
	fire_cd = buf.get_u16() / 1000.0
	mag = buf.get_u8()
	fire_seq = buf.get_u8()
	hp = buf.get_u16() / 10.0
	throw_charge = buf.get_u8() / 255.0
	held_grip = buf.get_8()
	team_share = buf.get_u8() / 255.0
	carry_mult = buf.get_u16() / 1000.0
	trav_from = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	trav_to = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
	trav_t = buf.get_u16() / 1000.0
	trav_dur = buf.get_u16() / 1000.0
	trav_id = buf.get_u16()
	trav_s = buf.get_float()
	trav_kind = buf.get_u8()


## Round-trip through the codec, so a predicting client and the server hold the same bits.
func quantize() -> MotorState:
	var b := StreamPeerBuffer.new()
	encode(b)
	b.seek(0)
	decode(b)
	return self


## Quantize to a signed 16-bit field.
static func _q(v: float, scale: float) -> int:
	return clampi(int(roundf(v * scale)), -32767, 32767)


## Quantize to a signed 8-bit field.
static func _q8(v: float, scale: float) -> int:
	return clampi(int(roundf(v * scale)), -127, 127)
