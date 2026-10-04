extends Node
## Builds item definitions. The pistol's grip comes from the Blender fit (art_src/pistol_fit.json:
## the gun's pose in model space while the mannequin plays Pistol_Idle), re-expressed in Godot's
## retargeted RightHand frame, so it sits exactly where it was fitted.
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/build_items.gd

const MANNEQUIN := "res://assets/characters/mannequin/"


func _ready() -> void:
	var scene: Node = (load(MANNEQUIN + "mannequin.glb") as PackedScene).instantiate()
	add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load(MANNEQUIN + "anims/ual.res")
	_world_scenes_first()
	_pistol(skel, lib)
	_ammo()
	_misc()
	_keys()
	scene.queue_free()


## World (pickup) scenes: a WorldItem rigid body with a visual and a box collider.
func _world_scene(path: String, item_id: StringName, visual: Node3D, box: Vector3, center := Vector3.ZERO) -> PackedScene:
	var rb := RigidBody3D.new()
	rb.name = String(item_id).capitalize().replace(" ", "")
	rb.set_script(load("res://addons/ultra_controller/items/world_item.gd"))
	rb.set("item_id", item_id)
	rb.add_child(visual)
	visual.owner = rb
	for c in visual.find_children("*"):
		if c.owner == null:
			c.owner = rb
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var bs := BoxShape3D.new()
	bs.size = box
	cs.shape = bs
	cs.position = center
	rb.add_child(cs)
	cs.owner = rb
	var ps := PackedScene.new()
	ps.pack(rb)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	ResourceSaver.save(ps, path)
	return ps


func _box_visual(size: Vector3, color: Color, emission := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Visual"
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.3
	m.roughness = 0.5
	if emission:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 0.6
	mi.material_override = m
	return mi


func _world_scenes_first() -> void:
	var gun := (load("res://assets/items/pistol/pistol.glb") as PackedScene).instantiate() as Node3D
	gun.name = "Visual"
	_world_scene("res://assets/items/pistol/pistol_world.tscn", &"pistol", gun, Vector3(0.04, 0.14, 0.2), Vector3(0, 0.0, 0.0))
	_world_scene("res://assets/items/ammo/ammo_9mm_world.tscn", &"ammo_9mm", _box_visual(Vector3(0.14, 0.07, 0.09), Color(0.25, 0.35, 0.15)), Vector3(0.14, 0.07, 0.09))
	_world_scene("res://assets/items/medkit/medkit_world.tscn", &"medkit", _box_visual(Vector3(0.22, 0.09, 0.16), Color(0.9, 0.9, 0.9)), Vector3(0.22, 0.09, 0.16))
	for k in [["red", Color(0.9, 0.15, 0.1)], ["blue", Color(0.15, 0.35, 0.95)], ["green", Color(0.15, 0.8, 0.25)]]:
		_world_scene("res://assets/items/keys/key_%s_world.tscn" % k[0], StringName("key_" + k[0]), _box_visual(Vector3(0.09, 0.025, 0.035), k[1], true), Vector3(0.09, 0.03, 0.04))


func _keys() -> void:
	for k in [["red", "Red key", "the vault"], ["blue", "Blue key", "the flooded store"], ["green", "Green key", "the high storeroom"]]:
		var d := ItemDefinition.new()
		d.id = StringName("key_" + k[0])
		d.display_name = k[1]
		d.description = "Opens %s." % k[2]
		d.kind = ItemDefinition.Kind.KEY
		d.key_id = StringName(k[0])
		d.mass = 0.05
		d.world_scene = load("res://assets/items/keys/key_%s_world.tscn" % k[0])
		ResourceSaver.save(d, "res://assets/items/keys/key_%s_item.tres" % k[0])
	print("saved keys")


func _pistol(skel: Skeleton3D, lib: AnimationLibrary) -> void:
	var fit: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://art_src/pistol_fit.json")) if FileAccess.file_exists("res://art_src/pistol_fit.json") else {}
	var gun_model := Transform3D.IDENTITY
	if fit.has("gun_in_model_space_rows"):
		var r: Array = fit["gun_in_model_space_rows"]
		gun_model = Transform3D(
			Basis(Vector3(r[0][0], r[1][0], r[2][0]), Vector3(r[0][1], r[1][1], r[2][1]), Vector3(r[0][2], r[1][2], r[2][2])),
			Vector3(r[0][3], r[1][3], r[2][3]))
	else:
		push_warning("art_src/pistol_fit.json missing (art_src is not copied to verify); keeping existing offsets")
		return
	UltraPoseSampler.pose(lib.get_animation(fit.get("clip", "Pistol_Idle")), skel, float(fit.get("time", 0.0)))
	var rh := UltraPoseSampler.global_pose(skel, skel.find_bone("RightHand"))
	var lh := UltraPoseSampler.global_pose(skel, skel.find_bone("LeftHand"))
	var d := ItemDefinition.new()
	d.id = &"pistol"
	d.display_name = "Pistol"
	d.description = "Semi-automatic 9 mm pistol. 12-round magazine."
	d.kind = ItemDefinition.Kind.FIREARM
	d.mass = 0.85
	d.max_stack = 1
	d.equip_scene = load("res://assets/items/pistol/pistol.glb")
	d.world_scene = load("res://assets/items/pistol/pistol_world.tscn") if ResourceLoader.exists("res://assets/items/pistol/pistol_world.tscn") else null
	d.equip_slots = ItemDefinition.EquipSlot.MAIN_HAND | ItemDefinition.EquipSlot.HIP
	d.grip_offset = rh.affine_inverse() * gun_model
	d.support_offset = gun_model.affine_inverse() * lh
	d.two_handed = true
	# Right hip holster: in the Hips bone frame; barrel down, grip back and up.
	var hips := UltraPoseSampler.global_pose(skel, skel.find_bone("Hips"))
	# Skeleton space: +Z forward, +Y up, -X = character's right. Barrel down (-Z_gun = -Y),
	# slide facing forward (+Y_gun = +Z), sitting just outside the right hip.
	var holster_basis := Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
	var holster_model := Transform3D(holster_basis.rotated(Vector3.FORWARD, deg_to_rad(-8.0)), Vector3(-0.235, 0.84, 0.0))
	d.holster_offset = hips.affine_inverse() * holster_model
	d.anim_roles = {"idle": "pistol_idle", "aim": "pistol_aim_neutral", "aim_up": "pistol_aim_up", "aim_down": "pistol_aim_down", "fire": "pistol_shoot", "reload": "pistol_reload"}
	d.equip_time = 0.35
	d.stats = {
		"mag_size": 12, "fire_interval": 0.15, "damage": 34.0, "range": 120.0, "spread_deg": 0.8,
		"ads_spread_deg": 0.15, "reload_time": 2.08, "reload_commit": 1.55, "ammo": "ammo_9mm",
		"impulse": 6.0, "recoil_pitch_deg": 2.4, "recoil_yaw_deg": 0.6, "ads_fov": 55.0,
	}
	print("pistol grip_offset ", d.grip_offset)
	print("pistol support_offset ", d.support_offset)
	var err := ResourceSaver.save(d, "res://assets/items/pistol/pistol_item.tres")
	print("saved pistol item ", err)


func _ammo() -> void:
	var d := ItemDefinition.new()
	d.id = &"ammo_9mm"
	d.display_name = "9 mm rounds"
	d.kind = ItemDefinition.Kind.AMMO
	d.mass = 0.012
	d.max_stack = 120
	d.world_scene = load("res://assets/items/ammo/ammo_9mm_world.tscn")
	DirAccess.make_dir_recursive_absolute("res://assets/items/ammo")
	ResourceSaver.save(d, "res://assets/items/ammo/ammo_9mm_item.tres")


func _misc() -> void:
	var med := ItemDefinition.new()
	med.id = &"medkit"
	med.display_name = "Medkit"
	med.kind = ItemDefinition.Kind.CONSUMABLE
	med.mass = 0.6
	med.max_stack = 5
	med.consumable_heal = 50.0
	med.world_scene = load("res://assets/items/medkit/medkit_world.tscn")
	DirAccess.make_dir_recursive_absolute("res://assets/items/medkit")
	ResourceSaver.save(med, "res://assets/items/medkit/medkit_item.tres")
	print("saved ammo + medkit")
