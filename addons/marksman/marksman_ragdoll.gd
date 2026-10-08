class_name MarksmanRagdoll
extends SinewRagdoll
## Marksman's body: Sinew's ragdoll + gait, walking on the stance the character is in - one group of
## reference cycles per stance and posture (MarksmanStanceSet.groups: unarmed / rifle / pistol, standing /
## crouched), switched as a gun is drawn or put away and on crouching. Prone is the clips' (crawling isn't a
## biped's gait).

## The gait group walking now (an index into MarksmanStanceSet.groups; -1 before the gait is set up).
var group := -1
## Seconds a stance change cross-fades the gait's pose over.
@export var stance_blend := 0.35


func _setup_gait() -> void:
	_gait_on = false
	_gait_running = false
	gait_w = 0.0
	group = -1
	var aset := character.anim.anim_set as MarksmanStanceSet if character.anim else null
	if aset == null or aset.groups.is_empty():
		super._setup_gait()          # (no stances: Sinew's own cycles)
		return
	if not gait or character.anim.skeleton == null:
		return
	world.physics.call("character_gait_enable", _id, true, gait_settings)
	var cycles := []
	for gi in aset.groups.size():
		var g: Dictionary = aset.groups[gi]
		var built := SinewGaitCycles.build_group(character.anim, parts, g.get("cycles", []), g.get("upper_from", {}), gi)
		for c in built:
			# (Crouched, the feet roll onto their balls through the stance.)
			c["rolling_stance"] = g.get("posture", "") == "crouch"
		cycles.append_array(built)
		var idle := SinewGaitCycles.idle_pose(character.anim, parts, StringName(g.get("idle", "idle")))
		if not idle.is_empty():
			world.physics.call("character_gait_set_idle", _id, idle.locals, idle.pelvis_height, gi)
	world.physics.call("character_gait_set_cycles", _id, cycles)
	gait_part_w.resize(parts.size())
	gait_part_w.fill(1.0)
	_gait_on = true
	_sync_group(0.0)


## The stance group the character's state asks for (-1: none - prone, or no stance set).
func wanted_group() -> int:
	var aset := character.anim.anim_set as MarksmanStanceSet if character.anim else null
	if aset == null:
		return -1
	var posture := MarksmanStance.posture(character)
	if posture == "prone":
		posture = "crouch"           # (the gait isn't walking; keep the nearest stance's legs ready)
	var gi := aset.group_index(MarksmanStance.of(character), posture)
	if gi < 0:
		gi = aset.group_index("unarmed", posture)
	return maxi(gi, 0)


func _sync_group(blend: float) -> void:
	var want := wanted_group()
	if want >= 0 and want != group and _gait_on and world.physics.has_method("character_gait_set_group"):
		world.physics.call("character_gait_set_group", _id, want, blend)
		group = want


func _update_gait(dt: float) -> void:
	_sync_group(stance_blend)
	super._update_gait(dt)


func _gait_states() -> Array:
	return super._gait_states() + [MotorState.Id.CROUCH]


## The stance cycles hold the gun the way the stance does (the rifle pack's arms carry the rifle): an item of
## the current stance doesn't take the upper body off the gait - only a carried prop or a one-shot does.
func _gait_upper_weight(busy: bool, speed: float) -> float:
	var st := character.state
	var drv := character.anim as SinewAnimDriver
	var item_busy := st.held_uid != 0 and MarksmanStance.of(character) == "unarmed"
	var really := item_busy or st.held_id != 0 or (drv != null and drv.upper_busy())
	return super._gait_upper_weight(really, speed)
