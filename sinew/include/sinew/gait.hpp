// Gait: procedural walking and running (Overgrowth-style). Footsteps come from the motion -
// each foot alternates stance and swing on a shared phase, the cadence and the share of the
// cycle spent standing follow the speed (a walk's double support, a run's flight). A standing
// foot is LOCKED where it was put (no foot sliding, by construction); a swinging foot heads for
// where the hip will be when it lands, on the real ground (ray probes: stairs, slopes) and lifts
// over an arc. The pelvis bobs and sways over the standing foot and drops when a foothold is low.
// The rest of the body comes from key poses: reference cycles (local rotations sampled at phases
// of a clip, phase 0 = left foot contact) blended by phase and speed - or, without any, a
// procedural arm swing and spine counter-twist. The legs are then fitted to the footholds with
// two-bone IK. Stopping takes a step or two to bring the feet home; turning on the spot steps too.
//
// The output is a world pose for the rig's parts: the body you show, and the target its muscles
// track.
#pragma once

#include "sinew/limbs.hpp"
#include "sinew/physics_world.hpp"
#include "sinew/rig.hpp"

#include <vector>

namespace sinew {

/// A reference cycle: one full stride (two steps), sampled at evenly spaced phases.
struct GaitCycle {
	float speed = 1.3f;                         ///< m/s it was authored at
	std::vector<std::vector<Quat>> samples;     ///< [sample][part]: local rotation (the root part: model space)
	std::vector<float> pelvis_height;           ///< [sample] pelvis height over the ground, model space
};

struct GaitSettings {
	/// Steps per second: base + per_ms * speed, capped; turning / settling on the spot: `idle`.
	float cadence_base = 1.35f, cadence_per_ms = 0.42f, cadence_max = 3.3f, cadence_idle = 1.7f;
	/// Share of a foot's cycle on the ground: a walk's (with double support) down to a run's.
	float duty_walk = 0.62f, duty_run = 0.36f;
	float walk_speed = 1.4f, run_speed = 3.5f;  ///< duty goes from walk to run between these
	float swing_height = 0.07f, swing_height_run = 0.16f;
	float bob = 0.022f;                         ///< pelvis up / down, m (twice a stride)
	float sway = 0.028f;                        ///< pelvis toward the standing foot, m
	float run_crouch = 0.05f;                   ///< pelvis lower at a run, m
	float arm_swing = 0.32f, arm_swing_run = 0.7f;  ///< procedural arm swing amplitude, rad
	float arms_down = 1.25f;                    ///< procedural: upper arms down from the rest (T) pose, rad
	float spine_twist = 0.09f;                  ///< procedural spine counter-twist, rad
	float stop_speed = 0.08f;                   ///< slower than this = standing
	float home_tolerance = 0.1f;                ///< a standing foot this far off its spot steps home
	float turn_tolerance = 0.55f;               ///< rad between a foot and the facing: step round
	float max_reach = 0.985f;                   ///< share of the leg length the hip may be from an ankle
};

struct GaitInput {
	Transform root;      ///< the character's ground point and facing (model space -> world)
	Vec3 velocity;       ///< world, m/s (the ground part is used)
	float dt = 1.0f / 60.0f;
};

class Gait {
public:
	/// `world` (optional) is probed for the ground under footholds.
	Gait(const Rig& rig, const Limbs& limbs, const PhysicsWorld* world = nullptr, const GaitSettings& settings = {});

	/// Reference cycles, any order (kept sorted by speed). Empty: procedural.
	void set_cycles(std::vector<GaitCycle> cycles);
	/// The standing pose (local rotations per part, root in model space); empty = the rig's rest.
	void set_idle_pose(std::vector<Quat> locals, float pelvis_height = -1.0f);
	/// Feet planted at their home spots under `root`, standing still.
	void reset(const Transform& root);
	void update(const GaitInput& in);

	/// World transform of every part (rig order).
	const std::vector<Transform>& pose() const { return _pose; }
	float phase() const { return _phase; }
	bool stepping() const { return _stepping; }
	bool foot_planted(int foot) const { return !_feet[size_t(foot)].swinging; }
	/// The ankle's world position (0 left, 1 right): planted or on its way.
	Vec3 ankle(int foot) const { return _feet[size_t(foot)].pos; }
	/// Where a foot is heading (its foothold) / where it would stand still.
	Vec3 foothold(int foot) const { return _feet[size_t(foot)].target; }
	Vec3 home(int foot) const;
	float cadence() const { return _cadence; }
	float duty() const { return _duty; }
	GaitSettings& settings() { return _s; }

private:
	struct Foot {
		Vec3 pos;            ///< ankle, world
		Vec3 lift, target;   ///< swing: from / to
		Quat yaw;            ///< world facing the foot was put down with
		Quat lift_yaw;
		bool swinging = false;
		float p = 0.0f;      ///< foot phase last tick
	};
	const Rig& _rig;
	const Limbs& _limbs;
	const PhysicsWorld* _world;
	GaitSettings _s;
	std::vector<GaitCycle> _cycles;
	std::vector<Quat> _idle;
	float _idle_height = -1.0f;
	std::vector<Quat> _rest_local;
	std::vector<Transform> _pose;
	Foot _feet[2];
	Transform _root;
	Vec3 _vel;
	float _phase = 0.0f, _cadence = 1.7f, _duty = 0.62f, _speed = 0.0f;
	bool _stepping = false;
	float _ankle_h = 0.08f;
	Vec3 _hip_model[2];      ///< the thighs' joints in model space (lateral offsets)
	int _leg[2] = { -1, -1 };

	Vec3 up() const;
	float ground_y(Vec3 p, float fallback) const;
	void base_pose(std::vector<Quat>& local, Quat& pelvis_model, float& pelvis_h) const;
	void step_feet(float dt);
	void solve(const std::vector<Quat>& local, Quat pelvis_model, float pelvis_h);
};

} // namespace sinew
