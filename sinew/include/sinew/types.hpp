// Sinew - active-physics character engine. Engine-agnostic value types.
// No engine or physics-library types appear in Sinew's public headers, so a binding
// (Godot, Unity, Unreal) only ever converts these plain structs.
#pragma once

#include <cstdint>

namespace sinew {

struct Vec3 {
	float x = 0.0f, y = 0.0f, z = 0.0f;
};

struct Quat {
	float x = 0.0f, y = 0.0f, z = 0.0f, w = 1.0f;
};

struct Transform {
	Vec3 p;
	Quat q;
};

/// Opaque handles (Box3D ids stored in 64 bits). 0 = none.
using BodyHandle = uint64_t;
using JointHandle = uint64_t;

} // namespace sinew
