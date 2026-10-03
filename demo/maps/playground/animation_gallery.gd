extends Node3D
## A mannequin per clip, each looping its animation under a name label. Only mannequins near
## the active camera animate, so the gallery costs little when you're elsewhere.
## Libraries added through intake (Mixamo / Blender) show up in their own rows.

@export var body_profile: BodyProfile = preload("res://assets/characters/mannequin/mannequin_body_profile.tres")
@export var spacing := 2.6
@export var per_row := 12
@export var active_radius := 22.0

var _entries: Array = []   # [Node3D, AnimationPlayer, StringName]


func _ready() -> void:
	if DisplayServer.get_name() == "headless" and not OS.get_cmdline_user_args().has("--gallery"):
		return
	var clips: Array[StringName] = []
	for n in body_profile.library.get_animation_list():
		if n != &"RESET":
			clips.append(n)
	var libs := {"": body_profile.library}
	for k: String in body_profile.extra_libraries:
		libs[k] = body_profile.extra_libraries[k]
		for n in (libs[k] as AnimationLibrary).get_animation_list():
			clips.append(StringName(k + "/" + n))
	for i in clips.size():
		var row := i / per_row
		var col := i % per_row
		var holder := Node3D.new()
		holder.position = Vector3(-row * spacing * 1.6, 0.1, (col - per_row * 0.5) * spacing)
		holder.rotation.y = -PI * 0.5
		add_child(holder)
		var body := body_profile.body_scene.instantiate() as Node3D
		if body_profile.model_faces_positive_z:
			body.rotation.y = PI
		holder.add_child(body)
		var ap := body.find_child("AnimationPlayer", true, false) as AnimationPlayer
		# Loop one-shots by replaying (never edit the shared clip's loop mode).
		ap.animation_finished.connect(func(n: StringName) -> void: ap.play(n))
		for k: String in libs:
			if not ap.has_animation_library(k):
				ap.add_animation_library(k, libs[k])
		var l := Label3D.new()
		l.text = String(clips[i])
		l.position = Vector3(0, 2.15, 0)
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 40
		l.outline_size = 10
		l.pixel_size = 0.005
		holder.add_child(l)
		_entries.append([holder, ap, clips[i]])


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for e: Array in _entries:
		var holder: Node3D = e[0]
		var ap: AnimationPlayer = e[1]
		var near := holder.global_position.distance_to(cam.global_position) < active_radius
		if near and not ap.is_playing():
			ap.play(e[2])
		elif not near and ap.is_playing():
			ap.pause()
