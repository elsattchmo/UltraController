#include "sinew_physics.h"

#include "sinew/version.hpp"

#include <godot_cpp/core/class_db.hpp>

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
	_world->step(float(dt));
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
}

} // namespace godot
