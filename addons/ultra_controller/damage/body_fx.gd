class_name UltraBodyFX
extends Node
## A character's injury presentation: hit reactions (clip + per-bone flinch), and what follows a
## limb coming off - the region collapses (DismemberModifier), a flesh cap covers the joint, the
## limb flies off as a gib (its triangles skinned on the CPU in the pose it had) and bleeds.
## Reads MotorState; never writes it. Gore follows the character's DamageProfile.

const R := UltraLimbs.Region
const PARENT_BONE := {
	R.HEAD: "Neck", R.ARM_L: "LeftShoulder", R.FOREARM_L: "LeftUpperArm", R.ARM_R: "RightShoulder",
	R.FOREARM_R: "RightUpperArm", R.THIGH_L: "Hips", R.SHIN_L: "LeftUpperLeg", R.THIGH_R: "Hips",
	R.SHIN_R: "RightUpperLeg",
}
const CAP_RADIUS := {
	R.HEAD: 0.065, R.ARM_L: 0.055, R.FOREARM_L: 0.045, R.ARM_R: 0.055, R.FOREARM_R: 0.045,
	R.THIGH_L: 0.08, R.SHIN_L: 0.058, R.THIGH_R: 0.08, R.SHIN_R: 0.058,
}
const MAX_GIBS := 16

static var _gibs: Array[Node3D] = []
static var _vertex_regions := {}          ## mesh RID -> Array[PackedByteArray] per surface
static var _flesh: StandardMaterial3D
static var _drip: StandardMaterial3D

var character: UltraCharacter
var dismember: DismemberModifier
var injury: InjuryModifier
var _shown := 0                            ## severed mask currently presented
var _caps := {}                            ## region -> Node3D


func setup(c: UltraCharacter) -> void:
	character = c
	var sk := c.skeleton
	injury = InjuryModifier.new()
	injury.name = "Injury"
	sk.add_child(injury)
	dismember = DismemberModifier.new()
	dismember.name = "Dismember"
	sk.add_child(dismember)                 # last: after IK, look and injuries
	UltraNet.world.on_event(&"sever", _on_sever)


func _exit_tree() -> void:
	UltraNet.world.off_event(&"sever", _on_sever)


func _process(_delta: float) -> void:
	if character == null:
		return
	var s := character.state
	if s.severed != _shown:
		_apply_mask(s.severed)
	var S := UltraLimbs.Status
	injury.dangle_l = 1.0 if UltraLimbs.status(s, R.ARM_L) == S.CRIPPLED or UltraLimbs.status(s, R.FOREARM_L) == S.CRIPPLED else 0.0
	injury.dangle_r = 1.0 if UltraLimbs.status(s, R.ARM_R) == S.CRIPPLED or UltraLimbs.status(s, R.FOREARM_R) == S.CRIPPLED else 0.0
	if s.state in [MotorState.Id.RAGDOLL, MotorState.Id.DEAD]:
		injury.dangle_l = 0.0
		injury.dangle_r = 0.0
	var vb := character.visual_root.global_basis
	injury.accel = (vb.inverse() * character.get_accel()) * Vector3(-1, 1, -1)   # world -> skeleton space


## Hit reaction: the matching clip on the upper body, and a kick on the bone that was hit.
func react(region: int, dir: Vector3, amount: float) -> void:
	if character.anim:
		character.anim.play_hit(region == R.HEAD)
	if region < 0 or injury == null:
		return
	var bone: String = UltraLimbs.BONES[region][0]
	if region == R.TORSO:
		bone = "Chest"
	var skel_dir := (character.visual_root.global_basis.inverse() * dir) * Vector3(-1, 1, -1)
	injury.flinch(bone, skel_dir, clampf(amount * 0.12, 1.5, 7.0))


func _apply_mask(mask: int) -> void:
	_shown = mask
	dismember.severed = mask
	for r: int in PARENT_BONE:
		var cut := (mask >> r) & 1 == 1
		# Only the top of a cut chain gets a cap (no cap on a forearm whose arm is gone).
		var top := cut
		for up: int in UltraLimbs.BELOW:
			if r in UltraLimbs.BELOW[up] and (mask >> up) & 1:
				top = false
		if top and not _caps.has(r):
			_caps[r] = _make_cap(r)
		elif not top and _caps.has(r):
			(_caps[r] as Node).queue_free()
			_caps.erase(r)


func _make_cap(r: int) -> Node3D:
	var sk := character.skeleton
	var att := BoneAttachment3D.new()
	att.bone_name = PARENT_BONE[r]
	sk.add_child(att)
	var child := sk.find_bone(UltraLimbs.BONES[r][0])
	var at := sk.get_bone_rest(child).origin
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	var rad: float = CAP_RADIUS[r]
	sm.radius = rad
	sm.height = rad * 1.3
	mi.mesh = sm
	mi.material_override = _flesh_mat()
	var dir := at.normalized() if at.length() > 0.001 else Vector3.UP
	mi.transform = Transform3D(Basis(Quaternion(Vector3.UP, dir)), at)
	att.add_child(mi)
	if character.damage_profile.blood_on():
		_bleed(mi)
	return att


func _bleed(on: Node3D) -> void:
	var p := CPUParticles3D.new()
	p.amount = 24
	p.lifetime = 0.9
	p.direction = Vector3.UP
	p.spread = 30.0
	p.initial_velocity_min = 0.3
	p.initial_velocity_max = 1.0
	p.gravity = Vector3(0, -9.8, 0)
	var m := SphereMesh.new()
	m.radius = 0.008
	m.height = 0.016
	m.radial_segments = 4
	m.rings = 2
	p.mesh = m
	p.material_override = _drip_mat()
	p.local_coords = false
	on.add_child(p)
	p.emitting = true
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 8.0
	tm.autostart = true
	tm.timeout.connect(func() -> void: p.emitting = false)
	p.add_child(tm)


# ---------------------------------------------------------------- severing

func _on_sever(net_id: int, cut: int, dir: Vector3, point: Vector3) -> void:
	if character == null or net_id != character.net_id:
		return
	_apply_mask(character.state.severed | cut)
	var fx := UltraEffects.instance()
	if fx and character.damage_profile.blood_on():
		fx.blood(point, -dir)
		fx.blood(point, Vector3.UP)
	spawn_gib(cut, dir)


## Throw the cut-off part as a rigid body made from its own triangles in their current pose.
func spawn_gib(cut: int, dir: Vector3) -> void:
	var mi := character.body_mesh()
	if mi == null or mi.mesh == null or mi.skin == null:
		return
	var sk := character.skeleton
	var regions := _regions_for(mi, sk)
	var mesh := mi.mesh as ArrayMesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bind_xf: Array[Transform3D] = []
	for i in mi.skin.get_bind_count():
		var b := mi.skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(mi.skin.get_bind_name(i))
		bind_xf.append(sk.global_transform * sk.get_bone_global_pose(maxi(b, 0)) * mi.skin.get_bind_pose(i))
	var pts := PackedVector3Array()
	var any := false
	for surf in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var vr: PackedByteArray = regions[surf]
		var per := bones.size() / maxi(verts.size(), 1)
		var mat := mi.get_active_material(surf)
		for t in range(0, idx.size(), 3):
			var a := idx[t]
			var b2 := idx[t + 1]
			var c2 := idx[t + 2]
			if not ((cut >> vr[a]) & 1 and (cut >> vr[b2]) & 1 and (cut >> vr[c2]) & 1):
				continue
			any = true
			for v in [a, b2, c2]:
				var acc := Vector3.ZERO
				var nacc := Vector3.ZERO
				for k in per:
					var w := weights[v * per + k]
					if w <= 0.0:
						continue
					var bx := bind_xf[bones[v * per + k]]
					acc += (bx * verts[v]) * w
					nacc += (bx.basis * norms[v]) * w
				if uvs.size() > v:
					st.set_uv(uvs[v])
				st.set_normal(nacc.normalized())
				st.add_vertex(acc)
				pts.append(acc)
		if any:
			st.set_material(mat)
	if not any:
		return
	var center := Vector3.ZERO
	for p in pts:
		center += p
	center /= pts.size()
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	var m := MeshInstance3D.new()
	var built := st.commit()
	m.mesh = built
	m.position = -center
	body.add_child(m)
	var aabb := AABB(pts[0] - center, Vector3.ZERO)
	for p in pts:
		aabb = aabb.expand(p - center)
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = aabb.size.clamp(Vector3.ONE * 0.06, Vector3.ONE * 2.0) * 0.85
	cs.shape = bx
	cs.position = aabb.get_center()
	body.add_child(cs)
	body.mass = clampf(aabb.size.x * aabb.size.y * aabb.size.z * 900.0, 1.0, 9.0)
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	root.add_child(body)
	body.global_position = center
	body.linear_velocity = character.state.vel + dir * 3.5 + Vector3.UP * 2.0
	body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	body.add_to_group(&"ultra_gib")
	_gibs.append(body)
	while _gibs.size() > MAX_GIBS:
		var old := _gibs.pop_front() as Node
		if is_instance_valid(old):
			old.queue_free()
	var life := Timer.new()
	life.one_shot = true
	life.wait_time = 30.0
	life.autostart = true
	life.timeout.connect(body.queue_free)
	body.add_child(life)


## Which region each vertex belongs to (by its strongest bone), cached per mesh.
static func _regions_for(mi: MeshInstance3D, sk: Skeleton3D) -> Array:
	var key := mi.mesh.get_rid()
	if _vertex_regions.has(key):
		return _vertex_regions[key]
	var bone_region := PackedByteArray()
	bone_region.resize(sk.get_bone_count())
	for b in sk.get_bone_count():
		bone_region[b] = _region_of_bone(sk, b)
	var out: Array = []
	var mesh := mi.mesh as ArrayMesh
	for surf in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / maxi(verts.size(), 1)
		var vr := PackedByteArray()
		vr.resize(verts.size())
		for v in verts.size():
			var best := 0
			for k in per:
				if weights[v * per + k] > weights[v * per + best]:
					best = k
			var bind := bones[v * per + best]
			var b := mi.skin.get_bind_bone(bind)
			if b < 0:
				b = sk.find_bone(mi.skin.get_bind_name(bind))
			vr[v] = bone_region[maxi(b, 0)]
		out.append(vr)
	_vertex_regions[key] = out
	return out


static func _region_of_bone(sk: Skeleton3D, b: int) -> int:
	while b >= 0:
		var n := sk.get_bone_name(b)
		for r: int in UltraLimbs.BONES:
			if n in UltraLimbs.BONES[r]:
				return r
		b = sk.get_bone_parent(b)
	return R.TORSO


static func _flesh_mat() -> StandardMaterial3D:
	if _flesh == null:
		_flesh = StandardMaterial3D.new()
		_flesh.albedo_color = Color(0.55, 0.08, 0.07)
		_flesh.roughness = 0.35
	return _flesh


static func _drip_mat() -> StandardMaterial3D:
	if _drip == null:
		_drip = StandardMaterial3D.new()
		_drip.albedo_color = Color(0.45, 0.02, 0.02)
		_drip.roughness = 0.2
	return _drip
