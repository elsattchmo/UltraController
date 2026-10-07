// Limb awareness: a character's body seen as limbs (arms, legs, spine, neck) - what each one
// is made of, whether it's still attached, how strong it is, where its end is and what it
// touches - and the effectors that move them: reach a hand to a point, place a foot, look at
// something, lean the spine. Effectors solve the limb's joints (two-bone IK, spine spread) into
// muscle targets for one tick (Character::set_effector), mixed with the animated pose by a
// weight, so code can drive any limb while the clip plays the rest.
#pragma once

#include "sinew/character.hpp"

#include <array>
#include <vector>

namespace sinew {

enum class LimbId : int { ArmL, ArmR, LegL, LegR, Spine, Neck, Count };

struct LimbInfo {
	std::vector<int> parts;   ///< root first
	int root = -1;            ///< the part that hangs off the body
	int upper = -1, lower = -1, end = -1;   ///< arms / legs: the two IK bones and the hand / foot
	Vec3 end_offset;          ///< arms / legs: the wrist / ankle in `lower`'s frame
	float upper_len = 0.0f, lower_len = 0.0f;
	bool present() const { return root >= 0; }
};

struct LimbState {
	bool present = false;
	bool attached = false;    ///< joined to the body all the way up
	float health = 0.0f;      ///< weakest muscle tone along the limb (0 = limp / gone, 1 = full)
	Vec3 end_position;        ///< hand / foot / head / upper-chest centre, world
	Vec3 end_velocity;
	bool contact = false;     ///< any of its parts touches something outside the body
	bool end_contact = false; ///< its end (hand, foot, head) does
	float reach = 0.0f;       ///< arms / legs: fully stretched length from the root joint
};

class Limbs {
public:
	explicit Limbs(const Rig& rig);

	const LimbInfo& limb(LimbId id) const { return _limbs[size_t(id)]; }
	LimbState state(const Character& c, LimbId id) const;
	/// World position of a limb's end part's centre.
	Vec3 end_position(const Character& c, LimbId id) const;

	/// Reach an arm's hand (its centre) to a world point. Out of reach it stretches toward it.
	/// Returns false if the arm is missing or cut off.
	bool reach(Character& c, LimbId arm, Vec3 point, float weight = 1.0f) const;
	/// Put a leg's ankle at a world point, the foot keeping its animated orientation.
	bool place_foot(Character& c, LimbId leg, Vec3 ankle, float weight = 1.0f) const;
	/// Turn the head toward a world point (at most `max_angle` away from the animated look).
	bool look(Character& c, Vec3 point, float weight = 1.0f, float max_angle = 1.2f) const;
	/// Lean the spine: pitch forward (+) / back, roll toward the body's right (+) / left,
	/// radians, spread over the spine's parts.
	void lean(Character& c, float pitch, float roll, float weight = 1.0f) const;

private:
	const Rig& _rig;
	std::array<LimbInfo, size_t(LimbId::Count)> _limbs;
	struct Solve {
		Quat parent;          ///< the upper bone's parent, live
		Quat upper_world;     ///< solved
		Quat lower_local;
		Vec3 root;            ///< the upper bone's joint, world
	};
	bool solve_two_bone(const Character& c, const LimbInfo& l, Vec3 target, Solve& out) const;
	bool two_bone(Character& c, const LimbInfo& l, Vec3 target, float weight, bool keep_end_world) const;
	/// World rotation of `part` with the targets of the coming step, from its parent's live pose.
	Quat target_world(const Character& c, int part) const;
};

/// Environment probes against the level (character parts are never seen).
struct EdgeProbe {
	bool found = false;
	float distance = 0.0f;    ///< along the direction to where the ground drops away
	float drop = 0.0f;        ///< how far down (max_drop + if nothing within range)
	Vec3 point;               ///< the last solid ground before the drop
};

namespace probes {
/// The ground straight under `p` within `max_distance`.
RayHit ground_below(const PhysicsWorld& w, Vec3 p, float max_distance = 3.0f);
/// Walk from `from` (a point at about the feet) along `dir` (flattened) up to `range`, looking
/// for the ground to fall away more than `min_drop`.
EdgeProbe edge_ahead(const PhysicsWorld& w, Vec3 from, Vec3 dir, float range = 1.5f, float min_drop = 0.45f);
/// A wall (or anything) within `reach` along `dir` from `origin`, swept as a 10 cm sphere.
RayHit wall_within(const PhysicsWorld& w, Vec3 origin, Vec3 dir, float reach = 0.8f);
/// Time until a body at `com` moving at `velocity` under gravity meets the level (the arc
/// swept in short segments), < 0 if not within `horizon` seconds.
float impact_eta(const PhysicsWorld& w, Vec3 com, Vec3 velocity, float horizon = 3.0f);
} // namespace probes

} // namespace sinew
