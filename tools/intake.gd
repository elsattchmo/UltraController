extends Node
## Animation intake (run by tools/intake.sh, or Project > Tools > Ultra > Process animation intake).
##   --mode=prepare   point every intake file's .import at the humanoid bone map + intake script
##   --mode=finalize  register the resulting libraries on the mannequin BodyProfile
## Drop Mixamo FBX files in intake/mixamo/ (name them Clip_loop.fbx to loop, Clip_RM.fbx for
## root motion) and Blender exports in intake/blender/ (tools/blender/ultra_blender.py).

const DIRS := {
	"res://intake/mixamo/": ["res://addons/ultra_controller/import/bone_maps/mixamo_humanoid.tres", false],
	"res://intake/blender/": ["res://addons/ultra_controller/import/bone_maps/ue_mannequin_humanoid.tres", false],
}
const POST := "res://addons/ultra_controller/import/intake_post_import.gd"
const BODY := "res://assets/characters/mannequin/mannequin_body_profile.tres"
const LIBS := "res://assets/characters/mannequin/anims/"


func _ready() -> void:
	match UltraArgs.get_str("mode", "prepare"):
		"prepare":
			print("intake: prepared %d files" % prepare())
		"finalize":
			finalize()


static func prepare() -> int:
	var n := 0
	for dir: String in DIRS:
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in DirAccess.get_files_at(dir):
			var ext := f.get_extension().to_lower()
			if ext not in ["fbx", "glb", "gltf"]:
				continue
			if configure(dir + f, DIRS[dir][0], DIRS[dir][1]):
				n += 1
	return n


## Rewrite one intake file's .import. Returns true if it changed (needs a reimport).
static func configure(src: String, bone_map: String, fix_silhouette: bool) -> bool:
	var imp := src + ".import"
	var cfg := ConfigFile.new()
	if cfg.load(imp) != OK:
		push_warning("intake: %s has not been imported yet (run --import first)" % src)
		return false
	if cfg.get_value("params", "import_script/path", "") == POST:
		return false
	var scene := load(src) as PackedScene
	var skel_path := "Skeleton3D"
	var hips_name := ""
	if scene:
		var root := scene.instantiate()
		var sk := root.find_children("*", "Skeleton3D", true, false)
		if not sk.is_empty():
			skel_path = str(root.get_path_to(sk[0]))
			for b in (sk[0] as Skeleton3D).get_bone_count():
				var bn := (sk[0] as Skeleton3D).get_bone_name(b)
				if bn.ends_with("Hips"):
					hips_name = bn
					break
		root.free()
	bone_map = _map_for_prefix(bone_map, hips_name)
	cfg.set_value("params", "animation/import", true)
	cfg.set_value("params", "animation/remove_immutable_tracks", false)
	cfg.set_value("params", "animation/import_rest_as_RESET", false)
	cfg.set_value("params", "import_script/path", POST)
	cfg.set_value("params", "_subresources", {"nodes": {"PATH:" + skel_path: {
		"retarget/bone_map": load(bone_map),
		"retarget/bone_renamer/rename_bones": true,
		"retarget/bone_renamer/unique_node/make_unique": true,
		"retarget/bone_renamer/unique_node/skeleton_name": "GeneralSkeleton",
		"retarget/remove_tracks/unmapped_bones": true,
		"retarget/rest_fixer/apply_node_transforms": true,
		"retarget/rest_fixer/normalize_position_tracks": true,
		"retarget/rest_fixer/reset_all_bone_poses_after_import": true,
		"retarget/rest_fixer/overwrite_axis": true,
		"retarget/rest_fixer/fix_silhouette/enable": fix_silhouette,
	}}})
	cfg.save(imp)
	# Force the next --import to redo it.
	var cache := ProjectSettings.globalize_path("res://.godot/imported/")
	for f in DirAccess.get_files_at(cache):
		if f.begins_with(src.get_file() + "-"):
			DirAccess.remove_absolute(cache + f)
	print("intake: configured %s (skeleton %s)" % [src, skel_path])
	return true


## Mixamo names bones per character: "mixamorig:Hips", "mixamorig1:Hips", ... (":" becomes
## "_" on import). Make (once) a copy of the bone map for this file's prefix.
static func _map_for_prefix(bone_map: String, hips_name: String) -> String:
	var bm := load(bone_map) as BoneMap
	if bm == null or hips_name == "":
		return bone_map
	var mapped := String(bm.get_skeleton_bone_name(&"Hips"))
	if mapped == hips_name or not mapped.ends_with("Hips"):
		return bone_map
	var old_prefix := mapped.trim_suffix("Hips")
	var new_prefix := hips_name.trim_suffix("Hips")
	var out_path := bone_map.get_base_dir().path_join("%s_%s.tres" % [bone_map.get_file().get_basename(), new_prefix.trim_suffix("_").validate_filename()])
	if ResourceLoader.exists(out_path):
		return out_path
	var nm := bm.duplicate() as BoneMap
	var prof := nm.profile
	for i in prof.bone_size:
		var pb := prof.get_bone_name(i)
		var sb := String(nm.get_skeleton_bone_name(pb))
		if sb.begins_with(old_prefix):
			nm.set_skeleton_bone_name(pb, StringName(new_prefix + sb.trim_prefix(old_prefix)))
	ResourceSaver.save(nm, out_path)
	print("intake: made bone map %s for prefix '%s'" % [out_path, new_prefix])
	return out_path


static func finalize() -> void:
	var body: BodyProfile = load(BODY)
	var extra := {}
	for lib: String in ["mixamo", "blender"]:
		var p := LIBS + lib + ".res"
		if ResourceLoader.exists(p):
			var l: AnimationLibrary = load(p)
			extra[lib] = l
			print("intake: library %s has %d clips: %s" % [lib, l.get_animation_list().size(), l.get_animation_list()])
	body.extra_libraries = extra
	ResourceSaver.save(body, BODY)
	print("intake: registered %d libraries on the mannequin" % extra.size())
