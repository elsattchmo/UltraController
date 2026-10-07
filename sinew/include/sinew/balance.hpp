// Balance: keeping a physical body on its feet the way a person does - no hand of god.
//
// Each tick it reads the body (centre of mass and its velocity, which feet are planted, the
// support polygon from their contacts with the ground, the capture point: where the COM would
// come to rest over if a foot were put there now) and acts through the legs only:
//  * stance: a virtual force on the COM (hold it over the support, at standing height) and a
//    torque on the pelvis (keep it upright, facing the way it should), turned into joint torques
//    up each planted leg (Jacobian transpose: an internal torque pair at ankle, knee and hip,
//    capped by the muscles' strength) - the ground pushes back through the feet, so it works
//    only as far as friction and the feet's footprint allow (ankle strategy, hip strategy);
//  * stepping: when the capture point leaves the support polygon, the foot farther from it
//    swings (place_foot along an arc) to just past the capture point;
//  * falling: too many steps, a step out of reach, the pelvis tipped or the COM sunk - it gives
//    up (fallen()), and the host lets the body go (a knock-down).
#pragma once

#include "sinew/limbs.hpp"

#include <vector>

namespace sinew {

struct BalanceSettings {
	float ankle_kp = 4.0f;        ///< shin lean (rad) per metre of COM off its target
	float ankle_kd = 1.5f;        ///< ... and per m/s of COM speed (damping)
	float max_lean = 0.25f;       ///< rad
	float stance_stiffness = 6.0f;  ///< standing hips / ankles: muscle stiffness factor
	float step_margin = 0.05f;    ///< capture point this far outside the support -> step
	float step_time = 0.22f;      ///< seconds a step takes (a little more for long ones)
	float step_time_per_m = 0.1f;
	float retarget_until = 0.4f;  ///< share of the swing during which the landing spot follows
	float step_height = 0.08f;    ///< foot lift mid-swing
	float step_past = 0.0f;       ///< foot put this far beyond the capture point ...
	float step_beyond = 0.0f;     ///< ... plus this share of its distance from the standing foot
	float max_step = 0.85f;       ///< longest step from the standing foot
	float min_width = 0.12f;      ///< feet never closer sideways than this (no crossing)
	float stance_width = 0.18f;   ///< closing step: feet this far apart (ankles), side by side
	int max_steps = 10;           ///< recovery steps before it gives up
	bool stepping = true;         ///< off: ankle / hip strategies only
	/// Upright assist (0 = none): a capped spring holding the pelvis upright and facing - no
	/// help with position, so pushes still have to be stepped out of. Euphoria's balancer had
	/// the same kind of help; real legs and feet do it with far finer control than ours.
	float upright_assist = 0.3f;
	float planted_tilt = 0.6f;    ///< a foot stands while its sole faces up at least this much (cos)
	float planted_lift = 0.06f;   ///< ... and its ankle is no higher than this over its usual height
	float fall_tilt = 0.9f;       ///< pelvis tipped this far from upright (rad) -> fallen
	float fall_sink = 0.6f;       ///< COM below this share of standing height -> fallen
};

class Balancer {
public:
	Balancer(Character& c, const Limbs& limbs, const BalanceSettings& settings = {});

	/// The standing pose to hold: the pelvis' world orientation (upright, facing) and the COM's
	/// height above the ground. Set from the current body if never called.
	void set_target(Quat pelvis, float com_height);
	/// Where the COM should be held over the support (world, the ground plane part counts),
	/// e.g. the animated COM; default: the middle of the planted feet.
	void set_com_target(Vec3 com);
	void clear_com_target() { _has_com_target = false; }
	/// Start over: both feet planted, no steps taken, not fallen (target re-read from the body).
	void reset();
	/// Run before Character::pre_step, after the targets for this tick are set.
	void pre_step(float dt);

	bool fallen() const { return _fallen; }
	/// Why it gave up: "tipped", "sank", "airborne", "out of steps", "leg lost" ("" = standing).
	const char* fall_reason() const { return _reason; }
	bool stepping() const { return _swing >= 0; }
	int steps() const { return _steps; }   ///< every step taken since reset()
	Vec3 com() const { return _com; }
	Vec3 com_velocity() const { return _com_vel; }
	Vec3 capture_point() const { return _cp; }
	/// The support polygon (ground plane), counter-clockwise seen from above.
	const std::vector<Vec3>& support() const { return _hull; }
	/// How far the capture point is outside the support (negative: inside), metres.
	float capture_error() const { return _cp_out; }
	bool planted(LimbId leg) const;
	const BalanceSettings& settings() const { return _s; }
	BalanceSettings& settings() { return _s; }

private:
	Character& _c;
	const Limbs& _limbs;
	BalanceSettings _s;
	Vec3 _up{ 0, 1, 0 };
	Quat _pelvis_target;
	float _height = 0.0f;
	bool _has_target = false;
	Vec3 _com_target;
	bool _has_com_target = false;
	float _ankle_height = 0.08f;
	// state
	Vec3 _com, _com_vel, _cp;
	float _cp_out = 0.0f;
	std::vector<Vec3> _hull;
	bool _planted[2] = { true, true };
	int _swing = -1;              ///< 0 left leg, 1 right leg, -1 none
	float _swing_t = 0.0f, _swing_time = 0.3f;
	Vec3 _swing_from, _swing_to;
	int _steps = 0;
	bool _fallen = false;
	const char* _reason = "";
	float _airborne_t = 0.0f;
	int _touch_age[2] = { 99, 99 };   ///< ticks since each foot last touched (contacts flicker)
	std::vector<Vec3> _last_support[2];
	bool _grounded_once = false;
	float _since_step = 1.0f;     ///< seconds since the last foot came down
	int _recovery_steps = 0;      ///< steps since it last stood steady
	float _steady_t = 0.0f;
	bool _tidying = false;        ///< the step under way is a closing step
	int _tidy_foot = -1;          ///< a closing step waiting for the weight to shift off this foot
	float _tidy_wait = 0.0f;
	Vec3 _tidy_to;

	LimbId leg(int i) const { return i == 0 ? LimbId::LegL : LimbId::LegR; }
	Vec3 ankle(int i) const;
	Vec3 sole_centre(int i) const;
	float ground_at(Vec3 p) const;
	void start_step(int force_swing = -1);
	/// After a recovery: bring the feet back side by side (the stance it stands best in).
	bool tidy_step();
	void stance_forces(float dt);
};

/// Convex hull (counter-clockwise seen from `up`) of points projected on the ground plane.
std::vector<Vec3> ground_hull(const std::vector<Vec3>& points, Vec3 up);
/// Signed distance from p (projected) to a hull: > 0 outside, < 0 inside.
float hull_distance(const std::vector<Vec3>& hull, Vec3 p, Vec3 up);

} // namespace sinew
