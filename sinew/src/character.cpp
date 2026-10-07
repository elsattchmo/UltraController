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
		d.box = def.box;
		d.box_xform = def.box_xform;
		d.box_half = def.box_half;
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
	if (_anchor) {
		_world.destroy_body(_anchor);
	}
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
	_parts[size_t(part)].tracking = false;
}

void Character::set_targets_from_pose(const std::vector<Transform>& world_pose) {
	const Rig& r = *_rig;
	for (size_t i = 0; i < _parts.size() && i < world_pose.size(); ++i) {
		const int parent = r.parts[i].parent;
		if (parent >= 0) {
			Part& p = _parts[i];
			const Quat q = normalized(conj(world_pose[size_t(parent)].q) * world_pose[i].q);
			p.prev_target = p.tracking ? p.target : q;
			p.target = q;
			p.tracking = true;
		}
	}
}

void Character::set_part_kinematic(int part, bool kinematic) {
	Part& p = _parts[size_t(part)];
	if (p.kinematic == kinematic || !attached(part)) {
		return;
	}
	p.kinematic = kinematic;
	_world.set_body_kind(p.body, kinematic ? BodyKind::Kinematic : BodyKind::Dynamic);
}

void Character::move_kinematic(const std::vector<Transform>& world_pose, float dt) {
	for (size_t i = 0; i < _parts.size() && i < world_pose.size(); ++i) {
		if (_parts[i].kinematic) {
			_world.move_kinematic(_parts[i].body, world_pose[i], dt);
		}
	}
}

void Character::set_effector(int part, Quat local, float weight) {
	Part& p = _parts[size_t(part)];
	p.effector = normalized(local);
	p.effector_weight = std::clamp(weight, 0.0f, 1.0f);
}

Quat Character::effective_target(int part) const {
	const Part& p = _parts[size_t(part)];
	return p.effector_weight > 0.0f ? normalized(slerp(p.target, p.effector, p.effector_weight)) : p.target;
}

float Character::muscle_torque(int part) const {
	const Part& p = _parts[size_t(part)];
	return p.muscle && !p.kinematic ? length(_world.joint_torque(p.muscle)) : 0.0f;
}

float Character::muscle_effort(int part) const {
	const Part& p = _parts[size_t(part)];
	if (!p.muscle || p.kinematic || !p.attached) {
		return -1.0f;
	}
	const float strength = _rig->parts[size_t(part)].muscle.strength * _stiffness;
	return strength > 0.0f ? muscle_torque(part) / strength : 0.0f;
}

int Character::part_of(BodyHandle body) const {
	for (size_t i = 0; i < _parts.size(); ++i) {
		if (_parts[i].body == body) {
			return int(i);
		}
	}
	return -1;
}

int Character::part_contacts(int part, ContactPoint* out, int capacity) const {
	ContactPoint buf[16];
	const int n = _world.contacts(_parts[size_t(part)].body, buf, 16);
	int written = 0;
	for (int i = 0; i < n && written < capacity; ++i) {
		if (part_of(buf[i].other) < 0) {
			out[written++] = buf[i];
		}
	}
	return written;
}

bool Character::part_touching(int part, bool static_only) const {
	ContactPoint buf[16];
	const int n = part_contacts(part, buf, 16);
	for (int i = 0; i < n; ++i) {
		if (!static_only || buf[i].other_kind != BodyKind::Dynamic) {
			return true;
		}
	}
	return false;
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

void Character::set_root_assist(const Transform& target, float strength, float dt, float hertz) {
	_assist = std::max(0.0f, strength);
	if (_anchor == 0) {
		if (_assist <= 0.0f) {
			return;
		}
		_anchor = _world.add_body(BodyKind::Kinematic, target);
		_drive = _world.add_drive(_anchor, _parts[0].body);
	} else {
		// Moved, not teleported: the anchor carries the target's velocity, so the drive's
		// damping doesn't drag a walking body back.
		_world.move_kinematic(_anchor, target, dt);
	}
	const float g = length(_world.gravity());
	const float m = mass();
	// Box3D normalises the drive by the pelvis' own mass (8 kg) while it carries the whole body:
	// scale the frequency by sqrt(M / m_pelvis) so it acts as a spring on the body (at a plain
	// 4 Hz it sagged 14 cm under the body's weight).
	hertz *= std::sqrt(m / std::max(_rig->parts[0].mass, 0.1f));
	// The angular spring acts on the pelvis' own small inertia while it carries the whole upper
	// body's lean: it needs to be much stiffer than the linear one (at the same 4 Hz the pelvis
	// sagged 6 deg).
	_world.set_drive(_drive, Transform{}, _assist > 0.0f ? hertz : 0.0f, 1.0f, m * g * 2.0f * _assist,
			_assist > 0.0f ? 2.5f * hertz : 0.0f, 1.0f, 600.0f * _assist);
}

void Character::set_upright_assist(Quat rotation, float strength, float dt, float hertz) {
	_assist = std::max(0.0f, strength);
	const Transform target{ part_transform(0).p, normalized(rotation) };
	if (_anchor == 0) {
		if (_assist <= 0.0f) {
			return;
		}
		_anchor = _world.add_body(BodyKind::Kinematic, target);
		_drive = _world.add_drive(_anchor, _parts[0].body);
	} else {
		_world.move_kinematic(_anchor, target, dt);
	}
	hertz *= std::sqrt(mass() / std::max(_rig->parts[0].mass, 0.1f));
	_world.set_drive(_drive, Transform{}, 0.0f, 1.0f, 0.0f, _assist > 0.0f ? 2.5f * hertz : 0.0f, 1.0f, 600.0f * _assist);
}

void Character::set_damping(float linear, float angular) {
	for (Part& p : _parts) {
		_world.set_damping(p.body, linear, angular);
	}
}

void Character::set_tone(float tone) {
	_tone = std::max(0.0f, tone);
}

void Character::set_tone(int part, float tone) {
	_parts[size_t(part)].tone = std::max(0.0f, tone);
}

void Character::pre_step(float dt) {
	const Rig& r = *_rig;
	const Vec3 g = _world.gravity();
	// Centres of mass and masses of each part's subtree (children come after parents, so one
	// backward pass sums them).
	const size_t n = _parts.size();
	std::vector<Vec3> moment(n);    // sum of m * com over the subtree
	std::vector<float> mass(n, 0.0f);
	std::vector<Vec3> com(n);
	for (size_t i = 0; i < n; ++i) {
		const float m = r.parts[i].mass;
		mass[i] = m;
		com[i] = _world.center_of_mass(_parts[i].body);
		moment[i] = com[i] * m;
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
		if (def.parent < 0 || !p.attached || p.kinematic) {
			continue;
		}
		const float tone = _tone * p.tone;
		const float strength = def.muscle.strength * tone * _stiffness;
		// Gravity compensation: cancel the torque gravity puts on this joint's subtree about the
		// pivot, as an internal torque pair (child +, parent -). It's part of the muscle's work,
		// so it comes out of the same strength; the spring gets what's left.
		float comp = 0.0f;
		if (_gravity_comp > 0.0f && p.gravity_comp && strength > 0.0f && mass[i] > 0.0f) {
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
		m.target = effective_target(int(i));
		// Box3D normalises a joint spring by the two bodies' own inertia, but the joint swings
		// everything below it: scale stiffness and damping by sqrt(subtree inertia / part inertia)
		// about the pivot, so the muscle is the spring it says on the load it carries (the spine,
		// carrying a 38 kg upper body on a 6 kg part, swung back and forth after a shove and
		// never settled; a clavicle swinging a whole arm let it sway 12 cm).
		// ... and only as far as the muscle is working: a low-tone body lying on the floor is
		// soft (stiff springs with tiny torque caps chattered: hands buzzing at 1-3 m/s).
		const float load = 1.0f + (load_scale(int(i), com) - 1.0f) * std::clamp(tone, 0.0f, 1.0f);
		// Stiffness falls off gently with tone (a relaxed limb is soft, not just weak).
		m.hertz = def.muscle.hertz * std::sqrt(std::min(tone, 1.0f)) * load * _stiffness * p.stiffness;
		m.damping = def.muscle.damping * load * std::max(p.stiffness, 1.0f);
		if (_lead && p.tracking && dt > 0.0f && m.hertz > 0.0f) {
			// A damped spring trails a target moving at w by 2 zeta / omega seconds: aim that far
			// ahead along the target's own motion (capped at 0.6 rad).
			const float lead = std::min(2.0f * def.muscle.damping / (2.0f * PI * m.hertz), 0.12f);
			Vec3 w = to_rotation_vector(conj(p.prev_target) * p.target) * (lead / dt);
			const float a = length(w);
			if (a > 0.6f) {
				w = w * (0.6f / a);
			}
			if (a > 1e-5f) {
				m.target = normalized(m.target * axis_angle(w, length(w)));
			}
		}
		// The target's motion is used once: a target nobody updates again stands still (a body
		// knocked down mid-walk kept leading its last walking target and its feet buzzed).
		p.prev_target = p.target;
		m.strength = std::max(0.0f, strength - comp);
		_world.set_muscle(p.muscle, def.frame_parent.p, m);
	}
	for (Part& p : _parts) {
		p.effector_weight = 0.0f;   // an effector lasts one tick
	}
}

float Character::load_scale(int part, const std::vector<Vec3>& com) const {
	const Rig& r = *_rig;
	const PartDef& def = r.parts[size_t(part)];
	const Vec3 pivot = xform(_world.body_transform(_parts[size_t(def.parent)].body), def.frame_parent.p);
	// The part's own inertia about the pivot: a capsule's (rod + radius) plus its offset.
	auto own = [&](int i) {
		const PartDef& d = r.parts[size_t(i)];
		const float len = length(d.b - d.a);
		return d.mass * (len * len / 12.0f + d.radius * d.radius * 0.4f);
	};
	const float d0 = length(com[size_t(part)] - pivot);
	const float part_i = own(part) + def.mass * d0 * d0;
	float sub_i = 0.0f;
	for (int k : r.subtree(part)) {
		if (_parts[size_t(k)].attached) {
			const float d = length(com[size_t(k)] - pivot);
			sub_i += own(k) + r.parts[size_t(k)].mass * d * d;
		}
	}
	return std::clamp(std::sqrt(sub_i / std::max(part_i, 1e-5f)), 1.0f, 6.0f);
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
