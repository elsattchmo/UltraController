#include "sinew.h"

#include "sinew/physics_world.hpp"
#include "sinew/version.hpp"

struct sinew_world {
	sinew::PhysicsWorld physics;
	explicit sinew_world(const sinew::WorldSettings& s) :
			physics(s) {}
};

namespace {
sinew::Vec3 v(sinew_vec3 a) { return { a.x, a.y, a.z }; }
sinew::Transform t(sinew_xform x) { return { v(x.p), { x.q.x, x.q.y, x.q.z, x.q.w } }; }
} // namespace

const char* sinew_version(void) {
	return sinew::version_string();
}

sinew_world* sinew_world_create(sinew_vec3 gravity, int substeps) {
	sinew::WorldSettings s;
	s.gravity = v(gravity);
	s.substeps = substeps;
	return new sinew_world(s);
}

void sinew_world_destroy(sinew_world* world) {
	delete world;
}

void sinew_world_step(sinew_world* world, float dt) {
	world->physics.step(dt);
}

uint64_t sinew_world_add_static_box(sinew_world* world, sinew_xform xform, sinew_vec3 half_extents) {
	return world->physics.add_static_box(t(xform), v(half_extents));
}

uint64_t sinew_world_add_capsule(sinew_world* world, sinew_xform xform, sinew_vec3 a, sinew_vec3 b, float radius,
		float density) {
	sinew::CapsuleDesc d;
	d.xform = t(xform);
	d.a = v(a);
	d.b = v(b);
	d.radius = radius;
	d.density = density;
	return world->physics.add_capsule_body(d);
}

sinew_xform sinew_body_transform(const sinew_world* world, uint64_t body) {
	sinew::Transform x = world->physics.body_transform(body);
	return { { x.p.x, x.p.y, x.p.z }, { x.q.x, x.q.y, x.q.z, x.q.w } };
}
