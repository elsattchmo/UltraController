// The rig: a character's physical body description - its parts (one capsule each, following a
// skeleton bone), how each part hangs off its parent (ball with cone + twist limits, or hinge)
// and the muscle at each joint. Built once per model (build_humanoid_rig), shared by every
// Character made from it.
#pragma once

#include "sinew/types.hpp"

#include <string>
#include <vector>

namespace sinew {

enum class JointKind { Root, Ball, Hinge };

/// Muscle tuning at a joint. Stiffness as a natural frequency keeps the feel independent of
/// the limb's inertia; strength caps the torque, so a strong blow overpowers it.
struct Muscle {
	float hertz = 6.0f;       ///< stiffness (natural frequency of the joint spring)
	float damping = 1.0f;     ///< damping ratio (1 = critical)
	float strength = 100.0f;  ///< max torque, N m
};

struct PartDef {
	std::string name;         ///< part name, e.g. "Hips" (the bone it follows)
	int parent = -1;          ///< parent part index (-1 = root)
	int bone = -1;            ///< index of the bone in the source skeleton
	Transform rest;           ///< the part's frame at rest, model space (= the bone's global rest)
	Vec3 a, b;                ///< capsule segment in part space
	float radius = 0.05f;
	float mass = 1.0f;        ///< kg
	float friction = 0.7f;
	JointKind joint = JointKind::Root;
	/// Joint frames in the parent's and this part's space. The pivot is this part's origin.
	/// Ball: the cone is centred on frame_parent's +Z, twist is about frame_child's +Z.
	/// Hinge: rotation about +Z of both, [hinge_min, hinge_max].
	Transform frame_parent, frame_child;
	float swing = 0.0f;
	float twist_min = 0.0f, twist_max = 0.0f;
	float hinge_min = 0.0f, hinge_max = 0.0f;
	Muscle muscle;
	int region = -1;          ///< host damage region (UltraLimbs.Region for the Godot demo)
};

struct Rig {
	std::vector<PartDef> parts;          ///< parents always come before their children
	std::vector<std::pair<int, int>> no_collide;   ///< non-adjacent pairs that must not collide
	Vec3 up{ 0.0f, 1.0f, 0.0f };          ///< model space: the body's up and the way it faces
	Vec3 forward{ 0.0f, 0.0f, 1.0f };

	int find(const std::string& name) const;
	float total_mass() const;
	/// Indices of `part` and every part below it.
	std::vector<int> subtree(int part) const;
};

/// A skeleton as the host engine sees it: bones in parent-first order with global rests in
/// model space. Bone names follow Godot's SkeletonProfileHumanoid (Hips, Spine, Chest,
/// UpperChest, Neck, Head, LeftUpperArm, LeftLowerArm, LeftHand, LeftUpperLeg, ...).
struct SkeletonDesc {
	std::vector<std::string> names;
	std::vector<int> parents;
	std::vector<Transform> rests;        ///< global (model space) rest of each bone
	Vec3 up{ 0.0f, 1.0f, 0.0f };
	Vec3 forward{ 0.0f, 0.0f, 1.0f };    ///< the way the model faces (Godot humanoid: +Z)
	int find(const std::string& name) const;
};

struct HumanoidOptions {
	float mass = 75.0f;              ///< total body mass, kg (split by de Leva's segment fractions)
	float strength = 1.0f;           ///< scales every muscle's strength
};

/// The physical body for a humanoid skeleton: 19 parts (pelvis, spine, chest, upper chest,
/// head, clavicles, arms, forearms, hands, thighs, shins, feet) with anatomical joint ranges.
/// Missing optional bones (UpperChest, hands, feet) are folded into their parents.
Rig build_humanoid_rig(const SkeletonDesc& skeleton, const HumanoidOptions& options = {});

/// A synthetic SkeletonProfileHumanoid T-pose (standing on y = 0, facing +Z), for tests and
/// tools without a model.
SkeletonDesc make_test_skeleton(float height = 1.8f);

} // namespace sinew
