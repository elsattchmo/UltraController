extends Node
## Builds the zombie's resources into assets/characters/zombie/:
##   zombie_animset.tres       role -> clip, measured authored speeds (walk / run / limp / crawl)
##   zombie_body_profile.tres  LITE tier body: the Romero scene, both clip libraries, baked hit capsules
##   zombie_movement.tres      slow, heavy ground movement, no traversal / roll / slide / lean
##   zombie_damage.tres        tough torso, headshot kills, no bleeding out, no knockouts
## Run: godot --headless --path . res://tools/tool_runner.tscn -- --tool=res://tools/build_zombie.gd
## (Archetype variants - walker, runner, brute ... - are made from these at spawn time by
## demo/zombies/zombie_archetype.gd; nothing here is per variant.)

const DIR := "res://assets/characters/zombie/"
const MQ := "res://assets/characters/mannequin/"
const Measure := preload("res://tools/anim_measure.gd")

## role -> clip: "mixamo/X" lives in the intake library, a bare name in the Quaternius one.
const ROLES := {
	&"idle": "mixamo/Z_Idle1", &"idle_alt": "mixamo/Z_Idle2", &"scratch": "mixamo/Z_Scratch",
	&"walk_f": "Zombie_Walk", &"shamble": "mixamo/Z_Walk", &"creep": "mixamo/Z_Creep",
	&"run_f": "mixamo/Z_Run", &"limp_f": "mixamo/Injured_Walk",
	&"crawl": "mixamo/Z_Crawl", &"lie": "mixamo/Z_StandUp",
	&"get_up": "mixamo/Z_StandUpBack", &"get_up_front": "mixamo/Z_StandUp",
	&"hit_chest": "mixamo/Z_Hit1", &"hit_chest2": "mixamo/Z_Hit2", &"hit_head": "mixamo/Z_Hit2",
	&"atk_swipe": "mixamo/Z_Swipe", &"atk_overhead": "mixamo/Z_Overhead", &"atk_punch": "mixamo/Z_Punch", &"atk_jab": "mixamo/Z_Jab",
	&"emote_scream": "mixamo/Z_Scream", &"emote_alert": "mixamo/Z_Alert", &"emote_agonize": "mixamo/Z_Agonize",
}
## Cycles to measure (clip name in its library) -> the bones to measure with.
const MEASURE := {
	"Zombie_Walk": ["LeftToes", "RightToes"], "mixamo/Z_Walk": ["LeftToes", "RightToes"],
	"mixamo/Z_Creep": ["LeftToes", "RightToes"], "mixamo/Z_Run": ["LeftToes", "RightToes"],
	"mixamo/Injured_Walk": ["LeftToes", "RightToes"], "mixamo/Z_Crawl": ["LeftHand", "RightHand"],
}


func _ready() -> void:
	var ual: AnimationLibrary = load(MQ + "anims/ual.res")
	var mixamo: AnimationLibrary = load(MQ + "anims/mixamo.res")
	var scene := (load(DIR + "zombie.glb") as PackedScene).instantiate()
	add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D

	var set := AnimationSet.new()
	for r: StringName in ROLES:
		var clip := String(ROLES[r])
		if _find(clip, ual, mixamo) == null:
			push_warning("missing clip for role %s: %s" % [r, clip])
			continue
		set.roles[r] = clip
	for clip: String in MEASURE:
		var a := _find(clip, ual, mixamo)
		if a == null:
			continue
		var m: Array = Measure.measure(a, sk, MEASURE[clip][0], MEASURE[clip][1])
		set.authored_speed[clip] = m[0]
		set.plant_phase[clip] = 0.0
		print("%-22s speed %.3f m/s  len %.2f s" % [clip, m[0], a.length])
	for lib: AnimationLibrary in [ual, mixamo]:
		for n in lib.get_animation_list():
			set.loops[String(n)] = lib.get_animation(n).loop_mode != Animation.LOOP_NONE
	print("animset save: ", ResourceSaver.save(set, DIR + "zombie_animset.tres"), "  roles ", set.roles.size())

	# Hit capsules from the idle pose (character space: feet at the origin, -Z forward).
	UltraPoseSampler.pose(mixamo.get_animation("Z_Idle1"), sk, 0.0)
	var p := func(b: String) -> Vector3:
		var v := UltraPoseSampler.global_pose(sk, sk.find_bone(b)).origin
		return Vector3(-v.x, v.y, -v.z)
	var boxes := UltraHitboxes.build(p)
	var head: Vector3 = p.call("Head")
	print("zombie head at ", head, ", ", boxes.size(), " capsules")

	var bp := BodyProfile.new()
	bp.visual_tier = BodyProfile.Tier.LITE
	bp.cap_meshes = false
	bp.body_scene = load(DIR + "zombie.glb")
	bp.anim_set = set
	bp.library = ual
	bp.extra_libraries = {"mixamo": mixamo}
	bp.model_faces_positive_z = true
	bp.skeleton_name = "GeneralSkeleton"
	bp.head_mesh_name = ""
	bp.body_mesh_name = "BodyMesh"
	bp.eye_offset = Vector3(0.0, 0.075, -0.1)
	bp.hitboxes = boxes
	if ResourceLoader.exists(DIR + "zombie_cuts.glb"):
		bp.cut_scene = load(DIR + "zombie_cuts.glb")     # (tools/blender make-cuts, see CLAUDE.md)
	print("body profile save: ", ResourceSaver.save(bp, DIR + "zombie_body_profile.tres"))

	# Movement: slow and heavy; a zombie never jumps, rolls, slides, leans or balances on edges.
	var mp := MovementProfile.new()
	mp.default_view = MovementProfile.View.THIRD_PERSON
	mp.allow_view_toggle = false
	mp.tp_rotation = MovementProfile.Rotation.FACE_AIM
	mp.default_gait = MovementProfile.Gait.WALK
	mp.walk_speed = 0.9
	mp.jog_speed = 1.6
	mp.sprint_speed = 3.2
	mp.crouch_speed = 0.9
	mp.crawl_speed = 0.5
	mp.back_mult = 0.5
	mp.strafe_mult = 0.7
	mp.accel = 3.5
	mp.decel = 7.0
	mp.sprint_stop_decel = 7.0
	mp.brake_decel = 9.0
	mp.turn_rate_walk = 300.0
	mp.turn_rate_sprint = 200.0
	mp.body_turn_rate = 200.0
	mp.character_collision = MovementProfile.CharacterCollision.SOFT
	mp.separation_speed = 1.6
	mp.mass = 75.0
	mp.push_strength = 250.0
	mp.enable_slide = false
	mp.enable_roll = false
	mp.enable_lean = false
	mp.enable_turn_in_place = false
	mp.enable_balance = false
	mp.enable_crouch = false
	mp.enable_crawl = true
	mp.enable_traversal = false
	mp.enable_swim = true
	mp.get_up_time = 4.0
	mp.impact_knockdown = 30.0
	print("movement save: ", ResourceSaver.save(mp, DIR + "zombie_movement.tres"))

	# Damage: torso soaks, the head kills (limb hp, not overall hp), no bleeding out.
	var dp := DamageProfile.new()
	dp.region_hp = PackedFloat32Array([60, 100, 45, 40, 45, 40, 70, 60, 70, 60, 25, 25, 32, 32])
	dp.region_mult = PackedFloat32Array([0.6, 0.3, 0.1, 0.08, 0.1, 0.08, 0.12, 0.1, 0.12, 0.1, 0.04, 0.04, 0.05, 0.05])
	dp.bleed_rate = PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	dp.cripple_bleed_rate = 0.0
	dp.heart_radius = 0.0
	dp.heart_bleed_rate = 0.0
	dp.ko_head = 9999.0
	dp.ko_heavy = 9999.0
	dp.knockdown_damage = 12.0
	dp.sever_overkill = 30.0
	dp.halve_survives = true
	dp.injured_leg_speed = 0.75
	dp.crippled_leg_speed = 0.55
	print("damage save: ", ResourceSaver.save(dp, DIR + "zombie_damage.tres"))
	scene.queue_free()


## A role's clip: "lib/name" from the named library, a bare name from the Quaternius one.
func _find(clip: String, ual: AnimationLibrary, mixamo: AnimationLibrary) -> Animation:
	if clip.begins_with("mixamo/"):
		var n := clip.substr(7)
		return mixamo.get_animation(n) if mixamo.has_animation(n) else null
	return ual.get_animation(clip) if ual.has_animation(clip) else null
