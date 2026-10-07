#include "sinew/limbs.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <cmath>
#include <string>

namespace sinew {

namespace {

Vec3 part_mid(const PartDef& d) { return (d.a + d.b) * 0.5f; }

// A hinge's local rotation (child in parent's frame) at angle `a` about the joint's +Z.
Quat hinge_local(const PartDef& d, float a) {
	return normalized(d.frame_parent.q * axis_angle(Vec3{ 0, 0, 1 }, a) * conj(d.frame_child.q));
}

} // namespace

Limbs::Limbs(const Rig& rig) :
		_rig(rig) {
	auto chain = [&](LimbId id, std::initializer_list<const char*> names) {
		LimbInfo& l = _limbs[size_t(id)];
		for (const char* n : names) {
			const int p = rig.find(n);
			if (p >= 0) {
				l.parts.push_back(p);
			}
		}
		if (!l.parts.empty()) {
			l.root = l.parts.front();
			l.end = l.parts.back();
		}
	};
	chain(LimbId::ArmL, { "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand" });
	chain(LimbId::ArmR, { "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand" });
	chain(LimbId::LegL, { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" });
	chain(LimbId::LegR, { "RightUpperLeg", "RightLowerLeg", "RightFoot" });
	chain(LimbId::Spine, { "Spine", "Chest", "UpperChest" });
	chain(LimbId::Neck, { "Neck" });
	// Arms and legs: the two IK bones, the wrist / ankle in the lower bone's frame.
	auto ik = [&](LimbId id, const char* upper, const char* lower, const char* end) {
		LimbInfo& l = _limbs[size_t(id)];
		l.upper = rig.find(upper);
		l.lower = rig.find(lower);
		const int e = rig.find(end);
		if (l.upper < 0 || l.lower < 0) {
			l.upper = l.lower = -1;
			return;
		}
		const PartDef& lo = rig.parts[size_t(l.lower)];
		l.end_offset = e >= 0 ? xform(inverse(lo.rest), rig.parts[size_t(e)].rest.p) : lo.b;
		l.upper_len = length(lo.frame_parent.p);   // the lower bone's pivot in the upper's frame
		l.lower_len = length(l.end_offset);
	};
	ik(LimbId::ArmL, "LeftUpperArm", "LeftLowerArm", "LeftHand");
	ik(LimbId::ArmR, "RightUpperArm", "RightLowerArm", "RightHand");
	ik(LimbId::LegL, "LeftUpperLeg", "LeftLowerLeg", "LeftFoot");
	ik(LimbId::LegR, "RightUpperLeg", "RightLowerLeg", "RightFoot");
}

Vec3 Limbs::end_position(const Character& c, LimbId id) const {
	const LimbInfo& l = limb(id);
	if (!l.present()) {
		return Vec3{};
	}
	return xform(c.part_transform(l.end), part_mid(_rig.parts[size_t(l.end)]));
}

LimbState Limbs::state(const Character& c, LimbId id) const {
	LimbState s;
	const LimbInfo& l = limb(id);
	if (!l.present()) {
		return s;
	}
	s.present = true;
	s.attached = c.attached(l.end);
	s.health = s.attached ? 1.0f : 0.0f;
	for (int p : l.parts) {
		s.health = std::min(s.health, c.part_tone(p));
		s.contact = s.contact || c.part_touching(p);
	}
	s.end_contact = c.part_touching(l.end);
	s.end_position = end_position(c, id);
	s.end_velocity = c.part_velocity(l.end);
	if (l.upper >= 0) {
		const float hand = l.end != l.lower ? length(part_mid(_rig.parts[size_t(l.end)])) : 0.0f;
		s.reach = l.upper_len + l.lower_len + hand;
	}
	return s;
}

Quat Limbs::target_world(const Character& c, int part) const {
	const int parent = _rig.parts[size_t(part)].parent;
	if (parent < 0) {
		return c.part_transform(part).q;
	}
	return normalized(c.part_transform(parent).q * c.effective_target(part));
}

void two_bone_ik(const Rig& rig, const LimbInfo& l, Vec3 root, Quat upper_base, Vec3 target, Quat& upper_world,
		Quat& lower_local) {
	const PartDef& lo = rig.parts[size_t(l.lower)];
	const float d = length(target - root);
	// The wrist / ankle in the upper bone's frame at hinge angle a; its distance from the root
	// joint shrinks as the hinge flexes. Sample the range, then bisect inside the best bracket.
	auto wrist = [&](float a) { return lo.frame_parent.p + rotate(hinge_local(lo, a), l.end_offset); };
	auto err = [&](float a) { return length(wrist(a)) - d; };
	const int N = 48;
	const float a0 = lo.hinge_min, a1 = lo.hinge_max;
	float best = a0, best_err = 1e9f;
	int bracket = -1;
	float prev = err(a0);
	for (int i = 0; i <= N; ++i) {
		const float a = a0 + (a1 - a0) * float(i) / float(N);
		const float e = err(a);
		if (std::fabs(e) < best_err) {
			best_err = std::fabs(e);
			best = a;
		}
		if (i > 0 && bracket < 0 && ((prev > 0.0f) != (e > 0.0f))) {
			bracket = i;
		}
		prev = e;
	}
	if (bracket > 0) {
		float lo_a = a0 + (a1 - a0) * float(bracket - 1) / float(N);
		float hi_a = a0 + (a1 - a0) * float(bracket) / float(N);
		const bool lo_pos = err(lo_a) > 0.0f;
		for (int k = 0; k < 20; ++k) {
			const float m = 0.5f * (lo_a + hi_a);
			if ((err(m) > 0.0f) == lo_pos) {
				lo_a = m;
			} else {
				hi_a = m;
			}
		}
		best = 0.5f * (lo_a + hi_a);
	}
	lower_local = hinge_local(lo, best);
	// Swing the upper bone (the least turn from its base orientation) so the wrist / ankle lies
	// along the line to the target: the elbow / knee keeps the base pose's side.
	const Vec3 v = rotate(upper_base, wrist(best));
	const Vec3 to = target - root;
	upper_world = upper_base;
	if (length(v) > 1e-5f && length(to) > 1e-5f) {
		upper_world = normalized(from_to(normalized(v), normalized(to)) * upper_base);
	}
}

bool Limbs::solve_two_bone(const Character& c, const LimbInfo& l, Vec3 target, Solve& out) const {
	if (l.upper < 0 || !c.attached(l.lower)) {
		return false;
	}
	const PartDef& up = _rig.parts[size_t(l.upper)];
	const PartDef& lo = _rig.parts[size_t(l.lower)];
	if (up.parent < 0 || lo.joint != JointKind::Hinge) {
		return false;
	}
	const Transform parent = c.part_transform(up.parent);
	out.parent = parent.q;
	out.root = xform(parent, up.frame_parent.p);
	const Quat upper_base = normalized(parent.q * c.effective_target(l.upper));
	two_bone_ik(_rig, l, out.root, upper_base, target, out.upper_world, out.lower_local);
	return true;
}

bool Limbs::two_bone(Character& c, const LimbInfo& l, Vec3 target, float weight, bool keep_end_world) const {
	Solve s;
	if (weight <= 0.0f || !solve_two_bone(c, l, target, s)) {
		return false;
	}
	const bool end = keep_end_world && l.end != l.lower && l.end >= 0;
	Quat end_world;
	if (end) {
		// The hand / foot's animated world orientation, kept (taken before the bones change).
		end_world = normalized(s.parent * c.effective_target(l.upper) * c.effective_target(l.lower) * c.effective_target(l.end));
	}
	c.set_effector(l.upper, conj(s.parent) * s.upper_world, weight);
	c.set_effector(l.lower, s.lower_local, weight);
	if (end) {
		c.set_effector(l.end, conj(s.upper_world * s.lower_local) * end_world, weight);
	}
	return true;
}

bool Limbs::reach(Character& c, LimbId arm, Vec3 point, float weight) const {
	const LimbInfo& l = limb(arm);
	if (l.upper < 0) {
		return false;
	}
	// The point is for the hand's centre: aim the wrist short of it by the hand, along where
	// the solved forearm carries the hand (a few passes: the hand's direction depends on the
	// solve).
	Vec3 wrist = point;
	if (l.end != l.lower) {
		const Vec3 hand_mid = part_mid(_rig.parts[size_t(l.end)]);
		const Quat hand_local = c.effective_target(l.end);
		Solve s;
		for (int k = 0; k < 3 && solve_two_bone(c, l, wrist, s); ++k) {
			wrist = point - rotate(s.upper_world * s.lower_local * hand_local, hand_mid);
		}
	}
	return two_bone(c, l, wrist, weight, false);
}

bool Limbs::place_foot(Character& c, LimbId leg, Vec3 ankle, float weight) const {
	return two_bone(c, limb(leg), ankle, weight, true);
}

bool Limbs::look(Character& c, Vec3 point, float weight, float max_angle) const {
	const LimbInfo& l = limb(LimbId::Neck);
	if (!l.present() || !c.attached(l.end) || weight <= 0.0f) {
		return false;
	}
	const PartDef& head = _rig.parts[size_t(l.end)];
	const Quat base = target_world(c, l.end);
	const Vec3 eye = xform(c.part_transform(l.end), part_mid(head));
	const Vec3 dir = point - eye;
	if (length(dir) < 1e-3f) {
		return false;
	}
	const Vec3 fwd = rotate(base, rotate(conj(head.rest.q), _rig.forward));
	const Vec3 axis = cross(fwd, normalized(dir));
	const float s = length(axis);
	const float angle = std::atan2(s, dot(fwd, normalized(dir)));
	Quat world = base;
	if (s > 1e-5f) {
		world = normalized(axis_angle(axis * (1.0f / s), std::min(angle, max_angle)) * base);
	}
	c.set_effector(l.end, conj(c.part_transform(head.parent).q) * world, weight);
	return true;
}

void Limbs::lean(Character& c, float pitch, float roll, float weight) const {
	const LimbInfo& l = limb(LimbId::Spine);
	if (!l.present() || weight <= 0.0f) {
		return;
	}
	// The body's left / forward axes, carried by the pelvis.
	const Quat hips = c.part_transform(0).q * conj(_rig.parts[0].rest.q);
	const Vec3 left = rotate(hips, cross(_rig.up, _rig.forward));
	const Vec3 fwd = rotate(hips, _rig.forward);
	const Vec3 rv = left * pitch + fwd * roll;
	const float angle = length(rv);
	if (angle < 1e-6f) {
		return;
	}
	const float share = angle / float(l.parts.size());
	for (int p : l.parts) {
		if (!c.attached(p)) {
			continue;
		}
		const Quat base_world = target_world(c, p);
		const Vec3 axis_local = rotate(conj(base_world), rv * (1.0f / angle));
		c.set_effector(p, c.effective_target(p) * axis_angle(axis_local, share), weight);
	}
}

namespace probes {

namespace {
Vec3 down_of(const PhysicsWorld& w) {
	const Vec3 g = w.gravity();
	return length(g) > 1e-4f ? normalized(g) : Vec3{ 0, -1, 0 };
}
} // namespace

RayHit ground_below(const PhysicsWorld& w, Vec3 p, float max_distance) {
	return w.cast_ray(p, down_of(w) * max_distance);
}

EdgeProbe edge_ahead(const PhysicsWorld& w, Vec3 from, Vec3 dir, float range, float min_drop) {
	EdgeProbe e;
	const Vec3 down = down_of(w);
	const Vec3 up = -down;
	Vec3 flat = dir - up * dot(dir, up);
	if (length(flat) < 1e-4f) {
		return e;
	}
	flat = normalized(flat);
	const float lift = 0.3f, depth = lift + min_drop + 2.0f;
	const RayHit base = w.cast_ray(from + up * lift, down * depth);
	if (!base.hit) {
		return e;
	}
	const float h0 = dot(base.point, up);
	e.point = base.point;
	for (float s = 0.05f; s <= range + 1e-4f; s += 0.05f) {
		const RayHit h = w.cast_ray(from + flat * s + up * lift, down * depth);
		const float drop = h.hit ? h0 - dot(h.point, up) : depth - lift;
		if (drop > min_drop) {
			e.found = true;
			e.distance = s;
			e.drop = drop;
			return e;
		}
		e.point = h.point;
	}
	return e;
}

RayHit wall_within(const PhysicsWorld& w, Vec3 origin, Vec3 dir, float reach) {
	if (length(dir) < 1e-5f) {
		return RayHit{};
	}
	return w.cast_sphere(origin, 0.1f, normalized(dir) * reach);
}

float impact_eta(const PhysicsWorld& w, Vec3 com, Vec3 velocity, float horizon) {
	const Vec3 g = w.gravity();
	const float dt = 1.0f / 30.0f;
	Vec3 p = com, v = velocity;
	for (float t = 0.0f; t < horizon; t += dt) {
		const Vec3 next = p + v * dt + g * (0.5f * dt * dt);
		const RayHit h = w.cast_ray(p, next - p);
		if (h.hit) {
			return t + dt * h.fraction;
		}
		p = next;
		v += g * dt;
	}
	return -1.0f;
}

} // namespace probes

} // namespace sinew
