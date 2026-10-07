#include "sinew/gait.hpp"

#include "sinew/balance.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <cmath>

namespace sinew {

namespace {

constexpr int MIN_STANCE_TICKS = 6;   // a foot just put down stays down this long before an early lift

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
	Vec3 p = _root.p + rotate(legs_q(), lateral);
	p = flat(p, U) + U * (ground_y(p, dot(_root.p, U)) + _ankle_h);
	return p;
}

Vec3 Gait::hip_ground(int foot) const {
	const Vec3 lateral = _hip_model[foot] - _rig.up * dot(_hip_model[foot], _rig.up);
	return _root.p + rotate(legs_q(), lateral);
}

float Gait::swing_s(const Foot& f, float p) const {
	// Through by the last tick before the cycle wraps (the foot is put down there, exactly).
	return std::clamp((p - f.lift_p) / std::max(1.0f - f.lift_p - _phase_step, 1e-3f), 0.0f, 1.0f);
}

Quat Gait::legs_q() const {
	return normalized(axis_angle(up(), _warp) * _root.q);
}

void Gait::reset(const Transform& root) {
	_root = root;
	_vel = Vec3{};
	_warp = 0.0f;
	_warp_back = false;
	_drop = 0.0f;
	_drive_acc = Vec3{};
	_trim = Vec3{};
	_lean = _lean_v = _acc = _prev_vel = Vec3{};
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
	_dt = std::max(in.dt, 1e-4f);
	_root = in.root;
	_vel = flat(in.velocity, up());
	_has_cmd = in.has_command;
	_cmd = in.has_command ? flat(in.command, up()) : _vel;
	// A teleport: start again where it is now.
	if (length(flat(_feet[0].pos - home(0), up())) > 2.5f || length(flat(_feet[1].pos - home(1), up())) > 2.5f) {
		reset(in.root);
		_vel = flat(in.velocity, up());
	}
	step_feet(in.dt);
	update_lean(in.dt);
	std::vector<Quat> local;
	Quat pm;
	float ph;
	base_pose(local, pm, ph);
	solve(local, pm, ph);
}

void Gait::update_lean(float dt) {
	if (dt <= 0.0f) {
		return;
	}
	const Vec3 U = up();
	const float g = _world ? std::max(length(_world->gravity()), 1.0f) : 9.81f;
	// The ground acceleration, lightly filtered (a capsule's speed steps tick to tick).
	const Vec3 a = flat((_vel - _prev_vel) * (1.0f / dt), U);
	_prev_vel = _vel;
	_acc = _acc + (a - _acc) * std::min(dt / 0.05f, 1.0f);
	Vec3 want = _acc * (_s.lean_gain / g);
	if (length(want) > _s.lean_max) {
		want = normalized(want) * _s.lean_max;
	}
	// Damped spring (sub-stepped: stable at any frame time), speed and angle capped.
	const float w = 2.0f * PI * _s.lean_hz;
	const int sub = std::max(1, int(std::ceil(w * dt / 0.3f)));
	const float h = dt / float(sub);
	for (int k = 0; k < sub; ++k) {
		_lean_v = _lean_v + ((want - _lean) * (w * w) - _lean_v * (2.0f * _s.lean_zeta * w)) * h;
		if (length(_lean_v) > _s.lean_rate) {
			_lean_v = normalized(_lean_v) * _s.lean_rate;
		}
		_lean = _lean + _lean_v * h;
		if (length(_lean) > _s.lean_max) {
			_lean = normalized(_lean) * _s.lean_max;
			_lean_v = _lean_v - normalized(_lean) * std::max(dot(_lean_v, normalized(_lean)), 0.0f);
		}
	}
	_lean = flat(_lean, U);
}

void Gait::step_feet(float dt) {
	const Vec3 U = up();
	_speed = length(_vel);
	const float want_speed = std::max(_speed, length(_cmd));
	const bool moving = want_speed > _s.stop_speed;
	_duty = moving ? _s.duty_walk + (_s.duty_run - _s.duty_walk) * smoothstep(_s.walk_speed, _s.run_speed, _speed) : _s.duty_walk;
	const float run = smoothstep(_s.walk_speed, _s.run_speed, _speed);
	// Hip warp toward the travel (off the facing), eased.
	{
		Vec3 F0 = flat(rotate(_root.q, _rig.forward), U);
		F0 = length(F0) > 1e-4f ? normalized(F0) : Vec3{ 0, 0, 1 };
		const Vec3 L0 = normalized(cross(U, F0));
		float want = 0.0f;
		if (moving) {
			const float th = std::atan2(dot(_vel, L0), dot(_vel, F0));
			const float a = std::fabs(th);
			if (a < 0.42f * PI) {
				_warp_back = false;
			} else if (a > 0.58f * PI) {
				_warp_back = true;
			}
			const float rel = _warp_back ? th - std::copysign(PI, th) : th;
			want = std::clamp(rel * _s.warp_gain, -_s.warp_max, _s.warp_max);
		}
		const float step = _s.warp_rate * dt;
		_warp += std::clamp(want - _warp, -step, step);
	}
	// Leg frame: forward / left of the legs.
	Vec3 F = flat(rotate(legs_q(), _rig.forward), U);
	F = length(F) > 1e-4f ? normalized(F) : Vec3{ 0, 0, 1 };
	const Vec3 Lv = normalized(cross(U, F));
	const float vf = dot(_vel, F), vl = dot(_vel, Lv);
	// The longest step depends on the direction: forward, backing, sideways (an ellipse between).
	float dir_scale = 1.0f, fwdness = 1.0f;
	if (_speed > 1e-3f) {
		const float cf = vf / _speed, cl = vl / _speed;
		const float a = cf >= 0.0f ? 1.0f : _s.step_back;
		dir_scale = 1.0f / std::sqrt((cf / a) * (cf / a) + (cl / _s.step_side) * (cl / _s.step_side));
		fwdness = std::clamp(cf, 0.0f, 1.0f);
	}
	const float step_max = (_s.step_max_walk + (_s.step_max_run - _s.step_max_walk) * run) * _leg_len * dir_scale;
	_step_max = step_max;
	_cadence = moving ? std::clamp(std::max(_s.cadence_base + _s.cadence_per_ms * want_speed, want_speed / std::max(step_max, 0.1f)),
								_s.cadence_idle * 0.8f, _s.cadence_max)
					  : _s.cadence_idle;
	// Keep stepping while moving, while a foot is in the air, or while a foot is off its spot
	// (stopped mid-stride, nudged) or turned away from the facing (turning on the spot).
	bool settle = false;
	for (int i = 0; i < 2; ++i) {
		const Foot& f = _feet[i];
		if (f.swinging || length(flat(f.pos - home(i), U)) > _s.home_tolerance ||
				angle_between(f.yaw, legs_q()) > _s.turn_tolerance) {
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
				return -dot(flat(f.pos - _root.p, U), _speed > 0.05f ? _vel : _cmd);
			}
			return length(flat(f.pos - home(i), U)) + 0.2f * angle_between(f.yaw, legs_q());
		};
		const int first = score(0) >= score(1) ? 0 : 1;
		_phase = frac(_duty + 0.5f * float(first));
	}
	// A standing foot stretched out behind the motion hurries the cycle (so it gets its turn to
	// lift sooner) - continuous, unlike a jump in phase, so a swinging foot never skips.
	// (Stretched = past the longest step, or well past where this stride's stance ends.)
	const float base_rate = _cadence * 0.5f;
	const float reach_out = std::max(_s.stretch * step_max, 1.35f * 0.5f * _speed * _duty / std::max(base_rate, 0.1f));
	float hurry = 1.0f;
	if (moving) {
		for (int i = 0; i < 2; ++i) {
			const Foot& f = _feet[i];
			if (f.swinging) {
				continue;
			}
			const Vec3 off = flat(f.pos - hip_ground(i), U);
			if (dot(off, _vel) < 0.0f) {
				const float over = length(off) - reach_out;
				// Both feet down (the other can take the weight): straight to its lift, at full hurry.
				const bool both_down = !_feet[1 - i].swinging && f.down_t >= MIN_STANCE_TICKS && over > 0.0f;
				hurry = std::max(hurry, both_down ? _s.hurry_max
						: 1.0f + std::clamp(over / (0.15f * step_max), 0.0f, _s.hurry_max - 1.0f));
			}
		}
	}
	if (hurry >= _s.hurry_max && _hurry_want < _s.hurry_max) {
		_early_lifts++;
	}
	_hurry_want = hurry;
	// Eased (a jump in the cycle's rate jumps every foot's roll with it).
	_hurry += std::clamp(hurry - _hurry, -_s.hurry_ease * dt, _s.hurry_ease * dt);
	const float rate = _cadence * 0.5f * _hurry;     // strides (two steps) per second
	_phase = frac(_phase + rate * dt);
	_phase_step = rate * dt;
	const float swing_h = _s.swing_height + (_s.swing_height_run - _s.swing_height) * smoothstep(_s.walk_speed, _s.run_speed, _speed);
	for (int i = 0; i < 2; ++i) {
		Foot& f = _feet[i];
		const float p = frac(_phase - 0.5f * float(i));
		// Up when the foot's stance share is over; down only when its swing is through (the cycle
		// wraps) - a duty that changes mid-swing (braking from a run) never drops a foot early.
		const bool swing = f.swinging ? p >= f.p : p >= _duty;
		const float m = moving ? std::clamp(_speed / std::max(_s.walk_speed, 0.1f), 0.0f, 1.0f) : 0.0f;
		// Heel strike and roll only walking forward (backing / side-stepping: flat-footed).
		const float toe_up = _s.toe_up * m * (1.0f - 0.8f * run) * fwdness;
		const float heel_rise = _s.heel_rise * m * (0.35f + 0.65f * fwdness);
		// Running: up on the ball of the foot the whole stance (landing on the forefoot), more at a sprint.
		const float fore = (_s.forefoot_run * run + (_s.forefoot_sprint - _s.forefoot_run) * smoothstep(_s.run_speed, _s.sprint_speed, _speed)) * fwdness;
		if (swing && !f.swinging) {
			f.swinging = true;
			f.lift = f.eff;
			f.lift_yaw = f.yaw;
			f.lift_pitch = f.pitch;
			f.lift_t = 0;
			f.lift_p = std::min(p, 0.98f);
		} else if (!swing && f.swinging) {
			f.down_t = 0;
			// Down: the foot stays exactly here until it lifts again.
			f.swinging = false;
			f.pos = f.target;
			f.yaw = legs_q();
		}
		f.p = p;
		if (!f.swinging) {
			f.down_t++;
			f.target = f.pos;
			// Heel strike (toes up, rolling flat), then the heel rising round the ball.
			const float q = std::clamp(p / std::max(_duty, 1e-3f), 0.0f, 1.0f);
			const float walk_pitch = -toe_up * (1.0f - smoothstep(0.0f, 0.2f, q)) + heel_rise * smoothstep(0.5f, 1.0f, q);
			const float run_pitch = fore + std::max(heel_rise - fore, 0.0f) * smoothstep(0.6f, 1.0f, q);
			float pitch = walk_pitch + (run_pitch - walk_pitch) * run;
			// At the foot's own pace (a hurried cycle mustn't whip the planted foot over).
			const float lim = _s.roll_rate * dt;
			pitch = f.pitch + std::clamp(pitch - f.pitch, -lim, lim);
			roll(f, pitch);
			continue;
		}
		// Where to land: where the hip will be at touchdown, a little ahead of it (so the hip is
		// over the foot at mid-stance); standing still, its own spot.
		Vec3 land;
		if (moving) {
			const float t_rem = (1.0f - p) / rate;
			const float stance_t = _duty / rate;
			// Where the hip will be at touchdown, plus half the coming stance at the wanted motion,
			// plus the capture offset of the difference (a body to brake: further ahead).
			const Vec3 at_td = hip_ground(i) + _vel * t_rem;
			const float omega = std::sqrt(9.81f / std::max(_pelvis_h, 0.4f));
			const Vec3 want = _cmd + _trim;
			Vec3 reach = _cmd * (0.5f * stance_t) + (_vel - want) * (_s.capture_gain / omega);
			// Never behind the hip along the way it's going: speeding up puts the foot under the body,
			// not back where an upright leg can't reach it (the push comes off the heel instead).
			const Vec3 heading = _speed > 0.2f ? _vel : _cmd;   // (just starting: the way it wants to go)
			if (length(heading) > 0.05f) {
				const Vec3 dir = normalized(heading);
				const float along = dot(reach, dir);
				if (along < 0.0f) {
					reach = reach - dir * along;
				}
			}
			const float lim = _s.land_max * _leg_len;
			if (length(reach) > lim) {
				reach = normalized(reach) * lim;
			}
			land = at_td + reach;
		} else {
			land = home(i);
		}
		// Never across the other foot (where it stands, or where it's landing).
		{
			const Foot& o = _feet[1 - i];
			const float side = i == 0 ? 1.0f : -1.0f;
			const float gap = side * dot(land - (o.swinging ? o.target : o.pos), Lv);
			if (gap < _s.stance_gap) {
				land = land + Lv * (side * (_s.stance_gap - gap));
			}
		}
		land = flat(land, U) + U * (ground_y(land, dot(_root.p, U)) + _ankle_h);
		// The foothold follows a change of motion at a foot's pace (a reversal mid-swing must not
		// teleport the foot); a fresh swing aims straight at it.
		if (f.lift_t == 0) {
			f.target = land;
		} else {
			const Vec3 d = land - f.target;
			const float lim = (_s.retarget_speed + _speed) * dt;
			f.target = length(d) > lim ? f.target + d * (lim / length(d)) : land;
		}
		f.lift_t++;
		land = f.target;
		const float s = swing_s(f, p);
		const float k = smooth(s);
		const Vec3 h = flat(f.lift, U) + (flat(land, U) - flat(f.lift, U)) * k;
		const float y = dot(f.lift, U) + (dot(land, U) - dot(f.lift, U)) * k + swing_h * std::sin(PI * s);
		f.pos = h + U * y;
		// In the air the foot turns from its push-off roll to toes up for the landing.
		const float land_pitch = -toe_up * (1.0f - run) + fore * run;    // heel first walking, forefoot running
		f.pitch = f.lift_pitch + (land_pitch - f.lift_pitch) * smooth(s);
		// Drawn: coming down onto the heel with the toes up - the ankle where the heel-strike
		// roll will have it on touchdown (else it pops up by the roll as the foot lands).
		Foot drawn = f;
		drawn.yaw = legs_q();
		roll(drawn, f.pitch);
		f.eff = f.pos + (drawn.eff - f.pos) * smooth(s);
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
		h = pelvis_h;
		if (c.pelvis_height.size() == m) {
			float mean = 0.0f;
			for (float x : c.pelvis_height) {
				mean += x / float(m);
			}
			const float raw = c.pelvis_height[i0] + (c.pelvis_height[i1] - c.pelvis_height[i0]) * t;
			h = mean + (raw - mean) * _s.cycle_bob;   // (the clip's bob, softened)
		}
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

std::vector<Vec3> Gait::support() const {
	const Vec3 U = up();
	std::vector<Vec3> pts;
	for (const Foot& f : _feet) {
		if (f.swinging) {
			continue;
		}
		Vec3 fwd = flat(rotate(f.yaw, _rig.forward), U);
		fwd = length(fwd) > 1e-4f ? normalized(fwd) : Vec3{ 0, 0, 1 };
		const Vec3 side = normalized(cross(U, fwd)) * _s.sole_half_width;
		const Vec3 o = flat(f.pos, U);
		const float heel = -_heel_d, toe = _ball_d + _s.toe_ahead;
		// Rolled: only the edge it stands on.
		const float from = f.pitch > 0.05f ? _ball_d : heel;
		const float to = f.pitch < -0.05f ? heel : toe;
		for (float x : { from, to }) {
			pts.push_back(o + fwd * x + side);
			pts.push_back(o + fwd * x - side);
		}
	}
	return pts.empty() ? pts : ground_hull(pts, U);
}

namespace {

// The point of a convex hull (ground plane) nearest p (p itself if inside).
Vec3 clamp_to_hull(const std::vector<Vec3>& hull, Vec3 p, Vec3 up) {
	if (hull.size() >= 3 && hull_distance(hull, p, up) <= 0.0f) {
		return p;
	}
	Vec3 best = hull.empty() ? p : hull[0];
	float bd = 1e30f;
	const size_t n = hull.size();
	for (size_t i = 0; i < n; ++i) {
		const Vec3 a = flat(hull[i], up), b = flat(hull[(i + 1) % n], up);
		const Vec3 ab = b - a;
		const float l2 = dot(ab, ab);
		const float t = l2 > 1e-9f ? std::clamp(dot(flat(p, up) - a, ab) / l2, 0.0f, 1.0f) : 0.0f;
		const Vec3 q = a + ab * t;
		const float d = length(flat(p, up) - q);
		if (d < bd) {
			bd = d;
			best = q;
		}
	}
	return best + up * dot(p, up);
}

} // namespace

Vec3 Gait::drive(Vec3 com, Vec3 velocity, Vec3 command, float dt) {
	const Vec3 U = up();
	const float g = _world ? std::max(length(_world->gravity()), 1.0f) : 9.81f;
	const Vec3 v = flat(velocity, U), u = flat(command, U);
	const float w2 = g / std::max(_pelvis_h, 0.4f);
	const float a_max = _s.friction * g;
	// Trim: the integral of the speed error (none while stopping / standing).
	const std::vector<Vec3> hull = support();
	// Only near the speed asked for (a steady offset), with a foot down: starting / stopping /
	// in flight it would wind up and throw the body past the speed afterwards.
	if (length(u) > 0.1f && !hull.empty() && length(u - v) < 0.25f * length(u)) {
		_trim = _trim + (u - v) * (_s.trim_gain * dt);
		const float lim = _s.trim_max * length(u);
		if (length(_trim) > lim) {
			_trim = normalized(_trim) * lim;
		}
	} else {
		_trim = _trim * std::max(0.0f, 1.0f - 4.0f * dt);
	}
	Vec3 a_des = (u + _trim - v) * (1.0f / std::max(_s.drive_tau, dt));
	// Barely moving and not asked to: plain capped acceleration (standing, stepping on the spot).
	const float k = smoothstep(0.1f, 0.4f, std::max(length(v), length(u)));
	Vec3 a_stand = a_des;
	if (length(a_stand) > _s.standing_accel) {
		a_stand = normalized(a_stand) * _s.standing_accel;
	}
	Vec3 a_pend;
	const Vec3 c = flat(com, U);
	if (hull.empty()) {
		_cop = c;                                  // in the air: nothing to push on
	} else {
		const Vec3 p_des = c - a_des * (1.0f / w2);
		_cop = flat(clamp_to_hull(hull, p_des, U), U);
		a_pend = (c - _cop) * w2;
	}
	Vec3 a = a_stand * (1.0f - k) + a_pend * k;
	if (length(a) > a_max) {
		a = normalized(a) * a_max;
	}
	_cop = _cop + U * dot(com, U);
	_drive_acc = a;
	return v + a * dt;
}

float Gait::capture_margin() const {
	const float g = _world ? std::max(length(_world->gravity()), 1.0f) : 9.81f;
	const float omega = std::sqrt(g / std::max(_pelvis_h, 0.4f));
	return _s.land_max * _leg_len - length(_vel - _cmd) / omega;
}

std::vector<float> Gait::leg_effort() const {
	const Rig& rig = _rig;
	std::vector<float> out(rig.parts.size(), -1.0f);
	const Vec3 U = up();
	const float g = _world ? std::max(length(_world->gravity()), 1.0f) : 9.81f;
	const float M = rig.total_mass();
	const Vec3 com = flat(_root.p, U);
	// Each planted foot's share of the weight and its point of contact (the centre of pressure,
	// clamped onto that foot's sole).
	Vec3 contact[2];
	float dist[2] = { 0.0f, 0.0f };
	int planted = 0;
	for (int i = 0; i < 2; ++i) {
		const Foot& f = _feet[i];
		Vec3 fwd = flat(rotate(f.yaw, rig.forward), U);
		fwd = length(fwd) > 1e-4f ? normalized(fwd) : Vec3{ 0, 0, 1 };
		const Vec3 side = normalized(cross(U, fwd));
		const Vec3 o = flat(f.eff, U);
		const Vec3 d = flat(_cop, U) - o;
		contact[i] = o + fwd * std::clamp(dot(d, fwd), -_heel_d, _ball_d + _s.toe_ahead) +
				side * std::clamp(dot(d, side), -_s.sole_half_width, _s.sole_half_width) + U * (dot(f.eff, U) - _ankle_h);
		dist[i] = length(flat(contact[i], U) - com);
		planted += f.swinging ? 0 : 1;
	}
	for (int i = 0; i < 2; ++i) {
		if (_leg[i] < 0) {
			continue;
		}
		const LimbInfo& l = _limbs.limb(LimbId(_leg[i]));
		const int parts[3] = { l.upper, l.lower, l.end };
		const Vec3 hip = _pose[size_t(l.upper)].p, knee = _pose[size_t(l.lower)].p, ankle = _pose[size_t(l.end)].p;
		const Vec3 joints[3] = { hip, knee, ankle };
		float share = 0.0f;
		if (!_feet[i].swinging) {
			share = planted == 2 ? 1.0f - dist[i] / std::max(dist[0] + dist[1], 1e-4f) : 1.0f;
		}
		// Ground force on this foot: its share of the weight, pointing (as for an inverted pendulum)
		// from the contact toward the centre of mass - it runs close by the hip, as a real one does.
		const Vec3 c3 = com + U * (dot(_root.p, U) + std::max(_pelvis_h, 0.4f));
		const Vec3 r = c3 - contact[i];
		const float rz = std::max(dot(r, U), 0.2f);
		const Vec3 F = (U * g + flat(r, U) * (g / rz)) * (share * M);
		// The leg's own segments (centres between the joints), held against gravity.
		const Vec3 seg[3] = { (hip + knee) * 0.5f, (knee + ankle) * 0.5f, ankle };
		for (int j = 0; j < 3; ++j) {
			const PartDef& d = rig.parts[size_t(parts[j])];
			Vec3 t = cross(contact[i] - joints[j], F);
			for (int k = j; k < 3; ++k) {
				t = t + cross(seg[k] - joints[j], U * (-g * rig.parts[size_t(parts[k])].mass));
			}
			out[size_t(parts[j])] = length(t) / std::max(d.muscle.strength, 1.0f);
		}
	}
	return out;
}

void Gait::solve(const std::vector<Quat>& local, Quat pelvis_model, float pelvis_h) {
	_pelvis_h = pelvis_h;
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
	// Knees bend more the faster it goes.
	const float bend = _s.knee_bend * smoothstep(0.0f, _s.walk_speed, _stepping ? _speed : 0.0f) + (_s.knee_bend_run - _s.knee_bend) * run +
			(_s.knee_bend_sprint - _s.knee_bend_run) * smoothstep(_s.run_speed, _s.sprint_speed, _speed);
	Vec3 P = _root.p + U * (pelvis_h - bend);
	if (procedural) {
		P += U * (-_s.bob * m * std::cos(4.0f * PI * _phase) - _s.run_crouch * run);
		P += left * (_s.sway * m * std::sin(2.0f * PI * _phase));
	}
	const float pw = _warp * _s.warp_pelvis;
	Quat Pq = normalized(axis_angle(U, pw) * _root.q * pelvis_model);
	if (procedural) {
		Pq = normalized(axis_angle(U, 0.5f * _s.spine_twist * m * c2) * Pq);
	}
	// Momentum: the pelvis tips its share of the lean and carries the weight over (the legs refit).
	const float lean_a = length(_lean);
	Vec3 lean_axis{ 1, 0, 0 };
	if (lean_a > 1e-4f) {
		const Vec3 d = _lean * (1.0f / lean_a);
		lean_axis = normalized(cross(U, d));
		Pq = normalized(axis_angle(lean_axis, lean_a * _s.lean_pelvis) * Pq);
		P += d * std::min(pelvis_h * lean_a * _s.lean_shift, _s.lean_shift_max);
	}
	// The hips must reach the planted ankles: lower the pelvis for a low or far foothold. (A foot in
	// the air is pulled in to the leg's reach below instead - a run's trailing foot just after push-off
	// dragged the hips 30 cm down.)
	float drop = 0.0f;
	for (int i = 0; i < 2; ++i) {
		if (_leg[i] < 0 || _feet[i].swinging) {
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
	// Eased: the hips sink into a stride's stretch and stay low through it (no dip at every step);
	// what's beyond the eased drop by more than the slack is taken at once (a leg must reach).
	if (drop > _drop) {
		_drop = std::min(drop, _drop + _s.drop_rise * _dt);
	} else {
		_drop = std::max(drop, _drop - _s.drop_fall * _dt);
	}
	P -= U * (_drop + std::max(0.0f, drop - _drop - _s.drop_slack));
	// Forward kinematics of the base pose.
	_pose[0] = Transform{ P, Pq };
	for (size_t i = 1; i < n; ++i) {
		const PartDef& d = rig.parts[i];
		const Transform& w = _pose[size_t(d.parent)];
		_pose[i] = Transform{ xform(w, d.frame_parent.p), normalized(w.q * local[i]) };
	}
	// The chest keeps facing: the spine turns the pelvis' warp back.
	const int spine_part = rig.find("Spine");
	if (spine_part >= 0 && std::fabs(pw) > 1e-5f) {
		turn_subtree(_pose, rig, spine_part, axis_angle(U, -pw), _pose[size_t(spine_part)].p);
	}
	// ... and leans the rest of the momentum lean; the arms trail the old motion.
	if (lean_a > 1e-4f) {
		if (spine_part >= 0) {
			turn_subtree(_pose, rig, spine_part, axis_angle(lean_axis, lean_a * (1.0f - _s.lean_pelvis)), _pose[size_t(spine_part)].p);
		}
		for (const char* arm : { "LeftUpperArm", "RightUpperArm" }) {
			const int a = rig.find(arm);
			if (a >= 0) {
				turn_subtree(_pose, rig, a, axis_angle(lean_axis, -lean_a * _s.arm_lag), _pose[size_t(a)].p);
			}
		}
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
		if (_feet[i].swinging) {
			const float reach = (l.upper_len + l.lower_len) * _s.max_reach;
			const Vec3 d = _feet[i].eff - hip;
			if (length(d) > reach) {
				_feet[i].eff = hip + normalized(d) * reach;
			}
		}
		Quat upper_world, lower_local;
		two_bone_ik(rig, l, hip, _pose[size_t(l.upper)].q, _feet[i].eff, upper_world, lower_local);
		_pose[size_t(l.upper)] = Transform{ hip, upper_world };
		const PartDef& sh = rig.parts[size_t(l.lower)];
		_pose[size_t(l.lower)] = Transform{ xform(_pose[size_t(l.upper)], sh.frame_parent.p), normalized(upper_world * lower_local) };
		// The foot: flat with the yaw it was put down with; turning toward the facing in the air.
		const Foot& f = _feet[i];
		Quat yaw = f.yaw;
		if (f.swinging) {
			const float s = swing_s(f, f.p);
			yaw = normalized(slerp(f.lift_yaw, legs_q(), smooth(s)));
		}
		Vec3 ffwd = flat(rotate(yaw, rig.forward), U);
		ffwd = length(ffwd) > 1e-4f ? normalized(ffwd) : fwd;
		const Quat pitch = axis_angle(normalized(cross(U, ffwd)), f.pitch);
		const PartDef& ft = rig.parts[size_t(l.end)];
		_pose[size_t(l.end)] = Transform{ xform(_pose[size_t(l.lower)], ft.frame_parent.p), normalized(pitch * yaw * ft.rest.q) };
	}
}

} // namespace sinew
