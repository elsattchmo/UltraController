class_name UltraCutBody
extends RefCounted
## The body in pieces (presentation): a model's pre-cut set (BodyProfile.cut_scene, made in
## Blender by `tools/blender/ultra_blender.py make-cuts`) swapped in for its one skin once it is
## hurt that badly. Every region is its own mesh ("Seg_<REGION>"), every cut has its two ends
## fitted to it ("Cap_<REGION>_stump" on the body, "Cap_<REGION>_end" on the part that comes
## off), the head comes in chunks ("Chunk_HEAD_<k>"), and there are two torso variants: the
## belly blown open ("Seg_TORSO_OPEN") and the torso in two at the waist ("Seg_WAIST_UP" /
## "_DOWN" + "Cap_WAIST_up" / "_down"). A severed region's pieces are hidden and its stump
## shown; nothing is scaled away, so the skin round a cut stays exactly where it was.
## All pieces skin to the character's own skeleton with the body's bind poses (by bone name).

## HALVED: the torso in two, both halves shown (a body killed that way). UPPER: cut in two and still
## alive (MotorState.F_HALVED) - only the upper half shows, the lower half and the legs are gone.
enum Torso { WHOLE, OPEN, HALVED, UPPER }

const R := UltraLimbs.Region
const PARENT := {
	R.HEAD: R.TORSO, R.ARM_L: R.TORSO, R.ARM_R: R.TORSO, R.THIGH_L: R.TORSO, R.THIGH_R: R.TORSO,
	R.FOREARM_L: R.ARM_L, R.FOREARM_R: R.ARM_R, R.HAND_L: R.FOREARM_L, R.HAND_R: R.FOREARM_R,
	R.SHIN_L: R.THIGH_L, R.SHIN_R: R.THIGH_R, R.FOOT_L: R.SHIN_L, R.FOOT_R: R.SHIN_R,
}
const LEGS := [R.THIGH_L, R.SHIN_L, R.FOOT_L, R.THIGH_R, R.SHIN_R, R.FOOT_R]

static var _sets := {}                    ## cut scene -> {part name: [ArrayMesh, Skin]}

var character: UltraCharacter
var parts := {}                           ## part name -> MeshInstance3D (under the skeleton)
var active := false
var torso := Torso.WHOLE
var severed := 0


func _init(c: UltraCharacter) -> void:
	character = c


## Whether this character's model has a cut set.
static func available(c: UltraCharacter) -> bool:
	return c.body_profile != null and c.body_profile.cut_scene != null and c.skeleton != null \
		and c.body_mesh() != null


## The meshes of a cut scene (loaded once per scene).
static func _set_of(scene: PackedScene) -> Dictionary:
	if _sets.has(scene):
		return _sets[scene]
	var out := {}
	var inst := scene.instantiate()
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh is ArrayMesh:
			out[String(mi.name)] = [mi.mesh, mi.skin]
	inst.free()
	_sets[scene] = out
	return out


## Load a cut set and close its pieces now (at level load), not on the frame someone is first
## blown apart (~0.1 s of hitch).
static func prewarm(scene: PackedScene) -> void:
	var pieces := _set_of(scene)
	for name: String in pieces:
		if name.begins_with("Seg_") and name != "Seg_TORSO_OPEN":
			UltraMeshCap.capped(pieces[name][0] as ArrayMesh)


static func region_name(r: int) -> String:
	return String(UltraLimbs.Region.keys()[r])


## A piece by its name in the cut set ("Seg_ARM_L", "Cap_HEAD_end"...), or null.
func part(name: String) -> MeshInstance3D:
	return parts.get(name) as MeshInstance3D


## Put the pieces on (the one-piece body and head go hidden).
func activate() -> void:
	if active:
		return
	active = true
	var sk := character.skeleton
	var bm := character.body_mesh()
	var hm := character.head_mesh
	var body_mat := bm.get_active_material(0)
	var head_mat := hm.get_active_material(0) if hm else body_mat
	# A model with several materials (a Mixamo body: skin, clothes): the pieces carry them by name.
	var live := {}
	for si in bm.mesh.get_surface_count():
		var sm := bm.mesh.surface_get_material(si)
		if sm and sm.resource_name != "":
			live[sm.resource_name] = bm.get_active_material(si)
	var pieces := _set_of(character.body_profile.cut_scene)
	for name: String in pieces:
		var src_mesh := pieces[name][0] as ArrayMesh
		var mi := MeshInstance3D.new()
		mi.name = "Cut_" + name
		# Pieces of skin are closed where they were cut (skin-coloured, under the caps), so
		# nothing ever shows through a piece's open edge. (Not the opened torso: its skin's edge
		# round the belly opening is a loop too - capping sealed the cavity over with skin.)
		mi.mesh = UltraMeshCap.capped(src_mesh) if name.begins_with("Seg_") and name != "Seg_TORSO_OPEN" else src_mesh
		mi.skin = _rebind(pieces[name][1] as Skin, bm.skin)
		mi.cast_shadow = bm.cast_shadow
		var is_head := name == "Seg_HEAD" or name.begins_with("Chunk_HEAD")
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			var mn := m.resource_name if m else "Main"
			var use: Material
			match mn:
				"CutFat": use = UltraCharacter._near_fade_mat(UltraWoundMesh.fat_mat())
				"CutMeat": use = UltraCharacter._near_fade_mat(UltraWoundMesh.meat_mat())
				"CutBone": use = UltraCharacter._near_fade_mat(UltraWoundMesh.bone_mat())
				"CutMarrow": use = UltraCharacter._near_fade_mat(UltraWoundMesh.marrow_mat())
				_: use = live.get(mn, head_mat if is_head else body_mat)
			mi.set_surface_override_material(si, use)
		mi.visible = false
		sk.add_child(mi)
		mi.skeleton = mi.get_path_to(sk)
		parts[name] = mi
	bm.visible = false
	if hm:
		hm.visible = false
	update()


## Back to the one-piece body (respawned whole).
func deactivate() -> void:
	if not active:
		return
	active = false
	for mi: MeshInstance3D in parts.values():
		mi.queue_free()
	parts.clear()
	var bm := character.body_mesh()
	if bm:
		bm.visible = true
	if character.head_mesh:
		character.head_mesh.visible = true
	torso = Torso.WHOLE
	severed = 0


## Region `r` is gone (it or a region it hangs from is severed).
func gone(r: int) -> bool:
	while r >= 0:
		if (severed >> r) & 1:
			return true
		r = PARENT.get(r, -1)
	return false


func update() -> void:
	if not active:
		return
	for mi: MeshInstance3D in parts.values():
		mi.visible = false
	match torso:
		Torso.WHOLE:
			_show("Seg_TORSO")
		Torso.OPEN:
			_show("Seg_TORSO_OPEN")
		Torso.HALVED:
			for n in ["Seg_WAIST_UP", "Seg_WAIST_DOWN", "Cap_WAIST_up", "Cap_WAIST_down"]:
				_show(n)
		Torso.UPPER:
			_show("Seg_WAIST_UP")
			_show("Cap_WAIST_up")
	for r: int in PARENT:
		if torso == Torso.UPPER and r in LEGS:
			continue                     # (they went with the lower half)
		var nm := region_name(r)
		if not gone(r):
			_show("Seg_" + nm)
		elif not gone(PARENT[r]):
			_show("Cap_%s_stump" % nm)
	sync_layers()


func _show(name: String) -> void:
	var mi := parts.get(name) as MeshInstance3D
	if mi:
		mi.visible = true


## First person hides our own head: the head piece goes on the head's render layers.
func sync_layers() -> void:
	var hm := character.head_mesh
	var mi := parts.get("Seg_HEAD") as MeshInstance3D
	if hm and mi:
		mi.layers = hm.layers


## The pieces of a severed chain (the top region and all under it) and the end of its cut.
func gib_parts(cut: int) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for r in UltraLimbs.COUNT:
		if not (cut >> r) & 1 or r == R.TORSO:
			continue
		var mi := part("Seg_" + region_name(r))
		if mi:
			out.append(mi)
		var top: bool = not (cut >> int(PARENT.get(r, R.TORSO))) & 1
		if top and part("Cap_%s_end" % region_name(r)):
			out.append(part("Cap_%s_end" % region_name(r)))
	return out


## What is about to leave with the lower half when the body is cut in two alive: the belly down
## to the hips with its sealed end, and whatever of the legs is still on (pieces, stumps).
## Call before switching `torso` to UPPER (it reads what is shown now).
func lower_half_parts() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in ["Seg_WAIST_DOWN", "Cap_WAIST_down"]:
		if part(n):
			out.append(part(n))
	for r: int in LEGS:
		for n in ["Seg_" + region_name(r), "Cap_%s_stump" % region_name(r)]:
			var mi := part(n)
			if mi and mi.visible:
				out.append(mi)
	return out


func head_chunks() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for name: String in parts:
		if name.begins_with("Chunk_HEAD"):
			out.append(parts[name])
	return out


static var _rebinds := {}


## The cut skin's binds with the body's bind poses (matched by bone name): Blender re-derives
## bone rests on its round trip (arm / leg bones came back turned), the vertices didn't move.
static func _rebind(cut: Skin, body: Skin) -> Skin:
	var key := "%d:%d" % [cut.get_instance_id(), body.get_instance_id()]
	if _rebinds.has(key):
		return _rebinds[key]
	var by_name := {}
	for j in body.get_bind_count():
		by_name[body.get_bind_name(j)] = body.get_bind_pose(j)
	var s := Skin.new()
	for i in cut.get_bind_count():
		var nm := cut.get_bind_name(i)
		s.add_named_bind(nm, by_name.get(nm, cut.get_bind_pose(i)))
	_rebinds[key] = s
	return s
