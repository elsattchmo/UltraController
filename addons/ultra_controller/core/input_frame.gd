class_name InputFrame
extends RefCounted
## One tick of player intent. This is the ONLY thing the motor reads from a player, and the
## only thing a client sends the server, so single-player, prediction and the server all
## simulate from identical (quantized) values.

const B_JUMP := 1 << 0
const B_CROUCH := 1 << 1
const B_SPRINT := 1 << 2
const B_WALK := 1 << 3
const B_INTERACT := 1 << 4
const B_PRIMARY := 1 << 5
const B_SECONDARY := 1 << 6
const B_THROW := 1 << 7
const B_DROP := 1 << 8
const B_RELOAD := 1 << 9
const B_LEAN_L := 1 << 10
const B_LEAN_R := 1 << 11
const B_VIEW_TP := 1 << 12      ## state bit: player is in third person (affects rotation mode)
const B_CRAWL := 1 << 13        ## state bit: toggled crawl (double-tap crouch)
const B_DODGE := 1 << 14
const B_GRAB := 1 << 15         ## interact held: grab physically instead of picking up / using

const ENCODED_SIZE := 17

var tick: int = 0
var move := Vector2.ZERO        ## x = right, y = forward; length <= 1
var yaw: float = 0.0            ## absolute aim yaw (radians, 0 = -Z)
var pitch: float = 0.0          ## absolute aim pitch (radians, + = up)
var buttons: int = 0
var target_id: int = 0          ## interaction / grab target net id (0 = none)
var want_slot: int = 0          ## hotbar slot the player wants in hand (1..9), 0 = empty hands


func has(bit: int) -> bool:
	return (buttons & bit) != 0


func move_world(yaw_override: float = NAN) -> Vector3:
	var y := yaw if is_nan(yaw_override) else yaw_override
	var fwd := Vector3(-sin(y), 0.0, -cos(y))
	var right := Vector3(cos(y), 0.0, -sin(y))
	return right * move.x + fwd * move.y


## Snap to exactly what survives encode/decode, so the local sim matches the server.
func quantize() -> InputFrame:
	var l := move.length()
	if l > 1.0:
		move /= l
	move = Vector2(roundf(move.x * 127.0) / 127.0, roundf(move.y * 127.0) / 127.0)
	yaw = _q_yaw(yaw)
	pitch = roundf(clampf(pitch, -1.55, 1.55) * 20000.0) / 20000.0
	return self


static func _q_yaw(y: float) -> float:
	var w := fposmod(y, TAU)
	return float(int(roundf(w / TAU * 65536.0)) % 65536) / 65536.0 * TAU


func copy() -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	f.move = move
	f.yaw = yaw
	f.pitch = pitch
	f.buttons = buttons
	f.target_id = target_id
	f.want_slot = want_slot
	return f


func encode(buf: StreamPeerBuffer) -> void:
	buf.put_u32(tick)
	buf.put_8(int(roundf(clampf(move.x, -1.0, 1.0) * 127.0)))
	buf.put_8(int(roundf(clampf(move.y, -1.0, 1.0) * 127.0)))
	buf.put_u16(int(roundf(fposmod(yaw, TAU) / TAU * 65536.0)) % 65536)
	buf.put_16(int(roundf(clampf(pitch, -1.55, 1.55) * 20000.0)))
	buf.put_u32(buttons)
	buf.put_u16(target_id)
	buf.put_u8(want_slot)
	# 4+1+1+2+2+4+2+1 = ENCODED_SIZE (17) bytes


static func decode(buf: StreamPeerBuffer) -> InputFrame:
	var f := InputFrame.new()
	f.tick = buf.get_u32()
	f.move = Vector2(buf.get_8() / 127.0, buf.get_8() / 127.0)
	f.yaw = buf.get_u16() / 65536.0 * TAU
	f.pitch = buf.get_16() / 20000.0
	f.buttons = buf.get_u32()
	f.target_id = buf.get_u16()
	f.want_slot = buf.get_u8()
	return f
