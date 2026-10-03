@tool
class_name UltraInputSettings
extends RefCounted
## Tunables shown in Project Settings > General > ultra_controller/input/*.
## Per-player overrides live in user://ultra_input.cfg and are layered on top at boot.

const ROOT := "ultra_controller/input/"
const USER_FILE := "user://ultra_input.cfg"

## name -> [default, type, hint, hint_string]
const SETTINGS := {
	"mouse_sensitivity": [0.12, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.01,2.0,0.001"],   # degrees per pixel
	"mouse_invert_y": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"ads_sensitivity_mult": [0.7, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.1,1.5,0.01"],
	"stick_yaw_speed_deg": [220.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "30,720,1"],
	"stick_pitch_speed_deg": [160.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "30,720,1"],
	"stick_invert_y": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"stick_inner_deadzone": [0.12, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,0.5,0.01"],
	"stick_outer_deadzone": [0.95, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.5,1,0.01"],
	"stick_response_exponent": [1.8, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1,4,0.05"],
	"stick_look_accel_time": [0.35, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,2,0.01"],
	"stick_look_accel_boost": [1.6, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1,3,0.05"],
	"trigger_threshold": [0.3, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.05,0.95,0.01"],
	"toggle_crouch": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"toggle_sprint": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"toggle_ads": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"aim_assist_enabled": [false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"aim_assist_slowdown": [0.45, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,1,0.01"],
	"vibration_enabled": [true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	"vibration_strength": [1.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,2,0.01"],
	"hold_time": [0.3, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.1,1,0.01"],
	## semantic action -> InputMap action name, for host projects with their own actions
	"action_overrides": [{}, TYPE_DICTIONARY, PROPERTY_HINT_NONE, ""],
}

static var _user := ConfigFile.new()
static var _user_loaded := false


static func register(save := false) -> void:
	var changed := false
	for n: String in SETTINGS:
		var spec: Array = SETTINGS[n]
		var key := ROOT + n
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, spec[0])
			changed = true
		ProjectSettings.set_initial_value(key, spec[0])
		ProjectSettings.set_as_basic(key, true)
		ProjectSettings.add_property_info({"name": key, "type": spec[1], "hint": spec[2], "hint_string": spec[3]})
	if changed and save:
		ProjectSettings.save()


static func get_value(n: String) -> Variant:
	if not _user_loaded:
		_user_loaded = true
		_user.load(USER_FILE)
	if _user.has_section_key("input", n):
		return _user.get_value("input", n)
	return ProjectSettings.get_setting(ROOT + n, (SETTINGS[n] as Array)[0] if SETTINGS.has(n) else null)


static func f(n: String) -> float:
	return float(get_value(n))


static func b(n: String) -> bool:
	return bool(get_value(n))


static func set_user_value(n: String, v: Variant) -> void:
	get_value(n)
	_user.set_value("input", n, v)
	_user.save(USER_FILE)
