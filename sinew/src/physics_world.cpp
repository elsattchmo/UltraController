#include "sinew/physics_world.hpp"

#include "convert.hpp"

#include "sinew/math.hpp"

#include <cstring>
#include <vector>

namespace sinew {

namespace {
// Character parts carry this category; world queries mask it out (they look at the level).
constexpr uint64_t CAT_PART = 2;
b3QueryFilter level_filter() {
	b3QueryFilter f = b3DefaultQueryFilter();
	f.maskBits = ~CAT_PART;
	return f;
}
} // namespace

struct PhysicsWorld::Impl {
	b3WorldId world = b3_nullWorldId;
	int substeps = 4;
	float joint_hertz = 60.0f;
	float joint_damping = 2.0f;
	std::vector<BodyHandle> dynamic_bodies;
	std::vector<b3MeshData*> meshes;   // mesh shapes reference these: freed with the world
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
	b3World_EnableContinuous(_impl->world, settings.continuous);
	if (settings.contact_hertz > 0.0f) {
		b3World_SetContactTuning(_impl->world, settings.contact_hertz, settings.contact_damping,
				settings.contact_push_speed);
	}
}

PhysicsWorld::~PhysicsWorld() {
	if (b3World_IsValid(_impl->world)) {
		b3DestroyWorld(_impl->world);
	}
	for (b3MeshData* m : _impl->meshes) {
		b3DestroyMesh(m);
	}
}

BodyHandle PhysicsWorld::add_body(BodyKind kind, const Transform& xform) {
	b3BodyDef def = b3DefaultBodyDef();
	def.type = kind == BodyKind::Static ? b3_staticBody : kind == BodyKind::Kinematic ? b3_kinematicBody : b3_dynamicBody;
	def.position = to_b3(xform.p);
	def.rotation = to_b3(xform.q);
	_impl->bodies++;
	return b3StoreBodyId(b3CreateBody(_impl->world, &def));
}

namespace {
b3ShapeDef shape_def(float friction) {
	b3ShapeDef def = b3DefaultShapeDef();
	def.baseMaterial.friction = friction;
	return def;
}
} // namespace

void PhysicsWorld::add_box_shape(BodyHandle body, const Transform& local, Vec3 half_extents, float friction) {
	b3BoxHull box = b3MakeTransformedBoxHull(half_extents.x, half_extents.y, half_extents.z, to_b3(local));
	b3ShapeDef def = shape_def(friction);
	b3CreateHullShape(body_id(body), &def, &box.base);
}

void PhysicsWorld::add_sphere_shape(BodyHandle body, Vec3 center, float radius, float friction) {
	b3Sphere sphere = { to_b3(center), radius };
	b3ShapeDef def = shape_def(friction);
	b3CreateSphereShape(body_id(body), &def, &sphere);
}

void PhysicsWorld::add_capsule_shape(BodyHandle body, Vec3 a, Vec3 b, float radius, float friction) {
	b3Capsule capsule = { to_b3(a), to_b3(b), radius };
	b3ShapeDef def = shape_def(friction);
	b3CreateCapsuleShape(body_id(body), &def, &capsule);
}

bool PhysicsWorld::add_hull_shape(BodyHandle body, const Vec3* points, int count, float friction) {
	std::vector<b3Vec3> pts(static_cast<size_t>(count));
	for (int i = 0; i < count; ++i) {
		pts[size_t(i)] = to_b3(points[i]);
	}
	b3HullData* hull = b3CreateHull(pts.data(), count, 64);
	if (hull == nullptr) {
		return false;
	}
	b3ShapeDef def = shape_def(friction);
	b3CreateHullShape(body_id(body), &def, hull);
	b3DestroyHull(hull);   // the shape keeps its own copy
	return true;
}

bool PhysicsWorld::add_mesh_shape(BodyHandle body, const Vec3* vertices, int vertex_count, const int* indices,
		int triangle_count, bool clockwise, float friction) {
	std::vector<b3Vec3> verts(static_cast<size_t>(vertex_count));
	for (int i = 0; i < vertex_count; ++i) {
		verts[size_t(i)] = to_b3(vertices[i]);
	}
	std::vector<int32_t> idx(indices, indices + size_t(triangle_count) * 3);
	b3MeshDef mesh_def = {};
	mesh_def.vertices = verts.data();
	mesh_def.indices = idx.data();
	mesh_def.vertexCount = vertex_count;
	mesh_def.triangleCount = triangle_count;
	mesh_def.weldVertices = true;
	mesh_def.weldTolerance = 0.001f;
	mesh_def.identifyEdges = true;
	mesh_def.clockWiseWinding = clockwise;
	b3MeshData* mesh = b3CreateMesh(&mesh_def, nullptr, 0);
	if (mesh == nullptr) {
		return false;
	}
	_impl->meshes.push_back(mesh);
	b3ShapeDef def = shape_def(friction);
	b3CreateMeshShape(body_id(body), &def, mesh, b3Vec3{ 1.0f, 1.0f, 1.0f });
	return true;
}

void PhysicsWorld::remove_body(BodyHandle body) {
	destroy_body(body);
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

BodyHandle PhysicsWorld::add_part(const PartBodyDesc& desc) {
	b3BodyDef body_def = b3DefaultBodyDef();
	body_def.type = b3_dynamicBody;
	body_def.position = to_b3(desc.xform.p);
	body_def.rotation = to_b3(desc.xform.q);
	body_def.linearVelocity = to_b3(desc.velocity);
	body_def.name = desc.name;
	b3BodyId body = b3CreateBody(_impl->world, &body_def);
	const float r = desc.radius;
	const float h = length(desc.b - desc.a);
	const float volume = PI * r * r * h + 4.0f / 3.0f * PI * r * r * r;
	b3ShapeDef shape_def = b3DefaultShapeDef();
	shape_def.density = desc.mass / volume;
	shape_def.baseMaterial.friction = desc.friction;
	shape_def.filter.groupIndex = desc.group;
	shape_def.filter.categoryBits = CAT_PART;
	b3Capsule capsule = { to_b3(desc.a), to_b3(desc.b), r };
	b3CreateCapsuleShape(body, &shape_def, &capsule);
	BodyHandle handle = b3StoreBodyId(body);
	_impl->dynamic_bodies.push_back(handle);
	_impl->bodies++;
	return handle;
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

JointHandle PhysicsWorld::add_hinge_joint(const HingeJointDesc& desc) {
	b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
	def.base.bodyIdA = body_id(desc.parent);
	def.base.bodyIdB = body_id(desc.child);
	def.base.localFrameA = to_b3(desc.frame_parent);
	def.base.localFrameB = to_b3(desc.frame_child);
	def.base.constraintHertz = _impl->joint_hertz;
	def.base.constraintDampingRatio = _impl->joint_damping;
	def.enableLimit = desc.min < desc.max;
	def.lowerAngle = desc.min;
	def.upperAngle = desc.max;
	return b3StoreJointId(b3CreateRevoluteJoint(_impl->world, &def));
}

JointHandle PhysicsWorld::add_muscle(BodyHandle parent, BodyHandle child, Vec3 pivot_in_parent, Vec3 pivot_in_child) {
	b3MotorJointDef def = b3DefaultMotorJointDef();
	def.base.bodyIdA = body_id(parent);
	def.base.bodyIdB = body_id(child);
	def.base.localFrameA = b3Transform{ to_b3(pivot_in_parent), b3Quat_identity };
	def.base.localFrameB = b3Transform{ to_b3(pivot_in_child), b3Quat_identity };
	def.base.collideConnected = false;
	def.linearHertz = 0.0f;
	def.maxSpringForce = 0.0f;
	def.maxVelocityForce = 0.0f;
	def.maxVelocityTorque = 0.0f;
	def.angularHertz = 0.0f;
	def.angularDampingRatio = 1.0f;
	def.maxSpringTorque = 0.0f;
	return b3StoreJointId(b3CreateMotorJoint(_impl->world, &def));
}

namespace {
// Box3D's motor joint skips a spring whose cap or hertz is 0 - but keeps warm-starting with the
// impulse it last stored, every substep, for good: a "switched off" root drive went on holding
// the body's weight (it floated up), a relaxed muscle kept its last torque. A tiny cap instead
// keeps the spring solved and clamps that impulse to nothing.
constexpr float OFF_CAP = 1e-6f;
float on_hertz(float hertz, float cap) { return cap > OFF_CAP && hertz > 0.0f ? hertz : 1.0f; }
float on_cap(float cap) { return cap > OFF_CAP ? cap : OFF_CAP; }
} // namespace

void PhysicsWorld::set_muscle(JointHandle muscle, Vec3 pivot_in_parent, const MuscleState& state) {
	b3JointId id = joint_id(muscle);
	b3Joint_SetLocalFrameA(id, b3Transform{ to_b3(pivot_in_parent), to_b3(state.target) });
	b3MotorJoint_SetAngularHertz(id, on_hertz(state.hertz, state.strength));
	b3MotorJoint_SetAngularDampingRatio(id, state.damping);
	b3MotorJoint_SetMaxSpringTorque(id, on_cap(state.strength));
}

JointHandle PhysicsWorld::add_drive(BodyHandle parent, BodyHandle child) {
	b3MotorJointDef def = b3DefaultMotorJointDef();
	def.base.bodyIdA = body_id(parent);
	def.base.bodyIdB = body_id(child);
	def.base.localFrameA = b3Transform_identity;
	def.base.localFrameB = b3Transform_identity;
	def.linearHertz = 0.0f;
	def.maxSpringForce = 0.0f;
	def.angularHertz = 0.0f;
	def.maxSpringTorque = 0.0f;
	def.maxVelocityForce = 0.0f;
	def.maxVelocityTorque = 0.0f;
	return b3StoreJointId(b3CreateMotorJoint(_impl->world, &def));
}

void PhysicsWorld::set_drive(JointHandle drive, const Transform& frame_in_parent, float linear_hertz, float linear_damping,
		float max_force, float angular_hertz, float angular_damping, float max_torque) {
	b3JointId id = joint_id(drive);
	b3Joint_SetLocalFrameA(id, to_b3(frame_in_parent));
	b3MotorJoint_SetLinearHertz(id, on_hertz(linear_hertz, max_force));
	b3MotorJoint_SetLinearDampingRatio(id, linear_damping);
	b3MotorJoint_SetMaxSpringForce(id, on_cap(max_force));
	b3MotorJoint_SetAngularHertz(id, on_hertz(angular_hertz, max_torque));
	b3MotorJoint_SetAngularDampingRatio(id, angular_damping);
	b3MotorJoint_SetMaxSpringTorque(id, on_cap(max_torque));
}

JointHandle PhysicsWorld::add_no_collide(BodyHandle a, BodyHandle b) {
	b3FilterJointDef def = b3DefaultFilterJointDef();
	def.base.bodyIdA = body_id(a);
	def.base.bodyIdB = body_id(b);
	return b3StoreJointId(b3CreateFilterJoint(_impl->world, &def));
}

void PhysicsWorld::destroy_joint(JointHandle joint) {
	b3DestroyJoint(joint_id(joint), true);
}

void PhysicsWorld::destroy_body(BodyHandle body) {
	auto& v = _impl->dynamic_bodies;
	for (size_t i = 0; i < v.size(); ++i) {
		if (v[i] == body) {
			v.erase(v.begin() + long(i));
			break;
		}
	}
	b3DestroyBody(body_id(body));
	_impl->bodies--;
}

float PhysicsWorld::joint_separation(JointHandle joint) const {
	return b3Joint_GetLinearSeparation(joint_id(joint));
}

float PhysicsWorld::hinge_angle(JointHandle joint) const {
	return b3RevoluteJoint_GetAngle(joint_id(joint));
}

float PhysicsWorld::joint_twist_angle(JointHandle joint) const {
	return b3SphericalJoint_GetTwistAngle(joint_id(joint));
}

void PhysicsWorld::set_body_kind(BodyHandle body, BodyKind kind) {
	b3Body_SetType(body_id(body), kind == BodyKind::Static ? b3_staticBody
					: kind == BodyKind::Kinematic				   ? b3_kinematicBody
																   : b3_dynamicBody);
}

void PhysicsWorld::set_transform(BodyHandle body, const Transform& xform) {
	b3Body_SetTransform(body_id(body), to_b3(xform.p), to_b3(xform.q));
}

void PhysicsWorld::move_kinematic(BodyHandle body, const Transform& target, float dt) {
	b3Body_SetTargetTransform(body_id(body), to_b3(target), dt, true);
}

void PhysicsWorld::set_damping(BodyHandle body, float linear, float angular) {
	b3Body_SetLinearDamping(body_id(body), linear);
	b3Body_SetAngularDamping(body_id(body), angular);
}

void PhysicsWorld::apply_torque(BodyHandle body, Vec3 torque) {
	b3Body_ApplyTorque(body_id(body), to_b3(torque), true);
}

void PhysicsWorld::apply_linear_impulse(BodyHandle body, Vec3 impulse, Vec3 world_point) {
	b3Body_ApplyLinearImpulse(body_id(body), to_b3(impulse), to_b3(world_point), true);
}

Vec3 PhysicsWorld::gravity() const {
	return from_b3(b3World_GetGravity(_impl->world));
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

int PhysicsWorld::contacts(BodyHandle body, ContactPoint* out, int capacity) const {
	const b3BodyId id = body_id(body);
	const int cap = b3Body_GetContactCapacity(id);
	if (cap <= 0 || capacity <= 0) {
		return 0;
	}
	std::vector<b3ContactData> data(static_cast<size_t>(cap));
	const int n = b3Body_GetContactData(id, data.data(), cap);
	int written = 0;
	for (int i = 0; i < n && written < capacity; ++i) {
		const b3ContactData& c = data[size_t(i)];
		const b3BodyId a = b3Shape_GetBody(c.shapeIdA);
		const b3BodyId b = b3Shape_GetBody(c.shapeIdB);
		const bool we_are_a = B3_ID_EQUALS(a, id);
		const b3BodyId other = we_are_a ? b : a;
		const Vec3 center_a = from_b3(b3Body_GetWorldCenter(a));
		for (int m = 0; m < c.manifoldCount && written < capacity; ++m) {
			const b3Manifold& man = c.manifolds[m];
			// Box3D's normal points from A to B: into us when we are B.
			const Vec3 normal = from_b3(man.normal) * (we_are_a ? -1.0f : 1.0f);
			for (int k = 0; k < man.pointCount && written < capacity; ++k) {
				const b3ManifoldPoint& mp = man.points[k];
				// Speculative points (not yet touching, no push) don't count.
				if (mp.separation > 0.005f && mp.totalNormalImpulse <= 0.0f) {
					continue;
				}
				ContactPoint& o = out[written++];
				o.other = b3StoreBodyId(other);
				o.other_kind = body_kind(o.other);
				o.point = center_a + from_b3(mp.anchorA);
				o.normal = normal;
				o.impulse = mp.totalNormalImpulse;
			}
		}
	}
	return written;
}

RayHit PhysicsWorld::cast_ray(Vec3 origin, Vec3 translation) const {
	RayHit h;
	const b3RayResult r = b3World_CastRayClosest(_impl->world, to_b3(origin), to_b3(translation), level_filter());
	if (r.hit) {
		h.hit = true;
		h.point = from_b3(r.point);
		h.normal = from_b3(r.normal);
		h.fraction = r.fraction;
		h.body = b3StoreBodyId(b3Shape_GetBody(r.shapeId));
	}
	return h;
}

namespace {
struct CastClosest {
	RayHit hit;
};
float cast_closest(b3ShapeId shape, b3Pos point, b3Vec3 normal, float fraction, uint64_t, int, int, void* context) {
	CastClosest* c = static_cast<CastClosest*>(context);
	if (!c->hit.hit || fraction < c->hit.fraction) {
		c->hit.hit = true;
		c->hit.point = from_b3(point);
		c->hit.normal = from_b3(normal);
		c->hit.fraction = fraction;
		c->hit.body = b3StoreBodyId(b3Shape_GetBody(shape));
	}
	return fraction;
}
} // namespace

RayHit PhysicsWorld::cast_sphere(Vec3 origin, float radius, Vec3 translation) const {
	const b3Vec3 zero = { 0.0f, 0.0f, 0.0f };
	b3ShapeProxy proxy = { &zero, 1, radius };
	CastClosest c;
	b3World_CastShape(_impl->world, to_b3(origin), &proxy, to_b3(translation), level_filter(), cast_closest, &c);
	return c.hit;
}

BodyKind PhysicsWorld::body_kind(BodyHandle body) const {
	switch (b3Body_GetType(body_id(body))) {
		case b3_staticBody:
			return BodyKind::Static;
		case b3_kinematicBody:
			return BodyKind::Kinematic;
		default:
			return BodyKind::Dynamic;
	}
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
