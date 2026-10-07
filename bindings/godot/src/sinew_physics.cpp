#include "sinew_physics.h"

#include "sinew/version.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

namespace godot {

namespace {

sinew::Vec3 to_sinew(const Vector3& v) {
	return sinew::Vec3{ float(v.x), float(v.y), float(v.z) };
}

sinew::Transform to_sinew(const Transform3D& t) {
	Quaternion q = t.basis.get_rotation_quaternion();
	return sinew::Transform{ to_sinew(t.origin), sinew::Quat{ float(q.x), float(q.y), float(q.z), float(q.w) } };
}

Vector3 to_godot(sinew::Vec3 v) {
	return Vector3(v.x, v.y, v.z);
}

Transform3D to_godot(const sinew::Transform& t) {
	return Transform3D(Basis(Quaternion(t.q.x, t.q.y, t.q.z, t.q.w)), to_godot(t.p));
}

} // namespace

SinewPhysics::SinewPhysics() :
		_world(std::make_unique<sinew::PhysicsWorld>()) {}

String SinewPhysics::version() {
	return String(sinew::version_string());
}

void SinewPhysics::setup(const Vector3& gravity, int substeps) {
	sinew::WorldSettings s;
	s.gravity = to_sinew(gravity);
	s.substeps = substeps;
	_balancers.clear();
	_limbs.clear();
	_characters.clear();   // they live in the old world
	_world = std::make_unique<sinew::PhysicsWorld>(s);
}

int64_t SinewPhysics::add_static_box(const Transform3D& xform, const Vector3& half_extents) {
	return int64_t(_world->add_static_box(to_sinew(xform), to_sinew(half_extents)));
}

int64_t SinewPhysics::add_capsule(const Transform3D& xform, const Vector3& a, const Vector3& b, double radius,
		double density) {
	sinew::CapsuleDesc d;
	d.xform = to_sinew(xform);
	d.a = to_sinew(a);
	d.b = to_sinew(b);
	d.radius = float(radius);
	d.density = float(density);
	return int64_t(_world->add_capsule_body(d));
}

int64_t SinewPhysics::add_ball_joint(int64_t parent, int64_t child, const Transform3D& frame_parent,
		const Transform3D& frame_child, double cone, double twist_min, double twist_max) {
	sinew::BallJointDesc d;
	d.parent = sinew::BodyHandle(parent);
	d.child = sinew::BodyHandle(child);
	d.frame_parent = to_sinew(frame_parent);
	d.frame_child = to_sinew(frame_child);
	d.cone = float(cone);
	d.twist_min = float(twist_min);
	d.twist_max = float(twist_max);
	return int64_t(_world->add_ball_joint(d));
}

void SinewPhysics::step(double dt) {
	for (auto& [id, b] : _balancers) {
		b->pre_step(float(dt));
	}
	for (auto& [id, c] : _characters) {
		c->pre_step(float(dt));
	}
	_world->step(float(dt));
	for (auto& [id, c] : _characters) {
		c->post_step();
	}
}

Transform3D SinewPhysics::body_transform(int64_t body) const {
	return to_godot(_world->body_transform(sinew::BodyHandle(body)));
}

Vector3 SinewPhysics::linear_velocity(int64_t body) const {
	return to_godot(_world->linear_velocity(sinew::BodyHandle(body)));
}

void SinewPhysics::set_linear_velocity(int64_t body, const Vector3& v) {
	_world->set_linear_velocity(sinew::BodyHandle(body), to_sinew(v));
}

double SinewPhysics::body_mass(int64_t body) const {
	return _world->body_mass(sinew::BodyHandle(body));
}

double SinewPhysics::joint_cone_angle(int64_t joint) const {
	return _world->joint_cone_angle(sinew::JointHandle(joint));
}

int64_t SinewPhysics::state_hash() const {
	return int64_t(_world->state_hash());
}

int SinewPhysics::body_count() const {
	return _world->body_count();
}

// ---------------------------------------------------------------- world mirror

namespace {
sinew::BodyKind kind_of(int kind) {
	return kind == SinewPhysics::KIND_STATIC ? sinew::BodyKind::Static
			: kind == SinewPhysics::KIND_KINEMATIC ? sinew::BodyKind::Kinematic
												 : sinew::BodyKind::Dynamic;
}
} // namespace

int64_t SinewPhysics::add_body(int kind, const Transform3D& xform) {
	return int64_t(_world->add_body(kind_of(kind), to_sinew(xform)));
}

void SinewPhysics::add_box_shape(int64_t body, const Transform3D& local, const Vector3& half_extents, double friction) {
	_world->add_box_shape(sinew::BodyHandle(body), to_sinew(local), to_sinew(half_extents), float(friction));
}

void SinewPhysics::add_sphere_shape(int64_t body, const Vector3& center, double radius, double friction) {
	_world->add_sphere_shape(sinew::BodyHandle(body), to_sinew(center), float(radius), float(friction));
}

void SinewPhysics::add_capsule_shape(int64_t body, const Vector3& a, const Vector3& b, double radius, double friction) {
	_world->add_capsule_shape(sinew::BodyHandle(body), to_sinew(a), to_sinew(b), float(radius), float(friction));
}

bool SinewPhysics::add_hull_shape(int64_t body, const PackedVector3Array& points, double friction) {
	std::vector<sinew::Vec3> pts;
	pts.reserve(size_t(points.size()));
	for (int64_t i = 0; i < points.size(); ++i) {
		pts.push_back(to_sinew(points[i]));
	}
	return _world->add_hull_shape(sinew::BodyHandle(body), pts.data(), int(pts.size()), float(friction));
}

bool SinewPhysics::add_mesh_shape(int64_t body, const PackedVector3Array& vertices, const PackedInt32Array& indices,
		bool clockwise, double friction) {
	if (vertices.size() < 3 || indices.size() < 3) {
		return false;
	}
	std::vector<sinew::Vec3> verts;
	verts.reserve(size_t(vertices.size()));
	for (int64_t i = 0; i < vertices.size(); ++i) {
		verts.push_back(to_sinew(vertices[i]));
	}
	std::vector<int> idx(indices.ptr(), indices.ptr() + indices.size());
	return _world->add_mesh_shape(sinew::BodyHandle(body), verts.data(), int(verts.size()), idx.data(),
			int(idx.size() / 3), clockwise, float(friction));
}

void SinewPhysics::remove_body(int64_t body) {
	_world->remove_body(sinew::BodyHandle(body));
}

void SinewPhysics::set_body_kind(int64_t body, int kind) {
	_world->set_body_kind(sinew::BodyHandle(body), kind_of(kind));
}

void SinewPhysics::set_transform(int64_t body, const Transform3D& xform) {
	_world->set_transform(sinew::BodyHandle(body), to_sinew(xform));
}

void SinewPhysics::move_kinematic(int64_t body, const Transform3D& target, double dt) {
	_world->move_kinematic(sinew::BodyHandle(body), to_sinew(target), float(dt));
}

void SinewPhysics::apply_impulse(int64_t body, const Vector3& impulse, const Vector3& point) {
	_world->apply_linear_impulse(sinew::BodyHandle(body), to_sinew(impulse), to_sinew(point));
}

Vector3 SinewPhysics::angular_velocity(int64_t body) const {
	return to_godot(_world->angular_velocity(sinew::BodyHandle(body)));
}

void SinewPhysics::set_angular_velocity(int64_t body, const Vector3& w) {
	_world->set_angular_velocity(sinew::BodyHandle(body), to_sinew(w));
}

// ---------------------------------------------------------------- rigs

int SinewPhysics::build_humanoid_rig(const PackedStringArray& names, const PackedInt32Array& parents, const Array& rests,
		const Vector3& up, const Vector3& forward, double mass) {
	sinew::SkeletonDesc sk;
	for (int64_t i = 0; i < names.size(); ++i) {
		sk.names.push_back(std::string(names[i].utf8().get_data()));
		sk.parents.push_back(i < parents.size() ? parents[i] : -1);
		sk.rests.push_back(i < rests.size() ? to_sinew(Transform3D(rests[i])) : sinew::Transform{});
	}
	sk.up = to_sinew(up);
	sk.forward = to_sinew(forward);
	sinew::HumanoidOptions options;
	options.mass = float(mass);
	_rigs.push_back(std::make_shared<sinew::Rig>(sinew::build_humanoid_rig(sk, options)));
	return int(_rigs.size()) - 1;
}

int SinewPhysics::rig_part_count(int rig) const {
	return rig >= 0 && rig < int(_rigs.size()) ? int(_rigs[size_t(rig)]->parts.size()) : 0;
}

Dictionary SinewPhysics::rig_part(int rig, int part) const {
	Dictionary d;
	if (rig < 0 || rig >= int(_rigs.size()) || part < 0 || part >= rig_part_count(rig)) {
		return d;
	}
	const sinew::PartDef& p = _rigs[size_t(rig)]->parts[size_t(part)];
	d["name"] = String(p.name.c_str());
	d["bone"] = p.bone;
	d["parent"] = p.parent;
	d["rest"] = to_godot(p.rest);
	d["a"] = to_godot(p.a);
	d["b"] = to_godot(p.b);
	d["radius"] = p.radius;
	d["mass"] = p.mass;
	d["region"] = p.region;
	d["joint"] = int(p.joint);
	d["box"] = p.box;
	d["box_xform"] = to_godot(p.box_xform);
	d["box_half"] = to_godot(p.box_half);
	d["strength"] = p.muscle.strength;
	return d;
}

// ---------------------------------------------------------------- characters

sinew::Character* SinewPhysics::_char(int id) const {
	auto it = _characters.find(id);
	return it == _characters.end() ? nullptr : it->second.get();
}

int SinewPhysics::add_character(int rig, const Transform3D& root, int group) {
	if (rig < 0 || rig >= int(_rigs.size())) {
		return 0;
	}
	const int id = _next_character++;
	_characters[id] = std::make_unique<sinew::Character>(*_world, _rigs[size_t(rig)], to_sinew(root), group);
	_limbs[id] = std::make_unique<sinew::Limbs>(*_rigs[size_t(rig)]);
	return id;
}

void SinewPhysics::remove_character(int character) {
	_balancers.erase(character);
	_limbs.erase(character);
	_characters.erase(character);
}

int64_t SinewPhysics::character_body(int character, int part) const {
	sinew::Character* c = _char(character);
	return c && part >= 0 && part < c->part_count() ? int64_t(c->body(part)) : 0;
}

Array SinewPhysics::character_pose(int character) const {
	Array out;
	if (sinew::Character* c = _char(character)) {
		for (int i = 0; i < c->part_count(); ++i) {
			out.push_back(to_godot(c->part_transform(i)));
		}
	}
	return out;
}

namespace {
std::vector<sinew::Transform> pose_of(const Array& world_pose) {
	std::vector<sinew::Transform> pose;
	pose.reserve(size_t(world_pose.size()));
	for (int64_t i = 0; i < world_pose.size(); ++i) {
		pose.push_back(to_sinew(Transform3D(world_pose[i])));
	}
	return pose;
}
} // namespace

void SinewPhysics::character_set_pose(int character, const Array& world_pose, const Vector3& velocity) {
	if (sinew::Character* c = _char(character)) {
		c->set_pose(pose_of(world_pose), to_sinew(velocity));
	}
}

void SinewPhysics::character_set_targets(int character, const Array& world_pose) {
	if (sinew::Character* c = _char(character)) {
		c->set_targets_from_pose(pose_of(world_pose));
	}
}

void SinewPhysics::character_set_target_local(int character, int part, const Quaternion& local) {
	if (sinew::Character* c = _char(character)) {
		c->set_target_local(part, sinew::Quat{ float(local.x), float(local.y), float(local.z), float(local.w) });
	}
}

void SinewPhysics::character_set_tone(int character, double tone) {
	if (sinew::Character* c = _char(character)) {
		c->set_tone(float(tone));
	}
}

void SinewPhysics::character_set_part_tone(int character, int part, double tone) {
	if (sinew::Character* c = _char(character)) {
		c->set_tone(part, float(tone));
	}
}

void SinewPhysics::character_set_gravity_compensation(int character, double k) {
	if (sinew::Character* c = _char(character)) {
		c->set_gravity_compensation(float(k));
	}
}

void SinewPhysics::character_set_stiffness(int character, double scale) {
	if (sinew::Character* c = _char(character)) {
		c->set_stiffness(float(scale));
	}
}

void SinewPhysics::character_set_damping(int character, double linear, double angular) {
	if (sinew::Character* c = _char(character)) {
		c->set_damping(float(linear), float(angular));
	}
}

void SinewPhysics::character_set_root_assist(int character, const Transform3D& target, double strength, double dt,
		double hertz) {
	if (sinew::Character* c = _char(character)) {
		c->set_root_assist(to_sinew(target), float(strength), float(dt), float(hertz));
	}
}

void SinewPhysics::character_set_kinematic(int character, bool kinematic) {
	if (sinew::Character* c = _char(character)) {
		for (int i = 0; i < c->part_count(); ++i) {
			c->set_part_kinematic(i, kinematic);
		}
	}
}

void SinewPhysics::character_set_part_kinematic(int character, int part, bool kinematic) {
	sinew::Character* c = _char(character);
	if (c && part >= 0 && part < c->part_count()) {
		c->set_part_kinematic(part, kinematic);
	}
}

void SinewPhysics::character_move_kinematic(int character, const Array& world_pose, double dt) {
	if (sinew::Character* c = _char(character)) {
		c->move_kinematic(pose_of(world_pose), float(dt));
	}
}

void SinewPhysics::character_set_velocity(int character, const Vector3& velocity) {
	if (sinew::Character* c = _char(character)) {
		for (int i = 0; i < c->part_count(); ++i) {
			_world->set_linear_velocity(c->body(i), to_sinew(velocity));
			_world->set_angular_velocity(c->body(i), sinew::Vec3{});
		}
	}
}

void SinewPhysics::character_add_velocity(int character, const Vector3& dv, double weight_root, double weight_rest) {
	if (sinew::Character* c = _char(character)) {
		for (int i = 0; i < c->part_count(); ++i) {
			if (!c->attached(i)) {
				continue;
			}
			const float k = float(i == 0 ? weight_root : weight_rest);
			const sinew::Vec3 v = _world->linear_velocity(c->body(i));
			const sinew::Vec3 d = to_sinew(dv);
			_world->set_linear_velocity(c->body(i), sinew::Vec3{ v.x + d.x * k, v.y + d.y * k, v.z + d.z * k });
		}
	}
}

bool SinewPhysics::character_sever(int character, int part) {
	sinew::Character* c = _char(character);
	return c && part >= 0 && part < c->part_count() && c->sever(part);
}

bool SinewPhysics::character_attached(int character, int part) const {
	sinew::Character* c = _char(character);
	return c && part >= 0 && part < c->part_count() && c->attached(part);
}

Vector3 SinewPhysics::character_center_of_mass(int character) const {
	sinew::Character* c = _char(character);
	return c ? to_godot(c->center_of_mass()) : Vector3();
}

double SinewPhysics::character_worst_joint_gap(int character) const {
	sinew::Character* c = _char(character);
	return c ? c->worst_joint_gap() : 0.0;
}

double SinewPhysics::character_worst_limit_excess(int character) const {
	sinew::Character* c = _char(character);
	return c ? c->worst_limit_excess() : 0.0;
}

double SinewPhysics::character_max_speed(int character) const {
	double m = 0.0;
	if (sinew::Character* c = _char(character)) {
		for (int i = 0; i < c->part_count(); ++i) {
			if (c->attached(i)) {
				const sinew::Vec3 v = _world->linear_velocity(c->body(i));
				m = std::max(m, double(std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z)));
			}
		}
	}
	return m;
}

// ---------------------------------------------------------------- limbs

const sinew::Limbs* SinewPhysics::_limbs_of(int id) const {
	auto it = _limbs.find(id);
	return it == _limbs.end() ? nullptr : it->second.get();
}

namespace {
bool limb_ok(int limb) { return limb >= 0 && limb < int(sinew::LimbId::Count); }

Dictionary hit_dict(const sinew::RayHit& h) {
	Dictionary d;
	d["hit"] = h.hit;
	d["point"] = to_godot(h.point);
	d["normal"] = to_godot(h.normal);
	d["body"] = int64_t(h.body);
	return d;
}
} // namespace

Dictionary SinewPhysics::character_limb_state(int character, int limb) const {
	Dictionary d;
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	if (!c || !l || !limb_ok(limb)) {
		return d;
	}
	const sinew::LimbState s = l->state(*c, sinew::LimbId(limb));
	d["present"] = s.present;
	d["attached"] = s.attached;
	d["health"] = s.health;
	d["end_position"] = to_godot(s.end_position);
	d["end_velocity"] = to_godot(s.end_velocity);
	d["contact"] = s.contact;
	d["end_contact"] = s.end_contact;
	d["reach"] = s.reach;
	return d;
}

bool SinewPhysics::character_reach(int character, int limb, const Vector3& point, double weight) {
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	return c && l && limb_ok(limb) && l->reach(*c, sinew::LimbId(limb), to_sinew(point), float(weight));
}

bool SinewPhysics::character_place_foot(int character, int limb, const Vector3& ankle, double weight) {
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	return c && l && limb_ok(limb) && l->place_foot(*c, sinew::LimbId(limb), to_sinew(ankle), float(weight));
}

bool SinewPhysics::character_look_at(int character, const Vector3& point, double weight, double max_angle) {
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	return c && l && l->look(*c, to_sinew(point), float(weight), float(max_angle));
}

void SinewPhysics::character_lean(int character, double pitch, double roll, double weight) {
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	if (c && l) {
		l->lean(*c, float(pitch), float(roll), float(weight));
	}
}

void SinewPhysics::character_set_effector(int character, int part, const Quaternion& local, double weight) {
	sinew::Character* c = _char(character);
	if (c && part >= 0 && part < c->part_count()) {
		c->set_effector(part, sinew::Quat{ float(local.x), float(local.y), float(local.z), float(local.w) }, float(weight));
	}
}

Array SinewPhysics::character_part_contacts(int character, int part) const {
	Array out;
	sinew::Character* c = _char(character);
	if (!c || part < 0 || part >= c->part_count()) {
		return out;
	}
	sinew::ContactPoint pts[16];
	const int n = c->part_contacts(part, pts, 16);
	for (int i = 0; i < n; ++i) {
		Dictionary d;
		d["point"] = to_godot(pts[i].point);
		d["normal"] = to_godot(pts[i].normal);
		d["impulse"] = pts[i].impulse;
		d["kind"] = int(pts[i].other_kind);
		d["body"] = int64_t(pts[i].other);
		out.push_back(d);
	}
	return out;
}

PackedFloat32Array SinewPhysics::character_muscle_effort(int character) const {
	PackedFloat32Array out;
	if (sinew::Character* c = _char(character)) {
		out.resize(c->part_count());
		for (int i = 0; i < c->part_count(); ++i) {
			out.set(i, c->muscle_effort(i));
		}
	}
	return out;
}

void SinewPhysics::character_balance_enable(int character, bool on, const Dictionary& settings) {
	sinew::Character* c = _char(character);
	const sinew::Limbs* l = _limbs_of(character);
	if (!c || !l) {
		return;
	}
	if (!on) {
		if (_balancers.count(character)) {
			// Hand the legs back: no stiffened stance muscles, compensation on, no assist.
			for (int i = 0; i < c->part_count(); ++i) {
				c->set_part_stiffness(i, 1.0f);
				c->set_part_gravity_compensation(i, true);
			}
			if (c->root_assist() > 0.0f) {
				c->set_upright_assist(c->part_transform(0).q, 0.0f, 1.0f / 60.0f);
			}
			_balancers.erase(character);
		}
		return;
	}
	auto& b = _balancers[character];
	if (!b) {
		b = std::make_unique<sinew::Balancer>(*c, *l);
	}
	sinew::BalanceSettings& s = b->settings();
	auto num = [&](const char* key, float& field) {
		if (settings.has(key)) {
			field = float(double(settings[key]));
		}
	};
	num("ankle_kp", s.ankle_kp);
	num("ankle_kd", s.ankle_kd);
	num("max_lean", s.max_lean);
	num("stance_stiffness", s.stance_stiffness);
	num("step_margin", s.step_margin);
	num("step_time", s.step_time);
	num("step_height", s.step_height);
	num("step_past", s.step_past);
	num("step_beyond", s.step_beyond);
	num("max_step", s.max_step);
	num("min_width", s.min_width);
	num("stance_width", s.stance_width);
	num("planted_tilt", s.planted_tilt);
	num("planted_lift", s.planted_lift);
	num("fall_tilt", s.fall_tilt);
	num("fall_sink", s.fall_sink);
	num("upright_assist", s.upright_assist);
	if (settings.has("max_steps")) {
		s.max_steps = int(settings["max_steps"]);
	}
	if (settings.has("stepping")) {
		s.stepping = bool(settings["stepping"]);
	}
}

bool SinewPhysics::character_balance_enabled(int character) const {
	return _balancers.count(character) > 0;
}

void SinewPhysics::character_balance_reset(int character) {
	auto it = _balancers.find(character);
	if (it != _balancers.end()) {
		it->second->reset();
	}
}

void SinewPhysics::character_balance_set_target(int character, const Quaternion& pelvis, double com_height) {
	auto it = _balancers.find(character);
	if (it != _balancers.end()) {
		it->second->set_target(sinew::Quat{ float(pelvis.x), float(pelvis.y), float(pelvis.z), float(pelvis.w) }, float(com_height));
	}
}

Dictionary SinewPhysics::character_balance_state(int character) const {
	Dictionary d;
	auto it = _balancers.find(character);
	if (it == _balancers.end()) {
		return d;
	}
	const sinew::Balancer& b = *it->second;
	d["fallen"] = b.fallen();
	d["reason"] = String(b.fall_reason());
	d["stepping"] = b.stepping();
	d["steps"] = b.steps();
	d["com"] = to_godot(b.com());
	d["com_velocity"] = to_godot(b.com_velocity());
	d["capture_point"] = to_godot(b.capture_point());
	d["capture_error"] = b.capture_error();
	PackedVector3Array hull;
	for (const sinew::Vec3& p : b.support()) {
		hull.push_back(to_godot(p));
	}
	d["support"] = hull;
	d["planted_l"] = b.planted(sinew::LimbId::LegL);
	d["planted_r"] = b.planted(sinew::LimbId::LegR);
	return d;
}

Dictionary SinewPhysics::ground_below(const Vector3& point, double max_distance) const {
	return hit_dict(sinew::probes::ground_below(*_world, to_sinew(point), float(max_distance)));
}

Dictionary SinewPhysics::edge_ahead(const Vector3& from, const Vector3& dir, double range, double min_drop) const {
	const sinew::EdgeProbe e = sinew::probes::edge_ahead(*_world, to_sinew(from), to_sinew(dir), float(range), float(min_drop));
	Dictionary d;
	d["found"] = e.found;
	d["distance"] = e.distance;
	d["drop"] = e.drop;
	d["point"] = to_godot(e.point);
	return d;
}

Dictionary SinewPhysics::wall_within(const Vector3& origin, const Vector3& dir, double reach) const {
	return hit_dict(sinew::probes::wall_within(*_world, to_sinew(origin), to_sinew(dir), float(reach)));
}

double SinewPhysics::impact_eta(const Vector3& com, const Vector3& velocity, double horizon) const {
	return sinew::probes::impact_eta(*_world, to_sinew(com), to_sinew(velocity), float(horizon));
}

void SinewPhysics::_bind_methods() {
	ClassDB::bind_static_method("SinewPhysics", D_METHOD("version"), &SinewPhysics::version);
	ClassDB::bind_method(D_METHOD("setup", "gravity", "substeps"), &SinewPhysics::setup);
	ClassDB::bind_method(D_METHOD("add_static_box", "xform", "half_extents"), &SinewPhysics::add_static_box);
	ClassDB::bind_method(D_METHOD("add_capsule", "xform", "a", "b", "radius", "density"), &SinewPhysics::add_capsule);
	ClassDB::bind_method(D_METHOD("add_ball_joint", "parent", "child", "frame_parent", "frame_child", "cone",
								 "twist_min", "twist_max"),
			&SinewPhysics::add_ball_joint);
	ClassDB::bind_method(D_METHOD("step", "dt"), &SinewPhysics::step);
	ClassDB::bind_method(D_METHOD("body_transform", "body"), &SinewPhysics::body_transform);
	ClassDB::bind_method(D_METHOD("linear_velocity", "body"), &SinewPhysics::linear_velocity);
	ClassDB::bind_method(D_METHOD("set_linear_velocity", "body", "velocity"), &SinewPhysics::set_linear_velocity);
	ClassDB::bind_method(D_METHOD("body_mass", "body"), &SinewPhysics::body_mass);
	ClassDB::bind_method(D_METHOD("joint_cone_angle", "joint"), &SinewPhysics::joint_cone_angle);
	ClassDB::bind_method(D_METHOD("state_hash"), &SinewPhysics::state_hash);
	ClassDB::bind_method(D_METHOD("body_count"), &SinewPhysics::body_count);

	BIND_ENUM_CONSTANT(KIND_STATIC);
	BIND_ENUM_CONSTANT(KIND_KINEMATIC);
	BIND_ENUM_CONSTANT(KIND_DYNAMIC);
	ClassDB::bind_method(D_METHOD("add_body", "kind", "xform"), &SinewPhysics::add_body);
	ClassDB::bind_method(D_METHOD("add_box_shape", "body", "local", "half_extents", "friction"), &SinewPhysics::add_box_shape, DEFVAL(0.6));
	ClassDB::bind_method(D_METHOD("add_sphere_shape", "body", "center", "radius", "friction"), &SinewPhysics::add_sphere_shape, DEFVAL(0.6));
	ClassDB::bind_method(D_METHOD("add_capsule_shape", "body", "a", "b", "radius", "friction"), &SinewPhysics::add_capsule_shape, DEFVAL(0.6));
	ClassDB::bind_method(D_METHOD("add_hull_shape", "body", "points", "friction"), &SinewPhysics::add_hull_shape, DEFVAL(0.6));
	ClassDB::bind_method(D_METHOD("add_mesh_shape", "body", "vertices", "indices", "clockwise", "friction"), &SinewPhysics::add_mesh_shape, DEFVAL(0.6));
	ClassDB::bind_method(D_METHOD("remove_body", "body"), &SinewPhysics::remove_body);
	ClassDB::bind_method(D_METHOD("set_body_kind", "body", "kind"), &SinewPhysics::set_body_kind);
	ClassDB::bind_method(D_METHOD("set_transform", "body", "xform"), &SinewPhysics::set_transform);
	ClassDB::bind_method(D_METHOD("move_kinematic", "body", "target", "dt"), &SinewPhysics::move_kinematic);
	ClassDB::bind_method(D_METHOD("apply_impulse", "body", "impulse", "point"), &SinewPhysics::apply_impulse);
	ClassDB::bind_method(D_METHOD("angular_velocity", "body"), &SinewPhysics::angular_velocity);
	ClassDB::bind_method(D_METHOD("set_angular_velocity", "body", "velocity"), &SinewPhysics::set_angular_velocity);

	ClassDB::bind_method(D_METHOD("build_humanoid_rig", "names", "parents", "rests", "up", "forward", "mass"), &SinewPhysics::build_humanoid_rig);
	ClassDB::bind_method(D_METHOD("rig_part_count", "rig"), &SinewPhysics::rig_part_count);
	ClassDB::bind_method(D_METHOD("rig_part", "rig", "part"), &SinewPhysics::rig_part);

	ClassDB::bind_method(D_METHOD("add_character", "rig", "root", "group"), &SinewPhysics::add_character);
	ClassDB::bind_method(D_METHOD("remove_character", "character"), &SinewPhysics::remove_character);
	ClassDB::bind_method(D_METHOD("character_body", "character", "part"), &SinewPhysics::character_body);
	ClassDB::bind_method(D_METHOD("character_pose", "character"), &SinewPhysics::character_pose);
	ClassDB::bind_method(D_METHOD("character_set_pose", "character", "world_pose", "velocity"), &SinewPhysics::character_set_pose);
	ClassDB::bind_method(D_METHOD("character_set_targets", "character", "world_pose"), &SinewPhysics::character_set_targets);
	ClassDB::bind_method(D_METHOD("character_set_target_local", "character", "part", "local"), &SinewPhysics::character_set_target_local);
	ClassDB::bind_method(D_METHOD("character_set_tone", "character", "tone"), &SinewPhysics::character_set_tone);
	ClassDB::bind_method(D_METHOD("character_set_part_tone", "character", "part", "tone"), &SinewPhysics::character_set_part_tone);
	ClassDB::bind_method(D_METHOD("character_set_gravity_compensation", "character", "k"), &SinewPhysics::character_set_gravity_compensation);
	ClassDB::bind_method(D_METHOD("character_set_stiffness", "character", "scale"), &SinewPhysics::character_set_stiffness);
	ClassDB::bind_method(D_METHOD("character_set_damping", "character", "linear", "angular"), &SinewPhysics::character_set_damping);
	ClassDB::bind_method(D_METHOD("character_set_root_assist", "character", "target", "strength", "dt", "hertz"), &SinewPhysics::character_set_root_assist, DEFVAL(4.0));
	ClassDB::bind_method(D_METHOD("character_set_kinematic", "character", "kinematic"), &SinewPhysics::character_set_kinematic);
	ClassDB::bind_method(D_METHOD("character_set_part_kinematic", "character", "part", "kinematic"), &SinewPhysics::character_set_part_kinematic);
	ClassDB::bind_method(D_METHOD("character_move_kinematic", "character", "world_pose", "dt"), &SinewPhysics::character_move_kinematic);
	ClassDB::bind_method(D_METHOD("character_set_velocity", "character", "velocity"), &SinewPhysics::character_set_velocity);
	ClassDB::bind_method(D_METHOD("character_add_velocity", "character", "dv", "weight_root", "weight_rest"), &SinewPhysics::character_add_velocity);
	ClassDB::bind_method(D_METHOD("character_sever", "character", "part"), &SinewPhysics::character_sever);
	ClassDB::bind_method(D_METHOD("character_attached", "character", "part"), &SinewPhysics::character_attached);
	ClassDB::bind_method(D_METHOD("character_center_of_mass", "character"), &SinewPhysics::character_center_of_mass);
	ClassDB::bind_method(D_METHOD("character_worst_joint_gap", "character"), &SinewPhysics::character_worst_joint_gap);
	ClassDB::bind_method(D_METHOD("character_worst_limit_excess", "character"), &SinewPhysics::character_worst_limit_excess);
	ClassDB::bind_method(D_METHOD("character_max_speed", "character"), &SinewPhysics::character_max_speed);

	ClassDB::bind_method(D_METHOD("character_limb_state", "character", "limb"), &SinewPhysics::character_limb_state);
	ClassDB::bind_method(D_METHOD("character_reach", "character", "limb", "point", "weight"), &SinewPhysics::character_reach, DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("character_place_foot", "character", "limb", "ankle", "weight"), &SinewPhysics::character_place_foot, DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("character_look_at", "character", "point", "weight", "max_angle"), &SinewPhysics::character_look_at, DEFVAL(1.0), DEFVAL(1.2));
	ClassDB::bind_method(D_METHOD("character_lean", "character", "pitch", "roll", "weight"), &SinewPhysics::character_lean, DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("character_set_effector", "character", "part", "local", "weight"), &SinewPhysics::character_set_effector, DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("character_part_contacts", "character", "part"), &SinewPhysics::character_part_contacts);
	ClassDB::bind_method(D_METHOD("character_muscle_effort", "character"), &SinewPhysics::character_muscle_effort);
	ClassDB::bind_method(D_METHOD("character_balance_enable", "character", "on", "settings"), &SinewPhysics::character_balance_enable, DEFVAL(Dictionary()));
	ClassDB::bind_method(D_METHOD("character_balance_enabled", "character"), &SinewPhysics::character_balance_enabled);
	ClassDB::bind_method(D_METHOD("character_balance_reset", "character"), &SinewPhysics::character_balance_reset);
	ClassDB::bind_method(D_METHOD("character_balance_set_target", "character", "pelvis", "com_height"), &SinewPhysics::character_balance_set_target);
	ClassDB::bind_method(D_METHOD("character_balance_state", "character"), &SinewPhysics::character_balance_state);
	ClassDB::bind_method(D_METHOD("ground_below", "point", "max_distance"), &SinewPhysics::ground_below, DEFVAL(3.0));
	ClassDB::bind_method(D_METHOD("edge_ahead", "from", "dir", "range", "min_drop"), &SinewPhysics::edge_ahead, DEFVAL(1.5), DEFVAL(0.45));
	ClassDB::bind_method(D_METHOD("wall_within", "origin", "dir", "reach"), &SinewPhysics::wall_within, DEFVAL(0.8));
	ClassDB::bind_method(D_METHOD("impact_eta", "com", "velocity", "horizon"), &SinewPhysics::impact_eta, DEFVAL(3.0));
}

} // namespace godot
