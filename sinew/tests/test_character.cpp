// The muscled body: a humanoid rig from a skeleton, a limp ragdoll that stays in one piece and
// inside its joint ranges, muscles that hold a pose against gravity (and give way when weak),
// severing, determinism and cost.
#include "doctest.h"

#include "sinew/character.hpp"
#include "sinew/math.hpp"

#include <chrono>
#include <cmath>
#include <memory>
#include <string>

using namespace sinew;

namespace {

constexpr float DT = 1.0f / 60.0f;

std::shared_ptr<const Rig> humanoid() {
	static std::shared_ptr<const Rig> rig = std::make_shared<Rig>(build_humanoid_rig(make_test_skeleton()));
	return rig;
}

void ground(PhysicsWorld& w) {
	w.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 50, 0.5f, 50 });
}

Transform at(float x, float y, float z) {
	return Transform{ Vec3{ x, y, z }, Quat{} };
}

/// Worst angle between each attached part's world rotation and its rest rotation (feet: only
/// when off the ground - standing, they settle flat on it, as they should).
float pose_error(const Character& c, const Transform& root, int skip = -1, bool feet = true) {
	float worst = 0.0f;
	for (int i = 0; i < c.part_count(); ++i) {
		if (i == skip || !c.attached(i) || (!feet && c.rig().parts[size_t(i)].name.find("Foot") != std::string::npos)) {
			continue;
		}
		worst = std::fmax(worst, angle_between(c.part_transform(i).q, (root * c.rig().parts[size_t(i)].rest).q));
	}
	return worst;
}

} // namespace

TEST_CASE("the humanoid rig: 19 parts, 75 kg, anatomical joints, rest inside every range") {
	const Rig& rig = *humanoid();
	CHECK(rig.parts.size() == 19);
	CHECK(rig.total_mass() == doctest::Approx(75.0f).epsilon(0.01));
	for (size_t i = 0; i < rig.parts.size(); ++i) {
		CHECK(rig.parts[i].parent < int(i));   // parents first
	}
	CHECK(rig.parts[size_t(rig.find("LeftLowerLeg"))].joint == JointKind::Hinge);
	CHECK(rig.parts[size_t(rig.find("RightLowerArm"))].joint == JointKind::Hinge);
	CHECK(rig.subtree(rig.find("LeftUpperArm")).size() == 3);
	PhysicsWorld w;
	Character c(w, humanoid(), at(0, 0, 0), 1);
	CHECK(c.worst_joint_gap() < 1e-4f);
	CHECK(c.worst_limit_excess() <= 0.0f);
}

TEST_CASE("knees and elbows flex the right way") {
	// Flex each hinge by 60 deg through its muscle with the rest held: the shin swings back,
	// the forearm forward.
	PhysicsWorld w(WorldSettings{ Vec3{ 0, 0, 0 } });   // no gravity: only the muscles act
	Character c(w, humanoid(), at(0, 0, 0), 1);
	const Rig& rig = c.rig();
	for (const char* name : { "LeftLowerLeg", "RightLowerArm" }) {
		const int part = rig.find(name);
		const PartDef& def = rig.parts[size_t(part)];
		const Quat rest_local = conj(rig.parts[size_t(def.parent)].rest.q) * def.rest.q;
		const Vec3 axis_parent = rotate(def.frame_parent.q, Vec3{ 0, 0, 1 });
		c.set_target_local(part, axis_angle(axis_parent, 60 * DEG) * rest_local);
	}
	for (int i = 0; i < 120; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	auto tip = [&](const char* name) {
		const int part = rig.find(name);
		const PartDef& def = rig.parts[size_t(part)];
		return xform(c.part_transform(part), def.b) - xform(c.part_transform(part), def.a);
	};
	CHECK(tip("LeftLowerLeg").z < -0.1f);    // shin swings back (the model faces +Z)
	CHECK(tip("RightLowerArm").z > 0.1f);    // forearm swings forward
}

TEST_CASE("a limp ragdoll dropped on the ground stays together and inside its joint ranges") {
	PhysicsWorld w;
	ground(w);
	Character c(w, humanoid(), Transform{ Vec3{ 0, 1.2f, 0 }, axis_angle(Vec3{ 1, 0, 0.3f }, 1.1f) }, 1);
	c.set_tone(0.0f);
	c.set_gravity_compensation(0.0f);
	for (int i = 0; i < c.part_count(); ++i) {
		w.set_linear_velocity(c.body(i), Vec3{ 2.0f, 0.0f, 1.0f });
	}
	float worst_gap = 0.0f, worst_limit = 0.0f;
	for (int i = 0; i < 300; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
		worst_gap = std::fmax(worst_gap, c.worst_joint_gap());
		worst_limit = std::fmax(worst_limit, c.worst_limit_excess());
	}
	INFO("worst gap ", worst_gap * 1000.0f, " mm, worst limit excess ", worst_limit / DEG, " deg");
	CHECK(worst_gap < 0.005f);
	// Box3D's limits are soft: an impact pushes a joint a few degrees past its range for a
	// few frames (measured 4.1 deg peak, ~7 frames), then it settles back inside.
	CHECK(worst_limit < 6.0f * DEG);
	CHECK(c.worst_limit_excess() < 1.0f * DEG);
	float speed = 0.0f;
	for (int i = 0; i < c.part_count(); ++i) {
		speed = std::fmax(speed, length(w.linear_velocity(c.body(i))));
		CHECK(c.part_transform(i).p.y > -0.02f);   // nothing through the floor
	}
	CHECK(speed < 0.1f);
	CHECK(c.center_of_mass().y < 0.35f);         // lying down
}

TEST_CASE("a body falling 8 m lands in one piece") {
	// Box3D's continuous collision stops each fast part at its own time of impact, which pulled
	// joints 14 cm apart; post_step puts them back on their anchors.
	PhysicsWorld w;
	ground(w);
	Character c(w, humanoid(), Transform{ Vec3{ 0, 8.0f, 0 }, axis_angle(Vec3{ 1, 0, 0.3f }, 1.1f) }, 1);
	c.set_tone(0.0f);
	c.set_gravity_compensation(0.0f);
	float worst_gap = 0.0f, lowest = 9.0f;
	for (int i = 0; i < 300; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
		worst_gap = std::fmax(worst_gap, c.worst_joint_gap());
		for (int k = 0; k < c.part_count(); ++k) {
			lowest = std::fmin(lowest, c.part_transform(k).p.y);
		}
	}
	INFO("worst gap ", worst_gap * 1000.0f, " mm, lowest part origin ", lowest, " m");
	CHECK(worst_gap < 0.005f);
	CHECK(lowest > -0.1f);           // a limb can dip into the floor for a frame, never through
	CHECK(c.center_of_mass().y < 0.35f);
}

TEST_CASE("muscles hold a T-pose against gravity with the pelvis held still") {
	PhysicsWorld w;
	const Transform root = at(0, 0.2f, 0);
	Character c(w, humanoid(), root, 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	for (int i = 0; i < 120; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	const float err = pose_error(c, root);
	INFO("worst part off its pose: ", err / DEG, " deg");
	CHECK(err < 5.0f * DEG);
}

TEST_CASE("gravity compensation lets soft muscles hold; weak muscles give way") {
	auto droop = [](float tone, float comp, float strength) {
		PhysicsWorld w;
		const Transform root = at(0, 0.2f, 0);
		auto rig = std::make_shared<Rig>(*humanoid());
		for (PartDef& p : rig->parts) {
			p.muscle.strength *= strength;
		}
		Character c(w, rig, root, 1);
		w.set_body_kind(c.body(0), BodyKind::Kinematic);
		c.set_tone(tone);
		c.set_gravity_compensation(comp);
		for (int i = 0; i < 120; ++i) {
			c.pre_step(DT);
			w.step(DT);
			c.post_step();
		}
		const int arm = c.rig().find("LeftUpperArm");
		return angle_between(c.part_transform(arm).q, (root * c.rig().parts[size_t(arm)].rest).q);
	};
	const float soft_uncomp = droop(0.15f, 0.0f, 1.0f);
	const float soft_comp = droop(0.15f, 1.0f, 1.0f);
	const float weak = droop(1.0f, 1.0f, 0.05f);   // shoulder 4 N m against ~10 N m of arm
	INFO("soft arm droops ", soft_uncomp / DEG, " deg without compensation, ", soft_comp / DEG, " with; weak ", weak / DEG);
	CHECK(soft_comp < 0.5f * soft_uncomp);
	CHECK(soft_comp < 8.0f * DEG);
	CHECK(weak > 45.0f * DEG);
}

TEST_CASE("a severed arm falls away; the rest keeps its pose") {
	PhysicsWorld w;
	ground(w);
	const Transform root = at(0, 0.3f, 0);
	Character c(w, humanoid(), root, 1);
	w.set_body_kind(c.body(0), BodyKind::Kinematic);
	for (int i = 0; i < 30; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	const float before = c.mass();
	const int arm = c.rig().find("LeftUpperArm");
	CHECK(c.sever(arm));
	CHECK_FALSE(c.sever(arm));
	CHECK_FALSE(c.attached(c.rig().find("LeftHand")));
	CHECK(c.mass() == doctest::Approx(before - 75.0f * (0.0271f + 0.0162f + 0.0061f)).epsilon(0.01));
	for (int i = 0; i < 120; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	CHECK(c.part_transform(arm).p.y < 0.25f);    // on the floor
	float worst = 0.0f;
	for (int i = 0; i < c.part_count(); ++i) {
		if (c.attached(i)) {
			worst = std::fmax(worst, angle_between(c.part_transform(i).q, (root * c.rig().parts[size_t(i)].rest).q));
		}
	}
	INFO("the rest: worst ", worst / DEG, " deg off");
	CHECK(worst < 5.0f * DEG);
}

TEST_CASE("characters simulate bit-identically") {
	auto run = [](float push) {
		PhysicsWorld w;
		ground(w);
		Character a(w, humanoid(), at(0, 0.05f, 0), 1);
		Character b(w, humanoid(), Transform{ Vec3{ 0.4f, 1.0f, 0.3f }, axis_angle(Vec3{ 0, 0, 1 }, 1.4f) }, 2);
		b.set_tone(0.2f);
		w.apply_linear_impulse(a.body(3), Vec3{ push, 0, 0 }, a.part_transform(3).p);
		for (int i = 0; i < 240; ++i) {
			a.pre_step(DT);
			b.pre_step(DT);
			w.step(DT);
			a.post_step();
			b.post_step();
		}
		return w.state_hash();
	};
	CHECK(run(40.0f) == run(40.0f));
	CHECK(run(40.0f) != run(41.0f));
}

TEST_CASE("cost: 30 muscled characters") {
	PhysicsWorld w;
	ground(w);
	std::vector<std::unique_ptr<Character>> crowd;
	for (int i = 0; i < 30; ++i) {
		crowd.push_back(std::make_unique<Character>(w, humanoid(), at(float(i % 6) * 1.2f, 0.05f, float(i / 6) * 1.2f), i + 1));
	}
	auto tick = [&] {
		for (auto& c : crowd) {
			c->pre_step(DT);
		}
		w.step(DT);
		for (auto& c : crowd) {
			c->post_step();
		}
	};
	for (int i = 0; i < 30; ++i) {
		tick();
	}
	const int steps = 240;
	const auto t0 = std::chrono::steady_clock::now();
	for (int i = 0; i < steps; ++i) {
		tick();
	}
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / steps;
	MESSAGE("30 characters: ", ms, " ms a tick (", ms / 30.0 * 1000.0, " us each, 8 substeps, 1 thread)");
	CHECK(ms / 30.0 < 0.5);   // generous for CI machines; the target is <= 0.15 ms each
}

TEST_CASE("powered: a standing body holds its pose on its feet, takes a shove and recovers") {
	PhysicsWorld w;
	ground(w);
	const Transform root = at(0, 0.0f, 0);
	Character c(w, humanoid(), root, 1);
	const Transform pelvis = root * c.rig().parts[0].rest;
	auto tick = [&](int n) {
		for (int i = 0; i < n; ++i) {
			c.set_root_assist(pelvis, 1.0f, DT);
			c.pre_step(DT);
			w.step(DT);
			c.post_step();
		}
	};
	tick(120);
	const float settled = pose_error(c, root, -1, false);
	const float drift = length(c.part_transform(0).p - pelvis.p);
	INFO("standing: worst part ", settled / DEG, " deg off, pelvis ", drift * 100.0f, " cm off");
	CHECK(settled < 6.0f * DEG);
	CHECK(drift < 0.03f);
	// A firm shove on the upper chest (40 N s): the body gives, then comes back.
	// (Much harder ones knock it into a pose the assist can't undo: falling is the balance
	// controller's and the behaviours' job, S5-S6.)
	const int chest = c.rig().find("UpperChest");
	w.apply_linear_impulse(c.body(chest), Vec3{ 0, 0, -40.0f }, c.part_transform(chest).p);
	float worst = 0.0f;
	for (int i = 0; i < 20; ++i) {
		tick(1);
		worst = std::fmax(worst, pose_error(c, root, -1, false));
	}
	tick(100);
	const float after = pose_error(c, root, -1, false);
	INFO("shoved: up to ", worst / DEG, " deg, ", after / DEG, " deg 2 s later");
	MESSAGE("shove: up to ", worst / DEG, " deg, ", after / DEG, " deg after");
	CHECK(worst > 10.0f * DEG);      // it really moved
	CHECK(after < 6.0f * DEG);       // and recovered
}

TEST_CASE("powered: the root follows a moving target (walking pace)") {
	PhysicsWorld w;   // no floor: the drive alone (rest-pose feet would drag along a floor)
	Character c(w, humanoid(), at(0, 0, 0), 1);
	const Transform rest = c.rig().parts[0].rest;
	float worst = 0.0f;
	for (int i = 0; i < 180; ++i) {
		const Transform target = at(0, 0, 1.4f * float(i) * DT) * rest;
		c.set_root_assist(target, 1.0f, DT);
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
		if (i > 60) {
			worst = std::fmax(worst, length(c.part_transform(0).p - target.p));
		}
	}
	INFO("pelvis lag at 1.4 m/s: ", worst * 100.0f, " cm");
	CHECK(worst < 0.05f);
}

TEST_CASE("releasing the root drive lets the body fall (no stale drive impulse)") {
	// Box3D warm-starts a switched-off motor-joint spring with its last impulse forever: a
	// released root drive kept holding the body's weight and it floated up.
	PhysicsWorld w;
	ground(w);
	Character c(w, humanoid(), at(0, 0, 0), 1);
	const Transform pelvis = c.rig().parts[0].rest;
	for (int i = 0; i < 60; ++i) {
		c.set_root_assist(pelvis, 1.0f, DT);
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	c.set_root_assist(pelvis, 0.0f, DT);
	c.set_tone(0.0f);
	for (int i = 0; i < 180; ++i) {
		c.pre_step(DT);
		w.step(DT);
		c.post_step();
	}
	CHECK(c.center_of_mass().y < 0.35f);
}
