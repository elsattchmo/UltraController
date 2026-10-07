// SinewPhysics: a Sinew physics world as a Godot RefCounted. The thin layer the Godot side
// (SinewCharacter, tests, tools) talks to; it only converts Godot values to Sinew's.
#pragma once

#include "sinew/physics_world.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <memory>

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

protected:
	static void _bind_methods();

private:
	std::unique_ptr<sinew::PhysicsWorld> _world;
};

} // namespace godot
