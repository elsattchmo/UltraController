// A Character: one instance of a Rig in a PhysicsWorld - the bodies, the limit joints, and a
// muscle at every joint pulling toward a target pose against gravity.
//
// Each tick: set targets (from animation or a behaviour), tune muscles, then pre_step() before
// PhysicsWorld::step(). Severing a part detaches it and everything below it, which go limp.
#pragma once

#include "sinew/physics_world.hpp"
#include "sinew/rig.hpp"

#include <algorithm>
#include <memory>
#include <vector>

namespace sinew {

class Character {
public:
	/// Build the body standing in the rig's rest pose at `root` (model space -> world).
	/// Parts get collision group -group_id (they never collide with each other unless
	/// self_collision, which uses the rig's no_collide list instead).
	Character(PhysicsWorld& world, std::shared_ptr<const Rig> rig, const Transform& root, int group_id,
			bool self_collision = true);
	~Character();
	Character(const Character&) = delete;
	Character& operator=(const Character&) = delete;

	const Rig& rig() const { return *_rig; }
	int part_count() const { return int(_parts.size()); }
	BodyHandle body(int part) const { return _parts[size_t(part)].body; }
	Transform part_transform(int part) const;
	/// Teleport every part to a world pose (one transform per part) with a common velocity.
	void set_pose(const std::vector<Transform>& world_pose, Vec3 velocity = {});

	/// Target rotation of `part` relative to its parent part (rest: parent.rest^-1 * part.rest).
	void set_target_local(int part, Quat local);
	Quat target_local(int part) const { return _parts[size_t(part)].target; }
	/// Targets from a whole world pose (e.g. the animated skeleton mapped onto the parts).
	/// Called every tick with a moving pose, the muscles lead it by their own lag (2 zeta /
	/// omega) so they track instead of trailing behind it.
	void set_targets_from_pose(const std::vector<Transform>& world_pose);

	/// A part driven kinematically (it follows move_kinematic and pushes, but isn't pushed),
	/// e.g. the legs while the animation walks. Its muscle rests; parts below can still be
	/// physical, hanging off it.
	void set_part_kinematic(int part, bool kinematic);
	bool part_kinematic(int part) const { return _parts[size_t(part)].kinematic; }
	/// Move the kinematic parts to their place in `world_pose` by the end of the coming step.
	void move_kinematic(const std::vector<Transform>& world_pose, float dt);
	/// A procedural target for one tick, mixed into the part's target by `weight` (0..1) at the
	/// next pre_step, then dropped: effectors (reach, look, place_foot, lean) and code driving a
	/// limb call it every tick, so a procedural pose blends with the animation part by part.
	void set_effector(int part, Quat local, float weight);
	/// The target the next pre_step will use (the effector's mix, if one is set this tick).
	Quat effective_target(int part) const;
	/// The rig's rest pose as targets.
	void set_targets_rest();

	/// Muscle tone: 0 = limp, 1 = the rig's muscles. Scales strength and stiffness.
	void set_tone(float tone);
	float tone() const { return _tone; }
	void set_tone(int part, float tone);
	/// Scales every muscle's stiffness and strength (a body tracking an animation closely wants
	/// more than one lying down). Default 1.
	void set_stiffness(float scale) { _stiffness = std::max(0.0f, scale); }
	/// Every part's velocity damping (1/s): a body settling on the floor gets more, so soft
	/// muscles don't keep it creeping.
	void set_damping(float linear, float angular);
	/// Lead moving targets by the muscles' lag (on by default).
	void set_lead(bool on) { _lead = on; }
	/// 0..1 share of gravity the muscles cancel up front (feed-forward), so soft muscles
	/// still hold a pose. The root carries the rest (it's what stands or lies on something).
	void set_gravity_compensation(float k) { _gravity_comp = k; }
	/// Per part: a leg standing on the ground carries the body instead (the balancer turns its
	/// joints' compensation off - it would hold the leg up as if it hung from the hips).
	void set_part_gravity_compensation(int part, bool on) { _parts[size_t(part)].gravity_comp = on; }
	float gravity_compensation() const { return _gravity_comp; }
	/// Per part: a further stiffness factor on its muscle (hertz and damping) - e.g. a standing
	/// hip, which holds the whole body above it through a light pelvis. Default 1.
	void set_part_stiffness(int part, float k) { _parts[size_t(part)].stiffness = std::max(0.0f, k); }
	/// Caps a muscle's torque (N m; < 0 = none) under its strength - e.g. a standing ankle can't push
	/// harder than the weight on the foot times the ball's lever before the foot tips onto its toes.
	void set_part_torque_cap(int part, float cap) { _parts[size_t(part)].torque_cap = cap; }

	/// Root assist: hold the root part (pelvis) to `target` with a capped spring, the way a
	/// balance controller would. strength 0 = off (the body stands or falls on its own).
	/// Linear: `hertz` / force cap mass * g * strength * 2; angular: 2.5 x hertz,
	/// torque cap 600 N m * strength. Stage S3's stand-in until the balancer (S5) takes over.
	/// Call every tick with the new target (dt: the coming step, so the anchor moves with it).
	void set_root_assist(const Transform& target, float strength, float dt, float hertz = 4.0f);
	float root_assist() const { return _assist; }
	/// Upright assist: only the angular half - the pelvis held to `rotation` by a spring with a
	/// torque cap of 600 N m * strength; nothing holds its position (the legs must). The
	/// balancer's optional help (a documented cheat, as euphoria's balance assistance).
	void set_upright_assist(Quat rotation, float strength, float dt, float hertz = 4.0f);

	/// Apply muscles and gravity compensation for the coming step.
	void pre_step(float dt);
	/// After PhysicsWorld::step: put every part back on its parent's joint anchor (with
	/// its subtree). Box3D's continuous collision stops a fast body at its time of impact on
	/// its own, ignoring joints, which tore a falling body apart by 5-13 cm for a frame.
	/// Returns the largest correction made, metres.
	float post_step();

	/// Cut `part` off its parent: the joint and muscle go, the piece and everything below it
	/// go limp and fall free. Returns false if it was already off (or is the root).
	bool sever(int part);
	bool attached(int part) const;

	float part_tone(int part) const { return _parts[size_t(part)].tone; }
	/// How hard the muscle into `part` worked over the last step: the torque it applied over
	/// its full strength (0 relaxed .. 1 flat out; can exceed 1 briefly). -1: no muscle (the
	/// root, a cut joint) or the part is driven kinematically.
	float muscle_effort(int part) const;
	/// The torque it applied (N m) - for debugging.
	float muscle_torque(int part) const;
	Vec3 part_velocity(int part) const { return _world.linear_velocity(_parts[size_t(part)].body); }
	/// Which part a body is (-1: not one of ours).
	int part_of(BodyHandle body) const;
	/// Where `part` touches something that isn't this character. Returns the count written.
	int part_contacts(int part, ContactPoint* out, int capacity) const;
	/// `part` touches something outside this character (`static_only`: the level).
	bool part_touching(int part, bool static_only = false) const;
	PhysicsWorld& world() const { return _world; }

	float mass() const;
	Vec3 center_of_mass() const;
	/// Largest anchor separation over the joints still attached, metres.
	float worst_joint_gap() const;
	/// Largest swing / hinge excursion past its limit, radians (0 = all within).
	float worst_limit_excess() const;

private:
	struct Part {
		BodyHandle body = 0;
		JointHandle joint = 0;     // limit joint to the parent
		JointHandle muscle = 0;
		Quat target;
		Quat prev_target;
		Quat effector;
		float effector_weight = 0.0f;
		bool tracking = false;     // target set from a pose last tick: lead it
		float tone = 1.0f;
		bool attached = true;
		bool kinematic = false;
		bool gravity_comp = true;
		float stiffness = 1.0f;
		float torque_cap = -1.0f;  // N m, < 0 = none
	};
	PhysicsWorld& _world;
	std::shared_ptr<const Rig> _rig;
	std::vector<Part> _parts;
	std::vector<JointHandle> _filters;
	float _tone = 1.0f;
	float _gravity_comp = 1.0f;
	float _assist = 0.0f;
	float _stiffness = 1.0f;
	bool _lead = true;
	BodyHandle _anchor = 0;     // kinematic body the root assist hangs from
	JointHandle _drive = 0;
	bool _limp_below(int part) const;
	float load_scale(int part, const std::vector<Vec3>& com) const;
};

} // namespace sinew
