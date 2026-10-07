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

	/// Root assist: hold the root part (pelvis) to `target` with a capped spring, the way a
	/// balance controller would. strength 0 = off (the body stands or falls on its own).
	/// Linear: `hertz` / force cap mass * g * strength * 2; angular: 2.5 x hertz,
	/// torque cap 600 N m * strength. Stage S3's stand-in until the balancer (S5) takes over.
	/// Call every tick with the new target (dt: the coming step, so the anchor moves with it).
	void set_root_assist(const Transform& target, float strength, float dt, float hertz = 4.0f);
	float root_assist() const { return _assist; }

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
		bool tracking = false;     // target set from a pose last tick: lead it
		float tone = 1.0f;
		bool attached = true;
		bool kinematic = false;
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
