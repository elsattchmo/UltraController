extends "res://demo/tours/tour_base.gd"
## The moves the user reported broken, filmed and measured (tools/sinew/moves_report.py reads it):
## standing (unarmed / pistol / rifle, each with Sinew's gait and with the clip alone as the reference),
## walking forward (from behind), the four diagonals, a sprint start, sprint turns (sweep and 180 flick),
## walk and sprint reversals. Every tick: the leg bones, chest, facing / aim, speed, the gait's state.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=sinew_moves_review --controller=sinew
##         --out=<dir> [--only=<segment substring>]
## (Durations in physics ticks: the tour's clock is real time and frame grabs are slow.)

const EVERY := 3
const CROP := Vector2i(640, 720)
const BONES := ["Hips", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg",
		"RightFoot", "RightToes", "LeftUpperArm", "RightUpperArm", "Head"]

var _c: UltraCharacter
var _r: SinewRagdoll
var _cam: Camera3D
var _cam_mode := "front"
var _frames: Array = []
var _rec := false
var _n := 0
var _shot := 0
var _ids: Dictionary = {}
var _pending: Dictionary = {}
var _label := ""
var _tick0 := 0


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/sinew_moves_review")
	var segs := SinewMoveSegments.all()
	var only := String(main.args.get("only", ""))
	steps = [{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
			{"call": _setup, "t": 600.0, "until": _ticks.bind(30)}]
	for s: Array in segs:
		var label: String = s[0]
		if only != "" and not label.contains(only) and not label.begins_with("@"):
			continue
		var st: Dictionary = (s[2] as Dictionary).duplicate()
		if label.begins_with("@"):
			steps.append({"call": _place.bind(label), "t": 0.1})
		var yaw_add := float(st.get("yaw_add", 0.0))
		st.erase("yaw_add")
		st["call"] = _seg.bind(label, s[3], s[4], yaw_add)
		st["t"] = 600.0
		st["until"] = _ticks.bind(int(s[1]))
		steps.append(st)
	steps.append({"call": _finish, "t": 0.2})


func _seg(label: String, cam: String, gait_on: bool, yaw_add: float) -> void:
	_label = label
	_cam_mode = cam
	_tick0 = Engine.get_physics_frames()
	if yaw_add != 0.0:
		_bot.live_yaw += deg_to_rad(yaw_add)
	if _r and _r.gait != gait_on:
		_r.gait = gait_on
		_r._setup_gait()
	print("moves_review: ", label, " at tick ", _tick0)


func _place(label: String) -> void:
	var at := SinewMoveSegments.place(label, main.map)
	if _c and not at.is_empty():
		_c.teleport(at[0], at[1])
		_bot.live_yaw = at[1]


func _ticks(n: int) -> bool:
	return Engine.get_physics_frames() - _tick0 >= n


func _setup() -> void:
	_c = main.player
	_r = _c.ragdoll as SinewRagdoll
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 45.0
	_cam.current = true
	var sk := _c.skeleton
	for b in BONES:
		_ids[b] = sk.find_bone(b)
	sk.skeleton_updated.connect(_on_posed)
	_rec = true
	_tick0 = Engine.get_physics_frames()


func _process(delta: float) -> void:
	super._process(delta)
	if _cam and _c and _c.visual_root:
		var root := _c.visual_root.global_position
		var yaw := Basis(Vector3.UP, _c.state.body_yaw)
		var fwd := yaw * Vector3(0, 0, -1)
		var right := yaw * Vector3(1, 0, 0)
		var at := root + Vector3.UP * 0.9
		match _cam_mode:
			"front": _cam.global_position = root + fwd * 3.4 + Vector3.UP * 1.1
			"behind": _cam.global_position = root - fwd * 3.4 + Vector3.UP * 1.5
			_: _cam.global_position = root + right * 4.2 + Vector3.UP * 1.0
		_cam.look_at(at, Vector3.UP)
	if _rec and not _pending.is_empty():
		var rec := _pending
		_pending = {}
		if _n % EVERY == 0 and _label != "" and not _label.begins_with("@"):
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var sz := img.get_size()
			var crop := img.get_region(Rect2i((sz.x - CROP.x) / 2, (sz.y - CROP.y) / 2, CROP.x, CROP.y))
			var name := "f%05d.png" % _shot
			crop.save_png(out_dir.path_join(name))
			rec["image"] = name
			_shot += 1
		_frames.append(rec)
		_n += 1


func _on_posed() -> void:
	if not _rec or _label == "" or (_label.begins_with("@") and not main.args.has("rec-all")):
		return
	var sk := _c.skeleton
	var bones := {}
	for b in BONES:
		var i: int = _ids[b]
		if i >= 0:
			var p := (sk.global_transform * sk.get_bone_global_pose(i)).origin
			bones[b] = [p.x, p.y, p.z]
	var st: Dictionary = _r.world.physics.call("character_gait_state", _r._id) if _r else {}
	_pending = {"t": Engine.get_physics_frames(), "label": _label, "bones": bones,
			"aim": float(_bot.live_yaw), "body": _c.state.body_yaw, "state": MotorState.Id.keys()[_c.state.state],
			"vel": [_c.state.vel.x, _c.state.vel.z], "pos": [_c.state.pos.x, _c.state.pos.y, _c.state.pos.z],
			"planted_l": bool(st.get("planted_l", true)), "planted_r": bool(st.get("planted_r", true)),
			"stepping": bool(st.get("stepping", false)), "gait_on": _r != null and _r.gait,
			"twist": _r.torso_twist if _r else 0.0, "pelvis_turn": float(st.get("pelvis_turn", 0.0)), "drop": float(st.get("pelvis_drop", 0.0)),
			"cadence": float(st.get("cadence", 0.0)), "dirw": float(st.get("clip_dirw", -1.0)),
			"step_max": float(st.get("step_max", 0.0)), "sink": _sinks(bones)}


## How far each toe / heel is under the ground beneath it (m, + = into it), probed in Sinew's world.
func _sinks(bones: Dictionary) -> Array:
	var out := []
	for side in ["Left", "Right"]:
		if not bones.has(side + "Toes") or not bones.has(side + "Foot"):
			continue
		var toe := Vector3(bones[side + "Toes"][0], bones[side + "Toes"][1], bones[side + "Toes"][2])
		var ankle := Vector3(bones[side + "Foot"][0], bones[side + "Foot"][1], bones[side + "Foot"][2])
		var along := Vector3(toe.x - ankle.x, 0.0, toe.z - ankle.z)
		along = along.normalized() if along.length() > 1e-3 else Vector3.ZERO
		# Sole points: toe tip (past the toe joint), under the ankle, the heel (behind the ankle).
		var pts := [[toe + (toe - ankle) * 0.6, 0.03], [ankle, 0.08], [ankle - along * 0.06, 0.08]]
		for pt: Array in pts:
			var p: Vector3 = pt[0]
			var hit: Dictionary = _r.world.physics.call("ground_below", p + Vector3.UP * 0.45, 1.2)
			if bool(hit.get("hit", false)):
				out.append((hit.point as Vector3).y - (p.y - float(pt[1])))
	return out


func _finish() -> void:
	_rec = false
	var f := FileAccess.open(out_dir.path_join("frames.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"every": EVERY, "frames": _frames}))
	f.close()
	print("moves_review: %d ticks, %d frames -> %s" % [_frames.size(), _shot, out_dir])
