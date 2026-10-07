// Procedural gait: footsteps from the motion, planted feet that never slide, stopping, running
// (a flight phase), turning on the spot, stairs, legs fitted to the footholds.
#include "doctest.h"

#include "sinew/gait.hpp"
#include "sinew/math.hpp"

#include <cmath>
#include <memory>
#include <string>

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
	Vec3 last[2], last_ball[2], last_heel[2];

	explicit Walker(bool floor = true) {
		if (floor) {
			world.add_static_box(Transform{ Vec3{ 0, -0.5f, 0 }, Quat{} }, Vec3{ 100, 0.5f, 100 });
		}
		limbs = std::make_unique<Limbs>(*rig);
		gait = std::make_unique<Gait>(*rig, *limbs, &world);
		gait->reset(root);
		for (int i = 0; i < 2; ++i) {
			last[i] = gait->ankle(i);
			last_ball[i] = gait->plant_ball(i);
			last_heel[i] = gait->plant_heel(i);
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
					// (A stance pivot turns the foot about its ball or heel: that point mustn't move.)
					const float m = std::fmin(length(gait->plant(i) - last[i]),
							std::fmin(length(gait->plant_ball(i) - last_ball[i]), length(gait->plant_heel(i) - last_heel[i])));
					worst_slide = std::fmax(worst_slide, m);
				}
				if (planted && !was_planted[i]) {
					landings[i]++;
				}
				both_air = both_air && !planted;
				was_planted[i] = planted;
				last[i] = gait->plant(i);
				last_ball[i] = gait->plant_ball(i);
				last_heel[i] = gait->plant_heel(i);
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

TEST_CASE("gait: ramps - planted soles lie on the slope as they do on the flat") {
	// (The rig's foot is one rigid box: up on the ball its toe end dips ~3.5 cm even on the flat - in the game
	// the toes bend. A slope must be no worse than that.)
	float flat_in = 0.0f, flat_lying = 0.0f;
	for (const float deg : { 0.0f, 15.0f, 25.0f }) {
		Walker w;
		// A slab rising toward +Z from z = 1 (its top through y 0 there).
		const float a = deg * 3.14159265f / 180.0f;
		const Quat q = axis_angle(Vec3{ 1, 0, 0 }, -a);
		const Vec3 dir{ 0, std::sin(a), std::cos(a) }, n = rotate(q, Vec3{ 0, 1, 0 });
		w.world.add_static_box(Transform{ Vec3{ 0, 0, 1 } + dir * 4.0f - n * 0.05f, q }, Vec3{ 2, 0.05f, 4 });
		const int foot[2] = { w.limbs->limb(LimbId::LegL).end, w.limbs->limb(LimbId::LegR).end };
		float worst_in = 0.0f;
		int lying = 0, checked = 0;
		for (int t = 0; t < 300; ++t) {
			w.run(Vec3{ 0, 0, 1.0f }, DT);
			for (int i = 0; i < 2; ++i) {
				const Vec3 an = w.gait->plant(i);
				if (!w.gait->foot_planted(i) || an.z < 1.6f || an.z > 7.0f) {
					continue;
				}
				const PartDef& d = w.rig->parts[size_t(foot[i])];
				const Transform& T = w.gait->pose()[size_t(foot[i])];
				float lo = 1e9f, hi = -1e9f;
				for (const float sx : { -1.0f, 1.0f }) {
					for (const float sz : { -1.0f, 1.0f }) {
						const Vec3 c = xform(T, xform(d.box_xform, Vec3{ sx * d.box_half.x, -d.box_half.y, sz * d.box_half.z }));
						const RayHit g = probes::ground_below(w.world, c + Vec3{ 0, 0.3f, 0 }, 1.0f);
						if (g.hit) {
							const float above = c.y - g.point.y;
							worst_in = std::fmax(worst_in, -above);
							lo = std::fmin(lo, above);
							hi = std::fmax(hi, above);
						}
					}
				}
				++checked;
				lying += hi < 0.03f ? 1 : 0;
			}
		}
		MESSAGE("ramp ", deg, " deg: worst sole corner inside ", worst_in * 100.0f, " cm, flat on it ", lying, " of ", checked, " planted frames");
		CHECK(checked > 50);
		if (deg == 0.0f) {
			flat_in = worst_in;
			flat_lying = float(lying) / float(checked);
			continue;
		}
		CHECK(worst_in < flat_in + 0.01f);                            // no deeper into the slope than the flat
		CHECK(float(lying) / float(checked) > 0.8f * flat_lying);     // the whole sole down on it as often
	}
}

TEST_CASE("gait: a small turn on the spot is a pivot, not a step") {
	Walker w;
	w.run(Vec3{}, 0.5f);
	w.run(Vec3{}, 0.5f, 40.0f * 3.14159265f / 180.0f / 0.5f);   // the body turns 40 deg
	w.run(Vec3{}, 1.0f);
	float turned = 0.0f;
	for (int i = 0; i < 2; ++i) {
		const Vec3 f = w.gait->plant_ball(i) - w.gait->plant(i);
		turned += 0.5f * std::atan2(f.x, f.z);
	}
	MESSAGE("turned 40 deg standing: ", w.landings[0] + w.landings[1], " steps, feet turned ", turned * 57.2958f, " deg, slide ",
			w.worst_slide * 1000.0f, " mm");
	CHECK(w.landings[0] + w.landings[1] == 0);
	CHECK(std::fabs(turned) > 0.5f);
	CHECK(w.worst_slide < 1e-4f);
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

namespace {

/// Walk at `v` (world) facing +Z and measure what 8-way movement gets wrong: feet crossing (in
/// the body frame), the pelvis sinking to reach a stretched foot, and the widest stance (lunges).
struct EightWay {
	float min_gap = 1e9f;       // left ankle's lateral lead over the right (+X is the left)
	float min_pelvis = 1e9f;    // pelvis height over the root
	float max_spread = 0.0f;    // horizontal distance between the ankles
};

/// The game's capsule: accelerates at 11 m/s2, brakes at 20 (fps.tres).
Vec3 ramp(Vec3 cur, Vec3 want) {
	const Vec3 d = want - cur;
	const float a = dot(d, cur) < 0.0f ? 20.0f : 11.0f;
	const float l = length(d);
	return l > a * DT ? cur + d * (a * DT / l) : want;
}

EightWay measure(Walker& w, Vec3& vel, Vec3 v, float seconds) {
	EightWay r;
	const int n = int(seconds / DT + 0.5f);
	for (int k = 0; k < n; ++k) {
		vel = ramp(vel, v);
		w.run(vel, DT);
		const Vec3 a = w.gait->ankle(0), b = w.gait->ankle(1);
		const float wp = w.gait->warp();      // the legs' frame: the facing (+Z) turned by the warp
		r.min_gap = std::fmin(r.min_gap, (a.x - b.x) * std::cos(wp) - (a.z - b.z) * std::sin(wp));
		r.min_pelvis = std::fmin(r.min_pelvis, w.gait->pose()[0].p.y - w.root.p.y);
		r.max_spread = std::fmax(r.max_spread, std::hypot(a.x - b.x, a.z - b.z));
	}
	return r;
}

} // namespace

TEST_CASE("gait: 8-way - strafing, backing and diagonals never cross the feet or lunge") {
	// Plain forward walking is the yardstick: no direction may sink the hips or straddle more.
	const float rest_h = Walker().rig->parts[0].rest.p.y;
	Walker base;
	Vec3 bv;
	const EightWay fwd = measure(base, bv, Vec3{ 0, 0, 1.4f }, 4.0f);
	const Vec3 dirs[] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, -1 }, { 0.7071f, 0, 0.7071f }, { -0.7071f, 0, -0.7071f },
		{ 0.7071f, 0, -0.7071f } };
	MESSAGE("forward: pelvis sank ", (rest_h - fwd.min_pelvis) * 100.0f, " cm, widest stance ", fwd.max_spread * 100.0f, " cm");
	for (const Vec3& d : dirs) {
		Walker w;
		Vec3 vel;
		const EightWay r = measure(w, vel, d * 1.4f, 4.0f);
		MESSAGE("dir (", d.x, ", ", d.z, "): min gap ", r.min_gap * 100.0f, " cm, pelvis sank ", (rest_h - r.min_pelvis) * 100.0f,
				" cm, widest stance ", r.max_spread * 100.0f, " cm, warp ", w.gait->warp());
		CHECK(r.min_gap > 0.08f);                           // never crossed (in the legs' frame)
		CHECK(r.min_pelvis >= fwd.min_pelvis - 0.02f);     // no slump
		// No lunge (a side-step is a longer stride: GaitSettings::step_side; a foot pivoting on its ball as the
		// legs warp toward a diagonal swings its ankle out a little more).
		CHECK(r.max_spread <= fwd.max_spread + 0.09f);
		CHECK(w.worst_slide < 1e-4f);
		CHECK(w.worst_reach < 0.02f);
	}
}

TEST_CASE("gait: reversing - forward to back, side to side, run to backing: no slump, no lunge") {
	const float rest_h = Walker().rig->parts[0].rest.p.y;
	struct Case {
		Vec3 a, b;
		float sink, spread;   // allowed: pelvis below rest / widest stance, m
	};
	const Case cases[] = { { { 0, 0, 1.4f }, { 0, 0, -1.4f }, 0.14f, 0.7f }, { { 1.4f, 0, 0 }, { -1.4f, 0, 0 }, 0.14f, 0.85f },
		{ { 0, 0, 3.5f }, { 0, 0, -1.4f }, 0.2f, 0.95f } };   // (braking from a run: a hard plant and a dip)
	for (const Case& c : cases) {
		Walker w;
		Vec3 vel;
		measure(w, vel, c.a, 2.0f);
		const EightWay r = measure(w, vel, c.b, 2.0f);
		MESSAGE("reverse (", c.a.x, ",", c.a.z, ") -> (", c.b.x, ",", c.b.z, "): min gap ", r.min_gap * 100.0f,
				" cm, pelvis sank ", (rest_h - r.min_pelvis) * 100.0f, " cm, widest ", r.max_spread * 100.0f, " cm");
		CHECK(r.min_gap > 0.08f);
		CHECK(rest_h - r.min_pelvis < c.sink);
		CHECK(r.max_spread < c.spread);
		CHECK(w.worst_slide < 1e-4f);
		// And it settles into the new direction: both feet near the hips again.
		for (int i = 0; i < 2; ++i) {
			Vec3 d = w.gait->ankle(i) - w.root.p;
			d.y = 0.0f;
			CHECK(length(d) < 0.6f);
		}
	}
}

TEST_CASE("gait: momentum - leans into a change of motion, bounded, nothing flies") {
	Walker w;
	Vec3 vel;
	const float cap = w.gait->settings().lean_max;
	// Fastest any part moves against the root, per tick (m/s): the yardstick is a steady walk.
	auto part_speed = [&](Vec3 v, float seconds, float& lean_min_z, float& lean_max_z, float& worst_lean) {
		std::vector<Transform> last = w.gait->pose();
		Vec3 last_root = w.root.p;
		float fastest = 0.0f;
		const int n = int(seconds / DT + 0.5f);
		for (int k = 0; k < n; ++k) {
			vel = ramp(vel, v);
			w.run(vel, DT);
			const Vec3 dr = w.root.p - last_root;
			for (size_t i = 0; i < last.size(); ++i) {
				fastest = std::fmax(fastest, length(w.gait->pose()[i].p - last[i].p - dr) / DT);
			}
			last = w.gait->pose();
			last_root = w.root.p;
			const Vec3 l = w.gait->lean();
			lean_min_z = std::fmin(lean_min_z, l.z);
			lean_max_z = std::fmax(lean_max_z, l.z);
			worst_lean = std::fmax(worst_lean, length(l));
		}
		return fastest;
	};
	float lo = 0, hi = 0, worst = 0;
	part_speed(Vec3{ 0, 0, 1.4f }, 0.4f, lo, hi, worst);
	const float start_fwd = hi;                                    // setting off: leaned forward
	lo = hi = 0;
	const float steady = part_speed(Vec3{ 0, 0, 1.4f }, 2.0f, lo, hi, worst);
	const float settled = length(w.gait->lean());
	lo = hi = 0;
	const float reversing = part_speed(Vec3{ 0, 0, -1.4f }, 1.5f, lo, hi, worst);
	MESSAGE("lean: setting off ", start_fwd, " rad forward, settled ", settled, ", braking ", -lo, " rad back (cap ", cap,
			"); fastest part vs the root: walking ", steady, " m/s, reversing ", reversing, " m/s");
	CHECK(start_fwd > 0.08f);                 // setting off leans forward
	CHECK(lo < -0.08f);                       // the reversal's braking leans back
	CHECK(settled < 0.02f);                   // and a steady walk stands up straight
	CHECK(worst <= cap + 1e-4f);              // bounded
	CHECK(reversing < 1.5f * steady);         // nothing flies about
}

namespace {

/// The body moves by the gait's own drive (inverted pendulum over the planted soles): the root
/// is the centre of mass's ground point, its velocity whatever the feet allow toward `command`.
struct Driven {
	Walker w;
	Vec3 vel;
	float max_acc = 0.0f;
	int landings = 0;
	bool was[2] = { true, true };
	void run(Vec3 command, float seconds, std::vector<float>* speeds = nullptr) {
		const int n = int(seconds / DT + 0.5f);
		for (int k = 0; k < n; ++k) {
			const Vec3 nv = w.gait->drive(w.root.p, vel, command, DT);
			max_acc = std::fmax(max_acc, length(nv - vel) / DT);
			vel = nv;
			w.root.p += vel * DT;
			GaitInput in{ w.root, vel, DT };
			in.command = command;
			in.has_command = true;
			w.gait->update(in);
			for (int i = 0; i < 2; ++i) {
				const bool pl = w.gait->foot_planted(i);
				if (pl && was[i]) {
					// (A stance pivot turns the foot about its ball or heel: that point mustn't move.)
					w.worst_slide = std::fmax(w.worst_slide, std::fmin(length(w.gait->plant(i) - w.last[i]),
							std::fmin(length(w.gait->plant_ball(i) - w.last_ball[i]), length(w.gait->plant_heel(i) - w.last_heel[i]))));
				}
				landings += pl && !was[i] ? 1 : 0;
				was[i] = pl;
				w.last[i] = w.gait->plant(i);
				w.last_ball[i] = w.gait->plant_ball(i);
				w.last_heel[i] = w.gait->plant_heel(i);
			}
			if (speeds) {
				speeds->push_back(length(vel));
			}
		}
	}
};

} // namespace

TEST_CASE("gait drive: starting, walking and stopping take steps - momentum from the feet") {
	Driven d;
	std::vector<float> sp;
	d.run(Vec3{}, 0.5f);
	CHECK(length(d.vel) < 0.01f);                       // standing: still
	d.run(Vec3{ 0, 0, 1.4f }, 4.0f, &sp);
	int reach90 = -1;
	for (size_t i = 0; i < sp.size(); ++i) {
		if (sp[i] > 0.9f * 1.4f) {
			reach90 = int(i);
			break;
		}
	}
	float lo = 1e9f, hi = 0.0f;
	for (size_t i = sp.size() - 120; i < sp.size(); ++i) {
		lo = std::fmin(lo, sp[i]);
		hi = std::fmax(hi, sp[i]);
	}
	const float travelled = d.w.root.p.z;
	d.run(Vec3{}, 3.0f);
	const float stop_dist = d.w.root.p.z - travelled;
	MESSAGE("drive: 90% of 1.4 m/s after ", reach90 * DT, " s, steady walk ", lo, "..", hi, " m/s, stopped in ", stop_dist,
			" m, hardest push ", d.max_acc, " m/s2, slide ", d.w.worst_slide * 1000.0f, " mm");
	CHECK(reach90 > 0);
	CHECK(reach90 * DT > 0.3f);                         // not instant: the body has to be tipped into it
	CHECK(reach90 * DT < 1.6f);                         // ... in a step or two
	CHECK(lo > 1.2f);                                   // a walk's speed breathes, it doesn't stall
	CHECK(hi < 1.6f);
	CHECK(stop_dist > 0.1f);                            // momentum carries it on a little
	CHECK(stop_dist < 1.2f);
	CHECK(length(d.vel) < 0.05f);                       // and it comes to rest
	CHECK(d.max_acc <= 0.8f * 9.81f + 0.01f);           // never more than the feet can push
	CHECK(d.w.worst_slide < 1e-4f);
}

TEST_CASE("gait drive: reversing brakes over a planted foot, then goes - every direction") {
	const Vec3 dirs[] = { { 0, 0, 1 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, -1 }, { 0.7071f, 0, 0.7071f }, { -0.7071f, 0, -0.7071f } };
	for (const Vec3& dir : dirs) {
		Driven d;
		d.run(dir * 1.4f, 3.0f);
		std::vector<float> sp;
		const Vec3 before = d.w.root.p;
		d.run(dir * -1.4f, 3.0f, &sp);
		const float back = dot(d.w.root.p - before, dir);
		float settled = 0.0f;
		for (size_t i = sp.size() - 60; i < sp.size(); ++i) {
			settled += sp[i] / 60.0f;
		}
		MESSAGE("reverse along (", dir.x, ",", dir.z, "): net ", back, " m in 3 s, settled at ", settled, " m/s, hardest push ",
				d.max_acc, " m/s2, slide ", d.w.worst_slide * 1000.0f, " mm");
		CHECK(back < -2.0f);                             // it did turn round and go
		CHECK(settled > 1.25f);                          // at the speed asked for, whichever way
		CHECK(settled < 1.55f);
		CHECK(d.max_acc <= 0.8f * 9.81f + 0.01f);
		CHECK(d.w.worst_slide < 1e-4f);
	}
}

TEST_CASE("gait drive: a run brakes to a stop in a few steps") {
	Driven d;
	d.run(Vec3{ 0, 0, 3.5f }, 3.0f);
	const float at = d.w.root.p.z;
	const int steps0 = d.landings;
	std::vector<float> sp;
	d.run(Vec3{}, 3.0f, &sp);
	int stopped = 0;
	while (stopped < int(sp.size()) && sp[size_t(stopped)] > 0.1f) {
		++stopped;
	}
	MESSAGE("run 3.5 m/s -> stop: ", d.w.root.p.z - at, " m in ", stopped * DT, " s, ", d.landings - steps0, " steps, now ",
			length(d.vel), " m/s");
	CHECK(d.landings - steps0 >= 2);                    // braking takes steps
	CHECK(d.w.root.p.z - at > 0.5f);
	CHECK(d.w.root.p.z - at < 3.5f);
	CHECK(length(d.vel) < 0.05f);
	CHECK(d.w.worst_slide < 1e-4f);
}

TEST_CASE("gait drive: speeding up into a run keeps every foot within reach") {
	Driven d;
	const float rest_h = d.w.rig->parts[0].rest.p.y;
	float low = 1e9f, worst_reach = 0.0f;
	for (int k = 0; k < 240; ++k) {
		d.run(Vec3{ 0, 0, 4.5f }, DT);
		low = std::fmin(low, d.w.gait->pose()[0].p.y - d.w.root.p.y);
		for (int i = 0; i < 2; ++i) {
			const int foot = d.w.limbs->limb(i == 0 ? LimbId::LegL : LimbId::LegR).end;
			worst_reach = std::fmax(worst_reach, length(d.w.gait->pose()[size_t(foot)].p - d.w.gait->ankle(i)));
		}
	}
	MESSAGE("run start: ", length(d.vel), " m/s after 4 s, pelvis sank ", (rest_h - low) * 100.0f, " cm, worst ankle miss ",
			worst_reach * 100.0f, " cm");
	CHECK(length(d.vel) > 4.0f);
	CHECK(worst_reach < 0.02f);                  // the legs reach the feet (a foot out of reach drags with the body)
	CHECK(rest_h - low < 0.25f);
	CHECK(d.w.worst_slide < 1e-4f);
}

TEST_CASE("gait: flow - the hips glide, they don't bob at every step") {
	struct Case {
		const char* name;
		Vec3 v;
	};
	const Case cases[] = { { "walk", { 0, 0, 1.4f } }, { "strafe", { 1.4f, 0, 0 } }, { "back", { 0, 0, -1.2f } },
		{ "diagonal", { 1.0f, 0, 1.0f } }, { "run", { 0, 0, 3.5f } } };
	for (const Case& c : cases) {
		Walker w;
		Vec3 vel;
		measure(w, vel, c.v, 2.5f);                    // up to speed
		float lo = 1e9f, hi = -1e9f, fastest = 0.0f;
		float last = w.gait->pose()[0].p.y;
		for (int k = 0; k < 120; ++k) {
			vel = ramp(vel, c.v);
			w.run(vel, DT);
			const float y = w.gait->pose()[0].p.y - w.root.p.y;
			lo = std::fmin(lo, y);
			hi = std::fmax(hi, y);
			fastest = std::fmax(fastest, std::fabs(w.gait->pose()[0].p.y - last) / DT);
			last = w.gait->pose()[0].p.y;
		}
		MESSAGE(std::string(c.name), ": hips move ", (hi - lo) * 100.0f, " cm up and down, at most ", fastest, " m/s vertically; height ", lo, "..", hi);
		CHECK(hi - lo < 0.045f);                       // a gentle rise and fall, not a bob
		CHECK(fastest < 0.65f);                        // (a side-step's quicker rhythm rises a little faster)
	}
}

TEST_CASE("gait: leg effort - the standing leg works, more at a run, the swinging leg little") {
	Walker w;
	w.run(Vec3{}, 0.5f);
	auto leg = [&](int side) {
		const LimbInfo& l = w.limbs->limb(side == 0 ? LimbId::LegL : LimbId::LegR);
		const std::vector<float> e = w.gait->leg_effort();
		return std::fmax(std::fmax(e[size_t(l.upper)], e[size_t(l.lower)]), e[size_t(l.end)]);
	};
	const float standing = std::fmax(leg(0), leg(1));
	const std::vector<float> e0 = w.gait->leg_effort();
	CHECK(e0[0] < 0.0f);                              // the pelvis isn't a leg muscle
	float stance_walk = 0.0f, swing_walk = 0.0f;
	for (int k = 0; k < 120; ++k) {
		w.run(Vec3{ 0, 0, 1.4f }, DT);
		for (int i = 0; i < 2; ++i) {
			(w.gait->foot_planted(i) && !w.gait->foot_planted(1 - i) ? stance_walk : swing_walk) =
					std::fmax(w.gait->foot_planted(i) && !w.gait->foot_planted(1 - i) ? stance_walk : swing_walk, leg(i));
		}
	}
	MESSAGE("leg effort: standing ", standing, ", walking stance ", stance_walk, " / swing ", swing_walk);
	CHECK(standing > 0.0f);
	CHECK(stance_walk > standing);                    // one leg carrying everything works harder
	CHECK(swing_walk < stance_walk);
	CHECK(stance_walk < 3.0f);                        // and the numbers are muscle-sized
}

TEST_CASE("gait drive: a shove is stumbled out of in steps; one too hard can't be caught") {
	struct R {
		int steps;
		float travelled, worst_margin;
	};
	auto shove = [](float dv) {
		Driven d;
		d.run(Vec3{}, 0.5f);
		const int s0 = d.landings;
		d.vel = Vec3{ 0, 0, -dv };                       // shoved backwards
		float worst = 1e9f;
		const float z0 = d.w.root.p.z;
		for (int k = 0; k < 120; ++k) {
			d.run(Vec3{}, DT);
			worst = std::fmin(worst, d.w.gait->capture_margin());
		}
		return R{ d.landings - s0, z0 - d.w.root.p.z, worst };
	};
	const R light = shove(1.2f), hard = shove(2.5f), huge = shove(4.5f);
	MESSAGE("shove 1.2 m/s: ", light.steps, " steps, ", light.travelled, " m, margin ", light.worst_margin, "; 2.5: ", hard.steps,
			" steps, ", hard.travelled, " m, margin ", hard.worst_margin, "; 4.5: margin ", huge.worst_margin);
	CHECK(light.steps >= 1);                           // even a light shove takes a step back
	CHECK(light.worst_margin > 0.0f);                  // ... and is caught
	CHECK(hard.steps > light.steps);                   // a hard one stumbles further
	CHECK(hard.travelled > light.travelled);
	CHECK(huge.worst_margin < 0.0f);                   // this one the feet can't catch
}

TEST_CASE("gait: standing tall - straight legs at rest, and back up after a walk") {
	Walker w;
	const float rest_h = w.rig->parts[0].rest.p.y;
	w.run(Vec3{}, 0.5f);
	const float before = w.gait->pose()[0].p.y - w.root.p.y;
	Vec3 vel;
	measure(w, vel, Vec3{ 0, 0, 1.4f }, 2.0f);
	measure(w, vel, Vec3{}, 2.0f);
	const float after = w.gait->pose()[0].p.y - w.root.p.y;
	MESSAGE("standing pelvis ", before, " (rest ", rest_h, "), after a walk and 2 s still ", after);
	CHECK(before > rest_h - 0.01f);
	CHECK(after > rest_h - 0.015f);
}
