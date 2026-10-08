extends "res://demo/tours/tour_base.gd"
## Marksman's locomotion filmed: per stance (unarmed, rifle, pistol) and posture (standing, crouched, prone),
## standing still then each of the 8 directions with the facing fixed, from a 3/4 camera. Frames go to
## <out>/<stance>_<posture>_<dir>_NN.png; tools/marksman/contact_sheet.py lays them out.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_moves_review --controller=marksman
##         --out=<dir> [--only=rifle] [--postures=stand,crouch,prone]

const DIRS := {"idle": Vector2.ZERO, "f": Vector2(0, 1), "fr": Vector2(0.7071, 0.7071), "r": Vector2(1, 0),
		"br": Vector2(0.7071, -0.7071), "b": Vector2(0, -1), "bl": Vector2(-0.7071, -0.7071), "l": Vector2(-1, 0),
		"fl": Vector2(-0.7071, 0.7071)}
const TICKS := 72
const EVERY := 8
const CROP := Vector2i(560, 640)

var _c: UltraCharacter
var _cam: Camera3D
var _seg := ""
var _tick0 := 0
var _n := 0
var _slots := {}


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_moves_review")
	var only := String(main.args.get("only", ""))
	var postures := String(main.args.get("postures", "stand,crouch,prone")).split(",")
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
			{"call": _setup, "t": 1.0}]
	for item in ["", "rifle", "pistol"]:
		var stance := "unarmed" if item == "" else item
		if only != "" and not stance.contains(only):
			continue
		for posture in postures:
			var buttons := {"stand": 0, "crouch": InputFrame.B_CROUCH, "prone": InputFrame.B_CRAWL | InputFrame.B_CROUCH}[posture]
			for d: String in DIRS:
				var label := "%s_%s_%s" % [stance, posture, d]
				steps.append({"call": _place.bind(item), "t": 0.1})
				# (Settle into the stance and posture on the spot, then move.)
				steps.append({"call": _arm.bind(item), "t": 600.0, "until": _ticks.bind(50), "buttons": buttons, "yaw": 0})
				steps.append({"call": _start.bind(label), "t": 600.0, "until": _ticks.bind(TICKS), "move": DIRS[d], "buttons": buttons, "yaw": 0})
	steps.append({"call": func() -> void: _seg = "", "t": 0.2})


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	for item: StringName in [&"rifle", &"pistol"]:
		UltraItems.give(_c, item)
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1


func _place(_item: String) -> void:
	_seg = ""
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)
	_bot.live_yaw = 0.0


func _arm(item: String) -> void:
	_slot = int(_slots.get(item, 0))
	_tick0 = Engine.get_physics_frames()


func _start(label: String) -> void:
	_seg = label
	_n = 0
	_tick0 = Engine.get_physics_frames()


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _process(delta: float) -> void:
	super._process(delta)
	if _cam == null or _c == null or _c.visual_root == null:
		return
	var root := _c.visual_root.global_position
	# A fixed 3/4 view from front-right (the character faces -Z).
	_cam.global_position = root + Vector3(2.6, 1.4, -3.0)
	_cam.look_at(root + Vector3.UP * 0.6, Vector3.UP)
	if _seg != "":
		var k := Engine.get_physics_frames() - _tick0
		if k >= _n * EVERY:
			_n += 1
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var sz := img.get_size()
			img.get_region(Rect2i((sz.x - CROP.x) / 2, (sz.y - CROP.y) / 2, CROP.x, CROP.y)).save_png(out_dir.path_join("%s_%02d.png" % [_seg, _n]))
