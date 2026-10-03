@tool
class_name UltraInputDefaults
extends RefCounted
## Seed data for the Input Map. Written into project.godot (Project Settings > Input Map)
## by the plugin / tools/setup_input.gd ONLY when an action is missing, so anything the
## user edits there wins. Gameplay code never reads this file: it reads InputMap actions
## through UltraInput, so nothing here is a hard-coded binding.

const PREFIX := "uc_"

## action suffix -> [deadzone, [events...]]. Event specs:
##   "key:W", "mouse:1", "joy:0" (button index), "axis:1:-1" (axis, direction)
const ACTIONS := {
	"move_forward": [0.05, ["key:W", "key:Up", "axis:1:-1"]],
	"move_back": [0.05, ["key:S", "key:Down", "axis:1:1"]],
	"move_left": [0.05, ["key:A", "key:Left", "axis:0:-1"]],
	"move_right": [0.05, ["key:D", "key:Right", "axis:0:1"]],
	"look_left": [0.05, ["axis:2:-1"]],
	"look_right": [0.05, ["axis:2:1"]],
	"look_up": [0.05, ["axis:3:-1"]],
	"look_down": [0.05, ["axis:3:1"]],
	"jump": [0.5, ["key:Space", "joy:0"]],
	"crouch": [0.5, ["key:C", "key:Ctrl", "joy:1"]],
	"sprint": [0.5, ["key:Shift", "joy:7"]],
	"walk": [0.5, ["key:Alt"]],
	"interact": [0.5, ["key:E", "joy:2"]],
	"primary": [0.3, ["mouse:1", "axis:5:1"]],
	"secondary": [0.3, ["mouse:2", "axis:4:1"]],
	"throw": [0.5, ["key:G", "joy:10"]],
	"drop": [0.5, ["key:Q", "joy:12"]],
	"reload": [0.5, ["key:R", "joy:3"]],
	"lean_left": [0.5, ["key:Z"]],
	"lean_right": [0.5, ["key:X"]],
	"dodge": [0.5, ["key:F", "joy:9"]],
	"toggle_view": [0.5, ["key:V", "joy:8"]],
	"inventory": [0.5, ["key:Tab", "key:I", "joy:4"]],
	"hotbar_next": [0.5, ["mouse:5", "joy:14"]],
	"hotbar_prev": [0.5, ["mouse:4", "joy:13"]],
	"hotbar_1": [0.5, ["key:1"]],
	"hotbar_2": [0.5, ["key:2"]],
	"hotbar_3": [0.5, ["key:3"]],
	"hotbar_4": [0.5, ["key:4"]],
	"hotbar_5": [0.5, ["key:5"]],
	"hotbar_6": [0.5, ["key:6"]],
	"hotbar_7": [0.5, ["key:7"]],
	"hotbar_8": [0.5, ["key:8"]],
	"hotbar_9": [0.5, ["key:9"]],
	"pause": [0.5, ["key:Escape", "joy:6"]],
	"join": [0.5, ["key:Enter", "joy:6"]],
	"leave": [0.5, ["joy:4"]],
	"debug_overlay": [0.5, ["key:F1"]],
	"debug_net": [0.5, ["key:F2"]],
	"debug_ik": [0.5, ["key:F3"]],
	"debug_ragdoll": [0.5, ["key:F4"]],
	"debug_scenarios": [0.5, ["key:F5"]],
	"debug_slowmo": [0.5, ["key:F6"]],
	"debug_freecam": [0.5, ["key:F7"]],
}


static func make_event(spec: String) -> InputEvent:
	var p := spec.split(":")
	match p[0]:
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = OS.find_keycode_from_string(p[1])
			return k
		"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = int(p[1]) as MouseButton
			return m
		"joy":
			var j := InputEventJoypadButton.new()
			j.button_index = int(p[1]) as JoyButton
			j.device = -1
			return j
		"axis":
			var a := InputEventJoypadMotion.new()
			a.axis = int(p[1]) as JoyAxis
			a.axis_value = float(p[2])
			a.device = -1
			return a
	return null


## Adds every missing uc_* action to ProjectSettings. Returns how many were added.
## Existing actions are left untouched (the user's bindings win).
static func install_missing(save := true) -> int:
	var added := 0
	for suffix: String in ACTIONS:
		var key := "input/" + PREFIX + suffix
		if ProjectSettings.has_setting(key):
			continue
		var spec: Array = ACTIONS[suffix]
		var events: Array[InputEvent] = []
		for e: String in spec[1]:
			var ev := make_event(e)
			if ev:
				events.append(ev)
		ProjectSettings.set_setting(key, {"deadzone": float(spec[0]), "events": events})
		added += 1
	if added > 0 and save:
		ProjectSettings.save()
	return added
