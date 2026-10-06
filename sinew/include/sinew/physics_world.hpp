// The physics layer: one Box3D world per PhysicsWorld. Every Box3D call in Sinew lives
// behind this interface (src/physics_world.cpp), so the solver can be swapped without
// touching rigs, control or behaviours.
#pragma once

#include "sinew/types.hpp"

#include <cstdint>
#include <memory>

namespace sinew {

struct WorldSettings {
	Vec3 gravity{ 0.0f, -9.81f, 0.0f };
	int substeps = 8;   ///< solver substeps per step (8 keeps joints within ~2 mm under hard hits)
	int workers = 1;    ///< Box3D worker threads (1 = run on the caller's thread)
	/// Joint constraint stiffness (Box3D soft step). Box3D clamps it to a quarter of the
	/// substep rate, so stiffer joints need more substeps: 8 substeps at 60 Hz allow 120.
	float joint_hertz = 120.0f;
	float joint_damping = 2.0f;
};

struct CapsuleDesc {
	Transform xform;          ///< body origin in the world
	Vec3 a, b;                ///< capsule segment in body space
	float radius = 0.05f;
	float density = 1000.0f;  ///< kg/m^3
	float friction = 0.6f;
	int group = 0;            ///< bodies sharing a negative group never collide
};

struct BallJointDesc {
	BodyHandle parent = 0, child = 0;
	Transform frame_parent;   ///< joint frame in the parent body's space (cone axis = +Z)
	Transform frame_child;    ///< joint frame in the child body's space (twist axis = +Z)
	float cone = 0.5f;        ///< swing limit, radians (<= 0: no cone limit)
	float twist_min = -0.3f, twist_max = 0.3f; ///< radians (min >= max: no twist limit)
};

class PhysicsWorld {
public:
	explicit PhysicsWorld(const WorldSettings& settings = {});
	~PhysicsWorld();
	PhysicsWorld(const PhysicsWorld&) = delete;
	PhysicsWorld& operator=(const PhysicsWorld&) = delete;

	BodyHandle add_static_box(const Transform& xform, Vec3 half_extents, float friction = 0.6f);
	BodyHandle add_capsule_body(const CapsuleDesc& desc);
	JointHandle add_ball_joint(const BallJointDesc& desc);
	void destroy_joint(JointHandle joint);

	void step(float dt);

	Transform body_transform(BodyHandle body) const;
	Vec3 linear_velocity(BodyHandle body) const;
	/// Velocity of the body's centre of mass.
	void set_linear_velocity(BodyHandle body, Vec3 v);
	Vec3 angular_velocity(BodyHandle body) const;
	void set_angular_velocity(BodyHandle body, Vec3 w);
	/// Centre of mass in world space.
	Vec3 center_of_mass(BodyHandle body) const;
	float body_mass(BodyHandle body) const;
	/// Current swing angle of a ball joint, radians.
	float joint_cone_angle(JointHandle joint) const;
	/// Hash of every dynamic body's pose and velocity bits: equal hashes = identical runs.
	uint64_t state_hash() const;
	int body_count() const;

private:
	struct Impl;
	std::unique_ptr<Impl> _impl;
};

} // namespace sinew
