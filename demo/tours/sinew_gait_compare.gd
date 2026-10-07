extends "res://demo/tours/tour_base.gd"
## Gait comparison capture: the player walks / jogs / sprints straight down the speed track, filmed
## side on by an ORTHOGRAPHIC camera locked to the character (so frames of two runs line up exactly),
## every frame saved as a crop plus every frame's bone positions (read at skeleton_updated) to
## frames.json. Run it twice - the reference clips as authored (gait off) and Sinew's gait - then
## tools/sinew/gait_compare.py pairs the frames by stride phase (left-foot contacts found in the bones
## themselves), makes side-by-side strips and overlays, and prints per-phase joint angles.
##   godot --path . --fixed-fps 60 --resolution 1280x720 -- --tour=sinew_gait_compare --controller=sinew
##         --no-kit --gaitcmp=clip|gait --pace=walk|jog|sprint --out=<dir>
## (--fixed-fps: every frame is one physics tick whatever the grabs cost.)

const BONES := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]
const WARMUP := 2.5          ## s up to speed before capturing
const CAPTURE := 3.0         ## s captured
const ORTHO := 2.6           ## m of view, top to bottom
const CROP := Vector2i(560, 720)

var _cam: Camera3D
var _c: UltraCharacter
var _mode := "gait"
var _pace := "walk"
var _frames: Array = []
var _bone_ids: Array[int] = []
var _capturing := false
var _n := 0
var _pending: Dictionary = {}


func _build() -> void:
	_mode = String(main.args.get("gaitcmp", "gait"))
	_pace = String(main.args.get("pace", "walk"))
	out_dir = out_dir.replace("/m1", "/sinew_gait_compare/%s_%s" % [_pace, _mode])
	var buttons := InputFrame.B_SPRINT if _pace == "sprint" else 0
	steps = [
		{"teleport": "speed_start", "t": 0.6, "yaw": 0, "pitch": -4, "view_tp": true, "slot": 0},
		{"call": _setup, "t": 0.5},
		# (Counted in physics frames: the tour's clock is real time, and frame grabs are slow.)
		{"call": _mark, "t": 600.0, "move": Vector2(0, 1), "yaw": 0, "buttons": buttons,
				"until": func() -> bool: return Engine.get_physics_frames() - _f0 >= int(WARMUP * 60.0)},
		{"call": _start, "t": 600.0, "move": Vector2(0, 1), "yaw": 0, "buttons": buttons,
				"until": func() -> bool: return _n >= int(CAPTURE * 60.0)},
		{"call": _finish, "t": 0.2},
	]


func _setup() -> void:
	_c = main.player
	if _c is SinewCharacter:
		(_c as SinewCharacter).physical_motion = false       # (the motor's motion: only the animation differs)
	var r := _c.ragdoll as SinewRagdoll
	if r:
		r.gait = _mode == "gait"
		r._setup_gait()
	if _pace == "jog":
		_c.profile.default_gait = MovementProfile.Gait.JOG
	# Nothing over the picture (the HUD's hotbar covered the feet).
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = ORTHO
	_cam.current = true
	var sk := _c.skeleton
	for b in BONES:
		_bone_ids.append(sk.find_bone(b))
	sk.skeleton_updated.connect(_on_posed)


var _f0 := 0


func _mark() -> void:
	_f0 = Engine.get_physics_frames()


func _start() -> void:
	_capturing = true


func _process(delta: float) -> void:
	super._process(delta)
	if _cam and _c and _c.visual_root:
		var root := _c.visual_root.global_position
		_cam.global_position = root + Vector3(4.0, 0.95, 0.0)
		_cam.look_at(root + Vector3(0.0, 0.95, 0.0), Vector3.UP)
	if _capturing and not _pending.is_empty():
		var rec := _pending
		_pending = {}
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var sz := img.get_size()
		var rect := Rect2i((sz.x - CROP.x) / 2, (sz.y - CROP.y) / 2, CROP.x, CROP.y)
		var crop := img.get_region(rect)
		var name := "f%04d.png" % _n
		crop.save_png(out_dir.path_join(name))
		rec["image"] = name
		_frames.append(rec)
		_n += 1


## The posed bones (the only time the modified pose can be read), in the character's frame:
## x = to its right, y = up from its ground point, z = forward.
func _on_posed() -> void:
	if not _capturing:
		return
	var sk := _c.skeleton
	var root := _c.visual_root.global_transform
	var yaw := Basis(Vector3.UP, _c.state.body_yaw)
	var fwd := yaw * Vector3(0, 0, -1)
	var right := yaw * Vector3(1, 0, 0)
	var bones := {}
	for k in BONES.size():
		var b: int = _bone_ids[k]
		if b < 0:
			continue
		var p := (sk.global_transform * sk.get_bone_global_pose(b)).origin - root.origin
		bones[BONES[k]] = [p.dot(right), p.y, p.dot(fwd)]
	var r := _c.ragdoll as SinewRagdoll
	var st: Dictionary = r.world.physics.call("character_gait_state", r._id) if r and _mode == "gait" else {}
	_pending = {"t": Engine.get_physics_frames(), "speed": Vector2(_c.state.vel.x, _c.state.vel.z).length(),
			"bones": bones, "gait_phase": float(st.get("phase", -1.0))}
	if st.has("ankle_l"):
		# The gait's own ankle target (the leg's IK goal), same frame as the bones.
		var a: Vector3 = (st.ankle_l as Vector3) - root.origin
		_pending["ankle_target_l"] = [a.dot(right), a.y, a.dot(fwd)]


func _finish() -> void:
	_capturing = false
	var f := FileAccess.open(out_dir.path_join("frames.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"mode": _mode, "pace": _pace, "ortho": ORTHO, "crop": [CROP.x, CROP.y],
			"view_px": 720, "frames": _frames}))
	f.close()
	print("gait_compare: %d frames -> %s" % [_frames.size(), out_dir])
