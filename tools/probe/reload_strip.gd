extends SceneTree
## Contact strip of a clip with the pistol at its item grip (one viewport, re-posed per frame):
##   godot --path . --resolution 400x500 --script res://tools/probe/reload_strip.gd -- --clip=Pistol_Reload --n=6 [--side=-1]
## Writes C:/Dev/verify/ultra/review/grip/strip_<clip>[_L].png

var _frames := 0
var _i := 0
var _n := 6
var _sk: Skeleton3D
var _anim: Animation
var _clip := ""
var _side := 1.0
var _strip: Image


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	_clip = String(args.get("clip", "Pistol_Reload"))
	_n = int(args.get("n", "6"))
	_side = float(args.get("side", "1"))
	var lib: AnimationLibrary = load(String(args.get("lib", "res://assets/characters/mannequin/anims/ual.res")))
	_anim = lib.get_animation(_clip)
	_from = float(args.get("from", "0"))
	_to = float(args.get("to", str(_anim.length)))
	_gun = not args.has("nogun")
	var def: Resource = load("res://assets/items/pistol/pistol_item.tres")
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
	var ap := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap:
		ap.stop()
	var att := BoneAttachment3D.new()
	att.bone_name = "RightHand"
	_sk.add_child(att)
	if _gun:
		var gun := (def.get("equip_scene") as PackedScene).instantiate() as Node3D
		att.add_child(gun)
		gun.transform = def.get("grip_offset")
	_cam = Camera3D.new()
	_cam.fov = 30
	w.add_child(_cam)
	process_frame.connect(_tick)


var _cam: Camera3D
var _from := 0.0
var _to := 1.0
var _gun := true


func _tick() -> void:
	_frames += 1
	if _frames % 3 == 1:
		UltraPoseSampler.pose(_anim, _sk, lerpf(_from, _to, _i / maxf(_n - 1, 1)))
		var chest := _sk.global_transform * Vector3(0, 0.6, 0.1)
		var fwd := (_sk.global_basis * Vector3(0, 0, 1)).normalized()
		var right := (_sk.global_basis * Vector3(-1, 0, 0)).normalized()
		var h := 1.5
		_cam.global_position = chest + (fwd * 1.3 + right * 1.0 * _side) * h + Vector3.UP * 0.35 * h
		_cam.look_at(chest + fwd * 0.15 * h + Vector3.UP * 0.25 * h, Vector3.UP)
	elif _frames % 3 == 0:
		var img := root.get_texture().get_image()
		if _strip == null:
			_strip = Image.create(img.get_width() * _n, img.get_height(), false, img.get_format())
		_strip.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(img.get_width() * _i, 0))
		_i += 1
		if _i >= _n:
			DirAccess.make_dir_recursive_absolute("C:/Dev/verify/ultra/review/grip")
			_strip.save_png("C:/Dev/verify/ultra/review/grip/strip_%s%s.png" % [_clip, "" if _side > 0 else "_L"])
			quit()
