extends SceneTree
## Motion-matching spike: what each candidate locomotion clip does - in place or not (hips drift), its ground
## velocity from the planted foot (skeleton space, +Z = the model's forward), how that changes over the clip.
## Run: godot --headless --path . --script res://tools/marksman/mm_probe.gd

const DIR := "res://assets/characters/mannequin/"
const AnimMeasure := preload("res://tools/anim_measure.gd")

const CLIPS := ["mixamo/N_StdWalk2", "mixamo/U_Walk_F", "mixamo/U_Walk_B", "mixamo/U_Walk_L", "mixamo/U_Walk_R",
	"mixamo/U_Run_F", "mixamo/U_Run_B", "mixamo/U_Run_L", "mixamo/U_Run_R", "mixamo/U_Sprint_F", "mixamo/S_Fast",
	"mixamo/Strafe_Walk_L", "mixamo/Strafe_Walk_R", "Walk_Backwards", "mixamo/LMM_Walking", "mixamo/LMM_StandardRun",
	"mixamo/LMM_LeftStrafeWalking", "mixamo/LMM_RightStrafeWalking", "mixamo/LMM_LeftStrafe", "mixamo/LMM_RightStrafe",
	"mixamo/LMM_Idle", "mixamo/SHT_StartWalking", "mixamo/SHT_StopWalking", "mixamo/SHT_StartWalkingBackwards",
	"mixamo/SHT_WalkBackwardsStop", "mixamo/SHT_Walking", "mixamo/SHT_WalkingBackwards", "mixamo/SHT_Strafe",
	"mixamo/SHT_Strafe2", "mixamo/AAD_RunToStop", "mixamo/AAD_Walking", "mixamo/AAD_Running", "mixamo/LOC_Running",
	"mixamo/PST_PistolWalkArc", "mixamo/PST_PistolRunArc", "Idle_A"]


func _init() -> void:
	var libs := {"mixamo": load(DIR + "anims/mixamo.res"), "": load(DIR + "anims/ual.res")}
	var scene: Node = (load(DIR + "mannequin.glb") as PackedScene).instantiate()
	root.add_child(scene)
	var sk := scene.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var hips := sk.find_bone("Hips")
	var toes := [sk.find_bone("LeftToes"), sk.find_bone("RightToes")]
	for clip: String in CLIPS:
		var lib: AnimationLibrary = libs.get(clip.get_slice("/", 0) if clip.contains("/") else "")
		var key := clip.get_slice("/", 1) if clip.contains("/") else clip
		if lib == null or not lib.has_animation(key):
			print("%-36s MISSING" % clip)
			continue
		var a := lib.get_animation(key)
		var n := int(a.length * 60.0)
		var hp: Array[Vector3] = []
		var tp := [[], []]
		for i in n + 1:
			AnimMeasure.pose(a, sk, minf(a.length * i / n, a.length))
			hp.append(AnimMeasure.global_pose(sk, hips).origin)
			for f in 2:
				tp[f].append(AnimMeasure.global_pose(sk, toes[f]).origin)
		var miny := minf(_min_y(tp[0]), _min_y(tp[1]))
		# Ground velocity per frame: minus the lower foot's slide while it is down (in place clips).
		var vel: Array[Vector2] = []
		var dt := a.length / n
		for i in n:
			var lo := 0 if (tp[0][i] as Vector3).y <= (tp[1][i] as Vector3).y else 1
			var p: Vector3 = tp[lo][i]
			var q: Vector3 = tp[lo][i + 1]
			if p.y > miny + 0.04:
				vel.append(Vector2(INF, INF))
				continue
			vel.append(-Vector2(q.x - p.x, q.z - p.z) / dt)
		# Windows of 0.25 s: the mean ground velocity.
		var segs := []
		var w := maxi(1, int(0.25 / dt))
		for s in range(0, n, w):
			var m := Vector2.ZERO
			var k := 0
			for i in range(s, mini(s + w, n)):
				if vel[i].x != INF:
					m += vel[i]
					k += 1
			segs.append("%4.2f@%4.0f" % [(m / maxi(k, 1)).length(), rad_to_deg((m / maxi(k, 1)).angle_to(Vector2(0, 1)))] if k > 0 else "  -- ")
		var drift := Vector2(hp[n].x - hp[0].x, hp[n].z - hp[0].z)
		print("%-36s %5.2fs loop=%d hips drift %5.2f m  | %s" % [clip, a.length, a.loop_mode, drift.length(), " ".join(segs)])
	quit()


func _min_y(ps: Array) -> float:
	var m := INF
	for p: Vector3 in ps:
		m = minf(m, p.y)
	return m
