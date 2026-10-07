// Procedural gait: footsteps from the motion, planted feet that never slide, stopping, running
// (a flight phase), turning on the spot, stairs, legs fitted to the footholds.
#include "doctest.h"

#include "sinew/gait.hpp"
#include "sinew/math.hpp"

#include <cmath>
#include <memory>

using namespace sinew;

namespace {

constexpr float DT = 1.0f / 60.0f;

struct Walker {
	std::shared_ptr<Rig> rig = std::make_shared<Rig>(build_humanoid_rig(make_test_skeleton()));
	PhysicsWorld world;
	std::unique_ptr<Limbs> limbs;
	std::unique_ptr<Gait> gait;
	Transform root;
	int landings[2] = { 0, 0 };
	float worst_slide = 0.0f;       // a planted foot's movement between two ticks
	float worst_reach = 0.0f;       // drawn ankle vs the foothold
	bool flight = false;
	bool was_planted[2] = { true, true };
	Vec3 last[2];

	explicit Walker(bool floor = true) {
		if (floor) {
			world.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 100, 0.5f, 100 });
		}
		limbs = std::make_unique<Limbs>(*rig);
		gait = std::make_unique<Gait>(*rig, *limbs, &world);
		gait->reset(root);
		for (int i = 0; i < 2; ++i) {
			last[i] = gait->ankle(i);
		}
	}
	/// Move the root at `v` for `seconds` (turning at `yaw_rate`), following the ground height.
	void run(Vec3 v, float seconds, float yaw_rate = 0.0f) {
		const int n = int(seconds / DT + 0.5f);
		for (int k = 0; k < n; ++k) {
			root.p += v * DT;
			root.q = normalized(axis_angle(Vec3{ 0, 1, 0 }, yaw_rate * DT) * root.q);
			const RayHit g = probes::ground_below(world, root.p + Vec3{ 0, 1.0f, 0 }, 3.0f);
			if (g.hit) {
				root.p.y = g.point.y;
			}
			gait->update(GaitInput{ root, v, DT });
			bool both_air = true;
			for (int i = 0; i < 2; ++i) {
				const bool planted = gait->foot_planted(i);
				if (planted && was_planted[i]) {
					worst_slide = std::fmax(worst_slide, length(gait->plant(i) - last[i]));
				}
				if (planted && !was_planted[i]) {
					landings[i]++;
				}
				both_air = both_air && !planted;
				was_planted[i] = planted;
				last[i] = gait->plant(i);
				const int foot = limbs->limb(i == 0 ? LimbId::LegL : LimbId::LegR).end;
				worst_reach = std::fmax(worst_reach, length(gait->pose()[size_t(foot)].p - gait->ankle(i)));
			}
			flight = flight || both_air;
		}
	}
	float off_home(int i) const {
		Vec3 d = gait->ankle(i) - gait->home(i);
		d.y = 0.0f;
		return length(d);
	}
};

} // namespace

TEST_CASE("gait: standing still - feet at home, no stepping") {
	Walker w;
	w.run(Vec3{}, 1.0f);
	CHECK_FALSE(w.gait->stepping());
	for (int i = 0; i < 2; ++i) {
		CHECK(w.off_home(i) < 0.01f);
		CHECK(w.gait->foot_planted(i));
	}
	CHECK(w.landings[0] + w.landings[1] == 0);
	// The drawn pose stands: pelvis at its height, feet at the ankles.
	CHECK(w.gait->pose()[0].p.y == doctest::Approx(w.rig->parts[0].rest.p.y).epsilon(0.05));
	CHECK(w.worst_reach < 0.01f);
}

TEST_CASE("gait: walking - alternating steps, planted feet never slide, legs reach the footholds") {
	Walker w;
	w.run(Vec3{ 0, 0, 1.4f }, 6.0f);
	const int steps = w.landings[0] + w.landings[1];
	MESSAGE("walk 1.4 m/s, 6 s: ", steps, " steps (cadence ", w.gait->cadence(), "/s), worst planted slide ",
			w.worst_slide * 1000.0f, " mm, worst ankle miss ", w.worst_reach * 100.0f, " cm");
	CHECK(steps >= 10);
	CHECK(steps <= 18);
	CHECK(std::abs(w.landings[0] - w.landings[1]) <= 1);   // they take turns
	CHECK(w.worst_slide < 1e-4f);                             // by construction
	CHECK(w.worst_reach < 0.02f);
	CHECK_FALSE(w.flight);                                    // a walk always has a foot down
	// Keeping up: neither foot left behind.
	for (int i = 0; i < 2; ++i) {
		Vec3 d = w.gait->ankle(i) - w.root.p;
		d.y = 0.0f;
		CHECK(length(d) < 0.8f);
	}
	// The left foot stays on the left (+X for a body facing +Z).
	CHECK(w.gait->ankle(0).x > w.gait->ankle(1).x);
}

TEST_CASE("gait: stopping brings the feet home and stands") {
	Walker w;
	w.run(Vec3{ 0, 0, 1.4f }, 3.0f);
	w.run(Vec3{}, 2.0f);
	CHECK_FALSE(w.gait->stepping());
	CHECK(w.off_home(0) < 0.1f);
	CHECK(w.off_home(1) < 0.1f);
	CHECK(w.worst_slide < 1e-4f);
}

TEST_CASE("gait: running has a flight phase and keeps up") {
	Walker w;
	w.run(Vec3{ 0, 0, 4.5f }, 4.0f);
	const int steps = w.landings[0] + w.landings[1];
	MESSAGE("run 4.5 m/s, 4 s: ", steps, " steps, duty ", w.gait->duty());
	CHECK(w.flight);
	CHECK(w.worst_slide < 1e-4f);
	CHECK(steps >= 8);
	for (int i = 0; i < 2; ++i) {
		Vec3 d = w.gait->ankle(i) - w.root.p;
		d.y = 0.0f;
		CHECK(length(d) < 1.4f);
	}
}

TEST_CASE("gait: turning on the spot steps round") {
	Walker w;
	w.run(Vec3{}, 0.5f);
	w.run(Vec3{}, 1.0f, PI / 2.0f);          // a quarter turn in a second, standing
	CHECK(w.gait->stepping());
	w.run(Vec3{}, 1.5f);
	CHECK(w.landings[0] + w.landings[1] >= 2);   // both feet stepped round
	CHECK_FALSE(w.gait->stepping());
	CHECK(w.worst_slide < 1e-4f);
	CHECK(w.off_home(0) < 0.1f);
	CHECK(w.off_home(1) < 0.1f);
}

TEST_CASE("gait: stairs - every foothold on a step") {
	Walker w;
	// Ten 0.17 m steps, 0.3 m deep, starting 1 m ahead (+Z).
	for (int k = 0; k < 10; ++k) {
		const float top = 0.17f * float(k + 1);
		w.world.add_static_box(Transform{ Vec3{ 0, top * 0.5f, 1.0f + 0.3f * float(k) + 0.15f + 3.0f }, Quat{} },
				Vec3{ 2.0f, top * 0.5f, 3.15f });
	}
	const float ankle_h = w.gait->plant(0).y;     // on the flat floor at y 0
	float worst = 0.0f;
	for (int t = 0; t < 360; ++t) {
		w.run(Vec3{ 0, 0, 0.9f }, DT);
		for (int i = 0; i < 2; ++i) {
			if (w.gait->foot_planted(i)) {
				const Vec3 a = w.gait->plant(i);
				const RayHit g = probes::ground_below(w.world, a + Vec3{ 0, 0.3f, 0 }, 1.0f);
				REQUIRE(g.hit);
				worst = std::fmax(worst, std::fabs(a.y - g.point.y - ankle_h));   // put down flat on the step under it
			}
		}
	}
	MESSAGE("stairs: climbed to ", w.root.p.y, " m, worst planted ankle off its step height ", worst * 100.0f, " cm");
	CHECK(w.root.p.y > 1.0f);
	CHECK(worst < 0.03f);
	CHECK(w.worst_slide < 1e-4f);
	CHECK(w.worst_reach < 0.03f);
}
