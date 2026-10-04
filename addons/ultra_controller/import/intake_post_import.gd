@tool
extends EditorScenePostImport
## Post-import for animation intake (Mixamo FBX in intake/mixamo, Blender GLB in intake/blender).
## The importer has already retargeted the clip onto SkeletonProfileHumanoid (bone map set
## by tools/intake.gd). Here each clip is:
##   * named after its file (Mixamo calls every clip "mixamo.com"); "_loop" suffix -> looping
##   * made in place: forward drift of the Hips is removed (sway kept), unless the file name
##     contains "_RM", in which case that drift is baked into a RootMotionCurve instead
##   * trimmed of rest-constant / duplicate tracks
##   * merged into assets/characters/mannequin/anims/<mixamo|blender>.res

const LIB_DIR := "res://assets/characters/mannequin/anims/"
const RM_DIR := "res://assets/characters/mannequin/rootmotion/"
const HIPS := "%GeneralSkeleton:Hips"
## Mannequin hip height: normalised position tracks are multiplied by this on playback.
const TARGET_MOTION_SCALE := 0.9167


func _post_import(scene: Node) -> Object:
	var src := get_source_file()
	var lib_name := "mixamo" if src.contains("/intake/mixamo/") else "blender"
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var player := scene.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if skel == null or player == null:
		push_warning("UltraController intake: %s has no retargeted skeleton or no animation" % src)
		return scene
	var lib_path := LIB_DIR + lib_name + ".res"
	var lib: AnimationLibrary = load(lib_path) if ResourceLoader.exists(lib_path) else AnimationLibrary.new()
	var base := src.get_file().get_basename()
	var real: Array[StringName] = []
	for n in player.get_animation_list():
		if n != &"RESET" and n != &"T-Pose":
			real.append(n)
	for n in real:
		var a := (player.get_animation(n) as Animation).duplicate(true) as Animation
		var clip := base if real.size() == 1 else "%s_%s" % [base, n]
		var looped := clip.ends_with("_loop")
		clip = clip.trim_suffix("_loop")
		var rm := clip.contains("_RM")
		_fix_root(a, StringName(clip), rm)
		UltraImportTools.clean_tracks(a, skel)
		a.loop_mode = Animation.LOOP_LINEAR if looped or UltraImportTools.loop_mode_for(clip) == Animation.LOOP_LINEAR else Animation.LOOP_NONE
		if lib.has_animation(clip):
			lib.remove_animation(clip)
		lib.add_animation(clip, a)
		print("UltraController intake: %s -> %s/%s (%.2fs, loop %s, root motion %s)" % [src.get_file(), lib_name, clip, a.length, a.loop_mode != 0, rm])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LIB_DIR))
	ResourceSaver.save(lib, lib_path)
	for l in player.get_animation_library_list():
		player.remove_animation_library(l)
	return scene


## Remove the Hips' net travel (keep sway); bake it as root motion for "_RM" clips.
func _fix_root(a: Animation, clip: StringName, bake: bool) -> void:
	var t := a.find_track(NodePath(HIPS), Animation.TYPE_POSITION_3D)
	if t < 0 or a.track_get_key_count(t) < 2:
		return
	var n := a.track_get_key_count(t)
	var p0: Vector3 = a.track_get_key_value(t, 0)
	var p1: Vector3 = a.track_get_key_value(t, n - 1)
	var travel := Vector2(p1.x - p0.x, p1.z - p0.z) * TARGET_MOTION_SCALE
	if travel.length() < 0.2:
		return
	if bake:
		var c := RootMotionCurve.new()
		c.clip = StringName("%s" % clip)
		c.length = a.length
		c.sample_rate = 60.0
		for i in int(ceil(a.length * 60.0)) + 1:
			var tt := minf(i / 60.0, a.length)
			var p := (a.position_track_interpolate(t, tt) - p0) * TARGET_MOTION_SCALE
			c.positions.append(Vector3(-p.x, 0.0, -p.z))       # model +Z forward -> character -Z
			c.yaws.append(0.0)
		ResourceSaver.save(c, RM_DIR + String(clip) + ".tres")
	for k in n:
		var tt := a.track_get_key_time(t, k)
		var p: Vector3 = a.track_get_key_value(t, k)
		if bake:
			p.x = p0.x
			p.z = p0.z
		else:
			var lin := p0.lerp(p1, tt / maxf(a.length, 0.001))
			p.x -= lin.x - p0.x
			p.z -= lin.z - p0.z
		a.track_set_key_value(t, k, p)
