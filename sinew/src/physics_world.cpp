#include "sinew/physics_world.hpp"

#include "convert.hpp"

#include <cstring>
#include <vector>

namespace sinew {

struct PhysicsWorld::Impl {
	b3WorldId world = b3_nullWorldId;
	int substeps = 4;
	float joint_hertz = 60.0f;
	float joint_damping = 2.0f;
	std::vector<BodyHandle> dynamic_bodies;
	int bodies = 0;
};

PhysicsWorld::PhysicsWorld(const WorldSettings& settings) :
		_impl(std::make_unique<Impl>()) {
	b3WorldDef def = b3DefaultWorldDef();
	def.gravity = to_b3(settings.gravity);
	def.workerCount = settings.workers < 1 ? 1 : settings.workers;
	_impl->world = b3CreateWorld(&def);
	_impl->substeps = settings.substeps < 1 ? 1 : settings.substeps;
	_impl->joint_hertz = settings.joint_hertz;
	_impl->joint_damping = settings.joint_damping;
}

PhysicsWorld::~PhysicsWorld() {
	if (b3World_IsValid(_impl->world)) {
		b3DestroyWorld(_impl->world);
	}
}

BodyHandle PhysicsWorld::add_static_box(const Transform& xform, Vec3 half_extents, float friction) {
	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = b3_staticBody;
	body_def.position = to_b3(xform.p);
	body_def.rotation = to_b3(xform.q);
	b3BodyId body = b3CreateBody(_impl->world, &body_def);
	b3BoxHull box = b3MakeBoxHull(half_extents.x, half_extents.y, half_extents.z);
	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.baseMaterial.friction = friction;
	b3CreateHullShape(body, &shape_def, &box.base);
	_impl->bodies++;
	return b3StoreBodyId(body);
}

BodyHandle PhysicsWorld::add_capsule_body(const CapsuleDesc& desc) {
	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = b3_dynamicBody;
	body_def.position = to_b3(desc.xform.p);
	body_def.rotation = to_b3(desc.xform.q);
	b3BodyId body = b3CreateBody(_impl->world, &body_def);
	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.density = desc.density;
	shape_def.baseMaterial.friction = desc.friction;
	shape_def.filter.groupIndex = desc.group;
	b3Capsule capsule = { to_b3(desc.a), to_b3(desc.b), desc.radius };
	b3CreateCapsuleShape(body, &shape_def, &capsule);
	BodyHandle h = b3StoreBodyId(body);
	_impl->dynamic_bodies.push_back(h);
	_impl->bodies++;
	return h;
}

JointHandle PhysicsWorld::add_ball_joint(const BallJointDesc& desc) {
	b3SphericalJointDef def = b3DefaultSphericalJointDef();
	def.base.bodyIdA = body_id(desc.parent);
	def.base.bodyIdB = body_id(desc.child);
	def.base.localFrameA = to_b3(desc.frame_parent);
	def.base.localFrameB = to_b3(desc.frame_child);
	def.base.constraintHertz = _impl->joint_hertz;
	def.base.constraintDampingRatio = _impl->joint_damping;
	def.enableConeLimit = desc.cone > 0.0f;
	def.coneAngle = desc.cone;
	def.enableTwistLimit = desc.twist_min < desc.twist_max;
	def.lowerTwistAngle = desc.twist_min;
	def.upperTwistAngle = desc.twist_max;
	return b3StoreJointId(b3CreateSphericalJoint(_impl->world, &def));
}

void PhysicsWorld::destroy_joint(JointHandle joint) {
	b3DestroyJoint(joint_id(joint), true);
}

void PhysicsWorld::step(float dt) {
	b3World_Step(_impl->world, dt, _impl->substeps);
}

Transform PhysicsWorld::body_transform(BodyHandle body) const {
	b3Transform t = b3Body_GetTransform(body_id(body));
	return Transform{ from_b3(t.p), from_b3(t.q) };
}

Vec3 PhysicsWorld::linear_velocity(BodyHandle body) const {
	return from_b3(b3Body_GetLinearVelocity(body_id(body)));
}

void PhysicsWorld::set_linear_velocity(BodyHandle body, Vec3 v) {
	b3Body_SetLinearVelocity(body_id(body), to_b3(v));
}

Vec3 PhysicsWorld::angular_velocity(BodyHandle body) const {
	return from_b3(b3Body_GetAngularVelocity(body_id(body)));
}

void PhysicsWorld::set_angular_velocity(BodyHandle body, Vec3 w) {
	b3Body_SetAngularVelocity(body_id(body), to_b3(w));
}

Vec3 PhysicsWorld::center_of_mass(BodyHandle body) const {
	return from_b3(b3Body_GetWorldCenter(body_id(body)));
}

float PhysicsWorld::body_mass(BodyHandle body) const {
	return b3Body_GetMass(body_id(body));
}

float PhysicsWorld::joint_cone_angle(JointHandle joint) const {
	return b3SphericalJoint_GetConeAngle(joint_id(joint));
}

uint64_t PhysicsWorld::state_hash() const {
	// FNV-1a over the raw float bits: any difference in any body shows.
	uint64_t h = 1469598103934665603ull;
	auto mix = [&h](const void* data, size_t n) {
		const unsigned char* b = static_cast<const unsigned char*>(data);
		for (size_t i = 0; i < n; ++i) {
			h ^= b[i];
			h *= 1099511628211ull;
		}
	};
	for (BodyHandle body : _impl->dynamic_bodies) {
		b3Transform t = b3Body_GetTransform(body_id(body));
		b3Vec3 v = b3Body_GetLinearVelocity(body_id(body));
		b3Vec3 w = b3Body_GetAngularVelocity(body_id(body));
		mix(&t, sizeof(t));
		mix(&v, sizeof(v));
		mix(&w, sizeof(w));
	}
	return h;
}

int PhysicsWorld::body_count() const {
	return _impl->bodies;
}

} // namespace sinew
