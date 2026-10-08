#include "sinew/balance.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace sinew {

namespace {

Vec3 flat(Vec3 v, Vec3 up) { return v - up * dot(v, up); }

// Two axes spanning the ground plane.
void plane_axes(Vec3 up, Vec3& e1, Vec3& e2) {
	const Vec3 a = std::fabs(up.x) < 0.9f ? Vec3{ 1, 0, 0 } : Vec3{ 0, 0, 1 };
	e1 = normalized(flat(a, up));
	e2 = cross(up, e1);
}

float smooth(float s) { return s * s * (3.0f - 2.0f * s); }

float seg_distance(Vec3 p, Vec3 a, Vec3 b) {
	const Vec3 ab = b - a;
	const float l2 = dot(ab, ab);
	const float t = l2 > 1e-9f ? std::clamp(dot(p - a, ab) / l2, 0.0f, 1.0f) : 0.0f;
	return length(p - (a + ab * t));
}

} // namespace

std::vector<Vec3> ground_hull(const std::vector<Vec3>& points, Vec3 up) {
	Vec3 e1, e2;
	plane_axes(up, e1, e2);
	struct P {
		float x, y;
		Vec3 v;
	};
	std::vector<P> pts;
	for (const Vec3& p : points) {
		const Vec3 f = flat(p, up);
		pts.push_back(P{ dot(f, e1), dot(f, e2), f });
	}
	std::sort(pts.begin(), pts.end(), [](const P& a, const P& b) { return a.x < b.x || (a.x == b.x && a.y < b.y); });
	if (pts.size() < 3) {
		std::vector<Vec3> out;
		for (const P& p : pts) {
			out.push_back(p.v);
		}
		return out;
	}
	auto turn = [](const P& o, const P& a, const P& b) { return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x); };
	std::vector<P> h(2 * pts.size());
	size_t k = 0;
	for (size_t i = 0; i < pts.size(); ++i) {   // Andrew's monotone chain
		while (k >= 2 && turn(h[k - 2], h[k - 1], pts[i]) <= 1e-9f) {
			--k;
		}
		h[k++] = pts[i];
	}
	for (size_t i = pts.size() - 1, t = k + 1; i-- > 0;) {
		while (k >= t && turn(h[k - 2], h[k - 1], pts[i]) <= 1e-9f) {
			--k;
		}
		h[k++] = pts[i];
	}
	std::vector<Vec3> out;
	for (size_t i = 0; i + 1 < k; ++i) {
		out.push_back(h[i].v);
	}
	return out;
}

float hull_distance(const std::vector<Vec3>& hull, Vec3 p, Vec3 up) {
	const Vec3 q = flat(p, up);
	if (hull.empty()) {
		return 1e6f;
	}
	if (hull.size() == 1) {
		return length(q - hull[0]);
	}
	float edge = 1e9f;
	bool inside = hull.size() >= 3;
	for (size_t i = 0; i < hull.size(); ++i) {
		const Vec3 a = hull[i], b = hull[(i + 1) % hull.size()];
		edge = std::min(edge, seg_distance(q, a, b));
		if (dot(cross(b - a, q - a), up) < 0.0f) {   // right of a counter-clockwise edge
			inside = false;
		}
	}
	return inside ? -edge : edge;
}

Balancer::Balancer(Character& c, const Limbs& limbs, const BalanceSettings& settings) :
		_c(c), _limbs(limbs), _s(settings) {
	const Vec3 g = c.world().gravity();
	_up = length(g) > 1e-4f ? -normalized(g) : Vec3{ 0, 1, 0 };
	const int foot = limbs.limb(LimbId::LegL).end;
	if (foot >= 0) {
		const PartDef& d = c.rig().parts[size_t(foot)];
		if (d.box) {
			const Transform box = d.rest * d.box_xform;
			_ankle_height = dot(d.rest.p, c.rig().up) - (dot(box.p, c.rig().up) - d.box_half.y);
			// The longer lever of the sole about the ankle (to the toes), m.
			const Vec3 fwd = c.rig().forward;
			const float a = dot(d.rest.p, fwd), b = dot(box.p, fwd);
			_sole_lever = std::max({ b + d.box_half.z - a, a - (b - d.box_half.z), 0.05f });
		}
	}
}

void Balancer::set_target(Quat pelvis, float com_height) {
	_pelvis_target = normalized(pelvis);
	_height = com_height;
	_has_target = true;
}

void Balancer::set_com_target(Vec3 com) {
	_com_target = com;
	_has_com_target = true;
}

void Balancer::reset() {
	_fallen = false;
	_reason = "";
	_steps = 0;
	_swing = -1;
	_has_target = false;
	_airborne_t = 0.0f;
	_planted[0] = _planted[1] = true;
	_touch_age[0] = _touch_age[1] = 99;
	_grounded_once = false;
	_since_step = 1.0f;
	_recovery_steps = 0;
	_steady_t = 0.0f;
	_tidying = false;
	_tidy_foot = -1;
}

bool Balancer::planted(LimbId l) const {
	return l == LimbId::LegL ? _planted[0] : l == LimbId::LegR ? _planted[1] : false;
}

Vec3 Balancer::sole_centre(int i) const {
	const int foot = _limbs.limb(leg(i)).end;
	const PartDef& fd = _c.rig().parts[size_t(foot)];
	const Transform ft = _c.part_transform(foot);
	return fd.box ? xform(ft, fd.box_xform.p) : ft.p;
}

Vec3 Balancer::ankle(int i) const {
	const int foot = _limbs.limb(leg(i)).end;
	return _c.part_transform(foot).p;
}

float Balancer::leg_tone(int i) const {
	float t = 1.0f;
	for (int p : _limbs.limb(leg(i)).parts) {
		t = std::min(t, _c.part_tone(p));
	}
	return t;
}

float Balancer::ground_at(Vec3 p) const {
	const RayHit h = probes::ground_below(_c.world(), p + _up * 0.5f, 3.0f);
	return h.hit ? dot(h.point, _up) : dot(p, _up) - 1.0f;
}

void Balancer::pre_step(float dt) {
	if (_fallen) {
		return;
	}
	// The body: centre of mass and its velocity.
	float m_sum = 0.0f;
	Vec3 mv{};
	for (int i = 0; i < _c.part_count(); ++i) {
		if (_c.attached(i)) {
			const float m = _c.rig().parts[size_t(i)].mass;
			m_sum += m;
			mv += _c.part_velocity(i) * m;
		}
	}
	_com = _c.center_of_mass();
	_com_vel = m_sum > 0.0f ? mv * (1.0f / m_sum) : Vec3{};
	// Feet: planted = touching something (and not the one swinging). Support from their contacts.
	std::vector<Vec3> support;
	float ground_sum = 0.0f;
	int ground_n = 0;
	bool legs_ok = true;
	for (int i = 0; i < 2; ++i) {
		const LimbInfo& l = _limbs.limb(leg(i));
		if (!l.present() || !_c.attached(l.end)) {
			legs_ok = false;
			_planted[i] = false;
			continue;
		}
		ContactPoint pts[16];
		int n = i == _swing ? 0 : _c.part_contacts(l.end, pts, 16);
		// Just taken over (a stagger starting mid-stride): feet the animation had placed make no contacts until they are
		// physical bodies resting on something - a sole already flat on the ground counts as standing at once (else the
		// first ticks had no support at all and the body tipped over its planted ankle before a contact arrived).
		if (n == 0 && i != _swing && _touch_age[i] >= 99) {
			const PartDef& fd = _c.rig().parts[size_t(l.end)];
			if (fd.box) {
				const Transform sole = _c.part_transform(l.end) * fd.box_xform;
				const Vec3 sole_up = rotate(sole.q, Vec3{ 0, 1, 0 });
				const Vec3 e = fd.box_half;
				float low = 1e9f;
				for (int k = 0; k < 4; ++k) {
					const Vec3 corner{ (k & 1) ? e.x : -e.x, -e.y, (k & 2) ? e.z : -e.z };
					low = std::min(low, dot(xform(sole, corner), _up));
				}
				const float g = ground_at(sole.p);
				if (dot(sole_up, _up) >= _s.planted_tilt && low - g < _s.seed_contact) {
					for (int k = 0; k < 4 && n < 16; ++k) {
						const Vec3 corner{ (k & 1) ? e.x : -e.x, -e.y, (k & 2) ? e.z : -e.z };
						const Vec3 c = xform(sole, corner);
						pts[n++].point = c - _up * (dot(c, _up) - g);
					}
				}
			}
		}
		if (n > 0) {
			// Standing on it = the sole down on the ground (not tipped onto its toe or edge).
			const PartDef& fd = _c.rig().parts[size_t(l.end)];
			const Transform ft = _c.part_transform(l.end);
			const Vec3 sole_up = rotate(ft.q * fd.box_xform.q, Vec3{ 0, 1, 0 });
			float lowest = 1e9f;
			for (int k = 0; k < n; ++k) {
				lowest = std::min(lowest, dot(pts[k].point, _up));
			}
			if (fd.box && (dot(sole_up, _up) < _s.planted_tilt || dot(ft.p, _up) - lowest > _ankle_height + _s.planted_lift)) {
				n = 0;
			}
		}
		if (n > 0) {
			_touch_age[i] = 0;
			_last_support[i].clear();
			for (int k = 0; k < n; ++k) {
				_last_support[i].push_back(pts[k].point);
			}
		} else if (_touch_age[i] < 99) {
			_touch_age[i]++;
		}
		// A foot that touched within the last few ticks is still standing (contacts come and go
		// tick to tick on a box resting on the floor).
		_planted[i] = i != _swing && _touch_age[i] <= 4;
		if (_planted[i]) {
			// The footprint: the sole's corners (the contact points themselves come and go).
			const PartDef& fd = _c.rig().parts[size_t(l.end)];
			const Transform sole = _c.part_transform(l.end) * fd.box_xform;
			const Vec3 e = fd.box_half;
			for (int k = 0; k < 4; ++k) {
				const Vec3 corner{ (k & 1) ? e.x : -e.x, -e.y, (k & 2) ? e.z : -e.z };
				support.push_back(xform(sole, fd.box ? corner : Vec3{}));
			}
			for (const Vec3& p : _last_support[i]) {
				ground_sum += dot(p, _up);
				ground_n++;
			}
		}
	}
	// (One foot down is enough to step from: taken over mid-stride, the other is in the air - waiting for both to have
	// touched, it never stepped and toppled over the planted ankle.)
	if (_planted[0] || _planted[1]) {
		_grounded_once = true;
	}
	if (!legs_ok) {
		_fallen = true;
		_reason = "leg lost";   // a leg gone: nothing to stand on (the behaviours crawl)
	}
	_hull = ground_hull(support, _up);
	const float ground = ground_n > 0 ? ground_sum / float(ground_n) : ground_at(_com);
	const float h = std::max(dot(_com, _up) - ground, 0.1f);
	if (!_has_target) {
		set_target(_c.part_transform(0).q, h);
	}
	const float g = length(_c.world().gravity());
	_cp = flat(_com, _up) + flat(_com_vel, _up) * std::sqrt(h / std::max(g, 0.1f));
	_cp_out = hull_distance(_hull, _cp, _up);

	// Fallen?
	const Quat pelvis_rest = _c.rig().parts[0].rest.q;
	const Vec3 pelvis_up = rotate(_c.part_transform(0).q * conj(pelvis_rest), _c.rig().up);
	const float tilt = std::acos(std::clamp(dot(pelvis_up, _up), -1.0f, 1.0f));
	_airborne_t = (_planted[0] || _planted[1] || _swing >= 0 || !_grounded_once) ? 0.0f : _airborne_t + dt;
	const char* why = _fallen ? "leg lost"
			: tilt > _s.fall_tilt ? "tipped"
			: h < _s.fall_sink * _height ? "sank"
			: _airborne_t > 0.5f ? "airborne"
			: (_recovery_steps >= _s.max_steps && _swing < 0 && _cp_out > _s.step_margin) ? "out of steps"
			: nullptr;
	if (why) {
		_reason = why;
		_fallen = true;
		for (int i = 0; i < 2; ++i) {
			for (int p : _limbs.limb(leg(i)).parts) {
				_c.set_part_gravity_compensation(p, true);
				_c.set_part_torque_cap(p, -1.0f);
			}
		}
		_swing = -1;
		if (_c.root_assist() > 0.0f) {
			_c.set_upright_assist(_pelvis_target, 0.0f, dt);
		}
		return;
	}

	// Step when the capture point has left the support.
	_since_step += dt;
	// Steady (both feet down, capture point well inside, slow): a new recovery starts.
	if (_swing < 0 && _planted[0] && _planted[1] && _cp_out < -0.03f && length(flat(_com_vel, _up)) < 0.15f) {
		_steady_t += dt;
		if (_steady_t > 0.5f) {
			_recovery_steps = 0;
		}
	} else {
		_steady_t = 0.0f;
	}
	// (A foot just put down gets a moment of double support, unless it's clearly not enough.)
	const bool settle = _since_step < 0.12f && _cp_out < 0.15f;
	if (_s.stepping && _swing < 0 && _grounded_once && !settle && !_hull.empty() && _cp_out > _s.step_margin &&
			(_planted[0] || _planted[1])) {
		start_step();
	}
	// A closing step (only after a recovery, and only once the weight is off that foot).
	if (_tidy_foot >= 0) {
		_tidy_wait += dt;
		const Vec3 stance = flat(sole_centre(1 - _tidy_foot), _up);
		if (_swing >= 0 || _cp_out > _s.step_margin || _tidy_wait > 0.8f || !_planted[1 - _tidy_foot]) {
			_tidy_foot = -1;   // something else came up / took too long
		} else if (length(flat(_com, _up) - stance) < 0.05f && length(flat(_com_vel, _up)) < 0.25f) {
			_swing = _tidy_foot;
			_tidying = true;
			_swing_from = ankle(_swing);
			_swing_to = _tidy_to;
			_swing_t = 0.0f;
			_swing_time = _s.step_time + 0.1f;
			_tidy_foot = -1;
		}
	} else if (_s.stepping && _swing < 0 && _recovery_steps > 0 && !settle && _since_step > 0.25f && _cp_out < -0.02f &&
			_planted[0] && _planted[1] && length(flat(_com_vel, _up)) < 0.35f) {
		tidy_step();
	}
	if (_swing >= 0) {
		_swing_t += dt;
		const float s = std::min(_swing_t / _swing_time, 1.0f);
		// Still early in the swing: follow the capture point if it moved on.
		if (s < _s.retarget_until && !_tidying) {
			const Vec3 from = _swing_from;
			const float t = _swing_t;
			start_step(_swing);
			_swing_from = from;
			_swing_t = t;
		}
		Vec3 p = _swing_from + (_swing_to - _swing_from) * smooth(s);
		p += _up * (_s.step_height * std::sin(PI * s));
		_limbs.place_foot(_c, leg(_swing), p, 1.0f);
		const int foot = _limbs.limb(leg(_swing)).end;
		ContactPoint pts[4];
		const bool down = s >= 1.0f && _c.part_contacts(foot, pts, 4) > 0;
		if (down || _swing_t > _swing_time + 0.25f) {
			_planted[_swing] = down;
			_swing = -1;
			_steps++;
			if (!_tidying) {
				_recovery_steps++;
			}
			_tidying = false;
			_since_step = 0.0f;
		}
	}
	for (int i = 0; i < 2; ++i) {
		const bool stance = _planted[i] && i != _swing;
		for (int p : _limbs.limb(leg(i)).parts) {
			_c.set_part_gravity_compensation(p, !stance);
		}
	}
	stance_forces(dt);
	if (_s.upright_assist > 0.0f || _c.root_assist() > 0.0f) {
		_c.set_upright_assist(_pelvis_target, _s.upright_assist, dt);
	}
}

void Balancer::start_step(int force_swing) {
	const Quat pelvis = _c.part_transform(0).q * conj(_c.rig().parts[0].rest.q);
	Vec3 left = flat(rotate(pelvis, cross(_c.rig().up, _c.rig().forward)), _up);
	left = length(left) > 1e-4f ? normalized(left) : Vec3{ 1, 0, 0 };
	int swing = force_swing;
	if (swing < 0) {
		if (_planted[0] != _planted[1]) {
			swing = _planted[0] ? 1 : 0;
		} else {
			// Falling out past one foot sideways: that foot steps out (the other would have to
			// cross over). Otherwise the foot farther from the capture point.
			const float l0 = dot(flat(ankle(0), _up), left), l1 = dot(flat(ankle(1), _up), left);
			const float lat = dot(_cp, left);
			if (lat > std::max(l0, l1)) {
				swing = l0 > l1 ? 0 : 1;
			} else if (lat < std::min(l0, l1)) {
				swing = l0 < l1 ? 0 : 1;
			} else {
				const float d0 = length(flat(ankle(0), _up) - _cp), d1 = length(flat(ankle(1), _up) - _cp);
				swing = d0 > d1 ? 0 : 1;
			}
		}
	}
	const int stance = 1 - swing;
	const int foot = _limbs.limb(leg(swing)).end;
	const PartDef& fd = _c.rig().parts[size_t(foot)];
	// The sole's centre relative to the ankle (flat): put the sole, not the ankle, past the point.
	const Transform ft = _c.part_transform(foot);
	const Vec3 sole_off = fd.box ? flat(xform(ft, fd.box_xform.p) - ft.p, _up) : Vec3{};
	Vec3 dir = flat(_cp - _com, _up);
	if (length(dir) < 1e-3f) {
		dir = flat(_cp - ankle(stance), _up);
	}
	dir = length(dir) > 1e-4f ? normalized(dir) : Vec3{};
	// Where the capture point will be when the foot lands: standing on one foot the body is an
	// inverted pendulum over it, and the capture point runs away from the stance foot as
	// e^(t / Tc), Tc = sqrt(h / g).
	const Vec3 pivot = flat(ankle(stance), _up) + (fd.box ? sole_off : Vec3{});
	const float g = length(_c.world().gravity());
	const float h = std::max(dot(_com, _up) - (dot(ankle(stance), _up) - _ankle_height), 0.3f);
	const float Tc = std::sqrt(h / std::max(g, 0.1f));
	const float t_left = std::max((force_swing >= 0 ? _swing_time - _swing_t : _s.step_time), 0.0f);
	const Vec3 cp_land = pivot + (_cp - pivot) * std::min(std::exp(t_left / Tc), 4.0f);
	// Land so the capture point ends up inside the new stance, not on its edge: past it by a
	// share of its distance from the standing foot (and a little more).
	Vec3 target = cp_land + (cp_land - pivot) * _s.step_beyond + dir * _s.step_past - sole_off;
	// Keep the feet apart sideways (the swing foot stays on its own side of the standing one).
	const Vec3 st = flat(ankle(stance), _up);
	const float side = swing == 0 ? 1.0f : -1.0f;
	const float d = dot(flat(target, _up) - st, left);
	if (side * d < _s.min_width) {
		target += left * (side * _s.min_width - d);
	}
	Vec3 v = flat(target, _up) - st;
	if (length(v) > _s.max_step) {
		v = normalized(v) * _s.max_step;
	}
	target = st + v;
	target = flat(target, _up) + _up * (ground_at(target) + _ankle_height);
	_swing = swing;
	_tidying = false;
	_swing_from = ankle(swing);
	_swing_to = target;
	_swing_t = 0.0f;
	const float dist = length(flat(_swing_to - _swing_from, _up));
	_swing_time = std::clamp(_s.step_time + _s.step_time_per_m * dist, _s.step_time, _s.step_time + 0.12f);
}

bool Balancer::tidy_step() {
	const Quat pelvis = _c.part_transform(0).q * conj(_c.rig().parts[0].rest.q);
	Vec3 left = flat(rotate(pelvis, cross(_c.rig().up, _c.rig().forward)), _up);
	Vec3 fwd = flat(rotate(pelvis, _c.rig().forward), _up);
	if (length(left) < 1e-4f || length(fwd) < 1e-4f) {
		return false;
	}
	left = normalized(left);
	fwd = normalized(fwd);
	const Vec3 l = flat(ankle(0), _up), r = flat(ankle(1), _up);
	const float width = dot(l - r, left), stagger = dot(l - r, fwd);
	if (std::fabs(width - _s.stance_width) < 0.06f && std::fabs(stagger) < 0.12f) {
		return false;   // tidy already
	}
	// The foot farther from the COM moves next to the other.
	const Vec3 com = flat(_com, _up);
	const int swing = length(l - com) > length(r - com) ? 0 : 1;
	const Vec3 other = swing == 0 ? r : l;
	Vec3 target = other + left * (swing == 0 ? _s.stance_width : -_s.stance_width);
	target = target + _up * (ground_at(target) + _ankle_height);
	// First the weight goes over the other foot (stance_forces aims the COM there).
	_tidy_foot = swing;
	_tidy_to = target;
	_tidy_wait = 0.0f;
	return true;
}

void Balancer::stance_forces(float /*dt*/) {
	int stance[2];
	int n = 0;
	for (int i = 0; i < 2; ++i) {
		if (_planted[i] && i != _swing) {
			stance[n++] = i;
		}
	}
	const Rig& rig = _c.rig();
	// A standing ankle pushes no harder than its share of the weight times the sole's lever: past
	// that the foot tips onto its toes (an uncapped ankle strategy rose the body 15 cm onto tiptoe
	// after a knock; then it's the hip's and a step's job).
	const float g = length(_c.world().gravity());
	const float ankle_cap = _c.mass() * g * _sole_lever * _s.ankle_cap / float(std::max(n, 1));
	for (int i = 0; i < 2; ++i) {
		const LimbInfo& l = _limbs.limb(leg(i));
		const bool st = _planted[i] && i != _swing;
		// A leg holds the body only as well as its muscles can: a weakened one (a hit leg, Character::set_tone per part)
		// stiffens and pushes in proportion - standing on it, the body gives way over it unless the other foot gets down.
		const float t = std::clamp(leg_tone(i), 0.0f, 1.0f);
		for (int p : { l.upper, l.end }) {
			if (p >= 0) {
				_c.set_part_stiffness(p, st ? 1.0f + (_s.stance_stiffness - 1.0f) * t : 1.0f);
			}
		}
		if (l.end >= 0) {
			_c.set_part_torque_cap(l.end, st && _s.ankle_cap > 0.0f ? ankle_cap * t : -1.0f);
		}
	}
	if (n == 0) {
		return;
	}
	// Where the COM should be: over the middle of the feet (the standing ones and the one landing).
	Vec3 target{};
	if (_tidy_foot >= 0) {
		target = flat(sole_centre(1 - _tidy_foot), _up);
	} else if (_has_com_target) {
		target = flat(_com_target, _up);
	} else {
		int k = 0;
		for (int i = 0; i < 2; ++i) {
			const int foot = _limbs.limb(leg(i)).end;
			const PartDef& fd = rig.parts[size_t(foot)];
			const Transform ft = _c.part_transform(foot);
			Vec3 sole = fd.box ? xform(ft, fd.box_xform.p) : ft.p;
			// On one foot it brakes over that foot (aiming between it and the landing spot
			// pushed the body on toward it: the step ran a metre long).
			if (i == _swing || !_planted[i]) {
				continue;
			}
			target += flat(sole, _up);
			k++;
		}
		target = target * (1.0f / float(std::max(k, 1)));
	}
	// Ankle strategy: tilt the standing shins toward where the COM should go (a PD on the COM,
	// as an angle), the ankle muscles doing it against the planted foot.
	const Vec3 e = target - flat(_com, _up);
	const Vec3 v = flat(_com_vel, _up);
	Vec3 lean = e * _s.ankle_kp - v * _s.ankle_kd;   // radians, along the ground
	if (length(lean) > _s.max_lean) {
		lean = normalized(lean) * _s.max_lean;
	}
	const float angle = length(lean);
	const Quat tilt = angle > 1e-5f ? axis_angle(normalized(cross(_up, lean)), angle) : Quat{};
	static const bool debug = getenv("SINEW_BAL_DBG") != nullptr;
	if (debug) {
		fprintf(stderr, "  e(%.3f %.3f) v(%.2f %.2f) lean(%.3f %.3f) tgt(%.3f %.3f)\n", e.x, e.z, v.x, v.z, lean.x, lean.z, target.x, target.z);
	}
	for (int k = 0; k < n; ++k) {
		const LimbInfo& l = _limbs.limb(leg(stance[k]));
		if (l.upper < 0 || l.end < 0 || l.end == l.lower) {
			continue;
		}
		// Hip strategy: the hip holds the PELVIS at its target orientation (the thigh, standing
		// on its foot, is the fixed end): local target = pelvis_target^-1 * thigh (live).
		const Quat thigh = _c.part_transform(l.upper).q;
		_c.set_effector(l.upper, conj(_pelvis_target) * thigh, 1.0f);
		// Ankle: tip the shin from where it is now toward where the COM should go (a stride's
		// legs lean every which way: pulling each to an upright neutral made them fight and
		// launched the body). local target = shin_wanted^-1 * foot (live).
		const Quat foot = _c.part_transform(l.end).q;
		const Quat shin_wanted = tilt * _c.part_transform(l.lower).q;
		_c.set_effector(l.end, conj(shin_wanted) * foot, 1.0f);
	}
}

} // namespace sinew
