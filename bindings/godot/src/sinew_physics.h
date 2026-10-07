// SinewPhysics: a Sinew physics world as a Godot RefCounted. The thin layer the Godot side
// (SinewCharacter, tests, tools) talks to; it only converts Godot values to Sinew's.
#pragma once

#include "sinew/balance.hpp"
#include "sinew/character.hpp"
#include "sinew/gait.hpp"
#include "sinew/limbs.hpp"
#include "sinew/physics_world.hpp"
#include "sinew/rig.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <map>
#include <memory>
#include <vector>

namespace godot {

class SinewPhysics : public RefCounted {
	GDCLASS(SinewPhysics, RefCounted)

public:
	SinewPhysics();

	/// "sinew 0.1.0 (box3d <commit>)"
	static String version();

	void setup(const Vector3& gravity, int substeps);
	int64_t add_static_box(const Transform3D& xform, const Vector3& half_extents);
	int64_t add_capsule(const Transform3D& xform, const Vector3& a, const Vector3& b, double radius, double density);
	int64_t add_ball_joint(int64_t parent, int64_t child, const Transform3D& frame_parent,
			const Transform3D& frame_child, double cone, double twist_min, double twist_max);
	void step(double dt);
	Transform3D body_transform(int64_t body) const;
	Vector3 linear_velocity(int64_t body) const;
	void set_linear_velocity(int64_t body, const Vector3& v);
	double body_mass(int64_t body) const;
	double joint_cone_angle(int64_t joint) const;
	int64_t state_hash() const;
	int body_count() const;

	// ---- world mirror ----
	enum Kind { KIND_STATIC = 0, KIND_KINEMATIC = 1, KIND_DYNAMIC = 2 };
	int64_t add_body(int kind, const Transform3D& xform);
	void add_box_shape(int64_t body, const Transform3D& local, const Vector3& half_extents, double friction);
	void add_sphere_shape(int64_t body, const Vector3& center, double radius, double friction);
	void add_capsule_shape(int64_t body, const Vector3& a, const Vector3& b, double radius, double friction);
	bool add_hull_shape(int64_t body, const PackedVector3Array& points, double friction);
	bool add_mesh_shape(int64_t body, const PackedVector3Array& vertices, const PackedInt32Array& indices, bool clockwise,
			double friction);
	void remove_body(int64_t body);
	void set_body_kind(int64_t body, int kind);
	void set_transform(int64_t body, const Transform3D& xform);
	void move_kinematic(int64_t body, const Transform3D& target, double dt);
	void apply_impulse(int64_t body, const Vector3& impulse, const Vector3& point);
	Vector3 angular_velocity(int64_t body) const;
	void set_angular_velocity(int64_t body, const Vector3& w);

	// ---- rigs ----
	/// A humanoid rig from a skeleton (bone names, parents, global rests in skeleton space).
	/// Returns a rig id.
	int build_humanoid_rig(const PackedStringArray& names, const PackedInt32Array& parents, const Array& rests,
			const Vector3& up, const Vector3& forward, double mass);
	int rig_part_count(int rig) const;
	/// {name, bone, parent, rest, a, b, radius, mass, region, joint}
	Dictionary rig_part(int rig, int part) const;

	// ---- characters ----
	int add_character(int rig, const Transform3D& root, int group);
	void remove_character(int character);
	int64_t character_body(int character, int part) const;
	/// Every part's world transform, in part order.
	Array character_pose(int character) const;
	void character_set_pose(int character, const Array& world_pose, const Vector3& velocity);
	void character_set_targets(int character, const Array& world_pose);
	void character_set_target_local(int character, int part, const Quaternion& local);
	void character_set_tone(int character, double tone);
	void character_set_part_tone(int character, int part, double tone);
	void character_set_gravity_compensation(int character, double k);
	void character_set_stiffness(int character, double scale);
	void character_set_damping(int character, double linear, double angular);
	void character_set_root_assist(int character, const Transform3D& target, double strength, double dt, double hertz);
	/// All parts kinematic (following move_character_kinematic) or dynamic.
	void character_set_kinematic(int character, bool kinematic);
	void character_set_part_kinematic(int character, int part, bool kinematic);
	void character_move_kinematic(int character, const Array& world_pose, double dt);
	void character_set_velocity(int character, const Vector3& velocity);
	void character_add_velocity(int character, const Vector3& dv, double weight_root, double weight_rest);
	bool character_sever(int character, int part);
	bool character_attached(int character, int part) const;
	Vector3 character_center_of_mass(int character) const;
	double character_worst_joint_gap(int character) const;
	double character_worst_limit_excess(int character) const;
	double character_max_speed(int character) const;

	// ---- limbs: awareness and effectors (limb: 0 arm L, 1 arm R, 2 leg L, 3 leg R, 4 spine, 5 neck) ----
	/// {present, attached, health, end_position, end_velocity, contact, end_contact, reach}
	Dictionary character_limb_state(int character, int limb) const;
	/// Effectors act on the next step only (call every tick, after character_set_targets).
	bool character_reach(int character, int limb, const Vector3& point, double weight);
	bool character_place_foot(int character, int limb, const Vector3& ankle, double weight);
	bool character_look_at(int character, const Vector3& point, double weight, double max_angle);
	void character_lean(int character, double pitch, double roll, double weight);
	/// A procedural local target (part in its parent's frame) mixed in by weight, next step only.
	void character_set_effector(int character, int part, const Quaternion& local, double weight);
	/// Where a part touches something outside its body: [{point, normal, impulse, kind}]
	Array character_part_contacts(int character, int part) const;

	// ---- muscles (debug) ----
	/// Per part: muscle effort (torque / strength, -1 = none or kinematic).
	PackedFloat32Array character_muscle_effort(int character) const;

	// ---- balance: physical legs standing on their own (see sinew/balance.hpp) ----
	/// On: the balancer runs each step (before the muscles). Settings: any BalanceSettings
	/// field by name (ankle_kp, step_time, upright_assist, max_steps, stepping...).
	void character_balance_enable(int character, bool on, const Dictionary& settings);
	bool character_balance_enabled(int character) const;
	void character_balance_reset(int character);
	void character_balance_set_target(int character, const Quaternion& pelvis, double com_height);
	/// {fallen, reason, stepping, steps, com, com_velocity, capture_point, capture_error,
	///  support: PackedVector3Array, planted_l, planted_r}
	Dictionary character_balance_state(int character) const;

	// ---- gait: procedural walking (see sinew/gait.hpp) ----
	/// Settings: any GaitSettings field by name (cadence_base, duty_walk, swing_height, bob, ...).
	void character_gait_enable(int character, bool on, const Dictionary& settings);
	/// Reference cycles: [{speed, samples: [[Quaternion per part] per phase], pelvis_height: PackedFloat32Array}]
	void character_gait_set_cycles(int character, const Array& cycles);
	void character_gait_set_idle(int character, const Array& locals, double pelvis_height);
	void character_gait_reset(int character, const Transform3D& root);
	/// Advance by dt with the character's ground point / facing and velocity; the world pose per part.
	/// `command` (a Vector3, optional): the motion wanted - footholds brake / catch toward it.
	Array character_gait_update(int character, const Transform3D& root, const Vector3& velocity, double dt,
			const Variant& command, const Variant& home_feet = Variant());
	bool character_gait_stepping(int character) const;
	void character_gait_disturb(int character, double seconds);
	/// Physical motion: the velocity after dt for a body at `com` moving at `velocity` toward
	/// `command`, as far as its planted feet allow (Gait::drive).
	/// A ball (dynamic, continuous collision) in the world: hits character parts and the level.
	int64_t add_ball(const Vector3& position, const Vector3& velocity, double radius, double mass, double restitution = 0.35);
	/// Estimated leg muscle effort per part from the gait's pose (Gait::leg_effort; -1: not a leg).
	PackedFloat32Array character_gait_leg_effort(int character) const;
	double character_gait_pelvis_turn(int character) const;
	Vector3 character_gait_drive(int character, const Vector3& com, const Vector3& velocity, const Vector3& command, double dt);
	/// {phase, stepping, cadence, duty, planted_l / r, ankle_l / r (drawn, rolling), plant_l / r (where
	///  it was put down: locked), foothold_l / r}
	Dictionary character_gait_state(int character) const;

	// ---- probes (the level only: character parts are never hit) ----
	/// {hit, point, normal, body}
	Dictionary ground_below(const Vector3& point, double max_distance) const;
	/// {found, distance, drop, point}
	Dictionary edge_ahead(const Vector3& from, const Vector3& dir, double range, double min_drop) const;
	Dictionary wall_within(const Vector3& origin, const Vector3& dir, double reach) const;
	/// Seconds until a body at com moving at velocity meets the level (< 0: not within horizon).
	double impact_eta(const Vector3& com, const Vector3& velocity, double horizon) const;

protected:
	static void _bind_methods();

private:
	std::unique_ptr<sinew::PhysicsWorld> _world;
	std::vector<std::shared_ptr<const sinew::Rig>> _rigs;
	std::map<int, std::unique_ptr<sinew::Character>> _characters;
	std::map<int, std::unique_ptr<sinew::Limbs>> _limbs;
	std::map<int, std::unique_ptr<sinew::Balancer>> _balancers;
	std::map<int, std::unique_ptr<sinew::Gait>> _gaits;
	int _next_character = 1;
	sinew::Character* _char(int id) const;
	const sinew::Limbs* _limbs_of(int id) const;
};

} // namespace godot
VARIANT_ENUM_CAST(godot::SinewPhysics::Kind);
