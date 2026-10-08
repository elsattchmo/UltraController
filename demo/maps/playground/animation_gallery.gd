extends Node3D
## A mannequin per clip, each looping its animation under a name label. Only mannequins near
## the active camera animate, so the gallery costs little when you're elsewhere.
## Libraries added through intake (Mixamo / Blender) show up in their own rows. The grid is kept roughly square (as
## many per row as it takes) and the floor under it (the level's GalleryFloor) is sized to it at load, so every
## intake's clips stand on floor.

@export var body_profile: BodyProfile = preload("res://assets/characters/mannequin/mannequin_body_profile.tres")
@export var spacing := 2.6
@export var per_row := 12        ## at least this many a row (more when there are many clips: see _ready)
@export var active_radius := 22.0

var _entries: Array = []   # [Node3D, AnimationPlayer, StringName]


func _ready() -> void:
	if DisplayServer.get_name() == "headless" and not OS.get_cmdline_user_args().has("--gallery"):
		return
	build()


## Puts out the mannequins and fits the floor (headless only on request: tests, --gallery).
func build() -> void:
	if not _entries.is_empty():
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
	# (Rows run west: 12 a row put 600+ clips 220 m out. As square as the spacing allows.)
	var cols := maxi(per_row, ceili(sqrt(clips.size() * 1.6)))
	for i in clips.size():
		var row := i / cols
		var col := i % cols
		var holder := Node3D.new()
		holder.position = Vector3(-row * spacing * 1.6, 0.1, (col - cols * 0.5) * spacing)
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
	_fit_floor(ceili(clips.size() / float(cols)), cols)


## The level's gallery floor under every row (+ a margin), its top where it was.
func _fit_floor(rows: int, cols: int) -> void:
	var floor_body := get_parent().get_node_or_null("GalleryFloor") as StaticBody3D
	if floor_body == null:
		return
	const MARGIN := 6.0
	var top := floor_body.global_position.y + _floor_size(floor_body).y * 0.5
	var east := global_position.x + MARGIN
	var west := global_position.x - (rows - 1) * spacing * 1.6 - MARGIN
	var half_z := cols * spacing * 0.5 + MARGIN
	var east_now := floor_body.global_position.x + _floor_size(floor_body).x * 0.5
	east = maxf(east, east_now)              # (never pull it back from where the level put it)
	var size := Vector3(east - west, _floor_size(floor_body).y, maxf(half_z * 2.0, _floor_size(floor_body).z))
	floor_body.global_position = Vector3((east + west) * 0.5, top - size.y * 0.5, global_position.z)
	for c in floor_body.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is BoxMesh:
			var m := ((c as MeshInstance3D).mesh as BoxMesh).duplicate() as BoxMesh
			m.size = size
			(c as MeshInstance3D).mesh = m
		elif c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			var b := ((c as CollisionShape3D).shape as BoxShape3D).duplicate() as BoxShape3D
			b.size = size
			(c as CollisionShape3D).shape = b


func _floor_size(floor_body: StaticBody3D) -> Vector3:
	for c in floor_body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			return ((c as CollisionShape3D).shape as BoxShape3D).size
	return Vector3(60, 0.1, 80)


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
