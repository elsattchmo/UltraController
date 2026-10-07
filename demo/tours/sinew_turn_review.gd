extends "res://demo/tours/tour_base.gd"
## Turning on the spot, filmed and measured: standing still, the aim swings 45 deg (inside the motor's
## turn-in-place zone: the torso alone should take it), then 120, back to -60, a 180 flick and a slow
## sweep. Frames from a camera above and behind (every 3rd tick) + every tick's measures to frames.json:
## aim / body / hips / chest facing, both feet (world), planted flags.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=sinew_turn_review --controller=sinew
##         --no-kit --out=<dir>
## tools/sinew/turn_report.py <dir> prints how close the feet came, crossings, the torso's lag and
## how many steps each turn took.

const EVERY := 3
const CROP := Vector2i(720, 720)

var _c: UltraCharacter
var _cam: Camera3D
var _frames: Array = []
var _rec := false
var _n := 0
var _shot := 0
var _ids: Dictionary = {}
var _pending: Dictionary = {}
var _label := ""


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_turn_review")
	# (Durations in physics ticks: the tour's own clock is real time and frame grabs are slow.)
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 600.0, "until": _ticks.bind(60)},
		{"call": _mark.bind("aim +45"), "t": 600.0, "yaw": 45, "until": _ticks.bind(100)},
		{"call": _mark.bind("aim +120"), "t": 600.0, "yaw": 120, "until": _ticks.bind(130)},
		{"call": _mark.bind("aim -60"), "t": 600.0, "yaw": -60, "until": _ticks.bind(150)},
		{"call": _mark.bind("flick +120 (180)"), "t": 600.0, "yaw": 120, "until": _ticks.bind(150)},
		{"call": _mark.bind("sweep 90 deg/s"), "t": 600.0, "yaw_rate": 90.0, "until": _ticks.bind(180)},
		{"call": _mark.bind("still"), "t": 600.0, "yaw_rate": 0.0, "until": _ticks.bind(90)},
		{"call": _mark.bind("turn 150 + go"), "t": 600.0, "yaw": 300, "move": Vector2(0, 1), "until": _ticks.bind(90)},
		{"call": _mark.bind("stop"), "t": 600.0, "move": Vector2.ZERO, "until": _ticks.bind(70)},
		{"call": _mark.bind("go back (180)"), "t": 600.0, "move": Vector2(0, -1), "until": _ticks.bind(90)},
		{"call": _finish, "t": 0.2},
	]


func _setup() -> void:
	_c = main.player
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 50.0
	_cam.current = true
	var sk := _c.skeleton
	for b in ["Hips", "LeftUpperLeg", "RightUpperLeg", "LeftUpperArm", "RightUpperArm", "LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
		_ids[b] = sk.find_bone(b)
	sk.skeleton_updated.connect(_on_posed)
	_rec = true
	_tick0 = Engine.get_physics_frames()


var _tick0 := 0


func _mark(label: String) -> void:
	_label = label
	print("turn_review: ", label, " at tick ", Engine.get_physics_frames())
	_tick0 = Engine.get_physics_frames()


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _process(delta: float) -> void:
	super._process(delta)
	if _cam and _c and _c.visual_root:
		var root := _c.visual_root.global_position
		_cam.global_position = root + Vector3(1.6, 2.6, 2.2)
		_cam.look_at(root + Vector3(0.0, 0.5, 0.0), Vector3.UP)
	if _rec and not _pending.is_empty():
		var rec := _pending
		_pending = {}
		if _n % EVERY == 0:
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var sz := img.get_size()
			var crop := img.get_region(Rect2i((sz.x - CROP.x) / 2, (sz.y - CROP.y) / 2, CROP.x, CROP.y))
			var name := "f%04d.png" % _shot
			crop.save_png(out_dir.path_join(name))
			rec["image"] = name
			_shot += 1
		_frames.append(rec)
		_n += 1


static func _facing(a: Vector3, b: Vector3) -> float:
	# Facing of a left -> right pair (left minus right points to the body's left): forward = left x up.
	var left := a - b
	left.y = 0.0
	var fwd := left.cross(Vector3.UP)
	return atan2(-fwd.x, -fwd.z)


func _on_posed() -> void:
	if not _rec:
		return
	var sk := _c.skeleton
	var g := func(n: String) -> Vector3: return (sk.global_transform * sk.get_bone_global_pose(_ids[n])).origin
	var r := _c.ragdoll as SinewRagdoll
	var st: Dictionary = r.world.physics.call("character_gait_state", r._id) if r else {}
	var lf: Vector3 = g.call("LeftFoot")
	var rf: Vector3 = g.call("RightFoot")
	var lt: Vector3 = g.call("LeftToes")
	var rt: Vector3 = g.call("RightToes")
	_pending = {"t": Engine.get_physics_frames(), "label": _label,
			"aim": float(_bot.live_yaw),
			"body": _c.state.body_yaw, "turning": _c.state.has(UltraMotor.F_TURNING),
			"hips": _facing(g.call("LeftUpperLeg"), g.call("RightUpperLeg")),
			"chest": _facing(g.call("LeftUpperArm"), g.call("RightUpperArm")),
			"lf": [lf.x, lf.y, lf.z], "rf": [rf.x, rf.y, rf.z], "lt": [lt.x, lt.y, lt.z], "rt": [rt.x, rt.y, rt.z],
			"planted_l": bool(st.get("planted_l", true)), "planted_r": bool(st.get("planted_r", true)),
			"vel": [_c.state.vel.x, _c.state.vel.z], "pos": [_c.state.pos.x, _c.state.pos.z]}


func _finish() -> void:
	_rec = false
	var f := FileAccess.open(out_dir.path_join("frames.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"every": EVERY, "frames": _frames}))
	f.close()
	print("turn_review: %d ticks, %d frames -> %s" % [_frames.size(), _shot, out_dir])
