extends SceneTree
## Close-up renders of the pistol in the posed hand (windowed):
##   godot --path . --resolution 900x700 --script res://tools/probe/grip_shot.gd -- --clip=Pistol_Aim_Neutral --t=0.1
## Writes C:/Dev/verify/ultra/review/grip/<clip>_<view>.png

var _frames := 0
var _views := []
var _cam: Camera3D
var _sk: Skeleton3D
var _clip := ""


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	_clip = String(args.get("clip", "Pistol_Aim_Neutral"))
	var t := float(args.get("t", "0.1"))
	var w := Node3D.new()
	root.add_child(w)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.35, 0.4, 0.48)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	env.environment = e
	w.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	w.add_child(sun)
	var scene: Node3D = (load("res://assets/characters/mannequin/mannequin.glb") as PackedScene).instantiate()
	w.add_child(scene)
	_sk = scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load("res://assets/characters/mannequin/anims/ual.res")
	var ap := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap:
		ap.stop()
	if args.has("fit"):
		UltraPoseSampler.pose(lib.get_animation("Pistol_Aim_Neutral"), _sk, 0.1)
	var def: Resource = load("res://assets/items/pistol/pistol_item.tres")
	var att := BoneAttachment3D.new()
	att.bone_name = "RightHand"
	_sk.add_child(att)
	var gun := (def.get("equip_scene") as PackedScene).instantiate() as Node3D
	att.add_child(gun)
	gun.transform = UltraGripFit.fit(_sk, gun) if args.has("fit") else def.get("grip_offset")
	if args.has("fit"):
		print("FIT grip_offset ", gun.transform)
		_clip += "_fit"
	UltraPoseSampler.pose(lib.get_animation(_clip.trim_suffix("_fit")), _sk, t)
	_clip += "_t%02d" % int(t * 10)
	_cam = Camera3D.new()
	_cam.fov = 35
	_cam.near = 0.01
	w.add_child(_cam)
	_views = [["right", Vector3(-0.55, 0.05, 0.15)], ["left", Vector3(0.55, 0.1, 0.15)]] if args.has("two") else [["right", Vector3(-0.45, 0.05, 0.15)], ["left", Vector3(0.45, 0.1, 0.15)], ["top", Vector3(-0.05, 0.45, 0.1)], ["front", Vector3(-0.1, 0.05, 0.5)], ["below", Vector3(-0.15, -0.4, 0.15)]]
	DirAccess.make_dir_recursive_absolute("C:/Dev/verify/ultra/review/grip")
	process_frame.connect(_tick)


func _tick() -> void:
	_frames += 1
	var hand := _sk.global_transform * _sk.get_bone_global_pose(_sk.find_bone("RightHand"))
	var i := _frames / 4 - 1
	if _frames % 4 == 1 and i >= 0 and i <= _views.size():
		if i > 0:
			var img := root.get_texture().get_image()
			img.save_png("C:/Dev/verify/ultra/review/grip/%s_%s.png" % [_clip, _views[i - 1][0]])
		if i == _views.size():
			quit()
			return
		var c := hand.origin + Vector3(0, 0, 0.06)
		_cam.global_position = c + _views[i][1]
		_cam.look_at(c, Vector3.UP if absf(_views[i][1].normalized().y) < 0.9 else Vector3.FORWARD)
