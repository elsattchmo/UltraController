class_name LocalInputSource
extends InputSource
## Reads the Input Map (never raw keys) for one local player. In single-player it accepts
## every device; in split-screen it only listens to the devices it has claimed, so two
## pads (or a pad and the keyboard) drive two different players.

signal device_changed(device: String)

const TRACKED: Array[StringName] = [
	&"move_forward", &"move_back", &"move_left", &"move_right",
	&"look_left", &"look_right", &"look_up", &"look_down",
	&"jump", &"crouch", &"sprint", &"walk", &"interact", &"primary", &"secondary",
	&"throw", &"drop", &"reload", &"lean_left", &"lean_right", &"toggle_view", &"dodge", &"leave",
	&"hotbar_1", &"hotbar_2", &"hotbar_3", &"hotbar_4", &"hotbar_5", &"hotbar_6", &"hotbar_7", &"hotbar_8", &"hotbar_9",
	&"hotbar_next", &"hotbar_prev", &"inventory", &"respawn", &"melee",
]

## Empty = accept every device (single local player).
var claimed_devices: PackedStringArray = []
## While false (menus open, window unfocused) the player stands still. Turning it back on
## forgets every held input, so the button that closed a menu (A = jump, B = crouch, Start)
## doesn't also act in the game: an action counts again once it is pressed afresh.
var enabled := true:
	set(v):
		if v and not enabled:
			_strength.clear()
			_prev_pressed.clear()
			_interact_t = -1.0
			_interact_pulse = 0
		enabled = v
## Mouse look only while the pointer is captured (the demo captures it on click).
var require_mouse_capture := true
## Multiplier used while aiming down sights.
var sens_mult := 1.0
## Hotbar slot the player wants in hand (1..9, 0 = empty hands). Persistent intent, so a lost
## packet can't drop a weapon swap.
var want_slot := 0
## Returns the net id of the object under the crosshair (UltraInteractionScanner).
var target_provider: Callable
## Optional: is a hotbar slot occupied? (for next/previous cycling)
var slot_filled: Callable

var active_device := "kbm"
var _strength := {}            # device -> {action -> strength}
var _stick_hold := 0.0
var _crouch_toggled := false
var _sprint_toggled := false
var _crawl := false
var _last_crouch_press := -10.0
var _prev_pressed := {}        # action -> bool, for edge detection in _process
var _interact_t := -1.0        # seconds interact has been held (-1 = up)
var _interact_pulse := 0       # InputFrame bit to send on the next sample (tap / hold)


## Send `bit` for one tick (UI buttons that act like a key press, e.g. Respawn).
func pulse(bit: int) -> void:
	_interact_pulse |= bit


func claims(device: String) -> bool:
	return claimed_devices.is_empty() or claimed_devices.has(device)


func _input(event: InputEvent) -> void:
	var dev := UltraInput.device_of(event)
	if dev == "" or not claims(dev):
		return
	if event is InputEventMouseMotion:
		if enabled and (not require_mouse_capture or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
			var mm := event as InputEventMouseMotion
			var s := deg_to_rad(UltraInputSettings.f("mouse_sensitivity")) * sens_mult
			var inv := -1.0 if UltraInputSettings.b("mouse_invert_y") else 1.0
			live_yaw -= mm.screen_relative.x * s
			live_pitch = clampf(live_pitch - mm.screen_relative.y * s * inv, -1.5, 1.5)
			_set_device(dev)
		return
	# A click that captures the pointer isn't a shot.
	if event is InputEventMouseButton and require_mouse_capture and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# The wheel sends press and release in the same frame (_process never saw it held):
	# a mouse button on hotbar next / previous cycles straight from the event.
	if event is InputEventMouseButton:
		for dir in [[&"hotbar_next", 1], [&"hotbar_prev", -1]]:
			var wa := UltraInput.action(dir[0])
			if InputMap.has_action(wa) and event.is_action(wa):
				if event.is_pressed() and enabled:
					want_slot = _cycle(want_slot, int(dir[1]))
					_set_device(dev)
				return
	var bucket: Dictionary = _strength.get(dev, {})
	var touched := false
	for sem in TRACKED:
		var act := UltraInput.action(sem)
		if InputMap.has_action(act) and event.is_action(act):
			bucket[sem] = event.get_action_strength(act)
			touched = true
	if touched:
		_strength[dev] = bucket
		if event.is_pressed():
			_set_device(dev)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_strength.clear()


func _set_device(dev: String) -> void:
	if dev != active_device:
		active_device = dev
		device_changed.emit(dev)


func strength(sem: StringName) -> float:
	var s := 0.0
	for dev: String in _strength:
		s = maxf(s, float((_strength[dev] as Dictionary).get(sem, 0.0)))
	return s


func pressed(sem: StringName) -> bool:
	var thr := UltraInputSettings.f("trigger_threshold") if sem in [&"primary", &"secondary"] else 0.5
	return strength(sem) >= thr


func _just_pressed(sem: StringName) -> bool:
	var now := pressed(sem)
	var was: bool = _prev_pressed.get(sem, false)
	_prev_pressed[sem] = now
	return now and not was


func _process(delta: float) -> void:
	if not enabled:
		return
	# Gamepad look: radial deadzone, response curve, and a turn boost after holding full tilt.
	var raw := Vector2(strength(&"look_right") - strength(&"look_left"), strength(&"look_down") - strength(&"look_up"))
	var look := UltraInput.shape_stick(raw)
	if look.length() > 0.95:
		_stick_hold += delta
	else:
		_stick_hold = 0.0
	if look != Vector2.ZERO:
		var accel_t := UltraInputSettings.f("stick_look_accel_time")
		var boost := 1.0
		if accel_t > 0.0:
			boost = lerpf(1.0, UltraInputSettings.f("stick_look_accel_boost"), clampf(_stick_hold / accel_t, 0.0, 1.0))
		var inv := -1.0 if UltraInputSettings.b("stick_invert_y") else 1.0
		live_yaw -= look.x * deg_to_rad(UltraInputSettings.f("stick_yaw_speed_deg")) * boost * delta * sens_mult
		live_pitch = clampf(live_pitch - look.y * deg_to_rad(UltraInputSettings.f("stick_pitch_speed_deg")) * delta * inv * sens_mult, -1.5, 1.5)
	# Toggles and edges that are presentation state.
	if _just_pressed(&"toggle_view"):
		view_tp = not view_tp
	if _just_pressed(&"crouch"):
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_crouch_press < 0.3:
			_crawl = not _crawl
			_crouch_toggled = _crawl
		elif UltraInputSettings.b("toggle_crouch") or _crawl:
			_crouch_toggled = not _crouch_toggled
			_crawl = false
		_last_crouch_press = now
	# Interact: a tap uses / picks up, holding past `hold_time` grabs physically.
	var held_i := pressed(&"interact")
	if held_i:
		if _interact_t < 0.0:
			_interact_t = 0.0
		elif _interact_t >= 0.0:
			_interact_t += delta
			if _interact_t >= UltraInputSettings.f("hold_time") and _interact_t - delta < UltraInputSettings.f("hold_time"):
				_interact_pulse |= InputFrame.B_GRAB
	elif _interact_t >= 0.0:
		if _interact_t < UltraInputSettings.f("hold_time"):
			_interact_pulse |= InputFrame.B_INTERACT
		_interact_t = -1.0
	if _just_pressed(&"sprint") and UltraInputSettings.b("toggle_sprint"):
		_sprint_toggled = not _sprint_toggled
	for n in 9:
		if _just_pressed(StringName("hotbar_%d" % (n + 1))):
			want_slot = 0 if want_slot == n + 1 else n + 1
	for dir in [[&"hotbar_next", 1], [&"hotbar_prev", -1]]:
		if _just_pressed(dir[0]):
			want_slot = _cycle(want_slot, int(dir[1]))


func _cycle(cur: int, dir: int) -> int:
	# 0 (holstered) is part of the cycle so you can put things away from the pad.
	var s := cur
	for _i in 10:
		s = posmod(s + dir, 10)
		if s == 0 or not slot_filled.is_valid() or bool(slot_filled.call(s - 1)):
			return s
	return cur


func sample(tick: int) -> InputFrame:
	var f := InputFrame.new()
	f.tick = tick
	f.yaw = live_yaw
	f.pitch = live_pitch
	f.want_slot = want_slot
	f.aim_from = aim_from
	if target_provider.is_valid():
		f.target_id = int(target_provider.call())
	if not enabled:
		return f.quantize()
	var mv := Vector2(strength(&"move_right") - strength(&"move_left"), strength(&"move_forward") - strength(&"move_back"))
	if active_device != "kbm":
		mv = UltraInput.shape_stick(mv)
	f.move = mv.limit_length(1.0)
	var b := 0
	if pressed(&"jump"): b |= InputFrame.B_JUMP
	var crouch_held := pressed(&"crouch")
	if UltraInputSettings.b("toggle_crouch") or _crawl:
		if _crouch_toggled: b |= InputFrame.B_CROUCH
	elif crouch_held:
		b |= InputFrame.B_CROUCH
	if _crawl: b |= InputFrame.B_CRAWL
	if pressed(&"sprint") or _sprint_toggled: b |= InputFrame.B_SPRINT
	if f.move.y < 0.3: _sprint_toggled = false          # stop or turn back: sprint ends
	if pressed(&"walk"): b |= InputFrame.B_WALK
	if pressed(&"respawn"): b |= InputFrame.B_RESPAWN
	if pressed(&"melee"): b |= InputFrame.B_MELEE
	# interact / grab are pulses (tap vs hold), held for exactly one tick
	b |= _interact_pulse
	_interact_pulse = 0
	if pressed(&"primary"): b |= InputFrame.B_PRIMARY
	if pressed(&"secondary"): b |= InputFrame.B_SECONDARY
	if pressed(&"throw"): b |= InputFrame.B_THROW
	if pressed(&"drop"): b |= InputFrame.B_DROP
	if pressed(&"reload"): b |= InputFrame.B_RELOAD
	if pressed(&"dodge"): b |= InputFrame.B_DODGE
	if pressed(&"lean_left"): b |= InputFrame.B_LEAN_L
	if pressed(&"lean_right"): b |= InputFrame.B_LEAN_R
	if view_tp: b |= InputFrame.B_VIEW_TP
	f.buttons = b
	return f.quantize()


func rumble(weak: float, strong: float, duration: float) -> void:
	if not UltraInputSettings.b("vibration_enabled") or not active_device.begins_with("joy"):
		return
	var k := UltraInputSettings.f("vibration_strength")
	Input.start_joy_vibration(int(active_device.substr(3)), clampf(weak * k, 0, 1), clampf(strong * k, 0, 1), duration)
