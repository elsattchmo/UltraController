#include "sinew/character.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <cmath>

namespace sinew {

Character::Character(PhysicsWorld& world, std::shared_ptr<const Rig> rig, const Transform& root, int group_id,
		bool self_collision) :
		_world(world), _rig(std::move(rig)) {
	const Rig& r = *_rig;
	_parts.resize(r.parts.size());
	const int group = self_collision ? 0 : -std::abs(group_id);
	for (size_t i = 0; i < r.parts.size(); ++i) {
		const PartDef& def = r.parts[i];
		PartBodyDesc d;
		d.xform = root * def.rest;
		d.a = def.a;
		d.b = def.b;
		d.radius = def.radius;
		d.mass = def.mass;
		d.friction = def.friction;
		d.group = group;
		d.name = def.name.c_str();
		_parts[i].body = world.add_part(d);
	}
	for (size_t i = 0; i < r.parts.size(); ++i) {
		const PartDef& def = r.parts[i];
		if (def.parent < 0) {
			continue;
		}
		Part& p = _parts[i];
		const BodyHandle parent = _parts[size_t(def.parent)].body;
		if (def.joint == JointKind::Hinge) {
			HingeJointDesc j;
			j.parent = parent;
			j.child = p.body;
			j.frame_parent = def.frame_parent;
			j.frame_child = def.frame_child;
			j.min = def.hinge_min;
			j.max = def.hinge_max;
			p.joint = world.add_hinge_joint(j);
		} else {
			BallJointDesc j;
			j.parent = parent;
			j.child = p.body;
			j.frame_parent = def.frame_parent;
			j.frame_child = def.frame_child;
			j.cone = def.swing;
			j.twist_min = def.twist_min;
			j.twist_max = def.twist_max;
			p.joint = world.add_ball_joint(j);
		}
		p.muscle = world.add_muscle(parent, p.body, def.frame_parent.p, Vec3{});
	}
	if (self_collision) {
		for (auto [a, b] : r.no_collide) {
			_filters.push_back(world.add_no_collide(_parts[size_t(a)].body, _parts[size_t(b)].body));
		}
	}
	set_targets_rest();
}

Character::~Character() {
	for (Part& p : _parts) {
		if (p.body) {
			_world.destroy_body(p.body);   // takes its joints with it
		}
	}
}

Transform Character::part_transform(int part) const {
	return _world.body_transform(_parts[size_t(part)].body);
}

void Character::set_pose(const std::vector<Transform>& world_pose, Vec3 velocity) {
	for (size_t i = 0; i < _parts.size() && i < world_pose.size(); ++i) {
		_world.set_transform(_parts[i].body, world_pose[i]);
		_world.set_linear_velocity(_parts[i].body, velocity);
		_world.set_angular_velocity(_parts[i].body, Vec3{});
	}
}

void Character::set_target_local(int part, Quat local) {
	_parts[size_t(part)].target = normalized(local);
}

void Character::set_targets_from_pose(const std::vector<Transform>& world_pose) {
	const Rig& r = *_rig;
	for (size_t i = 0; i < _parts.size() && i < world_pose.size(); ++i) {
		const int parent = r.parts[i].parent;
		if (parent >= 0) {
			_parts[i].target = normalized(conj(world_pose[size_t(parent)].q) * world_pose[i].q);
		}
	}
}

void Character::set_targets_rest() {
	const Rig& r = *_rig;
	for (size_t i = 0; i < _parts.size(); ++i) {
		const int parent = r.parts[i].parent;
		if (parent >= 0) {
			_parts[i].target = normalized(conj(r.parts[size_t(parent)].rest.q) * r.parts[i].rest.q);
		}
	}
}

void Character::set_tone(float tone) {
	_tone = std::max(0.0f, tone);
}

void Character::set_tone(int part, float tone) {
	_parts[size_t(part)].tone = std::max(0.0f, tone);
}

void Character::pre_step(float dt) {
	(void)dt;
	const Rig& r = *_rig;
	const Vec3 g = _world.gravity();
	// Centres of mass and masses of each part's subtree (children come after parents, so one
	// backward pass sums them).
	const size_t n = _parts.size();
	std::vector<Vec3> moment(n);    // sum of m * com over the subtree
	std::vector<float> mass(n, 0.0f);
	for (size_t i = 0; i < n; ++i) {
		const float m = r.parts[i].mass;
		mass[i] = m;
		moment[i] = _world.center_of_mass(_parts[i].body) * m;
	}
	for (size_t i = n; i-- > 1;) {
		const int parent = r.parts[i].parent;
		if (parent >= 0 && _parts[i].attached) {
			mass[size_t(parent)] += mass[i];
			moment[size_t(parent)] += moment[i];
		}
	}
	for (size_t i = 0; i < n; ++i) {
		const PartDef& def = r.parts[i];
		Part& p = _parts[i];
		if (def.parent < 0 || !p.attached) {
			continue;
		}
		const float tone = _tone * p.tone;
		const float strength = def.muscle.strength * tone;
		// Gravity compensation: cancel the torque gravity puts on this joint's subtree about the
		// pivot, as an internal torque pair (child +, parent -). It's part of the muscle's work,
		// so it comes out of the same strength; the spring gets what's left.
		float comp = 0.0f;
		if (_gravity_comp > 0.0f && strength > 0.0f && mass[i] > 0.0f) {
			const Vec3 pivot = xform(part_transform(def.parent), def.frame_parent.p);
			const Vec3 com = moment[i] * (1.0f / mass[i]);
			Vec3 torque = -cross(com - pivot, g * mass[i]) * _gravity_comp;
			comp = length(torque);
			if (comp > strength) {
				torque = torque * (strength / comp);
				comp = strength;
			}
			_world.apply_torque(p.body, torque);
			_world.apply_torque(_parts[size_t(def.parent)].body, -torque);
		}
		MuscleState m;
		m.target = p.target;
		// Stiffness falls off gently with tone (a relaxed limb is soft, not just weak).
		m.hertz = def.muscle.hertz * std::sqrt(std::min(tone, 1.0f));
		m.damping = def.muscle.damping;
		m.strength = std::max(0.0f, strength - comp);
		_world.set_muscle(p.muscle, def.frame_parent.p, m);
	}
}

float Character::post_step() {
	const Rig& r = *_rig;
	float worst = 0.0f;
	const size_t n = _parts.size();
	std::vector<Transform> pose(n);
	for (size_t i = 0; i < n; ++i) {
		pose[i] = _world.body_transform(_parts[i].body);
	}
	std::vector<Vec3> shift(n, Vec3{});
	bool any = false;
	for (size_t i = 0; i < n; ++i) {
		const PartDef& def = r.parts[i];
		if (def.parent < 0 || !_parts[i].attached) {
			continue;
		}
		// Parents come first: the parent's own shift is already in pose[parent].
		pose[i].p += shift[size_t(def.parent)];
		shift[i] = shift[size_t(def.parent)];
		const Vec3 anchor = xform(pose[size_t(def.parent)], def.frame_parent.p);
		const Vec3 pivot = xform(pose[i], def.frame_child.p);
		const Vec3 d = anchor - pivot;
		const float gap = length(d);
		if (gap > 0.002f) {
			pose[i].p += d;
			shift[i] += d;
			worst = std::max(worst, gap);
		}
		any = any || length(shift[i]) > 0.0f;
	}
	if (any) {
		for (size_t i = 0; i < n; ++i) {
			if (length(shift[i]) > 0.0f) {
				_world.set_transform(_parts[i].body, pose[i]);
			}
		}
	}
	return worst;
}

bool Character::sever(int part) {
	Part& p = _parts[size_t(part)];
	if (_rig->parts[size_t(part)].parent < 0 || !p.attached) {
		return false;
	}
	_world.destroy_joint(p.joint);
	_world.destroy_joint(p.muscle);
	p.joint = 0;
	p.muscle = 0;
	p.attached = false;
	// The piece is dead: everything below it goes limp.
	for (int i : _rig->subtree(part)) {
		_parts[size_t(i)].tone = 0.0f;
	}
	return true;
}

bool Character::attached(int part) const {
	// Attached to the root through every joint up the chain.
	for (int i = part; i >= 0; i = _rig->parts[size_t(i)].parent) {
		if (!_parts[size_t(i)].attached) {
			return false;
		}
	}
	return true;
}

float Character::mass() const {
	float m = 0.0f;
	for (size_t i = 0; i < _parts.size(); ++i) {
		if (attached(int(i))) {
			m += _rig->parts[i].mass;
		}
	}
	return m;
}

Vec3 Character::center_of_mass() const {
	Vec3 sum{};
	float m = 0.0f;
	for (size_t i = 0; i < _parts.size(); ++i) {
		if (attached(int(i))) {
			sum += _world.center_of_mass(_parts[i].body) * _rig->parts[i].mass;
			m += _rig->parts[i].mass;
		}
	}
	return m > 0.0f ? sum * (1.0f / m) : sum;
}

float Character::worst_joint_gap() const {
	float worst = 0.0f;
	for (const Part& p : _parts) {
		if (p.joint) {
			worst = std::max(worst, _world.joint_separation(p.joint));
		}
	}
	return worst;
}

float Character::worst_limit_excess() const {
	float worst = 0.0f;
	for (size_t i = 0; i < _parts.size(); ++i) {
		const Part& p = _parts[i];
		const PartDef& def = _rig->parts[i];
		if (!p.joint) {
			continue;
		}
		if (def.joint == JointKind::Hinge) {
			const float a = _world.hinge_angle(p.joint);
			worst = std::max({ worst, def.hinge_min - a, a - def.hinge_max });
		} else if (def.joint == JointKind::Ball) {
			worst = std::max(worst, _world.joint_cone_angle(p.joint) - def.swing);
			const float tw = _world.joint_twist_angle(p.joint);
			worst = std::max({ worst, def.twist_min - tw, tw - def.twist_max });
		}
	}
	return worst;
}

} // namespace sinew
