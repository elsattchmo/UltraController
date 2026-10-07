// Limb awareness and perception: limbs found on the rig, hands reaching points, feet placed,
// the head looking, the spine leaning (all through the muscles), contacts, and the probes.
#include "doctest.h"

#include "sinew/limbs.hpp"
#include "sinew/math.hpp"

#include <cmath>
#include <functional>
#include <memory>

using namespace sinew;

namespace {

constexpr float DT = 1.0f / 60.0f;

std::shared_ptr<const Rig> humanoid() {
	static std::shared_ptr<const Rig> rig = std::make_shared<Rig>(build_humanoid_rig(make_test_skeleton()));
	return rig;
}

Transform at(float x, float y, float z) {
	return Transform{ Vec3{ x, y, z }, Quat{} };
}

/// A body hung from a kinematic pelvis (no balance needed), ticked with `each` before every step.
void run(PhysicsWorld& w, Character& c, int ticks, const std::function<void()>& each) {
	for (int i = 0; i < ticks; ++i) {
		each();
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
}

} // namespace

TEST_CASE("limbs: arms, legs, spine and neck found on the humanoid rig") {
	const Rig& rig = *humanoid();
	Limbs limbs(rig);
	for (int i = 0; i < int(LimbId::Count); ++i) {
		CHECK(limbs.limb(LimbId(i)).present());
	}
	CHECK(limbs.limb(LimbId::ArmL).parts.size() == 4);
	CHECK(limbs.limb(LimbId::LegR).parts.size() == 3);
	CHECK(limbs.limb(LimbId::Spine).parts.size() == 3);
	CHECK(limbs.limb(LimbId::ArmL).upper == rig.find("LeftUpperArm"));
	PhysicsWorld w;
	Character c(w, humanoid(), at(0, 0, 0), 1);
	const LimbState arm = limbs.state(c, LimbId::ArmL);
	CHECK(arm.attached);
	CHECK(arm.health == doctest::Approx(1.0f));
	// Test skeleton: shoulder at 0.11 x 1.8, hand centre at 0.442 + a bit: ~0.66 m of arm.
	CHECK(arm.reach == doctest::Approx(0.66f).epsilon(0.1));
	CHECK(arm.end_position.x > 0.75f);   // the left hand, out at the side
	c.sever(rig.find("LeftLowerArm"));
	CHECK_FALSE(limbs.state(c, LimbId::ArmL).attached);
	CHECK(limbs.state(c, LimbId::ArmL).health == 0.0f);
	CHECK_FALSE(limbs.reach(c, LimbId::ArmL, Vec3{ 0, 1.4f, 0.5f }));
}

TEST_CASE("reach: a hand goes to a point in front of the chest, inside its joint ranges") {
	PhysicsWorld w;
	Character c(w, humanoid(), at(0, 0.2f, 0), 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	Limbs limbs(c.rig());
	const Vec3 chest = c.part_transform(c.rig().find("UpperChest")).p;
	for (const Vec3 off : { Vec3{ 0.15f, 0.0f, 0.4f }, Vec3{ 0.3f, -0.3f, 0.3f }, Vec3{ 0.0f, 0.1f, 0.35f } }) {
		const Vec3 goal = chest + off;
		float worst_limit = 0.0f;
		run(w, c, 120, [&] {
			limbs.reach(c, LimbId::ArmL, goal);
			worst_limit = std::fmax(worst_limit, c.worst_limit_excess());
		});
		const float miss = length(limbs.end_position(c, LimbId::ArmL) - goal);
		INFO("goal offset ", off.x, " ", off.y, " ", off.z, ": hand ", miss * 100.0f, " cm off, limit excess ", worst_limit / DEG, " deg");
		CHECK(miss < 0.03f);
		CHECK(worst_limit < 2.0f * DEG);
	}
	// The other arm kept its T-pose.
	const Vec3 right = limbs.end_position(c, LimbId::ArmR);
	CHECK(right.x < -0.75f);
}

TEST_CASE("reach: out of range stretches toward it; half weight lands between") {
	PhysicsWorld w;
	Character c(w, humanoid(), at(0, 0.2f, 0), 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	Limbs limbs(c.rig());
	const Vec3 chest = c.part_transform(c.rig().find("UpperChest")).p;
	const Vec3 far = chest + Vec3{ 0.1f, 0.0f, 2.0f };
	run(w, c, 120, [&] { limbs.reach(c, LimbId::ArmR, far); });
	const Vec3 hand = limbs.end_position(c, LimbId::ArmR);
	CHECK(hand.z > 0.45f);   // stretched straight out in front
	// Half weight: between the T-pose hand and the goal.
	PhysicsWorld w2;
	Character c2(w2, humanoid(), at(0, 0.2f, 0), 1);
	w2.set_body_kind(c2.body(0), BodyKind::Kinematic);
	const Vec3 rest_hand = limbs.end_position(c2, LimbId::ArmR);
	const Vec3 goal = chest + Vec3{ -0.15f, 0.0f, 0.4f };
	run(w2, c2, 120, [&] { limbs.reach(c2, LimbId::ArmR, goal, 0.5f); });
	const Vec3 half = limbs.end_position(c2, LimbId::ArmR);
	CHECK(length(half - goal) > 0.08f);
	CHECK(length(half - rest_hand) > 0.08f);
}

TEST_CASE("place_foot: the ankle goes where it's put, the foot keeps its orientation") {
	PhysicsWorld w;
	Character c(w, humanoid(), at(0, 0.5f, 0), 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	Limbs limbs(c.rig());
	const int foot = c.rig().find("LeftFoot");
	const Vec3 ankle0 = c.part_transform(foot).p;
	const Vec3 goal = ankle0 + Vec3{ 0.0f, 0.25f, 0.3f };   // a step up and forward
	run(w, c, 120, [&] { limbs.place_foot(c, LimbId::LegL, goal); });
	const float miss = length(c.part_transform(foot).p - goal);
	const float tilt = angle_between(c.part_transform(foot).q, (at(0, 0.5f, 0) * c.rig().parts[size_t(foot)].rest).q);
	INFO("ankle ", miss * 100.0f, " cm off, foot turned ", tilt / DEG, " deg");
	CHECK(miss < 0.03f);
	CHECK(tilt < 10.0f * DEG);
	CHECK(c.worst_limit_excess() < 2.0f * DEG);
}

TEST_CASE("look: the head turns toward a point; lean tips the spine") {
	PhysicsWorld w;
	const Transform root = at(0, 0.2f, 0);
	Character c(w, humanoid(), root, 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	Limbs limbs(c.rig());
	const int head = c.rig().find("Neck");
	const Vec3 eye = c.part_transform(head).p;
	const Vec3 target = eye + Vec3{ 1.0f, 0.3f, 1.0f };   // up and to the left
	run(w, c, 90, [&] { limbs.look(c, target); });
	const Vec3 fwd = rotate(c.part_transform(head).q, rotate(conj(c.rig().parts[size_t(head)].rest.q), Vec3{ 0, 0, 1 }));
	const Vec3 want = normalized(target - eye);
	const float off = std::acos(std::fmin(1.0f, dot(fwd, want)));
	INFO("head ", off / DEG, " deg off the look");
	CHECK(off < 8.0f * DEG);

	PhysicsWorld w2;
	Character c2(w2, humanoid(), root, 1);
	w2.set_body_kind(c2.body(0), BodyKind::Kinematic);
	const int chest = c2.rig().find("UpperChest");
	run(w2, c2, 90, [&] { limbs.lean(c2, 0.4f, 0.0f); });
	const Vec3 up = rotate(c2.part_transform(chest).q, rotate(conj(c2.rig().parts[size_t(chest)].rest.q), Vec3{ 0, 1, 0 }));
	const float pitch = std::atan2(up.z, up.y);
	INFO("upper chest pitched ", pitch / DEG, " deg");
	CHECK(pitch == doctest::Approx(0.4f).epsilon(0.25));
	CHECK(std::fabs(up.x) < 0.08f);
}

TEST_CASE("contacts: standing feet touch the ground, hands don't; the floor isn't the body") {
	PhysicsWorld w;
	w.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 50, 0.5f, 50 });
	const Transform root = at(0, 0.0f, 0);
	Character c(w, humanoid(), root, 1);
	const Transform pelvis = root * c.rig().parts[0].rest;
	Limbs limbs(c.rig());
	run(w, c, 60, [&] { c.set_root_assist(pelvis, 1.0f, DT); });
	const LimbState leg = limbs.state(c, LimbId::LegL);
	CHECK(leg.end_contact);
	CHECK(limbs.state(c, LimbId::LegR).end_contact);
	CHECK_FALSE(limbs.state(c, LimbId::ArmL).contact);
	CHECK_FALSE(limbs.state(c, LimbId::Neck).contact);
	ContactPoint pts[8];
	const int n = c.part_contacts(c.rig().find("LeftFoot"), pts, 8);
	REQUIRE(n > 0);
	CHECK(pts[0].other_kind == BodyKind::Static);
	CHECK(pts[0].normal.y > 0.9f);   // pushing the foot up
	CHECK(std::fabs(pts[0].point.y) < 0.03f);
}

TEST_CASE("probes: ground, edges, walls, time to impact - the body itself is never hit") {
	PhysicsWorld w;
	w.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 50, 0.5f, 50 });
	w.add_static_box(Transform{ Vec3{ 0, 0.5f, 0 }, Quat{} }, Vec3{ 1, 0.5f, 1 });       // a 1 m block, top at y 1
	w.add_static_box(Transform{ Vec3{ -5, 1.0f, 0 }, Quat{} }, Vec3{ 0.1f, 1.0f, 2 });   // a wall at x -4.9
	Character c(w, humanoid(), at(0, 1.0f, 0), 1);   // standing on the block

	const RayHit g = probes::ground_below(w, Vec3{ 0, 2.2f, 0 });
	REQUIRE(g.hit);
	CHECK(g.point.y == doctest::Approx(1.0f).epsilon(0.01));   // through the body to the block's top
	CHECK(c.part_of(g.body) < 0);

	const EdgeProbe e = probes::edge_ahead(w, Vec3{ 0, 1.0f, 0 }, Vec3{ 1, 0, 0 });
	REQUIRE(e.found);
	CHECK(e.distance == doctest::Approx(1.0f).epsilon(0.08));
	CHECK(e.drop == doctest::Approx(1.0f).epsilon(0.05));
	CHECK_FALSE(probes::edge_ahead(w, Vec3{ 3, 0.0f, 0 }, Vec3{ 0, 0, 1 }).found);   // open floor

	const RayHit wall = probes::wall_within(w, Vec3{ -4, 1.0f, 0 }, Vec3{ -1, 0, 0 }, 1.5f);
	REQUIRE(wall.hit);
	CHECK(wall.point.x == doctest::Approx(-4.9f).epsilon(0.02));
	CHECK_FALSE(probes::wall_within(w, Vec3{ -4, 1.0f, 0 }, Vec3{ 1, 0, 0 }, 1.5f).hit);

	const float eta = probes::impact_eta(w, Vec3{ 10, 5.0f, 0 }, Vec3{});
	CHECK(eta == doctest::Approx(std::sqrt(2.0f * 5.0f / 9.81f)).epsilon(0.03));
	CHECK(probes::impact_eta(w, Vec3{ 10, 5.0f, 0 }, Vec3{ 0, 30, 0 }, 1.0f) < 0.0f);   // still going up
}
