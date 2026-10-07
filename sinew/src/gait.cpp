#include "sinew/gait.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <cmath>

namespace sinew {

namespace {

float frac(float x) { return x - std::floor(x); }
float smooth(float s) { return s * s * (3.0f - 2.0f * s); }
float smoothstep(float a, float b, float x) { return b > a ? smooth(std::clamp((x - a) / (b - a), 0.0f, 1.0f)) : (x >= b ? 1.0f : 0.0f); }
Vec3 flat(Vec3 v, Vec3 up) { return v - up * dot(v, up); }

// Rotate a part and everything below it by R about `pivot` (world).
void turn_subtree(std::vector<Transform>& w, const Rig& rig, int part, Quat R, Vec3 pivot) {
	for (int i : rig.subtree(part)) {
		w[size_t(i)].q = normalized(R * w[size_t(i)].q);
		w[size_t(i)].p = pivot + rotate(R, w[size_t(i)].p - pivot);
	}
}

} // namespace

Gait::Gait(const Rig& rig, const Limbs& limbs, const PhysicsWorld* world, const GaitSettings& settings) :
		_rig(rig), _limbs(limbs), _world(world), _s(settings) {
	const size_t n = rig.parts.size();
	_rest_local.resize(n);
	_pose.resize(n);
	for (size_t i = 0; i < n; ++i) {
		const int p = rig.parts[i].parent;
		_rest_local[i] = p < 0 ? rig.parts[i].rest.q : normalized(conj(rig.parts[size_t(p)].rest.q) * rig.parts[i].rest.q);
	}
	const LimbId legs[2] = { LimbId::LegL, LimbId::LegR };
	for (int i = 0; i < 2; ++i) {
		const LimbInfo& l = limbs.limb(legs[i]);
		_leg[i] = l.upper >= 0 && l.lower >= 0 && l.end >= 0 ? int(legs[i]) : -1;
		_hip_model[i] = l.upper >= 0 ? rig.parts[size_t(l.upper)].rest.p : Vec3{};
	}
	const int foot = limbs.limb(LimbId::LegL).end;
	if (foot >= 0) {
		const PartDef& d = rig.parts[size_t(foot)];
		float sole = 0.0f;
		if (d.box) {
			const Transform box = d.rest * d.box_xform;
			sole = dot(box.p, rig.up) - d.box_half.y;
		}
		_ankle_h = dot(d.rest.p, rig.up) - sole;
		if (d.box) {
			const Transform box = d.rest * d.box_xform;
			const float heel_f = dot(box.p, rig.forward) - d.box_half.z;
			const float toe_f = dot(box.p, rig.forward) + d.box_half.z;
			const float ankle_f = dot(d.rest.p, rig.forward);
			_heel_d = std::max(ankle_f - heel_f, 0.02f);
			_ball_d = std::max(heel_f + 0.72f * (toe_f - heel_f) - ankle_f, 0.03f);
		}
	}
	{
		const LimbInfo& l = limbs.limb(LimbId::LegL);
		_leg_len = l.upper_len + l.lower_len + _ankle_h;
	}
	reset(Transform{});
}

void Gait::set_cycles(std::vector<GaitCycle> cycles) {
	_cycles.clear();
	for (GaitCycle& c : cycles) {
		if (!c.samples.empty() && c.samples[0].size() == _rig.parts.size()) {
			_cycles.push_back(std::move(c));
		}
	}
	std::sort(_cycles.begin(), _cycles.end(), [](const GaitCycle& a, const GaitCycle& b) { return a.speed < b.speed; });
}

void Gait::set_idle_pose(std::vector<Quat> locals, float pelvis_height) {
	_idle = locals.size() == _rig.parts.size() ? std::move(locals) : std::vector<Quat>{};
	_idle_height = pelvis_height;
}

Vec3 Gait::up() const {
	if (_world) {
		const Vec3 g = _world->gravity();
		if (length(g) > 1e-4f) {
			return -normalized(g);
		}
	}
	return Vec3{ 0, 1, 0 };
}

float Gait::ground_y(Vec3 p, float fallback) const {
	if (_world == nullptr) {
		return fallback;
	}
	const Vec3 U = up();
	const RayHit h = probes::ground_below(*_world, p + U * 0.6f, 1.6f);
	return h.hit ? dot(h.point, U) : fallback;
}

Vec3 Gait::home(int foot) const {
	const Vec3 U = up();
	const Vec3 hip = _hip_model[foot];
	const Vec3 lateral = hip - _rig.up * dot(hip, _rig.up);
	Vec3 p = xform(_root, lateral);
	p = flat(p, U) + U * (ground_y(p, dot(_root.p, U)) + _ankle_h);
	return p;
}

void Gait::reset(const Transform& root) {
	_root = root;
	_vel = Vec3{};
	_phase = 0.0f;
	_stepping = false;
	for (int i = 0; i < 2; ++i) {
		Foot& f = _feet[i];
		f.pos = f.eff = f.lift = f.target = home(i);
		f.pitch = f.lift_pitch = 0.0f;
		f.yaw = f.lift_yaw = root.q;
		f.swinging = false;
		f.p = frac(-0.5f * float(i));
	}
	std::vector<Quat> local;
	Quat pm;
	float ph;
	base_pose(local, pm, ph);
	solve(local, pm, ph);
}

void Gait::update(const GaitInput& in) {
	_root = in.root;
	_vel = flat(in.velocity, up());
	// A teleport: start again where it is now.
	if (length(flat(_feet[0].pos - home(0), up())) > 2.5f || length(flat(_feet[1].pos - home(1), up())) > 2.5f) {
		reset(in.root);
		_vel = flat(in.velocity, up());
	}
	step_feet(in.dt);
	std::vector<Quat> local;
	Quat pm;
	float ph;
	base_pose(local, pm, ph);
	solve(local, pm, ph);
}

void Gait::step_feet(float dt) {
	const Vec3 U = up();
	_speed = length(_vel);
	const bool moving = _speed > _s.stop_speed;
	_duty = moving ? _s.duty_walk + (_s.duty_run - _s.duty_walk) * smoothstep(_s.walk_speed, _s.run_speed, _speed) : _s.duty_walk;
	const float run = smoothstep(_s.walk_speed, _s.run_speed, _speed);
	const float step_max = (_s.step_max_walk + (_s.step_max_run - _s.step_max_walk) * run) * _leg_len;
	_cadence = moving ? std::clamp(std::max(_s.cadence_base + _s.cadence_per_ms * _speed, _speed / std::max(step_max, 0.1f)),
								_s.cadence_idle * 0.8f, _s.cadence_max)
					  : _s.cadence_idle;
	// Keep stepping while moving, while a foot is in the air, or while a foot is off its spot
	// (stopped mid-stride, nudged) or turned away from the facing (turning on the spot).
	bool settle = false;
	for (int i = 0; i < 2; ++i) {
		const Foot& f = _feet[i];
		if (f.swinging || length(flat(f.pos - home(i), U)) > _s.home_tolerance ||
				angle_between(f.yaw, _root.q) > _s.turn_tolerance) {
			settle = true;
		}
	}
	const bool was = _stepping;
	_stepping = moving || settle;
	if (!_stepping) {
		return;
	}
	if (!was) {
		// Starting off: the first step goes at once, with the foot that's behind (moving) or the
		// one furthest from where it should be (settling / turning).
		auto score = [&](int i) {
			const Foot& f = _feet[i];
			if (moving) {
				return -dot(flat(f.pos - _root.p, U), _vel);
			}
			return length(flat(f.pos - home(i), U)) + 0.2f * angle_between(f.yaw, _root.q);
		};
		const int first = score(0) >= score(1) ? 0 : 1;
		_phase = frac(_duty + 0.5f * float(first));
	}
	const float rate = _cadence * 0.5f;     // strides (two steps) per second
	_phase = frac(_phase + rate * dt);
	const float swing_h = _s.swing_height + (_s.swing_height_run - _s.swing_height) * smoothstep(_s.walk_speed, _s.run_speed, _speed);
	for (int i = 0; i < 2; ++i) {
		Foot& f = _feet[i];
		const float p = frac(_phase - 0.5f * float(i));
		const bool swing = p >= _duty;
		const float m = moving ? std::clamp(_speed / std::max(_s.walk_speed, 0.1f), 0.0f, 1.0f) : 0.0f;
		const float toe_up = _s.toe_up * m * (1.0f - 0.8f * run);
		if (swing && !f.swinging) {
			f.swinging = true;
			f.lift = f.eff;
			f.lift_yaw = f.yaw;
			f.lift_pitch = f.pitch;
		} else if (!swing && f.swinging) {
			// Down: the foot stays exactly here until it lifts again.
			f.swinging = false;
			f.pos = f.target;
			f.yaw = _root.q;
		}
		f.p = p;
		if (!f.swinging) {
			f.target = f.pos;
			// Heel strike (toes up, rolling flat), then the heel rising round the ball.
			const float q = std::clamp(p / std::max(_duty, 1e-3f), 0.0f, 1.0f);
			const float pitch = -toe_up * (1.0f - smoothstep(0.0f, 0.2f, q)) + _s.heel_rise * m * smoothstep(0.5f, 1.0f, q);
			roll(f, pitch);
			continue;
		}
		// Where to land: where the hip will be at touchdown, a little ahead of it (so the hip is
		// over the foot at mid-stance); standing still, its own spot.
		Vec3 land;
		if (moving) {
			const float t_rem = (1.0f - p) / rate;
			const float stance_t = _duty / rate;
			const Vec3 lateral = _hip_model[i] - _rig.up * dot(_hip_model[i], _rig.up);
			land = _root.p + _vel * (t_rem + 0.5f * stance_t) + rotate(_root.q, lateral);
		} else {
			land = home(i);
		}
		land = flat(land, U) + U * (ground_y(land, dot(_root.p, U)) + _ankle_h);
		f.target = land;
		const float s = std::clamp((p - _duty) / std::max(1.0f - _duty, 1e-3f), 0.0f, 1.0f);
		const float k = smooth(s);
		const Vec3 h = flat(f.lift, U) + (flat(land, U) - flat(f.lift, U)) * k;
		const float y = dot(f.lift, U) + (dot(land, U) - dot(f.lift, U)) * k + swing_h * std::sin(PI * s);
		f.pos = h + U * y;
		// In the air the foot turns from its push-off roll to toes up for the landing.
		f.pitch = f.lift_pitch + (-toe_up - f.lift_pitch) * smooth(s);
		f.eff = f.pos;
	}
}

void Gait::roll(Foot& f, float pitch) const {
	f.pitch = pitch;
	const Vec3 U = up();
	Vec3 fwd = flat(rotate(f.yaw, _rig.forward), U);
	fwd = length(fwd) > 1e-4f ? normalized(fwd) : Vec3{ 0, 0, 1 };
	const Vec3 left = normalized(cross(U, fwd));
	if (pitch >= 0.0f) {
		// Round the ball of the foot (on the ground ahead of the ankle): the heel and ankle rise.
		const Vec3 ball = f.pos + fwd * _ball_d - U * _ankle_h;
		f.eff = ball + rotate(axis_angle(left, pitch), f.pos - ball);
	} else {
		// Round the heel (on the ground behind the ankle): the toes are up.
		const Vec3 heel = f.pos - fwd * _heel_d - U * _ankle_h;
		f.eff = heel + rotate(axis_angle(left, pitch), f.pos - heel);
	}
}

void Gait::base_pose(std::vector<Quat>& local, Quat& pelvis_model, float& pelvis_h) const {
	const size_t n = _rig.parts.size();
	local = _idle.empty() ? _rest_local : _idle;
	pelvis_model = local[0];
	pelvis_h = _idle_height > 0.0f ? _idle_height : dot(_rig.parts[0].rest.p, _rig.up);
	if (_cycles.empty()) {
		return;
	}
	auto sample = [&](const GaitCycle& c, std::vector<Quat>& out, float& h) {
		const size_t m = c.samples.size();
		const float f = _phase * float(m);
		const size_t i0 = size_t(f) % m, i1 = (i0 + 1) % m;
		const float t = f - std::floor(f);
		out.resize(n);
		for (size_t k = 0; k < n; ++k) {
			out[k] = normalized(slerp(c.samples[i0][k], c.samples[i1][k], t));
		}
		h = c.pelvis_height.size() == m ? c.pelvis_height[i0] + (c.pelvis_height[i1] - c.pelvis_height[i0]) * t : pelvis_h;
	};
	// The two cycles either side of the speed (below the slowest: blended with standing).
	size_t hi = 0;
	while (hi < _cycles.size() && _cycles[hi].speed < _speed) {
		++hi;
	}
	std::vector<Quat> a, b;
	float ha = pelvis_h, hb = pelvis_h, w = 0.0f;
	if (hi == 0) {
		a = local;
		sample(_cycles[0], b, hb);
		w = _stepping ? std::clamp(_speed / std::max(_cycles[0].speed, 0.05f), 0.0f, 1.0f) : 0.0f;
		w = std::max(w, _stepping ? 0.35f : 0.0f);   // stepping on the spot still lifts the feet like a walk
	} else if (hi >= _cycles.size()) {
		sample(_cycles.back(), a, ha);
		b = a;
		hb = ha;
	} else {
		sample(_cycles[hi - 1], a, ha);
		sample(_cycles[hi], b, hb);
		w = std::clamp((_speed - _cycles[hi - 1].speed) / std::max(_cycles[hi].speed - _cycles[hi - 1].speed, 0.05f), 0.0f, 1.0f);
	}
	for (size_t k = 0; k < n; ++k) {
		local[k] = normalized(slerp(a[k], b[k], w));
	}
	pelvis_model = local[0];
	pelvis_h = ha + (hb - ha) * w;
}

void Gait::solve(const std::vector<Quat>& local, Quat pelvis_model, float pelvis_h) {
	const Rig& rig = _rig;
	const size_t n = rig.parts.size();
	const Vec3 U = up();
	const float run = smoothstep(_s.walk_speed, _s.run_speed, _speed);
	const float m = _stepping ? std::clamp(_speed / std::max(_s.walk_speed, 0.1f), 0.0f, 1.0f) : 0.0f;
	const float c2 = std::cos(2.0f * PI * _phase);
	const Vec3 fwd = normalized(rotate(_root.q, rig.forward));
	const Vec3 left = normalized(cross(U, fwd));
	const bool procedural = _cycles.empty();
	// Pelvis: over the ground point at its height, bobbing (lowest at each contact), swaying
	// toward the standing foot, lower at a run.
	Vec3 P = _root.p + U * pelvis_h;
	if (procedural) {
		P += U * (-_s.bob * m * std::cos(4.0f * PI * _phase) - _s.run_crouch * run);
		P += left * (_s.sway * m * std::sin(2.0f * PI * _phase));
	}
	Quat Pq = normalized(_root.q * pelvis_model);
	if (procedural) {
		Pq = normalized(axis_angle(U, 0.5f * _s.spine_twist * m * c2) * Pq);
	}
	// The hips must reach both ankles: lower the pelvis for a low foothold.
	float drop = 0.0f;
	for (int i = 0; i < 2; ++i) {
		if (_leg[i] < 0) {
			continue;
		}
		const LimbInfo& l = _limbs.limb(LimbId(_leg[i]));
		const float L = (l.upper_len + l.lower_len) * _s.max_reach;
		const Vec3 hip = P + rotate(Pq, rig.parts[size_t(l.upper)].frame_parent.p);
		const Vec3 d = hip - _feet[i].eff;
		const float dh = length(flat(d, U));
		const float dz = dot(d, U);
		const float allowed = std::sqrt(std::max(L * L - dh * dh, 0.0f));
		drop = std::max(drop, dz - allowed);
	}
	P -= U * drop;
	// Forward kinematics of the base pose.
	_pose[0] = Transform{ P, Pq };
	for (size_t i = 1; i < n; ++i) {
		const PartDef& d = rig.parts[i];
		const Transform& w = _pose[size_t(d.parent)];
		_pose[i] = Transform{ xform(w, d.frame_parent.p), normalized(w.q * local[i]) };
	}
	if (procedural) {
		// Spine: leaning into speed, counter-twisting against the pelvis.
		const int spine = rig.find("Spine");
		if (spine >= 0) {
			const Quat R = axis_angle(U, -_s.spine_twist * m * c2) * axis_angle(left, 0.1f * run);
			turn_subtree(_pose, rig, spine, R, _pose[size_t(spine)].p);
		}
		// Arms: down from the rest (T) pose, swinging against the legs (left arm back as the left
		// foot lands).
		const float amp = (_s.arm_swing + (_s.arm_swing_run - _s.arm_swing) * run) * m;
		const char* arms[2] = { "LeftUpperArm", "RightUpperArm" };
		for (int s = 0; s < 2; ++s) {
			const int a = rig.find(arms[s]);
			if (a < 0) {
				continue;
			}
			const float side = s == 0 ? 1.0f : -1.0f;
			const Quat down = axis_angle(fwd, -side * _s.arms_down);
			const Quat swing = axis_angle(left, side * amp * c2);
			turn_subtree(_pose, rig, a, normalized(swing * down), _pose[size_t(a)].p);
		}
	}
	// Legs onto the footholds.
	for (int i = 0; i < 2; ++i) {
		if (_leg[i] < 0) {
			continue;
		}
		const LimbInfo& l = _limbs.limb(LimbId(_leg[i]));
		const PartDef& th = rig.parts[size_t(l.upper)];
		const Vec3 hip = xform(_pose[size_t(th.parent)], th.frame_parent.p);
		Quat upper_world, lower_local;
		two_bone_ik(rig, l, hip, _pose[size_t(l.upper)].q, _feet[i].eff, upper_world, lower_local);
		_pose[size_t(l.upper)] = Transform{ hip, upper_world };
		const PartDef& sh = rig.parts[size_t(l.lower)];
		_pose[size_t(l.lower)] = Transform{ xform(_pose[size_t(l.upper)], sh.frame_parent.p), normalized(upper_world * lower_local) };
		// The foot: flat with the yaw it was put down with; turning toward the facing in the air.
		const Foot& f = _feet[i];
		Quat yaw = f.yaw;
		if (f.swinging) {
			const float s = std::clamp((f.p - _duty) / std::max(1.0f - _duty, 1e-3f), 0.0f, 1.0f);
			yaw = normalized(slerp(f.lift_yaw, _root.q, smooth(s)));
		}
		Vec3 ffwd = flat(rotate(yaw, rig.forward), U);
		ffwd = length(ffwd) > 1e-4f ? normalized(ffwd) : fwd;
		const Quat pitch = axis_angle(normalized(cross(U, ffwd)), f.pitch);
		const PartDef& ft = rig.parts[size_t(l.end)];
		_pose[size_t(l.end)] = Transform{ xform(_pose[size_t(l.lower)], ft.frame_parent.p), normalized(pitch * yaw * ft.rest.q) };
	}
}

} // namespace sinew
