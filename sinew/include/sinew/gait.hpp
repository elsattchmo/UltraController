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
	float cadence_base = 1.35f, cadence_per_ms = 0.42f, cadence_max = 5.0f, cadence_idle = 1.7f;
	/// Longest step, as a share of the leg's length (hip to sole): walking / running. Shorter legs
	/// step faster at the same speed (the cadence rises until the step fits).
	float step_max_walk = 0.62f, step_max_run = 1.15f;
	/// Foot roll: heel strike with the toes up, then the heel rising round the ball of the foot
	/// before push-off (rad; full at walking speed, toe-up fading at a run: mid-foot landing).
	float toe_up = 0.22f, heel_rise = 0.6f;
	/// Running on the balls of the feet: heel up this much (rad) through the stance at a run / sprint
	/// (a flat planted foot pinned the ankle low: the hips had to dip to reach it at every stride).
	float forefoot_run = 0.25f, forefoot_sprint = 0.4f;
	float roll_rate = 6.0f;                     ///< a standing foot's roll changes at most this fast, rad/s
	/// Share of a foot's cycle on the ground: a walk's (with double support) down to a run's.
	float duty_walk = 0.62f, duty_run = 0.36f;
	float walk_speed = 1.4f, run_speed = 3.5f;  ///< duty goes from walk to run between these
	float swing_height = 0.07f, swing_height_run = 0.16f;
	float bob = 0.012f;                         ///< pelvis up / down, m (twice a stride)
	float sway = 0.028f;                        ///< pelvis toward the standing foot, m
	float run_crouch = 0.0f;                    ///< procedural: pelvis lower at a run, m (knee_bend does it now)
	float arm_swing = 0.32f, arm_swing_run = 0.7f;  ///< procedural arm swing amplitude, rad
	float arms_down = 1.25f;                    ///< procedural: upper arms down from the rest (T) pose, rad
	float spine_twist = 0.09f;                  ///< procedural spine counter-twist, rad
	float stop_speed = 0.08f;                   ///< slower than this = standing
	float home_tolerance = 0.1f;                ///< a standing foot this far off its spot steps home
	float turn_tolerance = 0.55f;               ///< rad between a foot and the facing: step round
	float max_reach = 0.95f;                    ///< share of the leg length the hip may be from an ankle (knees never locked)
	/// Knees: the body carries itself lower the faster it goes (m): walking, running, sprinting.
	float knee_bend = 0.025f, knee_bend_run = 0.08f, knee_bend_sprint = 0.11f, sprint_speed = 6.0f;
	/// Flow: the reference cycles' own pelvis bob kept at this share; the drop a stretched leg
	/// needs is eased - in at `drop_rise` m/s, out at `drop_fall` (the hips settle low through a
	/// stride instead of dipping at every step); only what's beyond that by `drop_slack` is taken at once.
	float cycle_bob = 0.6f, drop_rise = 0.15f, drop_fall = 0.06f, drop_slack = 0.06f;
	/// 8-way: the longest step backing / sideways as a share of the forward one (the cadence rises
	/// to make up the speed: short quick side-steps, never a lunge).
	float step_back = 0.72f, step_side = 0.65f;
	/// Ankles at least this far apart sideways (body frame): a side-step never crosses the feet.
	float stance_gap = 0.13f;
	/// A standing foot left this far from its hip (share of the longest step), behind the motion,
	/// lifts at once (the motion reversed): the hips never sink to reach a foot left behind.
	float stretch = 0.8f;
	/// ... and while one is, the cycle runs up to this many times faster (the other foot lands sooner).
	float hurry_max = 2.5f, hurry_ease = 20.0f;   ///< (eased at hurry_ease per second)
	/// A swinging foot's foothold moves at most this fast when the motion changes (m/s).
	float retarget_speed = 3.0f;                ///< (+ the current speed)
	/// Hip warp: the legs walk in a frame turned toward the travel (a share of the angle off the
	/// facing, at most `warp_max` rad; backing diagonals turn toward the backward direction), the
	/// pelvis takes `warp_pelvis` of it and the spine turns the rest back so the chest keeps
	/// facing. Eased at `warp_rate` rad/s. A side-step at walking speed is then a turned walk.
	float warp_gain = 0.5f, warp_max = 0.7f, warp_pelvis = 0.8f, warp_rate = 3.0f;
	/// Momentum: the body leans into its acceleration (braking leans back, setting off forward, a
	/// reversal swings from one to the other), `lean_gain` x a/g rad, through a damped spring
	/// (`lean_hz`, `lean_zeta`: it lags the change, overshoots a little and settles). Bounded so
	/// nothing flies: at most `lean_max` rad, turning at most `lean_rate` rad/s; the pelvis takes
	/// `lean_pelvis` of it and moves `lean_shift` x its height x the lean (<= `lean_shift_max` m)
	/// so the weight goes over the feet; the arms trail the old motion by `arm_lag` x the lean.
	float lean_gain = 0.3f, lean_max = 0.25f, lean_hz = 2.2f, lean_zeta = 0.55f, lean_rate = 2.5f;
	float lean_pelvis = 0.35f, lean_shift = 0.0f, lean_shift_max = 0.07f, arm_lag = 0.7f;
	/// Physical motion (drive()): the body's centre of mass as an inverted pendulum (height h,
	/// omega = sqrt(g / h)) over its centre of pressure, which can only be inside the planted soles
	/// (heel up: the balls; toes up: the heels; no foot down: nowhere - no push in flight).
	/// It aims to reach the command in `drive_tau` s, never pushing harder than `friction` x g.
	float drive_tau = 0.2f, friction = 0.45f;
	float capture_gain = 1.5f;                  ///< foothold feedback on (velocity - command) / omega
	float land_max = 0.85f;                     ///< a foothold at most this share of the leg from the hip
	float sole_half_width = 0.045f;             ///< the support's half width at each foot, m
	float toe_ahead = 0.06f;                    ///< sole support past the ball, m
	float standing_accel = 3.0f;                ///< barely moving: plain capped acceleration (no pendulum)
	/// Speed trim: the feet reach further ahead of the ankle than behind it, so pushing on and
	/// braking aren't equal - an integral on (command - velocity), <= `trim_max` x the command,
	/// lets a steady walk settle at the speed asked for. Fades when stopping.
	float trim_gain = 1.5f, trim_max = 0.4f;
};

struct GaitInput {
	Transform root;      ///< the character's ground point and facing (model space -> world)
	Vec3 velocity;       ///< world, m/s (the ground part is used)
	float dt = 1.0f / 60.0f;
	/// The motion wanted (world, m/s). With it, footholds brake and catch the body: a foot goes
	/// down ahead of where the body is heading by its capture offset ((velocity - command) / omega),
	/// so a change of motion takes real steps. Without it, the feet follow `velocity`.
	Vec3 command;
	bool has_command = false;
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
	/// The ankle's world position (0 left, 1 right) as drawn: rolling on the heel / ball, or on its way.
	Vec3 ankle(int foot) const { return _feet[size_t(foot)].eff; }
	/// Where a planted foot was put down (its flat ankle position): it never moves while planted.
	Vec3 plant(int foot) const { return _feet[size_t(foot)].pos; }
	/// Where a foot is heading (its foothold) / where it would stand still.
	Vec3 foothold(int foot) const { return _feet[size_t(foot)].target; }
	Vec3 home(int foot) const;
	float cadence() const { return _cadence; }
	/// Physical motion: the velocity after `dt` for a body at `com` (ground point under the centre
	/// of mass) moving at `velocity`, wanting `command` - accelerated only as its feet allow (see
	/// GaitSettings::drive_tau). Uses the feet as of the last update(); call once per tick.
	Vec3 drive(Vec3 com, Vec3 velocity, Vec3 command, float dt);
	/// The centre of pressure drive() used last (world, on the ground plane).
	Vec3 cop() const { return _cop; }
	/// How hard each leg muscle would be working in the pose last solved (torque over the rig's
	/// strength, as Character::muscle_effort; -1 for parts that aren't legs) - for showing animated
	/// (kinematic) legs: a standing leg carries its share of the weight (split by how near the centre
	/// of mass is to each planted foot) and the push of drive()'s acceleration, applied at its part of
	/// the centre of pressure, against each joint's lever arm; a swinging leg holds itself up.
	std::vector<float> leg_effort() const;
	/// The support polygon: planted soles (ground plane, counter-clockwise from above). Empty in flight.
	std::vector<Vec3> support() const;
	/// The legs' turn toward the travel off the facing (rad, + = to the left).
	float warp() const { return _warp; }
	/// The momentum lean: world, horizontal, direction x angle (rad).
	Vec3 lean() const { return _lean; }
	/// How much faster than its cadence the cycle ran last tick (a foot left stretched behind).
	float hurry() const { return _hurry; }
	/// Times the cycle was hurried at full rate (a standing foot left far behind: the motion turned).
	int early_lifts() const { return _early_lifts; }
	float duty() const { return _duty; }
	GaitSettings& settings() { return _s; }

private:
	struct Foot {
		Vec3 pos;            ///< ankle, world, as planted (flat; locked while planted)
		Vec3 eff;            ///< ankle, world, as drawn (rolled on heel / ball)
		float pitch = 0.0f;  ///< foot roll: + heel up (round the ball), - toes up (round the heel)
		float lift_pitch = 0.0f;
		Vec3 lift, target;   ///< swing: from / to
		Quat yaw;            ///< world facing the foot was put down with
		Quat lift_yaw;
		bool swinging = false;
		int lift_t = 0;      ///< ticks into the swing
		int down_t = 100;    ///< ticks since it was put down
		float lift_p = 0.62f; ///< the foot's phase when it lifted (the swing runs from there to 1)
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
	float _heel_d = 0.06f, _ball_d = 0.1f;  ///< heel behind / ball ahead of the ankle, m
	float _leg_len = 0.9f;
	float _step_max = 0.5f;  ///< longest step this tick (direction and gait), m
	Vec3 hip_ground(int foot) const;
	float _warp = 0.0f;
	float _drop = 0.0f, _dt = 1.0f / 60.0f;
	Vec3 _cmd, _cop, _trim, _drive_acc;
	float _pelvis_h = 0.95f;     ///< last pelvis height over the ground (the pendulum's length)
	bool _has_cmd = false;
	Vec3 _lean, _lean_v, _acc, _prev_vel;
	void update_lean(float dt);
	float _hurry = 1.0f, _hurry_want = 1.0f;
	int _early_lifts = 0;
	bool _warp_back = false;
	Quat legs_q() const;
	float swing_s(const Foot& f, float p) const;    ///< 0..1 through the swing
	float _phase_step = 0.02f;                      ///< phase advanced last tick     ///< the legs' frame: the facing turned by the warp   ///< the hip's lateral spot on the ground plane under the root
	void roll(Foot& f, float pitch) const;
	Vec3 _hip_model[2];      ///< the thighs' joints in model space (lateral offsets)
	int _leg[2] = { -1, -1 };

	Vec3 up() const;
	float ground_y(Vec3 p, float fallback) const;
	void base_pose(std::vector<Quat>& local, Quat& pelvis_model, float& pelvis_h) const;
	void step_feet(float dt);
	void solve(const std::vector<Quat>& local, Quat pelvis_model, float pelvis_h);
};

} // namespace sinew
