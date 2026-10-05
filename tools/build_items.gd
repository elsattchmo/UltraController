extends Node
## Builds item definitions. The pistol's grip is fitted to the posed hand (UltraGripFit); the
## Blender fit (art_src/pistol_fit.json) only placed the model originally. (Old note:
## the gun's pose in model space while the mannequin plays Pistol_Idle), re-expressed in Godot's
## retargeted RightHand frame, so it sits exactly where it was fitted.
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/build_items.gd

const MANNEQUIN := "res://assets/characters/mannequin/"
const RIFLE := "res://assets/items/rifle/"
const SHOTGUN := "res://assets/items/shotgun/"


func _ready() -> void:
	var scene: Node = (load(MANNEQUIN + "mannequin.glb") as PackedScene).instantiate()
	add_child(scene)
	var skel := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var lib: AnimationLibrary = load(MANNEQUIN + "anims/ual.res")
	_world_scenes_first()
	_pistol(skel, lib)
	_rifle(skel, lib)
	_shotgun(skel, lib)
	_melee(skel, lib)
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
	var rifle := (load(RIFLE + "rifle.glb") as PackedScene).instantiate() as Node3D
	rifle.name = "Visual"
	_world_scene(RIFLE + "rifle_world.tscn", &"rifle", rifle, Vector3(0.06, 0.2, 1.1), Vector3(0, 0.0, -0.17))
	_world_scene("res://assets/items/ammo/ammo_556_world.tscn", &"ammo_556", _box_visual(Vector3(0.18, 0.09, 0.11), Color(0.42, 0.36, 0.2)), Vector3(0.18, 0.09, 0.11))
	if ResourceLoader.exists(SHOTGUN + "shotgun.glb"):
		var sg := (load(SHOTGUN + "shotgun.glb") as PackedScene).instantiate() as Node3D
		sg.name = "Visual"
		_world_scene(SHOTGUN + "shotgun_world.tscn", &"shotgun", sg, Vector3(0.06, 0.2, 1.0), Vector3(0, 0.0, -0.15))
	for mw: Array in [["bat", Vector3(0.08, 0.08, 0.8), Vector3(0, 0.27, 0)], ["machete", Vector3(0.05, 0.06, 0.62), Vector3(0, 0.22, 0)]]:
		var path := "res://assets/items/%s/%s.glb" % [mw[0], mw[0]]
		if ResourceLoader.exists(path):
			var v := (load(path) as PackedScene).instantiate() as Node3D
			v.name = "Visual"
			_world_scene("res://assets/items/%s/%s_world.tscn" % [mw[0], mw[0]], StringName(mw[0]), v, Vector3(mw[1].x, mw[1].z, mw[1].y), mw[2])
	_world_scene("res://assets/items/ammo/ammo_12g_world.tscn", &"ammo_12g", _box_visual(Vector3(0.12, 0.08, 0.08), Color(0.6, 0.12, 0.08)), Vector3(0.12, 0.08, 0.08))
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
	# Grip from the hand itself (UltraGripFit): the handle through the curled fingers, the
	# trigger finger along the frame, in the aiming pose. The support hand keeps where the
	# aiming clip puts it relative to the gun.
	UltraPoseSampler.pose(lib.get_animation("Pistol_Aim_Neutral"), skel, 0.1)
	var gun_node := (load("res://assets/items/pistol/pistol.glb") as PackedScene).instantiate() as Node3D
	var rh := UltraPoseSampler.global_pose(skel, skel.find_bone("RightHand"))
	var lh := UltraPoseSampler.global_pose(skel, skel.find_bone("LeftHand"))
	var grip := UltraGripFit.fit(skel, gun_node)
	gun_node.free()
	var gun_model := rh * grip
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
	d.grip_offset = grip
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
	d.anim_clips = {"butt_pistol": ["mixamo/M_PistolStrike"]}           # (gun-butt: UltraActionLayer.melee_swing)
	d.equip_time = 0.35
	d.recoil_gun_deg = 3.0
	d.stats = {
		"mag_size": 12, "fire_interval": 0.15, "damage": 34.0, "range": 120.0, "spread_deg": 0.8,
		"ads_spread_deg": 0.15, "reload_time": 2.08, "reload_commit": 1.55, "ammo": "ammo_9mm",
		"impulse": 6.0, "recoil_pitch_deg": 3.4, "recoil_yaw_deg": 0.9, "ads_fov": 55.0, "smoke": 0.1,
	}
	print("pistol grip_offset ", d.grip_offset)
	print("pistol support_offset ", d.support_offset)
	var err := ResourceSaver.save(d, "res://assets/items/pistol/pistol_item.tres")
	print("saved pistol item ", err)


## Two-handed carbine: right hand fitted to the pistol grip (UltraGripFit, same as the pistol),
## left hand on the handguard - where Mixamo's rifle-aiming clip puts it if that clip is in and
## its hand is on the handguard, otherwise palm up under the handguard at M_SupportGrip.
## Slung across the back (UpperChest frame) when not in hand: muzzle up over the left shoulder.
func _rifle(skel: Skeleton3D, lib: AnimationLibrary) -> void:
	var mix: AnimationLibrary = load(MANNEQUIN + "anims/mixamo.res") if ResourceLoader.exists(MANNEQUIN + "anims/mixamo.res") else null
	var aim: Animation = null
	for n in ["Rifle_Idle_Aiming"]:
		if aim == null and mix and mix.has_animation(n):
			aim = mix.get_animation(n)
			print("rifle: grip from mixamo/", n)
	var from_clip := aim != null
	if aim == null:
		aim = lib.get_animation("Pistol_Aim_Neutral")
	UltraPoseSampler.pose(aim, skel, 0.1)
	var gun_node := (load(RIFLE + "rifle.glb") as PackedScene).instantiate() as Node3D
	var rh := UltraPoseSampler.global_pose(skel, skel.find_bone("RightHand"))
	var lh := UltraPoseSampler.global_pose(skel, skel.find_bone("LeftHand"))
	var grip := UltraGripFit.fit(skel, gun_node)
	var gun_model := rh * grip
	var contact := gun_model * UltraPoseSampler.marker(gun_node, "M_SupportGrip").origin
	var lh_gun := gun_model.affine_inverse() * lh.origin
	var bdir := -gun_model.basis.z.normalized()        # skeleton space: +Z forward, +X left
	var hips := UltraPoseSampler.global_pose(skel, skel.find_bone("Hips"))
	var aim_offset := Vector2(rad_to_deg(atan2(bdir.x, bdir.z)), rad_to_deg(asin(bdir.y)))
	print("rifle: barrel in the aiming pose: yaw %.1f deg (+ = left of the model's forward), pitch %.1f deg; hips yaw %.1f deg" % [aim_offset.x, aim_offset.y, rad_to_deg(atan2(hips.basis.z.x, hips.basis.z.z))])
	print("rifle: clip left hand in the gun frame ", lh_gun, " (support marker ", UltraPoseSampler.marker(gun_node, "M_SupportGrip").origin, ")")
	var support := gun_model.affine_inverse() * _support_hand(skel, gun_model, contact)
	if from_clip and absf(lh_gun.x) < 0.07 and lh_gun.y > -0.12 and lh_gun.y < 0.06 and lh_gun.z < -0.15 and lh_gun.z > -0.5:
		support = gun_model.affine_inverse() * lh
		print("rifle: support hand from the clip")
	gun_node.free()
	var d := ItemDefinition.new()
	d.id = &"rifle"
	d.display_name = "Carbine"
	d.description = "Select-fire 5.56 mm carbine. 30-round magazine."
	d.kind = ItemDefinition.Kind.FIREARM
	d.mass = 3.2
	d.max_stack = 1
	d.equip_scene = load(RIFLE + "rifle.glb")
	d.world_scene = load(RIFLE + "rifle_world.tscn") if ResourceLoader.exists(RIFLE + "rifle_world.tscn") else null
	d.equip_slots = ItemDefinition.EquipSlot.MAIN_HAND | ItemDefinition.EquipSlot.BACK
	d.grip_offset = grip
	d.support_offset = support
	d.two_handed = true
	# Support hand under the fore-end, fingers wrapped round its right side (WeaponPoseModifier).
	d.support_fingers = Vector3(0.55, 0.0, -0.8)
	d.support_palm = Vector3(0.2, 1.0, 0.0)
	# Back: UpperChest frame in an idle pose. Skeleton space: +Z forward, +Y up, +X = the
	# character's left. Muzzle up over the left shoulder, sights against the back.
	UltraPoseSampler.pose(lib.get_animation("Idle_A"), skel, 0.5)
	var chest := UltraPoseSampler.global_pose(skel, skel.find_bone("UpperChest"))
	var barrel := Vector3(0.62, 1.0, 0.0).normalized()
	var z := -barrel
	var y := (Vector3(0, 0, 1) - barrel * barrel.z).normalized()
	var b := Basis(y.cross(z), y, z)
	var centre_local := Vector3(0, 0.03, -0.17)
	var centre := Vector3(chest.origin.x - 0.02, chest.origin.y - 0.06, chest.origin.z - 0.17)
	d.holster_bone = &"UpperChest"
	d.holster_offset = chest.affine_inverse() * Transform3D(b, centre - b * centre_local)
	d.anim_roles = {"idle": "rifle_idle", "aim": "rifle_aim", "fire": "rifle_aim", "reload": "rifle_reload"}
	d.aim_clip_offset = aim_offset.snappedf(0.1) if from_clip else Vector2.ZERO
	d.anim_clips = {
		"rifle_idle": ["mixamo/Rifle_Idle", "Pistol_Idle"],
		"rifle_aim": ["mixamo/Rifle_Idle_Aiming", "Pistol_Aim_Neutral"],
		"rifle_reload": ["mixamo/Rifle_Reload", "Pistol_Reload"],
		"butt_long": ["mixamo/M_RiflePunch"],              # (gun-butt, long guns)
	}
	d.equip_time = 0.6
	d.fire_mode = ItemDefinition.FireMode.AUTO
	d.fp_hip_offset = Vector3(0.11, -0.13, 0.22)
	d.fp_ads_distance = 0.15
	d.fp_ads_eye = Vector3(0.035, -0.07, 0.03)        # cheek down onto the stock
	# Heavier than the pistol: more inertia, slower to settle, a wider free-aim zone.
	d.sway_inertia = 0.5
	d.sway_return_hz = 1.6
	d.sway_damping = 0.7
	d.free_aim_deg = 6.0
	d.sway_amount = 1.35
	d.ads_sway_mult = 0.3
	d.recoil_gun_deg = 1.8
	d.sprint_lower_deg = _carry_dir(skel, mix, grip, Vector2(14.0, -24.0))
	d.stats = {
		"mag_size": 30, "fire_interval": 0.092, "damage": 30.0, "range": 300.0, "spread_deg": 1.4,
		"ads_spread_deg": 0.06, "reload_time": 2.6, "reload_commit": 1.9, "ammo": "ammo_556",
		"impulse": 7.0, "recoil_pitch_deg": 1.35, "recoil_yaw_deg": 0.55, "ads_fov": 52.0, "smoke": 0.14, "shell": "556",
	}
	print("rifle grip_offset ", d.grip_offset)
	print("rifle support_offset ", d.support_offset)
	var err := ResourceSaver.save(d, RIFLE + "rifle_item.tres")
	print("saved rifle item ", err)
	var ammo := ItemDefinition.new()
	ammo.id = &"ammo_556"
	ammo.display_name = "5.56 mm rounds"
	ammo.kind = ItemDefinition.Kind.AMMO
	ammo.mass = 0.012
	ammo.max_stack = 180
	ammo.world_scene = load("res://assets/items/ammo/ammo_556_world.tscn")
	ResourceSaver.save(ammo, "res://assets/items/ammo/ammo_556_item.tres")


## 12-gauge pump-action: held like the carbine (same clips, same grip fit), the support hand on
## the pump (M_SupportGrip rides the "Pump" node). Nine pellets a shot, a tube of six loaded
## a shell at a time, a pump after every shot (UltraEquipmentVisual drives the pump and the
## loading hand; the timing is the simulation's).
func _shotgun(skel: Skeleton3D, lib: AnimationLibrary) -> void:
	if not ResourceLoader.exists(SHOTGUN + "shotgun.glb"):
		return
	var mix: AnimationLibrary = load(MANNEQUIN + "anims/mixamo.res") if ResourceLoader.exists(MANNEQUIN + "anims/mixamo.res") else null
	var aim: Animation = mix.get_animation("Rifle_Idle_Aiming") if mix and mix.has_animation("Rifle_Idle_Aiming") else lib.get_animation("Pistol_Aim_Neutral")
	UltraPoseSampler.pose(aim, skel, 0.1)
	var gun_node := (load(SHOTGUN + "shotgun.glb") as PackedScene).instantiate() as Node3D
	var rh := UltraPoseSampler.global_pose(skel, skel.find_bone("RightHand"))
	var grip := UltraGripFit.fit(skel, gun_node)
	var gun_model := rh * grip
	var contact := gun_model * UltraPoseSampler.marker(gun_node, "M_SupportGrip").origin
	var bdir := -gun_model.basis.z.normalized()
	var aim_offset := Vector2(rad_to_deg(atan2(bdir.x, bdir.z)), rad_to_deg(asin(bdir.y)))
	var support := gun_model.affine_inverse() * _support_hand(skel, gun_model, contact)
	gun_node.free()
	var d := ItemDefinition.new()
	d.id = &"shotgun"
	d.display_name = "Shotgun"
	d.description = "12-gauge pump-action. Six in the tube, loaded a shell at a time."
	d.kind = ItemDefinition.Kind.FIREARM
	d.mass = 3.6
	d.max_stack = 1
	d.equip_scene = load(SHOTGUN + "shotgun.glb")
	d.world_scene = load(SHOTGUN + "shotgun_world.tscn") if ResourceLoader.exists(SHOTGUN + "shotgun_world.tscn") else null
	d.equip_slots = ItemDefinition.EquipSlot.MAIN_HAND | ItemDefinition.EquipSlot.BACK
	d.grip_offset = grip
	d.support_offset = support
	d.two_handed = true
	d.support_fingers = Vector3(0.55, 0.0, -0.8)
	d.support_palm = Vector3(0.2, 1.0, 0.0)
	# Slung like the carbine (back, muzzle up over the left shoulder).
	UltraPoseSampler.pose(lib.get_animation("Idle_A"), skel, 0.5)
	var chest := UltraPoseSampler.global_pose(skel, skel.find_bone("UpperChest"))
	var barrel := Vector3(0.62, 1.0, 0.0).normalized()
	var z := -barrel
	var y := (Vector3(0, 0, 1) - barrel * barrel.z).normalized()
	var b := Basis(y.cross(z), y, z)
	var centre_local := Vector3(0, 0.03, -0.15)
	var centre := Vector3(chest.origin.x - 0.02, chest.origin.y - 0.06, chest.origin.z - 0.19)
	d.holster_bone = &"UpperChest"
	d.holster_offset = chest.affine_inverse() * Transform3D(b, centre - b * centre_local)
	# The carbine's clips; the reload keeps the low-ready pose (the loading hand is IK).
	d.anim_roles = {"idle": "rifle_idle", "aim": "rifle_aim", "fire": "rifle_aim", "reload": "rifle_idle"}
	d.aim_clip_offset = aim_offset.snappedf(0.1)
	d.equip_time = 0.7
	d.fire_mode = ItemDefinition.FireMode.SEMI
	d.fp_hip_offset = Vector3(0.11, -0.13, 0.22)
	d.fp_ads_distance = 0.17
	d.fp_ads_eye = Vector3(0.035, -0.06, 0.03)
	d.sway_inertia = 0.55
	d.sway_return_hz = 1.5
	d.sway_damping = 0.65
	d.free_aim_deg = 6.0
	d.sway_amount = 1.4
	d.ads_sway_mult = 0.35
	# A real shove: the gun climbs a lot and comes back slowly.
	d.recoil_gun_deg = 11.0
	d.sprint_lower_deg = _carry_dir(skel, mix, grip, Vector2(14.0, -24.0))
	d.stats = {
		"mag_size": 6, "fire_interval": 1.15, "pellets": 9, "damage": 14.0, "pellet_spread_deg": 2.2,
		"range": 70.0, "spread_deg": 0.6, "ads_spread_deg": 0.2, "ammo": "ammo_12g",
		"impulse": 3.0, "recoil_pitch_deg": 14.0, "recoil_yaw_deg": 3.0, "ads_fov": 58.0,
		"reload_mode": "shell", "reload_start": 0.35, "shell_time": 0.55, "reload_end": 0.3,
		# A big kick: the pump waits for the gun to come back down.
		"pump_delay": 0.42, "pump_time": 0.46, "kick": 5.0, "shell": "12g", "smoke": 1.26,
	}
	ResourceSaver.save(d, SHOTGUN + "shotgun_item.tres")
	print("saved shotgun item; grip ", grip, " aim offset ", aim_offset)
	var ammo := ItemDefinition.new()
	ammo.id = &"ammo_12g"
	ammo.display_name = "12 ga shells"
	ammo.kind = ItemDefinition.Kind.AMMO
	ammo.mass = 0.04
	ammo.max_stack = 60
	ammo.world_scene = load("res://assets/items/ammo/ammo_12g_world.tscn")
	ResourceSaver.save(ammo, "res://assets/items/ammo/ammo_12g_item.tres")


## Melee weapons, swung with the UAL sword clips (a three-swing combo: Sword_Regular_A, B, C;
## contact = the swing hand's fastest moment, measured: A 0.24 s, B 0.24 s, C 0.64 s). The
## bat is blunt (knocks out); the machete is a blade (cuts limbs off). Gripped in the sword
## idle's hand (UltraGripFit on the GripBody up the handle).
## Melee weapons. Each swing of a combo is a segment of one Mixamo combo clip (the next swing
## starts where the last one's follow-through ends, so a chained combo plays the clip straight
## through), time-scaled by `rate`: its contact frame (the hand's speed peak, measured with
## tools/measure_melee.gd) lands on the sim's hit_from; control comes back at `ctrl`.
## Swing spec: [clip from, contact, ctrl, segment end, reach, damage, knockback, (rate)].
func _melee(skel: Skeleton3D, lib: AnimationLibrary) -> void:
	var mix: AnimationLibrary = load(MANNEQUIN + "anims/mixamo.res") if ResourceLoader.exists(MANNEQUIN + "anims/mixamo.res") else null
	for spec: Array in [
		# Bat: both hands, Mixamo "Two Handed Club Combo Attack" (overhead, a cut down and
		# across, a short swing back) from "Two Handed Weapon Stance".
		["bat", "Baseball bat", "Ash bat. Blunt: a blow to the head knocks a man out.", 1.0, &"blunt",
			"M_Club2Idle", "M_Club2Combo", 1.35, [
			[0.75, 1.48, 1.80, 2.20, 1.7, 30.0, 3.0],
			[1.80, 2.80, 3.30, 3.60, 1.7, 26.0, 2.6, 1.6],
			[3.30, 3.92, 4.40, 4.80, 1.8, 36.0, 5.0]]],
		# Machete: one hand, the sword combo (forehand, backhand, a lunging cut).
		["machete", "Machete", "A long blade. It cuts - limbs come off.", 0.7, &"blade",
			"", "M_SwordCombo", 1.4, [
			[0.45, 1.02, 1.40, 1.80, 1.55, 30.0, 1.2],
			[1.40, 2.00, 2.40, 2.75, 1.55, 30.0, 1.2],
			[2.40, 3.00, 3.70, 4.05, 1.7, 44.0, 2.0]]],
	]:
		var path := "res://assets/items/%s/%s.glb" % [spec[0], spec[0]]
		if not ResourceLoader.exists(path):
			continue
		var idle_clip: String = spec[5]
		var combo: String = spec[6]
		var have_idle := mix != null and idle_clip != "" and mix.has_animation(idle_clip)
		# The grip is fitted to the hand as the idle holds it.
		UltraPoseSampler.pose(mix.get_animation(idle_clip) if have_idle else lib.get_animation("Idle_Sword"), skel, 0.5)
		var node := (load(path) as PackedScene).instantiate() as Node3D
		var grip := UltraGripFit.fit(skel, node)
		node.free()
		var d := ItemDefinition.new()
		d.id = StringName(spec[0])
		d.display_name = spec[1]
		d.description = spec[2]
		d.kind = ItemDefinition.Kind.MELEE
		d.mass = spec[3]
		d.max_stack = 1
		d.equip_scene = load(path)
		var wpath := "res://assets/items/%s/%s_world.tscn" % [spec[0], spec[0]]
		d.world_scene = load(wpath) if ResourceLoader.exists(wpath) else null
		d.equip_slots = ItemDefinition.EquipSlot.MAIN_HAND | ItemDefinition.EquipSlot.BACK
		d.grip_offset = grip
		d.two_handed = false
		# Slung on the back, handle up over the right shoulder.
		UltraPoseSampler.pose(lib.get_animation("Idle_A"), skel, 0.5)
		var chest := UltraPoseSampler.global_pose(skel, skel.find_bone("UpperChest"))
		var up := Vector3(-0.45, -1.0, 0.0).normalized()          # down and to the left: handle up right
		var y := up
		var z := (Vector3(0, 0, -1) - y * y.z).normalized()
		var b := Basis(y.cross(z), y, z)
		d.holster_bone = &"UpperChest"
		d.holster_offset = chest.affine_inverse() * Transform3D(b, chest.origin + Vector3(-0.02, -0.02, -0.16) - b * Vector3(0, 0.25, 0))
		# Roles are shared by every character: each weapon names its own.
		var r := String(spec[0])
		d.anim_roles = {"idle": r + "_idle", "aim": r + "_idle"}
		d.anim_clips = {r + "_idle": ["mixamo/" + idle_clip, "Idle_Sword"] if have_idle else ["Idle_Sword"],
			r + "_combo": ["mixamo/" + combo]}
		var swings := []
		for w: Array in spec[8]:
			var rate: float = w[7] if w.size() > 7 else spec[7]
			var hit_from: float = (w[1] - w[0]) / rate
			swings.append({"time": snappedf((w[2] - w[0]) / rate, 0.01), "hit_from": snappedf(hit_from, 0.01),
				"hit_to": snappedf(hit_from + 0.1, 0.01), "reach": w[4], "damage": w[5], "kind": spec[4],
				"knockback": w[6], "impulse": w[5] * 0.5,
				"clip": StringName(r + "_combo"), "seg": Vector2(w[0], w[3]), "contact": w[1]})
		d.equip_time = 0.45
		d.stats = {"melee": swings}
		ResourceSaver.save(d, "res://assets/items/%s/%s_item.tres" % [spec[0], spec[0]])
		print("saved melee weapon ", spec[0], " grip ", grip, " swings ", swings.map(func(x: Dictionary) -> String: return "%.2f/%.2f" % [x.hit_from, x.time]))


## Sprinting, the rifle is carried at port arms (AnimDriver: one frame of the rifle sprint clip
## on the item layer); the free aim goes where that barrel points (yaw toward the off side,
## pitch; degrees, skeleton space: +Z forward, +X the character's left).
func _carry_dir(skel: Skeleton3D, mix: AnimationLibrary, grip: Transform3D, fallback: Vector2) -> Vector2:
	if mix == null or not mix.has_animation("R_Sprint_F"):
		return fallback
	# As AnimDriver draws it: the arms (clavicles out) from the rifle sprint's held frame on
	# the body of the plain sprint.
	UltraPoseSampler.pose(mix.get_animation("R_Sprint_F"), skel, UltraAnimDriver.SPRINT_CARRY_T)
	var arms := {}
	for bn in ["LeftShoulder", "RightShoulder"]:
		var root_b := skel.find_bone(bn)
		for b in skel.get_bone_count():
			var p := b
			while p >= 0 and p != root_b:
				p = skel.get_bone_parent(p)
			if p == root_b:
				arms[b] = skel.get_bone_pose(b)
	if mix.has_animation("S_Fast"):
		UltraPoseSampler.pose(mix.get_animation("S_Fast"), skel, 0.0)
	for b: int in arms:
		skel.set_bone_pose(b, arms[b])
	var g := UltraPoseSampler.global_pose(skel, skel.find_bone("RightHand")) * grip
	var dir := -g.basis.z.normalized()
	var out := Vector2(rad_to_deg(atan2(dir.x, dir.z)), rad_to_deg(asin(dir.y))).snappedf(0.1)
	print("sprint carry: barrel yaw %.1f deg (+ = left), pitch %.1f deg" % [out.x, out.y])
	return out


## Left hand bone (skeleton space) on the handguard at `contact` (the grip point under it):
## palm against its left side, fingers forward and down so they curl in under it (out of the
## sight picture), thumb along the top. The palm's direction in the hand bone's frame comes
## from the posed fingers (like UltraEquipmentVisual._hand_basis).
func _support_hand(skel: Skeleton3D, gun: Transform3D, contact: Vector3) -> Transform3D:
	var hb := UltraPoseSampler.global_pose(skel, skel.find_bone("LeftHand"))
	var tip := Vector3.ZERO
	for f in ["MiddleDistal", "RingDistal", "IndexDistal"]:
		tip += UltraPoseSampler.global_pose(skel, skel.find_bone("Left" + f)).origin / 3.0
	var v := hb.basis.orthonormalized().inverse() * (tip - hb.origin)
	v.y = 0.0
	var p_local := v.normalized() if v.length() > 0.005 else Vector3(0, 0, 1)
	var gx := gun.basis.x.normalized()
	var gy := gun.basis.y.normalized()
	var fwd := -gun.basis.z.normalized()
	var fingers := (fwd * 0.75 - gy * 0.6 + gx * 0.1).normalized()
	var palm := gx
	palm = (palm - fingers * palm.dot(fingers)).normalized()
	var src := Basis(Vector3.UP.cross(p_local), Vector3.UP, p_local)
	var dst := Basis(fingers.cross(palm), fingers, palm)
	var basis := (dst * src.inverse()).orthonormalized()
	# From the grip point under the handguard to the middle of its left side.
	var side := contact + gy * 0.028 - gx * 0.027
	return Transform3D(basis, side - fingers * 0.07 - palm * 0.025)


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
