@tool
class_name UltraInput
extends RefCounted
## Resolves semantic actions (&"jump") to Input Map action names ("uc_jump", or whatever the
## host project mapped it to in ultra_controller/input/action_overrides). Also applies the
## player's saved rebinds from user:// over the project defaults.

static var _cache := {}


static func action(semantic: StringName) -> StringName:
	var hit: Variant = _cache.get(semantic)
	if hit != null:
		return hit
	var overrides: Dictionary = UltraInputSettings.get_value("action_overrides")
	var name := StringName(overrides.get(String(semantic), UltraInputDefaults.PREFIX + String(semantic)))
	_cache[semantic] = name
	return name


static func clear_cache() -> void:
	_cache.clear()


## Called once at boot (UltraController bootstrap). Replays rebinds stored in user://.
static func apply_user_rebinds() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UltraInputSettings.USER_FILE) != OK or not cfg.has_section("bindings"):
		return
	for act: String in cfg.get_section_keys("bindings"):
		if not InputMap.has_action(act):
			continue
		var events: Array = cfg.get_value("bindings", act, [])
		InputMap.action_erase_events(act)
		for e: Variant in events:
			if e is InputEvent:
				InputMap.action_add_event(act, e)


static func save_user_rebind(act: StringName) -> void:
	var cfg := ConfigFile.new()
	cfg.load(UltraInputSettings.USER_FILE)
	cfg.set_value("bindings", String(act), InputMap.action_get_events(act))
	cfg.save(UltraInputSettings.USER_FILE)


static func reset_user_rebinds() -> void:
	var cfg := ConfigFile.new()
	cfg.load(UltraInputSettings.USER_FILE)
	if cfg.has_section("bindings"):
		cfg.erase_section("bindings")
	cfg.save(UltraInputSettings.USER_FILE)
	InputMap.load_from_project_settings()
	clear_cache()


## Device id for an event: "kbm" for keyboard & mouse, "joy<N>" for pads, "" for others.
static func device_of(e: InputEvent) -> String:
	if e is InputEventKey or e is InputEventMouse:
		return "kbm"
	if e is InputEventJoypadButton or e is InputEventJoypadMotion:
		return "joy%d" % e.device
	return ""


## Radial deadzone + response curve on a raw stick vector.
static func shape_stick(v: Vector2) -> Vector2:
	var inner := UltraInputSettings.f("stick_inner_deadzone")
	var outer := UltraInputSettings.f("stick_outer_deadzone")
	var l := v.length()
	if l <= inner:
		return Vector2.ZERO
	var t := clampf((l - inner) / maxf(outer - inner, 0.001), 0.0, 1.0)
	t = pow(t, UltraInputSettings.f("stick_response_exponent"))
	return v / l * t


## Glyph family for prompts: "kbm", "xbox", "playstation", "nintendo", "generic".
static func glyph_family(device: String) -> String:
	if device == "kbm" or device == "":
		return "kbm"
	var n := Input.get_joy_name(int(device.substr(3))).to_lower()
	if n.contains("ps") or n.contains("dualsense") or n.contains("dualshock") or n.contains("playstation"):
		return "playstation"
	if n.contains("nintendo") or n.contains("switch"):
		return "nintendo"
	if n.contains("xbox") or n.contains("xinput"):
		return "xbox"
	return "generic"
