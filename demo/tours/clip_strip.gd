extends "res://demo/tours/tour_base.gd"
## Films clips as they are authored, for picking them: a bare mannequin (the imported model, the libraries loaded) plays
## each clip seeked to `--frames` evenly spaced times, filmed from its right side (or `--cam=front`), root motion kept in
## the pose. Shots `<clip>_<k>.png` (the clip's "/" as "_").
##   godot --path . --resolution 1280x720 -- --tour=clip_strip --clips=mixamo/LMM_Jump,Jump_Start --frames=8 --out=<dir>

const DIR := "res://assets/characters/mannequin/"
var _clips: Array[String] = []
var _frames := 8
var _model: Node3D
var _ap: AnimationPlayer
var _cam: Camera3D
var _front := false


func _build() -> void:
	out_dir = out_dir.replace("/m1", "/clip_strip")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--clips="):
			for c in a.trim_prefix("--clips=").split(","):
				_clips.append(c)
		elif a.begins_with("--frames="):
			_frames = maxi(int(a.trim_prefix("--frames=")), 2)
		elif a == "--cam=front":
			_front = true
	steps = [{"call": _setup, "t": 0.5}]
	for clip in _clips:
		for k in _frames:
			steps.append({"call": _seek.bind(clip, float(k) / float(_frames - 1)), "t": 0.15,
					"shot": "%s_%d" % [clip.replace("/", "_"), k]})


func _setup() -> void:
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	main.player.visible = false
	_model = (load(DIR + "mannequin.glb") as PackedScene).instantiate() as Node3D
	main.add_child(_model)
	_model.global_position = Vector3(0, 0.05, -40)
	_ap = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _ap == null:
		_ap = AnimationPlayer.new()
		_model.add_child(_ap)
	_ap.root_node = _ap.get_path_to(_model)
	for lib in ["mixamo", "ual", "blender"]:
		var path := DIR + "anims/%s.res" % lib
		if ResourceLoader.exists(path) and not _ap.has_animation_library(lib):
			_ap.add_animation_library(lib, load(path))
	_cam = Camera3D.new()
	main.add_child(_cam)
	_cam.fov = 40.0
	_cam.current = true
	# (The model faces +Z: its right is -X.)
	_cam.global_position = _model.global_position + (Vector3(0, 1.1, 5.5) if _front else Vector3(-5.5, 1.1, 0.4))
	_cam.look_at(_model.global_position + Vector3(0, 0.9, 0.4), Vector3.UP)


func _seek(clip: String, frac: float) -> void:
	var name := clip if clip.contains("/") else "ual/" + clip
	if not _ap.has_animation(name):
		push_warning("clip_strip: no clip " + name)
		return
	_ap.play(name)
	_ap.seek(_ap.current_animation_length * frac, true)
	_ap.pause()
