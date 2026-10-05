class_name InputSource
extends Node
## Produces one InputFrame per simulation tick for a character. Implementations:
## LocalInputSource (keyboard/mouse/gamepad), BotInputSource (scripted), RemoteInputSource
## (server side: frames received from a client).

## Live aim, updated every rendered frame for the camera (ticks only sample it).
var live_yaw: float = 0.0
var live_pitch: float = 0.0
## Presentation state owned by the source (view mode, ADS) that also rides in the frame.
var view_tp := false
## The camera's position relative to the simulated eye (set every frame by the camera rig);
## rides in the frame so shots start where the player looks from.
var aim_from := Vector3.ZERO


func sample(_tick: int) -> InputFrame:
	var f := InputFrame.new()
	f.tick = _tick
	f.yaw = live_yaw
	f.pitch = live_pitch
	f.aim_from = aim_from
	return f.quantize()


## Called by the character on spawn / teleport so aim starts where the body faces.
func reset_aim(yaw: float, pitch: float = 0.0) -> void:
	live_yaw = yaw
	live_pitch = pitch


## Optional camera kick (recoil etc.) applied to live aim.
func add_aim_offset(dyaw: float, dpitch: float) -> void:
	live_yaw += dyaw
	live_pitch = clampf(live_pitch + dpitch, -1.5, 1.5)
