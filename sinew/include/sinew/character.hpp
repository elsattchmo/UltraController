// A Character: one instance of a Rig in a PhysicsWorld - the bodies, the limit joints, and a
// muscle at every joint pulling toward a target pose against gravity.
//
// Each tick: set targets (from animation or a behaviour), tune muscles, then pre_step() before
// PhysicsWorld::step(). Severing a part detaches it and everything below it, which go limp.
#pragma once

#include "sinew/physics_world.hpp"
#include "sinew/rig.hpp"

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
	void set_targets_from_pose(const std::vector<Transform>& world_pose);
	/// The rig's rest pose as targets.
	void set_targets_rest();

	/// Muscle tone: 0 = limp, 1 = the rig's muscles. Scales strength and stiffness.
	void set_tone(float tone);
	float tone() const { return _tone; }
	void set_tone(int part, float tone);
	/// 0..1 share of gravity the muscles cancel up front (feed-forward), so soft muscles
	/// still hold a pose. The root carries the rest (it's what stands or lies on something).
	void set_gravity_compensation(float k) { _gravity_comp = k; }

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
		float tone = 1.0f;
		bool attached = true;
	};
	PhysicsWorld& _world;
	std::shared_ptr<const Rig> _rig;
	std::vector<Part> _parts;
	std::vector<JointHandle> _filters;
	float _tone = 1.0f;
	float _gravity_comp = 1.0f;
	bool _limp_below(int part) const;
};

} // namespace sinew
