extends "res://tests/suites/s2_sinew_body.gd"
## Sinew stage 3: a standing SinewCharacter is POWERED - a physical body whose muscles track the
## animation (the pelvis held to the animated hips by the root drive), shown as is. A hit pushes
## the part it struck and the body recovers; walking it keeps up; knocked down it carries on from
## its own motion.


func before_each() -> void:
	powered = true


## Each part's physics position against the animated pose (world), worst distance.
func _track_error(r: SinewRagdoll) -> float:
	var anim := r._anim_world()
	var worst := 0.0
	for i in mini(anim.size(), r.pose_now.size()):
		worst = maxf(worst, (anim[i] as Transform3D).origin.distance_to(r.pose_now[i].origin))
	return worst


func test_standing_is_powered_and_tracks_the_animation() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	check(r._powered_on and r.modifier.blend > 0.99, "standing: powered, the skeleton shows the physics (blend %.2f)" % r.modifier.blend)
	# Positions (the elbow is a hinge: a clip's forearm twist is the one rotation it can't
	# copy, ~15 deg; the hand still lands within ~5 cm).
	var worst := 0.0
	for i in 60:
		await ticks(1)
		worst = maxf(worst, _track_error(r))
	info("standing: worst part %.3f m off the animation over a second" % worst)
	check(worst < 0.07, "every part within 7 cm of its animated place (worst %.3f m)" % worst)


func test_walking_powered_keeps_up() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	await ticks(30)
	var r := c.ragdoll as SinewRagdoll
	var worst := 0.0
	var fastest := 0.0
	var b := bot(c)
	b.set_steps([{"ticks": 150, "move": Vector2(0, 1)}])
	for i in 150:
		await ticks(1)
		if i > 30:
			worst = maxf(worst, _track_error(r))
			fastest = maxf(fastest, r.max_speed())
	info("walking: worst part %.3f m off the animation, fastest part %.1f m/s" % [worst, fastest])
	check(r._powered_on, "still powered while walking")
	check(worst < 0.15, "keeps up with the walk (worst %.3f m)" % worst)
	check(fastest < 6.0, "no part flailing (%.1f m/s)" % fastest)


func test_a_hit_pushes_the_part_and_it_recovers() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position + Vector3(1.5, 0, 0))
	await ticks(60)
	var r := c.ragdoll as SinewRagdoll
	var arm: int = r._part("LeftHand")      # (the upper arm's origin is its shoulder pivot)
	var before := _arm_off(r, arm)
	c.react_to_hit(UltraLimbs.Region.ARM_L, Vector3(1, 0, 0), 40.0)    # 20 N s
	var peak := 0.0
	for i in 20:
		await ticks(1)
		peak = maxf(peak, _arm_off(r, arm))
	await ticks(60)
	var after := _arm_off(r, arm)
	info("left arm: %.3f m off before, %.3f at the hit's peak, %.3f a second later" % [before, peak, after])
	check(peak > before + 0.06, "the shot knocks the arm away (the limb goes slack for a moment)")
	check(after < before + 0.02, "and the muscles bring it back")


func _arm_off(r: SinewRagdoll, part: int) -> float:
	var anim := r._anim_world()
	return (anim[part] as Transform3D).origin.distance_to(r.pose_now[part].origin) if part < anim.size() else 0.0


func test_spawn_and_teleport_snap_onto_the_animation() -> void:
	load_playground()
	var c := _sinew(marker("spawn").global_position)
	var worst_spawn := 0.0
	for i in 40:
		await ticks(1)
		if i > 20:
			worst_spawn = maxf(worst_spawn, _track_error(c.ragdoll as SinewRagdoll))
	c.teleport(c.state.pos + Vector3(10, 0, 5), 0.0)
	var worst_tp := 0.0
	for i in 40:
		await ticks(1)
		if i > 3:
			worst_tp = maxf(worst_tp, _track_error(c.ragdoll as SinewRagdoll))
	info("just spawned: worst %.3f m; after a 11 m teleport: worst %.3f m" % [worst_spawn, worst_tp])
	check(worst_spawn < 0.10, "no T-pose creeping down after the spawn (%.3f m)" % worst_spawn)
	check(worst_tp < 0.10, "no body left behind by a teleport (%.3f m)" % worst_tp)
