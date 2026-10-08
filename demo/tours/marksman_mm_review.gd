extends "res://demo/tours/tour_base.gd"
## Motion-matching spike, filmed: the comparison suite's moves (tests/suites/mm_marksman_compare.gd: starts, stops,
## reversals, stick turns, strafe flips, sprints, a seeded chaos stick), unarmed then with the rifle, facing fixed,
## from a 3/4 camera that follows. Run it twice - with and without `--mm` - and lay the two side by side with
## tools/marksman/mm_compare_sheet.py. Frames: <out>/<gait|mm>/<stance>_<NN>_<move>_<KK>.png, every EVERY ticks.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=marksman_mm_review --controller=marksman
##         --out=<dir> [--mm] [--only=rifle] [--every=2]

const Compare := preload("res://tests/suites/mm_marksman_compare.gd")
var EVERY := 6
const CROP := Vector2i(560, 640)

var _c: UltraCharacter
var _cam: Camera3D
var _seg := ""
var _tick0 := 0
var _n := 0
var _slots := {}


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/marksman_mm_review")
	var only := String(main.args.get("only", ""))
	EVERY = int(main.args.get("every", EVERY))
	steps = [{"teleport": "spawn", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
			{"call": _setup, "t": 1.0}]
	for item in ["", "rifle"]:
		var stance: String = "unarmed" if item == "" else item
		if only != "" and not stance.contains(only):
			continue
		steps.append({"call": _place.bind(item), "t": 600.0, "until": _ticks.bind(60), "yaw": 0})
		var i := 0
		for mv: Array in Compare.moves():
			var label := "%s_%02d_%s" % [stance, i, String(mv[0]).replace(" ", "-")]
			steps.append({"call": _start.bind(label), "t": 600.0, "until": _ticks.bind(int(mv[1])), "move": mv[2],
					"buttons": int(mv[3]), "yaw": 0})
			i += 1
	steps.append({"call": func() -> void: _seg = "", "t": 0.2})


func _setup() -> void:
	# (--out is applied after _build: the mode's folder under it.)
	out_dir = out_dir.path_join("mm" if "--mm" in OS.get_cmdline_user_args() else "gait")
	DirAccess.make_dir_recursive_absolute(out_dir)
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	UltraItems.give(_c, &"rifle")
	for i in _c.inventory.size():
		var it := _c.inventory.get_slot(i)
		if it:
			_slots[String(it.def_id)] = i + 1


func _place(item: String) -> void:
	_seg = ""
	_c.teleport(main.map.call("marker", "spawn").global_position + Vector3(-16, 0, -3), 0.0)
	_bot.live_yaw = 0.0
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
	_cam.global_position = root + Vector3(2.6, 1.4, -3.0)
	_cam.look_at(root + Vector3.UP * 0.6, Vector3.UP)
	if _seg != "":
		var k := Engine.get_physics_frames() - _tick0
		if k >= _n * EVERY:
			_n += 1
			var name := "%s_%02d.png" % [_seg, _n]
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var sz := img.get_size()
			img.get_region(Rect2i((sz.x - CROP.x) / 2, (sz.y - CROP.y) / 2, CROP.x, CROP.y)).save_png(out_dir.path_join(name))
