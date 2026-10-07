// Balance with physical legs: standing on its own feet (no root assist), taking pushes with
// the ankles / hips or a step, falling when it can't.
#include "doctest.h"

#include "sinew/balance.hpp"
#include "sinew/math.hpp"

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

struct Stand {
	PhysicsWorld w;
	std::unique_ptr<Character> c;
	std::unique_ptr<Limbs> limbs;
	std::unique_ptr<Balancer> bal;
	float stand_height = 0.0f;

	Stand() {
		w.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 50, 0.5f, 50 });
		c = std::make_unique<Character>(w, humanoid(), Transform{ Vec3{ 0, 0.005f, 0 }, Quat{} }, 1);
		limbs = std::make_unique<Limbs>(c->rig());
		bal = std::make_unique<Balancer>(*c, *limbs);
		// A relaxed standing pose: arms down a little (not the T), knees soft.
		c->set_stiffness(1.0f);
		stand_height = c->center_of_mass().y;
	}
	void tick(int n) {
		for (int i = 0; i < n; ++i) {
			bal->pre_step(DT);
			c->pre_step(DT);
			w.step(DT);
			c->post_step();
		}
	}
	void push(float ns, Vec3 dir) {
		const int chest = c->rig().find("Chest");
		w.apply_linear_impulse(c->body(chest), normalized(dir) * ns, c->part_transform(chest).p);
	}
	Vec3 settled;
	/// After the first second: it leans its weight over the middle of its soles.
	void settle() {
		tick(60);
		settled = c->part_transform(0).p;
	}
	float drift() const {
		const Vec3 p = c->part_transform(0).p - settled;
		return std::sqrt(p.x * p.x + p.z * p.z);
	}
};

} // namespace

TEST_CASE("hull: support polygon and distance") {
	const Vec3 up{ 0, 1, 0 };
	std::vector<Vec3> pts = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 1 }, { 0, 0, 1 }, { 0.5f, 0, 0.5f } };
	const std::vector<Vec3> h = ground_hull(pts, up);
	CHECK(h.size() == 4);
	CHECK(hull_distance(h, Vec3{ 0.5f, 3, 0.5f }, up) == doctest::Approx(-0.5f));
	CHECK(hull_distance(h, Vec3{ 2.0f, 0, 0.5f }, up) == doctest::Approx(1.0f));
}

TEST_CASE("balance: stands on its own legs for 10 s") {
	Stand s;
	s.settle();
	s.tick(540);
	INFO("fallen ", s.bal->fallen(), " (", std::string(s.bal->fall_reason()), "), steps ", s.bal->steps(), ", COM ", s.c->center_of_mass().y,
			" (was ", s.stand_height, "), pelvis drift ", s.drift(), " m, capture error ", s.bal->capture_error());
	CHECK_FALSE(s.bal->fallen());
	CHECK(s.c->center_of_mass().y > s.stand_height - 0.06f);
	CHECK(s.drift() < 0.08f);
	CHECK(s.bal->steps() == 0);
}

TEST_CASE("balance: a 30 N s push is taken on the ankles and hips") {
	for (const Vec3 dir : { Vec3{ 0, 0, 1 }, Vec3{ 0, 0, -1 }, Vec3{ 1, 0, 0 } }) {
		Stand s;
		s.settle();
		s.push(30.0f, dir);
		s.tick(240);
		INFO("push ", dir.x, " ", dir.z, ": fallen ", s.bal->fallen(), " (", std::string(s.bal->fall_reason()), "), steps ", s.bal->steps(), ", moved ", s.drift());
		CHECK_FALSE(s.bal->fallen());
		if (dir.x == 0.0f) {   // front / back: the feet are long enough (sideways it may step)
			CHECK(s.bal->steps() == 0);
			CHECK(s.drift() < 0.3f);   // (the feet slide a little: S6 work)
		}
	}
}

TEST_CASE("balance: harder pushes are stepped out of") {
	for (const float ns : { 60.0f, 100.0f }) {
		Stand s;
		s.settle();
		s.push(ns, Vec3{ 0, 0, 1 });
		s.tick(240);
		MESSAGE(ns, " N s push: ", s.bal->steps(), " steps, fallen ", s.bal->fallen(), " (", std::string(s.bal->fall_reason()), "), moved ", s.drift(), " m");
		CHECK_FALSE(s.bal->fallen());
		CHECK(s.bal->steps() >= 1);
		CHECK(s.c->worst_joint_gap() < 0.01f);
	}
}

TEST_CASE("balance: a huge shove can't be stepped out of - it falls") {
	Stand s;
	s.settle();
	s.push(250.0f, Vec3{ 0, 0, 1 });
	bool fell = false;
	for (int i = 0; i < 180 && !fell; ++i) {
		s.tick(1);
		fell = s.bal->fallen();
	}
	MESSAGE("250 N s push: fell ", fell, " (", std::string(s.bal->fall_reason()), ") after ", s.bal->steps(), " steps");
	CHECK(fell);
}
