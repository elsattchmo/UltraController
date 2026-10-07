#include "sinew/rig.hpp"

#include "sinew/math.hpp"

#include <algorithm>
#include <initializer_list>

namespace sinew {

int Rig::find(const std::string& name) const {
	for (size_t i = 0; i < parts.size(); ++i) {
		if (parts[i].name == name) {
			return int(i);
		}
	}
	return -1;
}

float Rig::total_mass() const {
	float m = 0.0f;
	for (const PartDef& p : parts) {
		m += p.mass;
	}
	return m;
}

std::vector<int> Rig::subtree(int part) const {
	std::vector<int> out{ part };
	// Parents come first, so one forward pass collects every descendant.
	for (size_t i = size_t(part) + 1; i < parts.size(); ++i) {
		if (std::find(out.begin(), out.end(), parts[i].parent) != out.end()) {
			out.push_back(int(i));
		}
	}
	return out;
}

int SkeletonDesc::find(const std::string& name) const {
	for (size_t i = 0; i < names.size(); ++i) {
		if (names[i] == name) {
			return int(i);
		}
	}
	return -1;
}

namespace {

// UltraLimbs.Region values (the Godot demo's damage regions). The core only carries them.
enum Region { HEAD = 0, TORSO = 1, ARM_L = 2, FOREARM_L = 3, ARM_R = 4, FOREARM_R = 5, THIGH_L = 6, SHIN_L = 7,
	THIGH_R = 8, SHIN_R = 9, HAND_L = 10, HAND_R = 11, FOOT_L = 12, FOOT_R = 13 };

enum class Shape { Along, Lateral };

struct Spec {
	const char* bone;
	const char* parent;      // parent part's bone
	const char* end;         // bone the capsule runs to ("" = extend along the bone)
	float extend;            // length (x height) when there's no end bone
	float mass;              // de Leva segment mass fraction (male)
	float radius;            // x height
	Shape shape;
	float half_width;        // lateral capsules: x height
	JointKind joint;
	float swing, twist;      // ball: degrees
	float tilt;              // ball: cone centre turned this far (deg) toward tilt_dir
	Vec3 tilt_dir;           // in model space (+Z forward, +Y up, +X the body's left)
	float hinge_min, hinge_max; // hinge: degrees
	Vec3 flex_dir;           // hinge: which way the child moves when the joint flexes
	float strength;          // N m
	float hertz;
	int region;
};

const Vec3 UP{ 0, 1, 0 }, DOWN{ 0, -1, 0 }, FWD{ 0, 0, 1 }, BACK{ 0, 0, -1 };

// Joint ranges are anatomical (ROM tables), muscle strengths roughly an adult's peak torques.
const Spec SPECS[] = {
	{ "Hips", "", "", 0, 0.1117f, 0.075f, Shape::Lateral, 0.045f, JointKind::Root, 0, 0, 0, {}, 0, 0, {}, 0, 0, TORSO },
	{ "Spine", "Hips", "Chest", 0, 0.0820f, 0.070f, Shape::Lateral, 0.035f, JointKind::Ball, 30, 25, 0, {}, 0, 0, {}, 300, 7, TORSO },
	{ "Chest", "Spine", "UpperChest", 0, 0.0813f, 0.070f, Shape::Lateral, 0.050f, JointKind::Ball, 25, 20, 0, {}, 0, 0, {}, 300, 7, TORSO },
	{ "UpperChest", "Chest", "Neck", 0, 0.1096f, 0.070f, Shape::Lateral, 0.070f, JointKind::Ball, 20, 15, 0, {}, 0, 0, {}, 250, 7, TORSO },
	{ "Neck", "UpperChest", "", 0.17f, 0.0694f, 0.058f, Shape::Along, 0, JointKind::Ball, 45, 60, 10, FWD, 0, 0, {}, 40, 8, HEAD },
	{ "LeftShoulder", "UpperChest", "LeftUpperArm", 0, 0.0250f, 0.030f, Shape::Along, 0, JointKind::Ball, 25, 15, 0, {}, 0, 0, {}, 220, 8, TORSO },
	{ "LeftUpperArm", "LeftShoulder", "LeftLowerArm", 0, 0.0271f, 0.030f, Shape::Along, 0, JointKind::Ball, 85, 110, 40, { 0, -0.8f, 0.6f }, 0, 0, {}, 80, 8, ARM_L },
	{ "LeftLowerArm", "LeftUpperArm", "LeftHand", 0, 0.0162f, 0.024f, Shape::Along, 0, JointKind::Hinge, 0, 0, 0, {}, -5, 145, FWD, 60, 9, FOREARM_L },
	{ "LeftHand", "LeftLowerArm", "", 0.075f, 0.0061f, 0.024f, Shape::Along, 0, JointKind::Ball, 70, 80, 0, {}, 0, 0, {}, 15, 10, HAND_L },
	{ "RightShoulder", "UpperChest", "RightUpperArm", 0, 0.0250f, 0.030f, Shape::Along, 0, JointKind::Ball, 25, 15, 0, {}, 0, 0, {}, 220, 8, TORSO },
	{ "RightUpperArm", "RightShoulder", "RightLowerArm", 0, 0.0271f, 0.030f, Shape::Along, 0, JointKind::Ball, 85, 110, 40, { 0, -0.8f, 0.6f }, 0, 0, {}, 80, 8, ARM_R },
	{ "RightLowerArm", "RightUpperArm", "RightHand", 0, 0.0162f, 0.024f, Shape::Along, 0, JointKind::Hinge, 0, 0, 0, {}, -5, 145, FWD, 60, 9, FOREARM_R },
	{ "RightHand", "RightLowerArm", "", 0.075f, 0.0061f, 0.024f, Shape::Along, 0, JointKind::Ball, 70, 80, 0, {}, 0, 0, {}, 15, 10, HAND_R },
	{ "LeftUpperLeg", "Hips", "LeftLowerLeg", 0, 0.1416f, 0.048f, Shape::Along, 0, JointKind::Ball, 70, 35, 35, FWD, 0, 0, {}, 250, 7, THIGH_L },
	{ "LeftLowerLeg", "LeftUpperLeg", "LeftFoot", 0, 0.0433f, 0.034f, Shape::Along, 0, JointKind::Hinge, 0, 0, 0, {}, -3, 145, BACK, 200, 8, SHIN_L },
	{ "LeftFoot", "LeftLowerLeg", "LeftToes", 0.04f, 0.0137f, 0.025f, Shape::Along, 0, JointKind::Ball, 35, 15, 0, {}, 0, 0, {}, 120, 9, FOOT_L },
	{ "RightUpperLeg", "Hips", "RightLowerLeg", 0, 0.1416f, 0.048f, Shape::Along, 0, JointKind::Ball, 70, 35, 35, FWD, 0, 0, {}, 250, 7, THIGH_R },
	{ "RightLowerLeg", "RightUpperLeg", "RightFoot", 0, 0.0433f, 0.034f, Shape::Along, 0, JointKind::Hinge, 0, 0, 0, {}, -3, 145, BACK, 200, 8, SHIN_R },
	{ "RightFoot", "RightLowerLeg", "RightToes", 0.04f, 0.0137f, 0.025f, Shape::Along, 0, JointKind::Ball, 35, 15, 0, {}, 0, 0, {}, 120, 9, FOOT_R },
};

/// The fold target when an optional bone is missing.
const char* fallback(const std::string& bone) {
	if (bone == "LeftShoulder" || bone == "RightShoulder") {
		return "UpperChest";
	}
	if (bone == "UpperChest") {
		return "Chest";
	}
	if (bone == "Chest") {
		return "Spine";
	}
	return nullptr;
}

} // namespace

Rig build_humanoid_rig(const SkeletonDesc& sk, const HumanoidOptions& options) {
	Rig rig;
	// Height from the skeleton: feet to the top of the head bone (+ a head's height).
	float top = 0.0f, bottom = 1e9f;
	for (const Transform& t : sk.rests) {
		top = std::max(top, dot(t.p, sk.up));
		bottom = std::min(bottom, dot(t.p, sk.up));
	}
	const int head_bone = sk.find("Head");
	const float H = std::max(0.5f, (head_bone >= 0 ? dot(sk.rests[size_t(head_bone)].p, sk.up) + 0.0f : top) / 0.87f);
	const Vec3 left = cross(sk.up, sk.forward);   // the body's left (+X for +Y up, +Z forward)
	// Model-space directions in the specs are written for +Y up, +Z forward, +X left.
	auto model_dir = [&](Vec3 d) { return normalized(left * d.x + sk.up * d.y + sk.forward * d.z); };

	std::vector<std::string> part_bones;
	for (const Spec& s : SPECS) {
		const int bone = sk.find(s.bone);
		if (bone < 0) {
			continue;
		}
		PartDef p;
		p.name = s.bone;
		p.bone = bone;
		p.rest = sk.rests[size_t(bone)];
		p.mass = s.mass * options.mass;
		p.region = s.region;
		p.muscle = Muscle{ s.hertz, 1.0f, s.strength * options.strength };
		p.joint = s.joint;
		// Parent: the named bone if it's a part, else what it folds into.
		std::string parent = s.parent;
		while (!parent.empty() && rig.find(parent) < 0) {
			const char* f = fallback(parent);
			parent = f ? f : "";
		}
		p.parent = parent.empty() ? -1 : rig.find(parent);
		if (s.joint != JointKind::Root && p.parent < 0) {
			continue;   // a limb without anything to hang from
		}
		// Capsule end: the end bone (or what replaces it), else an extension along the bone.
		std::string end = s.end;
		int end_bone = end.empty() ? -1 : sk.find(end);
		if (end_bone < 0 && end == "UpperChest") {
			end_bone = sk.find("Neck");
		}
		const Transform inv = inverse(p.rest);
		const Vec3 bone_dir_local{ 0.0f, 1.0f, 0.0f };   // humanoid bones point down +Y
		Vec3 end_local = end_bone >= 0 ? xform(inv, sk.rests[size_t(end_bone)].p) : bone_dir_local * (s.extend * H);
		if (end_bone >= 0 && s.extend > 0.0f) {
			end_local = end_local + normalized(end_local) * (s.extend * H);   // feet: on past the toes' root
		}
		p.radius = s.radius * H;
		if (s.shape == Shape::Lateral) {
			// A wide capsule across the body at the middle of the segment.
			Vec3 mid = end_local * 0.5f;
			if (std::string(s.bone) == "Hips") {
				mid = Vec3{ 0, 0, 0 } + rotate(conj(p.rest.q), -sk.up) * (0.02f * H);
			}
			Vec3 side = rotate(conj(p.rest.q), left) * (s.half_width * H);
			p.a = mid - side;
			p.b = mid + side;
		} else {
			const float len = length(end_local);
			const Vec3 dir = normalized(end_local);
			const float inset = std::min(0.3f * p.radius, 0.25f * len);
			p.a = dir * inset;
			p.b = dir * (len - inset);
			if (std::string(s.bone).find("Foot") != std::string::npos) {
				// A foot rests flat: keep the toe end's capsule above the sole.
				const float ankle_h = dot(p.rest.p, sk.up) - bottom;
				p.radius = std::min(p.radius, std::max(0.6f * ankle_h, 0.02f));
			}
		}
		if (p.parent >= 0) {
			const PartDef& par = rig.parts[size_t(p.parent)];
			const Transform par_inv = inverse(par.rest);
			// Child frame: +Z along the bone (twist axis).
			const Vec3 axis_child = normalized(end_local.x == 0 && end_local.y == 0 && end_local.z == 0 ? bone_dir_local : end_local);
			const Quat q_child = from_to(Vec3{ 0, 0, 1 }, axis_child);
			// The same frame seen from the parent (zero relative rotation at rest).
			const Quat q_parent_rest = conj(par.rest.q) * p.rest.q * q_child;
			p.frame_child = Transform{ Vec3{}, q_child };
			const Vec3 pivot = xform(par_inv, p.rest.p);
			if (s.joint == JointKind::Ball) {
				Quat qa = q_parent_rest;
				if (s.tilt != 0.0f) {
					// Turn the cone's centre (world: the bone's rest direction) toward tilt_dir.
					const Vec3 bone_world = rotate(p.rest.q, axis_child);
					const Vec3 toward = model_dir(s.tilt_dir);
					const Vec3 axis = cross(bone_world, toward);
					if (length(axis) > 1e-4f) {
						const Quat tilt_world = axis_angle(axis, s.tilt * DEG);
						qa = conj(par.rest.q) * tilt_world * par.rest.q * qa;
					}
				}
				p.frame_parent = Transform{ pivot, qa };
				p.swing = s.swing * DEG;
				p.twist_min = -s.twist * DEG;
				p.twist_max = s.twist * DEG;
			} else {
				// Hinge about (bone x flex direction): positive angles flex.
				const Vec3 bone_world = rotate(p.rest.q, axis_child);
				const Vec3 hinge_world = normalized(cross(bone_world, model_dir(s.flex_dir)));
				const Quat frame_world = from_to(Vec3{ 0, 0, 1 }, hinge_world);
				p.frame_child = Transform{ Vec3{}, conj(p.rest.q) * frame_world };
				p.frame_parent = Transform{ pivot, conj(par.rest.q) * frame_world };
				p.hinge_min = s.hinge_min * DEG;
				p.hinge_max = s.hinge_max * DEG;
			}
		}
		part_bones.push_back(s.bone);
		rig.parts.push_back(p);
	}
	// Fold the mass of missing optional segments into the part that covers them.
	auto fold = [&](const char* missing, const char* into, float fraction) {
		if (sk.find(missing) < 0 && rig.find(into) >= 0) {
			rig.parts[size_t(rig.find(into))].mass += fraction * options.mass;
		}
	};
	fold("UpperChest", "Chest", 0.1096f);
	fold("LeftShoulder", "UpperChest", 0.0250f);
	fold("RightShoulder", "UpperChest", 0.0250f);
	fold("LeftHand", "LeftLowerArm", 0.0061f);
	fold("RightHand", "RightLowerArm", 0.0061f);
	fold("LeftFoot", "LeftLowerLeg", 0.0137f);
	fold("RightFoot", "RightLowerLeg", 0.0137f);
	// Grandparent pairs (and the thighs, which overlap at the crotch) never collide.
	for (size_t i = 0; i < rig.parts.size(); ++i) {
		const int p = rig.parts[i].parent;
		if (p >= 0 && rig.parts[size_t(p)].parent >= 0) {
			rig.no_collide.push_back({ rig.parts[size_t(p)].parent, int(i) });
		}
	}
	auto pair = [&](const char* a, const char* b) {
		if (rig.find(a) >= 0 && rig.find(b) >= 0) {
			rig.no_collide.push_back({ rig.find(a), rig.find(b) });
		}
	};
	pair("LeftUpperLeg", "RightUpperLeg");
	pair("Neck", "LeftUpperArm");
	pair("Neck", "RightUpperArm");
	pair("Neck", "LeftShoulder");
	pair("Neck", "RightShoulder");
	pair("LeftShoulder", "RightShoulder");
	pair("Spine", "LeftUpperLeg");
	pair("Spine", "RightUpperLeg");
	pair("Chest", "LeftUpperArm");
	pair("Chest", "RightUpperArm");
	// Arms hang and swing right against the torso and past the hips and thighs: with the torso as
	// capsules (wider than a slim body) they caught on it and couldn't reach the animated pose.
	for (const char* side : { "Left", "Right" }) {
		for (const char* limb : { "UpperArm", "LowerArm", "Hand" }) {
			const std::string arm = std::string(side) + limb;
			for (const char* body : { "Hips", "Spine", "Chest", "UpperChest", "LeftUpperLeg", "RightUpperLeg", "LeftShoulder", "RightShoulder" }) {
				pair(arm.c_str(), body);
			}
		}
	}
	return rig;
}

SkeletonDesc make_test_skeleton(float H) {
	SkeletonDesc sk;
	struct B {
		const char* name;
		const char* parent;
		Vec3 pos;    // x height; +X = the body's left, +Z forward
	};
	const B bones[] = {
		{ "Hips", "", { 0, 0.530f, 0 } },
		{ "Spine", "Hips", { 0, 0.580f, 0 } },
		{ "Chest", "Spine", { 0, 0.650f, 0 } },
		{ "UpperChest", "Chest", { 0, 0.720f, 0 } },
		{ "Neck", "UpperChest", { 0, 0.820f, 0 } },
		{ "Head", "Neck", { 0, 0.870f, 0 } },
		{ "LeftShoulder", "UpperChest", { 0.020f, 0.800f, 0 } },
		{ "LeftUpperArm", "LeftShoulder", { 0.110f, 0.810f, 0 } },
		{ "LeftLowerArm", "LeftUpperArm", { 0.296f, 0.810f, 0 } },
		{ "LeftHand", "LeftLowerArm", { 0.442f, 0.810f, 0 } },
		{ "RightShoulder", "UpperChest", { -0.020f, 0.800f, 0 } },
		{ "RightUpperArm", "RightShoulder", { -0.110f, 0.810f, 0 } },
		{ "RightLowerArm", "RightUpperArm", { -0.296f, 0.810f, 0 } },
		{ "RightHand", "RightLowerArm", { -0.442f, 0.810f, 0 } },
		{ "LeftUpperLeg", "Hips", { 0.050f, 0.500f, 0 } },
		{ "LeftLowerLeg", "LeftUpperLeg", { 0.050f, 0.285f, 0 } },
		{ "LeftFoot", "LeftLowerLeg", { 0.050f, 0.039f, 0 } },
		{ "LeftToes", "LeftFoot", { 0.050f, 0.012f, 0.100f } },
		{ "RightUpperLeg", "Hips", { -0.050f, 0.500f, 0 } },
		{ "RightLowerLeg", "RightUpperLeg", { -0.050f, 0.285f, 0 } },
		{ "RightFoot", "RightLowerLeg", { -0.050f, 0.039f, 0 } },
		{ "RightToes", "RightFoot", { -0.050f, 0.012f, 0.100f } },
	};
	const size_t n = sizeof(bones) / sizeof(bones[0]);
	for (size_t i = 0; i < n; ++i) {
		sk.names.push_back(bones[i].name);
		sk.parents.push_back(bones[i].parent[0] ? sk.find(bones[i].parent) : -1);
	}
	// Each bone's +Y points at its first child (or carries on from its parent at a tip).
	for (size_t i = 0; i < n; ++i) {
		Vec3 pos = bones[i].pos * H;
		Vec3 dir{ 0, 0, 0 };
		for (size_t k = i + 1; k < n; ++k) {
			if (sk.parents[k] == int(i)) {
				dir = bones[k].pos * H - pos;
				break;
			}
		}
		if (length(dir) < 1e-6f) {
			dir = sk.parents[i] >= 0 ? pos - bones[size_t(sk.parents[i])].pos * H : Vec3{ 0, 1, 0 };
		}
		if (std::string(bones[i].name) == "Head") {
			dir = Vec3{ 0, 1, 0 };
		}
		Vec3 hint = std::fabs(normalized(dir).z) > 0.9f ? Vec3{ 0, 1, 0 } : Vec3{ 0, 0, 1 };
		sk.rests.push_back(Transform{ pos, basis_y(dir, hint) });
	}
	return sk;
}

} // namespace sinew
