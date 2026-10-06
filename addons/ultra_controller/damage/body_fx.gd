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
const MAX_GIBS := 32

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


func _process(delta: float) -> void:
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
	_drive_blood(delta)


# ---------------------------------------------------------------- bleeding

var _beat := 0.0
var _drip_t := 0.0
var _seep_t := 0.0
var _pool_t := 0.0
var _dead_t := 0.0


## Open stumps pump blood with the heart (weaker as the blood runs out; a dribble once dead);
## anyone lying in it grows a pool, and a body that's been shot dead bleeds out under itself.
func _drive_blood(delta: float) -> void:
	var fx := UltraEffects.instance()
	if fx == null or fx.blood_fx == null or not character.damage_profile.blood_on():
		return
	var s := character.state
	var Id := MotorState.Id
	var dead := s.state == Id.DEAD
	_dead_t = _dead_t + delta if dead else 0.0
	var lying := s.state in [Id.RAGDOLL, Id.DEAD, Id.GET_UP]
	var life := clampf(s.hp / 100.0, 0.0, 1.0)
	var flow := 0.0 if dead and _dead_t > 12.0 else (0.25 if dead else 0.4 + 0.6 * life)
	_beat -= delta
	_drip_t -= delta
	_pool_t -= delta
	var beat := false
	if _beat <= 0.0:
		_beat = 0.75 if not dead else 1.4
		beat = true
	for r: int in _caps:
		var att := _caps[r] as Node3D
		if not is_instance_valid(att) or att.get_child_count() == 0:
			continue
		var cap := att.get_child(0) as Node3D
		var at := cap.global_position
		var out := cap.global_basis.y.normalized()
		if flow <= 0.0:
			continue
		if beat:
			fx.blood_fx.spray(at, out + Vector3.UP * 0.15, int(4 + 8 * flow), 1.2 + 2.2 * flow, 22.0, 0.007, character)
		if _drip_t <= 0.0:
			fx.blood_fx.spray(at, Vector3.DOWN, 1, 0.3, 30.0, 0.006, character)
		if lying and _pool_t <= 0.0:
			fx.blood_fx.pool(at, 0.12 + 0.1 * flow)
	# Crippled limbs seep: a drop now and then off the wound.
	_seep_t -= delta
	if _seep_t <= 0.0 and not dead and character.skeleton:
		_seep_t = randf_range(0.35, 0.7)
		var sk := character.skeleton
		for r in UltraLimbs.COUNT:
			if r == R.HEAD or UltraLimbs.status(s, r) != UltraLimbs.Status.CRIPPLED:
				continue
			var bones: Array = UltraLimbs.BONES[r]
			var b := sk.find_bone(bones[0] if r != R.TORSO else "Chest")
			if b < 0:
				continue
			var bp := sk.global_transform * sk.get_bone_global_pose(b).origin
			fx.blood_fx.spray(bp + Vector3(randf_range(-0.04, 0.04), 0.0, randf_range(-0.04, 0.04)), Vector3.DOWN, 1, 0.4, 25.0, 0.006, character)
	if _drip_t <= 0.0:
		_drip_t = 0.09
	# Shot dead: a pool spreads from under the chest for a while.
	if dead and _dead_t < 10.0 and _pool_t <= 0.0 and character.skeleton:
		var sk := character.skeleton
		var ch := sk.find_bone("Chest")
		if ch >= 0:
			fx.blood_fx.pool(sk.global_transform * sk.get_bone_global_pose(ch).origin, 0.16)
	if _pool_t <= 0.0:
		_pool_t = 0.45


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

func _on_sever(net_id: int, cut: int, dir: Vector3, point: Vector3, kind := &"bullet") -> void:
	if character == null or net_id != character.net_id:
		return
	_apply_mask(character.state.severed | cut)
	# Buckshot / a blast through the head: it bursts - chunks of it fly, a red mist.
	var head := 1 << R.HEAD
	if cut & head and (kind == &"buckshot" or kind == &"blast"):
		var fx2 := UltraEffects.instance()
		if fx2 and fx2.blood_fx and character.damage_profile.blood_on():
			fx2.blood_fx.spray(point, dir + Vector3.UP * 0.3, 90, 7.0, 35.0, 0.008, character)
			fx2.blood_fx.spray(point, Vector3.UP, 40, 3.5, 45.0, 0.007, character)
			for i in 8:
				fx2.blood_fx.splat_body(character, point + Vector3(randf_range(-0.2, 0.2), randf_range(-0.45, -0.05), randf_range(-0.2, 0.2)), randf_range(0.1, 0.18))
		spawn_gib(head, dir, 9, 7.0)
		cut &= ~head
		if cut == 0:
			return
	var fx := UltraEffects.instance()
	if fx and character.damage_profile.blood_on():
		if fx.blood_fx:
			# The limb tears off: a gush along the hit, a fountain up, the body splashed.
			fx.blood_fx.spray(point, dir + Vector3.UP * 0.2, 45, 4.5, 30.0, 0.008, character)
			fx.blood_fx.spray(point, Vector3.UP, 25, 2.8, 35.0, 0.007, character)
			for i in 6:
				fx.blood_fx.splat_body(character, point + Vector3(randf_range(-0.15, 0.15), randf_range(-0.25, 0.1), randf_range(-0.15, 0.15)), randf_range(0.08, 0.16))
		else:
			fx.blood(point, -dir)
	spawn_gib(cut, dir)


## Throw the cut-off part as rigid bodies made from its own triangles (body and head meshes)
## in their current pose. `pieces` > 1 breaks it into that many chunks round its middle, each
## with a bit of flesh in it, blown out at `burst` m/s (a head blown off by buckshot).
func spawn_gib(cut: int, dir: Vector3, pieces := 1, burst := 0.0) -> void:
	var tris: Array = []            # [Vector3 a, b, c, normals..., uvs..., material]
	for mi: MeshInstance3D in [character.body_mesh(), character.head_mesh]:
		if mi != null and mi.mesh != null and mi.skin != null:
			_collect_tris(mi, cut, tris)
	if tris.is_empty():
		return
	var center := Vector3.ZERO
	for t: Array in tris:
		center += (t[0] + t[1] + t[2]) / 3.0
	center /= tris.size()
	var groups: Array = []
	if pieces <= 1:
		var all := []
		for k in tris.size():
			all.append(k)
		groups.append(all)
	else:
		# Chunks: each triangle goes to the nearest of `pieces` directions round the middle.
		var dirs := _sphere_dirs(pieces)
		for d in dirs:
			groups.append([])
		for k in tris.size():
			var t: Array = tris[k]
			var mid: Vector3 = (t[0] + t[1] + t[2]) / 3.0
			var v := (mid - center).normalized()
			var best := 0
			for q in dirs.size():
				if dirs[q].dot(v) > dirs[best].dot(v):
					best = q
			(groups[best] as Array).append(k)
	for g: Array in groups:
		if g.is_empty():
			continue
		var gc := Vector3.ZERO
		for k: int in g:
			var t: Array = tris[k]
			gc += (t[0] + t[1] + t[2]) / 3.0
		gc /= g.size()
		var out := (gc - center).normalized() if pieces > 1 and gc.distance_to(center) > 0.001 else Vector3.ZERO
		var vel := character.state.vel + dir * 3.5 + Vector3.UP * 2.0
		if burst > 0.0:
			vel = character.state.vel + dir * burst * randf_range(0.5, 1.1) + out * burst * randf_range(0.4, 0.8) + Vector3.UP * randf_range(1.0, 3.0)
		_make_gib(tris, g, gc, vel, pieces > 1)


## The cut region's triangles from one skinned mesh, posed (world space).
func _collect_tris(mi: MeshInstance3D, cut: int, out: Array) -> void:
	var sk := character.skeleton
	var regions := _regions_for(mi, sk)
	var mesh := mi.mesh as ArrayMesh
	var bind_xf: Array[Transform3D] = []
	for i in mi.skin.get_bind_count():
		var b := mi.skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(mi.skin.get_bind_name(i))
		bind_xf.append(sk.global_transform * sk.get_bone_global_pose(maxi(b, 0)) * mi.skin.get_bind_pose(i))
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
			var tri: Array[int] = [idx[t], idx[t + 1], idx[t + 2]]
			if not ((cut >> vr[tri[0]]) & 1 and (cut >> vr[tri[1]]) & 1 and (cut >> vr[tri[2]]) & 1):
				continue
			var p: Array = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, mat]
			for j in 3:
				var v: int = tri[j]
				var acc := Vector3.ZERO
				var nacc := Vector3.ZERO
				for k in per:
					var w := weights[v * per + k]
					if w <= 0.0:
						continue
					var bx := bind_xf[bones[v * per + k]]
					acc += (bx * verts[v]) * w
					nacc += (bx.basis * norms[v]) * w
				p[j] = acc
				p[3 + j] = nacc.normalized()
				p[6 + j] = uvs[v] if uvs.size() > v else Vector2.ZERO
			out.append(p)


func _make_gib(tris: Array, group: Array, center: Vector3, vel: Vector3, chunk: bool) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var aabb := AABB()
	var first := true
	for k: int in group:
		var t: Array = tris[k]
		for j in 3:
			st.set_uv(t[6 + j])
			st.set_normal(t[3 + j])
			st.add_vertex(t[j] - center)
			if first:
				aabb = AABB(t[j] - center, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(t[j] - center)
	st.set_material((tris[group[0]] as Array)[9])
	var body := RigidBody3D.new()
	body.collision_layer = 0
	body.collision_mask = UltraLayers.WORLD_STATIC | UltraLayers.WORLD_DYNAMIC
	var m := MeshInstance3D.new()
	m.mesh = st.commit()
	body.add_child(m)
	if chunk:
		# Torn flesh in the broken piece (the skin alone is a hollow shell).
		var f := MeshInstance3D.new()
		var sm := SphereMesh.new()
		var r := clampf(aabb.size.length() * 0.22, 0.012, 0.05)
		sm.radius = r
		sm.height = r * 1.6
		sm.radial_segments = 6
		sm.rings = 3
		f.mesh = sm
		f.material_override = _flesh_mat()
		f.position = aabb.get_center() * 0.6
		body.add_child(f)
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = aabb.size.clamp(Vector3.ONE * (0.025 if chunk else 0.06), Vector3.ONE * 2.0) * 0.85
	cs.shape = bx
	cs.position = aabb.get_center()
	body.add_child(cs)
	body.mass = clampf(aabb.size.x * aabb.size.y * aabb.size.z * 900.0, 0.05 if chunk else 1.0, 9.0)
	var root := character.get_tree().current_scene if character.get_tree().current_scene else character.get_parent()
	root.add_child(body)
	body.global_position = center
	body.linear_velocity = vel
	body.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)) * (2.5 if chunk else 1.0)
	body.add_to_group(&"ultra_gib")
	# (Gibs free themselves after 30 s: drop the freed ones before counting - casting a freed
	# object raised an error once the oldest had expired.)
	for k in range(_gibs.size() - 1, -1, -1):
		if not is_instance_valid(_gibs[k]):
			_gibs.remove_at(k)
	_gibs.append(body)
	while _gibs.size() > MAX_GIBS:
		var old: Variant = _gibs.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()
	var life := Timer.new()
	life.one_shot = true
	life.wait_time = 30.0
	life.autostart = true
	life.timeout.connect(body.queue_free)
	body.add_child(life)
	# Chunks bleed where they fly.
	var fx := UltraEffects.instance()
	if chunk and fx and fx.blood_fx and character.damage_profile.blood_on():
		fx.blood_fx.spray(center, vel, 3, vel.length() * 0.8, 15.0, 0.007)


## `n` directions spread evenly over a sphere (Fibonacci).
static func _sphere_dirs(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var golden := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / n * 2.0
		var r := sqrt(maxf(1.0 - y * y, 0.0))
		out.append(Vector3(cos(golden * i) * r, y, sin(golden * i) * r))
	return out


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
