// The physics layer: one Box3D world per PhysicsWorld. Every Box3D call in Sinew lives
// behind this interface (src/physics_world.cpp), so the solver can be swapped without
// touching rigs, control or behaviours.
#pragma once

#include "sinew/types.hpp"

#include <cstdint>
#include <memory>

namespace sinew {

enum class BodyKind { Static, Kinematic, Dynamic };

struct WorldSettings {
	Vec3 gravity{ 0.0f, -9.81f, 0.0f };
	int substeps = 8;   ///< solver substeps per step (8 keeps joints within ~2 mm under hard hits)
	int workers = 1;    ///< Box3D worker threads (1 = run on the caller's thread)
	/// Joint constraint stiffness (Box3D soft step). Box3D clamps it to a quarter of the
	/// substep rate, so stiffer joints need more substeps: 8 substeps at 60 Hz allow 120.
	float joint_hertz = 120.0f;
	float joint_damping = 2.0f;
	/// Contact softness (Box3D): stiffness, damping ratio and the fastest speed overlap is
	/// pushed apart at. 0 = Box3D's defaults.
	float contact_hertz = 0.0f;
	float contact_damping = 0.0f;
	float contact_push_speed = 0.0f;
	/// Box3D's continuous collision (time of impact) for fast bodies.
	bool continuous = true;
};

struct CapsuleDesc {
	Transform xform;          ///< body origin in the world
	Vec3 a, b;                ///< capsule segment in body space
	float radius = 0.05f;
	float density = 1000.0f;  ///< kg/m^3
	float friction = 0.6f;
	int group = 0;            ///< bodies sharing a negative group never collide
};

/// A body part: one capsule with a given mass (density follows from the capsule's volume).
struct PartBodyDesc {
	Transform xform;
	Vec3 a, b;                ///< capsule segment in body space
	float radius = 0.05f;
	bool box = false;         ///< a box (box_xform / box_half, body space) instead of the capsule
	Transform box_xform;
	Vec3 box_half;
	float mass = 1.0f;        ///< kg
	float friction = 0.7f;
	int group = 0;            ///< bodies sharing a negative group never collide
	Vec3 velocity;
	const char* name = nullptr;
};

struct BallJointDesc {
	BodyHandle parent = 0, child = 0;
	Transform frame_parent;   ///< joint frame in the parent body's space (cone axis = +Z)
	Transform frame_child;    ///< joint frame in the child body's space (twist axis = +Z)
	float cone = 0.5f;        ///< swing limit, radians (<= 0: no cone limit)
	float twist_min = -0.3f, twist_max = 0.3f; ///< radians (min >= max: no twist limit)
};

/// A hinge (knee, elbow): rotation about the frames' +Z only, limited to [min, max].
struct HingeJointDesc {
	BodyHandle parent = 0, child = 0;
	Transform frame_parent, frame_child;
	float min = 0.0f, max = 0.0f;  ///< radians; positive = child turning about +Z
};

/// A muscle: a capsule-free angular spring between two bodies with a torque cap (Box3D's motor
/// joint, linear part off). It pulls the child's rotation toward parent * target.
struct MuscleState {
	Quat target;                   ///< wanted child rotation in the parent body's frame
	float hertz = 0.0f;            ///< spring natural frequency (mass-normalised): stiffness
	float damping = 1.0f;          ///< spring damping ratio
	float strength = 0.0f;         ///< max torque, N m (0 = relaxed)
};

/// One point where a body touches another.
struct ContactPoint {
	BodyHandle other = 0;     ///< the body touched
	BodyKind other_kind = BodyKind::Static;
	Vec3 point;               ///< world
	Vec3 normal;              ///< world, pointing from the other body into this one
	float impulse = 0.0f;     ///< normal impulse over the last step, N s
};

/// What a world query hit (character parts are never hit: queries see the level only).
struct RayHit {
	bool hit = false;
	Vec3 point;
	Vec3 normal;
	float fraction = 1.0f;    ///< along the translation, 0..1
	BodyHandle body = 0;
};

class PhysicsWorld {
public:
	explicit PhysicsWorld(const WorldSettings& settings = {});
	~PhysicsWorld();
	PhysicsWorld(const PhysicsWorld&) = delete;
	PhysicsWorld& operator=(const PhysicsWorld&) = delete;

	BodyHandle add_static_box(const Transform& xform, Vec3 half_extents, float friction = 0.6f);

	// ---- world mirror: a host engine's colliders as bodies + shapes ----
	/// An empty body; give it shapes with the add_*_shape calls. Static and kinematic bodies
	/// stand in for the host's level geometry and its moving things (doors, platforms, props).
	BodyHandle add_body(BodyKind kind, const Transform& xform);
	void add_box_shape(BodyHandle body, const Transform& local, Vec3 half_extents, float friction = 0.6f);
	void add_sphere_shape(BodyHandle body, Vec3 center, float radius, float friction = 0.6f);
	void add_capsule_shape(BodyHandle body, Vec3 a, Vec3 b, float radius, float friction = 0.6f);
	/// Convex hull of the points (false if they are degenerate).
	bool add_hull_shape(BodyHandle body, const Vec3* points, int count, float friction = 0.6f);
	/// Triangle mesh (static bodies only collide with it). `clockwise` = front faces wind
	/// clockwise (Godot's convention). The world keeps the mesh data alive.
	bool add_mesh_shape(BodyHandle body, const Vec3* vertices, int vertex_count, const int* indices,
			int triangle_count, bool clockwise, float friction = 0.6f);
	/// Remove a body that isn't a character part (a mirrored collider that went away).
	void remove_body(BodyHandle body);
	BodyHandle add_capsule_body(const CapsuleDesc& desc);
	BodyHandle add_part(const PartBodyDesc& desc);
	JointHandle add_ball_joint(const BallJointDesc& desc);
	JointHandle add_hinge_joint(const HingeJointDesc& desc);
	/// A muscle from parent to child acting about `pivot` (in the parent's frame).
	JointHandle add_muscle(BodyHandle parent, BodyHandle child, Vec3 pivot_in_parent, Vec3 pivot_in_child);
	void set_muscle(JointHandle muscle, Vec3 pivot_in_parent, const MuscleState& state);
	/// A drive: a full 6-dof spring (linear + angular, each with a force / torque cap) pulling
	/// `child` onto `parent` * frame. Used to hold a body's root to an animated pose.
	JointHandle add_drive(BodyHandle parent, BodyHandle child);
	void set_drive(JointHandle drive, const Transform& frame_in_parent, float linear_hertz, float linear_damping,
			float max_force, float angular_hertz, float angular_damping, float max_torque);
	/// Bodies a and b never collide with each other.
	JointHandle add_no_collide(BodyHandle a, BodyHandle b);
	void destroy_joint(JointHandle joint);
	void destroy_body(BodyHandle body);
	/// How far the two anchors of a joint have drifted apart, metres.
	float joint_separation(JointHandle joint) const;
	float hinge_angle(JointHandle joint) const;
	float joint_twist_angle(JointHandle joint) const;
	/// The torque a joint applied over the last step (N m, world).
	Vec3 joint_torque(JointHandle joint) const;

	void set_body_kind(BodyHandle body, BodyKind kind);
	/// Teleport (no velocity change).
	void set_transform(BodyHandle body, const Transform& xform);
	/// Kinematic bodies: reach `target` by the end of the next step of length dt.
	void move_kinematic(BodyHandle body, const Transform& target, float dt);
	/// Velocity damping (1/s) of a body.
	void set_damping(BodyHandle body, float linear, float angular);
	/// Torque (N m) applied over the next step.
	void apply_torque(BodyHandle body, Vec3 torque);
	void apply_linear_impulse(BodyHandle body, Vec3 impulse, Vec3 world_point);
	Vec3 gravity() const;

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
	/// Points where `body` touches something (other bodies' shapes in contact this step).
	/// Returns how many were written (at most `capacity`).
	int contacts(BodyHandle body, ContactPoint* out, int capacity) const;
	/// Closest hit of a ray / a swept sphere from `origin` along `translation`, against the
	/// level (static, kinematic and loose bodies - never character parts).
	RayHit cast_ray(Vec3 origin, Vec3 translation) const;
	RayHit cast_sphere(Vec3 origin, float radius, Vec3 translation) const;
	BodyKind body_kind(BodyHandle body) const;

	/// Hash of every dynamic body's pose and velocity bits: equal hashes = identical runs.
	uint64_t state_hash() const;
	int body_count() const;

private:
	struct Impl;
	std::unique_ptr<Impl> _impl;
};

} // namespace sinew
