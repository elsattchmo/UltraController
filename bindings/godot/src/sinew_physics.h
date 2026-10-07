// SinewPhysics: a Sinew physics world as a Godot RefCounted. The thin layer the Godot side
// (SinewCharacter, tests, tools) talks to; it only converts Godot values to Sinew's.
#pragma once

#include "sinew/character.hpp"
#include "sinew/physics_world.hpp"
#include "sinew/rig.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
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

protected:
	static void _bind_methods();

private:
	std::unique_ptr<sinew::PhysicsWorld> _world;
	std::vector<std::shared_ptr<const sinew::Rig>> _rigs;
	std::map<int, std::unique_ptr<sinew::Character>> _characters;
	int _next_character = 1;
	sinew::Character* _char(int id) const;
};

} // namespace godot
VARIANT_ENUM_CAST(godot::SinewPhysics::Kind);
