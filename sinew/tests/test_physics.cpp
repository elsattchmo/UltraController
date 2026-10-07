// Physics layer invariants. These are the guarantees the muscles and behaviours build on:
// bodies rest on the ground, joints hold together and inside their limits under hard
// shoves, and identical inputs give bit-identical runs.
#include "doctest.h"

#include "sinew/physics_world.hpp"
#include "sinew/version.hpp"

#include <cmath>
#include <string>

using namespace sinew;

namespace {

constexpr float DT = 1.0f / 60.0f;
constexpr float PI = 3.14159265f;

Transform at(float x, float y, float z) {
	return Transform{ Vec3{ x, y, z }, Quat{} };
}

float length(Vec3 v) {
	return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
}

Vec3 rotate(Quat q, Vec3 v) {
	// v + 2 q.xyz x (q.xyz x v + w v)
	Vec3 u{ q.x, q.y, q.z };
	Vec3 c1{ u.y * v.z - u.z * v.y + q.w * v.x, u.z * v.x - u.x * v.z + q.w * v.y, u.x * v.y - u.y * v.x + q.w * v.z };
	Vec3 c2{ u.y * c1.z - u.z * c1.y, u.z * c1.x - u.x * c1.z, u.x * c1.y - u.y * c1.x };
	return Vec3{ v.x + 2.0f * c2.x, v.y + 2.0f * c2.y, v.z + 2.0f * c2.z };
}

/// Ground: a static slab whose top is at y = 0.
void ground(PhysicsWorld& w) {
	w.add_static_box(at(0.0f, -0.5f, 0.0f), Vec3{ 20.0f, 0.5f, 20.0f });
}

/// A static anchor with a capsule "limb" hanging below it on a ball joint whose cone axis
/// points down (+Z of both frames turned onto -Y).
struct Pendulum {
	BodyHandle anchor, limb;
	JointHandle joint;
};

Pendulum pendulum(PhysicsWorld& w, float cone) {
	Pendulum p;
	p.anchor = w.add_static_box(at(0.0f, 3.0f, 0.0f), Vec3{ 0.1f, 0.1f, 0.1f });
	CapsuleDesc c;
	c.xform = at(0.0f, 2.9f, 0.0f);
	c.a = Vec3{ 0.0f, -0.05f, 0.0f };
	c.b = Vec3{ 0.0f, -0.40f, 0.0f };
	c.radius = 0.05f;
	p.limb = w.add_capsule_body(c);
	const float s = std::sqrt(0.5f);
	BallJointDesc j;
	j.parent = p.anchor;
	j.child = p.limb;
	j.frame_parent = Transform{ Vec3{ 0.0f, -0.1f, 0.0f }, Quat{ s, 0.0f, 0.0f, s } };
	j.frame_child = Transform{ Vec3{}, Quat{ s, 0.0f, 0.0f, s } };
	j.cone = cone;
	j.twist_min = -0.2f;
	j.twist_max = 0.2f;
	p.joint = w.add_ball_joint(j);
	return p;
}

} // namespace

TEST_CASE("version names sinew and its box3d commit") {
	std::string v = version_string();
	CHECK(v.find("sinew 0.1.0") == 0);
	CHECK(v.find("box3d") != std::string::npos);
}

TEST_CASE("a dropped capsule comes to rest lying on the ground") {
	PhysicsWorld w;
	ground(w);
	CapsuleDesc c;
	c.xform = at(0.0f, 1.0f, 0.0f);
	c.a = Vec3{ -0.2f, 0.0f, 0.0f };
	c.b = Vec3{ 0.2f, 0.0f, 0.0f };
	c.radius = 0.1f;
	BodyHandle body = w.add_capsule_body(c);
	for (int i = 0; i < 180; ++i) {
		w.step(DT);
	}
	Transform t = w.body_transform(body);
	CHECK(std::fabs(t.p.y - 0.1f) < 0.01f);
	CHECK(length(w.linear_velocity(body)) < 0.01f);
}

TEST_CASE("capsule mass is density times volume") {
	PhysicsWorld w;
	CapsuleDesc c;
	c.a = Vec3{ 0.0f, 0.0f, 0.0f };
	c.b = Vec3{ 0.0f, 0.4f, 0.0f };
	c.radius = 0.05f;
	c.density = 1000.0f;
	BodyHandle body = w.add_capsule_body(c);
	const float volume = PI * 0.05f * 0.05f * 0.4f + 4.0f / 3.0f * PI * 0.05f * 0.05f * 0.05f;
	CHECK(w.body_mass(body) == doctest::Approx(1000.0f * volume).epsilon(0.02));
}

/// Spin the limb about its pivot (a consistent swing: centre of mass moving with the spin).
void swing(PhysicsWorld& w, const Pendulum& p, Vec3 omega) {
	Vec3 com = w.center_of_mass(p.limb);
	Vec3 r{ com.x, com.y - 2.9f, com.z };
	w.set_angular_velocity(p.limb, omega);
	w.set_linear_velocity(p.limb, Vec3{ omega.y * r.z - omega.z * r.y, omega.z * r.x - omega.x * r.z,
			omega.x * r.y - omega.y * r.x });
}

struct Excursion {
	float cone = 0.0f;   ///< worst swing angle seen
	float gap = 0.0f;    ///< worst distance between the two joint anchors
};

Excursion shove(float spin) {
	PhysicsWorld w;
	Pendulum p = pendulum(w, 30.0f * PI / 180.0f);
	swing(w, p, Vec3{ spin / 3.0f, 0.0f, spin });
	Excursion e;
	for (int i = 0; i < 180; ++i) {
		w.step(DT);
		e.cone = std::fmax(e.cone, w.joint_cone_angle(p.joint));
		Transform t = w.body_transform(p.limb);
		e.gap = std::fmax(e.gap, length(Vec3{ t.p.x, t.p.y - 2.9f, t.p.z }));
	}
	return e;
}

TEST_CASE("a ball joint holds together and inside its cone when a limb is flung") {
	const float cone = 30.0f * PI / 180.0f;
	// 20 rad/s (~1150 deg/s): a limb flung by a shotgun blast or a hard fall.
	Excursion hard = shove(20.0f);
	INFO("hard: cone ", hard.cone * 180.0f / PI, " deg, gap ", hard.gap * 1000.0f, " mm");
	CHECK(hard.cone <= cone + 3.0f * PI / 180.0f);
	CHECK(hard.gap < 0.005f);
	// 34 rad/s (~2000 deg/s): beyond anything a body does; still no tearing.
	Excursion extreme = shove(34.0f);
	INFO("extreme: cone ", extreme.cone * 180.0f / PI, " deg, gap ", extreme.gap * 1000.0f, " mm");
	CHECK(extreme.cone <= cone + 6.0f * PI / 180.0f);
	CHECK(extreme.gap < 0.005f);
}

TEST_CASE("a flung limb settles back hanging inside its cone") {
	PhysicsWorld w;
	const float cone = 30.0f * PI / 180.0f;
	Pendulum p = pendulum(w, cone);
	swing(w, p, Vec3{ 0.0f, 0.0f, 20.0f });
	for (int i = 0; i < 600; ++i) {
		w.step(DT);
	}
	Vec3 down = rotate(w.body_transform(p.limb).q, Vec3{ 0.0f, -1.0f, 0.0f });
	CHECK(down.y < -std::cos(cone));
}

TEST_CASE("identical runs are bit-identical; a different push is not") {
	auto run = [](float push) {
		PhysicsWorld w;
		ground(w);
		Pendulum p = pendulum(w, 0.8f);
		swing(w, p, Vec3{ 0.0f, 0.0f, push });
		for (int k = 0; k < 4; ++k) {
			CapsuleDesc c;
			c.xform = at(0.3f * k, 1.0f + 0.5f * k, 0.1f * k);
			c.a = Vec3{ -0.2f, 0.0f, 0.0f };
			c.b = Vec3{ 0.2f, 0.0f, 0.0f };
			c.radius = 0.1f;
			w.add_capsule_body(c);
		}
		for (int i = 0; i < 240; ++i) {
			w.step(DT);
		}
		return w.state_hash();
	};
	CHECK(run(5.0f) == run(5.0f));
	CHECK(run(5.0f) != run(5.001f));
}

TEST_CASE("world mirror: bodies land on hull, mesh and kinematic shapes") {
	PhysicsWorld w;
	// A static mesh floor (two triangles, Godot's clockwise front faces seen from above).
	const Vec3 verts[] = { { -5, 0, -5 }, { 5, 0, -5 }, { 5, 0, 5 }, { -5, 0, 5 } };
	const int cw[] = { 0, 1, 2, 0, 2, 3 };
	BodyHandle floor = w.add_body(BodyKind::Static, Transform{});
	REQUIRE(w.add_mesh_shape(floor, verts, 4, cw, 2, true));
	// A static convex wedge at x = 3 and a kinematic box at x = -3.
	BodyHandle rock = w.add_body(BodyKind::Static, at(3, 0, 0));
	const Vec3 wedge[] = { { -0.5f, 0, -0.5f }, { 0.5f, 0, -0.5f }, { -0.5f, 0, 0.5f }, { 0.5f, 0, 0.5f }, { -0.5f, 0.4f, -0.5f },
		{ -0.5f, 0.4f, 0.5f } };
	REQUIRE(w.add_hull_shape(rock, wedge, 6));
	BodyHandle lift = w.add_body(BodyKind::Kinematic, at(-3, 0.25f, 0));
	w.add_box_shape(lift, Transform{}, Vec3{ 0.5f, 0.25f, 0.5f });
	auto drop = [&](float x) {
		CapsuleDesc c;
		c.xform = at(x, 1.5f, 0);
		c.a = Vec3{ -0.1f, 0, 0 };
		c.b = Vec3{ 0.1f, 0, 0 };
		c.radius = 0.05f;
		return w.add_capsule_body(c);
	};
	BodyHandle on_floor = drop(0.0f), on_lift = drop(-3.0f), on_rock = drop(2.7f);
	for (int i = 0; i < 120; ++i) {
		w.move_kinematic(lift, at(-3, 0.25f + 0.5f * float(i) / 120.0f, 0), DT);
		w.step(DT);
	}
	CHECK(std::fabs(w.body_transform(on_floor).p.y - 0.05f) < 0.01f);
	CHECK(w.body_transform(on_lift).p.y > 0.95f);       // riding the lift up to its top at 1.0 m
	CHECK(w.body_transform(on_rock).p.y > 0.06f);       // on the wedge's slope, not the floor
}
