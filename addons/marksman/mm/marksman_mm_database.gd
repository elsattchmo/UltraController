class_name MarksmanMMDatabase
extends RefCounted
## Motion matching (spike): a database of locomotion clip frames and what each frame is doing - where the feet are
## and how they move, how the hips move, and where the character will be over the next second - searched for the
## frame that best continues the pose on screen toward where the motor is taking the body (Clavet 2016, Holden's
## "Learned Motion Matching" features). Built at load from clips that are IN PLACE (every Mixamo intake clip is): the
## ground velocity of a frame is what its planted foot slides back by.
##
## Space: the skeleton's (model) space, +Z = the model's forward; the root is the skeleton origin on the ground.

const FPS := 30.0
## Trajectory sample times (s ahead).
const TRAJ_T: Array[float] = [0.33, 0.67, 1.0]
## Feature layout: left foot pos (3), right foot pos (3), left foot vel (3), right foot vel (3), hips vel (3),
## trajectory positions (x, z) x 3, trajectory velocities (x, z) x 3.
const DIM := 27
const GROUPS := [[0, 6], [6, 12], [12, 15], [15, 21], [21, 27]]
## Group weights: foot positions, foot velocities, hips velocity, trajectory positions, trajectory velocities.
var weights: Array[float] = [0.75, 1.0, 1.0, 1.0, 1.5]

## Per clip: {name (the player's animation name), anim, loop, length, vel (Vector2, m/s), ground (m: its soles' floor height,
## skeleton space), start (first frame index), count}.
var clips: Array[Dictionary] = []
var frame_clip := PackedInt32Array()
var frame_time := PackedFloat32Array()
## Per frame: bit 0 = the left foot is planted, bit 1 = the right.
var contact := PackedByteArray()
## Raw and normalised (and weighted) features, DIM per frame.
var raw := PackedFloat32Array()
var feats := PackedFloat32Array()
var mean := PackedFloat32Array()
var scale := PackedFloat32Array()


## clips: [{name: StringName, anim: Animation}] (loop from the animation's loop mode).
func build(sk: Skeleton3D, list: Array) -> void:
	var lf := sk.find_bone("LeftFoot")
	var rf := sk.find_bone("RightFoot")
	var lt := sk.find_bone("LeftToes")
	var rt := sk.find_bone("RightToes")
	var hips := sk.find_bone("Hips")
	# Sole points in each foot bone's frame (from rest): heel under the ankle 6 cm back, ball under the toe joint.
	var soles := []
	for fb: Array in [[lf, lt], [rf, rt]]:
		var rest := sk.get_bone_global_rest(fb[0])
		var tr := sk.get_bone_global_rest(fb[1])
		soles.append([rest.affine_inverse() * Vector3(rest.origin.x, 0.0, rest.origin.z - 0.06),
				rest.affine_inverse() * Vector3(tr.origin.x, 0.0, tr.origin.z)])
	for spec: Dictionary in list:
		var a: Animation = spec.anim
		var loop := a.loop_mode != Animation.LOOP_NONE
		var n60 := maxi(2, int(ceil(a.length * 60.0)))
		var dt60 := a.length / n60
		var P := {"lf": [], "rf": [], "lt": [], "rt": [], "hips": []}
		var lows: Array[float] = []
		for i in n60 + 1:
			var g := SinewGaitCycles._globals(a, sk, minf(i * dt60, a.length))
			P.lf.append(g[lf].origin)
			P.rf.append(g[rf].origin)
			P.lt.append(g[lt].origin)
			P.rt.append(g[rt].origin)
			P.hips.append(g[hips].origin)
			var lo := INF
			for k2 in 2:
				var fx: Transform3D = g[lf] if k2 == 0 else g[rf]
				for pt: Vector3 in soles[k2]:
					lo = minf(lo, (fx * pt).y)
			lows.append(lo)
		var vel := _ground_velocity(P, n60, dt60)
		# Where this clip's floor is (the lower sole's 5th percentile): clips are authored a few cm off the ground.
		lows.sort()
		var c := {"name": spec.name, "anim": a, "loop": loop, "length": a.length, "vel": vel, "ground": lows[int(lows.size() * 0.05)],
				"start": frame_clip.size(), "count": 0, "speed": vel.length()}
		var miny := [_min_y(P.lf), _min_y(P.rf), _min_y(P.lt), _min_y(P.rt)]
		var nf := maxi(1, int(floor(a.length * FPS)))
		var root_v := Vector3(vel.x, 0.0, vel.y)
		for k in nf:
			var t := k / FPS
			var i := clampi(int(round(t / dt60)), 0, n60)
			var i0 := mini(i, n60 - 1)
			var j0 := i0 + 1
			var f := PackedFloat32Array()
			f.resize(DIM)
			var l_pos: Vector3 = P.lf[i]
			var r_pos: Vector3 = P.rf[i]
			var l_v: Vector3 = ((P.lf[j0] as Vector3) - (P.lf[i0] as Vector3)) / dt60 + root_v
			var r_v: Vector3 = ((P.rf[j0] as Vector3) - (P.rf[i0] as Vector3)) / dt60 + root_v
			var h_v: Vector3 = ((P.hips[j0] as Vector3) - (P.hips[i0] as Vector3)) / dt60 + root_v
			_put(f, 0, l_pos)
			_put(f, 3, r_pos)
			_put(f, 6, l_v)
			_put(f, 9, r_v)
			_put(f, 12, h_v)
			for s in TRAJ_T.size():
				var p := vel * TRAJ_T[s]
				f[15 + s * 2] = p.x
				f[16 + s * 2] = p.y
				f[21 + s * 2] = vel.x
				f[22 + s * 2] = vel.y
			raw.append_array(f)
			frame_clip.append(clips.size())
			frame_time.append(t)
			# Planted: the foot (ankle or toe) low and hardly moving over the ground.
			var bits := 0
			for side in 2:
				var ank: Vector3 = P.lf[i] if side == 0 else P.rf[i]
				var toe: Vector3 = P.lt[i] if side == 0 else P.rt[i]
				var low: bool = ank.y < float(miny[side]) + 0.05 or toe.y < float(miny[side + 2]) + 0.025
				var v: Vector3 = l_v if side == 0 else r_v
				if low and Vector2(v.x, v.z).length() < maxf(0.6, 0.3 * vel.length()):
					bits |= 1 << side
			contact.append(bits)
			c.count += 1
		clips.append(c)
	_normalise()


func size() -> int:
	return frame_clip.size()


## The frame index playing at time t of clip ci.
func frame_at(ci: int, t: float) -> int:
	var c := clips[ci]
	var k := int(floor(t * FPS))
	k = posmod(k, c.count) if c.loop else clampi(k, 0, c.count - 1)
	return c.start + k


## The query: frame fi's pose (feet, hips) as the BODY moves it - its own motion relative to the root plus the body's
## velocity `body_v` (skeleton xz) in place of the clip's (a clip that doesn't move the way the body does - the idle
## still playing as the body sets off - would otherwise ask for more of itself) - and `traj` (raw, 12 values: 6
## positions, 6 velocities) for the trajectory.
func query_from(fi: int, traj: PackedFloat32Array, body_v := Vector2.INF) -> PackedFloat32Array:
	var q := PackedFloat32Array()
	q.resize(DIM)
	var dv := Vector2.ZERO
	if body_v != Vector2.INF:
		dv = body_v - (clips[frame_clip[fi]].vel as Vector2)
	for d in 15:
		var v := raw[fi * DIM + d]
		if d >= 6:                  # velocities: x and z of each
			var k := (d - 6) % 3
			v += dv.x if k == 0 else (dv.y if k == 2 else 0.0)
		q[d] = (v - mean[d]) * scale[d]
	for d in 12:
		q[15 + d] = (traj[d] - mean[15 + d]) * scale[15 + d]
	return q


## Best frame for q: [index, cost]. Frames of `skip_clip` within `skip_t` s of `skip_time` are left out (a match
## that is where we already are is no match). Non-looping clips: not the last 0.2 s.
func search(q: PackedFloat32Array, skip_clip := -1, skip_time := 0.0, skip_t := 0.2) -> Array:
	var best := -1
	var best_c := INF
	var n := size()
	for fi in n:
		var base := fi * DIM
		# Trajectory first (it decides most): stop as soon as this frame can't win.
		var c := 0.0
		for d in range(15, DIM):
			var e := feats[base + d] - q[d]
			c += e * e
		if c >= best_c:
			continue
		for d in 15:
			var e := feats[base + d] - q[d]
			c += e * e
			if c >= best_c:
				break
		if c >= best_c:
			continue
		var ci := frame_clip[fi]
		if ci == skip_clip:
			var cl := clips[ci]
			var dt := absf(frame_time[fi] - skip_time)
			if cl.loop:
				dt = minf(dt, cl.length - dt)
			if dt < skip_t:
				continue
		if not clips[ci].loop and frame_time[fi] > clips[ci].length - 0.2:
			continue
		best_c = c
		best = fi
	return [best, best_c]


func cost(q: PackedFloat32Array, fi: int) -> float:
	var c := 0.0
	for d in DIM:
		var e := feats[fi * DIM + d] - q[d]
		c += e * e
	return c


## Ground velocity of an in-place clip (m/s, skeleton xz): the lower foot's slide back while it is down, averaged.
func _ground_velocity(P: Dictionary, n: int, dt: float) -> Vector2:
	var miny := minf(_min_y(P.lt), _min_y(P.rt))
	var sum := Vector2.ZERO
	var k := 0
	for i in n:
		var lo := "lt" if (P.lt[i] as Vector3).y <= (P.rt[i] as Vector3).y else "rt"
		var p: Vector3 = P[lo][i]
		var q: Vector3 = P[lo][i + 1]
		if p.y > miny + 0.04:
			continue
		sum -= Vector2(q.x - p.x, q.z - p.z) / dt
		k += 1
	var v := sum / maxi(k, 1)
	return v if v.length() > 0.08 else Vector2.ZERO


func _normalise() -> void:
	var n := size()
	mean.resize(DIM)
	scale.resize(DIM)
	for d in DIM:
		var m := 0.0
		for fi in n:
			m += raw[fi * DIM + d]
		mean[d] = m / maxi(n, 1)
	for gi in GROUPS.size():
		var g: Array = GROUPS[gi]
		var var_sum := 0.0
		for d in range(g[0], g[1]):
			for fi in n:
				var e := raw[fi * DIM + d] - mean[d]
				var_sum += e * e
		var sd := sqrt(var_sum / maxi(n * (int(g[1]) - int(g[0])), 1))
		for d in range(g[0], g[1]):
			scale[d] = weights[gi] / maxf(sd, 1e-3)
	feats.resize(raw.size())
	for fi in n:
		for d in DIM:
			feats[fi * DIM + d] = (raw[fi * DIM + d] - mean[d]) * scale[d]


static func _put(f: PackedFloat32Array, at: int, v: Vector3) -> void:
	f[at] = v.x
	f[at + 1] = v.y
	f[at + 2] = v.z


static func _min_y(ps: Array) -> float:
	var m := INF
	for p: Vector3 in ps:
		m = minf(m, p.y)
	return m
